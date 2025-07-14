-- modules/SmartLootEngine.lua - FULLY INTEGRATED STATE MACHINE
local SmartLootEngine = {}
local mq = require("mq")
local logging = require("modules.logging")
local database = require("modules.database")
local lootHistory = require("modules.loot_history")
local lootStats = require("modules.loot_stats")
local config = require("modules.config")
local util = require("modules.util")
local waterfallTracker = require("modules.waterfall_chain_tracker")
local json = require("dkjson")
local actors = require ("actors")
local tempRules = require("modules.temp_rules")

-- ============================================================================
-- STATE MACHINE DEFINITIONS
-- ============================================================================

-- Engine States
SmartLootEngine.LootState = {
    Idle = 1,
    FindingCorpse = 2,
    NavigatingToCorpse = 3,
    OpeningLootWindow = 4,
    ProcessingItems = 5,
    WaitingForPendingDecision = 6,
    ExecutingLootAction = 7,
    CleaningUpCorpse = 8,
    ProcessingPeers = 9,
    OnceModeCompletion = 10,
    CombatDetected = 11,
    EmergencyStop = 12,
    WaitingForWaterfallCompletion = 13,
}

-- Engine Modes (compatible with existing system)
SmartLootEngine.LootMode = {
    Idle = "idle",
    Main = "main",
    Once = "once", 
    Background = "background",
    RGMain = "rgmain",
    RGOnce = "rgonce",
    Disabled = "disabled"
}

-- Loot Action Types
SmartLootEngine.LootAction = {
    None = 0,
    Loot = 1,
    Destroy = 2,
    Ignore = 3,
    Skip = 4
}

-- ============================================================================
-- ENGINE STATE
-- ============================================================================

SmartLootEngine.state = {
    -- Core state machine
    currentState = SmartLootEngine.LootState.Idle,
    mode = SmartLootEngine.LootMode.Background,
    nextActionTime = 0,
    
    -- Current processing context
    currentCorpseID = 0,
    currentCorpseSpawnID = 0,
    currentCorpseName = "",
    currentCorpseDistance = 0,
    currentItemIndex = 0,
    totalItemsOnCorpse = 0,
    
    -- Navigation state
    navStartTime = 0,
    navTargetX = 0,
    navTargetY = 0,
    navTargetZ = 0,
    openLootAttempts = 0,
    navWarningAnnounced = false,
    
    -- Current item processing
    currentItem = {
        name = "",
        itemID = 0,
        iconID = 0,
        quantity = 1,
        slot = 0,
        rule = "",
        action = SmartLootEngine.LootAction.None
    },
    
    -- Loot action execution
    lootActionInProgress = false,
    lootActionStartTime = 0,
    lootActionType = SmartLootEngine.LootAction.None,
    lootActionTimeoutMs = 5000,
    
    -- Decision state
    needsPendingDecision = false,
    pendingDecisionStartTime = 0,
    pendingDecisionTimeoutMs = 30000,
    
    -- Session tracking
    processedCorpsesThisSession = {},
    ignoredItemsThisSession = {},
    recordedDropsThisSession = {},
    sessionCorpseCount = 0,
    
    -- Target preservation for RGMercs integration
    originalTargetID = 0,
    originalTargetName = "",
    originalTargetType = "",
    targetPreserved = false,
    
    -- Peer coordination
    peerProcessingQueue = {},
    lastPeerTriggerTime = 0,
    waterfallSessionActive = false,
    waitingForWaterfallCompletion = false,
    
    -- RG Mode state
    rgMainTriggered = false,
    useRGChase = false,
    
    -- RGMain peer tracking
    rgMainPeerCompletions = {},  -- peer_name -> { completed = bool, timestamp = number }
    rgMainSessionId = nil,
    rgMainSessionStartTime = 0,
    
    -- Emergency state
    emergencyStop = false,
    emergencyReason = "",
    
    -- UI Integration
    lootUI = nil,
    settings = nil,
    
    -- Performance tracking
    lastTickTime = 0,
    averageTickTime = 0,
    tickCount = 0
}

-- ============================================================================
-- ENGINE CONFIGURATION
-- ============================================================================

SmartLootEngine.config = {
    -- Timing settings
    tickIntervalMs = 25,
    itemPopulationDelayMs = 100,
    itemProcessingDelayMs = 50,
    ignoredItemDelayMs = 25,
    lootActionDelayMs = 200,
    
    -- Distance settings
    lootRadius = 200,
    lootRange = 15,
    lootRangeTolerance = 2,
    maxNavTimeMs = 30000,
    maxOpenLootAttempts = 3,
    navRetryDelayMs = 500,
    
    -- Combat settings
    enableCombatDetection = true,
    combatWaitDelayMs = 1500,
    maxLootWaitTime = 5000,
    
    -- Decision settings
    pendingDecisionTimeoutMs = 30000,
    autoResolveUnknownItems = false,
    defaultUnknownItemAction = "Ignore",
    
    -- Feature settings
    enablePeerCoordination = true,
    enableStatisticsLogging = true,
    peerTriggerDelay = 10000,
    
    -- Error handling
    maxConsecutiveErrors = 5,
    errorRecoveryDelayMs = 2000,
    maxItemProcessingTime = 10000,
    
    -- Inventory settings
    enableInventorySpaceCheck = true,
    minFreeInventorySlots = 5,
    autoInventoryOnLoot = true,
    
    -- Corpse scanning settings
    maxCorpseSlots = 48,
    emptySlotThreshold = 5
}

-- ============================================================================
-- ENGINE STATISTICS
-- ============================================================================

SmartLootEngine.stats = {
    sessionStart = mq.gettime(),
    corpsesProcessed = 0,
    itemsLooted = 0,
    itemsIgnored = 0,
    itemsDestroyed = 0,
    itemsLeftBehind = 0,
    peersTriggered = 0,
    decisionsRequired = 0,
    navigationTimeouts = 0,
    lootWindowFailures = 0,
    lootActionFailures = 0,
    emergencyStops = 0,
    consecutiveErrors = 0
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function getStateName(state)
    for name, value in pairs(SmartLootEngine.LootState) do
        if value == state then
            return name
        end
    end
    return "Unknown"
end

local function getActionName(action)
    for name, value in pairs(SmartLootEngine.LootAction) do
        if value == action then
            return name
        end
    end
    return "Unknown"
end

local function logStateTransition(fromState, toState, reason)
    local fromName = getStateName(fromState)
    local toName = getStateName(toState)
    logging.debug(string.format("[Engine] State: %s -> %s (%s)", fromName, toName, reason or ""))
end

local function setState(newState, reason)
    local oldState = SmartLootEngine.state.currentState
    if oldState ~= newState then
        logStateTransition(oldState, newState, reason)
        SmartLootEngine.state.currentState = newState
    end
end

local function scheduleNextTick(delayMs)
    SmartLootEngine.state.nextActionTime = mq.gettime() + (delayMs or SmartLootEngine.config.tickIntervalMs)
end

local function resetCurrentItem()
    SmartLootEngine.state.currentItem = {
        name = "",
        itemID = 0,
        iconID = 0,
        quantity = 1,
        slot = 0,
        rule = "",
        action = SmartLootEngine.LootAction.None
    }
end

-- ============================================================================
-- TARGET PRESERVATION FOR RGMERCS INTEGRATION
-- ============================================================================

function SmartLootEngine.preserveCurrentTarget()
    local currentTarget = mq.TLO.Target
    if not currentTarget() then
        -- No target to preserve
        SmartLootEngine.state.originalTargetID = 0
        SmartLootEngine.state.originalTargetName = ""
        SmartLootEngine.state.originalTargetType = ""
        SmartLootEngine.state.targetPreserved = false
        return false
    end
    
    local targetID = currentTarget.ID() or 0
    local targetName = currentTarget.Name() or ""
    local targetType = currentTarget.Type() or ""
    
    -- Only preserve non-corpse targets
    if targetType:lower() == "corpse" then
        SmartLootEngine.state.originalTargetID = 0
        SmartLootEngine.state.originalTargetName = ""
        SmartLootEngine.state.originalTargetType = ""
        SmartLootEngine.state.targetPreserved = false
        logging.debug("[Engine] Target preservation: skipped corpse target")
        return false
    end
    
    SmartLootEngine.state.originalTargetID = targetID
    SmartLootEngine.state.originalTargetName = targetName
    SmartLootEngine.state.originalTargetType = targetType
    SmartLootEngine.state.targetPreserved = true
    
    logging.debug(string.format("[Engine] Target preserved: %s (ID: %d, Type: %s)", 
                  targetName, targetID, targetType))
    return true
end

function SmartLootEngine.restorePreservedTarget()
    if not SmartLootEngine.state.targetPreserved or SmartLootEngine.state.originalTargetID == 0 then
        return false
    end
    
    -- Check if the preserved target still exists
    local targetSpawn = mq.TLO.Spawn(SmartLootEngine.state.originalTargetID)
    if not targetSpawn() then
        logging.debug(string.format("[Engine] Target restoration: preserved target %s (ID: %d) no longer exists", 
                      SmartLootEngine.state.originalTargetName, SmartLootEngine.state.originalTargetID))
        SmartLootEngine.clearPreservedTarget()
        return false
    end
    
    -- Restore the target
    mq.cmdf("/target id %d", SmartLootEngine.state.originalTargetID)
    
    logging.debug(string.format("[Engine] Target restored: %s (ID: %d)", 
                  SmartLootEngine.state.originalTargetName, SmartLootEngine.state.originalTargetID))
    
    -- Clear preservation state
    SmartLootEngine.clearPreservedTarget()
    return true
end

function SmartLootEngine.clearPreservedTarget()
    SmartLootEngine.state.originalTargetID = 0
    SmartLootEngine.state.originalTargetName = ""
    SmartLootEngine.state.originalTargetType = ""
    SmartLootEngine.state.targetPreserved = false
end

-- ============================================================================
-- RGMERCS INTEGRATION
-- ============================================================================

function SmartLootEngine.notifyRGMercsProcessing()
    -- Send message to RGMercs that we're starting to process loot
    local success, err = pcall(function()
        local actors = require("actors")
        actors.send({to='loot_module'}, {
            Subject = 'processing',
            Who = mq.TLO.Me.Name(),
            CombatLooting = SmartLootEngine.config.enableCombatDetection
        })
    end)
    
    if not success then
        logging.debug("[Engine] Failed to send processing message to RGMercs: " .. tostring(err))
    else
        logging.debug("[Engine] Notified RGMercs that loot processing started")
    end
end

function SmartLootEngine.notifyRGMercsComplete()
    -- For RGMain mode, only send completion when all peers have finished
    if SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGMain then
        -- Check if all RGMain peers have completed
        if not SmartLootEngine.areAllRGMainPeersComplete() then
            logging.debug("[Engine] RGMain mode - waiting for all peers to complete before notifying RGMercs")
            return
        end
        logging.debug("[Engine] RGMain mode - all peers complete, notifying RGMercs")
    end
    
    -- Send message to RGMercs that we're done processing loot
    local success, err = pcall(function()
        local actors = require("actors")
        actors.send({to='loot_module'}, {
            Subject = 'done_looting',
            Who = mq.TLO.Me.Name(),
            CombatLooting = SmartLootEngine.config.enableCombatDetection
        })
    end)
    
    if not success then
        logging.debug("[Engine] Failed to send completion message to RGMercs: " .. tostring(err))
    else
        logging.debug("[Engine] Notified RGMercs that loot processing completed")
    end
end

-- ============================================================================
-- RGMAIN PEER TRACKING
-- ============================================================================

function SmartLootEngine.startRGMainSession()
    -- Start a new RGMain session
    SmartLootEngine.state.rgMainSessionId = string.format("%s_%d", mq.TLO.Me.Name(), mq.gettime())
    SmartLootEngine.state.rgMainSessionStartTime = mq.gettime()
    SmartLootEngine.state.rgMainPeerCompletions = {}
    
    -- Get list of peers and initialize completion tracking
    local peers = util.getConnectedPeers()
    for _, peerName in ipairs(peers) do
        if peerName == mq.TLO.Me.Name() then
            -- Mark ourselves as already complete since we're RGMain
            SmartLootEngine.state.rgMainPeerCompletions[peerName] = {
                completed = true,
                timestamp = mq.gettime()
            }
        else
            SmartLootEngine.state.rgMainPeerCompletions[peerName] = {
                completed = false,
                timestamp = 0
            }
        end
    end
    
    -- Trigger all peers
    SmartLootEngine.triggerRGMainPeers()
    
    logging.debug("[Engine] Started RGMain session %s with %d peers", 
                  SmartLootEngine.state.rgMainSessionId, 
                  #peers)
end

function SmartLootEngine.triggerRGMainPeers()
    -- Send trigger command to all peers
    local actors = require("actors")
    local peers = util.getConnectedPeers()
    
    for _, peerName in ipairs(peers) do
        if peerName ~= mq.TLO.Me.Name() then
            local message = {
                cmd = "rg_peer_trigger",
                sender = mq.TLO.Me.Name(),
                sessionId = SmartLootEngine.state.rgMainSessionId
            }
            actors.send({mailbox = "smartloot_mailbox", server = peerName}, json.encode(message))
            logging.debug("[Engine] Triggered peer: %s", peerName)
        end
    end
end

function SmartLootEngine.reportRGMainCompletion(peerName, sessionId)
    -- Record peer completion
    if SmartLootEngine.state.rgMainSessionId == sessionId then
        if SmartLootEngine.state.rgMainPeerCompletions[peerName] then
            SmartLootEngine.state.rgMainPeerCompletions[peerName].completed = true
            SmartLootEngine.state.rgMainPeerCompletions[peerName].timestamp = mq.gettime()
            logging.debug("[Engine] Peer %s reported completion for session %s", peerName, sessionId)
            
            -- Check if all peers are complete
            if SmartLootEngine.areAllRGMainPeersComplete() then
                logging.debug("[Engine] All RGMain peers have completed - notifying RGMercs")
                SmartLootEngine.notifyRGMercsComplete()
            end
        end
    else
        logging.debug("[Engine] Ignoring completion from %s - wrong session (expected: %s, got: %s)", 
                      peerName, SmartLootEngine.state.rgMainSessionId or "none", sessionId)
    end
end

function SmartLootEngine.areAllRGMainPeersComplete()
    if not SmartLootEngine.state.rgMainSessionId then
        return true  -- No active session
    end
    
    -- Check if we're the RGMain character
    if SmartLootEngine.state.mode ~= SmartLootEngine.LootMode.RGMain then
        return true  -- Not RGMain, don't block
    end
    
    -- Check all peers
    for peerName, status in pairs(SmartLootEngine.state.rgMainPeerCompletions) do
        if not status.completed then
            -- Check for timeout (5 minutes)
            local sessionDuration = mq.gettime() - SmartLootEngine.state.rgMainSessionStartTime
            if sessionDuration > 300000 then
                logging.debug("[Engine] RGMain session timeout - proceeding without peer %s", peerName)
                return true
            end
            return false
        end
    end
    
    return true
end

function SmartLootEngine.notifyRGMainComplete()
    -- Send completion notification to RGMain character
    if SmartLootEngine.state.mode ~= SmartLootEngine.LootMode.RGMain then
        local actors = require("actors")
        local rgMainChar = SmartLootEngine.getRGMainCharacter()
        
        if rgMainChar then
            local message = {
                cmd = "rg_peer_complete",
                sender = mq.TLO.Me.Name(),
                sessionId = SmartLootEngine.state.rgMainSessionId or "unknown"
            }
            actors.send({mailbox = "smartloot_mailbox", server = rgMainChar}, json.encode(message))
            logging.debug("[Engine] Notified RGMain character %s of completion", rgMainChar)
        end
    end
end

function SmartLootEngine.getRGMainCharacter()
    -- Find the RGMain character in the group/raid
    -- We need to track which character triggered the RGMain session
    -- For now, we'll use a simple approach - store it when we receive the trigger
    
    -- If we have an active RGMain session, the session ID contains the RGMain character name
    if SmartLootEngine.state.rgMainSessionId then
        local rgMainName = SmartLootEngine.state.rgMainSessionId:match("^(.-)_")
        if rgMainName then
            return rgMainName
        end
    end
    
    -- Fallback - if no session, we can't determine the RGMain character
    logging.debug("[Engine] Unable to determine RGMain character - no active session")
    return nil
end

-- ============================================================================
-- SAFETY AND VALIDATION
-- ============================================================================

function SmartLootEngine.isInCombat()
    if not SmartLootEngine.config.enableCombatDetection then
        return false
    end
    
    return mq.TLO.Me.CombatState() == "COMBAT" or mq.TLO.SpawnCount("xtarhater")() > 0
end

function SmartLootEngine.isSafeToLoot()
    -- Emergency stop check
    if SmartLootEngine.state.emergencyStop then
        return false
    end
    
    -- Basic safety checks
    if not mq.TLO.Me() or mq.TLO.Me.CurrentHPs() <= 0 then
        return false
    end
    
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then
        return false
    end
    
    -- Combat check
    if SmartLootEngine.isInCombat() then
        return false
    end
    
    return true
end

function SmartLootEngine.isLootWindowOpen()
    return mq.TLO.Window("LootWnd").Open()
end

function SmartLootEngine.isItemOnCursor()
    return mq.TLO.Cursor() ~= nil
end

function SmartLootEngine.hasInventorySpace()
    if not SmartLootEngine.config.enableInventorySpaceCheck then
        return true
    end
    
    local freeSlots = mq.TLO.Me.FreeInventory() or 0
    local minRequired = SmartLootEngine.config.minFreeInventorySlots
    
    if freeSlots < minRequired then
        logging.debug(string.format("[Engine] Insufficient inventory space: %d free, %d required", freeSlots, minRequired))
        return false
    end
    
    return true
end

-- ============================================================================
-- CORPSE MANAGEMENT
-- ============================================================================

function SmartLootEngine.findNearestCorpse()
    if not mq.TLO.Me() then
        return nil
    end
    
    local radius = SmartLootEngine.config.lootRadius
    local corpseCount = mq.TLO.SpawnCount(string.format("npccorpse radius %d", radius))() or 0
    
    if corpseCount == 0 then
        return nil
    end
    
    local closestCorpse = nil
    local closestDistance = radius
    
    for i = 1, corpseCount do
        local corpse = mq.TLO.NearestSpawn(i, string.format("npccorpse radius %d", radius))
        if corpse() then
            local corpseID = corpse.ID()
            local distance = corpse.Distance() or 999
            
            -- Skip if already processed
            if not SmartLootEngine.state.processedCorpsesThisSession[corpseID] then
                local corpseName = corpse.Name() or ""
                local deity = corpse.Deity() or 0
                
                -- Enhanced NPC corpse detection
                local isNPCCorpse = true
                
                -- Skip obvious PC corpses by name pattern
                if corpseName:find("'s corpse") and not corpseName:find("`s_corpse") then
                    isNPCCorpse = false
                elseif corpseName:find("corpse of ") then
                    isNPCCorpse = false
                end
                
                if isNPCCorpse and distance < closestDistance then
                    closestCorpse = {
                        spawnID = corpseID,
                        corpseID = corpseID,
                        name = corpseName,
                        distance = distance,
                        x = corpse.X() or 0,
                        y = corpse.Y() or 0,
                        z = corpse.Z() or 0
                    }
                    closestDistance = distance
                end
            end
        end
    end
    
    return closestCorpse
end

function SmartLootEngine.markCorpseProcessed(corpseID)
    SmartLootEngine.state.processedCorpsesThisSession[corpseID] = true
    SmartLootEngine.stats.corpsesProcessed = SmartLootEngine.stats.corpsesProcessed + 1
    SmartLootEngine.state.sessionCorpseCount = SmartLootEngine.state.sessionCorpseCount + 1
    
    logging.debug(string.format("[Engine] Marked corpse %d as processed (total: %d)", 
                  corpseID, SmartLootEngine.stats.corpsesProcessed))
end

function SmartLootEngine.isCorpseInRange(corpse)
    return corpse and corpse.distance <= SmartLootEngine.config.lootRange
end

-- ============================================================================
-- ITEM PROCESSING
-- ============================================================================

function SmartLootEngine.getCorpseItemCount()
    if not SmartLootEngine.isLootWindowOpen() then
        return 0
    end
    
    return mq.TLO.Corpse.Items() or 0
end

function SmartLootEngine.getCorpseItem(index)
    if not SmartLootEngine.isLootWindowOpen() then
        return nil
    end
    
    local item = mq.TLO.Corpse.Item(index)
    if not item or not item() then
        return nil
    end
    
    return {
        name = item.Name() or "",
        itemID = item.ID() or 0,
        iconID = item.Icon() or 0,
        quantity = item.Stack() or 1,
        valid = true
    }
end

function SmartLootEngine.evaluateItemRule(itemName, itemID, iconID)
    -- CHECK TEMPORARY RULES FIRST
    local tempRule, originalName, assignedPeer = tempRules.getRule(itemName)
    if tempRule then
        logging.debug(string.format("[Engine] Using temporary rule for %s: %s (peer: %s)", 
                                    itemName, tempRule, assignedPeer or "none"))

        if itemID and itemID > 0 then
            tempRules.convertToPermanent(itemName, itemID, iconID)
            database.refreshLootRuleCache()
            
            -- Adjust rule for main looter if peer was assigned
            if assignedPeer then
                SmartLootEngine.state.tempRulePeerAssignment = assignedPeer
                return "Ignore", itemID, iconID
            end
        end
        logging.log(string.format("[DEBUG] Temp rule hit for %s -> %s (assigned to: %s)", itemName, tempRule, assignedPeer))
        return tempRule, itemID, iconID
    end
    
    -- Clear any previous peer assignment
    SmartLootEngine.state.tempRulePeerAssignment = nil
    
    -- Get rule from database with itemID priority
    local rule, dbItemID, dbIconID = database.getLootRule(itemName, true, itemID)
    logging.log(string.format("Engine] Rule returned for %s (ID:%d): %s", itemName, itemID or 0, rule))
    
    -- Use database IDs if current ones are invalid
    if itemID == 0 and dbItemID and dbItemID > 0 then
        itemID = dbItemID
    end
    if iconID == 0 and dbIconID and dbIconID > 0 then
        iconID = dbIconID
    end
    
    -- Handle no rule case
    if not rule or rule == "" or rule == "Unset" then
        return "Unset", itemID, iconID
    end
    
    -- Handle threshold rules
    if rule:find("KeepIfFewerThan") then
        local threshold = tonumber(rule:match(":(%d+)")) or 0
        local currentCount = mq.TLO.FindItemCount(itemName)() or 0
        
        if currentCount < threshold then
            return "Keep", itemID, iconID
        else
            return "LeftBehind", itemID, iconID
        end
    end
    
    return rule, itemID, iconID
end

function SmartLootEngine.recordItemDrop(itemName, itemID, iconID, quantity, corpseID, npcName)
    if not SmartLootEngine.config.enableStatisticsLogging then
        return
    end
    
    local dropKey = corpseID .. "_" .. itemName
    if SmartLootEngine.state.recordedDropsThisSession[dropKey] then
        return
    end
    
    local zoneName = mq.TLO.Zone.Name() or "Unknown"
    
    lootStats.recordItemDrop(
        itemName,
        itemID,
        iconID,
        zoneName,
        1,
        corpseID,
        npcName,
        corpseID
    )
    
    SmartLootEngine.state.recordedDropsThisSession[dropKey] = true
end

-- Helper function to check if corpse was seen recently
local function wasCorpseSeenRecently(corpseID, zoneName, minutes)
    local sql = string.format([[
      SELECT timestamp
        FROM loot_stats_corpses
       WHERE corpse_id = %d
         AND zone_name  = '%s'
       ORDER BY timestamp DESC
       LIMIT 1
    ]], corpseID, zoneName:gsub("'", "''"))
  
    local rows, err = lootStats.executeSelect(sql)
    if not rows then
        logging.debug("[Engine] wasCorpseSeenRecently SQL error: " .. tostring(err))
        return false
    end
  
    local dt = rows[1] and rows[1].timestamp
    if not dt then
        return false
    end
  
    -- Parse "YYYY-MM-DD HH:MM:SS" into a Lua timestamp
    local Y, M, D, h, m, s = dt:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
    if not Y then 
        logging.debug("[Engine] Could not parse timestamp: " .. tostring(dt))
        return false 
    end
    
    local tstamp = os.time{
        year  = tonumber(Y),
        month = tonumber(M),
        day   = tonumber(D),
        hour  = tonumber(h),
        min   = tonumber(m),
        sec   = tonumber(s),
    }
  
    return (os.time() - tstamp) < (minutes * 60)
end

function SmartLootEngine.recordCorpseEncounter(corpseID, corpseName, zoneName)
    if not SmartLootEngine.config.enableStatisticsLogging then
        return true
    end
    
    -- Check if we've seen this corpse recently (within 15 minutes)
    if wasCorpseSeenRecently(corpseID, zoneName, 15) then
        return true -- Skip, but treat as success
    end
    
    local escapedZone = zoneName:gsub("'", "''")
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    
    -- Use SQLite syntax "INSERT OR IGNORE" instead of MySQL "INSERT IGNORE"
    local sql = string.format([[
      INSERT OR IGNORE INTO loot_stats_corpses
        (corpse_id, zone_name, timestamp)
      VALUES
        (%d, '%s', '%s')
    ]], corpseID, escapedZone, timestamp)
  
    local success = lootStats.executeNonQuery(sql)
    if success then
        logging.debug(string.format("[Engine] Recorded corpse encounter: %d in %s", corpseID, zoneName))
    else
        logging.debug(string.format("[Engine] Failed to record corpse encounter: %d in %s", corpseID, zoneName))
    end
    
    return success
end

-- ============================================================================
-- LOOT ACTION EXECUTION
-- ============================================================================

function SmartLootEngine.executeLootAction(action, itemSlot, itemName, itemID, iconID, quantity)
    logging.debug(string.format("[Engine] Executing %s action for %s (slot %d)", 
                  getActionName(action), itemName, itemSlot))
    
    SmartLootEngine.state.lootActionInProgress = true
    SmartLootEngine.state.lootActionStartTime = mq.gettime()
    SmartLootEngine.state.lootActionType = action
    
    if action == SmartLootEngine.LootAction.Loot then
        -- Use shift+click for stacked items
        if quantity > 1 then
            mq.cmdf("/nomodkey /shift /itemnotify loot%d rightmouseup", itemSlot)
        else
            mq.cmdf("/nomodkey /shift /itemnotify loot%d leftmouseup", itemSlot)
        end
        
    elseif action == SmartLootEngine.LootAction.Destroy then
        mq.cmdf("/nomodkey /shift /itemnotify loot%d leftmouseup", itemSlot)
        
    elseif action == SmartLootEngine.LootAction.Ignore then
        -- No action needed for ignore - just record and continue
        SmartLootEngine.recordLootAction("Ignored", itemName, itemID, iconID, quantity)
        SmartLootEngine.state.lootActionInProgress = false
        return true
    end
    
    return true
end

function SmartLootEngine.checkLootActionCompletion()
    if not SmartLootEngine.state.lootActionInProgress then
        return false
    end
    
    local now = mq.gettime()
    local elapsed = now - SmartLootEngine.state.lootActionStartTime
    local action = SmartLootEngine.state.lootActionType
    local itemName = SmartLootEngine.state.currentItem.name
    local itemSlot = SmartLootEngine.state.currentItem.slot
    
    -- Check if item was removed from corpse
    local currentItem = SmartLootEngine.getCorpseItem(itemSlot)
    local itemWasRemoved = not currentItem or currentItem.name ~= itemName
    
    -- Check if item is on cursor
    local itemOnCursor = SmartLootEngine.isItemOnCursor()
    
    -- Handle successful loot action
    if itemWasRemoved or itemOnCursor then
        SmartLootEngine.state.lootActionInProgress = false
        
        if action == SmartLootEngine.LootAction.Destroy and itemOnCursor then
            -- Destroy the item
            mq.cmd("/destroy")
            SmartLootEngine.recordLootAction("Destroyed", itemName, 
                                             SmartLootEngine.state.currentItem.itemID,
                                             SmartLootEngine.state.currentItem.iconID,
                                             SmartLootEngine.state.currentItem.quantity)
            SmartLootEngine.stats.itemsDestroyed = SmartLootEngine.stats.itemsDestroyed + 1
            
        elseif action == SmartLootEngine.LootAction.Loot then
            -- Auto-inventory the item
            if SmartLootEngine.config.autoInventoryOnLoot then
                for i = 1, 3 do
                    mq.cmd("/autoinv")
                    mq.delay(25)
                    if not SmartLootEngine.isItemOnCursor() then
                        break
                    end
                end
            end
            
            SmartLootEngine.recordLootAction("Looted", itemName,
                                             SmartLootEngine.state.currentItem.itemID,
                                             SmartLootEngine.state.currentItem.iconID,
                                             SmartLootEngine.state.currentItem.quantity)
            SmartLootEngine.stats.itemsLooted = SmartLootEngine.stats.itemsLooted + 1
        end
        
        logging.debug(string.format("[Engine] Loot action completed for %s in %dms", itemName, elapsed))
        return true
        
    elseif elapsed > SmartLootEngine.state.lootActionTimeoutMs then
        -- Action timed out
        logging.debug(string.format("[Engine] Loot action for %s timed out after %dms", itemName, elapsed))
        SmartLootEngine.state.lootActionInProgress = false
        SmartLootEngine.stats.lootActionFailures = SmartLootEngine.stats.lootActionFailures + 1
        return true
    end
    
    return false
end

function SmartLootEngine.recordLootAction(action, itemName, itemID, iconID, quantity)
    local targetSpawn = mq.TLO.Target
    local corpseName = (targetSpawn() and targetSpawn.Name()) or SmartLootEngine.state.currentCorpseName
    local corpseID = SmartLootEngine.state.currentCorpseID
    
    -- Record to history
    lootHistory.recordLoot(itemName, itemID, iconID, action, corpseName, corpseID, quantity)
    
    -- Send chat message if configured
    if config and config.sendChatMessage and (action == "Ignored" or action == "Left Behind" or action:find("Ignored")) then
        local itemLink = util.createItemLink(itemName, itemID)
        config.sendChatMessage(string.format("%s %s from corpse %d", action, itemLink, corpseID))
    end
    
    logging.debug(string.format("[Engine] Recorded %s action for %s", action, itemName))
end

-- ============================================================================
-- PEER COORDINATION
-- ============================================================================

function SmartLootEngine.queueIgnoredItem(itemName, itemID)
    table.insert(SmartLootEngine.state.ignoredItemsThisSession, {name = itemName, id = itemID})
    logging.debug(string.format("[Engine] Queued ignored item for peer processing: %s (ID: %d)", itemName, itemID))
end

function SmartLootEngine.findNextInterestedPeer(itemName, itemID)
    if not SmartLootEngine.config.enablePeerCoordination then
        return nil
    end
    -- Check for temporary peer assignment first
    local assignedPeer = tempRules.getPeerAssignment(itemName)
    if assignedPeer then
        -- Verify peer is connected
        local connectedPeers = util.getConnectedPeers()
        for _, peer in ipairs(connectedPeers) do
            if peer:lower() == assignedPeer:lower() then
                return assignedPeer
            end
        end
    end
    
    local currentToon = util.getCurrentToon()
    local connectedPeers = util.getConnectedPeers()
    
    if not config.peerLootOrder or #config.peerLootOrder == 0 then
        return nil
    end
    
    -- Find current character's position in loot order
    local currentIndex = nil
    for i, peer in ipairs(config.peerLootOrder) do
        if peer:lower() == currentToon:lower() then
            currentIndex = i
            break
        end
    end
    
    if not currentIndex then
        return nil
    end
    
    -- Check peers after current character
    for i = currentIndex + 1, #config.peerLootOrder do
        local peer = config.peerLootOrder[i]
        
        -- Check if peer is connected
        local isConnected = false
        for _, connectedPeer in ipairs(connectedPeers) do
            if peer:lower() == connectedPeer:lower() then
                isConnected = true
                break
            end
        end
        
        if isConnected then
            local peerRules = database.getLootRulesForPeer(peer)
            local ruleData = nil
            if itemID and itemID > 0 then
                local compositeKey = string.format("%s_%d", itemName, itemID)
                ruleData = peerRules[compositeKey]
            end
            
            if not ruleData then
                local lowerName = string.lower(itemName)
                ruleData = peerRules[lowerName] or peerRules[itemName]
            end
            
            if ruleData and (ruleData.rule == "Keep" or ruleData.rule:find("KeepIfFewerThan")) then
                return peer
            end
        end
    end
    
    return nil
end

function SmartLootEngine.triggerPeerForItem(itemName, itemID)
    local now = mq.gettime()
    if now - SmartLootEngine.state.lastPeerTriggerTime < SmartLootEngine.config.peerTriggerDelay then
        return false
    end
    
    local interestedPeer = SmartLootEngine.findNextInterestedPeer(itemName, itemID)
    if not interestedPeer then
        return false
    end
    
    logging.debug(string.format("[Engine] Triggering peer %s for item %s", interestedPeer, itemName))
    
    -- Register with waterfall tracker BEFORE triggering
    local peerRegistered = waterfallTracker.onPeerTriggered(interestedPeer)
    util.sendPeerCommand(interestedPeer, "/sl_rulescache")

    mq.delay(100) -- optional: slight delay to let cache refresh
    
    -- Send peer command using centralized utility function
    if util.sendPeerCommand(interestedPeer, "/sl_doloot") then
        logging.debug(string.format("[Engine] Successfully sent loot command to %s", interestedPeer))
    else
        logging.debug(string.format("[Engine] Failed to send loot command to %s", interestedPeer))
    end
    
    -- Send chat announcement about triggering peer
    if config and config.sendChatMessage then
        config.sendChatMessage(string.format("Triggering %s to loot remaining items", interestedPeer))
    end
    
    SmartLootEngine.state.lastPeerTriggerTime = now
    SmartLootEngine.stats.peersTriggered = SmartLootEngine.stats.peersTriggered + 1
    
    logging.debug(string.format("[Engine] Peer triggered and registered with waterfall tracker: %s", interestedPeer))
    
    return true
end

-- ============================================================================
-- PENDING DECISION HANDLING
-- ============================================================================

function SmartLootEngine.createPendingDecision(itemName, itemID, iconID, quantity)
    logging.debug(string.format("[Engine] Creating pending decision: %s (itemID=%d, iconID=%d)", 
                  itemName, itemID or 0, iconID or 0))
    
    SmartLootEngine.state.needsPendingDecision = true
    SmartLootEngine.state.pendingDecisionStartTime = mq.gettime()
    
    -- Update UI if available
    if SmartLootEngine.state.lootUI then
        SmartLootEngine.state.lootUI.currentItem = {
            name = itemName,
            index = SmartLootEngine.state.currentItemIndex,
            numericCorpseID = SmartLootEngine.state.currentCorpseID,
            decisionStartTime = mq.gettime(),
            itemID = itemID,
            iconID = iconID
        }
    end
    
    -- Send chat notification
    if config and config.sendChatMessage then
        local itemLink = util.createItemLink(itemName, itemID)
        config.sendChatMessage(string.format('Pending loot decision required for %s by %s', 
                                             itemLink, mq.TLO.Me.Name()))
    end
    
    SmartLootEngine.stats.decisionsRequired = SmartLootEngine.stats.decisionsRequired + 1
    logging.debug(string.format("[Engine] Created pending decision for: %s", itemName))
end

function SmartLootEngine.checkPendingDecisionTimeout()
    if not SmartLootEngine.state.needsPendingDecision then
        return false
    end
    
    local elapsed = mq.gettime() - SmartLootEngine.state.pendingDecisionStartTime
    if elapsed > SmartLootEngine.config.pendingDecisionTimeoutMs then
        logging.debug(string.format("[Engine] Pending decision timed out after %dms", elapsed))
        
        if SmartLootEngine.config.autoResolveUnknownItems then
            local defaultAction = SmartLootEngine.config.defaultUnknownItemAction
            SmartLootEngine.resolvePendingDecision(SmartLootEngine.state.currentItem.name, 
                                                   SmartLootEngine.state.currentItem.itemID,
                                                   defaultAction,
                                                   SmartLootEngine.state.currentItem.iconID)
        else
            SmartLootEngine.resolvePendingDecision(SmartLootEngine.state.currentItem.name,
                                                   SmartLootEngine.state.currentItem.itemID,
                                                   "Ignore",
                                                   SmartLootEngine.state.currentItem.iconID)
        end
        return true
    end
    
    return false
end

-- ============================================================================
-- STATE MACHINE PROCESSORS
-- ============================================================================

function SmartLootEngine.processIdleState()
    -- Check if we should transition to active looting
    if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Main or
       SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or
       (SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGMain and SmartLootEngine.state.rgMainTriggered) or
       SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
        
        setState(SmartLootEngine.LootState.FindingCorpse, "Active mode detected")
        scheduleNextTick(100)
    else
        -- Stay idle in background mode
        scheduleNextTick(100)
    end
end

function SmartLootEngine.processFindingCorpseState()
    -- Start waterfall session if this is the beginning of loot processing
    if not SmartLootEngine.state.waterfallSessionActive then
        SmartLootEngine.state.waterfallSessionActive = true
        waterfallTracker.onLootSessionStart(SmartLootEngine.state.mode)
        SmartLootEngine.notifyRGMercsProcessing()
    end
    
    local corpse = SmartLootEngine.findNearestCorpse()
    
    if not corpse then
        -- No corpses found - handle based on mode
        if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or 
           SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
            setState(SmartLootEngine.LootState.ProcessingPeers, "No corpses in once mode")
        else
            setState(SmartLootEngine.LootState.ProcessingPeers, "No corpses found")
        end
        scheduleNextTick(100)
        return
    end
    
    -- Setup corpse processing
    SmartLootEngine.state.currentCorpseID = corpse.corpseID
    SmartLootEngine.state.currentCorpseSpawnID = corpse.spawnID
    SmartLootEngine.state.currentCorpseName = corpse.name
    SmartLootEngine.state.currentCorpseDistance = corpse.distance
    SmartLootEngine.state.currentItemIndex = 1
    SmartLootEngine.state.openLootAttempts = 0
    SmartLootEngine.state.emptySlotStreak = 0
    resetCurrentItem()
    
    logging.debug(string.format("[Engine] Selected corpse %d (%s), distance: %.1f", 
                  corpse.corpseID, corpse.name, corpse.distance))
    
    -- Check if we need to navigate
    if SmartLootEngine.isCorpseInRange(corpse) then
        setState(SmartLootEngine.LootState.OpeningLootWindow, "Within loot range")
        scheduleNextTick(100)
    else
        setState(SmartLootEngine.LootState.NavigatingToCorpse, "Too far from corpse")
        SmartLootEngine.state.navStartTime = mq.gettime()
        SmartLootEngine.state.navWarningAnnounced = false
        SmartLootEngine.state.navTargetX = corpse.x
        SmartLootEngine.state.navTargetY = corpse.y
        SmartLootEngine.state.navTargetZ = corpse.z
        mq.cmdf("/nav id %d", corpse.spawnID)
        scheduleNextTick(SmartLootEngine.config.navRetryDelayMs)
    end
end

function SmartLootEngine.processNavigatingToCorpseState()
    -- Check if target corpse still exists
    local corpse = mq.TLO.Spawn(SmartLootEngine.state.currentCorpseSpawnID)
    if not corpse() then
        logging.debug("[Engine] Navigation target disappeared")
        mq.cmd("/nav stop")
        setState(SmartLootEngine.LootState.FindingCorpse, "Target disappeared")
        scheduleNextTick(100)
        return
    end
    
    local distance = corpse.Distance() or 999
    SmartLootEngine.state.currentCorpseDistance = distance
    
    -- Check if we're now in range
    if distance <= SmartLootEngine.config.lootRange then
        logging.debug(string.format("[Engine] Navigation successful, distance: %.1f", distance))
        mq.cmd("/nav stop")
        setState(SmartLootEngine.LootState.OpeningLootWindow, "Navigation complete")
        scheduleNextTick(250)
        return
    end
    
    -- Check for navigation timeout
    local navElapsed = mq.gettime() - SmartLootEngine.state.navStartTime
    
    -- Check for 7-second warning announcement
    if navElapsed > 7000 and not SmartLootEngine.state.navWarningAnnounced then
        SmartLootEngine.state.navWarningAnnounced = true
        config.sendChatMessage("navigation stuck, manual intervention required")
        logging.debug("[Engine] Navigation stuck warning announced after 7 seconds")
    end
    
    if navElapsed > SmartLootEngine.config.maxNavTimeMs then
        logging.debug(string.format("[Engine] Navigation timeout after %dms", navElapsed))
        mq.cmd("/nav stop")
        SmartLootEngine.markCorpseProcessed(SmartLootEngine.state.currentCorpseID)
        SmartLootEngine.stats.navigationTimeouts = SmartLootEngine.stats.navigationTimeouts + 1
        setState(SmartLootEngine.LootState.FindingCorpse, "Navigation timeout")
        scheduleNextTick(1000)
        return
    end
    
    scheduleNextTick(SmartLootEngine.config.navRetryDelayMs)
end

function SmartLootEngine.processOpeningLootWindowState()
    -- Target the corpse
    mq.cmdf("/target id %d", SmartLootEngine.state.currentCorpseSpawnID)
    
    if SmartLootEngine.isLootWindowOpen() then
        logging.debug(string.format("[Engine] Loot window opened for corpse %d", SmartLootEngine.state.currentCorpseID))
        
        SmartLootEngine.state.totalItemsOnCorpse = SmartLootEngine.getCorpseItemCount()
        
        -- Record corpse encounter for statistics
        if SmartLootEngine.config.enableStatisticsLogging then
            local zoneName = mq.TLO.Zone.Name() or "Unknown"
            SmartLootEngine.recordCorpseEncounter(
                SmartLootEngine.state.currentCorpseID,
                SmartLootEngine.state.currentCorpseName,
                zoneName
            )
        end
        
        setState(SmartLootEngine.LootState.ProcessingItems, "Loot window opened")
        scheduleNextTick(SmartLootEngine.config.itemPopulationDelayMs)
    else
        logging.debug(string.format("[Engine] Attempting to open loot window (attempt %d)", 
                      SmartLootEngine.state.openLootAttempts + 1))
        
        mq.cmd("/loot")
        SmartLootEngine.state.openLootAttempts = SmartLootEngine.state.openLootAttempts + 1
        
        if SmartLootEngine.state.openLootAttempts >= SmartLootEngine.config.maxOpenLootAttempts then
            logging.debug(string.format("[Engine] Failed to open loot window after %d attempts", 
                          SmartLootEngine.config.maxOpenLootAttempts))
            SmartLootEngine.markCorpseProcessed(SmartLootEngine.state.currentCorpseID)
            SmartLootEngine.stats.lootWindowFailures = SmartLootEngine.stats.lootWindowFailures + 1
            setState(SmartLootEngine.LootState.FindingCorpse, "Loot window failed")
            scheduleNextTick(500)
        else
            scheduleNextTick(500)
        end
    end
end

function SmartLootEngine.processProcessingItemsState()
    -- Check if loot window is still open
    if not SmartLootEngine.isLootWindowOpen() then
        logging.debug("[Engine] Loot window closed during item processing")
        SmartLootEngine.markCorpseProcessed(SmartLootEngine.state.currentCorpseID)
        setState(SmartLootEngine.LootState.FindingCorpse, "Loot window closed")
        scheduleNextTick(100)
        return
    end
    
    -- Initialize empty slot tracking if not present
    if not SmartLootEngine.state.emptySlotStreak then
        SmartLootEngine.state.emptySlotStreak = 0
    end
    
    local maxSlots = SmartLootEngine.config.maxCorpseSlots
    local emptyThreshold = SmartLootEngine.config.emptySlotThreshold
    
    -- Check if we've scanned all possible slots or hit empty slot threshold
    if SmartLootEngine.state.currentItemIndex > maxSlots then
        logging.debug(string.format("[Engine] Finished scanning all %d slots on corpse %d", 
                      maxSlots, SmartLootEngine.state.currentCorpseID))
        setState(SmartLootEngine.LootState.CleaningUpCorpse, "All slots scanned")
        scheduleNextTick(100)
        return
    end
    
    if SmartLootEngine.state.emptySlotStreak >= emptyThreshold then
        logging.debug(string.format("[Engine] Encountered %d consecutive empty slots. Ending scan early.", emptyThreshold))
        setState(SmartLootEngine.LootState.CleaningUpCorpse, "Empty slot threshold reached")
        scheduleNextTick(100)
        return
    end
    
    -- Get current item
    local itemInfo = SmartLootEngine.getCorpseItem(SmartLootEngine.state.currentItemIndex)
    
    if not itemInfo then
        -- Empty slot, increment streak and move to next
        SmartLootEngine.state.emptySlotStreak = SmartLootEngine.state.emptySlotStreak + 1
        SmartLootEngine.state.currentItemIndex = SmartLootEngine.state.currentItemIndex + 1
        scheduleNextTick(10)
        return
    end
    
    -- Reset empty slot streak since we found an item
    SmartLootEngine.state.emptySlotStreak = 0

    if not SmartLootEngine.hasInventorySpace() then
        logging.debug("[Engine] Skipping corpse due to insufficient inventory space")
        setState(SmartLootEngine.LootState.CleaningUpCorpse, "Inventory full")
        scheduleNextTick(100)
        return
    end
    
    -- Update current item state
    SmartLootEngine.state.currentItem.name = itemInfo.name
    SmartLootEngine.state.currentItem.itemID = itemInfo.itemID
    SmartLootEngine.state.currentItem.iconID = itemInfo.iconID
    SmartLootEngine.state.currentItem.quantity = itemInfo.quantity
    SmartLootEngine.state.currentItem.slot = SmartLootEngine.state.currentItemIndex
    
    logging.debug(string.format("[Engine] Item from corpse: %s (itemID=%d, iconID=%d)", 
                  itemInfo.name, itemInfo.itemID, itemInfo.iconID))
    
    -- Record item drop for statistics
    SmartLootEngine.recordItemDrop(
        itemInfo.name,
        itemInfo.itemID, 
        itemInfo.iconID,
        itemInfo.quantity,
        SmartLootEngine.state.currentCorpseID,
        SmartLootEngine.state.currentCorpseName
    )
    
    -- Evaluate rule
    local rule, finalItemID, finalIconID = SmartLootEngine.evaluateItemRule(
        itemInfo.name, itemInfo.itemID, itemInfo.iconID)
    
    SmartLootEngine.state.currentItem.rule = rule
    SmartLootEngine.state.currentItem.itemID = finalItemID
    SmartLootEngine.state.currentItem.iconID = finalIconID
    
    logging.debug(string.format("[Engine] Processing item %d: %s (rule: %s)", 
                  SmartLootEngine.state.currentItemIndex, itemInfo.name, rule))
    
    -- Handle rule outcomes
    if rule == "Unset" then
        SmartLootEngine.createPendingDecision(itemInfo.name, finalItemID, finalIconID, itemInfo.quantity)
        setState(SmartLootEngine.LootState.WaitingForPendingDecision, "Pending decision required")
        return
        
    elseif rule == "Keep" then
        SmartLootEngine.state.currentItem.action = SmartLootEngine.LootAction.Loot
        setState(SmartLootEngine.LootState.ExecutingLootAction, "Keep rule")
        scheduleNextTick(100)
        
    elseif rule == "Destroy" then
        SmartLootEngine.state.currentItem.action = SmartLootEngine.LootAction.Destroy
        setState(SmartLootEngine.LootState.ExecutingLootAction, "Destroy rule")
        scheduleNextTick(100)
        
    elseif rule == "Ignore" or rule == "LeftBehind" then
        SmartLootEngine.state.currentItem.action = SmartLootEngine.LootAction.Ignore
        SmartLootEngine.queueIgnoredItem(itemInfo.name, finalItemID)
        
        local actionText = rule == "LeftBehind" and "Left Behind" or "Ignored"
        SmartLootEngine.recordLootAction(actionText, itemInfo.name, finalItemID, finalIconID, itemInfo.quantity)
        SmartLootEngine.stats.itemsIgnored = SmartLootEngine.stats.itemsIgnored + 1
        
        -- Move to next item
        SmartLootEngine.state.currentItemIndex = SmartLootEngine.state.currentItemIndex + 1
        scheduleNextTick(SmartLootEngine.config.ignoredItemDelayMs)
        
    else
        -- Unknown rule - treat as ignore
        logging.debug(string.format("[Engine] Unknown rule '%s' for item %s - treating as ignore", rule, itemInfo.name))
        SmartLootEngine.state.currentItem.action = SmartLootEngine.LootAction.Ignore
        SmartLootEngine.queueIgnoredItem(itemInfo.name, finalItemID)
        SmartLootEngine.recordLootAction("Ignored (Unknown Rule)", itemInfo.name, finalItemID, finalIconID, itemInfo.quantity)
        SmartLootEngine.stats.itemsIgnored = SmartLootEngine.stats.itemsIgnored + 1
        
        SmartLootEngine.state.currentItemIndex = SmartLootEngine.state.currentItemIndex + 1
        scheduleNextTick(SmartLootEngine.config.ignoredItemDelayMs)
    end
end

function SmartLootEngine.processWaitingForPendingDecisionState()
    -- Check for decision timeout
    if SmartLootEngine.checkPendingDecisionTimeout() then
        setState(SmartLootEngine.LootState.ProcessingItems, "Decision timeout")
        scheduleNextTick(100)
        return
    end
    
    -- Wait for external resolution
    scheduleNextTick(100)
end

function SmartLootEngine.processExecutingLootActionState()
    local item = SmartLootEngine.state.currentItem
    
    -- Start loot action if not already in progress
    if not SmartLootEngine.state.lootActionInProgress then
        if SmartLootEngine.executeLootAction(item.action, item.slot, item.name, item.itemID, item.iconID, item.quantity) then
            scheduleNextTick(SmartLootEngine.config.lootActionDelayMs)
        else
            -- Failed to start action
            SmartLootEngine.stats.lootActionFailures = SmartLootEngine.stats.lootActionFailures + 1
            SmartLootEngine.state.currentItemIndex = SmartLootEngine.state.currentItemIndex + 1 -- Still increment on failure to avoid getting stuck
            setState(SmartLootEngine.LootState.ProcessingItems, "Loot action failed")
            scheduleNextTick(SmartLootEngine.config.itemProcessingDelayMs)
        end
        return
    end
    
    -- Check if action completed
    if SmartLootEngine.checkLootActionCompletion() then
        -- ALWAYS move to the next item index after an action is completed (or timed out)
        SmartLootEngine.state.currentItemIndex = SmartLootEngine.state.currentItemIndex + 1
        
        setState(SmartLootEngine.LootState.ProcessingItems, "Action completed")
        scheduleNextTick(SmartLootEngine.config.itemProcessingDelayMs)
        return
    end
    
    scheduleNextTick(25)
end

function SmartLootEngine.processCleaningUpCorpseState()
    -- Close loot window
    if SmartLootEngine.isLootWindowOpen() then
        mq.cmd("/notify LootWnd DoneButton leftmouseup")
        scheduleNextTick(500)
        return
    end
    
    -- Mark corpse as processed
    SmartLootEngine.markCorpseProcessed(SmartLootEngine.state.currentCorpseID)
    
    -- Reset corpse-specific state
    SmartLootEngine.state.currentCorpseID = 0
    SmartLootEngine.state.currentCorpseSpawnID = 0
    SmartLootEngine.state.currentCorpseName = ""
    SmartLootEngine.state.currentCorpseDistance = 0
    SmartLootEngine.state.currentItemIndex = 0
    SmartLootEngine.state.totalItemsOnCorpse = 0
    SmartLootEngine.state.emptySlotStreak = 0
    resetCurrentItem()
    
    setState(SmartLootEngine.LootState.FindingCorpse, "Continue processing")
    
    scheduleNextTick(100)
end

function SmartLootEngine.processProcessingPeersState()
    -- Process ignored items for peer coordination
    if #SmartLootEngine.state.ignoredItemsThisSession > 0 then
        local triggeredAny = false
        
        for _, item in ipairs(SmartLootEngine.state.ignoredItemsThisSession) do
            if SmartLootEngine.triggerPeerForItem(item.name, item.id) then
                triggeredAny = true
                break -- Only trigger one peer per cycle
            end
        end
        
        -- Clear ignored items after processing
        SmartLootEngine.state.ignoredItemsThisSession = {}
        
        if triggeredAny then
            logging.debug("[Engine] Triggered peer for ignored item")
        else
            -- Check if we should send completion message
            --SmartLootEngine.checkAndSendCompletionMessage()
        end
    else
        -- No ignored items to process - check if we should send completion message
        --SmartLootEngine.checkAndSendCompletionMessage()
    end
    
    -- Check if local looting is complete and handle waterfall
    if SmartLootEngine.state.waterfallSessionActive then
        local waterfallComplete = waterfallTracker.onLootSessionEnd()
        
        if waterfallComplete then
            -- Waterfall is complete - we can finish
            SmartLootEngine.state.waterfallSessionActive = false
            SmartLootEngine.state.waitingForWaterfallCompletion = false
            
            logging.debug("[Engine] Waterfall chain completed")
            
            -- Handle mode transitions
            if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or 
               SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
                setState(SmartLootEngine.LootState.OnceModeCompletion, "Waterfall complete - once mode")
            else
                -- For Background/Main mode, check for more corpses before going idle
                local moreCorpses = SmartLootEngine.findNearestCorpse()
                if moreCorpses then
                    logging.debug("[Engine] More corpses available - continuing processing")
                    setState(SmartLootEngine.LootState.FindingCorpse, "More corpses available")
                    scheduleNextTick(100)
                    return
                else
                    --[[Send completion announcement
                    if config and config.sendChatMessage then
                        config.sendChatMessage("Looting completed - no more corpses to process")
                    end]]
                    setState(SmartLootEngine.LootState.Idle, "Waterfall complete - no more corpses")
                end
            end
        else
            -- Still waiting for waterfall completion
            SmartLootEngine.state.waitingForWaterfallCompletion = true
            logging.debug("[Engine] Waiting for waterfall chain completion")
            setState(SmartLootEngine.LootState.WaitingForWaterfallCompletion, "Peers still processing")
        end
    else
        -- No waterfall session - proceed normally
        if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or 
           SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
            setState(SmartLootEngine.LootState.OnceModeCompletion, "Once mode peer processing complete")
        else
            -- For Background/Main mode, check for more corpses before going idle
            local moreCorpses = SmartLootEngine.findNearestCorpse()
            if moreCorpses then
                logging.debug("[Engine] More corpses available - continuing processing")
                setState(SmartLootEngine.LootState.FindingCorpse, "More corpses available")
                scheduleNextTick(100)
                return
            else
                -- Send completion announcement
                if config and config.sendChatMessage then
                    config.sendChatMessage("Looting completed - no more corpses to process")
                end
                -- Notify RGMain if we're a peer
                SmartLootEngine.notifyRGMainComplete()
                SmartLootEngine.notifyRGMercsComplete()
                setState(SmartLootEngine.LootState.Idle, "Peer processing complete - no more corpses")
            end
        end
    end
    
    scheduleNextTick(500)
end

function SmartLootEngine.processOnceModeCompletionState()
    logging.debug("[Engine] Once mode completion")
    
    -- Send completion announcement
    if config and config.sendChatMessage then
        config.sendChatMessage("Looting session completed")
    end
    
    -- Notify RGMain if we're a peer
    SmartLootEngine.notifyRGMainComplete()
    
    -- Notify RGMercs that looting is complete
    SmartLootEngine.notifyRGMercsComplete()
    
    -- Restart Chase
    mq.cmd('/luachase pause off')
    -- Switch to background mode
    SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Once mode complete")
    setState(SmartLootEngine.LootState.Idle, "Once mode complete")
    scheduleNextTick(500)
end

function SmartLootEngine.processCombatDetectedState()
    -- Preserve current target before cleanup (for RGMercs integration)
    SmartLootEngine.preserveCurrentTarget()
    
    -- Close loot window if open
    if SmartLootEngine.isLootWindowOpen() then
        mq.cmd("/notify LootWnd DoneButton leftmouseup")
    end
    
    -- Stop navigation if active
    if mq.TLO.Navigation.Active() then
        mq.cmd("/nav stop")
    end
    
    -- Auto-inventory any cursor item
    if SmartLootEngine.isItemOnCursor() and SmartLootEngine.config.autoInventoryOnLoot then
        mq.cmd("/autoinv")
    end
    
    -- Restore preserved target for RGMercs integration
    SmartLootEngine.restorePreservedTarget()
    
    -- Wait for combat to end
    if not SmartLootEngine.isInCombat() then
        setState(SmartLootEngine.LootState.Idle, "Combat ended")
        scheduleNextTick(100)
    else
        scheduleNextTick(SmartLootEngine.config.combatWaitDelayMs)
    end
end

function SmartLootEngine.processEmergencyStopState()
    -- Preserve current target before cleanup (for RGMercs integration)
    SmartLootEngine.preserveCurrentTarget()
    
    -- Emergency cleanup
    if SmartLootEngine.isLootWindowOpen() then
        mq.cmd("/notify LootWnd DoneButton leftmouseup")
    end
    
    mq.cmd("/nav stop")
    
    if SmartLootEngine.isItemOnCursor() then
        mq.cmd("/autoinv")
    end
    
    -- Restore preserved target for RGMercs integration
    SmartLootEngine.restorePreservedTarget()
    
    -- Clear all state
    SmartLootEngine.state.lootActionInProgress = false
    SmartLootEngine.state.needsPendingDecision = false
    SmartLootEngine.state.currentCorpseID = 0
    resetCurrentItem()
    
    -- AUTO-RECOVERY: Check if conditions are safe to resume
    local stopDuration = mq.gettime() - (SmartLootEngine.state.emergencyStopTime or mq.gettime())
    local autoRecoveryDelay = 5000 -- 5 seconds
    
    if stopDuration > autoRecoveryDelay then
        -- Check if it's safe to auto-resume
        if SmartLootEngine.isSafeToLoot() and not SmartLootEngine.isInCombat() then
            logging.debug(string.format("[Engine] Auto-recovery: Emergency stop cleared after %.1fs", stopDuration / 1000))
            SmartLootEngine.resume()
            return
        else
            logging.debug("[Engine] Auto-recovery delayed: unsafe conditions")
        end
    else
        logging.debug(string.format("[Engine] Emergency stop: %s (%.1fs remaining)", 
                      SmartLootEngine.state.emergencyReason, 
                      (autoRecoveryDelay - stopDuration) / 1000))
    end
    
    -- Stay in emergency state but check again soon
    scheduleNextTick(1000)
end

function SmartLootEngine.processWaitingForWaterfallCompletionState()
    -- Check if waterfall chain has completed
    local waterfallComplete = waterfallTracker.checkWaterfallProgress()
    
    if waterfallComplete then
        SmartLootEngine.state.waterfallSessionActive = false
        SmartLootEngine.state.waitingForWaterfallCompletion = false
        
        logging.debug("[Engine] Waterfall completion detected while waiting")
        
        -- Send completion announcement
        if config and config.sendChatMessage then
            config.sendChatMessage("All peers finished looting - session complete")
        end
        
        -- For RGMain mode, mark ourselves as complete and notify RGMercs if all peers are done
        if SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGMain then
            -- Mark RGMain as complete
            if SmartLootEngine.state.rgMainPeerCompletions[mq.TLO.Me.Name()] then
                SmartLootEngine.state.rgMainPeerCompletions[mq.TLO.Me.Name()].completed = true
                SmartLootEngine.state.rgMainPeerCompletions[mq.TLO.Me.Name()].timestamp = mq.gettime()
            end
            SmartLootEngine.notifyRGMercsComplete()
        end
        
        -- Handle mode transitions based on original mode
        if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or 
           SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
            setState(SmartLootEngine.LootState.OnceModeCompletion, "Waterfall complete - once mode")
        else
            setState(SmartLootEngine.LootState.Idle, "Waterfall complete")
        end
        
        scheduleNextTick(100)
    else
        -- Check for timeout
        local waterfallStatus = waterfallTracker.getStatus()
        if waterfallStatus.sessionDuration > SmartLootEngine.config.maxLootWaitTime then
            logging.debug("[Engine] Waterfall timeout - proceeding anyway")
            SmartLootEngine.state.waterfallSessionActive = false
            SmartLootEngine.state.waitingForWaterfallCompletion = false
            
            -- Send timeout completion announcement
            if config and config.sendChatMessage then
                config.sendChatMessage("Looting session timed out - proceeding without waiting for peers")
            end
            
            -- Force completion notification
            SmartLootEngine.notifyRGMercsComplete()
            
            if SmartLootEngine.state.mode == SmartLootEngine.LootMode.Once or 
               SmartLootEngine.state.mode == SmartLootEngine.LootMode.RGOnce then
                setState(SmartLootEngine.LootState.OnceModeCompletion, "Waterfall timeout")
            else
                setState(SmartLootEngine.LootState.Idle, "Waterfall timeout")
            end
        else
            -- Continue waiting
            scheduleNextTick(1000)
        end
    end
end

-- ============================================================================
-- MAIN TICK PROCESSOR
-- ============================================================================

function SmartLootEngine.processTick()
    local tickStart = mq.gettime()
    
    -- Check if it's time to process
    if tickStart < SmartLootEngine.state.nextActionTime then
        return
    end
    
    -- Safety checks
    if not SmartLootEngine.isSafeToLoot() then
        if SmartLootEngine.state.currentState ~= SmartLootEngine.LootState.CombatDetected and
           SmartLootEngine.state.currentState ~= SmartLootEngine.LootState.EmergencyStop then
            setState(SmartLootEngine.LootState.CombatDetected, "Unsafe conditions")
        end
        SmartLootEngine.processCombatDetectedState()
        return
    end
    
    -- Resume from combat if we were in combat state
    if SmartLootEngine.state.currentState == SmartLootEngine.LootState.CombatDetected and
       SmartLootEngine.state.emergencyStop == false then
        setState(SmartLootEngine.LootState.Idle, "Safe to loot again")
        scheduleNextTick(100)
        return
    end
    
    -- Resume from emergency stop if we were in that state and flag is cleared
    if SmartLootEngine.state.currentState == SmartLootEngine.LootState.EmergencyStop and
       SmartLootEngine.state.emergencyStop == false then
        setState(SmartLootEngine.LootState.Idle, "Emergency stop cleared")
        scheduleNextTick(100)
        return
    end
    
    -- Handle emergency stop
    if SmartLootEngine.state.emergencyStop and 
       SmartLootEngine.state.currentState ~= SmartLootEngine.LootState.EmergencyStop then
        setState(SmartLootEngine.LootState.EmergencyStop, "Emergency stop activated")
    end
    
    -- Process current state
    local currentState = SmartLootEngine.state.currentState
    
    if currentState == SmartLootEngine.LootState.Idle then
        SmartLootEngine.processIdleState()
    elseif currentState == SmartLootEngine.LootState.FindingCorpse then
        SmartLootEngine.processFindingCorpseState()
    elseif currentState == SmartLootEngine.LootState.NavigatingToCorpse then
        SmartLootEngine.processNavigatingToCorpseState()
    elseif currentState == SmartLootEngine.LootState.OpeningLootWindow then
        SmartLootEngine.processOpeningLootWindowState()
    elseif currentState == SmartLootEngine.LootState.ProcessingItems then
        SmartLootEngine.processProcessingItemsState()
    elseif currentState == SmartLootEngine.LootState.WaitingForPendingDecision then
        SmartLootEngine.processWaitingForPendingDecisionState()
    elseif currentState == SmartLootEngine.LootState.ExecutingLootAction then
        SmartLootEngine.processExecutingLootActionState()
    elseif currentState == SmartLootEngine.LootState.CleaningUpCorpse then
        SmartLootEngine.processCleaningUpCorpseState()
    elseif currentState == SmartLootEngine.LootState.ProcessingPeers then
        SmartLootEngine.processProcessingPeersState()
    elseif currentState == SmartLootEngine.LootState.WaitingForWaterfallCompletion then
        SmartLootEngine.processWaitingForWaterfallCompletionState()
    elseif currentState == SmartLootEngine.LootState.OnceModeCompletion then
        SmartLootEngine.processOnceModeCompletionState()
    elseif currentState == SmartLootEngine.LootState.CombatDetected then
        SmartLootEngine.processCombatDetectedState()
    elseif currentState == SmartLootEngine.LootState.EmergencyStop then
        SmartLootEngine.processEmergencyStopState()
    else
        -- Unknown state - reset to idle
        logging.debug(string.format("[Engine] Unknown state %d - resetting to Idle", currentState))
        setState(SmartLootEngine.LootState.Idle, "Unknown state reset")
        scheduleNextTick(1000)
    end
    
    -- Update performance metrics
    local tickEnd = mq.gettime()
    local tickTime = tickEnd - tickStart
    SmartLootEngine.state.tickCount = SmartLootEngine.state.tickCount + 1
    SmartLootEngine.state.averageTickTime = (SmartLootEngine.state.averageTickTime * (SmartLootEngine.state.tickCount - 1) + tickTime) / SmartLootEngine.state.tickCount
    SmartLootEngine.state.lastTickTime = tickTime
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function SmartLootEngine.setLootMode(newMode, reason)
    local oldMode = SmartLootEngine.state.mode
    SmartLootEngine.state.mode = newMode
    
    logging.debug(string.format("[Engine] Mode changed: %s -> %s (%s)", oldMode, newMode, reason or ""))
    
    -- Handle mode-specific initialization
    if newMode == SmartLootEngine.LootMode.RGMain then
        SmartLootEngine.state.rgMainTriggered = false
    elseif newMode == SmartLootEngine.LootMode.Once or newMode == SmartLootEngine.LootMode.RGOnce then
        -- Pause chase if configured
        if SmartLootEngine.state.useRGChase then
            if config and config.executeChaseCommand then
                config.executeChaseCommand("pause")
            else
                mq.cmd("/rgl pauseon")
            end
        end
    elseif newMode == SmartLootEngine.LootMode.Background then
        -- Resume chase if coming from Once mode
        if (oldMode == SmartLootEngine.LootMode.Once or oldMode == SmartLootEngine.LootMode.RGOnce) and SmartLootEngine.state.useRGChase then
            if config and config.executeChaseCommand then
                config.executeChaseCommand("resume")
            else
                mq.cmd("/rgl pauseoff")
            end
        end
    elseif newMode == SmartLootEngine.LootMode.Disabled then
        SmartLootEngine.state.emergencyStop = true
        SmartLootEngine.state.emergencyReason = "Mode disabled"
        setState(SmartLootEngine.LootState.EmergencyStop, "Disabled")
    end
    
    -- Clear emergency stop when switching to active mode
    if newMode ~= SmartLootEngine.LootMode.Disabled then
        SmartLootEngine.state.emergencyStop = false
        SmartLootEngine.state.emergencyReason = ""
    end
end

function SmartLootEngine.getLootMode()
    return SmartLootEngine.state.mode
end

function SmartLootEngine.triggerRGMain()
    local mode = SmartLootEngine.getLootMode():lower()
    if mode ~= "rgmain" then
        return false
    end

    if SmartLootEngine.state.rgMainTriggered then
        return false
    end

    SmartLootEngine.state.rgMainTriggered = true
    
    -- Start RGMain session and trigger peers
    SmartLootEngine.startRGMainSession()
    
    -- Start finding corpses
    setState(SmartLootEngine.LootState.FindingCorpse, "RGMain triggered")
    
    return true
end

function SmartLootEngine.resolvePendingDecision(itemName, itemID, selectedRule, iconID)
    if not SmartLootEngine.state.needsPendingDecision then
        return false
    end
    
    logging.debug(string.format("[Engine] Resolving pending decision: %s -> %s", itemName, selectedRule))
    
    -- Save the rule to database
    database.saveLootRule(itemName, itemID, selectedRule, iconID or 0)
    
    -- Update current item with resolved rule
    SmartLootEngine.state.currentItem.rule = selectedRule
    SmartLootEngine.state.currentItem.itemID = itemID
    SmartLootEngine.state.currentItem.iconID = iconID or 0
    
    -- Clear pending decision state
    SmartLootEngine.state.needsPendingDecision = false
    
    -- Clear UI pending decision if available
    if SmartLootEngine.state.lootUI then
        SmartLootEngine.state.lootUI.currentItem = nil
        SmartLootEngine.state.lootUI.pendingLootAction = nil
    end
    
    -- Resume item processing with the resolved rule
    setState(SmartLootEngine.LootState.ProcessingItems, "Decision resolved")
    scheduleNextTick(100)
    
    return true
end

function SmartLootEngine.getState()
    local waterfallStatus = waterfallTracker.getStatus()
    
    return {
        currentState = SmartLootEngine.state.currentState,
        currentStateName = getStateName(SmartLootEngine.state.currentState),
        mode = SmartLootEngine.state.mode,
        currentCorpseID = SmartLootEngine.state.currentCorpseID,
        currentItemIndex = SmartLootEngine.state.currentItemIndex,
        currentItemName = SmartLootEngine.state.currentItem.name,
        needsPendingDecision = SmartLootEngine.state.needsPendingDecision,
        pendingItemDetails = {
            itemName = SmartLootEngine.state.currentItem.name,
            itemID = SmartLootEngine.state.currentItem.itemID,
            iconID = SmartLootEngine.state.currentItem.iconID
        },
        waitingForLootAction = SmartLootEngine.state.lootActionInProgress,
        waitingForWaterfall = SmartLootEngine.state.waitingForWaterfallCompletion,
        waterfallActive = SmartLootEngine.state.waterfallSessionActive,
        waterfallStatus = waterfallStatus,
        stats = {
            corpsesProcessed = SmartLootEngine.stats.corpsesProcessed,
            itemsLooted = SmartLootEngine.stats.itemsLooted,
            itemsIgnored = SmartLootEngine.stats.itemsIgnored,
            itemsDestroyed = SmartLootEngine.stats.itemsDestroyed,
            peersTriggered = SmartLootEngine.stats.peersTriggered,
            decisionsRequired = SmartLootEngine.stats.decisionsRequired,
            emergencyStops = SmartLootEngine.stats.emergencyStops
        },
        performance = {
            lastTickTime = SmartLootEngine.state.lastTickTime,
            averageTickTime = SmartLootEngine.state.averageTickTime,
            tickCount = SmartLootEngine.state.tickCount
        }
    }
end

function SmartLootEngine.resetProcessedCorpses()
    SmartLootEngine.state.processedCorpsesThisSession = {}
    SmartLootEngine.state.ignoredItemsThisSession = {}
    SmartLootEngine.state.recordedDropsThisSession = {}
    SmartLootEngine.state.sessionCorpseCount = 0

    logging.debug("[Engine] Reset all processed corpse tracking")
end

function SmartLootEngine.emergencyStop(reason)
    SmartLootEngine.state.emergencyStop = true
    SmartLootEngine.state.emergencyReason = reason or "Manual trigger"
    SmartLootEngine.state.emergencyStopTime = mq.gettime()
    SmartLootEngine.state.needsPendingDecision = false
    SmartLootEngine.state.lootActionInProgress = false
    SmartLootEngine.stats.emergencyStops = SmartLootEngine.stats.emergencyStops + 1
    
    -- End waterfall session if active
    if SmartLootEngine.state.waterfallSessionActive then
        waterfallTracker.endSession()
        SmartLootEngine.state.waterfallSessionActive = false
        SmartLootEngine.state.waitingForWaterfallCompletion = false
    end
    
    setState(SmartLootEngine.LootState.EmergencyStop, "Emergency stop")
    
    logging.debug(string.format("[Engine] Emergency stop activated: %s", SmartLootEngine.state.emergencyReason))
end

-- Quick stop - less aggressive than emergency stop
function SmartLootEngine.quickStop(reason)
    -- If processing, allow current action to complete
    if SmartLootEngine.state.lootActionInProgress then
        SmartLootEngine.state.stopAfterCurrentAction = true
        util.printSmartLoot("Quick stop requested - will stop after current action", "info")
    else
        -- If not processing, stop immediately
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, reason or "Quick stop")
    end
end

function SmartLootEngine.resume()
    SmartLootEngine.state.emergencyStop = false
    SmartLootEngine.state.emergencyReason = ""
    SmartLootEngine.state.emergencyStopTime = 0
    setState(SmartLootEngine.LootState.Idle, "Emergency stop cleared")
    logging.debug("[Engine] Emergency stop cleared")
end

function SmartLootEngine.setLootUIReference(lootUI, settings)
    SmartLootEngine.state.lootUI = lootUI
    SmartLootEngine.state.settings = settings
    
    -- Sync config from settings
    if settings then
        SmartLootEngine.config.lootRadius = settings.lootRadius or SmartLootEngine.config.lootRadius
        SmartLootEngine.config.lootRange = settings.lootRange or SmartLootEngine.config.lootRange
        SmartLootEngine.config.combatWaitDelayMs = settings.combatWaitDelay or SmartLootEngine.config.combatWaitDelayMs
        SmartLootEngine.state.useRGChase = settings.useRGChase or false
    end
    
    logging.debug("[Engine] UI and settings references configured")
end

function SmartLootEngine.getPerformanceMetrics()
    return {
        averageTickTime = SmartLootEngine.state.averageTickTime,
        lastTickTime = SmartLootEngine.state.lastTickTime,
        tickCount = SmartLootEngine.state.tickCount,
        corpsesPerMinute = SmartLootEngine.stats.corpsesProcessed / math.max(1, (mq.gettime() - SmartLootEngine.stats.sessionStart) / 60000),
        itemsPerMinute = (SmartLootEngine.stats.itemsLooted + SmartLootEngine.stats.itemsIgnored) / math.max(1, (mq.gettime() - SmartLootEngine.stats.sessionStart) / 60000)
    }
end

return SmartLootEngine