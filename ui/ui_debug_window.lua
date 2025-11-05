-- ui/ui_debug_window.lua - SmartLoot Debug Window
local ImGui = require("ImGui")
local mq = require("mq")

local debugWindow = {
    show = false,
    autoUpdate = true,
    refreshRate = 1000, -- ms
    lastUpdate = 0,
    windowFlags = ImGuiWindowFlags.None
}

-- Helper function to get color for state
local function getStateColor(stateName)
    if stateName == "Idle" then
        return 0.7, 0.7, 0.7, 1 -- Gray
    elseif stateName == "FindingCorpse" then
        return 0, 1, 1, 1 -- Cyan
    elseif stateName == "NavigatingToCorpse" then
        return 1, 1, 0, 1 -- Yellow
    elseif stateName == "OpeningLootWindow" then
        return 1, 0.5, 0, 1 -- Orange
    elseif stateName == "ProcessingItems" then
        return 0, 1, 0, 1 -- Green
    elseif stateName == "WaitingForPendingDecision" then
        return 1, 0, 1, 1 -- Magenta
    elseif stateName == "ExecutingLootAction" then
        return 0, 0.8, 0, 1 -- Bright Green
    elseif stateName == "CleaningUpCorpse" then
        return 0.5, 0.5, 1, 1 -- Light Blue
    elseif stateName == "ProcessingPeers" then
        return 0.8, 0.8, 0, 1 -- Bright Yellow
    elseif stateName == "CombatDetected" then
        return 1, 0, 0, 1 -- Red
    elseif stateName == "EmergencyStop" then
        return 0.8, 0, 0, 1 -- Dark Red
    else
        return 1, 1, 1, 1 -- White
    end
end

-- Helper function to format time
local function formatTime(ms)
    if ms < 1000 then
        return string.format("%.0fms", ms)
    else
        return string.format("%.1fs", ms / 1000)
    end
end

-- Helper function to get action name
local function getActionName(actionNum)
    if actionNum == 0 then return "None"
    elseif actionNum == 1 then return "Loot"
    elseif actionNum == 2 then return "Destroy" 
    elseif actionNum == 3 then return "Ignore"
    elseif actionNum == 4 then return "Skip"
    else return "Unknown"
    end
end

function debugWindow.draw(SmartLootEngine, lootUI)
    if not lootUI.showDebugWindow then
        return
    end
    
    local now = mq.gettime()
    
    -- Auto-refresh check
    if debugWindow.autoUpdate and (now - debugWindow.lastUpdate) > debugWindow.refreshRate then
        debugWindow.lastUpdate = now
    end
    
    ImGui.SetNextWindowSize(600, 700, ImGuiCond.FirstUseEver)
    
    local shouldDraw, shouldClose = ImGui.Begin("SmartLoot Debug Window", true, debugWindow.windowFlags)
    
    -- Handle close button BEFORE drawing content
    if not shouldClose then
        lootUI.showDebugWindow = false
        local config = require("modules.config")
        config.uiVisibility.showDebugWindow = false
        if config.save then config.save() end
        ImGui.End()
        return
    end
    
    if shouldDraw then
        local state = SmartLootEngine.getState()
        local config = SmartLootEngine.config
        local engineState = SmartLootEngine.state
        
        -- Header with current status
        ImGui.PushStyleColor(ImGuiCol.Text, getStateColor(state.currentStateName))
        ImGui.Text("ENGINE STATE: " .. state.currentStateName)
        ImGui.PopStyleColor()
        
        ImGui.SameLine()
        ImGui.Text(" | MODE: " .. state.mode)
        
        -- Auto-refresh toggle
        ImGui.Separator()
        debugWindow.autoUpdate = ImGui.Checkbox("Auto Refresh", debugWindow.autoUpdate)
        ImGui.SameLine()
        if ImGui.Button("Refresh Now") then
            debugWindow.lastUpdate = now
        end
        
        -- RGMercs Communication Heartbeat
        if ImGui.CollapsingHeader("RGMercs Communication", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.Indent()
            
            local rgmercs = engineState.rgmercs or {}
            local lastSent = rgmercs.lastMessageSent or 0
            local timeSinceLastSent = lastSent > 0 and (now - lastSent) / 1000 or -1
            
            -- Status indicator
            ImGui.Text("Status: ")
            ImGui.SameLine()
            
            if rgmercs.messagesSent > 0 then
                if timeSinceLastSent >= 0 and timeSinceLastSent < 30 then
                    -- Active (green)
                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                    ImGui.Text("✓ ACTIVE")
                    ImGui.PopStyleColor()
                elseif timeSinceLastSent >= 30 and timeSinceLastSent < 60 then
                    -- Warning (yellow)
                    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
                    ImGui.Text("⚠ IDLE")
                    ImGui.PopStyleColor()
                else
                    -- Stale (gray)
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 0.6, 1)
                    ImGui.Text("○ STALE")
                    ImGui.PopStyleColor()
                end
            else
                -- Never sent
                ImGui.PushStyleColor(ImGuiCol.Text, 0.5, 0.5, 0.5, 1)
                ImGui.Text("○ NO MESSAGES SENT")
                ImGui.PopStyleColor()
            end
            
            ImGui.Separator()
            
            -- Messages sent TO RGMercs
            ImGui.Text("Messages Sent to RGMercs: " .. (rgmercs.messagesSent or 0))
            
            if lastSent > 0 then
                ImGui.Text("  Last Sent Type: " .. (rgmercs.lastMessageType or "Unknown"))
                ImGui.Text("  Last Sent: " .. string.format("%.1fs ago", timeSinceLastSent))
            else
                ImGui.Text("  Last Sent: Never")
            end
            
            ImGui.Separator()
            
            -- Acknowledgments received FROM RGMercs
            local lastReceived = rgmercs.lastMessageReceived or 0
            local timeSinceLastReceived = lastReceived > 0 and (now - lastReceived) / 1000 or -1
            
            ImGui.Text("Acknowledgments from RGMercs: " .. (rgmercs.messagesReceived or 0))
            
            if lastReceived > 0 then
                ImGui.Text("  Last Ack Type: " .. (rgmercs.lastAckSubject or "Unknown"))
                ImGui.Text("  Last Received: " .. string.format("%.1fs ago", timeSinceLastReceived))
                
                -- Show communication health
                ImGui.Text("  Round-trip: ")
                ImGui.SameLine()
                if timeSinceLastReceived < 5 then
                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
                    ImGui.Text("✓ HEALTHY")
                    ImGui.PopStyleColor()
                elseif timeSinceLastReceived < 30 then
                    ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0, 1)
                    ImGui.Text("⚠ DELAYED")
                    ImGui.PopStyleColor()
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 1, 0.3, 0.3, 1)
                    ImGui.Text("✗ NO RESPONSE")
                    ImGui.PopStyleColor()
                end
            else
                ImGui.Text("  Last Received: Never")
            end
            
            -- Error display
            if rgmercs.lastError and rgmercs.lastError ~= "" then
                local errorTime = rgmercs.lastErrorTime or 0
                local timeSinceError = errorTime > 0 and (now - errorTime) / 1000 or -1
                
                ImGui.Separator()
                ImGui.PushStyleColor(ImGuiCol.Text, 1, 0.3, 0.3, 1)
                ImGui.Text("Last Error:")
                ImGui.PopStyleColor()
                ImGui.TextWrapped(rgmercs.lastError)
                if timeSinceError >= 0 then
                    ImGui.Text(string.format("(%.1fs ago)", timeSinceError))
                end
            end
            
            -- Info text
            ImGui.Separator()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1)
            ImGui.TextWrapped("SmartLoot sends 'processing' when starting to loot and 'done_looting' when finished. This helps RGMercs coordinate looting behavior.")
            ImGui.PopStyleColor()
            
            ImGui.Unindent()
        end
        
        -- Core Engine Status
        if ImGui.CollapsingHeader("Core Engine Status") then
            ImGui.Indent()
            
            ImGui.Text("Current State: " .. state.currentStateName)
            ImGui.Text("Mode: " .. state.mode)
            ImGui.Text("Next Action Time: " .. formatTime(math.max(0, engineState.nextActionTime - now)))
            ImGui.Text("Emergency Stop: " .. (engineState.emergencyStop and "YES" or "NO"))
            if engineState.emergencyStop then
                ImGui.SameLine()
                ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1)
                ImGui.Text("(" .. (engineState.emergencyReason or "Unknown") .. ")")
                ImGui.PopStyleColor()
                
                if engineState.emergencyStopTime and engineState.emergencyStopTime > 0 then
                    local elapsed = now - engineState.emergencyStopTime
                    local autoRecoveryIn = math.max(0, 5000 - elapsed) -- 5 second auto-recovery
                    if autoRecoveryIn > 0 then
                        ImGui.Text("Auto-recovery in: " .. string.format("%.1fs", autoRecoveryIn / 1000))
                    else
                        ImGui.Text("Auto-recovery: Checking conditions...")
                    end
                end
            end
            
            ImGui.Unindent()
        end
        
        -- Safety Checks
        if ImGui.CollapsingHeader("Safety Checks") then
            ImGui.Indent()
            
            local safeToLoot = SmartLootEngine.isSafeToLoot()
            local inCombat = SmartLootEngine.isInCombat()
            local lootWindow = SmartLootEngine.isLootWindowOpen()
            local cursorItem = SmartLootEngine.isItemOnCursor()
            
            ImGui.Text("Safe to Loot: ")
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, safeToLoot and 0 or 1, safeToLoot and 1 or 0, 0, 1)
            ImGui.Text(safeToLoot and "YES" or "NO")
            ImGui.PopStyleColor()
            
            ImGui.Text("In Combat: ")
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, inCombat and 1 or 0, inCombat and 0 or 1, 0, 1)
            ImGui.Text(inCombat and "YES" or "NO")
            ImGui.PopStyleColor()
            
            ImGui.Text("Loot Window Open: " .. (lootWindow and "YES" or "NO"))
            ImGui.Text("Item on Cursor: " .. (cursorItem and "YES" or "NO"))
            ImGui.Text("Game State: " .. (mq.TLO.MacroQuest.GameState() or "Unknown"))
            ImGui.Text("Character HP: " .. (mq.TLO.Me.CurrentHPs() or 0) .. "/" .. (mq.TLO.Me.MaxHPs() or 0))
            
            ImGui.Unindent()
        end
        
        -- Current Processing Context
        if ImGui.CollapsingHeader("Current Processing") then
            ImGui.Indent()
            
            ImGui.Text("Current Corpse ID: " .. (state.currentCorpseID > 0 and tostring(state.currentCorpseID) or "None"))
            ImGui.Text("Current Item Index: " .. state.currentItemIndex)
            ImGui.Text("Current Item Name: " .. (state.currentItemName ~= "" and state.currentItemName or "None"))
            ImGui.Text("Total Items on Corpse: " .. (engineState.totalItemsOnCorpse or 0))
            ImGui.Text("Corpse Distance: " .. string.format("%.1f", engineState.currentCorpseDistance or 0))
            
            if engineState.currentItem and engineState.currentItem.name ~= "" then
                ImGui.Separator()
                ImGui.Text("Current Item Details:")
                ImGui.Indent()
                ImGui.Text("Name: " .. engineState.currentItem.name)
                ImGui.Text("Rule: " .. engineState.currentItem.rule)
                ImGui.Text("Action: " .. getActionName(engineState.currentItem.action or 0))
                ImGui.Text("Item ID: " .. engineState.currentItem.itemID)
                ImGui.Text("Icon ID: " .. engineState.currentItem.iconID)
                ImGui.Text("Quantity: " .. engineState.currentItem.quantity)
                ImGui.Unindent()
            end
            
            ImGui.Unindent()
        end
        
        -- Corpse Detection
        if ImGui.CollapsingHeader("Corpse Detection") then
            ImGui.Indent()
            
            local radius = config.lootRadius
            local center = SmartLootEngine.getEffectiveCenter()
            local query = string.format("npccorpse radius %d loc %.1f %.1f %.1f", radius, center.x, center.y, center.z)
            local corpseCount = mq.TLO.SpawnCount(query)() or 0
            local totalCorpses = mq.TLO.SpawnCount("npccorpse")() or 0

            ImGui.Text("Search Radius: " .. radius)
            ImGui.Text(string.format("Search Center: %.1f, %.1f, %.1f", center.x, center.y, center.z))
            ImGui.Text("Corpses in Radius: " .. corpseCount)
            ImGui.Text("Total Zone Corpses: " .. totalCorpses)
            ImGui.Text("Processed This Session: " .. (engineState.sessionCorpseCount or 0))

            if corpseCount > 0 then
                ImGui.Separator()
                ImGui.Text("Nearby Corpses:")
                for i = 1, math.min(corpseCount, 5) do
                    local corpse = mq.TLO.NearestSpawn(i, query)
                    if corpse() then
                        local corpseID = corpse.ID()
                        local distance = corpse.Distance() or 999
                        local corpseName = corpse.Name() or "Unknown"
                        local processed = engineState.processedCorpsesThisSession[corpseID] and "✓" or "✗"
                        
                        ImGui.Text(string.format("  %s [%d] %s (%.1f)", processed, corpseID, corpseName, distance))
                    end
                end
            end
            
            ImGui.Unindent()
        end
        
        -- Action Status
        if ImGui.CollapsingHeader("Action Status") then
            ImGui.Indent()
            
            ImGui.Text("Loot Action in Progress: " .. (engineState.lootActionInProgress and "YES" or "NO"))
            if engineState.lootActionInProgress then
                local elapsed = now - engineState.lootActionStartTime
                ImGui.Text("Action Type: " .. getActionName(engineState.lootActionType))
                ImGui.Text("Action Duration: " .. formatTime(elapsed))
                ImGui.Text("Timeout in: " .. formatTime(math.max(0, engineState.lootActionTimeoutMs - elapsed)))
            end
            
            ImGui.Text("Pending Decision: " .. (state.needsPendingDecision and "YES" or "NO"))
            if state.needsPendingDecision then
                local elapsed = now - engineState.pendingDecisionStartTime
                ImGui.Text("Decision Duration: " .. formatTime(elapsed))
                ImGui.Text("Decision Timeout: " .. formatTime(math.max(0, config.pendingDecisionTimeoutMs - elapsed)))
            end
            
            ImGui.Text("RG Main Triggered: " .. (engineState.rgMainTriggered and "YES" or "NO"))
            
            ImGui.Unindent()
        end
        
        -- Session Statistics
        if ImGui.CollapsingHeader("Session Statistics") then
            ImGui.Indent()
            
            local sessionTime = state.stats.sessionStart and (now - state.stats.sessionStart) / 1000 / 60 or 0 -- minutes
            
            ImGui.Text("Session Duration: " .. string.format("%.1f minutes", sessionTime))
            ImGui.Text("Corpses Processed: " .. (state.stats.corpsesProcessed or 0))
            ImGui.Text("Items Looted: " .. (state.stats.itemsLooted or 0))
            ImGui.Text("Items Ignored: " .. (state.stats.itemsIgnored or 0))
            ImGui.Text("Items Destroyed: " .. (state.stats.itemsDestroyed or 0))
            ImGui.Text("Items Left Behind: " .. (state.stats.itemsLeftBehind or 0))
            ImGui.Text("Peers Triggered: " .. (state.stats.peersTriggered or 0))
            ImGui.Text("Decisions Required: " .. (state.stats.decisionsRequired or 0))
            ImGui.Text("Navigation Timeouts: " .. (state.stats.navigationTimeouts or 0))
            ImGui.Text("Loot Window Failures: " .. (state.stats.lootWindowFailures or 0))
            ImGui.Text("Emergency Stops: " .. (state.stats.emergencyStops or 0))
            
            if sessionTime > 0 then
                ImGui.Separator()
                ImGui.Text("Rates:")
                ImGui.Text("  Corpses/Min: " .. string.format("%.1f", (state.stats.corpsesProcessed or 0) / sessionTime))
                ImGui.Text("  Items/Min: " .. string.format("%.1f", ((state.stats.itemsLooted or 0) + (state.stats.itemsIgnored or 0)) / sessionTime))
            end
            
            -- Database Statistics
            ImGui.Separator()
            ImGui.Text("Database Statistics:")
            
            -- Test database connection and get stats
            local success, corpseCount = pcall(function()
                local lootStats = require("modules.loot_stats")
                local sql = "SELECT COUNT(*) as count FROM loot_stats_corpses WHERE zone_name = '" .. 
                           (mq.TLO.Zone.Name() or "Unknown"):gsub("'", "''") .. "'"
                local rows = lootStats.executeSelect(sql)
                return rows and rows[1] and rows[1].count or 0
            end)
            
            if success then
                ImGui.Text("  Corpses Recorded (This Zone): " .. corpseCount)
            else
                ImGui.Text("  Database Error: " .. tostring(corpseCount))
            end
            
            ImGui.Unindent()
        end
        
        -- Performance Metrics
        if ImGui.CollapsingHeader("Performance") then
            ImGui.Indent()
            
            local perf = state.performance or {}
            
            ImGui.Text("Last Tick Time: " .. string.format("%.2fms", perf.lastTickTime or 0))
            ImGui.Text("Average Tick Time: " .. string.format("%.2fms", perf.averageTickTime or 0))
            ImGui.Text("Total Ticks: " .. (perf.tickCount or 0))
            ImGui.Text("Tick Interval: " .. config.tickIntervalMs .. "ms")
            
            ImGui.Unindent()
        end
        
        -- Configuration
        if ImGui.CollapsingHeader("Configuration") then
            ImGui.Indent()
            
            ImGui.Text("Loot Radius: " .. config.lootRadius)
            ImGui.Text("Loot Range: " .. config.lootRange)
            ImGui.Text("Combat Detection: " .. (config.enableCombatDetection and "Enabled" or "Disabled"))
            ImGui.Text("Peer Coordination: " .. (config.enablePeerCoordination and "Enabled" or "Disabled"))
            ImGui.Text("Statistics Logging: " .. (config.enableStatisticsLogging and "Enabled" or "Disabled"))
            ImGui.Text("Max Nav Time: " .. formatTime(config.maxNavTimeMs))
            ImGui.Text("Pending Decision Timeout: " .. formatTime(config.pendingDecisionTimeoutMs))
            
            ImGui.Unindent()
        end
        
        -- Control Buttons
        ImGui.Separator()
        if ImGui.Button("Emergency Stop") then
            SmartLootEngine.emergencyStop("Debug Window")
        end
        ImGui.SameLine()
        if ImGui.Button("Resume") then
            SmartLootEngine.resume()
        end
        ImGui.SameLine()
        if ImGui.Button("Reset Corpses") then
            SmartLootEngine.resetProcessedCorpses()
        end
        
        if ImGui.Button("Trigger Once Mode") then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "Debug Window")
        end
        ImGui.SameLine()
        if ImGui.Button("Set Background Mode") then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Debug Window")
        end        
    end
    ImGui.End()
end

function debugWindow.toggle(lootUI)
    lootUI.showDebugWindow = not lootUI.showDebugWindow
    if lootUI.showDebugWindow then
        lootUI.forceDebugWindowVisible = true
    end
end

function debugWindow.setVisible(lootUI, visible)
    lootUI.showDebugWindow = visible
    if visible then
        lootUI.forceDebugWindowVisible = true
    end
end

return debugWindow