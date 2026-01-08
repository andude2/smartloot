-- config.lua - Updated with chat output configuration
local config = {}
local mq = require("mq")
local json = require("dkjson")

-- Get current server name for per-server configs
local currentServerName = mq.TLO.EverQuest.Server()
local sanitizedServerName = currentServerName:lower():gsub(" ", "_")

config.filePath = mq.TLO.MacroQuest.Path("config")() .. "/smartloot_config.json"

-- Default settings (global, not per-server) - Added chat output settings
config.lootCommandType = "dannet"  -- Default to "dannet" instead of "e3"
config.dannetBroadcastChannel = "group" -- Options: group (dgga), raid (dgra)
config.mainToonName = mq.TLO.Me.Name() or "MainToon"  -- Default to current character name
config.lootDelay = 5      -- Delay in seconds before background bots try to loot
config.retryCount = 3     -- Number of retry attempts for background bots
config.retryDelay = 5     -- Delay between retry attempts in seconds
-- corpse detection and loot interaction distances (match UI defaults)
config.lootRadius = 200   -- search radius for corpses
config.lootRange = 15     -- interaction distance to open loot

-- Chat output configuration
config.chatOutputMode = "group"  -- Default to group chat
config.customChatCommand = "/say"  -- Default custom command if mode is "custom"

-- Item announce configuration
config.itemAnnounceMode = "all"  -- Options: "all", "ignored", "none"

-- Farming mode configuration
config.farmingMode = false  -- Whether farming mode is active (bypasses corpse deduplication)

-- Peer selection strategy for ignored items
config.peerSelectionStrategy = "items_first" -- Options: items_first, peers_first

-- Lore item checking configuration (always enabled to prevent getting stuck)
config.loreCheckAnnounce = true  -- Whether to announce when Lore conflicts are detected

-- Default settings additions (add to existing defaults)
config.useChaseCommands = false  -- Whether to use chase commands at all
config.chasePauseCommand = "/luachase pause on"  -- Command to pause chase
config.chaseResumeCommand = "/luachase pause off"  -- Command to resume chase

-- Navigation command configuration
config.navigationCommand = "/nav"  -- Primary navigation command
config.navigationFallbackCommand = "/moveto"  -- Fallback command if primary unavailable
config.navigationStopCommand = "/nav stop"  -- Command to stop navigation if supported

-- Hotbar configuration
config.hotbar = {
    position = { x = 100, y = 300 },
    buttonSize = 50,
    alpha = 0.8,
    vertical = false,
    showLabels = false,
    compactMode = false,
    useTextLabels = false,
    show = true,
    buttonVisibility = {
        startBG = true,
        stopBG = true,
        clearCache = true,
        lootAll = true,
        autoKnown = true,
        pausePeer = true,
        toggleUI = true,
        addRule = true,
        peerCommands = true,
        settings = true
    }
}

-- Inventory settings (persisted)
config.inventory = {
    enableInventorySpaceCheck = true,
    minFreeInventorySlots = 5,
    autoInventoryOnLoot = true,
}

-- Live Stats window configuration
config.liveStats = {
    show = false,
    compactMode = false,
    alpha = 0.85,
    position = { x = 200, y = 200 },
    stateDisplay = {
        showDetailedState = false,
        minDisplayTime = 500,
    },
}

-- UI Visibility Configuration
config.uiVisibility = {
    showPeerCommands = true,
    showDebugWindow = false,
    showHotbar = true,
    showUI = false,
}

-- SmartLoot Engine Speed Configuration
config.engineSpeed = {
    -- Speed multiplier: 1.0 = normal, 0.75 = 25% faster, 1.25 = 25% slower
    -- Lower values = faster processing, higher values = slower processing
    multiplier = 1.0,
    
    -- Base timing settings (in milliseconds) - these are the reference values
    baseTiming = {
        tickIntervalMs = 25,
        itemPopulationDelayMs = 100,
        itemProcessingDelayMs = 50,
        ignoredItemDelayMs = 25,
        lootActionDelayMs = 200,
        navRetryDelayMs = 500,
        combatWaitDelayMs = 1500,
        
        -- Timeout settings
        maxNavTimeMs = 30000,
        pendingDecisionTimeoutMs = 30000,
        maxLootWaitTime = 5000,
        errorRecoveryDelayMs = 2000,
        maxItemProcessingTime = 10000,
        
        -- Peer coordination timing
        peerTriggerDelay = 10000
    }
}

-- : SmartLoot Engine Timing configuration (computed from speed settings)
config.engineTiming = {
    -- These will be computed based on speed multiplier
    tickIntervalMs = 25,
    itemPopulationDelayMs = 100,
    itemProcessingDelayMs = 50,
    ignoredItemDelayMs = 25,
    lootActionDelayMs = 200,
    navRetryDelayMs = 500,
    combatWaitDelayMs = 1500,
    
    -- Timeout settings
    maxNavTimeMs = 30000,
    pendingDecisionTimeoutMs = 30000,
    maxLootWaitTime = 5000,
    errorRecoveryDelayMs = 2000,
    maxItemProcessingTime = 10000,
    
    -- Peer coordination timing
    peerTriggerDelay = 10000
}

-- Valid chat output modes
config.validChatModes = {
    "rsay",
    "group", 
    "guild",
    "custom",
    "silent"
}

-- Per-server settings
config.peerLootOrder = {}  -- This will be per-server

-- Internal configuration structure
local configData = {
    global = {
        lootCommandType = config.lootCommandType,
        dannetBroadcastChannel = config.dannetBroadcastChannel,
        mainToonName = config.mainToonName,
        lootDelay = config.lootDelay,
        retryCount = config.retryCount,
        retryDelay = config.retryDelay,
        peerSelectionStrategy = config.peerSelectionStrategy,
        -- Chat configuration in global settings
        chatOutputMode = config.chatOutputMode,
        customChatCommand = config.customChatCommand,
        -- Item announce configuration in global settings
        itemAnnounceMode = config.itemAnnounceMode,
        -- Farming mode configuration in global settings
        farmingMode = config.farmingMode,
        -- Chase command configuration
        useChaseCommands = config.useChaseCommands,
        chasePauseCommand = config.chasePauseCommand,
        chaseResumeCommand = config.chaseResumeCommand,
        navigationCommand = config.navigationCommand,
        navigationFallbackCommand = config.navigationFallbackCommand,
        navigationStopCommand = config.navigationStopCommand,
        -- Hotbar configuration in global settings
        hotbar = config.hotbar,
        -- Engine timing configuration in global settings
        engineTiming = config.engineTiming,
        -- Engine speed configuration in global settings
        engineSpeed = config.engineSpeed,
        -- Inventory configuration in global settings
        inventory = config.inventory,
    },
    servers = {}
}

-- Floating Button configuration
config.floatingButton = {
    size = 60,
    alpha = 0.95,
    x = 100,
    y = 100,
    show = true,
}

-- Load function to read stored configuration
function config.load()
    local file = io.open(config.filePath, "r")
    if file then
        local contents = file:read("*a")
        file:close()
        local decoded = json.decode(contents)
        if decoded then
            -- New format
            configData.global = decoded.global or configData.global
            configData.servers = decoded.servers or {}
            
            -- Apply global settings
            config.lootCommandType = configData.global.lootCommandType or config.lootCommandType
            config.mainToonName = configData.global.mainToonName or config.mainToonName
            config.lootDelay = configData.global.lootDelay or config.lootDelay
            config.retryCount = configData.global.retryCount or config.retryCount
            config.retryDelay = configData.global.retryDelay or config.retryDelay
            
            -- Apply chat settings
            config.chatOutputMode = configData.global.chatOutputMode or config.chatOutputMode
            config.customChatCommand = configData.global.customChatCommand or config.customChatCommand
            config.dannetBroadcastChannel = configData.global.dannetBroadcastChannel or config.dannetBroadcastChannel
            -- Apply item announce settings
            config.itemAnnounceMode = configData.global.itemAnnounceMode or config.itemAnnounceMode
            -- Apply farming mode settings
            config.farmingMode = configData.global.farmingMode or config.farmingMode
            config.useChaseCommands = configData.global.useChaseCommands or config.useChaseCommands
            config.chasePauseCommand = configData.global.chasePauseCommand or config.chasePauseCommand
            config.chaseResumeCommand = configData.global.chaseResumeCommand or config.chaseResumeCommand
            config.navigationCommand = configData.global.navigationCommand or config.navigationCommand
            config.navigationFallbackCommand = configData.global.navigationFallbackCommand or config.navigationFallbackCommand
            config.navigationStopCommand = configData.global.navigationStopCommand or config.navigationStopCommand

            -- Apply hotbar settings
            if configData.global.hotbar then
                config.hotbar = configData.global.hotbar
            end

            -- Apply live stats settings
            if configData.global.liveStats then
                config.liveStats = configData.global.liveStats
            end

            config.peerSelectionStrategy = configData.global.peerSelectionStrategy or config.peerSelectionStrategy
            -- Apply loot distances if present
            if configData.global.lootRadius then config.lootRadius = tonumber(configData.global.lootRadius) or config.lootRadius end
            if configData.global.lootRange then config.lootRange = tonumber(configData.global.lootRange) or config.lootRange end
            
            -- Apply engine timing settings
            if configData.global.engineTiming then
                config.engineTiming = configData.global.engineTiming
            end
            
            -- Apply engine speed settings
            if configData.global.engineSpeed then
                config.engineSpeed = configData.global.engineSpeed
            end
            
            -- Apply inventory settings
            if configData.global.inventory then
                config.inventory = configData.global.inventory
                -- Push to engine if available
                if config.syncInventoryToEngine then pcall(config.syncInventoryToEngine) end
            end

            -- Apply UI visibility settings
            if configData.global.uiVisibility then
                config.uiVisibility = configData.global.uiVisibility
            end
            
            -- Apply per-server settings
            local serverConfig = configData.servers[sanitizedServerName] or {}
            config.peerLootOrder = serverConfig.peerLootOrder or {}
            -- Ensure characters table exists for per-character toggles
            serverConfig.characters = serverConfig.characters or {}
            configData.servers[sanitizedServerName] = serverConfig

            -- Apply floating button settings
            if configData.global.floatingButton then
                config.floatingButton = configData.global.floatingButton
            end
        end
    else
        -- No config file exists, initialize with defaults
        configData.servers[sanitizedServerName] = {
            peerLootOrder = {},
            characters = {}
        }
        -- Set default chat settings
        configData.global.chatOutputMode = config.chatOutputMode
        configData.global.customChatCommand = config.customChatCommand
        configData.global.dannetBroadcastChannel = config.dannetBroadcastChannel
        -- Initialize floating button settings
        configData.global.floatingButton = config.floatingButton
    end
end

-- Save function to store configuration
function config.save()
    -- Update internal structure with current values
    configData.global.lootCommandType = config.lootCommandType
    configData.global.dannetBroadcastChannel = config.dannetBroadcastChannel
    configData.global.mainToonName = config.mainToonName
    configData.global.lootDelay = config.lootDelay
    configData.global.retryCount = config.retryCount
    configData.global.retryDelay = config.retryDelay
    configData.global.peerSelectionStrategy = config.peerSelectionStrategy
    -- Persist loot distances
    configData.global.lootRadius = config.lootRadius
    configData.global.lootRange = config.lootRange
    
    -- Update chat settings
    configData.global.chatOutputMode = config.chatOutputMode
    configData.global.customChatCommand = config.customChatCommand
    -- Update item announce settings
    configData.global.itemAnnounceMode = config.itemAnnounceMode
    -- Update farming mode settings
    configData.global.farmingMode = config.farmingMode
    configData.global.useChaseCommands = config.useChaseCommands
    configData.global.chasePauseCommand = config.chasePauseCommand
    configData.global.chaseResumeCommand = config.chaseResumeCommand
    configData.global.navigationCommand = config.navigationCommand
    configData.global.navigationFallbackCommand = config.navigationFallbackCommand
    configData.global.navigationStopCommand = config.navigationStopCommand
    
    -- Update hotbar settings
    configData.global.hotbar = config.hotbar
    -- Update live stats settings
    configData.global.liveStats = config.liveStats

    -- Update engine timing settings
    configData.global.engineTiming = config.engineTiming
    
    -- Update engine speed settings
    configData.global.engineSpeed = config.engineSpeed

    -- Update inventory settings from engine if available, else from config
    do
        local Engine = package.loaded["modules.SmartLootEngine"]
        if Engine and Engine.config then
            config.inventory.enableInventorySpaceCheck = Engine.config.enableInventorySpaceCheck and true or false
            config.inventory.minFreeInventorySlots = tonumber(Engine.config.minFreeInventorySlots) or config.inventory.minFreeInventorySlots
            config.inventory.autoInventoryOnLoot = Engine.config.autoInventoryOnLoot and true or false
        end
    end
    configData.global.inventory = config.inventory

    -- Update UI visibility settings
    configData.global.uiVisibility = config.uiVisibility

    -- Update floating button settings
    configData.global.floatingButton = config.floatingButton
    
    -- Ensure server config exists
    if not configData.servers[sanitizedServerName] then
        configData.servers[sanitizedServerName] = {}
    end
    
    -- Update server-specific settings
    local serverConfig = configData.servers[sanitizedServerName] or {}
    serverConfig.peerLootOrder = config.peerLootOrder
    serverConfig.characters = serverConfig.characters or {}
    configData.servers[sanitizedServerName] = serverConfig
    
    local file = io.open(config.filePath, "w")
    if file then
        file:write(json.encode(configData, { indent = true }))
        file:close()
        return true
    else
        return false
    end
end

-- Quick setters for commonly tuned distances
function config.setLootRadius(radius)
    radius = math.max(10, math.min(1000, tonumber(radius) or config.lootRadius))
    config.lootRadius = radius
    config.save()
    -- Also push to engine live
    local Engine = package.loaded["modules.SmartLootEngine"]
    if Engine and Engine.setLootRadius then Engine.setLootRadius(radius) end
    return radius
end

function config.setLootRange(range)
    range = math.max(5, math.min(100, tonumber(range) or config.lootRange))
    config.lootRange = range
    config.save()
    local Engine = package.loaded["modules.SmartLootEngine"]
    if Engine and Engine.setLootRange then Engine.setLootRange(range) end
    return range
end

-- Chat output helper functions
function config.setChatMode(mode)
    if not mode then return false end
    
    mode = mode:lower()
    
    -- Validate mode
    local validMode = false
    for _, validMode in ipairs(config.validChatModes) do
        if mode == validMode then
            validMode = true
            break
        end
    end
    
    if not validMode then
        return false, "Invalid chat mode. Valid modes: " .. table.concat(config.validChatModes, ", ")
    end
    
    config.chatOutputMode = mode
    config.save()
    return true
end

-- ============================================================================
-- Per-character settings (server-scoped)
-- ============================================================================

local function ensureCharacterConfig(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    if not configData.servers[sanitizedServerName] then
        configData.servers[sanitizedServerName] = { peerLootOrder = {}, characters = {} }
    end
    local serverConfig = configData.servers[sanitizedServerName]
    serverConfig.characters = serverConfig.characters or {}
    serverConfig.characters[toonName] = serverConfig.characters[toonName] or {}
    return serverConfig.characters[toonName], toonName
end

function config.setWhitelistOnly(toonName, value)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)
    charCfg.whitelistOnly = value and true or false
    config.save()
    return charCfg.whitelistOnly
end

function config.isWhitelistOnly(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.whitelistOnly == true
end

function config.getCharacterConfig(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    return chars[toonName] or {}
end

-- Optional: When in whitelist-only mode, prevent this toon from triggering peers
function config.setWhitelistNoTriggerPeers(toonName, value)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)
    charCfg.whitelistNoTriggerPeers = value and true or false
    config.save()
    return charCfg.whitelistNoTriggerPeers
end

function config.isWhitelistNoTriggerPeers(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.whitelistNoTriggerPeers == true
end

-- Default action for new items (per character)
function config.setDefaultNewItemAction(toonName, action)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)
    
    -- Validate action
    local validActions = {"Prompt", "PromptThenKeep", "PromptThenIgnore", "Keep", "Ignore", "Destroy"}
    local isValid = false
    for _, validAction in ipairs(validActions) do
        if action == validAction then
            isValid = true
            break
        end
    end
    
    if not isValid then
        return false, "Invalid action. Valid actions: " .. table.concat(validActions, ", ")
    end
    
    charCfg.defaultNewItemAction = action
    config.save()
    return charCfg.defaultNewItemAction
end

function config.getDefaultNewItemAction(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.defaultNewItemAction or "Prompt"
end

-- Default prompt dropdown selection for new item prompt (per character)
function config.setDefaultPromptDropdown(toonName, selection)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)

    -- Validate selection
    local validSelections = {"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}
    local isValid = false
    for _, validSelection in ipairs(validSelections) do
        if selection == validSelection then
            isValid = true
            break
        end
    end

    if not isValid then
        return false, "Invalid selection. Valid options: " .. table.concat(validSelections, ", ")
    end

    charCfg.defaultPromptDropdown = selection
    config.save()
    return charCfg.defaultPromptDropdown
end

function config.getDefaultPromptDropdown(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.defaultPromptDropdown or "Keep"
end

-- Decision timeout for new items (per character)
function config.setDecisionTimeout(toonName, timeoutMs)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)
    
    -- Validate timeout (minimum 5 seconds, maximum 5 minutes)
    timeoutMs = math.max(5000, math.min(300000, tonumber(timeoutMs) or 30000))
    
    charCfg.decisionTimeoutMs = timeoutMs
    config.save()
    return charCfg.decisionTimeoutMs
end

function config.getDecisionTimeout(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.decisionTimeoutMs or 30000
end

-- Auto-broadcast new rules created by Default Action (per character)
function config.setAutoBroadcastNewRules(toonName, enabled)
    local charCfg
    charCfg, toonName = ensureCharacterConfig(toonName)
    charCfg.autoBroadcastNewRules = enabled and true or false
    config.save()
    return charCfg.autoBroadcastNewRules
end

function config.isAutoBroadcastNewRules(toonName)
    if not toonName or toonName == "" or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    local serverConfig = configData.servers[sanitizedServerName] or {}
    local chars = serverConfig.characters or {}
    local charCfg = chars[toonName]
    return charCfg and charCfg.autoBroadcastNewRules == true
end

function config.setPeerSelectionStrategy(strategy)
    local normalized = "items_first"
    if type(strategy) == "string" then
        strategy = strategy:lower()
        if strategy == "peers" or strategy == "peers_first" then
            normalized = "peers_first"
        end
    end

    config.peerSelectionStrategy = normalized
    config.save()
    return normalized
end

function config.getPeerSelectionStrategy()
    return config.peerSelectionStrategy or "items_first"
end

function config.setCustomChatCommand(command)
    if not command or command == "" then
        return false, "Custom chat command cannot be empty"
    end
    
    -- Ensure command starts with /
    if not command:match("^/") then
        command = "/" .. command
    end
    
    config.customChatCommand = command
    config.save()
    return true
end

function config.getChatCommand()
    local mode = config.chatOutputMode:lower()
    
    if mode == "rsay" then
        return "/rsay"
    elseif mode == "group" then
        return "/g"
    elseif mode == "guild" then
        return "/gu"
    elseif mode == "custom" then
        return config.customChatCommand
    elseif mode == "silent" then
        return nil  -- No output
    else
        -- Fallback to group if somehow invalid
        return "/g"
    end
end

function config.sendChatMessage(message)
    local chatCommand = config.getChatCommand()
    
    if not chatCommand then
        -- Silent mode - no output
        return
    end
    
    -- Send the message using the configured chat command
    mq.cmdf('%s %s', chatCommand, message)
end

function config.getChatModeDescription()
    local mode = config.chatOutputMode:lower()
    
    if mode == "rsay" then
        return "Raid Say (/rsay)"
    elseif mode == "group" then
        return "Group Chat (/g)"
    elseif mode == "guild" then
        return "Guild Chat (/gu)"
    elseif mode == "custom" then
        return "Custom (" .. config.customChatCommand .. ")"
    elseif mode == "silent" then
        return "Silent (No Output)"
    else
        return "Unknown Mode"
    end
end

-- Debug function to show chat configuration
function config.debugChatConfig()
    print("=== SmartLoot Chat Configuration ===")
    print("Chat Output Mode: " .. config.chatOutputMode)
    print("Description: " .. config.getChatModeDescription())
    print("Chat Command: " .. tostring(config.getChatCommand() or "None (Silent)"))
    if config.chatOutputMode == "custom" then
        print("Custom Command: " .. config.customChatCommand)
    end
end

-- Item announce helper functions
function config.setItemAnnounceMode(mode)
    if not mode then return false end
    
    mode = mode:lower()
    local validModes = {"all", "ignored", "none"}
    
    -- Validate mode
    local isValid = false
    for _, validMode in ipairs(validModes) do
        if mode == validMode then
            isValid = true
            break
        end
    end
    
    if not isValid then
        return false, "Invalid item announce mode. Valid modes: " .. table.concat(validModes, ", ")
    end
    
    config.itemAnnounceMode = mode
    config.save()
    return true
end

function config.getItemAnnounceMode()
    return config.itemAnnounceMode
end

function config.getItemAnnounceModeDescription()
    local mode = config.itemAnnounceMode:lower()
    
    if mode == "all" then
        return "All Items"
    elseif mode == "ignored" then
        return "Ignored Items Only"
    elseif mode == "none" then
        return "No Item Announcements"
    else
        return "Unknown Mode"
    end
end

function config.shouldAnnounceItem(action)
    local mode = config.itemAnnounceMode:lower()
    
    if mode == "none" then
        return false
    elseif mode == "all" then
        return true
    elseif mode == "ignored" then
        return action == "Ignored"
    else
        return false -- Default to no announcement if mode is unknown
    end
end

-- Farming mode helper functions
function config.setFarmingMode(enabled)
    config.farmingMode = enabled or false
    config.save()
    return true
end

function config.getFarmingMode()
    return config.farmingMode
end

function config.toggleFarmingMode()
    config.farmingMode = not config.farmingMode
    config.save()
    return config.farmingMode
end

function config.isFarmingModeActive()
    return config.farmingMode == true
end

function config.setChaseCommands(useChase, pauseCmd, resumeCmd)
    config.useChaseCommands = useChase or false
    
    if pauseCmd and pauseCmd ~= "" then
        -- Ensure command starts with /
        if not pauseCmd:match("^/") then
            pauseCmd = "/" .. pauseCmd
        end
        config.chasePauseCommand = pauseCmd
    end
    
    if resumeCmd and resumeCmd ~= "" then
        -- Ensure command starts with /
        if not resumeCmd:match("^/") then
            resumeCmd = "/" .. resumeCmd
        end
        config.chaseResumeCommand = resumeCmd
    end
    
    config.save()
    return true
end

function config.executeChaseCommand(action)
    if not config.useChaseCommands then
        return false, "Chase commands disabled"
    end
    
    local command = nil
    if action == "pause" then
        command = config.chasePauseCommand
    elseif action == "resume" then
        command = config.chaseResumeCommand
    else
        return false, "Invalid chase action: " .. tostring(action)
    end
    
    if not command or command == "" then
        return false, "No chase command configured for: " .. action
    end
    
    mq.cmd(command)
    return true, "Executed: " .. command
end

local function normalizeSlashCommand(cmd)
    if not cmd then return nil end
    local trimmed = cmd:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil end
    if not trimmed:match("^/") then
        trimmed = "/" .. trimmed
    end
    return trimmed
end

function config.setNavigationCommands(primary, fallback, stop)
    local updated = false

    if primary ~= nil then
        local normalized = normalizeSlashCommand(primary) or config.navigationCommand
        if normalized ~= config.navigationCommand then
            config.navigationCommand = normalized
            updated = true
        end
    end

    if fallback ~= nil then
        local normalized = normalizeSlashCommand(fallback) or config.navigationFallbackCommand
        if normalized ~= config.navigationFallbackCommand then
            config.navigationFallbackCommand = normalized
            updated = true
        end
    end

    if stop ~= nil then
        local normalized = normalizeSlashCommand(stop)
        if not normalized and type(stop) == "string" then
            normalized = "" -- allow clearing the stop command
        end
        if normalized ~= config.navigationStopCommand then
            config.navigationStopCommand = normalized
            updated = true
        end
    end

    if updated then
        config.save()
    end

    return config.navigationCommand, config.navigationFallbackCommand, config.navigationStopCommand
end

function config.getChaseConfigDescription()
    if not config.useChaseCommands then
        return "Chase Commands: Disabled"
    end
    
    return string.format("Chase Commands: Enabled (Pause: %s, Resume: %s)", 
        config.chasePauseCommand or "None", 
        config.chaseResumeCommand or "None")
end

-- Helper function to save peer loot order (now per-server)
function config.savePeerOrder(orderList)
    config.peerLootOrder = orderList or {}
    config.save()
end

-- Helper function to get peer loot order for current server
function config.getPeerOrder()
    return config.peerLootOrder or {}
end

-- Helper function to clear peer order for current server
function config.clearPeerOrder()
    config.peerLootOrder = {}
    config.save()
end

-- Helper function to get the next peer in the custom order
function config.getNextPeerInOrder(currentPeer)
    if #config.peerLootOrder == 0 then
        return nil  -- No custom order defined
    end
    
    -- Find current peer in the order
    local currentIndex = nil
    for i, peer in ipairs(config.peerLootOrder) do
        if peer == currentPeer then
            currentIndex = i
            break
        end
    end
    
    -- If current peer not in list, start from beginning
    if not currentIndex then
        return config.peerLootOrder[1]
    end
    
    -- Get next peer in order (wrap around to start if at end)
    local nextIndex = (currentIndex % #config.peerLootOrder) + 1
    return config.peerLootOrder[nextIndex]
end

-- Get configuration for a specific server (utility function)
function config.getServerConfig(serverName)
    if not serverName then
        serverName = sanitizedServerName
    else
        serverName = serverName:lower():gsub(" ", "_")
    end
    
    return configData.servers[serverName] or {}
end

-- Set configuration for a specific server (utility function)
function config.setServerConfig(serverName, serverConfig)
    if not serverName then
        serverName = sanitizedServerName
    else
        serverName = serverName:lower():gsub(" ", "_")
    end
    
    configData.servers[serverName] = serverConfig or {}
    config.save()
end

-- Get list of all configured servers
function config.getConfiguredServers()
    local servers = {}
    for serverName, _ in pairs(configData.servers) do
        table.insert(servers, serverName)
    end
    table.sort(servers)
    return servers
end

-- Hotbar configuration helper functions
function config.saveHotbarSettings(hotbarSettings)
    if hotbarSettings then
        config.hotbar = hotbarSettings
        config.save()
        return true
    end
    return false
end

function config.getHotbarSettings()
    return config.hotbar
end

function config.setHotbarPosition(x, y)
    config.hotbar.position.x = x
    config.hotbar.position.y = y
    config.save()
end

function config.setHotbarButtonVisible(buttonId, visible)
    if config.hotbar.buttonVisibility[buttonId] ~= nil then
        config.hotbar.buttonVisibility[buttonId] = visible
        config.save()
        return true
    end
    return false
end

function config.getHotbarButtonVisible(buttonId)
    return config.hotbar.buttonVisibility[buttonId] or false
end

-- Floating Button helpers
function config.getFloatingButtonSettings()
    return config.floatingButton
end

function config.setFloatingButtonSize(size)
    size = math.max(40, math.min(120, tonumber(size) or 60))
    config.floatingButton.size = size
    config.save()
    return size
end

function config.setFloatingButtonAlpha(alpha)
    alpha = math.max(0.1, math.min(1.0, tonumber(alpha) or 0.95))
    config.floatingButton.alpha = alpha
    config.save()
    return alpha
end

function config.setFloatingButtonPosition(x, y)
    config.floatingButton.x = tonumber(x) or config.floatingButton.x
    config.floatingButton.y = tonumber(y) or config.floatingButton.y
    config.save()
end

function config.setFloatingButtonVisible(show)
    config.floatingButton.show = show and true or false
    config.save()
end

function config.setHotbarUseTextLabels(useText)
    config.hotbar.useTextLabels = useText
    config.save()
end

function config.setHotbarVertical(vertical)
    config.hotbar.vertical = vertical
    config.save()
end

function config.setHotbarAlpha(alpha)
    config.hotbar.alpha = math.max(0.1, math.min(1.0, alpha))
    config.save()
end

function config.setHotbarButtonSize(size)
    config.hotbar.buttonSize = math.max(25, math.min(80, size))
    config.save()
end

function config.setHotbarShowLabels(show)
    config.hotbar.showLabels = show
    config.save()
end

function config.setHotbarCompactMode(compact)
    config.hotbar.compactMode = compact
    config.save()
end

function config.setHotbarShow(show)
    config.hotbar.show = show
    config.save()
end

function config.resetHotbarToDefaults()
    config.hotbar = {
        position = { x = 100, y = 300 },
        buttonSize = 50,
        alpha = 0.8,
        vertical = false,
        showLabels = false,
        compactMode = false,
        useTextLabels = false,
        show = true,
        buttonVisibility = {
            startBG = true,
            stopBG = true,
            clearCache = true,
            lootAll = true,
            autoKnown = true,
            pausePeer = true,
            toggleUI = true,
            addRule = true,
            peerCommands = true,
            settings = true
        }
    }
    config.save()
end

-- Engine Timing configuration helper functions
function config.getEngineTiming()
    return config.engineTiming
end

function config.setEngineTimingValue(key, value)
    if config.engineTiming[key] ~= nil then
        config.engineTiming[key] = value
        config.save()
        return true
    end
    return false
end

function config.setItemPopulationDelay(delayMs)
    config.engineTiming.itemPopulationDelayMs = delayMs
    config.save()
end

function config.setItemProcessingDelay(delayMs)
    config.engineTiming.itemProcessingDelayMs = delayMs
    config.save()
end

function config.setLootActionDelay(delayMs)
    config.engineTiming.lootActionDelayMs = delayMs
    config.save()
end

function config.setIgnoredItemDelay(delayMs)
    config.engineTiming.ignoredItemDelayMs = delayMs
    config.save()
end

function config.setNavRetryDelay(delayMs)
    config.engineTiming.navRetryDelayMs = delayMs
    config.save()
end

function config.setMaxNavTime(timeMs)
    config.engineTiming.maxNavTimeMs = timeMs
    config.save()
end

function config.setCombatWaitDelay(delayMs)
    config.engineTiming.combatWaitDelayMs = delayMs
    config.save()
end

function config.applyTimingPreset(preset)
    if preset == "fast" then
        config.engineTiming.itemPopulationDelayMs = 75
        config.engineTiming.itemProcessingDelayMs = 25
        config.engineTiming.lootActionDelayMs = 150
        config.engineTiming.ignoredItemDelayMs = 10
        config.engineTiming.navRetryDelayMs = 250
        config.engineTiming.combatWaitDelayMs = 1000
    elseif preset == "balanced" then
        config.engineTiming.itemPopulationDelayMs = 100
        config.engineTiming.itemProcessingDelayMs = 50
        config.engineTiming.lootActionDelayMs = 200
        config.engineTiming.ignoredItemDelayMs = 25
        config.engineTiming.navRetryDelayMs = 500
        config.engineTiming.combatWaitDelayMs = 1500
    elseif preset == "conservative" then
        config.engineTiming.itemPopulationDelayMs = 200
        config.engineTiming.itemProcessingDelayMs = 100
        config.engineTiming.lootActionDelayMs = 300
        config.engineTiming.ignoredItemDelayMs = 50
        config.engineTiming.navRetryDelayMs = 750
        config.engineTiming.combatWaitDelayMs = 2500
    else
        return false
    end
    config.save()
    return true
end

function config.resetEngineTimingToDefaults()
    config.engineTiming = {
        -- Timing settings (in milliseconds)
        tickIntervalMs = 25,
        itemPopulationDelayMs = 100,
        itemProcessingDelayMs = 50,
        ignoredItemDelayMs = 25,
        lootActionDelayMs = 200,
        navRetryDelayMs = 500,
        combatWaitDelayMs = 1500,
        
        -- Timeout settings
        maxNavTimeMs = 30000,
        pendingDecisionTimeoutMs = 30000,
        maxLootWaitTime = 5000,
        errorRecoveryDelayMs = 2000,
        maxItemProcessingTime = 10000,
        
        -- Peer coordination timing
        peerTriggerDelay = 10000
    }
    config.save()
end

-- Sync engine timing settings to SmartLootEngine
function config.syncTimingToEngine()
    local SmartLootEngine = package.loaded["modules.SmartLootEngine"]
    if SmartLootEngine and SmartLootEngine.config then
        -- Sync timing settings from persistent config to engine config
        SmartLootEngine.config.tickIntervalMs = config.engineTiming.tickIntervalMs
        SmartLootEngine.config.itemPopulationDelayMs = config.engineTiming.itemPopulationDelayMs
        SmartLootEngine.config.itemProcessingDelayMs = config.engineTiming.itemProcessingDelayMs
        SmartLootEngine.config.ignoredItemDelayMs = config.engineTiming.ignoredItemDelayMs
        SmartLootEngine.config.lootActionDelayMs = config.engineTiming.lootActionDelayMs
        SmartLootEngine.config.navRetryDelayMs = config.engineTiming.navRetryDelayMs
        SmartLootEngine.config.combatWaitDelayMs = config.engineTiming.combatWaitDelayMs
        SmartLootEngine.config.maxNavTimeMs = config.engineTiming.maxNavTimeMs
        SmartLootEngine.config.pendingDecisionTimeoutMs = config.engineTiming.pendingDecisionTimeoutMs
        SmartLootEngine.config.maxLootWaitTime = config.engineTiming.maxLootWaitTime
        SmartLootEngine.config.errorRecoveryDelayMs = config.engineTiming.errorRecoveryDelayMs
        SmartLootEngine.config.maxItemProcessingTime = config.engineTiming.maxItemProcessingTime
        SmartLootEngine.config.peerTriggerDelay = config.engineTiming.peerTriggerDelay
        return true
    end
return false
end

-- Inventory sync and setters
function config.syncInventoryToEngine()
    local Engine = package.loaded["modules.SmartLootEngine"]
    if not Engine or not Engine.config then return false end
    Engine.config.enableInventorySpaceCheck = config.inventory.enableInventorySpaceCheck and true or false
    Engine.config.minFreeInventorySlots = tonumber(config.inventory.minFreeInventorySlots) or 5
    Engine.config.autoInventoryOnLoot = config.inventory.autoInventoryOnLoot and true or false
    return true
end

function config.getInventorySettings()
    return {
        enableInventorySpaceCheck = config.inventory.enableInventorySpaceCheck and true or false,
        minFreeInventorySlots = tonumber(config.inventory.minFreeInventorySlots) or 5,
        autoInventoryOnLoot = config.inventory.autoInventoryOnLoot and true or false,
    }
end

function config.setInventoryCheck(enabled)
    config.inventory.enableInventorySpaceCheck = enabled and true or false
    config.syncInventoryToEngine()
    config.save()
    return config.inventory.enableInventorySpaceCheck
end

function config.setMinFreeInventorySlots(slots)
    slots = tonumber(slots) or config.inventory.minFreeInventorySlots or 5
    slots = math.max(1, math.min(30, slots))
    config.inventory.minFreeInventorySlots = slots
    config.syncInventoryToEngine()
    config.save()
    return slots
end

function config.setAutoInventoryOnLoot(enabled)
    config.inventory.autoInventoryOnLoot = enabled and true or false
    config.syncInventoryToEngine()
    config.save()
    return config.inventory.autoInventoryOnLoot
end

-- Speed Multiplier Functions
-- Function to apply speed multiplier to all timing settings
function config.applySpeedMultiplier(multiplier)
    -- Validate multiplier (prevent negative or extreme values)
    multiplier = math.max(0.25, math.min(4.0, multiplier))
    
    -- Store the new multiplier
    config.engineSpeed.multiplier = multiplier
    
    -- Apply multiplier to all timing settings
    for key, baseValue in pairs(config.engineSpeed.baseTiming) do
        config.engineTiming[key] = math.floor(baseValue * multiplier + 0.5)
    end
    
    -- Sync to engine
    config.syncTimingToEngine()
    config.save()
    return true
end

-- Function to get current speed multiplier
function config.getSpeedMultiplier()
    return config.engineSpeed.multiplier
end

-- Function to set speed as percentage faster/slower
-- Examples: 
--   -25 = 25% faster (multiplier = 0.75)
--   +25 = 25% slower (multiplier = 1.25)
function config.setSpeedPercentage(percentage)
    local multiplier = 1.0 + (percentage / 100)
    return config.applySpeedMultiplier(multiplier)
end

-- Function to get current speed as percentage
function config.getSpeedPercentage()
    local percentage = (config.engineSpeed.multiplier - 1.0) * 100
    return math.floor(percentage + 0.5)
end

-- Preset speed profiles
function config.applySpeedPreset(preset)
    if preset == "very_fast" then
        return config.applySpeedMultiplier(0.5)  -- 50% faster
    elseif preset == "fast" then
        return config.applySpeedMultiplier(0.75) -- 25% faster
    elseif preset == "normal" then
        return config.applySpeedMultiplier(1.0)  -- Normal speed
    elseif preset == "slow" then
        return config.applySpeedMultiplier(1.5)  -- 50% slower
    elseif preset == "very_slow" then
        return config.applySpeedMultiplier(2.0)  -- 100% slower
    else
        return false
    end
end

-- Updated debug function to show current configuration
function config.debugPrint()
    print("=== SmartLoot Configuration Debug ===")
    print("Current Server: " .. currentServerName .. " (" .. sanitizedServerName .. ")")
    print("Config File: " .. config.filePath)
    print("Global Settings:")
    print("  Loot Command Type: " .. tostring(config.lootCommandType))
    print("  Main Toon Name: " .. tostring(config.mainToonName))
    print("  Chat Output Mode: " .. tostring(config.chatOutputMode))
    print("  Chat Command: " .. tostring(config.getChatCommand() or "Silent"))
    if config.chatOutputMode == "custom" then
        print("  Custom Chat Command: " .. tostring(config.customChatCommand))
    end
    print("Chase Configuration:")
    print("  Use Chase Commands: " .. tostring(config.useChaseCommands))
    if config.useChaseCommands then
        print("  Chase Pause Command: " .. tostring(config.chasePauseCommand))
        print("  Chase Resume Command: " .. tostring(config.chaseResumeCommand))
    end
    print("Navigation Commands:")
    print("  Primary Command: " .. tostring(config.navigationCommand))
    print("  Fallback Command: " .. tostring(config.navigationFallbackCommand))
    local stopLabel = config.navigationStopCommand
    if stopLabel == nil or stopLabel == "" then
        stopLabel = "(disabled)"
    end
    print("  Stop Command: " .. tostring(stopLabel))
    print("Hotbar Configuration:")
    print("  Position: " .. config.hotbar.position.x .. ", " .. config.hotbar.position.y)
    print("  Button Size: " .. config.hotbar.buttonSize)
    print("  Alpha: " .. config.hotbar.alpha)
    print("  Vertical: " .. tostring(config.hotbar.vertical))
    print("  Use Text Labels: " .. tostring(config.hotbar.useTextLabels))
    print("  Show: " .. tostring(config.hotbar.show))
    print("Inventory Settings:")
    local inv = config.getInventorySettings()
    print("  Inventory Check: " .. tostring(inv.enableInventorySpaceCheck))
    print("  Min Free Slots: " .. tostring(inv.minFreeInventorySlots))
    print("  Auto-Inventory: " .. tostring(inv.autoInventoryOnLoot))
    print("Per-Server Settings:")
    print("  Peer Loot Order: " .. (#config.peerLootOrder > 0 and table.concat(config.peerLootOrder, ", ") or "(empty)"))
    print("All Configured Servers:")
    local servers = config.getConfiguredServers()
    for _, server in ipairs(servers) do
        local serverConfig = config.getServerConfig(server)
        local peerOrder = serverConfig.peerLootOrder or {}
        print("  " .. server .. ": " .. (#peerOrder > 0 and table.concat(peerOrder, ", ") or "(no peer order)"))
    end
end

-- Load settings when script starts
config.load()

return config
