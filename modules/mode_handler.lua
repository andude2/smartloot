-- modules/mode_handler.lua
-- Dynamic mode detection and restoration for RGMercs integration
local modeHandler = {}
local mq = require("mq")
local logging = require("modules.logging")
local config = require("modules.config")
local util = require("modules.util")

-- Mode state tracking
modeHandler.state = {
    originalMode = nil,
    currentMode = nil,
    modeStack = {},
    isRGTriggered = false,
    lastModeChange = 0,
    peerMonitoringActive = false,
    lastPeerCheck = 0,
    lastConnectedPeers = {},
}

-- Determine if current character should be RGMain based on peer order
function modeHandler.shouldBeRGMain()
    local currentToon = mq.TLO.Me.Name()
    local connectedPeers = util.getConnectedPeers()
    
    if not config.peerLootOrder or #config.peerLootOrder == 0 then
        logging.log("No peer loot order configured - defaulting to RGMain")
        return true
    end
    
    -- Find current character in peer loot order
    local currentIndex = nil
    for i, peer in ipairs(config.peerLootOrder) do
        if peer:lower() == currentToon:lower() then
            currentIndex = i
            break
        end
    end
    
    if not currentIndex then
        logging.log(string.format("Current character '%s' not found in peer loot order - defaulting to RGMain", currentToon))
        return true
    end
    
    -- Check if any higher-priority peers are connected
    for i = 1, currentIndex - 1 do
        local higherPriorityPeer = config.peerLootOrder[i]
        for _, connectedPeer in ipairs(connectedPeers) do
            if higherPriorityPeer:lower() == connectedPeer:lower() then
                logging.log(string.format("Higher priority peer '%s' is connected - should be Bacground", higherPriorityPeer))
                return false
            end
        end
    end
    
    logging.log(string.format("No higher priority peers connected - should be RGMain (position %d)", currentIndex))
    return true
end

-- Detect appropriate RG mode based on context
function modeHandler.detectRGMode()
    if modeHandler.shouldBeRGMain() then
        return "rgmain"
    else
        return "background"
    end
end

-- Handle dynamic mode setting when called by RGMercs
function modeHandler.handleRGMercsCall(args)
    logging.log("SmartLoot called by RGMercs - determining appropriate mode")
    
    -- Store current mode if we haven't already
    if not modeHandler.state.originalMode then
        modeHandler.state.originalMode = runMode
        logging.log(string.format("Stored original mode: %s", runMode))
    end
    
    -- Determine new mode based on peer hierarchy
    local newMode = modeHandler.detectRGMode()
    
    -- Set the mode
    if newMode ~= runMode then
        logging.log(string.format("RGMercs trigger: switching from %s to %s", runMode, newMode))
        modeHandler.setMode(newMode, "RGMercs call")
    else
        logging.log(string.format("RGMercs trigger: already in correct mode (%s)", newMode))
    end
    
    -- Mark as RG triggered
    modeHandler.state.isRGTriggered = true
    
    return newMode
end

function modeHandler.refreshModeBasedOnPeers()
    local currentToon = mq.TLO.Me.Name()
    local connectedPeers = util.getConnectedPeers()
    
    -- Only auto-adjust if we're in main or background mode (not RG modes)
    local currentMode = runMode
    if currentMode ~= "main" and currentMode ~= "background" then
        return false
    end
    
    local shouldBeMain = modeHandler.shouldBeRGMain()
    local needsModeChange = false
    local newMode = currentMode
    
    if shouldBeMain and currentMode ~= "main" then
        newMode = "main"
        needsModeChange = true
    elseif not shouldBeMain and currentMode ~= "background" then
        newMode = "background"
        needsModeChange = true
    end
    
    if needsModeChange then
        logging.log(string.format("Peer status changed - switching from %s to %s", currentMode, newMode))
        modeHandler.setMode(newMode, "Peer status change")
        
        -- Update the SmartLoot engine mode as well
        if _G.SmartLootEngine then
            local engineMode = newMode == "main" and SmartLootEngine.LootMode.Main or SmartLootEngine.LootMode.Background
            SmartLootEngine.setLootMode(engineMode, "Peer order change")
        end
        
        return true
    end
    
    return false
end

-- Set mode with proper tracking
function modeHandler.setMode(newMode, reason)
    local oldMode = runMode
    
    -- Push current mode onto stack for restoration
    table.insert(modeHandler.state.modeStack, {
        mode = oldMode,
        timestamp = os.time(),
        reason = reason or "manual"
    })
    
    -- Update BOTH global runMode AND mode handler state
    _G.runMode = newMode  -- Explicitly set global
    runMode = newMode     -- Local reference
    modeHandler.state.currentMode = newMode
    modeHandler.state.lastModeChange = os.time()
    
    -- Handle mode-specific initialization
    if newMode == "rgmain" then
        if _G.settings then
            _G.settings.rgMainTriggered = true
        end
        logging.log("Switched to RGMain mode - ready for main looter duties")
    elseif newMode == "background" then
        logging.log("Switched to Background mode - ready for peer coordination")
    end
    
    logging.log(string.format("Mode changed: %s -> %s (%s)", oldMode, newMode, reason or "unknown"))
    
    return true
end

-- Restore previous mode from stack
function modeHandler.restorePreviousMode(reason)
    if #modeHandler.state.modeStack == 0 then
        logging.log("No previous mode to restore")
        return false
    end
    
    local previousState = table.remove(modeHandler.state.modeStack)
    local oldMode = runMode
    
    -- Update BOTH global and local references
    _G.runMode = previousState.mode
    runMode = previousState.mode
    modeHandler.state.currentMode = previousState.mode
    modeHandler.state.lastModeChange = os.time()
    
    logging.log(string.format("Restored mode: %s -> %s (%s)", oldMode, previousState.mode, reason or "completion"))
    
    -- Handle mode-specific cleanup
    if oldMode == "rgmain" or oldMode == "rgonce" then
        modeHandler.state.isRGTriggered = false
        if _G.settings then
            _G.settings.rgMainTriggered = false
        end
    end
    
    return true
end

-- Restore original mode (clear entire stack)
function modeHandler.restoreOriginalMode(reason)
    if not modeHandler.state.originalMode then
        logging.log("No original mode stored to restore")
        return false
    end
    
    local oldMode = runMode
    
    -- Update BOTH global and local references
    _G.runMode = modeHandler.state.originalMode
    runMode = modeHandler.state.originalMode
    modeHandler.state.currentMode = modeHandler.state.originalMode
    modeHandler.state.lastModeChange = os.time()
    
    -- Clear state
    modeHandler.state.modeStack = {}
    modeHandler.state.isRGTriggered = false
    modeHandler.state.originalMode = nil
    
    if _G.settings then
        _G.settings.rgMainTriggered = false
    end
    
    logging.log(string.format("Restored original mode: %s -> %s (%s)", oldMode, runMode, reason or "reset"))
    
    return true
end

-- Handle completion of RG cycle
function modeHandler.handleRGCycleComplete()
    if not modeHandler.state.isRGTriggered then
        return false
    end
    
    local wasRGMain = (runMode == "rgmain")
    local wasRGOnce = (runMode == "background")
    
    if wasRGMain then
        -- Stay in RGMain mode, just reset trigger
        modeHandler.state.isRGTriggered = false
        if settings then
            settings.rgMainTriggered = false
        end
        logging.log("RGMain cycle complete - staying in RGMain mode")
        return true
    elseif wasRGOnce then
        -- Return to previous mode (likely background)
        modeHandler.restorePreviousMode("RGOnce cycle complete")
        return true
    end
    
    return false
end

-- Check if we're currently in an RG mode
function modeHandler.isInRGMode()
    return runMode == "rgmain" or runMode == "rgonce"
end

-- Check if we're triggered and active
function modeHandler.isRGActive()
    return modeHandler.state.isRGTriggered and modeHandler.isInRGMode()
end

-- Get current mode information
function modeHandler.getModeInfo()
    return {
        currentMode = runMode,
        originalMode = modeHandler.state.originalMode,
        isRGTriggered = modeHandler.state.isRGTriggered,
        isRGActive = modeHandler.isRGActive(),
        stackDepth = #modeHandler.state.modeStack,
        lastModeChange = modeHandler.state.lastModeChange
    }
end

-- Get a summary of current peer status for debugging
function modeHandler.getPeerStatus()
    local currentToon = mq.TLO.Me.Name()
    local connectedPeers = util.getConnectedPeers()
    local shouldBeMain = modeHandler.shouldBeRGMain()
    
    -- Get current mode from global or fallback to original mode
    local currentMode = _G.runMode or modeHandler.state.originalMode or modeHandler.state.currentMode or "unknown"
    
    local status = {
        currentCharacter = currentToon,
        connectedPeers = connectedPeers,
        peerLootOrder = config.peerLootOrder or {},
        shouldBeMain = shouldBeMain,
        currentMode = currentMode,
        recommendedMode = shouldBeMain and "main" or "background"
    }
    
    return status
end

-- Debug function to show mode stack
function modeHandler.debugModeStack()
    logging.log("=== Mode Handler Debug ===")
    logging.log("Current Mode: " .. tostring(runMode))
    logging.log("Original Mode: " .. tostring(modeHandler.state.originalMode))
    logging.log("RG Triggered: " .. tostring(modeHandler.state.isRGTriggered))
    logging.log("Stack Depth: " .. tostring(#modeHandler.state.modeStack))
    
    for i, state in ipairs(modeHandler.state.modeStack) do
        logging.log(string.format("  Stack[%d]: %s (%s) at %s", 
            i, state.mode, state.reason, os.date("%H:%M:%S", state.timestamp)))
    end
end

-- Print detailed peer status for debugging
function modeHandler.debugPeerStatus()
    local status = modeHandler.getPeerStatus()
    
    logging.log("=== Peer Status Debug ===")
    logging.log("Current Character: " .. status.currentCharacter)
    logging.log("Current Mode: " .. status.currentMode)
    logging.log("Should Be Main: " .. tostring(status.shouldBeMain))
    logging.log("Recommended Mode: " .. status.recommendedMode)
    
    logging.log("Configured Peer Order:")
    for i, peer in ipairs(status.peerLootOrder) do
        local isConnected = false
        for _, connectedPeer in ipairs(status.connectedPeers) do
            if peer:lower() == connectedPeer:lower() then
                isConnected = true
                break
            end
        end
        local isCurrent = peer:lower() == status.currentCharacter:lower()
        local marker = isCurrent and " <-- CURRENT" or ""
        local connectionStatus = isConnected and " [CONNECTED]" or " [OFFLINE]"
        logging.log(string.format("  %d. %s%s%s", i, peer, connectionStatus, marker))
    end
    
    logging.log("Connected Peers:")
    for _, peer in ipairs(status.connectedPeers) do
        logging.log("  - " .. peer)
    end
end

-- Monitor for peer connections/disconnections and auto-adjust mode
function modeHandler.startPeerMonitoring()
    if modeHandler.state.peerMonitoringActive then
        return false
    end
    
    modeHandler.state.peerMonitoringActive = true
    modeHandler.state.lastPeerCheck = mq.gettime()
    modeHandler.state.lastConnectedPeers = util.getConnectedPeers()
    
    logging.log("Started peer monitoring for dynamic mode switching")
    return true
end

function modeHandler.stopPeerMonitoring()
    modeHandler.state.peerMonitoringActive = false
    logging.log("Stopped peer monitoring")
end

-- Check for peer changes (call this periodically from main loop)
function modeHandler.checkPeerChanges()
    if not modeHandler.state.peerMonitoringActive then
        return false
    end
    
    local now = mq.gettime()
    local checkInterval = 5000 -- Check every 5 seconds
    
    if now - modeHandler.state.lastPeerCheck < checkInterval then
        return false
    end
    
    modeHandler.state.lastPeerCheck = now
    local currentPeers = util.getConnectedPeers()
    local lastPeers = modeHandler.state.lastConnectedPeers or {}
    
    -- Check if peer list changed
    local peersChanged = false
    if #currentPeers ~= #lastPeers then
        peersChanged = true
    else
        for _, peer in ipairs(currentPeers) do
            local found = false
            for _, lastPeer in ipairs(lastPeers) do
                if peer:lower() == lastPeer:lower() then
                    found = true
                    break
                end
            end
            if not found then
                peersChanged = true
                break
            end
        end
    end
    
    if peersChanged then
        logging.log("Peer connection changes detected")
        modeHandler.state.lastConnectedPeers = currentPeers
        
        -- Refresh mode based on new peer status
        local modeChanged = modeHandler.refreshModeBasedOnPeers()
        if modeChanged then
            logging.log("Mode automatically adjusted due to peer changes")
        end
        
        return true
    end
    
    return false
end


-- Initialize mode handler
function modeHandler.initialize(currentMode)
    modeHandler.state.currentMode = currentMode
    modeHandler.state.originalMode = currentMode
    logging.log("Mode handler initialized with mode: " .. currentMode)
end

-- Reset all mode state (for emergencies)
function modeHandler.reset()
    local oldMode = runMode
    
    if modeHandler.state.originalMode then
        _G.runMode = modeHandler.state.originalMode
        runMode = modeHandler.state.originalMode
    end
    
    modeHandler.state = {
        originalMode = nil,
        currentMode = runMode,
        modeStack = {},
        isRGTriggered = false,
        lastModeChange = os.time(),
        peerMonitoringActive = false,
        lastPeerCheck = 0,
        lastConnectedPeers = {},
    }
    
    if _G.settings then
        _G.settings.rgMainTriggered = false
    end
    
    logging.log(string.format("Mode handler reset: %s -> %s", oldMode, runMode))
end

return modeHandler