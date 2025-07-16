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
config.mainToonName = mq.TLO.Me.Name() or "MainToon"  -- Default to current character name
config.lootDelay = 5      -- Delay in seconds before background bots try to loot
config.retryCount = 3     -- Number of retry attempts for background bots
config.retryDelay = 5     -- Delay between retry attempts in seconds

-- NEW: Chat output configuration
config.chatOutputMode = "group"  -- Default to group chat
config.customChatCommand = "/say"  -- Default custom command if mode is "custom"

-- NEW: Item announce configuration
config.itemAnnounceMode = "all"  -- Options: "all", "ignored", "none"

-- NEW: Farming mode configuration
config.farmingMode = false  -- Whether farming mode is active (bypasses corpse deduplication)

-- Default settings additions (add to existing defaults)
config.useChaseCommands = false  -- Whether to use chase commands at all
config.chasePauseCommand = "/luachase pause on"  -- Command to pause chase
config.chaseResumeCommand = "/luachase pause off"  -- Command to resume chase

-- NEW: Hotbar configuration
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

-- NEW: SmartLoot Engine Speed Configuration
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

-- NEW: SmartLoot Engine Timing configuration (computed from speed settings)
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
        mainToonName = config.mainToonName,
        lootDelay = config.lootDelay,
        retryCount = config.retryCount,
        retryDelay = config.retryDelay,
        -- NEW: Chat configuration in global settings
        chatOutputMode = config.chatOutputMode,
        customChatCommand = config.customChatCommand,
        -- NEW: Item announce configuration in global settings
        itemAnnounceMode = config.itemAnnounceMode,
        -- NEW: Farming mode configuration in global settings
        farmingMode = config.farmingMode,
        -- NEW: Chase command configuration
        useChaseCommands = config.useChaseCommands,
        chasePauseCommand = config.chasePauseCommand,
        chaseResumeCommand = config.chaseResumeCommand,
        -- NEW: Hotbar configuration in global settings
        hotbar = config.hotbar,
        -- NEW: Engine timing configuration in global settings
        engineTiming = config.engineTiming,
        -- NEW: Engine speed configuration in global settings
        engineSpeed = config.engineSpeed,
    },
    servers = {}
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
            
            -- NEW: Apply chat settings
            config.chatOutputMode = configData.global.chatOutputMode or config.chatOutputMode
            config.customChatCommand = configData.global.customChatCommand or config.customChatCommand
            -- NEW: Apply item announce settings
            config.itemAnnounceMode = configData.global.itemAnnounceMode or config.itemAnnounceMode
            -- NEW: Apply farming mode settings
            config.farmingMode = configData.global.farmingMode or config.farmingMode
            config.useChaseCommands = configData.global.useChaseCommands or config.useChaseCommands
            config.chasePauseCommand = configData.global.chasePauseCommand or config.chasePauseCommand
            config.chaseResumeCommand = configData.global.chaseResumeCommand or config.chaseResumeCommand
            
            -- NEW: Apply hotbar settings
            if configData.global.hotbar then
                config.hotbar = configData.global.hotbar
            end
            
            -- NEW: Apply engine timing settings
            if configData.global.engineTiming then
                config.engineTiming = configData.global.engineTiming
            end
            
            -- NEW: Apply engine speed settings
            if configData.global.engineSpeed then
                config.engineSpeed = configData.global.engineSpeed
            end
            
            -- Apply per-server settings
            local serverConfig = configData.servers[sanitizedServerName] or {}
            config.peerLootOrder = serverConfig.peerLootOrder or {}
        end
    else
        -- No config file exists, initialize with defaults
        configData.servers[sanitizedServerName] = {
            peerLootOrder = {}
        }
        -- Set default chat settings
        configData.global.chatOutputMode = config.chatOutputMode
        configData.global.customChatCommand = config.customChatCommand
    end
end

-- Save function to store configuration
function config.save()
    -- Update internal structure with current values
    configData.global.lootCommandType = config.lootCommandType
    configData.global.mainToonName = config.mainToonName
    configData.global.lootDelay = config.lootDelay
    configData.global.retryCount = config.retryCount
    configData.global.retryDelay = config.retryDelay
    
    -- NEW: Update chat settings
    configData.global.chatOutputMode = config.chatOutputMode
    configData.global.customChatCommand = config.customChatCommand
    -- NEW: Update item announce settings
    configData.global.itemAnnounceMode = config.itemAnnounceMode
    -- NEW: Update farming mode settings
    configData.global.farmingMode = config.farmingMode
    configData.global.useChaseCommands = config.useChaseCommands
    configData.global.chasePauseCommand = config.chasePauseCommand
    configData.global.chaseResumeCommand = config.chaseResumeCommand
    
    -- NEW: Update hotbar settings
    configData.global.hotbar = config.hotbar
    
    -- NEW: Update engine timing settings
    configData.global.engineTiming = config.engineTiming
    
    -- NEW: Update engine speed settings
    configData.global.engineSpeed = config.engineSpeed
    
    -- Ensure server config exists
    if not configData.servers[sanitizedServerName] then
        configData.servers[sanitizedServerName] = {}
    end
    
    -- Update server-specific settings
    configData.servers[sanitizedServerName].peerLootOrder = config.peerLootOrder
    
    local file = io.open(config.filePath, "w")
    if file then
        file:write(json.encode(configData, { indent = true }))
        file:close()
        return true
    else
        return false
    end
end

-- NEW: Chat output helper functions
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

-- NEW: Item announce helper functions
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

-- NEW: Farming mode helper functions
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

-- NEW: Hotbar configuration helper functions
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

-- NEW: Engine Timing configuration helper functions
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
    local SmartLootEngine = require("modules.SmartLootEngine")
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

-- NEW: Speed Multiplier Functions
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
    print("Hotbar Configuration:")
    print("  Position: " .. config.hotbar.position.x .. ", " .. config.hotbar.position.y)
    print("  Button Size: " .. config.hotbar.buttonSize)
    print("  Alpha: " .. config.hotbar.alpha)
    print("  Vertical: " .. tostring(config.hotbar.vertical))
    print("  Use Text Labels: " .. tostring(config.hotbar.useTextLabels))
    print("  Show: " .. tostring(config.hotbar.show))
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