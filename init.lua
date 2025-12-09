-- init.lua - PURE STATE MACHINE VERSION with Bindings Module
local mq               = require("mq")
local PackageMan       = require('mq.PackageMan')
local sqlite3          = PackageMan.Require("lsqlite3")
local database         = require("modules.database")
local ImGui            = require("ImGui")
local logging          = require("modules.logging")
local lootHistory      = require("modules.loot_history")
local lootStats        = require("modules.loot_stats")
local json             = require("dkjson")
local config           = require("modules.config")
local util             = require("modules.util")
local Icons            = require("mq.Icons")
local actors           = require("actors")
local modeHandler      = require("modules.mode_handler")
local SmartLootEngine  = require("modules.SmartLootEngine")
local waterfallTracker = require("modules.waterfall_chain_tracker")
local bindings         = require("modules.bindings")

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local dbInitialized    = false
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

local args = { ... }

mq.delay(150)

initializeDatabase()
local engineInitialized, runMode = initializeSmartLootEngine(args)

if not engineInitialized then
    runMode = "main"
    logging.log("[SmartLoot] Engine initialization failed, defaulting to main mode")
end

if runMode ~= "main" and runMode ~= "once" and runMode ~= "background" and
    runMode ~= "rgmain" and runMode ~= "rgonce" then
    util.printSmartLoot(
        'Invalid run mode: ' .. runMode .. '. Valid options are "main", "once", "background", "rgmain", or "rgonce"',
        "error")
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
    showHotbar = config.uiVisibility.showHotbar,
    showUI = config.uiVisibility.showUI,
    showDebugWindow = config.uiVisibility.showDebugWindow, -- Add debug window flag
    windowLocked = false,                                  -- Lock window feature
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

    bulkCopyRulesPopup = {
        isOpen = false,
        sourceCharacter = "",
        targetCharacter = "",
        previewRules = nil,
        allCharacters = {},
        copying = false,
        copyResult = ""
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
    showPeerCommands = config.uiVisibility.showPeerCommands,
    peerCommandsOpen = config.uiVisibility.showPeerCommands,
    showSettingsTab = false,
    emergencyStop = false,

    -- Session Report Popup state
    sessionReportPopup = {
        isOpen = false,
        scope = "all", -- all|me
        limit = 20,
        rows = nil,
        needsFetch = false,
    },

    -- Whitelist manager popup state
    whitelistManagerPopup = {
        isOpen = false,
        filter = "",
        addItemName = "",
        addRuleType = "Keep",
        addThreshold = 1,
        lastRefresh = 0,
        entries = nil,
    },
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
    peerSelectionStrategy = (config.getPeerSelectionStrategy and config.getPeerSelectionStrategy())
        or config.peerSelectionStrategy or SmartLootEngine.config.peerSelectionStrategy or "items_first",
}

-- Sync settings from loaded config
settings.lootRadius = config.lootRadius or settings.lootRadius
settings.lootRange = config.lootRange or settings.lootRange
settings.combatWaitDelay = config.engineTiming and config.engineTiming.combatWaitDelayMs or settings.combatWaitDelay
settings.pendingDecisionTimeout = config.engineTiming and config.engineTiming.pendingDecisionTimeoutMs or
settings.pendingDecisionTimeout

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
        local skipRuleSave = action.skipRuleSave or false

        SmartLootEngine.resolvePendingDecision(itemName, action.itemID, rule, action.iconID, skipRuleSave)
        lootUI.pendingLootAction = nil
        lootUI.currentItem = nil

        logging.debug(string.format("[Bridge] Resolved engine decision for: %s with rule: %s (skipSave: %s)", 
            itemName, rule, tostring(skipRuleSave)))
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
    elseif cmd == "directed_tasks" then
        local tasks = data.tasks or {}
        if type(tasks) == "table" and SmartLootEngine.enqueueDirectedTasks then
            SmartLootEngine.enqueueDirectedTasks(tasks)
            util.printSmartLoot(string.format("Received %d directed tasks from %s", #tasks, sender), "info")
        end
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
    elseif cmd == "directed_assign_open" then
        SmartLootEngine.setDirectedAssignmentVisible(true)
        util.printSmartLoot("Directed Assignment UI opened by " .. sender, "info")
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
            paused = engineState.paused,
            pendingDecision = engineState.needsPendingDecision,
            corpseID = engineState.currentCorpseID
        }

        actors.send(sender .. "_smartloot_mailbox", json.encode(statusData))
    elseif cmd == "pending_decision_request" then
        -- Another character is requesting we make a decision for their item
        -- Store in global remote pending decisions queue
        _G.SMARTLOOT_REMOTE_DECISIONS = _G.SMARTLOOT_REMOTE_DECISIONS or {}

        table.insert(_G.SMARTLOOT_REMOTE_DECISIONS, {
            requester = sender,
            itemName = data.itemName,
            itemID = data.itemID or 0,
            iconID = data.iconID or 0,
            quantity = data.quantity or 1,
            timestamp = mq.gettime()
        })

        logging.debug(string.format("[SmartLoot] Added remote pending decision from %s for item: %s (queue size: %d)",
            sender, data.itemName, #_G.SMARTLOOT_REMOTE_DECISIONS))
    elseif cmd == "pending_decision_response" then
        -- Foreground character responded with a decision
        local itemName = data.itemName
        local itemID = data.itemID or 0
        local iconID = data.iconID or 0
        local rule = data.rule

        if rule and itemName then
            -- Only resolve if this character is currently waiting for a decision on this exact item
            local engineState = SmartLootEngine.getState()
            if engineState.needsPendingDecision and 
               engineState.pendingItemDetails.itemName == itemName and
               (engineState.pendingItemDetails.itemID or 0) == itemID then
                -- Apply the rule and resolve the pending decision
                SmartLootEngine.resolvePendingDecision(itemName, itemID, rule, iconID)
                logging.debug(string.format("[SmartLoot] Applied remote decision from %s: %s = %s", sender, itemName, rule))
            else
                logging.debug(string.format("[SmartLoot] Received decision from %s for %s but not currently pending on this character", sender, itemName))
            end
        end
    elseif cmd == "clear_remote_decision" then
        -- A decision was resolved by foreground - clear it from our queue
        local requester = data.requester
        local itemName = data.itemName
        local itemID = data.itemID or 0
        
        _G.SMARTLOOT_REMOTE_DECISIONS = _G.SMARTLOOT_REMOTE_DECISIONS or {}
        
        -- Remove matching decisions from the queue
        local newQueue = {}
        local removedCount = 0
        for _, decision in ipairs(_G.SMARTLOOT_REMOTE_DECISIONS) do
            -- Keep decisions that don't match
            if not (decision.requester == requester and decision.itemName == itemName and (decision.itemID or 0) == itemID) then
                table.insert(newQueue, decision)
            else
                removedCount = removedCount + 1
            end
        end
        
        _G.SMARTLOOT_REMOTE_DECISIONS = newQueue
        
        if removedCount > 0 then
            logging.debug(string.format("[SmartLoot] Cleared %d resolved remote decision(s) for '%s' from %s", 
                removedCount, itemName, requester))
        end
    else
        util.printSmartLoot("Unknown command '" .. tostring(cmd) .. "' from " .. sender, "warning")
    end
end)

-- ============================================================================
-- COMMAND MAILBOX (EZInventory-style targeted commands)
-- ============================================================================

local smartlootCommandMailbox = actors.register("smartloot_command", function(message)
    local content = message()
    if type(content) ~= "table" then return end
    if content.type ~= "command" then return end

    local myName = mq.TLO.Me.Name()
    local target = content.target

    -- If there's a target specified and it's not me, ignore the message
    -- If target is nil, it's a broadcast to everyone
    if target and myName and target ~= myName then
        -- Not for me
        return
    end

    local cmd = content.command or ""
    local args = content.args or {}

    if cmd == "reload_rules" then
        database.refreshLootRuleCache()
        database.clearPeerRuleCache()
        local currentToon = mq.TLO.Me.Name()
        if currentToon then
            database.refreshLootRuleCacheForPeer(currentToon)
        end
        util.printSmartLoot("Rules reloaded via command mailbox", "info")
    elseif cmd == "start_once" then
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "Command mailbox")
        util.printSmartLoot("Starting Once via command mailbox", "info")
    elseif cmd == "start_rgonce" then
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.RGOnce, "Command mailbox")
        util.printSmartLoot("Starting RGOnce via command mailbox", "info")
    elseif cmd == "pause" then
        local action = args.action or "toggle"
        if action == "on" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Paused by command")
            util.printSmartLoot("Paused via command mailbox", "warning")
        elseif action == "off" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Resumed by command")
            util.printSmartLoot("Resumed via command mailbox", "success")
        else
            local currentMode = SmartLootEngine.getLootMode()
            if currentMode == SmartLootEngine.LootMode.Disabled then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Toggled by command")
                util.printSmartLoot("Resumed via command mailbox", "success")
            else
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Toggled by command")
                util.printSmartLoot("Paused via command mailbox", "warning")
            end
        end
    elseif cmd == "directed_tasks" then
        local tasks = args.tasks or {}
        if type(tasks) == "table" and SmartLootEngine.enqueueDirectedTasks then
            SmartLootEngine.enqueueDirectedTasks(tasks)
            util.printSmartLoot(string.format("Enqueued %d directed tasks via command mailbox", #tasks), "info")
        end
    elseif cmd == "directed_assign_open" then
        if SmartLootEngine and SmartLootEngine.setDirectedAssignmentVisible then
            SmartLootEngine.setDirectedAssignmentVisible(true)
            util.printSmartLoot("Directed Assignment UI opened via command mailbox", "info")
        end
    elseif cmd == "clear_cache" then
        SmartLootEngine.resetProcessedCorpses()
        util.printSmartLoot("Corpse cache cleared via command mailbox", "system")
    elseif cmd == "emergency_stop" then
        SmartLootEngine.emergencyStop("Emergency stop via command mailbox")
        util.printSmartLoot("Emergency stop executed via command mailbox", "system")
    end
end)

if smartlootCommandMailbox then
    logging.log("[SmartLoot] Command mailbox registered: smartloot_command")
else
    logging.log("[SmartLoot] smartloot_command mailbox already in use or failed to register")
end

-- ============================================================================
-- STATE BROADCASTING MAILBOX (For RGMercs and other consumers)
-- ============================================================================

-- State broadcast system for external consumers (e.g., RGMercs)
local STATE_BROADCAST = {
    mailbox_name = "smartloot_state",
    actor = nil,
    lastStateBroadcast = 0,
    broadcastInterval = 2, -- seconds - reduced frequency to avoid spam
}

-- State broadcast handler (consumers can listen to this mailbox)
local function handleStateRequestMessage(message)
    local msg = message()
    if type(msg) ~= "table" then return end
    
    local cmd = msg.cmd or ""
    local sender = msg.sender or msg.character or "Unknown"
    
    if cmd == "state_request" then
        -- Send current state directly back to requester
        logging.debug(string.format("[SmartLoot] State request from %s, sending response", sender))
        
        -- Send to requester's specific mailbox if they provided one
        local replyTo = msg.replyTo or msg.mailbox
        if replyTo then
            -- Send to specific mailbox
            sendStateToMailbox(replyTo, sender)
        else
            -- Broadcast state update
            broadcastEngineState(nil)
        end
    elseif cmd == "subscribe" then
        -- Future: track subscribers for targeted updates
        logging.debug(string.format("[SmartLoot] %s subscribed to state updates", sender))
    elseif cmd == "unsubscribe" then
        -- Future: remove from subscriber list
        logging.debug(string.format("[SmartLoot] %s unsubscribed from state updates", sender))
    end
end

-- Forward declarations
local broadcastEngineState
local sendStateToMailbox

-- Periodic state broadcast ticker
local function publishStateBroadcastTick()
    local now = os.time()
    
    -- Only broadcast at configured interval
    if (now - (STATE_BROADCAST.lastStateBroadcast or 0) < STATE_BROADCAST.broadcastInterval) then
        return
    end
    
    -- Broadcast current state
    broadcastEngineState(nil) -- nil = broadcast to all
    STATE_BROADCAST.lastStateBroadcast = now
end

-- ============================================================================
-- LOOT STATUS PRESENCE (Mailbox-based actor presence system)
-- ============================================================================

-- Make LOOT_STATUS globally accessible for peer discovery
_G.SMARTLOOT_PRESENCE = {
    mailbox_name = "smartloot_loot_status",
    actor = nil,
    peers = {},            -- [peerName] = { isLooting=bool, lastSeen=os.time(), mode="once|rgonce" }
    lastHeartbeatSent = 0,
    heartbeatInterval = 5, -- seconds
    staleAfter = 12,       -- seconds (2x heartbeat)
    lastPrune = 0,
}

local LOOT_STATUS = _G.SMARTLOOT_PRESENCE

local function _safeLower(s)
    if type(s) ~= "string" then return "" end
    return s:lower()
end

local function handleLootStatusMessage(message)
    local msg = message()
    if type(msg) ~= "table" then return end

    local sender = msg.character or msg.sender or "Unknown"
    local myName = mq.TLO.Me.Name()
    if sender and myName and _safeLower(sender) == _safeLower(myName) then
        -- Ignore our own broadcast
        return
    end

    local now = os.time()
    local cmd = msg.cmd or ""
    local mode = msg.mode or ""
    local entry = LOOT_STATUS.peers[sender] or {}

    if cmd == "looting_start" or cmd == "looting_heartbeat" or cmd == "presence_heartbeat" then
        entry.isLooting = (mode == "once" or mode == "rgonce")
        entry.mode = mode
        entry.lastSeen = now
        LOOT_STATUS.peers[sender] = entry
    elseif cmd == "looting_stop" then
        entry.isLooting = false
        entry.mode = mode
        entry.lastSeen = now
        LOOT_STATUS.peers[sender] = entry
    end
end

-- Register mailbox to receive peer looting presence
local ok_mailbox
ok_mailbox, LOOT_STATUS.actor = pcall(function()
    return actors.register(LOOT_STATUS.mailbox_name, handleLootStatusMessage)
end)
if not ok_mailbox or not LOOT_STATUS.actor then
    logging.log(string.format("[SmartLoot] Failed to register mailbox %s (presence tracker)", LOOT_STATUS.mailbox_name))
else
    logging.log(string.format("[SmartLoot] Presence mailbox registered: %s", LOOT_STATUS.mailbox_name))
end

-- Mode transition + heartbeat publisher
local _lastPublishedMode = nil
local function publishLootStatusTick()
    local mode = SmartLootEngine.getLootMode()
    local myName = mq.TLO.Me.Name()
    local now = os.time()

    local inActive = (mode == SmartLootEngine.LootMode.Once or mode == SmartLootEngine.LootMode.RGOnce)
    local lastWasActive = (_lastPublishedMode == "once" or _lastPublishedMode == "rgonce")

    local function _send(msg)
        -- Prefer actor handle if registered, fall back to global send
        if LOOT_STATUS.actor then
            LOOT_STATUS.actor:send({ mailbox = LOOT_STATUS.mailbox_name }, msg)
        else
            actors.send({ mailbox = LOOT_STATUS.mailbox_name }, msg)
        end
    end

    -- Entering once/rgonce: announce start immediately
    if inActive and not lastWasActive then
        _send({
            cmd = "looting_start",
            character = myName,
            mode = mode,
            timestamp = now,
        })
        LOOT_STATUS.lastHeartbeatSent = 0 -- force heartbeat soon after
    end

    -- ALWAYS send heartbeat for presence detection (not just when actively looting)
    if (now - (LOOT_STATUS.lastHeartbeatSent or 0) >= LOOT_STATUS.heartbeatInterval) then
        _send({
            cmd = inActive and "looting_heartbeat" or "presence_heartbeat",
            character = myName,
            mode = mode,
            timestamp = now,
        })
        LOOT_STATUS.lastHeartbeatSent = now
    end

    -- Exiting once/rgonce: announce stop
    if (not inActive) and lastWasActive then
        _send({
            cmd = "looting_stop",
            character = myName,
            mode = _lastPublishedMode,
            timestamp = now,
        })
    end

    _lastPublishedMode = mode
end

-- Prune stale peer entries
local function pruneStalePeerLootStatus()
    local now = os.time()
    if now - (LOOT_STATUS.lastPrune or 0) < 3 then return end
    LOOT_STATUS.lastPrune = now

    for name, entry in pairs(LOOT_STATUS.peers) do
        local last = entry.lastSeen or 0
        if (now - last) > LOOT_STATUS.staleAfter then
            LOOT_STATUS.peers[name] = nil
        end
    end
end

-- Broadcast current engine state (defined after LOOT_STATUS)
broadcastEngineState = function(targetPeer)
    local state = SmartLootEngine.getState()
    local center = SmartLootEngine.getEffectiveCenter()
    local query = string.format("npccorpse radius %d loc %.1f %.1f %.1f", 
        settings.lootRadius, center.x, center.y, center.z)
    local corpseCount = mq.TLO.SpawnCount(query)() or 0
    
    -- Check for new unprocessed corpses
    local hasNewCorpses = false
    if corpseCount > 0 then
        for i = 1, corpseCount do
            local corpse = mq.TLO.NearestSpawn(i, query)
            if corpse and corpse.ID() then
                local corpseID = corpse.ID()
                if not SmartLootEngine.isCorpseProcessed(corpseID) then
                    hasNewCorpses = true
                    break
                end
            end
        end
    end
    
    -- Check if any peer is actively looting
    local anyPeerLooting = false
    local me = mq.TLO.Me.Name()
    local now = os.time()
    if LOOT_STATUS and LOOT_STATUS.peers then
        for name, entry in pairs(LOOT_STATUS.peers) do
            if not me or _safeLower(name) ~= _safeLower(me) then
                if entry.isLooting and entry.lastSeen and 
                   (now - entry.lastSeen) <= (LOOT_STATUS.staleAfter or 12) then
                    anyPeerLooting = true
                    break
                end
            end
        end
    end
    
    -- Compute SafeToLoot
    local safeToLoot = true
    if mq.TLO.Me() then
        if mq.TLO.Me.Combat() or mq.TLO.Me.Casting() or mq.TLO.Me.Moving() then
            safeToLoot = false
        end
    else
        safeToLoot = false
    end
    
    local stateData = {
        cmd = "state_update",
        sender = mq.TLO.Me.Name(),
        timestamp = os.time(),
        
        -- Core engine state matching TLO methods
        hasNewCorpses = hasNewCorpses,
        anyPeerLooting = anyPeerLooting,
        safeToLoot = safeToLoot,
        
        -- Additional useful state information
        mode = state.mode,
        engineState = state.currentStateName,
        isProcessing = state.currentStateName == "ProcessingItems" or 
                      state.currentStateName == "FindingCorpse" or
                      state.currentStateName == "NavigatingToCorpse" or
                      state.currentStateName == "OpeningLootWindow" or
                      state.currentStateName == "CleaningUpCorpse",
        isIdle = state.currentStateName == "Idle",
        corpseCount = corpseCount,
        needsPendingDecision = state.needsPendingDecision or false,
        inCombat = mq.TLO.Me.Combat() or false,
    }
    
    -- Send to specific peer or broadcast to all
    local destination = targetPeer and { to = targetPeer } or { mailbox = STATE_BROADCAST.mailbox_name }
    
    if STATE_BROADCAST.actor then
        STATE_BROADCAST.actor:send(destination, stateData)
    else
        actors.send(destination, stateData)
    end
end

-- Register state broadcast mailbox
local ok_state_mailbox
ok_state_mailbox, STATE_BROADCAST.actor = pcall(function()
    return actors.register(STATE_BROADCAST.mailbox_name, handleStateRequestMessage)
end)

if not ok_state_mailbox or not STATE_BROADCAST.actor then
    logging.log(string.format("[SmartLoot] Failed to register mailbox %s (state broadcaster)", 
        STATE_BROADCAST.mailbox_name))
else
    logging.log(string.format("[SmartLoot] State broadcast mailbox registered: %s", 
        STATE_BROADCAST.mailbox_name))
end

-- RGMercs acknowledgment mailbox
local function handleRGMercsAck(message)
    local msg = message()
    logging.debug("[SmartLoot] RGMercs ack handler CALLED, message type: " .. type(msg))
    
    if type(msg) ~= "table" then 
        logging.debug("[SmartLoot] RGMercs ack message is not a table: " .. tostring(msg))
        return 
    end
    
    local cmd = msg.cmd or ""
    local subject = msg.subject or ""
    local who = msg.who or "Unknown"
    
    logging.debug(string.format("[SmartLoot] RGMercs ack received - cmd=%s, subject=%s, who=%s", cmd, subject, who))
    
    if cmd == "ack" then
        SmartLootEngine.state.rgmercs.lastMessageReceived = mq.gettime()
        SmartLootEngine.state.rgmercs.lastAckSubject = subject
        SmartLootEngine.state.rgmercs.messagesReceived = (SmartLootEngine.state.rgmercs.messagesReceived or 0) + 1
        logging.debug(string.format("[SmartLoot] Received acknowledgment from RGMercs (%s): %s (total: %d)", 
            who, subject, SmartLootEngine.state.rgmercs.messagesReceived))
    else
        logging.debug(string.format("[SmartLoot] >>> Unknown ack command: %s", cmd))
    end
end

local ok_ack_mailbox, rgmercs_ack_actor = pcall(function()
    return actors.register("smartloot_rgmercs_ack", handleRGMercsAck)
end)

if not ok_ack_mailbox then
    logging.log(string.format("[SmartLoot] Failed to register RGMercs ack mailbox: %s", tostring(rgmercs_ack_actor)))
elseif not rgmercs_ack_actor then
    logging.debug("[SmartLoot] RGMercs ack mailbox registration returned nil")
else
    logging.debug("[SmartLoot] RGMercs acknowledgment mailbox registered: smartloot_rgmercs_ack")
    logging.debug("[SmartLoot] RGMercs should send acks to this mailbox when it receives messages")
end

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
            return 'bool', state.needsPendingDecision
        end,

        CorpseCount = function(_, self)
            local center = SmartLootEngine.getEffectiveCenter()
            local query = string.format("npccorpse radius %d loc %.1f %.1f %.1f", settings.lootRadius, center.x, center
            .y, center.z)
            local corpseCount = mq.TLO.SpawnCount(query)() or 0
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
            -- Get processed corpses directly from the engine's internal state
            local processedCorpses = SmartLootEngine.state.processedCorpsesThisSession or {}

            -- Check for unprocessed NPC corpses
            local center = SmartLootEngine.getEffectiveCenter()
            local query = string.format("npccorpse radius %d loc %.1f %.1f %.1f", settings.lootRadius, center.x, center
            .y, center.z)
            local corpseCount = mq.TLO.SpawnCount(query)()
            if corpseCount and corpseCount > 0 then
                for i = 1, corpseCount do
                    local corpse = mq.TLO.NearestSpawn(i, query)
                    if corpse and corpse.ID() then
                        local corpseID = corpse.ID()
                        -- Check if corpse is processed using the SmartLootEngine's helper function
                        -- This handles both old boolean format and new table format
                        if not SmartLootEngine.isCorpseProcessed(corpseID) then
                            return 'bool', true
                        end
                    end
                end
            end
            return 'bool', false
        end,

        -- Control/interrupt states
        CanSafelyInterrupt = function(_, self)
            local state = SmartLootEngine.getState()
            -- Can interrupt if idle or between actions
            local safeStates = { "Idle", "WaitingForCorpses", "CheckingCorpses" }
            for _, stateName in ipairs(safeStates) do
                if state.currentStateName == stateName then
                    return 'bool', true
                end
            end
            return 'bool', false
        end,

        -- Peer looting presence (Actor Mailbox-based)
        PeerLooting = function(_, self, peerName)
            if not peerName or peerName == "" then return 'bool', false end
            local me = mq.TLO.Me.Name()
            if me and _safeLower(peerName) == _safeLower(me) then
                return 'bool', false
            end
            local entry = LOOT_STATUS and LOOT_STATUS.peers and LOOT_STATUS.peers[peerName]
            if not entry then return 'bool', false end
            local now = os.time()
            if entry.lastSeen and (now - entry.lastSeen) > (LOOT_STATUS.staleAfter or 12) then
                return 'bool', false
            end
            return 'bool', entry.isLooting == true
        end,

        AnyPeerLooting = function(_, self)
            local me = mq.TLO.Me.Name()
            local now = os.time()
            if not LOOT_STATUS or not LOOT_STATUS.peers then return 'bool', false end
            for name, entry in pairs(LOOT_STATUS.peers) do
                if not me or _safeLower(name) ~= _safeLower(me) then
                    if entry.isLooting and entry.lastSeen and (now - entry.lastSeen) <= (LOOT_STATUS.staleAfter or 12) then
                        return 'bool', true
                    end
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
local uiDirectedAssign = safeRequire("ui.ui_directed_assign", "DirectedAssign")
-- local uiTempRules = safeRequire("ui.ui_temp_rules", "TempRules") -- Removed - replaced with name-based rules

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
    -- Apply SmartLoot-scoped rounded theme (local to our draw only)
    local ROUND = 8.0
    local _sl_pushed = 0
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    ImGui.PushStyleVar(ImGuiStyleVar.ChildRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    ImGui.PushStyleVar(ImGuiStyleVar.GrabRounding, ROUND)
    _sl_pushed = _sl_pushed + 1
    if ImGuiStyleVar.TabRounding ~= nil then
        ImGui.PushStyleVar(ImGuiStyleVar.TabRounding, ROUND)
        _sl_pushed = _sl_pushed + 1
    end
    -- Main UI Window
    if lootUI.showUI then
        ImGui.SetNextWindowBgAlpha(0.75)
        ImGui.SetNextWindowSize(800, 600, ImGuiCond.FirstUseEver)

        local windowFlags = bit32.bor(ImGuiWindowFlags.None)
        if lootUI.windowLocked then
            windowFlags = bit32.bor(windowFlags, ImGuiWindowFlags.NoMove, ImGuiWindowFlags.NoResize)
        end

        local open, shouldClose = ImGui.Begin("SmartLoot - Loot Smarter, Not Harder", true, windowFlags)
        if open then
            -- Header with dynamic status and buttons
            local currentTime = mq.gettime()

            -- Status indicator with animated pulse
            local pulseSpeed = 2.0 -- seconds for full pulse cycle
            local pulsePhase = (currentTime / 1000) % pulseSpeed / pulseSpeed * 2 * math.pi
            local pulseAlpha = 0.5 + 0.3 * math.sin(pulsePhase)

            if lootUI.paused then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.4, 0.2, 1.0) -- Orange
                ImGui.Text(Icons.FA_PAUSE .. " Paused")
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, pulseAlpha) -- Animated green
                ImGui.Text(Icons.FA_COG .. " Active")
            end
            ImGui.PopStyleColor()

            ImGui.SameLine()

            -- Add some status info based on recent activity
            local statusText = ""
            if lootUI.lastProcessedItem and (currentTime - (lootUI.lastProcessedTime or 0)) < 5000 then
                statusText = string.format("Last: %s", lootUI.lastProcessedItem)
            elseif lootUI.currentCorpse then
                statusText = "Processing corpse..."
            else
                statusText = "Ready"
            end

            ImGui.TextColored(0.7, 0.7, 0.7, 1.0, " | " .. statusText)
            ImGui.SameLine()

            -- Animated stick figure
            if not lootUI.paused then
                -- Calculate available space for animation
                local currentPos = ImGui.GetCursorPosX()
                local buttonWidth = 30
                local buttonSpacing = 5
                local totalButtonWidth = (buttonWidth * 2) + buttonSpacing + 20 -- extra margin
                local windowWidth = ImGui.GetWindowWidth()
                local availableSpace = windowWidth - currentPos - totalButtonWidth

                if availableSpace > 120 then -- Minimum space needed for animation + buffer
                    -- Animation cycle: 8 seconds to cross the space (much slower)
                    local animSpeed = 8000   -- milliseconds for full cycle
                    local animPhase = (currentTime % animSpeed) / animSpeed
                    -- Stop before hitting buttons - leave 40px buffer
                    local maxTravel = availableSpace - 40
                    local stickX = currentPos + (maxTravel * animPhase)

                    -- Sword-waving animation frames (much slower)
                    local frameSpeed = 600 -- Change frame every 600ms (much slower)
                    local frameIndex = math.floor((currentTime / frameSpeed) % 4)

                    -- 3-line ASCII stick figure warrior with FA weapon effects
                    local swordFrames = {
                        -- Frame 1: sword raised high
                        {
                            " o " .. Icons.FA_MAGIC, -- head + magic sparkles
                            "/|\\",                  -- arms up + body
                            "/ \\" .. Icons.FA_BOLT  -- legs + lightning
                        },
                        -- Frame 2: sword swing
                        {
                            " o ",                   -- head
                            "-|\\" .. Icons.FA_FIRE, -- swing + body + fire
                            "| |"                    -- legs standing
                        },
                        -- Frame 3: sword down
                        {
                            " o ",                   -- head
                            " |/",                   -- body + arm down
                            "/ \\" .. Icons.FA_MAGIC -- legs + magic effect
                        },
                        -- Frame 4: ready position
                        {
                            " o " .. Icons.FA_BOLT, -- head + energy
                            "\\|/",                 -- arms spread + body
                            "| |"                   -- legs ready
                        }
                    }

                    local currentFrame = swordFrames[frameIndex + 1]

                    -- Store button Y position before drawing stick figure
                    local buttonY = ImGui.GetCursorPosY()

                    -- Position and draw the 3-line stick figure
                    local startY = buttonY

                    -- Draw each line of the stick figure
                    for i, line in ipairs(currentFrame) do
                        ImGui.SetCursorPosX(stickX)
                        ImGui.SetCursorPosY(startY + (i - 1) * 12) -- 12px line spacing
                        ImGui.TextColored(0.8, 0.6, 0.2, 1.0, line)
                    end

                    -- Reset cursor position to align buttons with top of stick figure
                    ImGui.SetCursorPosY(buttonY)
                    ImGui.SetCursorPosX(currentPos + maxTravel + 50) -- Position after stick figure's travel area
                end
            else
                -- When paused, show a sleeping figure
                ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "(˘▾˘)~♪ Zzz...")
                ImGui.SameLine()
            end

            -- Push buttons to the right side
            local buttonWidth = 30
            local buttonSpacing = 5
            local totalButtonWidth = (buttonWidth * 2) + buttonSpacing
            local availableWidth = ImGui.GetContentRegionAvail()
            local offsetX = availableWidth - totalButtonWidth

            if offsetX > 0 then
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + offsetX)
            end

            -- Pause/Resume button
            local pauseIcon = lootUI.paused and Icons.FA_PLAY or Icons.FA_PAUSE
            local pauseColor = lootUI.paused and { 0.2, 0.8, 0.2, 1.0 } or { 0.8, 0.2, 0.2, 1.0 }
            local pauseHoverColor = lootUI.paused and { 0.3, 0.9, 0.3, 1.0 } or { 0.9, 0.3, 0.3, 1.0 }
            local pauseActiveColor = lootUI.paused and { 0.1, 0.6, 0.1, 1.0 } or { 0.6, 0.1, 0.1, 1.0 }

            ImGui.PushStyleColor(ImGuiCol.Button, pauseColor[1], pauseColor[2], pauseColor[3], pauseColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, pauseHoverColor[1], pauseHoverColor[2], pauseHoverColor[3],
                pauseHoverColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, pauseActiveColor[1], pauseActiveColor[2], pauseActiveColor[3],
                pauseActiveColor[4])
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)

            if ImGui.Button(pauseIcon, buttonWidth, buttonWidth) then
                lootUI.paused = not lootUI.paused
                mq.cmd("/sl_pause " .. (lootUI.paused and "on" or "off"))
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(lootUI.paused and "Resume loot processing" or "Pause loot processing")
            end

            ImGui.PopStyleVar()
            ImGui.PopStyleColor(3)

            -- Lock button next to pause button
            ImGui.SameLine()

            local lockIcon = lootUI.windowLocked and Icons.FA_LOCK or Icons.FA_UNLOCK
            local lockColor = lootUI.windowLocked and { 0.8, 0.6, 0.2, 1.0 } or { 0.6, 0.6, 0.6, 1.0 }
            local lockHoverColor = lootUI.windowLocked and { 1.0, 0.8, 0.4, 1.0 } or { 0.8, 0.8, 0.8, 1.0 }
            local lockActiveColor = lootUI.windowLocked and { 0.6, 0.4, 0.1, 1.0 } or { 0.4, 0.4, 0.4, 1.0 }

            ImGui.PushStyleColor(ImGuiCol.Button, lockColor[1], lockColor[2], lockColor[3], lockColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, lockHoverColor[1], lockHoverColor[2], lockHoverColor[3],
                lockHoverColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, lockActiveColor[1], lockActiveColor[2], lockActiveColor[3],
                lockActiveColor[4])
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)

            if ImGui.Button(lockIcon, buttonWidth, buttonWidth) then
                lootUI.windowLocked = not lootUI.windowLocked
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(lootUI.windowLocked and "Unlock window" or "Lock window")
            end

            ImGui.PopStyleVar()
            ImGui.PopStyleColor(3)
            ImGui.Spacing(5)
            ImGui.Separator()

            if ImGui.BeginTabBar("MainTabBar") then
                if uiLootRules then
                    uiLootRules.draw(lootUI, database, settings, util, uiPopups)
                end
                -- AFK Temp Rules removed - replaced with name-based rule creation in Loot Rules tab
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

                ImGui.EndTabBar()
            end
        end
        ImGui.End()

        if not open and lootUI.showUI then
            lootUI.showUI = false
            config.uiVisibility.showUI = false
            if config.save then config.save() end
        end
    end

    -- UI Components
    if lootUI.useFloatingButton then
        if uiFloatingButton and uiFloatingButton.draw then
            uiFloatingButton.draw(lootUI, settings, function()
                lootUI.showUI = not lootUI.showUI
                config.uiVisibility.showUI = lootUI.showUI
                if config.save then config.save() end
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
            config.uiVisibility.showUI = lootUI.showUI
            if config.save then config.save() end
            if lootUI.showUI then
                lootUI.forceWindowVisible = true
                lootUI.forceWindowUncollapsed = true
            end
        end, nil, util)
    end

    -- Directed Assignment UI (only when flagged by engine)
    if uiDirectedAssign and uiDirectedAssign.draw then
        uiDirectedAssign.draw(SmartLootEngine)
    end

    -- Always show popups
    if uiPopups then
        uiPopups.drawLootDecisionPopup(lootUI, settings, nil)
        uiPopups.drawRemotePendingDecisionsPopup(lootUI, database, util)
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
        uiPopups.drawSessionReportPopup(lootUI, lootHistory, SmartLootEngine)
        uiPopups.drawWhitelistManagerPopup(lootUI, database, util)
        uiPopups.drawBulkCopyRulesPopup(lootUI, database, util)
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

    -- Pop SmartLoot-scoped rounded theme
    if _sl_pushed > 0 then ImGui.PopStyleVar(_sl_pushed) end
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
    show = false,
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
-- CLEANUP AND SHUTDOWN HANDLING
-- ============================================================================

local isShuttingDown = false
local function cleanupSmartLoot()
    if isShuttingDown then return end
    isShuttingDown = true

    logging.log("[SmartLoot] Shutdown initiated - cleaning up resources...")

    -- Clean up the engine completely
    if SmartLootEngine and SmartLootEngine.cleanup then
        SmartLootEngine.cleanup()
        logging.log("[SmartLoot] Engine cleaned up")
    elseif SmartLootEngine and SmartLootEngine.emergencyStop then
        SmartLootEngine.emergencyStop("Shutdown cleanup")
        logging.log("[SmartLoot] Engine emergency stopped")
    end

    -- Clean up command bindings
    if bindings and bindings.cleanup then
        bindings.cleanup()
        logging.log("[SmartLoot] Command bindings cleaned up")
    end

    -- Close database connections in lootHistory
    if lootHistory and lootHistory.close then
        pcall(function()
            lootHistory.close()
            logging.log("[SmartLoot] Loot history database connections closed")
        end)
    end

    -- Close database connections in main database module
    if database and database.cleanup then
        pcall(function()
            database.cleanup()
            logging.log("[SmartLoot] Main database connections closed")
        end)
    end

    -- Attempt to remove/destroy ImGui window first to prevent callbacks during teardown
    pcall(function()
        if mq and mq.imgui and (mq.imgui.destroy or mq.imgui.delete or mq.imgui.remove) then
            local destroy = mq.imgui.destroy or mq.imgui.delete or mq.imgui.remove
            destroy('SmartLoot')
            logging.log("[SmartLoot] ImGui window destroyed")
        end
    end)

    -- Clean up UI modules
    if uiLiveStats and uiLiveStats.cleanup then
        uiLiveStats.cleanup()
    end

    -- Clean up mailbox actors
    if smartlootMailbox then
        smartlootMailbox = nil
        logging.log("[SmartLoot] Mailbox actors cleaned up")
    end

    if smartlootCommandMailbox then
        smartlootCommandMailbox = nil
    end

    if LOOT_STATUS and LOOT_STATUS.actor then
        LOOT_STATUS.actor = nil
        LOOT_STATUS.peers = {}
    end
    
    if STATE_BROADCAST and STATE_BROADCAST.actor then
        STATE_BROADCAST.actor = nil
    end

    -- Clean up TLO (best-effort, protected)
    pcall(function()
        if mq.RemoveTopLevelObject then
            mq.RemoveTopLevelObject('SmartLoot')
            logging.log("[SmartLoot] TLO removed")
        end
    end)

    -- Clean up mode handler
    if modeHandler and modeHandler.cleanup then
        pcall(function()
            modeHandler.cleanup()
            logging.log("[SmartLoot] Mode handler cleaned up")
        end)
    end

    logging.log("[SmartLoot] Cleanup completed successfully")
end

-- Additional shutdown signal handling (conservative approach)
local shutdownCheckCount = 0
local lastShutdownCheck = 0
local function checkForShutdownSignals()
    local now = mq.gettime()

    -- Only check every 5 seconds to avoid false positives
    if now - lastShutdownCheck < 5000 then
        return false
    end
    lastShutdownCheck = now

    -- Very conservative shutdown detection - only trigger if multiple checks fail
    local mqAvailable = pcall(function() return mq.TLO.MacroQuest and mq.TLO.MacroQuest() end)
    local meAvailable = pcall(function() return mq.TLO.Me and mq.TLO.Me() end)

    if not mqAvailable or not meAvailable then
        shutdownCheckCount = shutdownCheckCount + 1

        -- Only consider shutdown if we've had multiple consecutive failures
        if shutdownCheckCount >= 3 then
            logging.log("[SmartLoot] Multiple consecutive TLO failures - shutdown detected")
            return true
        end
    else
        -- Reset counter if checks pass
        shutdownCheckCount = 0
    end

    return false
end

-- ============================================================================
-- MAIN LOOP - PURE STATE ENGINE
-- ============================================================================

local function processMainTick()
    -- Check for shutdown signal
    if isShuttingDown then
        return false
    end

    -- CORE ENGINE PROCESSING - This drives everything
    SmartLootEngine.processTick()

    -- BRIDGE: Handle engine -> UI communication
    handleEnginePendingDecision()

    -- BRIDGE: Handle UI -> engine communication
    processUIDecisionForEngine()

    -- Publish our looting presence and maintain peer table
    publishLootStatusTick()
    pruneStalePeerLootStatus()
    
    -- Publish engine state for external consumers (RGMercs, etc.)
    publishStateBroadcastTick()

    -- PEER MONITORING: Check for peer connection changes and auto-adjust mode
    modeHandler.checkPeerChanges()

    -- Zone change detection
    checkForZoneChange()

    return true
end

-- Main loop - simplified to just run the state engine
local mainTimer = mq.gettime()
while true do
    -- Avoid pumping events after shutdown begins to prevent callbacks during teardown
    if not isShuttingDown then
        mq.doevents()
    end

    -- If MQ reports we are no longer in-game, begin shutdown
    local gs = nil
    pcall(function() gs = mq.TLO.MacroQuest.GameState and mq.TLO.MacroQuest.GameState() end)
    if gs and gs ~= "INGAME" then
        isShuttingDown = true
    end

    local now = mq.gettime()
    if now >= mainTimer then
        if not processMainTick() then
            -- Shutdown requested
            break
        end
        mainTimer = now + 50 -- Process every 50ms
    end

    mq.delay(10) -- Small delay to prevent 100% CPU usage

    -- Check if we should exit (MQ2 shutting down, etc.)
    if isShuttingDown or checkForShutdownSignals() then
        if not isShuttingDown then
            logging.log("[SmartLoot] Shutdown signal detected in main loop")
        end
        break
    end
end

-- Final cleanup before script ends
cleanupSmartLoot()
