local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local uiUtils = require("ui.ui_utils")
local actors = require("actors")
local json = require("dkjson")
local util = require("modules.util")

local uiLootRules = {}

-- State for deferred cache refresh
local pendingCacheRefresh = false
local cacheRefreshTimer = 0

-- Drop zone state
local dropZoneState = {
    isActive = false,
    itemDropped = false,
    showRulePopup = false,
    droppedItem = {
        hasItem = false,
        itemName = "",
        itemID = 0,
        iconID = 0
    },
    selectedRule = "Keep",
    threshold = 1,
    lastCursorCheck = 0
}

-- Color scheme constants
local COLORS = {
    HEADER_BG = {0.15, 0.25, 0.4, 0.9},
    SECTION_BG = {0.08, 0.08, 0.12, 0.8},
    ADD_SECTION_BG = {0.1, 0.2, 0.1, 0.7},
    RULES_SECTION_BG = {0.12, 0.08, 0.08, 0.7},
    CARD_BG = {0.1, 0.1, 0.15, 0.8},
    SUCCESS_COLOR = {0.2, 0.8, 0.2, 1},
    WARNING_COLOR = {0.8, 0.6, 0.2, 1},
    DANGER_COLOR = {0.8, 0.2, 0.2, 1},
    INFO_COLOR = {0.2, 0.6, 0.8, 1}
}

-- Rule action colors
local RULE_COLORS = {
    Keep = {0.2, 0.8, 0.2, 1},
    Ignore = {0.8, 0.2, 0.2, 1},
    Destroy = {0.6, 0.2, 0.8, 1},
    KeepIfFewerThan = {0.8, 0.6, 0.2, 1},
    Unset = {0.5, 0.5, 0.5, 1}
}

local RULE_TYPES = {"Keep", "Ignore", "KeepIfFewerThan", "Destroy"}

-- Helper function to get rule color
local function getRuleColor(rule)
    return RULE_COLORS[rule] or RULE_COLORS.Unset
end

-- Helper function to parse rule and threshold
local function parseRule(ruleString)
    if not ruleString then return "Unset", 1 end
    
    if string.find(ruleString, "KeepIfFewerThan:") then
        local threshold = ruleString:match("KeepIfFewerThan:(%d+)")
        return "KeepIfFewerThan", tonumber(threshold) or 1
    end
    
    return ruleString, 1
end

-- Helper function to get ItemID from game only
local function ensureItemID(itemName, currentItemID)
    if currentItemID and currentItemID > 0 then
        return currentItemID
    end
    
    -- Try to get from game
    local findItem = mq.TLO.FindItem(itemName)
    if findItem and findItem.ID() and findItem.ID() > 0 then
        return findItem.ID()
    end
    
    -- Return 0 if no valid ID available - caller must handle this
    return 0
end

-- Helper function to send reload message to peer
local function sendReloadMessageToPeer(peer)
    util.sendPeerCommand(peer, "/sl_rulescache")
end

-- Helper function to update rule and handle all the database operations
local function updateItemRule(itemName, newRuleValue, targetCharacter, database, util, forceRefresh, providedItemID, providedIconID)
    -- Get current rule data to preserve ItemID and IconID
    local currentRule, currentItemID, currentIconID
    if targetCharacter == mq.TLO.Me.Name() then
        currentRule, currentItemID, currentIconID = database.getLootRule(itemName, true)
    else
        local peerRules = database.getLootRulesForPeer(targetCharacter)
        local ruleData = peerRules[itemName] or {rule = "Unset", item_id = 0, icon_id = 0}
        currentRule = ruleData.rule
        currentItemID = ruleData.item_id
        currentIconID = ruleData.icon_id
    end
    
    -- Use provided IDs if available, otherwise use current or generate new ones
    local itemID = providedItemID or ensureItemID(itemName, currentItemID)
    local iconID = providedIconID or currentIconID or 0
    
    local success = false
    if targetCharacter == mq.TLO.Me.Name() then
        success = database.saveLootRule(itemName, itemID, newRuleValue, iconID)
        if success then
            logging.debug("Changed rule for " .. itemName .. " to " .. newRuleValue .. " on " .. targetCharacter)

            -- Don't refresh cache immediately - let the UI handle it on next frame
            -- This prevents the dropdown from resetting during interaction
            pendingCacheRefresh = true
            cacheRefreshTimer = mq.gettime() + 100  -- 100ms delay

            -- Send reload message if connected
            local connectedPeers = util.getConnectedPeers()
            for _, peer in ipairs(connectedPeers) do
                if peer == targetCharacter then
                    sendReloadMessageToPeer(targetCharacter)
                    break
                end
            end
        else
            logging.debug("Failed to save rule for " .. itemName .. " on " .. targetCharacter)
        end
    else
        if database.saveLootRuleFor then
            success = database.saveLootRuleFor(targetCharacter, itemName, itemID, newRuleValue, iconID)
            if success then
                logging.debug("Changed rule for " .. itemName .. " to " .. newRuleValue .. " on " .. targetCharacter)

                -- NEW: Refresh cache for peer after saving
                database.refreshLootRuleCacheForPeer(targetCharacter)

                -- Send reload message if connected
                local connectedPeers = util.getConnectedPeers()
                for _, peer in ipairs(connectedPeers) do
                    if peer == targetCharacter then
                        sendReloadMessageToPeer(targetCharacter)
                        break
                    end
                end
            else
                logging.debug("Failed to save rule for " .. itemName .. " on " .. targetCharacter)
            end
        end
    end

    return success
end

-- Get cursor item information
local function getCursorItemInfo()
    local cursor = mq.TLO.Cursor
    if not cursor() then
        return { hasItem = false, itemName = "", itemID = 0, iconID = 0 }
    end
    
    return {
        hasItem = true,
        itemName = cursor.Name() or "Unknown Item",
        itemID = cursor.ID() or 0,
        iconID = cursor.Icon() or 0
    }
end

-- Handle drop zone logic (throttled to 100ms intervals)
local function handleDropZoneLogic()
    local now = mq.gettime()
    if now - dropZoneState.lastCursorCheck < 100 then
        return
    end
    dropZoneState.lastCursorCheck = now
    
    local cursorItem = getCursorItemInfo()
    
    if cursorItem.hasItem then
        dropZoneState.isActive = true
        dropZoneState.droppedItem = cursorItem
    elseif dropZoneState.isActive then
        -- Cursor was cleared - check if dropped on zone
        if dropZoneState.itemDropped then
            dropZoneState.showRulePopup = true
            dropZoneState.itemDropped = false
        end
        dropZoneState.isActive = false
    end
end

-- Draw the item drop zone
local function drawItemDropZone(lootUI)
    local cursorItem = getCursorItemInfo()
    
    if not cursorItem.hasItem then
        -- Show placeholder drop zone
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.2, 0.3, 0.3)
        ImGui.PushStyleColor(ImGuiCol.Border, 0.4, 0.4, 0.6, 0.5)
        ImGui.PushStyleVar(ImGuiStyleVar.ChildBorderSize, 2.0)
        
        if ImGui.BeginChild("DropZone", 0, 80, ImGuiChildFlags.Border) then
            -- Center the text
            local windowSizeX, windowSizeY = ImGui.GetWindowSize()
            local text = "Drag & Drop Item Here to Inventory & Add Rule"
            local textSizeX, textSizeY = ImGui.CalcTextSize(text)
            ImGui.SetCursorPos((windowSizeX - textSizeX) * 0.5, (windowSizeY - textSizeY) * 0.5)
            ImGui.TextColored(0.7, 0.7, 0.8, 1.0, text)
        end
        ImGui.EndChild()
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(2)
    else
        -- Show active drop zone with item preview
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.5, 0.2, 0.4)
        ImGui.PushStyleColor(ImGuiCol.Border, 0.4, 0.8, 0.4, 0.8)
        ImGui.PushStyleVar(ImGuiStyleVar.ChildBorderSize, 3.0)
        
        if ImGui.BeginChild("DropZoneActive", 0, 120, ImGuiChildFlags.Border) then
            local windowSizeX, windowSizeY = ImGui.GetWindowSize()
            
            -- Show item icon
            if cursorItem.iconID > 0 then
                local iconPosX = (windowSizeX - 48) * 0.5
                ImGui.SetCursorPos(iconPosX, 10)
                uiUtils.drawItemIcon(cursorItem.iconID, 48, 48)
            end
            
            -- Item name
            local nameSizeX, nameSizeY = ImGui.CalcTextSize(cursorItem.itemName)
            ImGui.SetCursorPos((windowSizeX - nameSizeX) * 0.5, 65)
            ImGui.TextColored(0.8, 1.0, 0.8, 1.0, cursorItem.itemName)
            
            -- Drop instruction
            local instruction = "Release to Inventory & Add Rule"
            local instrSizeX, instrSizeY = ImGui.CalcTextSize(instruction)
            ImGui.SetCursorPos((windowSizeX - instrSizeX) * 0.5, 85)
            ImGui.TextColored(0.8, 1.0, 0.8, 1.0, instruction)
            
            -- Check if mouse was released over this area
            if ImGui.IsWindowHovered() and not ImGui.IsMouseDown(0) then
                -- Store item info before auto-inventory
                dropZoneState.droppedItem = cursorItem
                dropZoneState.itemDropped = true
                
                -- Auto-inventory the item
                mq.cmdf("/autoinv")
            end
        end
        ImGui.EndChild()
        ImGui.PopStyleVar()
        ImGui.PopStyleColor(2)
    end
end

-- Draw the rule creation popup after dropping an item
local function drawDropZoneRulePopup(lootUI, database, util)
    if not dropZoneState.showRulePopup then
        return
    end
    
    ImGui.OpenPopup("Add Rule for Item##DropZone")
    
    if ImGui.BeginPopupModal("Add Rule for Item##DropZone", nil, ImGuiWindowFlags.AlwaysAutoResize) then
        local item = dropZoneState.droppedItem
        
        -- Item info header
        ImGui.TextColored(0.2, 0.6, 0.8, 1.0, "Creating rule for:")
        ImGui.SameLine()
        if item.iconID > 0 then
            uiUtils.drawItemIcon(item.iconID, 24, 24)
            ImGui.SameLine()
        end
        ImGui.Text(item.itemName)
        
        ImGui.Separator()
        
        -- Rule selection dropdown
        ImGui.Text("Rule:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        if ImGui.BeginCombo("##dropZoneRule", dropZoneState.selectedRule) then
            for _, rule in ipairs(RULE_TYPES) do
                local isSelected = (dropZoneState.selectedRule == rule)
                local color = getRuleColor(rule)
                ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
                if ImGui.Selectable(rule, isSelected) then
                    dropZoneState.selectedRule = rule
                    if rule == "KeepIfFewerThan" then
                        dropZoneState.threshold = 1
                    end
                end
                ImGui.PopStyleColor()
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        
        -- Threshold input for conditional rules
        if dropZoneState.selectedRule == "KeepIfFewerThan" then
            ImGui.SameLine()
            ImGui.Text("Threshold:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(80)
            local newThreshold, changed = ImGui.InputInt("##dropZoneThreshold", dropZoneState.threshold, 0, 0)
            if changed then
                dropZoneState.threshold = math.max(1, newThreshold)
            end
        end
        
        -- Character selection for rule assignment
        ImGui.Text("Assign to:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        
        local targetCharacter = lootUI.selectedCharacterForRules or mq.TLO.Me.Name()
        if ImGui.BeginCombo("##dropZoneCharacter", targetCharacter) then
            local currentChar = mq.TLO.Me.Name()
            
            -- Current character
            local isSelected = (targetCharacter == currentChar)
            if ImGui.Selectable(currentChar, isSelected) then
                lootUI.selectedCharacterForRules = currentChar
            end
            
            -- Connected peers
            local connectedPeers = util.getConnectedPeers()
            for _, peer in ipairs(connectedPeers) do
                if peer ~= currentChar then
                    local isSelected = (targetCharacter == peer)
                    if ImGui.Selectable(peer, isSelected) then
                        lootUI.selectedCharacterForRules = peer
                    end
                end
            end
            ImGui.EndCombo()
        end
        
        -- Apply and Cancel buttons
        ImGui.Separator()
        ImGui.PushStyleColor(ImGuiCol.Button, COLORS.SUCCESS_COLOR[1], COLORS.SUCCESS_COLOR[2], COLORS.SUCCESS_COLOR[3], 0.8)
        if ImGui.Button("Apply Rule") then
            -- Build final rule string
            local finalRule = dropZoneState.selectedRule
            if dropZoneState.selectedRule == "KeepIfFewerThan" then
                finalRule = "KeepIfFewerThan:" .. dropZoneState.threshold
            end
            
            -- Get target character
            local targetChar = lootUI.selectedCharacterForRules or mq.TLO.Me.Name()
            
            -- Save the rule using existing function, passing item ID and icon ID
            local success = updateItemRule(item.itemName, finalRule, targetChar, database, util, true, item.itemID, item.iconID)
            
            if success then
                logging.debug(string.format("Successfully added rule '%s' for '%s' via drop zone (ItemID: %d, IconID: %d)", 
                                          finalRule, item.itemName, item.itemID, item.iconID))
            else
                logging.debug(string.format("Failed to add rule for '%s' via drop zone", item.itemName))
            end
            
            -- Close popup and reset state
            dropZoneState.showRulePopup = false
            dropZoneState.selectedRule = "Keep"
            dropZoneState.threshold = 1
        end
        ImGui.PopStyleColor()
        
        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            dropZoneState.showRulePopup = false
            dropZoneState.selectedRule = "Keep"
            dropZoneState.threshold = 1
        end
        
        ImGui.EndPopup()
    end
end

-- Check if item exists in current rules
local function itemExistsInRules(itemName, allRules)
    if not itemName or itemName == "" then return false end
    
    local lowerItemName = itemName:lower()
    for itemKey, ruleData in pairs(allRules) do
        -- Check both the composite key and actual item name
        if itemKey:lower() == lowerItemName then
            return true
        end
        if ruleData and ruleData.item_name then
            if ruleData.item_name:lower() == lowerItemName then
                return true
            end
        end
    end
    return false
end

-- Draw the universal rule management section (Search + Add combined in one input)
local function drawUniversalRuleSection(lootUI, database, util, allRules)
    -- Drag and Drop Zone
    ImGui.Text("Quick Rule Creation:")
    drawItemDropZone(lootUI)
    
    ImGui.Separator()
    
    -- Universal input row with character select
    ImGui.AlignTextToFramePadding()
    ImGui.Text("Search:")
    ImGui.SameLine()
    
    -- Universal text input (serves as both search and add item field)
    ImGui.SetNextItemWidth(200)
    lootUI.universalInput = lootUI.universalInput or ""
    local universalInput, changedInput = ImGui.InputText("##universalInput", lootUI.universalInput, 128)
    if changedInput then
        lootUI.universalInput = universalInput
        -- Update search filter for real-time filtering
        lootUI.searchFilter = universalInput
        lootUI.currentPage = 1
    end
    
    ImGui.SameLine()
    ImGui.Text("Character:")
    ImGui.SameLine()
    
    -- Character selector
    ImGui.SetNextItemWidth(120)
    if not lootUI.selectedCharacterForRules or lootUI.selectedCharacterForRules == "" then
        lootUI.selectedCharacterForRules = mq.TLO.Me.Name()
    end
    
    if ImGui.BeginCombo("##character", lootUI.selectedCharacterForRules) then
        local currentChar = mq.TLO.Me.Name()
        local isSelected = (lootUI.selectedCharacterForRules == currentChar)
        if ImGui.Selectable(currentChar, isSelected) then
            lootUI.selectedCharacterForRules = currentChar
        end
        
        local connectedPeers = util.getConnectedPeers()
        for _, peer in ipairs(connectedPeers) do
            if peer ~= currentChar then
                local isSelected = (lootUI.selectedCharacterForRules == peer)
                if ImGui.Selectable(peer, isSelected) then
                    lootUI.selectedCharacterForRules = peer
                end
            end
        end
        ImGui.EndCombo()
    end
    
    ImGui.SameLine()
    
    -- Refresh button
    if ImGui.Button("Refresh##RefreshChars") then
        local connectedPeers = util.getConnectedPeers()
        logging.debug("Refreshed characters list. Connected peers: " .. table.concat(connectedPeers, ", "))
    end
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Refresh connected peers list")
    end
    
    ImGui.SameLine()
    
    -- Clear search button
    if ImGui.Button("Clear##ClearSearch") then
        lootUI.universalInput = ""
        lootUI.searchFilter = ""
        lootUI.currentPage = 1
    end
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Clear search/input")
    end
    
    ImGui.SameLine()
    
    -- Context-sensitive controls based on whether item exists
    local itemExists = itemExistsInRules(lootUI.universalInput, allRules)
    
    if not itemExists and lootUI.universalInput and lootUI.universalInput ~= "" then
        -- Show Add Rule controls when item doesn't exist
        ImGui.Text("Rule:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        lootUI.newRule = lootUI.newRule or "Keep"
        
        if ImGui.BeginCombo("##addRule", lootUI.newRule) then
            for _, rule in ipairs(RULE_TYPES) do
                local isSelected = (lootUI.newRule == rule)
                local color = getRuleColor(rule)
                
                ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
                if ImGui.Selectable(rule, isSelected) then
                    lootUI.newRule = rule
                    if rule == "KeepIfFewerThan" then
                        lootUI.newRuleThreshold = 1
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
        if lootUI.newRule == "KeepIfFewerThan" then
            ImGui.SameLine()
            ImGui.SetNextItemWidth(60)
            lootUI.newRuleThreshold = lootUI.newRuleThreshold or 1
            local newThreshold, changedThreshold = ImGui.InputInt("##threshold", lootUI.newRuleThreshold, 0, 0)
            if changedThreshold then
                lootUI.newRuleThreshold = math.max(1, newThreshold)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Threshold amount")
            end
        end
        
        ImGui.SameLine()
        
        -- Add Rule button
        ImGui.PushStyleColor(ImGuiCol.Button, COLORS.SUCCESS_COLOR[1], COLORS.SUCCESS_COLOR[2], COLORS.SUCCESS_COLOR[3], 0.8)
        if ImGui.Button("Add Rule##AddNew") then
            local targetChar = lootUI.selectedCharacterForRules or mq.TLO.Me.Name()
            local itemName = lootUI.universalInput
            
            if itemName and itemName ~= "" and targetChar and targetChar ~= "" then
                local finalRule = lootUI.newRule
                if lootUI.newRule == "KeepIfFewerThan" then
                    finalRule = "KeepIfFewerThan:" .. (lootUI.newRuleThreshold or 1)
                end
                
                local itemID = ensureItemID(itemName, 0)
                local iconID = 0
                
                local findItem = mq.TLO.FindItem(itemName)
                if findItem and findItem.Icon() then
                    iconID = findItem.Icon()
                end
                
                if targetChar == mq.TLO.Me.Name() then
                    local success = database.saveLootRule(itemName, itemID, finalRule, iconID)
                    if success then
                        logging.debug("Added new rule for item: " .. itemName)
                        database.refreshLootRuleCache()
                    else
                        logging.debug("Failed to add rule for item: " .. itemName)
                    end
                else
                    if database.saveLootRuleFor then
                        local success = database.saveLootRuleFor(targetChar, itemName, itemID, finalRule, iconID)
                        if success then
                            logging.debug("Added new rule for " .. itemName .. " on " .. targetChar)
                            local connectedPeers = util.getConnectedPeers()
                            for _, peer in ipairs(connectedPeers) do
                                if peer == targetChar then
                                    sendReloadMessageToPeer(targetChar)
                                    break
                                end
                            end
                        else
                            logging.debug("Failed to add rule for " .. itemName .. " on " .. targetChar)
                        end
                    end
                end
                
                -- Clear the input after successful add
                lootUI.universalInput = ""
                lootUI.searchFilter = ""
                lootUI.newRule = "Keep"
                lootUI.newRuleThreshold = 1
            end
        end
        ImGui.PopStyleColor()
        
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Add a new rule for '" .. lootUI.universalInput .. "'")
        end
        
    else
        -- Show filter controls when searching existing items
        ImGui.Text("Filter:")
        ImGui.SameLine()
        
        ImGui.SetNextItemWidth(120)
        lootUI.ruleFilter = lootUI.ruleFilter or "All"
        
        if ImGui.BeginCombo("##filter", lootUI.ruleFilter) then
            local filters = {"All", "Keep", "Ignore", "Destroy", "KeepIfFewerThan"}
            for _, filter in ipairs(filters) do
                local isSelected = (lootUI.ruleFilter == filter)
                if ImGui.Selectable(filter, isSelected) then
                    lootUI.ruleFilter = filter
                    lootUI.currentPage = 1
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        
        if lootUI.universalInput and lootUI.universalInput ~= "" then
            ImGui.SameLine()
            ImGui.TextColored(0.7, 0.9, 0.7, 1.0, "Searching: " .. lootUI.universalInput)
        end
    end
    
    -- Show selected character info
    if lootUI.selectedCharacterForRules and lootUI.selectedCharacterForRules ~= "" then
        ImGui.Separator()
        ImGui.Text("Viewing rules for: ")
        ImGui.SameLine()
        ImGui.TextColored(0.2, 0.8, 0.2, 1.0, lootUI.selectedCharacterForRules)
    end
end

-- Draw the main rules table section (simplified)
local function drawRulesTable(lootUI, database, util, filteredItems)
    
    -- Pagination calculation
    local itemsPerPage = lootUI.itemsPerPage or 15
    local totalItems = #filteredItems
    local totalPages = math.max(1, math.ceil(totalItems / itemsPerPage))
    lootUI.currentPage = math.max(1, math.min(lootUI.currentPage or 1, totalPages))
    
    local startIndex = (lootUI.currentPage - 1) * itemsPerPage + 1
    local endIndex = math.min(startIndex + itemsPerPage - 1, totalItems)
    
    -- Right-aligned pagination info
    local windowWidth = ImGui.GetContentRegionAvail()
    local paginationText = string.format("Showing rules %d to %d of %d (Page %d/%d)", 
                                        startIndex, math.min(endIndex, totalItems), totalItems, lootUI.currentPage, totalPages)
    local textWidth = ImGui.CalcTextSize(paginationText)
    local rightPadding = 8.0
    
    ImGui.SameLine(windowWidth - textWidth - rightPadding)
    ImGui.Text(paginationText)
    
    -- Scrollable table
    ImGui.BeginChild("LootRulesScrollableTable", 0, 420, ImGuiWindowFlags.HorizontalScrollbar)
    
    local tableFlags = ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollY
    if ImGui.BeginTable("LootRulesTable", 6, tableFlags) then
        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 35)
        ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Item ID", ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 200)
        ImGui.TableSetupColumn("Peers", ImGuiTableColumnFlags.WidthFixed, 100)
        ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 100)
        ImGui.TableHeadersRow()
        
        -- Draw table rows
        for i = startIndex, math.min(endIndex, totalItems) do
            local itemKey = filteredItems[i]
            if not itemKey then break end
            
            ImGui.TableNextRow()
            
            -- Get rule data based on selected character - FRESH DATA EACH FRAME
            local ruleData
            if lootUI.selectedCharacterForRules == mq.TLO.Me.Name() then
                local allRules = database.getAllLootRules()
                ruleData = allRules[itemKey]
            else
                local peerRules = database.getLootRulesForPeer(lootUI.selectedCharacterForRules)
                ruleData = peerRules[itemKey]
            end
            
            -- Extract actual item name from rule data, handling fallback properly
            local itemName, itemID, iconID
            if ruleData then
                itemName = ruleData.item_name or itemKey
                itemID = ruleData.item_id or 0
                iconID = ruleData.icon_id or 0
            else
                -- If no rule data found, extract from composite key if possible
                if itemKey:match("_(%d+)$") then
                    itemName = itemKey:match("^(.+)_(%d+)$") -- Extract name part
                    itemID = tonumber(itemKey:match("_(%d+)$")) or 0 -- Extract ID part
                    iconID = 0
                else
                    itemName = itemKey
                    itemID = 0
                    iconID = 0
                end
                ruleData = {rule = "Unset", item_id = itemID, icon_id = iconID, item_name = itemName}
            end
            
            -- Column 1: Icon
            ImGui.TableSetColumnIndex(0)
            uiUtils.drawItemIcon(iconID)
            
            -- Column 2: Item Name
            ImGui.TableSetColumnIndex(1)
            local selectableId = itemName .. "##item_" .. i
            if ImGui.Selectable(selectableId, false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap) then
                -- Handle selection if needed
            end
            
            -- Context menu for item name
            if ImGui.BeginPopupContextItem("ContextMenu##" .. i) then
                ImGui.Text("Actions for: " .. itemName)
                ImGui.Separator()
                
                if ImGui.MenuItem("Update ItemID/IconID for All Peers") then
                    lootUI.updateIDsPopup = lootUI.updateIDsPopup or {}
                    lootUI.updateIDsPopup.isOpen = true
                    lootUI.updateIDsPopup.itemName = itemName
                    lootUI.updateIDsPopup.currentItemID = itemID
                    lootUI.updateIDsPopup.currentIconID = iconID
                    lootUI.updateIDsPopup.newItemID = itemID
                    lootUI.updateIDsPopup.newIconID = iconID
                end
                
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Update ItemID and IconID for this item across all characters/peers")
                end
                
                ImGui.EndPopup()
            end
            
            -- Column 3: Item ID
            ImGui.TableSetColumnIndex(2)
            ImGui.Text(tostring(itemID))
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Database Item ID (Primary Key)")
            end
            
            -- Column 4: Rule dropdown
            ImGui.TableSetColumnIndex(3)
            
            -- Use the already fetched ruleData from earlier - don't re-fetch
            local displayRule, threshold = parseRule(ruleData.rule)
            local ruleColor = getRuleColor(displayRule)
            
            ImGui.PushStyleColor(ImGuiCol.Button, ruleColor[1] * 0.3, ruleColor[2] * 0.3, ruleColor[3] * 0.3, 0.8)
            
            local comboId = "##rule_" .. i .. "_" .. itemName
            
            ImGui.SetNextItemWidth(120)
            
            if ImGui.BeginCombo(comboId, displayRule) then
                for _, ruleType in ipairs(RULE_TYPES) do
                    local isSelected = (displayRule == ruleType)
                    local color = getRuleColor(ruleType)
                    
                    ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
                    
                    local selectableId = ruleType .. "##ruleType_" .. i .. "_" .. ruleType
                    if ImGui.Selectable(selectableId, isSelected) then
                        local targetCharacter = lootUI.selectedCharacterForRules
                        local newRuleValue = ruleType
                        
                        if ruleType == "KeepIfFewerThan" then
                            newRuleValue = "KeepIfFewerThan:" .. threshold
                        end
                        
                        -- Only update if the rule actually changed
                        if newRuleValue ~= ruleData.rule then
                            -- Use the centralized update function, preserving iconID
                            updateItemRule(itemName, newRuleValue, targetCharacter, database, util, true, itemID, iconID)
                            
                            -- Update the local ruleData to reflect the change immediately
                            ruleData.rule = newRuleValue
                            displayRule = ruleType
                        else
                            logging.debug("Skipped update for " .. itemName .. " - rule value unchanged (" .. newRuleValue .. ")")
                        end
                    end
                    
                    ImGui.PopStyleColor()
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            
            ImGui.PopStyleColor()
            
            -- Threshold input for KeepIfFewerThan
            if displayRule == "KeepIfFewerThan" then
                ImGui.SameLine()
                ImGui.PushID("Threshold" .. i)
                ImGui.SetNextItemWidth(80)
                
                local newThreshold, changedThreshold = ImGui.InputInt("##threshold", threshold, 0, 0)
                if changedThreshold then
                    newThreshold = math.max(1, newThreshold)
                    local newRuleValue = "KeepIfFewerThan:" .. newThreshold
                    local targetCharacter = lootUI.selectedCharacterForRules
                    
                    -- Use the centralized update function, preserving iconID  
                    updateItemRule(itemName, newRuleValue, targetCharacter, database, util, true, itemID, iconID)
                end
                
                ImGui.PopID()
            end
            
            -- Column 5: Peers button
            ImGui.TableSetColumnIndex(4)
            ImGui.PushID(itemName)
            
            if ImGui.Button("Peers") then
                lootUI.peerItemRulesPopup = lootUI.peerItemRulesPopup or {}
                lootUI.peerItemRulesPopup.isOpen = true
                lootUI.peerItemRulesPopup.itemName = itemName
                lootUI.peerItemRulesPopup.itemID = itemID
                lootUI.peerItemRulesPopup.iconID = iconID
            end
            
            ImGui.SameLine()
            
            -- Apply All button - applies LOCAL rule to all peers
            if ImGui.Button("Apply All") then
                local connectedPeers = util.getConnectedPeers()
                local currentCharacter = mq.TLO.Me.Name()
                
                if #connectedPeers > 0 then
                    -- Get the LOCAL rule for this item (not the rule from the currently selected character)
                    local localRule, localItemID, localIconID = database.getLootRule(itemName, true, itemID)
                    
                    if localRule and localRule ~= "" then
                        local appliedCount = 0
                        -- Use the itemID and iconID from the current row, not from the local rule lookup
                        -- This ensures we don't accidentally change IDs when applying rules
                        local useItemID = itemID  -- From the current row
                        local useIconID = iconID  -- From the current row
                        
                        -- Only use local values if current row has no IDs
                        if useItemID == 0 and localItemID and localItemID > 0 then
                            useItemID = localItemID
                        end
                        if useIconID == 0 and localIconID and localIconID > 0 then
                            useIconID = localIconID
                        end
                        
                        -- First, update the local character's rule to ensure IDs are consistent
                        if useItemID ~= localItemID or useIconID ~= localIconID then
                            database.saveLootRule(itemName, useItemID, localRule, useIconID)
                            logging.debug(string.format("Updated local rule IDs for '%s' (itemID=%d, iconID=%d)", 
                                                      itemName, useItemID, useIconID))
                        end
                        
                        -- Then apply to all peers
                        for _, peer in ipairs(connectedPeers) do
                            if peer ~= currentCharacter then
                                if database.saveLootRuleFor then
                                    local success = database.saveLootRuleFor(peer, itemName, useItemID, localRule, useIconID)
                                    if success then
                                        appliedCount = appliedCount + 1
                                        sendReloadMessageToPeer(peer)
                                        logging.debug(string.format("Applied local rule '%s' for '%s' to peer %s (itemID=%d, iconID=%d)", 
                                                                localRule, itemName, peer, useItemID, useIconID))
                                    else
                                        logging.debug(string.format("No change (or failed) applying rule for '%s' to peer %s - reload sent anyway", itemName, peer))
                                    end
                                end
                            end
                        end
                        
                        if appliedCount > 0 then
                            logging.debug(string.format("Successfully applied local rule '%s' for '%s' to %d connected peers", 
                                                      localRule, itemName, appliedCount))
                        else
                            logging.debug("Failed to apply rule to any connected peers")
                        end
                    else
                        logging.debug(string.format("No local rule found for '%s' - cannot apply to peers", itemName))
                    end
                else
                    logging.debug("No connected peers found to apply rule to")
                end
            end
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Apply this item's LOCAL rule (your character's rule) to all connected peers")
            end
            
            ImGui.PopID()
            
            -- Column 6: Actions (Delete button)
            ImGui.TableSetColumnIndex(5)
            ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.2, 0.2, 0.8)
            if ImGui.Button("Delete##" .. i) then
                local targetCharacter = lootUI.selectedCharacterForRules or mq.TLO.Me.Name()
                
                if targetCharacter == mq.TLO.Me.Name() then
                    -- Delete from local character
                    local success = database.deleteLootRule(itemName, itemID)
                    if success then
                        logging.debug("Successfully deleted rule for " .. itemName)
                        database.refreshLootRuleCache()
                    else
                        logging.debug("Failed to delete rule for " .. itemName)
                    end
                else
                    -- Delete from peer character
                    if database.deleteLootRuleFor then
                        local success = database.deleteLootRuleFor(targetCharacter, itemName, itemID)
                        if success then
                            logging.debug("Successfully deleted rule for " .. itemName .. " on " .. targetCharacter)
                            database.refreshLootRuleCacheForPeer(targetCharacter)
                            
                            -- Send reload message to peer if connected
                            local connectedPeers = util.getConnectedPeers()
                            for _, peer in ipairs(connectedPeers) do
                                if peer == targetCharacter then
                                    sendReloadMessageToPeer(targetCharacter)
                                    break
                                end
                            end
                        else
                            logging.debug("Failed to delete rule for " .. itemName .. " on " .. targetCharacter)
                        end
                    else
                        logging.debug("deleteLootRuleFor function not available")
                    end
                end
            end
            ImGui.PopStyleColor()
        end
        
        ImGui.EndTable()
    end
    
    ImGui.EndChild()
    
    -- Pagination controls
    if totalPages > 1 then
        ImGui.Separator()
        
        if ImGui.Button("< Prev") and lootUI.currentPage > 1 then
            lootUI.currentPage = lootUI.currentPage - 1
        end
        
        ImGui.SameLine()
        ImGui.Text("Page " .. lootUI.currentPage .. " of " .. totalPages)
        
        ImGui.SameLine()
        if ImGui.Button("Next >") and lootUI.currentPage < totalPages then
            lootUI.currentPage = lootUI.currentPage + 1
        end
    end
end

-- Filter and search items
local function getFilteredItems(allRules, searchFilter, ruleFilter)
    local allItems = {}
    for itemKey, _ in pairs(allRules) do
        table.insert(allItems, itemKey)
    end
    
    logging.debug(string.format("[UI] getFilteredItems: %d total items, searchFilter='%s', ruleFilter='%s'", 
                                #allItems, searchFilter or "nil", ruleFilter or "nil"))
    
    local filteredItems = {}
    
    -- Convert search filter to lowercase for case-insensitive search
    local lowerSearchFilter = ""
    if searchFilter and searchFilter ~= "" then
        lowerSearchFilter = string.lower(searchFilter)
    end
    
    -- Sort by actual item name for better user experience
    table.sort(allItems, function(a, b)
        local aName = allRules[a] and allRules[a].item_name or a
        local bName = allRules[b] and allRules[b].item_name or b
        return aName:lower() < bName:lower()
    end)
    
    for _, itemKey in ipairs(allItems) do
        local ruleData = allRules[itemKey]
        local actualItemName = ruleData and ruleData.item_name or itemKey
        
        -- Case-insensitive search on actual item name
        local matchesSearch = (lowerSearchFilter == "") or 
                             (string.find(string.lower(actualItemName), lowerSearchFilter, 1, true) ~= nil)
        
        -- Rule filter
        local matchesFilter = (ruleFilter == "All")
        if not matchesFilter then
            if ruleData then
                local rule = ruleData.rule or "Unset"
                if ruleFilter == "KeepIfFewerThan" and string.find(rule, "KeepIfFewerThan") then
                    matchesFilter = true
                elseif rule == ruleFilter then
                    matchesFilter = true
                end
            end
        end
        
        if matchesSearch and matchesFilter then
            table.insert(filteredItems, itemKey)
        end
    end
    
    logging.debug(string.format("[UI] getFilteredItems result: %d items after filtering", #filteredItems))
    return filteredItems
end

-- Main draw function
function uiLootRules.draw(lootUI, database, settings, util, uiPopups)
    -- Handle drop zone logic (cursor monitoring)
    handleDropZoneLogic()
    
    -- Handle deferred cache refresh
    if pendingCacheRefresh and mq.gettime() >= cacheRefreshTimer then
        database.refreshLootRuleCache()
        pendingCacheRefresh = false
        logging.debug("[UI] Deferred cache refresh completed")
    end
    
    if ImGui.BeginTabItem((uiUtils.UI_ICONS.SETTINGS or "S") .. " Loot Rules Editor") then
        -- Initialize UI state
        lootUI.currentPage = lootUI.currentPage or 1
        lootUI.searchFilter = lootUI.searchFilter or ""
        lootUI.ruleFilter = lootUI.ruleFilter or "All"
        
        -- Get rules first so we can check if items exist
        local allRules
        local currentChar = mq.TLO.Me.Name()
        logging.debug(string.format("[UI] Current character: '%s', Selected: '%s'", currentChar, lootUI.selectedCharacterForRules or "nil"))
        
        if lootUI.selectedCharacterForRules == currentChar then
            allRules = database.getAllLootRules() or {}
            local count = 0
            for _ in pairs(allRules) do count = count + 1 end
            logging.debug(string.format("[UI] Got %d rules from getAllLootRules()", count))
        else
            allRules = database.getLootRulesForPeer(lootUI.selectedCharacterForRules) or {}
            local count = 0
            for _ in pairs(allRules) do count = count + 1 end
            logging.debug(string.format("[UI] Got %d rules from getLootRulesForPeer('%s')", count, lootUI.selectedCharacterForRules or "nil"))
        end
        
        -- Universal Rule Management Section (Search + Add in one input)
        drawUniversalRuleSection(lootUI, database, util, allRules)
        
        -- Filter and search items
        local filteredItems = getFilteredItems(allRules, lootUI.searchFilter, lootUI.ruleFilter)
        
        -- Draw the main rules table
        drawRulesTable(lootUI, database, util, filteredItems)
        
        -- Draw the drop zone rule popup if needed
        drawDropZoneRulePopup(lootUI, database, util)
        
        ImGui.EndTabItem()
    end
end

return uiLootRules