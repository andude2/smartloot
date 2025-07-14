-- ui/ui_temp_rules.lua - UI for managing temporary rules
local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local tempRules = require("modules.temp_rules")
local Icons = require("mq.icons")

local uiTempRules = {}

-- UI State
local tempRuleState = {
    newItemName = "",
    newRule = "Keep",
    newThreshold = 1,
    newAssignedPeer = "",
    searchFilter = "",
    showHelp = false
}

-- Color scheme
local COLORS = {
    HEADER_BG = {0.15, 0.25, 0.4, 0.9},
    TEMP_RULE_BG = {0.4, 0.2, 0.1, 0.7},
    SUCCESS_COLOR = {0.2, 0.8, 0.2, 1},
    WARNING_COLOR = {0.8, 0.6, 0.2, 1},
    DANGER_COLOR = {0.8, 0.2, 0.2, 1},
    INFO_COLOR = {0.2, 0.6, 0.8, 1}
}

local RULE_COLORS = {
    Keep = {0.2, 0.8, 0.2, 1},
    Ignore = {0.8, 0.2, 0.2, 1},
    Destroy = {0.6, 0.2, 0.8, 1},
    KeepIfFewerThan = {0.8, 0.6, 0.2, 1}
}

local RULE_TYPES = {"Keep", "Ignore", "KeepIfFewerThan", "Destroy"}

function uiTempRules.draw(lootUI, database, settings, util)
    if ImGui.BeginTabItem(Icons.MD_HOURGLASS_EMPTY .. " AFK Farm Rules") then
        -- Header with status
        local tempCount = tempRules.getCount()
        local isActive = tempCount > 0
        
        ImGui.PushStyleColor(ImGuiCol.Text, isActive and COLORS.SUCCESS_COLOR[1] or COLORS.WARNING_COLOR[1],
                                           isActive and COLORS.SUCCESS_COLOR[2] or COLORS.WARNING_COLOR[2],
                                           isActive and COLORS.SUCCESS_COLOR[3] or COLORS.WARNING_COLOR[3], 1)
        ImGui.Text(string.format("AFK Farming Mode: %s (%d temporary rules)", 
                                isActive and "ACTIVE" or "INACTIVE", tempCount))
        ImGui.PopStyleColor()
        
        ImGui.SameLine()
        if ImGui.Button("?") then
            tempRuleState.showHelp = not tempRuleState.showHelp
        end
        
        if tempRuleState.showHelp then
            ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 0.9)
            ImGui.BeginChild("HelpText", 0, 120, true)
            ImGui.TextWrapped("AFK Farming Mode allows you to set rules for items you haven't encountered yet.")
            ImGui.TextWrapped("When SmartLoot encounters an item matching a temporary rule:")
            ImGui.BulletText("It will use the temporary rule immediately")
            ImGui.BulletText("Convert it to a permanent rule with the discovered Item ID")
            ImGui.BulletText("Remove it from the temporary list")
            ImGui.TextWrapped("This is perfect for AFK farming when you know what items might drop!")
            ImGui.EndChild()
            ImGui.PopStyleColor()
        end
        
        ImGui.Separator()
        
        -- Add new temporary rule section
        ImGui.Text("Add Temporary Rule:")
        
        -- Item name input
        ImGui.SetNextItemWidth(300)
        local newName, changedName = ImGui.InputText("##tempItemName", tempRuleState.newItemName, 128)
        if changedName then
            tempRuleState.newItemName = newName
        end
        
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Enter item name (case insensitive)")
        end
        
        ImGui.SameLine()
        ImGui.Text("Rule:")
        ImGui.SameLine()
        
        -- Rule dropdown
        ImGui.SetNextItemWidth(80)
        if ImGui.BeginCombo("##tempRule", tempRuleState.newRule) then
            for _, rule in ipairs(RULE_TYPES) do
                local isSelected = (tempRuleState.newRule == rule)
                local color = RULE_COLORS[rule]
                
                ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
                if ImGui.Selectable(rule, isSelected) then
                    tempRuleState.newRule = rule
                    if rule == "KeepIfFewerThan" then
                        tempRuleState.newThreshold = 1
                    end
                end
                ImGui.PopStyleColor()
                
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        
        -- Threshold input for KeepIfFewerThan
        if tempRuleState.newRule == "KeepIfFewerThan" then
            ImGui.SameLine()
            ImGui.Text("Threshold:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(80)
            
            local newThreshold, changedThreshold = ImGui.InputInt("##tempThreshold", tempRuleState.newThreshold, 0, 0)
            if changedThreshold then
                tempRuleState.newThreshold = math.max(1, newThreshold)
            end
        end
        ImGui.SameLine()
        -- Peer assignment dropdown
        ImGui.Text("Assign to Peer (Optional):")
        ImGui.SetNextItemWidth(200)

        -- Create peer list with "None" option
        local assignmentPeerList = {"None"}
        local connectedPeers = util.getConnectedPeers()
        for _, peer in ipairs(connectedPeers) do
            table.insert(assignmentPeerList, peer)
        end

        -- Ensure we have a valid selection
        if not tempRuleState.newAssignedPeer or tempRuleState.newAssignedPeer == "" then
            tempRuleState.newAssignedPeer = "None"
        end
        ImGui.SameLine()
        if ImGui.BeginCombo("##tempAssignedPeer", tempRuleState.newAssignedPeer) then
            for i, peer in ipairs(assignmentPeerList) do
                local selected = (tempRuleState.newAssignedPeer == peer)
                if ImGui.Selectable(peer, selected) then
                    tempRuleState.newAssignedPeer = peer
                end
                if selected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end

        -- Convert "None" back to empty string for processing
        local actualAssignedPeer = (tempRuleState.newAssignedPeer == "None") and "" or tempRuleState.newAssignedPeer

        
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Leave empty for self, or enter character name to assign to specific peer")
        end
        
        ImGui.SameLine()
        
        -- Add button
        ImGui.PushStyleColor(ImGuiCol.Button, COLORS.SUCCESS_COLOR[1], COLORS.SUCCESS_COLOR[2], COLORS.SUCCESS_COLOR[3], 0.8)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, COLORS.SUCCESS_COLOR[1] + 0.1, COLORS.SUCCESS_COLOR[2] + 0.1, COLORS.SUCCESS_COLOR[3] + 0.1, 1)
        
        if ImGui.Button("Add Temp Rule") then
            if tempRuleState.newItemName and tempRuleState.newItemName ~= "" then
                -- This local variable should correctly hold the peer name if step 1 is successful.
                local assignedPeerToPass = tempRuleState.newAssignedPeer 

                logging.log("DEBUG: Value of assignedPeerToPass before add: '" .. tostring(assignedPeerToPass) .. "'") -- ADD THIS LINE

                local success, err = tempRules.add(
                    tempRuleState.newItemName,
                    tempRuleState.newRule,
                    tempRuleState.newThreshold,
                    assignedPeerToPass
                )
                
                if success then
                    local logMsg = "[AFK Farm] Added temporary rule for: " .. tempRuleState.newItemName
                    -- The assignedPeer here can be read from tempRuleState.newAssignedPeer for logging
                    if tempRuleState.newAssignedPeer and tempRuleState.newAssignedPeer ~= "" then
                        logMsg = logMsg .. " (assigned to " .. tempRuleState.newAssignedPeer .. ")"
                    end
                    logging.log(logMsg)
                    
                    -- Clear the form
                    tempRuleState.newItemName = ""
                    tempRuleState.newRule = "Keep"
                    tempRuleState.newThreshold = 1
                    tempRuleState.newAssignedPeer = "" -- This clears the input box for next time
                else
                    logging.log("[AFK Farm] Failed to add rule: " .. tostring(err))
                end
            end
        end
        
        ImGui.PopStyleColor(2)
                
        -- Temporary rules table
        ImGui.BeginChild("TempRulesTable", 0, 0)
        
        if ImGui.BeginTable("TempRulesTableContent", 6, 
            ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollY) then
            
            ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 150)
            ImGui.TableSetupColumn("Assigned Peer", ImGuiTableColumnFlags.WidthFixed, 120)
            ImGui.TableSetupColumn("Added", ImGuiTableColumnFlags.WidthFixed, 120)
            ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthFixed, 100)
            ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 80)
            ImGui.TableHeadersRow()
            
            -- Get and filter rules
            local allRules = tempRules.getAll()
            local filteredRules = {}
            
            local lowerSearch = tempRuleState.searchFilter:lower()
            for _, rule in ipairs(allRules) do
                if lowerSearch == "" or rule.itemName:lower():find(lowerSearch, 1, true) then
                    table.insert(filteredRules, rule)
                end
            end
            
            -- Display rules
            for i, ruleData in ipairs(filteredRules) do
                ImGui.TableNextRow()
                
                -- Item Name
                ImGui.TableSetColumnIndex(0)
                ImGui.Text(ruleData.itemName)
                
                -- Rule
                ImGui.TableSetColumnIndex(1)
                local displayRule, threshold = tempRules.parseRule(ruleData.rule)
                local ruleColor = RULE_COLORS[displayRule] or COLORS.INFO_COLOR
                
                ImGui.PushStyleColor(ImGuiCol.Text, ruleColor[1], ruleColor[2], ruleColor[3], 1)
                if displayRule == "KeepIfFewerThan" then
                    ImGui.Text(displayRule .. " (" .. threshold .. ")")
                else
                    ImGui.Text(displayRule)
                end
                ImGui.PopStyleColor()
                
                -- Assigned Peer
                ImGui.TableSetColumnIndex(2)
                if ruleData.assignedPeer and ruleData.assignedPeer ~= "" then
                    ImGui.PushStyleColor(ImGuiCol.Text, COLORS.INFO_COLOR[1], COLORS.INFO_COLOR[2], COLORS.INFO_COLOR[3], 1)
                    ImGui.Text(ruleData.assignedPeer)
                    ImGui.PopStyleColor()
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.6, 0.6, 1)
                    ImGui.Text("Self")
                    ImGui.PopStyleColor()
                end
                
                -- Added time
                ImGui.TableSetColumnIndex(3)
                ImGui.Text(ruleData.addedAt or "Unknown")
                
                -- Status
                ImGui.TableSetColumnIndex(4)
                ImGui.TextColored(COLORS.WARNING_COLOR[1], COLORS.WARNING_COLOR[2], COLORS.WARNING_COLOR[3], 1, "Waiting")
                
                -- Actions
                ImGui.TableSetColumnIndex(5)
                ImGui.PushID("TempRule" .. i)
                
                ImGui.PushStyleColor(ImGuiCol.Button, COLORS.DANGER_COLOR[1], COLORS.DANGER_COLOR[2], COLORS.DANGER_COLOR[3], 0.8)
                if ImGui.Button("Remove") then
                    tempRules.remove(ruleData.itemName)
                end
                ImGui.PopStyleColor()
                
                ImGui.PopID()
            end
            
            ImGui.EndTable()
        end
        
        ImGui.EndChild()
        
        ImGui.EndTabItem()
    end
end

return uiTempRules