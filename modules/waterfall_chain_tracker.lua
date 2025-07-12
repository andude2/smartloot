-- modules/waterfall_chain_tracker.lua - Tracks peer loot waterfall chains
local WaterfallChainTracker = {}
local mq = require("mq")
local logging = require("modules.logging")
local util = require("modules.util")
local json = require("dkjson")
local actors = require("actors")

-- ============================================================================
-- WATERFALL CHAIN STATE
-- ============================================================================

WaterfallChainTracker.state = {
    -- My role in the chain
    isMainLooter = false,
    triggeredByMain = nil,  -- Who triggered me (if I'm background)
    
    -- Peers I've triggered (if I'm main)
    triggeredPeers = {},
    
    -- Waterfall completion tracking
    activePeerSessions = {},  -- peer_name -> session_id
    completedPeerSessions = {},  -- session_id -> completion_data
    
    -- Session tracking
    currentSessionId = nil,
    sessionStartTime = 0,
    
    -- Chain metrics
    totalPeersInChain = 0,
    completedPeersInChain = 0,
    
    -- Timeout settings
    peerResponseTimeoutMs = 60000,  -- 1 minute
    chainCompletionTimeoutMs = 300000,  -- 5 minutes
}

-- ============================================================================
-- SESSION MANAGEMENT
-- ============================================================================

function WaterfallChainTracker.generateSessionId()
    local toonName = mq.TLO.Me.Name() or "unknown"
    local timestamp = mq.gettime()
    return string.format("%s_%d", toonName, timestamp)
end

function WaterfallChainTracker.startMainSession(mode)
    WaterfallChainTracker.state.isMainLooter = true
    WaterfallChainTracker.state.triggeredByMain = nil
    WaterfallChainTracker.state.currentSessionId = WaterfallChainTracker.generateSessionId()
    WaterfallChainTracker.state.sessionStartTime = mq.gettime()
    WaterfallChainTracker.state.triggeredPeers = {}
    WaterfallChainTracker.state.activePeerSessions = {}
    WaterfallChainTracker.state.completedPeerSessions = {}
    WaterfallChainTracker.state.totalPeersInChain = 0
    WaterfallChainTracker.state.completedPeersInChain = 0
    
    logging.debug(string.format("[Waterfall] Started main session: %s (mode: %s)", 
                WaterfallChainTracker.state.currentSessionId, mode))
end

function WaterfallChainTracker.startBackgroundSession(triggeredBy, sessionId)
    WaterfallChainTracker.state.isMainLooter = false
    WaterfallChainTracker.state.triggeredByMain = triggeredBy
    WaterfallChainTracker.state.currentSessionId = sessionId or WaterfallChainTracker.generateSessionId()
    WaterfallChainTracker.state.sessionStartTime = mq.gettime()
    WaterfallChainTracker.state.triggeredPeers = {}
    WaterfallChainTracker.state.activePeerSessions = {}
    WaterfallChainTracker.state.completedPeerSessions = {}
    WaterfallChainTracker.state.totalPeersInChain = 0
    WaterfallChainTracker.state.completedPeersInChain = 0
    
    logging.debug(string.format("[Waterfall] Started background session: %s (triggered by: %s)", 
                WaterfallChainTracker.state.currentSessionId, triggeredBy))
end

function WaterfallChainTracker.endSession()
    local sessionId = WaterfallChainTracker.state.currentSessionId
    local isMain = WaterfallChainTracker.state.isMainLooter
    local triggeredBy = WaterfallChainTracker.state.triggeredByMain
    
    -- Clear state
    WaterfallChainTracker.state.isMainLooter = false
    WaterfallChainTracker.state.triggeredByMain = nil
    WaterfallChainTracker.state.currentSessionId = nil
    WaterfallChainTracker.state.sessionStartTime = 0
    WaterfallChainTracker.state.triggeredPeers = {}
    WaterfallChainTracker.state.activePeerSessions = {}
    WaterfallChainTracker.state.completedPeerSessions = {}
    WaterfallChainTracker.state.totalPeersInChain = 0
    WaterfallChainTracker.state.completedPeersInChain = 0
    
    logging.debug(string.format("[Waterfall] Ended session: %s (was main: %s)", 
                sessionId, tostring(isMain)))
    
    return {
        sessionId = sessionId,
        isMain = isMain,
        triggeredBy = triggeredBy
    }
end

-- ============================================================================
-- PEER TRACKING
-- ============================================================================

function WaterfallChainTracker.registerPeerTrigger(peerName, peerSessionId)
    local now = mq.gettime()
    if not WaterfallChainTracker.state.currentSessionId then
        logging.debug("[Waterfall] No active session - cannot register peer trigger")
        return false
    end
    
    -- Add to triggered peers list
    table.insert(WaterfallChainTracker.state.triggeredPeers, {
        name = peerName,
        sessionId = peerSessionId,
        triggerTime = mq.gettime()
    })
    
    -- Track active session
    WaterfallChainTracker.state.activePeerSessions[peerName] = peerSessionId
    WaterfallChainTracker.state.totalPeersInChain = WaterfallChainTracker.state.totalPeersInChain + 1
    
    logging.debug(string.format("[Waterfall] Registered peer trigger: %s (session: %s)", 
                peerName, peerSessionId))
    
    -- Send session tracking info to peer
    local sessionStartMessage = {
        cmd = "waterfall_session_start",
        mainSessionId = WaterfallChainTracker.state.currentSessionId,
        peerSessionId = peerSessionId,
        triggeredBy = mq.TLO.Me.Name(),
        isMainLooter = WaterfallChainTracker.state.isMainLooter,
        triggerTime = now
    }
    
    local success = WaterfallChainTracker.sendToPeer(peerName, sessionStartMessage)
    if not success then
        logging.debug(string.format("[Waterfall] Failed to send session start to %s - removing from triggered list", peerName))
        -- Remove from triggered peers if we can't contact them
        for i = #WaterfallChainTracker.state.triggeredPeers, 1, -1 do
            if WaterfallChainTracker.state.triggeredPeers[i].name == peerName then
                table.remove(WaterfallChainTracker.state.triggeredPeers, i)
                break
            end
        end
        WaterfallChainTracker.state.activePeerSessions[peerName] = nil
        WaterfallChainTracker.state.totalPeersInChain = WaterfallChainTracker.state.totalPeersInChain - 1
        return false
    end
    
    return true
end

function WaterfallChainTracker.registerPeerCompletion(peerName, peerSessionId, completionData)
    if not WaterfallChainTracker.state.currentSessionId then
        logging.debug("[Waterfall] No active session - ignoring peer completion")
        return false
    end
    
    -- Verify this peer was triggered by us
    local wasTriggered = false
    local peerTriggerTime = 0
    for _, peer in ipairs(WaterfallChainTracker.state.triggeredPeers) do
        if peer.name == peerName and peer.sessionId == peerSessionId then
            wasTriggered = true
            peerTriggerTime = peer.triggerTime
            break
        end
    end
    
    if not wasTriggered then
        logging.debug(string.format("[Waterfall] Peer %s completion ignored - not in our triggered list (session: %s)", peerName, peerSessionId))
        return false
    end
    
    -- Check if this peer was already completed
    if WaterfallChainTracker.state.completedPeerSessions[peerSessionId] then
        logging.debug(string.format("[Waterfall] Peer %s completion ignored - already marked complete", peerName))
        return false
    end
    
    -- Mark as completed
    WaterfallChainTracker.state.completedPeerSessions[peerSessionId] = {
        peerName = peerName,
        completionTime = mq.gettime(),
        data = completionData or {}
    }
    
    -- Remove from active sessions
    WaterfallChainTracker.state.activePeerSessions[peerName] = nil
    WaterfallChainTracker.state.completedPeersInChain = WaterfallChainTracker.state.completedPeersInChain + 1
    
    logging.debug(string.format("[Waterfall] Peer completion registered: %s (session: %s) [%d/%d]", 
                peerName, peerSessionId, 
                WaterfallChainTracker.state.completedPeersInChain, 
                WaterfallChainTracker.state.totalPeersInChain))
    
    return true
end

-- ============================================================================
-- WATERFALL COMPLETION DETECTION
-- ============================================================================

function WaterfallChainTracker.isWaterfallComplete()
    if not WaterfallChainTracker.state.currentSessionId then
        return false
    end
    
    -- Check if all triggered peers have completed
    local allPeersCompleted = (WaterfallChainTracker.state.completedPeersInChain >= WaterfallChainTracker.state.totalPeersInChain)
    
    -- Check for timeouts
    local now = mq.gettime()
    local hasTimedOutPeers = false
    
    for peerName, sessionId in pairs(WaterfallChainTracker.state.activePeerSessions) do
        -- Find the trigger time for this peer
        local triggerTime = now
        for _, peer in ipairs(WaterfallChainTracker.state.triggeredPeers) do
            if peer.name == peerName and peer.sessionId == sessionId then
                triggerTime = peer.triggerTime
                break
            end
        end
        
        if (now - triggerTime) > WaterfallChainTracker.state.peerResponseTimeoutMs then
            logging.debug(string.format("[Waterfall] Peer %s timed out (session: %s)", peerName, sessionId))
            hasTimedOutPeers = true
            
            -- Mark as completed with timeout
            WaterfallChainTracker.state.completedPeerSessions[sessionId] = {
                peerName = peerName,
                completionTime = now,
                data = { timeout = true }
            }
            WaterfallChainTracker.state.activePeerSessions[peerName] = nil
            WaterfallChainTracker.state.completedPeersInChain = WaterfallChainTracker.state.completedPeersInChain + 1
        end
    end
    
    -- Recalculate completion status
    allPeersCompleted = (WaterfallChainTracker.state.completedPeersInChain >= WaterfallChainTracker.state.totalPeersInChain)
    
    return allPeersCompleted
end

function WaterfallChainTracker.notifyWaterfallComplete()
    if not WaterfallChainTracker.state.currentSessionId then
        return false
    end
    
    local sessionData = {
        sessionId = WaterfallChainTracker.state.currentSessionId,
        isMainLooter = WaterfallChainTracker.state.isMainLooter,
        triggeredBy = WaterfallChainTracker.state.triggeredByMain,
        totalPeers = WaterfallChainTracker.state.totalPeersInChain,
        completedPeers = WaterfallChainTracker.state.completedPeersInChain,
        sessionDuration = mq.gettime() - WaterfallChainTracker.state.sessionStartTime
    }
    
    if WaterfallChainTracker.state.isMainLooter then
        -- I'm the main looter - notify RGMercs that the entire waterfall is complete
        logging.debug(string.format("[Waterfall] Main session complete: %s (%d peers processed)", 
                    sessionData.sessionId, sessionData.completedPeers))
        
        --[[Send completion announcement
        local util = require("modules.util")
        if util and util.sendGroupMessage then
            util.sendGroupMessage(string.format("Waterfall loot chain completed - %d peers participated", sessionData.completedPeers))
        end]]
        
        -- Send to RGMercs if available
        local SmartLootEngine = require("modules.SmartLootEngine")
        SmartLootEngine.notifyRGMercsComplete()
        
    else
        -- I'm a background looter - notify the main looter that my waterfall is complete
        if WaterfallChainTracker.state.triggeredByMain then
            logging.debug(string.format("[Waterfall] Background session complete: %s (notifying main: %s)", 
                        sessionData.sessionId, WaterfallChainTracker.state.triggeredByMain))
            
            WaterfallChainTracker.sendToPeer(WaterfallChainTracker.state.triggeredByMain, {
                cmd = "waterfall_completion",
                sessionId = WaterfallChainTracker.state.currentSessionId,
                peerName = mq.TLO.Me.Name(),
                completionData = sessionData
            })
        end
    end
    
    return true
end

-- ============================================================================
-- COMMUNICATION
-- ============================================================================

function WaterfallChainTracker.sendToPeer(peerName, messageData)
    messageData.sender = mq.TLO.Me.Name()
    messageData.timestamp = mq.gettime()
    
    local success, err = pcall(function()
        actors.send(peerName .. "_smartloot_mailbox", json.encode(messageData))
    end)
    
    if not success then
        logging.debug(string.format("[Waterfall] Failed to send message to %s: %s", peerName, tostring(err)))
        return false
    end
    
    logging.debug(string.format("[Waterfall] Sent message to %s: %s", peerName, messageData.cmd))
    return true
end

function WaterfallChainTracker.handleMailboxMessage(data)
    local cmd = data.cmd
    local sender = data.sender or "Unknown"
    
    if cmd == "waterfall_session_start" then
        -- A main/background looter is starting a session and telling me about it
        local mainSessionId = data.mainSessionId
        local peerSessionId = data.peerSessionId
        local triggeredBy = data.triggeredBy
        local isMainLooter = data.isMainLooter
        
        logging.debug(string.format("[Waterfall] Received session start from %s (main session: %s, peer session: %s)", 
                    sender, mainSessionId, peerSessionId))
        
        -- Store the session context
        WaterfallChainTracker.startBackgroundSession(triggeredBy, peerSessionId)
        
    elseif cmd == "waterfall_completion" then
        -- A peer is notifying me that their waterfall is complete
        local peerSessionId = data.sessionId
        local peerName = data.peerName
        local completionData = data.completionData
        
        logging.debug(string.format("[Waterfall] Received completion from %s (session: %s)", peerName, peerSessionId))
        
        local registered = WaterfallChainTracker.registerPeerCompletion(peerName, peerSessionId, completionData)
        
        if registered then
            logging.debug(string.format("[Waterfall] Peer completion registered: %s [%d/%d peers complete]", 
                        peerName, 
                        WaterfallChainTracker.state.completedPeersInChain, 
                        WaterfallChainTracker.state.totalPeersInChain))
        else
            logging.debug(string.format("[Waterfall] Peer completion rejected: %s (not in triggered list)", peerName))
        end
        
    elseif cmd == "waterfall_status_request" then
        -- Someone is asking for my waterfall status
        local responseData = {
            cmd = "waterfall_status_response",
            sender = mq.TLO.Me.Name(),
            target = sender,
            currentSessionId = WaterfallChainTracker.state.currentSessionId,
            isMainLooter = WaterfallChainTracker.state.isMainLooter,
            triggeredBy = WaterfallChainTracker.state.triggeredByMain,
            activePeers = table.getn(WaterfallChainTracker.state.activePeerSessions),
            completedPeers = WaterfallChainTracker.state.completedPeersInChain,
            totalPeers = WaterfallChainTracker.state.totalPeersInChain
        }
        
        WaterfallChainTracker.sendToPeer(sender, responseData)
    end
end

-- ============================================================================
-- INTEGRATION FUNCTIONS
-- ============================================================================

function WaterfallChainTracker.onLootSessionStart(mode)
    -- Called when SmartLootEngine starts a loot session
    if mode == "main" or mode == "once" or mode == "rgmain" or mode == "rgonce" then
        WaterfallChainTracker.startMainSession(mode)
    end
end

function WaterfallChainTracker.onPeerTriggered(peerName)
    -- Called when SmartLootEngine triggers a peer
    if WaterfallChainTracker.state.currentSessionId then
        local peerSessionId = WaterfallChainTracker.generateSessionId() .. "_" .. peerName
        return WaterfallChainTracker.registerPeerTrigger(peerName, peerSessionId)
    end
    return false
end

function WaterfallChainTracker.onLootSessionEnd()
    -- Called when SmartLootEngine completes local looting
    if not WaterfallChainTracker.state.currentSessionId then
        return false
    end
    
    -- If I'm a background looter, report completion to the main looter
    if not WaterfallChainTracker.state.isMainLooter and WaterfallChainTracker.state.triggeredByMain then
        logging.debug(string.format("[Waterfall] Background session complete - reporting to main looter: %s", 
                    WaterfallChainTracker.state.triggeredByMain))
        
        local completionData = {
            sessionDuration = mq.gettime() - WaterfallChainTracker.state.sessionStartTime,
            itemsProcessed = 0, -- Could add stats here if needed
            status = "completed"
        }
        
        WaterfallChainTracker.sendToPeer(WaterfallChainTracker.state.triggeredByMain, {
            cmd = "waterfall_completion",
            sessionId = WaterfallChainTracker.state.currentSessionId,
            peerName = mq.TLO.Me.Name(),
            completionData = completionData
        })
        
        -- End my session immediately after reporting
        WaterfallChainTracker.endSession()
        return true
    end
    
    -- If I'm the main looter, check if waterfall is complete
    if WaterfallChainTracker.isWaterfallComplete() then
        WaterfallChainTracker.notifyWaterfallComplete()
        WaterfallChainTracker.endSession()
        return true
    else
        logging.debug(string.format("[Waterfall] Main looter waiting for %d peers to finish", 
                    WaterfallChainTracker.state.totalPeersInChain - WaterfallChainTracker.state.completedPeersInChain))
        return false
    end
end

function WaterfallChainTracker.checkWaterfallProgress()
    -- Called periodically to check for waterfall completion
    if not WaterfallChainTracker.state.currentSessionId then
        return false
    end
    
    -- Only the main looter should actively check for waterfall completion
    if not WaterfallChainTracker.state.isMainLooter then
        return false
    end
    
    if WaterfallChainTracker.isWaterfallComplete() then
        logging.debug(string.format("[Waterfall] Waterfall chain complete: %d/%d peers finished", 
                    WaterfallChainTracker.state.completedPeersInChain, 
                    WaterfallChainTracker.state.totalPeersInChain))
        WaterfallChainTracker.notifyWaterfallComplete()
        WaterfallChainTracker.endSession()
        return true
    end
    
    return false
end

-- ============================================================================
-- STATUS AND DEBUG
-- ============================================================================

function WaterfallChainTracker.getStatus()
    return {
        hasActiveSession = WaterfallChainTracker.state.currentSessionId ~= nil,
        sessionId = WaterfallChainTracker.state.currentSessionId,
        isMainLooter = WaterfallChainTracker.state.isMainLooter,
        triggeredBy = WaterfallChainTracker.state.triggeredByMain,
        totalPeers = WaterfallChainTracker.state.totalPeersInChain,
        completedPeers = WaterfallChainTracker.state.completedPeersInChain,
        activePeers = {},
        sessionDuration = WaterfallChainTracker.state.sessionStartTime > 0 and 
                         (mq.gettime() - WaterfallChainTracker.state.sessionStartTime) or 0
    }
end

function WaterfallChainTracker.printStatus()
    local status = WaterfallChainTracker.getStatus()
    
    if not status.hasActiveSession then
        util.printSmartLoot("No active waterfall session", "info")
        return
    end
    
    util.printSmartLoot("=== Waterfall Chain Status ===", "system")
    util.printSmartLoot("Session ID: " .. (status.sessionId or "None"), "info")
    util.printSmartLoot("Role: " .. (status.isMainLooter and "Main Looter" or "Background Looter"), "info")
    if status.triggeredBy then
        util.printSmartLoot("Triggered By: " .. status.triggeredBy, "info")
    end
    util.printSmartLoot(string.format("Peers: %d completed / %d total", status.completedPeers, status.totalPeers), "info")
    util.printSmartLoot(string.format("Duration: %.1fs", status.sessionDuration / 1000), "info")
    
    if WaterfallChainTracker.state.activePeerSessions then
        for peerName, sessionId in pairs(WaterfallChainTracker.state.activePeerSessions) do
            -- Find the trigger time for this peer
            local triggerTime = 0
            for _, peer in ipairs(WaterfallChainTracker.state.triggeredPeers) do
                if peer.name == peerName and peer.sessionId == sessionId then
                    triggerTime = peer.triggerTime
                    break
                end
            end
            
            local waitTime = triggerTime > 0 and (mq.gettime() - triggerTime) / 1000 or 0
            util.printSmartLoot(string.format("  Active: %s (%.1fs waiting)", peerName, waitTime), "info")
        end
    end
    
    if WaterfallChainTracker.state.completedPeerSessions then
        for sessionId, completion in pairs(WaterfallChainTracker.state.completedPeerSessions) do
            local completionTime = completion.completionTime or 0
            local timeTaken = completionTime > 0 and (completionTime - WaterfallChainTracker.state.sessionStartTime) / 1000 or 0
            local status = completion.data and completion.data.timeout and "(timeout)" or "(completed)"
            util.printSmartLoot(string.format("  Completed: %s %.1fs %s", completion.peerName, timeTaken, status), "info")
        end
    end
end

return WaterfallChainTracker