-- init.lua - PURE STATE MACHINE VERSION with Bindings Module
local mq = require("mq")
local database = require("modules.database")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local lootHistory = require("modules.loot_history")
local lootStats = require("modules.loot_stats")
local json = require("dkjson")
local config = require("modules.config")
local util = require("modules.util")
local lfs = require("lfs")
local Icons = require("mq.icons")
local actors = require("actors")
local modeHandler = require("modules.mode_handler")
local SmartLootEngine = require("modules.SmartLootEngine")
local waterfallTracker = require("modules.waterfall_chain_tracker")
local bindings = require("modules.bindings")  -- NEW: Load bindings module

-- init.lua - PURE STATE MACHINE VERSION with Bindings Module
local mq = require("mq")
local database = require("modules.database")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local lootHistory = require("modules.loot_history")
local lootStats = require("modules.loot_stats")
local json = require("dkjson")
local config = require("modules.config")
local util = require("modules.util")
local lfs = require("lfs")
local Icons = require("mq.icons")
local actors = require("actors")
local modeHandler = require("modules.mode_handler")
local SmartLootEngine = require("modules.SmartLootEngine")
local waterfallTracker = require("modules.waterfall_chain_tracker")
local bindings = require("modules.bindings")  -- NEW: Load bindings module

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local dbInitialized = false
local function initializeDatabase()
    if not dbInitialized then
        local success, err = database.healthCheck()
        if success then
            logging.log("[SmartLoot] SQLite database initialized successfully")
            dbInitialized = true
        else
            logging.log("[SmartLoot] Failed to initialize SQLite database: " .. tostring(err))
            database.refreshLootRuleCache()
            dbInitialized = true
        end
    end
end

local function getCurrentToon()
    return mq.TLO.Me.Name() or "unknown"
end

local function processStartupArguments(args)
    modeHandler.initialize("main")
    
    if #args == 0 then
        -- No arguments provided - use dynamic detection
        local rgRunning = false
        if mq.TLO.Lua.Script("rgmercs").Status() == "RUNNING" then
            rgRunning = true
        end
        
        local inGroupRaid = mq.TLO.Group.Members() > 1 or mq.TLO.Raid.Members() > 0
        
        if rgRunning and inGroupRaid then
            logging.log("No arguments but detected RGMercs context - using dynamic mode")
            return modeHandler.handleRGMercsCall(args)
        else
            -- Non-RGMercs scenario - check peer order for dynamic mode
            logging.log("No arguments and no RGMercs - checking peer order for dynamic mode")
            
            if modeHandler.shouldBeRGMain() then
                logging.log("Peer order indicates this character should be Main looter")
                return "main"
            else
                logging.log("Peer order indicates this character should be Background looter")
                return "background"
            end
        end
    end
    
    local firstArg = args[1]:lower()
    
    if firstArg == "main" then
        return "main"
    elseif firstArg == "once" then
        return "once"
    elseif firstArg == "background" then
        return "background"
    elseif firstArg == "rgmain" then
        modeHandler.state.originalMode = "rgmain"
        return "rgmain"
    elseif firstArg == "rgonce" then
        modeHandler.state.originalMode = "rgonce"
        return "rgonce"
    else
        logging.log("Unknown argument detected, treating as RGMercs call: " .. firstArg)
        return modeHandler.handleRGMercsCall(args)
    end
end

-- ============================================================================
-- ENGINE INITIALIZATION
-- ============================================================================

local function initializeSmartLootEngine(args)
    if not dbInitialized then
        logging.log("[SmartLoot] Cannot initialize engine - database not ready")
        return false
    end

    local initialMode = processStartupArguments(args or {})
    
    local modeMapping = {
        ["main"] = SmartLootEngine.LootMode.Main,
        ["once"] = SmartLootEngine.LootMode.Once,
        ["background"] = SmartLootEngine.LootMode.Background,
        ["rgmain"] = SmartLootEngine.LootMode.RGMain,
        ["rgonce"] = SmartLootEngine.LootMode.RGOnce
    }
    
    local engineMode = modeMapping[initialMode] or SmartLootEngine.LootMode.Background

    SmartLootEngine.setLootMode(engineMode, "Startup initialization")

    logging.log("[SmartLoot] State machine engine initialized in mode: " .. engineMode)
    return true, initialMode
end

-- ============================================================================
-- STARTUP
-- ============================================================================

local args = {...}

mq.delay(150)

initializeDatabase()
local engineInitialized, runMode = initializeSmartLootEngine(args)

if not engineInitialized then
    runMode = "main"
    logging.log("[SmartLoot] Engine initialization failed, defaulting to main mode")
end

if runMode ~= "main" and runMode ~= "once" and runMode ~= "background" and 
   runMode ~= "rgmain" and runMode ~= "rgonce" then
    util.printSmartLoot('Invalid run mode: ' .. runMode .. '. Valid options are "main", "once", "background", "rgmain", or "rgonce"', "error")
    runMode = "main"
end

-- Make runMode globally accessible for other modules
_G.runMode = runMode

if runMode == "main" or runMode == "background" then
    modeHandler.startPeerMonitoring()
    logging.log("[SmartLoot] Peer monitoring started for dynamic mode switching")
end

if config.master_looter_mode then
    require("smartloot.master.init")
end

-- ============================================================================
-- PEER DATABASE DISCOVERY
-- ============================================================================

local availablePeers = {}
local function scanForPeerDatabases()
    local dbPath = mq.TLO.MacroQuest.Path('resources')()
    
    if not dbPath then
        logging.log("[SmartLoot] Could not get resources path")
        return
    end
    
    for file in lfs.dir(dbPath) do
        local server = file:match("^smartloot_(.-)%.db$")
        if server then
            table.insert(availablePeers, {
                name = server,
                server = server,
                filename = file
            })
            logging.log("[SmartLoot] Found database for server: " .. server)
        end
    end
end

scanForPeerDatabases()

-- ============================================================================
-- UI STATE (Simplified for State Engine)
-- ============================================================================

local lootUI = { 
    show = true,
    currentItem = nil,
    choices = {},
    showEditor = true,
    newItem = "",
    newRule = "Keep",
    newThreshold = 1,
    paused = false,
    pendingDeleteItem = nil,
    pendingDecision = nil,
    selectedPeer = "",
    selectedViewPeer = "Local",
    applyToAllPeers = false,
    editingThresholdForPeer = nil,
    remoteDecisions = {},
    showHotbar = true,
    showUI = false,
    showDebugWindow = false,  -- Add debug window flag
    selectedItemForPopup = nil,

    peerItemRulesPopup = {
        isOpen = false,
        itemName = ""
    },

    updateIDsPopup = {
        isOpen = false,
        itemName = "",
        currentItemID = 0,
        currentIconID = 0,
        newItemID = 0,
        newIconID = 0
    },

    addNewRulePopup = {
        isOpen = false,
        itemName = "",
        rule = "Keep",
        threshold = 1,
        selectedCharacter = ""
    },
    
    iconUpdatePopup = {
        isOpen = false,
        itemName = "",
        currentIconID = 0,
        newIconID = 0
    },

    searchFilter = "",
    selectedZone = mq.TLO.Zone.Name() or "All",
    peerOrderList = nil,
    selectedPeerToAdd = nil,
    lastFetchFilters = {},
    pageStats = {},
    totalItems = 0,
    needsStatsRefetch = true,
    lootStatsMode = "stats",
    resumeItemIndex = nil,
    useFloatingButton = true,
    showPeerCommands = true,
    showSettingsTab = false,
    emergencyStop = false,
}

local settings = {
    loopDelay = 500,
    lootRadius = 200,
    lootRange = 15,
    combatWaitDelay = 1500,
    pendingDecisionTimeout = 30000,
    defaultUnknownItemAction = "Ignore",
    peerName = "",
    isMain = false,
    mainToonName = "",
    peerTriggerPaused = false,
    showLogWindow = false,
    rgMainTriggered = false,
    useRGChase = false,
}

local historyUI = {
    show = true,
    searchFilter = "",
    selectedLooter = "All",
    selectedZone = "All",
    selectedAction = "All",
    selectedTimeFrame = "All Time",
    customStartDate = os.date("%Y-%m-%d"),
    customEndDate = os.date("%Y-%m-%d"),
    startDate = "",
    endDate = "",
    currentPage = 1,
    itemsPerPage = 12,
    sortColumn = "timestamp",
    sortDirection = "DESC"
}

-- ============================================================================
-- ENGINE-UI INTEGRATION BRIDGE
-- ============================================================================

local function handleEnginePendingDecision()
    local engineState = SmartLootEngine.getState()
    
    -- Check if engine needs a pending decision and UI doesn't have one
    if engineState.needsPendingDecision and not lootUI.currentItem then
        local pendingDetails = engineState.pendingItemDetails

        lootUI.currentItem = {
            name = pendingDetails.itemName,
            index = engineState.currentItemIndex,
            numericCorpseID = engineState.currentCorpseID,
            decisionStartTime = mq.gettime(),
            itemID = pendingDetails.itemID,
            iconID = pendingDetails.iconID
        }
        
        logging.debug("[Bridge] Created UI pending decision for: " .. pendingDetails.itemName)
    end
end

local function processUIDecisionForEngine()
    local engineState = SmartLootEngine.getState()

    -- Check if UI has a pending loot action to send to engine
    if lootUI.pendingLootAction and engineState.needsPendingDecision then
        local action = lootUI.pendingLootAction
        local itemName = action.item.name
        local rule = action.rule
        
        SmartLootEngine.resolvePendingDecision(itemName, action.itemID, rule, action.iconID)
        lootUI.pendingLootAction = nil
        lootUI.currentItem = nil
        
        logging.debug("[Bridge] Resolved engine decision for: " .. itemName .. " with rule: " .. rule)
        return
    end
    
    -- Clear stale UI state if engine doesn't need a decision
    if not engineState.needsPendingDecision and lootUI.currentItem and not lootUI.pendingLootAction then
        logging.debug("[Bridge] Clearing stale UI pending decision state")
        lootUI.currentItem = nil
    end
end

-- ============================================================================
-- MAILBOX COMMAND INTEGRATION - UPDATED with RGMain flag handling
-- ============================================================================

local smartlootMailbox = actors.register("smartloot_mailbox", function(message)
    local raw = message()
    if not raw then return end

    local data, pos, err = json.decode(raw)
    if not data or type(data) ~= "table" then
        util.printSmartLoot("Invalid mailbox message: " .. tostring(err or raw), "error")
        return
    end

    local sender = data.sender or "Unknown"
    local cmd = data.cmd

    if cmd == "set_rgmain_flag" then
        local isRGMain = data.isRGMain or false
        util.printSmartLoot("RGMain flag received from " .. sender .. ": " .. tostring(isRGMain), "info")
        
        if isRGMain then
            -- Switch to RGMain mode and wait for triggers
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.RGMain, "RGMain flag from " .. sender)
            util.printSmartLoot("Character set to RGMain mode - waiting for RGMercs triggers", "success")
        else
            -- Switch to background mode for non-RGMain characters
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Non-RGMain flag from " .. sender)
            util.printSmartLoot("Character set to Background mode - autonomous looting", "success")
        end
        
    elseif cmd == "waterfall_session_start" or cmd == "waterfall_completion" or cmd == "waterfall_status_request" then
        waterfallTracker.handleMailboxMessage(data)
        return
        
    elseif cmd == "reload_rules" then
        util.printSmartLoot("Reload command received from " .. sender .. ". Refreshing rule cache.", "info")
        database.refreshLootRuleCache()
        -- Also clear peer rule caches since rules may have been updated by other characters
        database.clearPeerRuleCache()
        -- Refresh our own peer cache entry to ensure UI shows updated self-rules
        local currentToon = mq.TLO.Me.Name()
        if currentToon then
            database.refreshLootRuleCacheForPeer(currentToon)
        end
        
    elseif cmd == "rg_trigger" then
        util.printSmartLoot("RG trigger command received from " .. sender, "info")
        if SmartLootEngine.triggerRGMain() then
            util.printSmartLoot("RGMain triggered successfully", "success")
        else
            --util.printSmartLoot("RG trigger ignored - not in RGMain mode", "warning")
        end
        
    elseif cmd == "start_once" then
        util.printSmartLoot("Once mode trigger received from " .. sender, "info")
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "Mailbox command from " .. sender)
        
    elseif cmd == "start_rgonce" then
        util.printSmartLoot("RGOnce mode trigger received from " .. sender, "info")
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.RGOnce, "Mailbox command from " .. sender)
        
    elseif cmd == "rg_peer_trigger" then
        -- RGMain has triggered us to start looting
        util.printSmartLoot("RGMain peer trigger received from " .. sender, "info")
        local sessionId = data.sessionId
        SmartLootEngine.state.rgMainSessionId = sessionId
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "RGMain peer trigger from " .. sender)
        
    elseif cmd == "rg_peer_complete" then
        -- A peer is reporting completion to RGMain
        local sessionId = data.sessionId
        SmartLootEngine.reportRGMainCompletion(sender, sessionId)

    elseif message.cmd == "refresh_rules" then
        local database = require("modules.database")
        database.refreshLootRuleCache()
        logging.log("[SmartLoot] Reloaded local loot rule cache")
        
    elseif cmd == "emergency_stop" then
        SmartLootEngine.emergencyStop("Emergency stop from " .. sender)
        util.printSmartLoot("Emergency stop executed by " .. sender, "system")
        
    elseif cmd == "pause" then
        local action = data.action or "toggle"
        if action == "on" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Paused by " .. sender)
            util.printSmartLoot("Paused by " .. sender, "warning")
        elseif action == "off" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Resumed by " .. sender)
            util.printSmartLoot("Resumed by " .. sender, "success")
        else
            local currentMode = SmartLootEngine.getLootMode()
            if currentMode == SmartLootEngine.LootMode.Disabled then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Toggled by " .. sender)
                util.printSmartLoot("Resumed by " .. sender, "success")
            else
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Toggled by " .. sender)
                util.printSmartLoot("Paused by " .. sender, "warning")
            end
        end
        
    elseif cmd == "clear_cache" then
        util.printSmartLoot("Cache clear command received from " .. sender, "info")
        SmartLootEngine.resetProcessedCorpses()
        util.printSmartLoot("Corpse cache cleared", "system")
        
    elseif cmd == "status_request" then
        util.printSmartLoot("Status request from " .. sender, "info")
        
        local engineState = SmartLootEngine.getState()
        local statusData = {
            cmd = "status_response",
            sender = getCurrentToon(),
            target = sender,
            mode = engineState.mode,
            state = engineState.currentStateName,
            paused = engineState.mode == SmartLootEngine.LootMode.Disabled,
            pendingDecision = engineState.needsPendingDecision,
            corpseID = engineState.currentCorpseID
        }
        
        actors.send(sender .. "_smartloot_mailbox", json.encode(statusData))
        
    else
        util.printSmartLoot("Unknown command '" .. tostring(cmd) .. "' from " .. sender, "warning")
    end
end)

-- ============================================================================
-- TLO (Top Level Object)
-- ============================================================================

local smartLootType = mq.DataType.new('SmartLoot', {
    Members = {
        State = function(_, self)
            local state = SmartLootEngine.getState()
            
            if state.mode == SmartLootEngine.LootMode.Disabled then
                return 'string', "Disabled"
            elseif state.needsPendingDecision then
                return 'string', "Pending Decision"
            elseif state.waitingForLootAction then
                return 'string', "Processing Loot"
            elseif state.currentStateName == "CombatDetected" then
                return 'string', "Combat Detected"
            elseif state.currentStateName == "Idle" then
                return 'string', "Idle"
            else
                return 'string', state.currentStateName
            end
        end,

        Mode = function(_, self)
            return 'string', SmartLootEngine.getLootMode()
        end,
        
        EngineState = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', state.currentStateName
        end,
        
        Paused = function(_, self)
            local currentMode = SmartLootEngine.getLootMode()
            return 'bool', currentMode == SmartLootEngine.LootMode.Disabled
        end,
        
        PendingDecision = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', state.needsPendingDecision and "TRUE" or "FALSE"
        end,
        
        CorpseCount = function(_, self)
            local corpseCount = mq.TLO.SpawnCount(string.format("npccorpse radius %d", settings.lootRadius))() or 0
            return 'string', tostring(corpseCount)
        end,
        
        CurrentCorpse = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', tostring(state.currentCorpseID)
        end,
        
        ItemsProcessed = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', tostring(state.stats.itemsLooted + state.stats.itemsIgnored)
        end,
        
        Version = function(_, self)
            return 'string', "SmartLoot 2.0 State Engine"
        end,
        
        -- Processing state indicators
        IsProcessing = function(_, self)
            local state = SmartLootEngine.getState()
            local processingStates = {
                "ProcessingItems", "FindingCorpse", "NavigatingToCorpse", 
                "OpeningLootWindow", "CleaningUpCorpse"
            }
            for _, stateName in ipairs(processingStates) do
                if state.currentStateName == stateName then
                    return 'bool', true
                end
            end
            return 'bool', false
        end,
        
        IsIdle = function(_, self)
            local state = SmartLootEngine.getState()
            return 'bool', state.currentStateName == "Idle"
        end,
        
        -- Detailed statistics
        ItemsLooted = function(_, self)
            local state = SmartLootEngine.getState()
            return 'int', state.stats.itemsLooted or 0
        end,
        
        ItemsIgnored = function(_, self)
            local state = SmartLootEngine.getState()
            return 'int', state.stats.itemsIgnored or 0
        end,
        
        ProcessedCorpses = function(_, self)
            local state = SmartLootEngine.getState()
            return 'int', state.stats.corpsesProcessed or 0
        end,
        
        PeersTriggered = function(_, self)
            local state = SmartLootEngine.getState()
            return 'int', state.stats.peersTriggered or 0
        end,
        
        -- Safety state checks
        SafeToLoot = function(_, self)
            -- Check if it's safe to loot (no combat, etc.)
            local me = mq.TLO.Me
            if not me() then return 'bool', false end
            
            -- Not safe if in combat
            if me.Combat() then return 'bool', false end
            
            -- Not safe if casting
            if me.Casting() then return 'bool', false end
            
            -- Not safe if moving
            if me.Moving() then return 'bool', false end
            
            return 'bool', true
        end,
        
        InCombat = function(_, self)
            return 'bool', mq.TLO.Me.Combat() or false
        end,
        
        LootWindowOpen = function(_, self)
            return 'bool', mq.TLO.Corpse.Open() or false
        end,
        
        -- Time tracking
        LastAction = function(_, self)
            local state = SmartLootEngine.getState()
            -- Return seconds since last action (placeholder - needs engine support)
            return 'int', 0
        end,
        
        TimeInCurrentState = function(_, self)
            local state = SmartLootEngine.getState()
            -- Return seconds in current state (placeholder - needs engine support)
            return 'int', 0
        end,
        
        -- State information
        IsEnabled = function(_, self)
            local state = SmartLootEngine.getState()
            return 'bool', state.mode ~= SmartLootEngine.LootMode.Disabled
        end,
        
        NeedsDecision = function(_, self)
            local state = SmartLootEngine.getState()
            return 'bool', state.needsPendingDecision or false
        end,
        
        PendingItem = function(_, self)
            local state = SmartLootEngine.getState()
            if state.needsPendingDecision and state.pendingItemDetails then
                return 'string', state.pendingItemDetails.itemName or ""
            end
            return 'string', ""
        end,
        
        -- Error handling
        ErrorState = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', state.errorMessage or ""
        end,
        
        EmergencyStatus = function(_, self)
            local state = SmartLootEngine.getState()
            return 'string', string.format("State: %s, Mode: %s, Corpse: %s", 
                state.currentStateName, state.mode, tostring(state.currentCorpseID))
        end,
        
        -- Global order system
        GlobalOrder = function(_, self, index)
            local globalOrder = database.loadGlobalLootOrder()
            if index then
                local idx = tonumber(index)
                if idx and idx > 0 and idx <= #globalOrder then
                    return 'string', globalOrder[idx]
                end
            end
            return 'int', #globalOrder
        end,
        
        GlobalOrderList = function(_, self)
            local globalOrder = database.loadGlobalLootOrder()
            return 'string', table.concat(globalOrder, ",")
        end,
        
        GlobalOrderCount = function(_, self)
            local globalOrder = database.loadGlobalLootOrder()
            return 'int', #globalOrder
        end,
        
        IsMainLooter = function(_, self)
            local currentChar = mq.TLO.Me.Name()
            local globalOrder = database.loadGlobalLootOrder()
            return 'bool', globalOrder[1] == currentChar
        end,
        
        GlobalOrderPosition = function(_, self)
            local currentChar = mq.TLO.Me.Name()
            local globalOrder = database.loadGlobalLootOrder()
            for i, name in ipairs(globalOrder) do
                if name == currentChar then
                    return 'int', i
                end
            end
            return 'int', 0
        end,
        
        -- Corpse detection
        HasNewCorpses = function(_, self)
            local state = SmartLootEngine.getState()
            local processedCorpses = state.processedCorpses or {}
            
            -- Check for unprocessed NPC corpses
            local corpseCount = mq.TLO.SpawnCount(string.format("npccorpse radius %d", settings.lootRadius))()
            if corpseCount and corpseCount > 0 then
                for i = 1, corpseCount do
                    local corpse = mq.TLO.NearestSpawn(i, string.format("npccorpse radius %d", settings.lootRadius))
                    if corpse and corpse.ID() and not processedCorpses[corpse.ID()] then
                        return 'bool', true
                    end
                end
            end
            return 'bool', false
        end,
        
        -- Control/interrupt states
        CanSafelyInterrupt = function(_, self)
            local state = SmartLootEngine.getState()
            -- Can interrupt if idle or between actions
            local safeStates = {"Idle", "WaitingForCorpses", "CheckingCorpses"}
            for _, stateName in ipairs(safeStates) do
                if state.currentStateName == stateName then
                    return 'bool', true
                end
            end
            return 'bool', false
        end,
    },
    
    Methods = {
        TriggerRGMain = function(_, self)
            if SmartLootEngine.triggerRGMain() then
                logging.log("RGMain triggered via TLO")
                return 'string', "TRUE"
            else
                logging.log("TLO trigger ignored - not in RGMain mode")
                return 'string', "FALSE"
            end
        end,
        
        EmergencyStop = function(_, self)
            SmartLootEngine.emergencyStop("TLO call")
            logging.log("EMERGENCY STOP via TLO")
            return 'string', "Emergency Stop Executed"
        end,

        SetMode = function(_, self, newMode)
            local modeMapping = {
                ["main"] = SmartLootEngine.LootMode.Main,
                ["once"] = SmartLootEngine.LootMode.Once,
                ["background"] = SmartLootEngine.LootMode.Background,
                ["rgmain"] = SmartLootEngine.LootMode.RGMain,
                ["disabled"] = SmartLootEngine.LootMode.Disabled
            }
            
            local engineMode = modeMapping[newMode:lower()]
            if engineMode then
                SmartLootEngine.setLootMode(engineMode, "TLO call")
                return 'string', "Mode set to " .. engineMode
            else
                return 'string', "Invalid mode: " .. newMode
            end
        end,

        ResetCorpses = function(_, self)
            SmartLootEngine.resetProcessedCorpses()
            return 'string', "Corpse cache reset"
        end,

        GetPerformance = function(_, self)
            local perf = SmartLootEngine.getPerformanceMetrics()
            return 'string', string.format("Avg Tick: %.2fms, CPM: %.1f, IPM: %.1f", 
                   perf.averageTickTime, perf.corpsesPerMinute, perf.itemsPerMinute)
        end,
        
        -- Command handling (matches C++ TLO)
        Command = function(_, self, command)
            if not command then
                return 'string', "Available commands: once, main, background, stop, emergency, quickstop, clear"
            end
            
            local cmd = command:lower()
            local result = "Unknown command"
            
            if cmd == "once" then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "TLO Command")
                result = "Once mode started"
            elseif cmd == "main" then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Main, "TLO Command")
                result = "Main mode started"
            elseif cmd == "background" then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "TLO Command")
                result = "Background mode started"
            elseif cmd == "stop" or cmd == "disable" then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "TLO Command")
                result = "SmartLoot disabled"
            elseif cmd == "emergency" then
                SmartLootEngine.emergencyStop("TLO Command")
                result = "Emergency stop executed"
            elseif cmd == "quickstop" then
                SmartLootEngine.quickStop("TLO Command")
                result = "Quick stop executed"
            elseif cmd == "clear" or cmd == "reset" then
                SmartLootEngine.resetProcessedCorpses()
                result = "Cache cleared"
            end
            
            return 'string', result
        end,
        
        -- Emergency stop (matches C++ TLO)
        Stop = function(_, self)
            SmartLootEngine.emergencyStop("TLO Stop")
            return 'bool', true
        end,
        
        -- Quick stop (matches C++ TLO)
        QuickStop = function(_, self)
            SmartLootEngine.quickStop("TLO QuickStop")
            return 'bool', true
        end,
    },
    
    ToString = function(self)
        local state = SmartLootEngine.getState()
        
        if state.mode == SmartLootEngine.LootMode.Disabled then
            return "Paused"
        elseif state.needsPendingDecision then
            return "Pending Decision"
        elseif state.waitingForLootAction then
            return "Processing Loot"
        elseif state.currentStateName == "CombatDetected" then
            return "Combat"
        else
            return "Running (" .. state.mode .. ")"
        end
    end,
})

local function SmartLootTLOHandler(param)
    return smartLootType, {}
end

mq.AddTopLevelObject('SmartLoot', SmartLootTLOHandler)

logging.log("[SmartLoot] TLO registered: ${SmartLoot.Status}")

-- ============================================================================
-- UI MODULE LOADING
-- ============================================================================

local uiModules = {}
local function safeRequire(moduleName, friendlyName)
    local success, module = pcall(require, moduleName)
    if success then
        uiModules[friendlyName] = module
        logging.log("[SmartLoot] Loaded UI module: " .. friendlyName)
        return module
    else
        logging.log("[SmartLoot] Failed to load UI module " .. friendlyName .. ": " .. tostring(module))
        return nil
    end
end

local uiLootRules = safeRequire("ui.ui_loot_rules", "LootRules")
local uiPopups = safeRequire("ui.ui_popups", "Popups")
local uiHotbar = safeRequire("ui.ui_hotbar", "Hotbar")
local uiFloatingButton = safeRequire("ui.ui_floating_button", "FloatingButton")
local uiLootHistory = safeRequire("ui.ui_loot_history", "LootHistory")
local uiLootStatistics = safeRequire("ui.ui_loot_statistics", "LootStatistics")
local uiPeerLootOrder = safeRequire("ui.ui_peer_loot_order", "PeerLootOrder")
local uiPeerCommands = safeRequire("ui.ui_peer_commands", "PeerCommands")
local uiSettings = safeRequire("ui.ui_settings", "Settings")
local uiDebugWindow = safeRequire("ui.ui_debug_window", "DebugWindow")
local uiLiveStats = safeRequire("ui.ui_live_stats", "LiveStats")
local uiHelp = safeRequire("ui.ui_help", "Help")
local uiTempRules = safeRequire("ui.ui_temp_rules", "TempRules")

-- Configure engine UI integration
if dbInitialized then
    SmartLootEngine.setLootUIReference(lootUI, settings)
    logging.log("[SmartLoot] Engine UI integration configured")
end

-- ============================================================================
-- COMMAND BINDINGS INITIALIZATION - MOVED TO BINDINGS MODULE
-- ============================================================================

-- Initialize the bindings module with all required references
bindings.initialize(
    SmartLootEngine,
    lootUI,
    modeHandler,
    waterfallTracker,
    uiLiveStats,
    uiHelp
)

-- ============================================================================
-- IMGUI INTERFACE
-- ============================================================================

mq.imgui.init("SmartLoot", function()
    -- Main UI Window
    if lootUI.showUI then
        ImGui.SetNextWindowBgAlpha(0.75)
        ImGui.SetNextWindowSize(800, 600, ImGuiCond.FirstUseEver)
        
        local windowFlags = bit32.bor(ImGuiWindowFlags.None)
        
        local open, shouldClose = ImGui.Begin("SmartLoot - Loot Smarter, Not Harder", true, windowFlags)
        if open then
            if ImGui.BeginTabBar("MainTabBar") then
                if uiLootRules then
                    uiLootRules.draw(lootUI, database, settings, util, uiPopups)
                end
                if uiTempRules then
                    uiTempRules.draw(lootUI, database, settings, util)
                end
                if uiSettings then
                    uiSettings.draw(lootUI, settings, config)
                end
                if uiLootHistory then
                    uiLootHistory.draw(historyUI, lootHistory)
                end
                if uiLootStatistics then
                    uiLootStatistics.draw(lootUI, lootStats)
                end
                if uiPeerLootOrder then
                    uiPeerLootOrder.draw(lootUI, config, util)
                end
                
                --[[Engine Stats Tab
                if ImGui.BeginTabItem("Engine Stats") then
                    local state = SmartLootEngine.getState()
                    local perf = SmartLootEngine.getPerformanceMetrics()
                    
                    ImGui.Text("Performance Metrics:")
                    ImGui.Indent()
                    ImGui.Text("Average Tick Time: " .. string.format("%.2fms", perf.averageTickTime))
                    ImGui.Text("Last Tick Time: " .. string.format("%.2fms", perf.lastTickTime))
                    ImGui.Text("Total Ticks: " .. perf.tickCount)
                    ImGui.Text("Corpses/Minute: " .. string.format("%.1f", perf.corpsesPerMinute))
                    ImGui.Text("Items/Minute: " .. string.format("%.1f", perf.itemsPerMinute))
                    ImGui.Unindent()
                    
                    ImGui.Separator()
                    
                    ImGui.Text("Session Statistics:")
                    ImGui.Indent()
                    ImGui.Text("Corpses Processed: " .. state.stats.corpsesProcessed)
                    ImGui.Text("Items Looted: " .. state.stats.itemsLooted)
                    ImGui.Text("Items Ignored: " .. state.stats.itemsIgnored)
                    ImGui.Text("Items Destroyed: " .. state.stats.itemsDestroyed)
                    ImGui.Text("Peers Triggered: " .. state.stats.peersTriggered)
                    ImGui.Text("Decisions Required: " .. state.stats.decisionsRequired)
                    ImGui.Text("Emergency Stops: " .. state.stats.emergencyStops)
                    ImGui.Unindent()
                    
                    ImGui.Separator()
                    
                    if ImGui.Button("Reset Processed Corpses") then
                        SmartLootEngine.resetProcessedCorpses()
                    end
                    ImGui.SameLine()
                    if ImGui.Button("Emergency Stop") then
                        SmartLootEngine.emergencyStop("UI Button")
                    end
                    ImGui.SameLine()
                    if ImGui.Button("Resume") then
                        SmartLootEngine.resume()
                    end
                    
                    ImGui.Separator()
                    
                    if ImGui.Button("Open Debug Window") then
                        lootUI.showDebugWindow = true
                        lootUI.forceDebugWindowVisible = true
                    end
                    
                    ImGui.Separator()
                    
                    if ImGui.Button("Open Live Stats") then
                        if uiLiveStats then
                            uiLiveStats.setVisible(true)
                        end
                    end
                    ImGui.SameLine()
                    if ImGui.Button("Toggle Live Stats") then
                        if uiLiveStats then
                            uiLiveStats.toggle()
                        end
                    end
                    
                    ImGui.Separator()
                    
                    -- NEW: Add bindings information to Engine Stats tab
                    ImGui.Text("Command Bindings:")
                    if ImGui.Button("List All Commands") then
                        bindings.listBindings()
                    end
                    ImGui.SameLine()
                    if ImGui.Button("Show Help") then
                        if uiHelp then
                            uiHelp.show()
                        else
                            mq.cmd("/sl_help")
                        end
                    end
                    
                    ImGui.EndTabItem()
                end]]
                
                ImGui.EndTabBar()
            end
        end
        ImGui.End()
        
        if not open and lootUI.showUI then
            lootUI.showUI = false
        end
    end

    -- UI Components
    if lootUI.useFloatingButton then
        if uiFloatingButton and uiFloatingButton.draw then
            uiFloatingButton.draw(lootUI, settings, function() 
                lootUI.showUI = not lootUI.showUI 
                if lootUI.showUI then
                    lootUI.forceWindowVisible = true
                    lootUI.forceWindowUncollapsed = true
                end
            end, nil, util, SmartLootEngine)
        end
    end

    if uiHotbar and uiHotbar.draw then
        uiHotbar.draw(lootUI, settings, function() 
            lootUI.showUI = not lootUI.showUI
            if lootUI.showUI then
                lootUI.forceWindowVisible = true
                lootUI.forceWindowUncollapsed = true
            end
        end, nil, util)
    end

    -- Always show popups
    if uiPopups then
        uiPopups.drawLootDecisionPopup(lootUI, settings, nil)
        uiPopups.drawLootStatsPopup(lootUI, lootStats)
        uiPopups.drawLootRulesPopup(lootUI, database, util)
        uiPopups.drawPeerItemRulesPopup(lootUI, database, util)
        uiPopups.drawUpdateIDsPopup(lootUI, database, util)
        uiPopups.drawAddNewRulePopup(lootUI, database, util)
        uiPopups.drawIconUpdatePopup(lootUI, database, lootStats, lootHistory)
        uiPopups.drawThresholdPopup(lootUI, database)
        uiPopups.drawGettingStartedPopup(lootUI)
        uiPopups.drawDuplicateCleanupPopup(lootUI, database)
        uiPopups.drawLegacyImportPopup(lootUI, database, util)
        uiPopups.drawLegacyImportConfirmationPopup(lootUI, database, util)
    end
    
    if lootUI.showPeerCommands and uiPeerCommands then
        uiPeerCommands.draw(lootUI, nil, util)
    end
    
    -- Log window UI not implemented yet
    -- if uiLogWindow then
    --     uiLogWindow.draw(settings, logging)
    -- end
    
    -- Live stats window
    if uiLiveStats then
        local liveStatsConfig = {
            getConnectedPeers = function() 
                return util.getConnectedPeers() 
            end,
            isDatabaseConnected = function()
                return dbInitialized
            end,
            farmingMode = {
                isActive = function(charName)
                    -- TODO: Implement farming mode detection
                    return false
                end,
                toggle = function(charName)
                    -- TODO: Implement farming mode toggle
                    logging.log("[LiveStats] Farming mode toggle not yet implemented for " .. charName)
                end
            }
        }
        uiLiveStats.draw(SmartLootEngine, liveStatsConfig)
    end
    
    -- Debug window
    if lootUI.showDebugWindow and uiDebugWindow then
        uiDebugWindow.draw(SmartLootEngine, lootUI)
    end
    
    -- Help window
    if uiHelp then
        uiHelp.render()
    end
end)

-- ============================================================================
-- ZONE CHANGE DETECTION
-- ============================================================================

local currentZone = mq.TLO.Zone.ID()
local function checkForZoneChange()
    local newZone = mq.TLO.Zone.ID()
    if newZone ~= currentZone then
        logging.log("Zone change detected: resetting corpse tracking")
        SmartLootEngine.resetProcessedCorpses()
        currentZone = newZone
    end
end

-- ============================================================================
-- STARTUP COMPLETE
-- ============================================================================

-- Add live stats configuration to the main settings 
local liveStatsSettings = {
    show = true,
    compactMode = false,
    alpha = 0.85,
    position = { x = 200, y = 200 }
}

-- Load live stats settings from config if available
if config and config.liveStats then
    for key, value in pairs(config.liveStats) do
        if liveStatsSettings[key] ~= nil then
            liveStatsSettings[key] = value
        end
    end
end

-- Apply settings to live stats window
if uiLiveStats then
    uiLiveStats.setConfig(liveStatsSettings)
end

logging.log("[SmartLoot] State Engine initialization completed successfully in " .. runMode .. " mode")
logging.log("[SmartLoot] UI Mode: " .. (lootUI.useFloatingButton and "Floating Button" or "Hotbar"))
logging.log("[SmartLoot] Database: SQLite")

-- Welcome message for new users
util.printSmartLoot("SmartLoot initialized! First time? Run: /sl_getstarted", "info")
if dbInitialized then
    SmartLootEngine.config.pendingDecisionTimeoutMs = settings.pendingDecisionTimeout
    SmartLootEngine.config.defaultUnknownItemAction = settings.defaultUnknownItemAction
    logging.log("[SmartLoot] Pending decision timeout set to: " .. (settings.pendingDecisionTimeout / 1000) .. " seconds")
    
    -- Sync timing settings from persistent config to engine
    config.syncTimingToEngine()
    logging.log("[SmartLoot] Timing settings loaded from persistent config")
end
if uiLiveStats then
    logging.log("[SmartLoot] Live Stats Window: Available")
end

-- ============================================================================
-- MAIN LOOP - PURE STATE ENGINE
-- ============================================================================

local function processMainTick()
    -- CORE ENGINE PROCESSING - This drives everything
    SmartLootEngine.processTick()
    
    -- BRIDGE: Handle engine -> UI communication
    handleEnginePendingDecision()
    
    -- BRIDGE: Handle UI -> engine communication  
    processUIDecisionForEngine()
    
    -- PEER MONITORING: Check for peer connection changes and auto-adjust mode
    modeHandler.checkPeerChanges()
    
    -- Zone change detection
    checkForZoneChange()
end

-- Main loop - simplified to just run the state engine
local mainTimer = mq.gettime()
while true do
    mq.doevents()
    
    local now = mq.gettime()
    if now >= mainTimer then
        processMainTick()
        mainTimer = now + 50  -- Process every 50ms
    end
    
    mq.delay(10)  -- Small delay to prevent 100% CPU usage
end