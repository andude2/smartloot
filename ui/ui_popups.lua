-- ui/ui_popups.lua (Enhanced with improved peer rule workflow)
local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local uiUtils = require("ui.ui_utils")
local util = require("modules.util")
local database = require("modules.database")
local json = require("dkjson")

local uiPopups = {}

-- Loot Decision Popup - REDESIGNED with better layout and consistent button sizing
function uiPopups.drawLootDecisionPopup(lootUI, settings, loot)
    if lootUI.currentItem then
        ImGui.SetNextWindowSize(520, 420)
        local decisionOpen = ImGui.Begin("SmartLoot - Choose Action", true, ImGuiWindowFlags.NoResize)
        if decisionOpen then
            -- Header with item info in a styled box
            ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.2, 0.8)
            ImGui.BeginChild("ItemHeader", 0, 60, true)
            ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 8)
            ImGui.Text("Item requiring decision:")
            ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2)
            ImGui.TextColored(1, 1, 0, 1, lootUI.currentItem.name)
            ImGui.EndChild()
            ImGui.PopStyleColor()
            
            -- Get current item info
            local itemName = lootUI.currentItem.name
            local itemID = lootUI.currentItem.itemID or 0
            local iconID = lootUI.currentItem.iconID or 0
            
            ImGui.Spacing()
            
            -- Rule selection section
            ImGui.Text("Select rule to apply:")
            ImGui.Separator()
            
            -- Initialize selected rule state
            lootUI.pendingDecisionRule = lootUI.pendingDecisionRule or "Keep"
            lootUI.pendingThreshold = lootUI.pendingThreshold or 1
            
            -- Rule dropdown with better spacing
            ImGui.SetNextItemWidth(180)
            if ImGui.BeginCombo("##pendingRule", lootUI.pendingDecisionRule) then
                for _, rule in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan"}) do
                    local isSelected = (lootUI.pendingDecisionRule == rule)
                    if ImGui.Selectable(rule, isSelected) then
                        lootUI.pendingDecisionRule = rule
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            
            -- Threshold input for KeepIfFewerThan
            if lootUI.pendingDecisionRule == "KeepIfFewerThan" then
                ImGui.SameLine()
                ImGui.Text("Threshold:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(80)
                local newThreshold, changedThreshold = ImGui.InputInt("##pendingThreshold", lootUI.pendingThreshold)
                if changedThreshold then
                    lootUI.pendingThreshold = math.max(1, newThreshold)
                end
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Helper function to build final rule string
            local function getFinalRule()
                if lootUI.pendingDecisionRule == "KeepIfFewerThan" then
                    return "KeepIfFewerThan:" .. lootUI.pendingThreshold
                else
                    return lootUI.pendingDecisionRule
                end
            end
            
            -- Helper function to apply rule and queue loot action
            local function applyRuleAndQueue(rule, skipAction)
                local itemID_from_current = lootUI.currentItem.itemID or 0
                local iconID_from_current = lootUI.currentItem.iconID or 0
                
                -- Save the rule locally
                database.saveLootRule(itemName, itemID_from_current, rule, iconID_from_current)
                
                -- Refresh local cache after saving rule
                database.refreshLootRuleCache()
                
                if not skipAction then
                    -- Queue the loot action
                    lootUI.pendingLootAction = {
                        item = lootUI.currentItem,
                        itemID = itemID_from_current,
                        iconID = iconID_from_current,
                        rule = rule,
                        numericCorpseID = lootUI.currentItem.numericCorpseID,
                        startTime = lootUI.currentItem.decisionStartTime
                    }
                end
                
                -- Clear currentItem for immediate processing
                lootUI.currentItem = nil
                lootUI.pendingDecisionRule = "Keep"
                lootUI.pendingThreshold = 1
            end
            
            -- Main action buttons - smaller, side by side with rounded corners
            local buttonWidth = 175
            local buttonHeight = 30
            local roundingRadius = 6
            
            -- Push rounding style for ALL buttons in this popup
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, roundingRadius)
            
            -- OPTION 1: Apply To All (DEFAULT - highlighted and prominent)
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.7, 0.2, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.8, 0.3, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.6, 0.1, 1.0)
            
            if ImGui.Button("Apply To All Connected Peers", buttonWidth, buttonHeight) then
                local rule = getFinalRule()
                local connectedPeers = util.getConnectedPeers()
                local currentCharacter = mq.TLO.Me.Name()
                
                local itemID_from_current = lootUI.currentItem.itemID or 0
                local iconID_from_current = lootUI.currentItem.iconID or 0
                
                logging.debug(string.format("[Popup] Apply All: itemName=%s, itemID=%d, iconID=%d", 
                    itemName, itemID_from_current, iconID_from_current))

                -- Apply to all connected peers
                local appliedCount = 0
                for _, peer in ipairs(connectedPeers) do
                    if peer ~= currentCharacter then
                        if database.saveLootRuleFor then
                            local success = database.saveLootRuleFor(peer, itemName, itemID_from_current, rule, iconID_from_current)
                            if success then
                                appliedCount = appliedCount + 1
                                -- Send reload command to peer
                                util.sendPeerCommand(peer, "/sl_rulescache")
                            end
                        end
                    end
                end
                
                logging.log(string.format("Applied rule '%s' for '%s' to %d connected peers", rule, itemName, appliedCount))
                
                -- Refresh local cache after applying rules to all peers
                database.refreshLootRuleCache()
                
                applyRuleAndQueue(rule)
            end
            ImGui.PopStyleColor(3)
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("RECOMMENDED: Set this rule for yourself AND all connected peers, then process the item")
            end
            
            ImGui.SameLine()
            ImGui.Spacing()
            ImGui.SameLine()
            
            -- OPTION 2: Just me and process
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.8, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.6, 0.9, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.4, 0.7, 1.0)
            
            if ImGui.Button("Apply To Just Me & Process", buttonWidth, buttonHeight) then
                local rule = getFinalRule()
                logging.log(string.format("Setting rule '%s' for '%s' locally only and processing", rule, itemName))
                applyRuleAndQueue(rule, false)
            end
            ImGui.PopStyleColor(3)
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Set rule only for yourself and process the item immediately")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Advanced options section
            ImGui.Text("Advanced Options:")
            ImGui.Spacing()
            
            -- Bottom row: All three buttons in one row
            local buttonWidth = (ImGui.GetContentRegionAvail() - 20) / 3 -- Three buttons per row with spacing
            
            ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.4, 0.8, 0.8)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.5, 0.9, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.3, 0.7, 1.0)
            
            if ImGui.Button("Open Peer Rule Editor", buttonWidth, 30) then
                -- Open the peer item rules popup
                lootUI.peerItemRulesPopup = lootUI.peerItemRulesPopup or {}
                lootUI.peerItemRulesPopup.isOpen = true
                lootUI.peerItemRulesPopup.itemName = itemName
                lootUI.peerItemRulesPopup.itemID = lootUI.currentItem.itemID or 0
                lootUI.peerItemRulesPopup.iconID = lootUI.currentItem.iconID or 0
                
                logging.log(string.format("Opening peer rule editor for item: %s (itemID=%d, iconID=%d)", 
                    itemName, lootUI.currentItem.itemID or 0, lootUI.currentItem.iconID or 0))
            end
            ImGui.PopStyleColor(3)
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Configure rules individually per character")
            end
            
            ImGui.SameLine()
            
            -- Process with Ignore option
            ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.6, 0.2, 0.8)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.7, 0.3, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.5, 0.1, 1.0)
            
            if ImGui.Button("Process as Ignored", buttonWidth, 30) then
                local rule = "Ignore"
                logging.log(string.format("Processing '%s' as ignored - will trigger peer chain", itemName))
                applyRuleAndQueue(rule, false)
            end
            ImGui.PopStyleColor(3)
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Set to 'Ignore' for yourself and trigger peer chain")
            end
            
            ImGui.SameLine()
            
            -- Skip item button
            ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.6, 0.6, 0.8)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.7, 0.7, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.5, 0.5, 1.0)
            
            if ImGui.Button("Skip Item (Leave Unset)", buttonWidth, 30) then
                logging.log("Skipping item " .. itemName .. " - leaving rule unset")
                lootUI.currentItem = nil
                lootUI.pendingDecisionRule = "Keep"
                lootUI.pendingThreshold = 1
                -- Don't queue any loot action - just move on
            end
            ImGui.PopStyleColor(3)
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Skip this item without setting any rule")
            end
            
            -- Pop the rounding style at the very end, after all buttons
            ImGui.PopStyleVar()
            
            ImGui.Spacing()
            ImGui.Separator()
            
            -- Help text at bottom
            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1)
            ImGui.TextWrapped("Tip: Use 'Peer Rule Editor' to set different rules per character, then 'Process as Ignored' to trigger the peer chain.")
            ImGui.PopStyleColor()
            
        end
        ImGui.End()
        
        -- If window was closed, clean up state
        if not decisionOpen then
            lootUI.currentItem = nil
            lootUI.pendingDecisionRule = "Keep"
            lootUI.pendingThreshold = 1
        end
    end
end

-- Peer Item Rules Popup (ENHANCED with better workflow integration)
function uiPopups.drawPeerItemRulesPopup(lootUI, database, util)
    if lootUI.peerItemRulesPopup and lootUI.peerItemRulesPopup.isOpen then
        local windowTitle = "Peer Rules for: " .. (lootUI.peerItemRulesPopup.itemName or "Unknown Item")
        
        logging.debug(string.format("[PeerRulesPopup] Opened for: %s (itemID=%d, iconID=%d)", 
            lootUI.peerItemRulesPopup.itemName or "Unknown", 
            lootUI.peerItemRulesPopup.itemID or 0, 
            lootUI.peerItemRulesPopup.iconID or 0))
        
        -- Clear states if item changed
        if lootUI.peerItemRulesPopup.lastItemName and 
           lootUI.peerItemRulesPopup.lastItemName ~= lootUI.peerItemRulesPopup.itemName then
            lootUI.peerItemRulesPopup.peerStates = {}
        end
        lootUI.peerItemRulesPopup.lastItemName = lootUI.peerItemRulesPopup.itemName
        
        -- Clear recentlyChanged flags after a delay to allow database to update
        if lootUI.peerItemRulesPopup.peerStates then
            local currentTime = mq.gettime()
            for peer, peerState in pairs(lootUI.peerItemRulesPopup.peerStates) do
                if peerState.recentlyChanged and peerState.changeTime and 
                   (currentTime - peerState.changeTime) > 2000 then -- 2 second delay
                    peerState.recentlyChanged = false
                    peerState.changeTime = nil
                end
            end
        end
        
        ImGui.SetNextWindowSize(500, 400, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin(windowTitle, keepOpen) then
            ImGui.Text("Configure rules for '" .. (lootUI.peerItemRulesPopup.itemName or "") .. "' across all peers.")
            ImGui.Separator()

            -- Build peer list outside of table scope so it's available for buttons
            local peerList = {}
            local currentCharacter = mq.TLO.Me.Name()
            if currentCharacter then
                table.insert(peerList, currentCharacter)
            end

            -- Add connected peers
            local connectedPeers = util.getConnectedPeers()
            local connectedPeerSet = {}
            for _, peer in ipairs(connectedPeers) do
                connectedPeerSet[peer] = true
                if peer ~= currentCharacter then
                    table.insert(peerList, peer)
                end
            end

            -- Add other characters that have rules in database
            local allCharacters = database.getAllCharactersWithRules()
            logging.debug(string.format("[PeerRules] getAllCharactersWithRules returned: %s", 
                                      table.concat(allCharacters or {}, ", ")))
            
            for _, charName in ipairs(allCharacters) do
                if charName ~= currentCharacter then
                    local alreadyAdded = false
                    for _, existingPeer in ipairs(peerList) do
                        if existingPeer == charName then
                            alreadyAdded = true
                            break
                        end
                    end
                    if not alreadyAdded then
                        table.insert(peerList, charName)
                        logging.debug(string.format("[PeerRules] Added character from DB: %s", charName))
                    end
                end
            end

            -- Sort peer list alphabetically, keeping current character first
            table.sort(peerList, function(a, b)
                if a == currentCharacter then return true end
                if b == currentCharacter then return false end
                return a < b
            end)
            
            logging.debug(string.format("[PeerRules] Final peer list: %s", table.concat(peerList, ", ")))

            -- Quick Actions section - moved above table for better UX
            ImGui.Text("Quick Actions:")
            
            if ImGui.Button("Set All to Keep") then
                local itemName = lootUI.peerItemRulesPopup.itemName
                -- Use the itemID and iconID from the popup
                local itemID = lootUI.peerItemRulesPopup.itemID or 0
                local iconID = lootUI.peerItemRulesPopup.iconID or 0
                
                logging.debug(string.format("[SetAllKeep] PeerList has %d entries: %s", #peerList, table.concat(peerList, ", ")))
                logging.debug(string.format("[SetAllKeep] ConnectedPeers: %s", table.concat(connectedPeers or {}, ", ")))
                
                local updateCount = 0
                for _, peer in ipairs(peerList) do
                    if peer == currentCharacter then
                        local success = database.saveLootRule(itemName, itemID, "Keep", iconID)
                        if success then
                            updateCount = updateCount + 1
                            logging.debug(string.format("[SetAllKeep] Updated local character: %s", peer))
                        end
                    else
                        local success = database.saveLootRuleFor(peer, itemName, itemID, "Keep", iconID)
                        if success then
                            updateCount = updateCount + 1
                            logging.debug(string.format("[SetAllKeep] Updated peer: %s", peer))
                        end
                        if connectedPeerSet[peer] then
                            util.sendPeerCommand(peer, "/sl_rulescache")
                        end
                    end
                end
                logging.log(string.format("Set all %d peers to 'Keep' for %s", updateCount, itemName))
            end
            
            ImGui.SameLine()
            
            if ImGui.Button("Set All to Ignore") then
                local itemName = lootUI.peerItemRulesPopup.itemName
                -- Use the itemID and iconID from the popup
                local itemID = lootUI.peerItemRulesPopup.itemID or 0
                local iconID = lootUI.peerItemRulesPopup.iconID or 0
                
                logging.debug(string.format("[SetAllIgnore] PeerList has %d entries: %s", 
                                          #peerList, table.concat(peerList, ", ")))
                logging.debug(string.format("[SetAllIgnore] ConnectedPeers: %s", 
                                          table.concat(connectedPeers or {}, ", ")))
                
                local updateCount = 0
                for _, peer in ipairs(peerList) do
                    if peer == currentCharacter then
                        local success = database.saveLootRule(itemName, itemID, "Ignore", iconID)
                        if success then
                            updateCount = updateCount + 1
                            logging.debug(string.format("[SetAllIgnore] Updated local character: %s", peer))
                        end
                    else
                        local success = database.saveLootRuleFor(peer, itemName, itemID, "Ignore", iconID)
                        if success then
                            updateCount = updateCount + 1
                            logging.debug(string.format("[SetAllIgnore] Updated peer: %s", peer))
                        end
                        if connectedPeerSet[peer] then
                            util.sendPeerCommand(peer, "/sl_rulescache")
                        end
                    end
                end
                logging.log(string.format("Set all %d peers to 'Ignore' for %s", updateCount, itemName))
            end
            
            ImGui.SameLine()
            
            if ImGui.Button("Close") then
                keepOpen = false
            end
            
            -- Add context help
            ImGui.SameLine()
            ImGui.TextColored(0.7, 0.7, 0.7, 1, " - Configure rules here, then return to loot decision")
            
            ImGui.Separator()

            if ImGui.BeginTable("PeerItemRulesTable", 3, 
                ImGuiTableFlags.BordersInnerV + 
                ImGuiTableFlags.RowBg + 
                ImGuiTableFlags.Resizable) then
                
                ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()

                -- Initialize persistent state for peer rules if not exists
                if not lootUI.peerItemRulesPopup.peerStates then
                    lootUI.peerItemRulesPopup.peerStates = {}
                end

                for _, peer in ipairs(peerList) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    
                    if peer == currentCharacter then
                        ImGui.TextColored(0.2, 0.8, 0.2, 1, peer .. " (You)")
                    else
                        if connectedPeerSet[peer] then
                            ImGui.TextColored(0.2, 0.6, 0.8, 1, peer .. " (Online)")
                        else
                            ImGui.TextColored(0.7, 0.7, 0.7, 1, peer .. " (Offline)")
                        end
                    end

                    ImGui.TableSetColumnIndex(1)
                    
                    -- Get current rule for this peer
                    local peerRules = database.getLootRulesForPeer(peer)
                    local itemName = lootUI.peerItemRulesPopup.itemName or ""
                    local lowerItemName = string.lower(itemName)
                    local itemID = lootUI.peerItemRulesPopup.itemID or 0
                    
                    -- Try to find the rule - first by composite key if we have an itemID, then by name
                    local ruleData = nil
                    if itemID > 0 then
                        local compositeKey = string.format("%s_%d", itemName, itemID)
                        ruleData = peerRules[compositeKey]
                    end
                    
                    -- Fallback to name-based lookup
                    if not ruleData then
                        ruleData = peerRules[lowerItemName] or peerRules[itemName]
                    end
                    
                    -- Default if no rule found
                    if not ruleData then
                        ruleData = { rule = "", item_id = itemID, icon_id = lootUI.peerItemRulesPopup.iconID or 0 }
                    end
                    
                    local currentRuleStr = ruleData.rule or ""
                    
                    -- Initialize persistent state for this peer if not exists
                    if not lootUI.peerItemRulesPopup.peerStates[peer] then
                        lootUI.peerItemRulesPopup.peerStates[peer] = {
                            displayRule = currentRuleStr,
                            threshold = 1
                        }
                    end
                    
                    local peerState = lootUI.peerItemRulesPopup.peerStates[peer]
                    
                    -- Parse the current rule for display
                    local displayRule, threshold
                    if string.sub(currentRuleStr, 1, 15) == "KeepIfFewerThan" then
                        displayRule = "KeepIfFewerThan"
                        local colonPos = string.find(currentRuleStr, ":")
                        if colonPos then
                            threshold = tonumber(string.sub(currentRuleStr, colonPos + 1)) or 1
                        end
                    elseif currentRuleStr == "" then
                        displayRule = "Unset"
                    else
                        displayRule = currentRuleStr
                    end
                    
                    -- Update persistent state if not recently changed
                    if not peerState.recentlyChanged then
                        peerState.displayRule = displayRule
                        peerState.threshold = threshold or 1
                    end

                    -- Rule combo box
                    if ImGui.BeginCombo("##ruleCombo_" .. peer, peerState.displayRule) then
                        for _, option in ipairs({"Keep", "Ignore", "KeepIfFewerThan", "Destroy", "Unset"}) do
                            local isSelected = (peerState.displayRule == option)
                            if ImGui.Selectable(option, isSelected) then
                                local newRuleValue = option
                                if option == "KeepIfFewerThan" then
                                    newRuleValue = "KeepIfFewerThan:" .. peerState.threshold
                                elseif option == "Unset" then
                                    newRuleValue = ""
                                end

                                if newRuleValue ~= currentRuleStr then
                                    -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                                    local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                                    local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                                    
                                    local success = false
                                    if peer == currentCharacter then
                                        success = database.saveLootRule(itemName, itemID, newRuleValue, iconID)
                                    else
                                        success = database.saveLootRuleFor(peer, itemName, itemID, newRuleValue, iconID)
                                    end
                                    
                                    if success then
                                        -- Update persistent state
                                        peerState.displayRule = (option == "KeepIfFewerThan") and "KeepIfFewerThan" or option
                                        peerState.recentlyChanged = true
                                        peerState.changeTime = mq.gettime()
                                        logging.debug(string.format("[PeerRules] Successfully saved rule '%s' for %s -> %s (itemID=%d, iconID=%d)", 
                                            newRuleValue, peer, itemName, itemID, iconID))
                                        
                                        -- Force refresh of rules cache
                                        if peer == currentCharacter then
                                            database.refreshLootRuleCache()
                                        else
                                            database.refreshLootRuleCacheForPeer(peer)
                                        end
                                        
                                        -- Send command only for connected peers after change
                                        if peer ~= currentCharacter and connectedPeerSet[peer] then
                                            util.sendPeerCommand(peer, "/sl_rulescache")
                                        end
                                        
                                        -- Debug: Check if rule is in cache after refresh
                                        local testRules = database.getLootRulesForPeer(peer)
                                        local testKey = itemID > 0 and string.format("%s_%d", itemName, itemID) or itemName
                                        local testRule = testRules[testKey]
                                        if testRule then
                                            logging.debug(string.format("[PeerRules] Verified rule in cache: key=%s, rule=%s", testKey, testRule.rule))
                                        else
                                            logging.debug(string.format("[PeerRules] WARNING: Rule not found in cache after refresh! key=%s", testKey))
                                        end
                                    else
                                        logging.debug(string.format("[PeerRules] Failed to save rule '%s' for %s -> %s", newRuleValue, peer, itemName))
                                    end
                                end
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.EndCombo()
                    end

                    -- Threshold input for KeepIfFewerThan
                    if peerState.displayRule == "KeepIfFewerThan" then
                        ImGui.SameLine()
                        local newThreshold, changedThreshold = ImGui.InputInt("##threshold_" .. peer, peerState.threshold)
                        if changedThreshold then
                            newThreshold = math.max(1, newThreshold)
                            if newThreshold ~= peerState.threshold then
                                local updatedRule = "KeepIfFewerThan:" .. newThreshold
                                -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                                local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                                local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                                
                                local success = false
                                if peer == currentCharacter then
                                    success = database.saveLootRule(itemName, itemID, updatedRule, iconID)
                                else
                                    success = database.saveLootRuleFor(peer, itemName, itemID, updatedRule, iconID)
                                end
                                
                                if success then
                                    peerState.threshold = newThreshold
                                    peerState.recentlyChanged = true
                                    peerState.changeTime = mq.gettime()
                                    logging.debug(string.format("[PeerRules] Successfully updated threshold to %d for %s -> %s", newThreshold, peer, itemName))
                                    
                                    -- Force refresh of rules cache
                                    if peer == currentCharacter then
                                        database.refreshLootRuleCache()
                                    else
                                        database.refreshLootRuleCacheForPeer(peer)
                                    end
                                    
                                    -- Send command only for connected peers after change
                                    if peer ~= currentCharacter and connectedPeerSet[peer] then
                                        util.sendPeerCommand(peer, "/sl_rulescache")
                                    end
                                else
                                    logging.debug(string.format("[PeerRules] Failed to update threshold to %d for %s -> %s", newThreshold, peer, itemName))
                                end
                            end
                        end
                    end

                    ImGui.TableSetColumnIndex(2)
                    if ImGui.Button("Unset##" .. peer) then
                        if currentRuleStr ~= "" then
                            -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                            local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                            local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                            
                            local success = false
                            if peer == currentCharacter then
                                success = database.saveLootRule(itemName, itemID, "", iconID)
                            else
                                success = database.saveLootRuleFor(peer, itemName, itemID, "", iconID)
                            end
                            
                            if success then
                                peerState.displayRule = "Unset"
                                peerState.recentlyChanged = true
                                peerState.changeTime = mq.gettime()
                                logging.debug(string.format("[PeerRules] Successfully unset rule for %s -> %s", peer, itemName))
                                
                                -- Force refresh of rules cache
                                if peer == currentCharacter then
                                    database.refreshLootRuleCache()
                                else
                                    database.refreshLootRuleCacheForPeer(peer)
                                end
                                
                                -- Send command only for connected peers after change
                                if peer ~= currentCharacter and connectedPeerSet[peer] then
                                    util.sendPeerCommand(peer, "/sl_rulescache")
                                end
                            else
                                logging.debug(string.format("[PeerRules] Failed to unset rule for %s -> %s", peer, itemName))
                            end
                        end
                    end
                end
                ImGui.EndTable()
            end

        end
        ImGui.End()

        if not keepOpen then
            lootUI.peerItemRulesPopup.isOpen = false
            lootUI.peerItemRulesPopup.itemName = ""
            -- Don't clear peerStates - let them persist to remember dropdown selections
        end
    end
end

-- Update ItemID/IconID Popup
function uiPopups.drawUpdateIDsPopup(lootUI, database, util)
    if lootUI.updateIDsPopup and lootUI.updateIDsPopup.isOpen then
        local windowTitle = "Update ItemID/IconID: " .. (lootUI.updateIDsPopup.itemName or "Unknown Item")
        
        ImGui.SetNextWindowSize(500, 350, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin(windowTitle, keepOpen) then
            local popup = lootUI.updateIDsPopup
            
            -- Header with item info
            ImGui.BeginGroup()
            if popup.currentIconID and popup.currentIconID > 0 then
                uiUtils.drawItemIcon(popup.currentIconID)
            else
                ImGui.Text("[No Icon]")
            end
            ImGui.SameLine()
            ImGui.BeginGroup()
            ImGui.Text("Item: " .. (popup.itemName or ""))
            ImGui.Text("Current ItemID: " .. (popup.currentItemID or 0))
            ImGui.Text("Current IconID: " .. (popup.currentIconID or 0))
            ImGui.EndGroup()
            ImGui.EndGroup()

            ImGui.Separator()

            -- Instructions
            ImGui.TextWrapped("This will update the ItemID and IconID for this item across ALL characters who have rules for it. " ..
                "This is useful when you have better item information (like from actually seeing the item in-game) " ..
                "that you want to propagate to all your characters.")

            ImGui.Separator()

            -- Input fields
            ImGui.Text("New Values:")

            -- ItemID input
            ImGui.Text("New ItemID:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            local newItemID, changedItemID = ImGui.InputInt("##newItemID", popup.newItemID or 0)
            if changedItemID then
                popup.newItemID = math.max(0, newItemID)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("The game's internal ItemID for this item")
            end

            -- Show change indicator for ItemID
            ImGui.SameLine()
            if (popup.newItemID or 0) ~= (popup.currentItemID or 0) then
                if (popup.newItemID or 0) == 0 then
                    ImGui.TextColored(0.8, 0.6, 0.2, 1, "(will clear ItemID)")
                else
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "(changed from " .. (popup.currentItemID or 0) .. ")")
                end
            else
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "(unchanged)")
            end

            -- IconID input with live preview
            ImGui.Text("New IconID:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            local newIconID, changedIconID = ImGui.InputInt("##newIconID", popup.newIconID or 0)
            if changedIconID then
                popup.newIconID = math.max(0, newIconID)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("The icon ID used to display this item's icon")
            end

            -- Live icon preview
            ImGui.SameLine()
            if popup.newIconID and popup.newIconID > 0 then
                uiUtils.drawItemIcon(popup.newIconID)
                ImGui.SameLine()
            end

            -- Show change indicator for IconID
            if (popup.newIconID or 0) ~= (popup.currentIconID or 0) then
                if (popup.newIconID or 0) == 0 then
                    ImGui.TextColored(0.8, 0.6, 0.2, 1, "(will clear IconID)")
                else
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "(changed from " .. (popup.currentIconID or 0) .. ")")
                end
            else
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "(unchanged)")
            end

            -- Icon comparison if changed
            if (popup.newIconID or 0) ~= (popup.currentIconID or 0) and 
               popup.newIconID and popup.newIconID > 0 and 
               popup.currentIconID and popup.currentIconID > 0 then
                ImGui.Separator()
                ImGui.Text("Icon Comparison:")

                -- Current icon
                ImGui.BeginGroup()
                ImGui.Text("Current (" .. popup.currentIconID .. "):")
                uiUtils.drawItemIcon(popup.currentIconID)
                ImGui.EndGroup()

                ImGui.SameLine()
                ImGui.Text(" -> ")
                ImGui.SameLine()

                -- New icon
                ImGui.BeginGroup()
                ImGui.Text("New (" .. popup.newIconID .. "):")
                uiUtils.drawItemIcon(popup.newIconID)
                ImGui.EndGroup()
            end

            ImGui.Separator()

            -- Get list of affected characters
            local allCharacters = database.getAllCharactersWithRules()
            local affectedCharacters = {}
            
            for _, character in ipairs(allCharacters) do
                local peerRules = database.getLootRulesForPeer(character)
                local lowerItemName = string.lower(popup.itemName or "")
                local itemName = popup.itemName or ""
                local currentItemID = popup.currentItemID or 0
                
                -- Check both name-based and composite key lookups
                local hasRule = false
                
                -- Try composite key first if we have an itemID
                if currentItemID > 0 then
                    local compositeKey = string.format("%s_%d", itemName, currentItemID)
                    if peerRules[compositeKey] then
                        hasRule = true
                    end
                end
                
                -- Try name-based lookup
                if not hasRule and (peerRules[lowerItemName] or peerRules[itemName]) then
                    hasRule = true
                end
                
                -- Also check all rules to find any that match the item name
                if not hasRule then
                    for key, ruleData in pairs(peerRules) do
                        if ruleData.item_name and 
                           (string.lower(ruleData.item_name) == lowerItemName or ruleData.item_name == itemName) then
                            hasRule = true
                            break
                        end
                    end
                end
                
                if hasRule then
                    table.insert(affectedCharacters, character)
                end
            end

            -- Show affected characters
            if #affectedCharacters > 0 then
                ImGui.Text("Characters with rules for this item (" .. #affectedCharacters .. "):")
                ImGui.BeginChild("AffectedCharactersList", 0, 80, true)
                for _, character in ipairs(affectedCharacters) do
                    local currentChar = mq.TLO.Me.Name()
                    if character == currentChar then
                        ImGui.TextColored(0.2, 0.8, 0.2, 1, character .. " (Current)")
                    else
                        ImGui.Text(character)
                    end
                end
                ImGui.EndChild()
            else
                ImGui.TextColored(0.8, 0.6, 0.2, 1, "No characters found with rules for this item.")
            end

            ImGui.Separator()

            -- Action buttons
            local hasChanges = ((popup.newItemID or 0) ~= (popup.currentItemID or 0)) or 
                              ((popup.newIconID or 0) ~= (popup.currentIconID or 0))

            if not hasChanges then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
            else
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
            end

            if ImGui.Button("Update All Characters", 150, 0) and hasChanges then
                -- Update all affected characters
                local updateCount = 0
                local itemName = popup.itemName or ""
                local newItemID = popup.newItemID or popup.currentItemID or 0
                local newIconID = popup.newIconID or popup.currentIconID or 0
                
                logging.debug(string.format("[UpdateIDs] Starting update for '%s': currentID=%d->%d, iconID=%d->%d, affected=%d", 
                                          itemName, popup.currentItemID or 0, newItemID, 
                                          popup.currentIconID or 0, newIconID, #affectedCharacters))

                for _, character in ipairs(affectedCharacters) do
                    local peerRules = database.getLootRulesForPeer(character)
                    local lowerItemName = string.lower(itemName)
                    local currentItemID = popup.currentItemID or 0
                    
                    -- Find the current rule using the same logic as detection
                    local currentRule = nil
                    local foundKey = nil
                    
                    -- Try composite key first if we have an itemID
                    if currentItemID > 0 then
                        local compositeKey = string.format("%s_%d", itemName, currentItemID)
                        if peerRules[compositeKey] then
                            currentRule = peerRules[compositeKey]
                            foundKey = compositeKey
                        end
                    end
                    
                    -- Try name-based lookup
                    if not currentRule then
                        currentRule = peerRules[lowerItemName] or peerRules[itemName]
                        foundKey = currentRule and (peerRules[lowerItemName] and lowerItemName or itemName)
                    end
                    
                    -- Search all rules if still not found
                    if not currentRule then
                        for key, ruleData in pairs(peerRules) do
                            if ruleData.item_name and 
                               (string.lower(ruleData.item_name) == lowerItemName or ruleData.item_name == itemName) then
                                currentRule = ruleData
                                foundKey = key
                                break
                            end
                        end
                    end
                    
                    if currentRule then
                        logging.debug(string.format("[UpdateIDs] Updating %s: found rule with key '%s', rule='%s'", 
                                                  character, foundKey or "unknown", currentRule.rule or ""))
                        
                        -- Save with new IDs
                        local success = database.saveLootRuleFor(character, itemName, newItemID, currentRule.rule, newIconID)
                        if success then
                            updateCount = updateCount + 1
                            
                            -- If the old key was different from what the new one will be, we might need to delete the old entry
                            if currentItemID > 0 and newItemID ~= currentItemID then
                                -- The saveLootRuleFor should handle this, but let's log it
                                logging.debug(string.format("[UpdateIDs] ItemID changed from %d to %d for %s", 
                                                          currentItemID, newItemID, character))
                            end
                        else
                            logging.debug(string.format("[UpdateIDs] Failed to update rule for %s", character))
                        end
                        
                        -- Send reload command to connected peers
                        local connectedPeers = util.getConnectedPeers()
                        for _, connectedPeer in ipairs(connectedPeers) do
                            if connectedPeer == character then
                                util.sendPeerCommand(peer, "/sl_rulescache")
                                break
                            end
                        end
                    else
                        logging.debug(string.format("[UpdateIDs] No rule found for %s (this shouldn't happen!)", character))
                    end
                end

                -- Refresh current character's rules if affected
                local currentChar = mq.TLO.Me.Name()
                for _, character in ipairs(affectedCharacters) do
                    if character == currentChar then
                        database.refreshLootRuleCache()
                        break
                    end
                end

                logging.log(string.format("SmartLoot: Updated ItemID/IconID for '%s' across %d characters", itemName, updateCount))
                keepOpen = false
            end
            ImGui.PopStyleColor(3)

            if not hasChanges and ImGui.IsItemHovered() then
                ImGui.SetTooltip("No changes detected. Modify ItemID or IconID to enable update.")
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 80, 0) then
                keepOpen = false
            end

            ImGui.SameLine()
            if ImGui.Button("Reset", 80, 0) then
                popup.newItemID = popup.currentItemID
                popup.newIconID = popup.currentIconID
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Reset values to current ItemID/IconID")
            end

            ImGui.Separator()

            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("You can get ItemID/IconID by examining items in-game")
            ImGui.BulletText("This update preserves all existing rules, only updating the IDs")
            ImGui.BulletText("Connected peers will automatically reload their rules")
        end
        ImGui.End()

        if not keepOpen then
            lootUI.updateIDsPopup.isOpen = false
            lootUI.updateIDsPopup.itemName = ""
            lootUI.updateIDsPopup.currentItemID = 0
            lootUI.updateIDsPopup.currentIconID = 0
            lootUI.updateIDsPopup.newItemID = 0
            lootUI.updateIDsPopup.newIconID = 0
        end
    end
end

-- Loot Stats Popup
function uiPopups.drawLootStatsPopup(lootUI, lootStats)
    if lootUI.selectedStatItem then
        ImGui.SetNextWindowSize(400, 300, ImGuiCond.FirstUseEver)
        local popupOpen = ImGui.Begin("Loot Stats for " .. lootUI.selectedStatItem, true)
        if popupOpen then
            local zoneStats = lootStats.getItemDropRates(lootUI.selectedStatItem) or {}
            if ImGui.BeginTable("ZoneStatsTable", 4, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                ImGui.TableSetupColumn("Zone", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Drops", ImGuiTableColumnFlags.WidthFixed, 50)
                ImGui.TableSetupColumn("Corpses", ImGuiTableColumnFlags.WidthFixed, 50)
                ImGui.TableSetupColumn("Drop Rate %", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()
                for _, zoneStat in ipairs(zoneStats) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(zoneStat.zone_name or "")
                    ImGui.TableSetColumnIndex(1)
                    ImGui.Text(tostring(zoneStat.drop_count or 0))
                    ImGui.TableSetColumnIndex(2)
                    ImGui.Text(tostring(zoneStat.corpse_count or 0))
                    ImGui.TableSetColumnIndex(3)
                    ImGui.Text(string.format("%.2f", zoneStat.drop_rate or 0))
                end
                ImGui.EndTable()
            else
                ImGui.Text("No detailed stats available.")
            end

            if ImGui.Button("Close") then
                lootUI.selectedStatItem = nil
            end
        end
        ImGui.End()
    end
end

-- Enhanced Loot Rules Popup with right-click context menu
function uiPopups.drawLootRulesPopup(lootUI, database, util)
    if lootUI.selectedItemForPopup then
        ImGui.SetNextWindowSize(400, 300, ImGuiCond.FirstUseEver)
        local popupOpen = ImGui.Begin("Loot Rules for " .. lootUI.selectedItemForPopup, true)
        if popupOpen then
            if ImGui.BeginTable("LootRulesPopupTable", 2, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableHeadersRow()

                local peerList = { mq.TLO.Me.Name() or "Local" }
                local connectedPeers = util.getConnectedPeers()
                for _, peer in ipairs(connectedPeers) do
                    if peer ~= (mq.TLO.Me.Name() or "Local") then
                        table.insert(peerList, peer)
                    end
                end

                for _, peer in ipairs(peerList) do
                    ImGui.TableNextRow()

                    ImGui.TableSetColumnIndex(0)
                    -- Make the peer name selectable for right-click context menu
                    local selectableId = peer .. "##peer_" .. lootUI.selectedItemForPopup
                    local isRowSelected = ImGui.Selectable(selectableId, false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowItemOverlap)

                    -- Handle right-click context menu for Update IDs
                    if ImGui.BeginPopupContextItem("ContextMenu##" .. peer .. "_" .. lootUI.selectedItemForPopup) then
                        ImGui.Text("Actions for: " .. lootUI.selectedItemForPopup)
                        ImGui.Separator()

                        if ImGui.MenuItem("Update ItemID/IconID for All Peers") then
                            -- Set up the update IDs popup
                            lootUI.updateIDsPopup = lootUI.updateIDsPopup or {}
                            lootUI.updateIDsPopup.isOpen = true
                            lootUI.updateIDsPopup.itemName = lootUI.selectedItemForPopup
                            
                            -- Get current rule data to populate IDs
                            local ruleData = database.getLootRulesForPeer(peer)[string.lower(lootUI.selectedItemForPopup)] or 
                                           database.getLootRulesForPeer(peer)[lootUI.selectedItemForPopup] or 
                                           { rule = "", item_id = 0, icon_id = 0 }
                            
                            lootUI.updateIDsPopup.currentItemID = ruleData.item_id or 0
                            lootUI.updateIDsPopup.currentIconID = ruleData.icon_id or 0
                            lootUI.updateIDsPopup.newItemID = ruleData.item_id or 0
                            lootUI.updateIDsPopup.newIconID = ruleData.icon_id or 0
                        end

                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Update ItemID and IconID for this item across all characters/peers")
                        end

                        ImGui.EndPopup()
                    end

                    ImGui.TableSetColumnIndex(1)
                    local ruleData = database.getLootRulesForPeer(peer)[string.lower(lootUI.selectedItemForPopup)] or 
                                   database.getLootRulesForPeer(peer)[lootUI.selectedItemForPopup] or 
                                   { rule = "Unset" }
                    local currentRule = ruleData.rule
                    local displayRule = currentRule or "Unset"
                    local threshold = 1

                    if currentRule and string.sub(currentRule, 1, 15) == "KeepIfFewerThan" then
                        displayRule = "KeepIfFewerThan"
                        local t = currentRule:match(":(%d+)")
                        threshold = tonumber(t) or 1
                    end

                    if ImGui.BeginCombo("##ruleCombo_" .. peer, displayRule) then
                        for _, option in ipairs({"Keep", "Ignore", "KeepIfFewerThan", "Destroy"}) do
                            local isSelected = (displayRule == option)
                            if ImGui.Selectable(option, isSelected) then
                                local newRule = option
                                if option == "KeepIfFewerThan" then
                                    newRule = "KeepIfFewerThan:" .. threshold
                                end
                                if peer == (mq.TLO.Me.Name() or "Local") then
                                    local itemID = ruleData.item_id or 0
                                    local iconID = ruleData.icon_id or 0
                                    database.saveLootRule(lootUI.selectedItemForPopup, itemID, newRule, iconID)
                                else
                                    database.saveLootRuleFor(peer, lootUI.selectedItemForPopup, ruleData.item_id, newRule, ruleData.icon_id)
                                    util.sendPeerCommand(peer, "/sl_rulescache")
                                end
                                currentRule = newRule
                                displayRule = (option == "KeepIfFewerThan") and "KeepIfFewerThan" or newRule
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.EndCombo()
                    end

                    if displayRule == "KeepIfFewerThan" then
                        ImGui.SameLine()
                        local newThreshold, changedThreshold = ImGui.InputInt("##threshold_" .. peer, threshold, 0, 0)
                        if changedThreshold then
                            newThreshold = math.max(1, newThreshold)
                            local newRule = "KeepIfFewerThan:" .. newThreshold
                            if peer == (mq.TLO.Me.Name() or "Local") then
                                database.saveLootRule(lootUI.selectedItemForPopup, ruleData.item_id, newRule, ruleData.icon_id)
                            else
                                database.saveLootRuleFor(peer, lootUI.selectedItemForPopup, ruleData.item_id, newRule, ruleData.icon_id)
                                util.sendPeerCommand(peer, "/sl_rulescache")
                            end
                            currentRule = newRule
                            displayRule = "KeepIfFewerThan"
                            threshold = newThreshold
                        end
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Separator()
            if ImGui.Button("Close") then
                lootUI.selectedItemForPopup = nil
            end
        end
        ImGui.End()

        if not popupOpen then
            lootUI.selectedItemForPopup = nil
        end
    end
end

-- KeepIfFewerThan Threshold Popup
function uiPopups.drawThresholdPopup(lootUI, database)
    if lootUI.editingThresholdForPeer then
        ImGui.SetNextWindowSize(300, 150)
        ImGui.OpenPopup("KeepIfFewerThanThreshold")

        if ImGui.BeginPopupModal("KeepIfFewerThanThreshold", nil, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("Set threshold for:")
            ImGui.TextColored(1, 1, 0, 1, lootUI.editingThresholdForPeer.itemName)
            ImGui.Text("Peer: " .. lootUI.editingThresholdForPeer.peer)
            ImGui.Separator()

            ImGui.Text("Keep if fewer than:")
            ImGui.SameLine()
            local newThreshold, changedThreshold = ImGui.InputInt("##thresholdPopup", lootUI.editingThresholdForPeer.threshold, 1)
            if changedThreshold then
                lootUI.editingThresholdForPeer.threshold = math.max(1, newThreshold)
            end

            ImGui.Separator()

            if ImGui.Button("Apply", 120, 0) then
                local newRule = "KeepIfFewerThan:" .. lootUI.editingThresholdForPeer.threshold
                local rule, itemID, iconID
                if lootUI.editingThresholdForPeer.peer == "Local" then
                    rule, itemID, iconID = database.getLootRule(lootUI.editingThresholdForPeer.itemName, true)
                    database.saveLootRule(lootUI.editingThresholdForPeer.itemName, itemID, newRule, iconID)
                else
                    rule, itemID, iconID = database.getLootRule(lootUI.editingThresholdForPeer.itemName, true)
                    database.saveLootRuleFor(
                        lootUI.editingThresholdForPeer.peer,
                        lootUI.editingThresholdForPeer.itemName,
                        itemID,
                        newRule,
                        iconID
                    )
                end
                logging.log("Set " .. newRule .. " rule for " .. lootUI.editingThresholdForPeer.itemName ..
                            " on " .. lootUI.editingThresholdForPeer.peer)
                lootUI.editingThresholdForPeer = nil
                ImGui.CloseCurrentPopup()
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 120, 0) then
                lootUI.editingThresholdForPeer = nil
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        end
    end
end

-- Add New Rule Popup
function uiPopups.drawAddNewRulePopup(lootUI, database, util)
    if lootUI.addNewRulePopup and lootUI.addNewRulePopup.isOpen then
        ImGui.SetNextWindowSize(400, 250, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin("Add New Loot Rule", keepOpen) then
            local popup = lootUI.addNewRulePopup
            
            ImGui.Text("Create a new loot rule:")
            ImGui.Separator()

            -- Item name input
            ImGui.Text("Item Name:")
            ImGui.SetNextItemWidth(300)
            local newItemName, changedItemName = ImGui.InputText("##newItemName", popup.itemName or "")
            if changedItemName then
                popup.itemName = newItemName
            end

            -- Rule selection
            ImGui.Text("Rule:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(120)
            if ImGui.BeginCombo("##newRule", popup.rule or "Keep") then
                for _, ruleOption in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan"}) do
                    local isSelected = (popup.rule == ruleOption)
                    if ImGui.Selectable(ruleOption, isSelected) then
                        popup.rule = ruleOption
                        if ruleOption == "KeepIfFewerThan" then
                            popup.threshold = popup.threshold or 1
                        end
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end

            -- Threshold input for KeepIfFewerThan
            if popup.rule == "KeepIfFewerThan" then
                ImGui.SameLine()
                ImGui.Text("Threshold:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(80)
                local newThreshold, changedThreshold = ImGui.InputInt("##newRuleThreshold", popup.threshold or 1)
                if changedThreshold then
                    popup.threshold = math.max(1, newThreshold)
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Keep item only if you have fewer than this amount in inventory")
                end
            end

            -- Character selector
            ImGui.Text("Character:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            
            local currentChar = mq.TLO.Me.Name() or "Local"
            popup.selectedCharacter = popup.selectedCharacter or currentChar
            
            if ImGui.BeginCombo("##selectedCharacter", popup.selectedCharacter) then
                -- Current character first
                local isSelected = (popup.selectedCharacter == currentChar)
                if ImGui.Selectable(currentChar, isSelected) then
                    popup.selectedCharacter = currentChar
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
                
                -- Other characters
                local allCharacters = database.getAllCharactersWithRules()
                for _, charName in ipairs(allCharacters) do
                    if charName ~= currentChar then
                        local isSelected = (popup.selectedCharacter == charName)
                        if ImGui.Selectable(charName, isSelected) then
                            popup.selectedCharacter = charName
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                end
                ImGui.EndCombo()
            end

            ImGui.Separator()

            -- Action buttons
            local canAdd = popup.itemName and popup.itemName ~= "" and popup.rule and popup.selectedCharacter
            
            if not canAdd then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
            else
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
            end

            if ImGui.Button("Add Rule", 120, 0) and canAdd then
                local finalRule = popup.rule
                if popup.rule == "KeepIfFewerThan" then
                    finalRule = "KeepIfFewerThan:" .. (popup.threshold or 1)
                end

                if popup.selectedCharacter == currentChar then
                    database.saveLootRule(popup.itemName, 0, finalRule, 0)
                else
                    database.saveLootRuleFor(popup.selectedCharacter, popup.itemName, 0, finalRule, 0)
                    -- Send reload command to peer if connected
                    local connectedPeers = util.getConnectedPeers()
                    for _, peer in ipairs(connectedPeers) do
                        if peer == popup.selectedCharacter then
                            util.sendPeerCommand(peer, "/sl_rulescache")
                            break
                        end
                    end
                end

                logging.log(string.format("Added new loot rule: %s -> %s for character %s", 
                    popup.itemName, finalRule, popup.selectedCharacter))
                database.refreshLootRuleCacheForPeer(popup.selectedCharacter)

                -- Clear the form
                popup.itemName = ""
                popup.rule = "Keep"
                popup.threshold = 1
                popup.selectedCharacter = currentChar
            end
            ImGui.PopStyleColor(3)

            if not canAdd and ImGui.IsItemHovered() then
                ImGui.SetTooltip("Please fill in all required fields")
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 80, 0) then
                keepOpen = false
            end

            ImGui.SameLine()
            if ImGui.Button("Clear", 80, 0) then
                popup.itemName = ""
                popup.rule = "Keep"
                popup.threshold = 1
                popup.selectedCharacter = currentChar
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Clear all fields")
            end

            ImGui.Separator()

            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("Item names are case-sensitive")
            ImGui.BulletText("Rules apply immediately after creation")
            ImGui.BulletText("Connected peers will automatically reload their rules")
        end
        ImGui.End()

        if not keepOpen then
            lootUI.addNewRulePopup.isOpen = false
            lootUI.addNewRulePopup.itemName = ""
            lootUI.addNewRulePopup.rule = "Keep"
            lootUI.addNewRulePopup.threshold = 1
            lootUI.addNewRulePopup.selectedCharacter = mq.TLO.Me.Name() or "Local"
        end
    end
end

function uiPopups.drawIconUpdatePopup(lootUI, database, lootStats, lootHistory)
    if lootUI.iconUpdatePopup.isOpen then
        ImGui.OpenPopup("UpdateIconIDPopup")

        if not lootUI.iconUpdatePopup.inited then
            local _, currentItemID, currentIconID = database.getLootRule(lootUI.iconUpdatePopup.itemName, true)
            lootUI.iconUpdatePopup.currentItemID = currentItemID or 0
            lootUI.iconUpdatePopup.currentIconID = currentIconID or 0
            lootUI.iconUpdatePopup.newItemID = lootUI.iconUpdatePopup.currentItemID
            lootUI.iconUpdatePopup.newIconID = lootUI.iconUpdatePopup.currentIconID
            lootUI.iconUpdatePopup.inited = true
        end

        if ImGui.BeginPopupModal("UpdateIconIDPopup", nil, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("Update Icon ID and Item ID for:")
            ImGui.TextColored(1, 1, 0, 1, lootUI.iconUpdatePopup.itemName)
            ImGui.Separator()

            ImGui.Text("Current Item ID: " .. tostring(lootUI.iconUpdatePopup.currentItemID))
            ImGui.Text("Current Icon ID: " .. tostring(lootUI.iconUpdatePopup.currentIconID))
            if lootUI.iconUpdatePopup.currentIconID > 0 then
                ImGui.Text("Current Icon:")
                ImGui.SameLine()
                uiUtils.drawItemIcon(lootUI.iconUpdatePopup.currentIconID)
            else
                ImGui.Text("No icon currently set")
            end

            ImGui.Separator()

            local newItemID, changedItemID = ImGui.InputInt("New Item ID", lootUI.iconUpdatePopup.newItemID)
            if changedItemID then
                lootUI.iconUpdatePopup.newItemID = math.max(0, newItemID)
            end

            local newIconID, changedIcon = ImGui.InputInt("New Icon ID", lootUI.iconUpdatePopup.newIconID)
            if changedIcon then
                lootUI.iconUpdatePopup.newIconID = math.max(0, newIconID)
            end

            if lootUI.iconUpdatePopup.newIconID > 0 then
                ImGui.Text("Preview:")
                ImGui.SameLine()
                uiUtils.drawItemIcon(lootUI.iconUpdatePopup.newIconID)
            end

            ImGui.Separator()

            if ImGui.Button("Update", 120, 0) then
                local itemName = lootUI.iconUpdatePopup.itemName
                local newItemID = lootUI.iconUpdatePopup.newItemID or lootUI.iconUpdatePopup.currentItemID
                local newIconID = lootUI.iconUpdatePopup.newIconID or lootUI.iconUpdatePopup.currentIconID

                local success = database.updateItemAndIconForAll(itemName, newItemID, newIconID)

                if success then
                    database.refreshLootRuleCache()
                    if lootStats then lootStats.updateIconID(itemName, newIconID) end
                    if lootHistory then lootHistory.updateIconID(itemName, newIconID) end
                    logging.log("Successfully updated item ID to " .. newItemID .. " and icon ID for " .. itemName .. " to " .. newIconID .. " in database.")
                else
                    logging.log("Failed to update item and icon IDs for " .. itemName .. " in database.")
                end

                lootUI.iconUpdatePopup.isOpen = false
                lootUI.iconUpdatePopup.inited = false
                ImGui.CloseCurrentPopup()
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 120, 0) then
                lootUI.iconUpdatePopup.isOpen = false
                lootUI.iconUpdatePopup.inited = false
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        else
            lootUI.iconUpdatePopup.isOpen = false
            lootUI.iconUpdatePopup.inited = false
        end
    end
end

function uiPopups.drawGettingStartedPopup(lootUI)
    if lootUI.showGettingStartedPopup then
        ImGui.SetNextWindowSize(700, 600, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin("SmartLoot - Getting Started Guide", keepOpen) then
            -- Welcome header with a nice color
            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0) -- Light blue
            ImGui.Text("Welcome to SmartLoot!")
            ImGui.PopStyleColor()
            ImGui.Separator()
            
            -- Softer white for main description text
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.9, 1.0) -- Soft white
            ImGui.TextWrapped("This guide will help you get set up and looting in no time.")
            ImGui.PopStyleColor()

            if ImGui.CollapsingHeader("Overview") then
                -- Slightly dimmed text for readability
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("SmartLoot is an intelligent auto-looting system that:")
                ImGui.PopStyleColor()
                
                -- Bullet points in a pleasant green
                ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.9, 0.7, 1.0) -- Light green
                ImGui.BulletText("Automatically loots corpses based on your predefined rules - if an item does not have a rule set, it will prompt you for a decision")
                ImGui.BulletText("Coordinates your looting order with other characters to avoid conflicts and corpse race conditions")
                ImGui.BulletText("Tracks loot history and statistics")
                ImGui.PopStyleColor()
            end

            if ImGui.CollapsingHeader("Quick Setup") then
                -- Step numbers in a nice orange
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.4, 1.0) -- Light orange
                ImGui.TextWrapped("1. Open UI: /smartloot, or left click the floating 'SL' button")
                ImGui.TextWrapped("2. Go to Peer Loot Order tab")
                ImGui.TextWrapped("3. Set a Looting Order based on priority - the first on the list will load as your 'Main' Looter")
                ImGui.TextWrapped("4. Go to the Settings Tab")
                ImGui.TextWrapped("5. Configure Behavior:")
                ImGui.PopStyleColor()
                
                ImGui.Indent()
                -- Sub-bullets in a softer blue
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 1.0, 1.0) -- Light blue
                ImGui.BulletText("Peer Coordination - This will determine how commands are sent between clients")
                ImGui.BulletText("Chat Output Settings - This will determine how you announce things")
                ImGui.BulletText("Chase Integration - if you use a chase module that leashes characters, you'll need to pause")
                ImGui.PopStyleColor()
                
                ImGui.Indent()
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0) -- Dim gray for continuation
                ImGui.TextWrapped("or stop chasing/auto following so they can navigate to corpses")
                ImGui.PopStyleColor()
                ImGui.Unindent()
                ImGui.Unindent()
            end

            if ImGui.CollapsingHeader("Loot Rules") then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("Go to 'Loot Rules' tab to set up item rules")
                ImGui.PopStyleColor()
                
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.7, 0.9, 1.0) -- Light purple
                ImGui.BulletText("Rules: Keep, Ignore, Destroy, or assign to specific character")
                ImGui.BulletText("Use search and filters to find items quickly")
                ImGui.BulletText("Add rules as you encounter new items")
                ImGui.PopStyleColor()
            end

            if ImGui.CollapsingHeader("Basic Usage") then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("Start script: /lua run smartloot")
                ImGui.PopStyleColor()
                
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.7, 1.0) -- Light yellow
                ImGui.BulletText("Manual loot: /sl_doloot")
                ImGui.BulletText("Pause/Resume: /sl_pause")
                ImGui.BulletText("Emergency stop: /sl_emergency_stop")
                ImGui.PopStyleColor()
            end

            ImGui.Spacing()
            if ImGui.Button("Close", 100, 30) then
                lootUI.showGettingStartedPopup = false
            end
        end
        ImGui.End()

        if not keepOpen then
            lootUI.showGettingStartedPopup = false
        end
    end
end

return uiPopups