-- ui/ui_loot_history.lua
local mq = require("mq")
local ImGui = require("ImGui")
local database = require("modules.loot_history")
local logging = require("modules.logging")
local uiUtils = require("ui.ui_utils")
local bit = require("bit") -- Ensure bit library is explicitly used for bitwise operations

local uiLootHistory = {}

-- Helper function for sorting table data
local function sortTableData(data, sortColumn, sortDirection)
    if not data or #data == 0 then return end

    local function get_value(item, col)
        if col == "looted_quantity" then return item.looted_quantity or 0
        elseif col == "looted_count" then return item.looted_count or 0
        elseif col == "ignored_count" then return item.ignored_count or 0
        elseif col == "timestamp" then return item.unix_timestamp or 0 -- Use unix timestamp for proper date sort
        else return item[col] end
    end

    table.sort(data, function(a, b)
        local valA = get_value(a, sortColumn)
        local valB = get_value(b, sortColumn)

        if type(valA) == "string" and type(valB) == "string" then
            if sortDirection == "ASC" then
                return valA:lower() < valB:lower()
            else
                return valA:lower() > valB:lower()
            end
        else -- Assume number or comparable type
            if sortDirection == "ASC" then
                return valA < valB
            else
                return valA > valB
            end
        end
    end)
end


function uiLootHistory.draw(historyUI, database)
    if ImGui.BeginTabItem("Loot History") then
        -- Initialize defaults if they are nil
        historyUI.searchFilter = historyUI.searchFilter or ""
        historyUI.selectedLooter = historyUI.selectedLooter or "All"
        historyUI.selectedZone = historyUI.selectedZone or "All"
        historyUI.selectedAction = historyUI.selectedAction or "All"
        historyUI.selectedTimeFrame = historyUI.selectedTimeFrame or "All Time"
        historyUI.customStartDate = historyUI.customStartDate or os.date("%Y-%m-%d")
        historyUI.customEndDate = historyUI.customEndDate or os.date("%Y-%m-%d")
        historyUI.startDate = historyUI.startDate or ""
        historyUI.endDate = historyUI.endDate or ""
        historyUI.currentPage = historyUI.currentPage or 1
        historyUI.itemsPerPage = historyUI.itemsPerPage or 12 -- Ensure this is always a number
        historyUI.totalItems = historyUI.totalItems or 0    -- Initialize to 0
        historyUI.totalPages = historyUI.totalPages or 1    -- Initialize to 1
        historyUI.aggregatedView = historyUI.aggregatedView or false
        historyUI.sortColumn = historyUI.sortColumn or "timestamp"
        historyUI.sortDirection = historyUI.sortDirection or "DESC"
        historyUI.needsRefetch = historyUI.needsRefetch or true
        historyUI.historyData = historyUI.historyData or {} -- Ensure historyData is a table

        -- Search and filter controls
        ImGui.Text("Search / Filter:")
        local newSearch, changedSearch = ImGui.InputText("##historySearch", historyUI.searchFilter, 128)
        if changedSearch then
            historyUI.searchFilter = newSearch
            historyUI.currentPage = 1
            historyUI.needsRefetch = true
        end

        -- Filter dropdowns in a row
        ImGui.BeginGroup()
        ImGui.Text("Filter by:")
        ImGui.SameLine()

        -- Looter dropdown
        ImGui.Text("Looter")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        if ImGui.BeginCombo("##historyLooter", historyUI.selectedLooter) then
            for _, looter in ipairs(database.getUniqueLooters()) do
                if ImGui.Selectable(looter .. "##looter", historyUI.selectedLooter == looter) then
                    historyUI.selectedLooter = looter
                    historyUI.currentPage = 1
                    historyUI.needsRefetch = true
                end
            end
            ImGui.EndCombo()
        end

        ImGui.SameLine()

        -- Zone dropdown
        ImGui.Text("Zone")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        if ImGui.BeginCombo("##historyZone", historyUI.selectedZone) then
            for _, zone in ipairs(database.getUniqueZones()) do
                if ImGui.Selectable(zone .. "##zone", historyUI.selectedZone == zone) then
                    historyUI.selectedZone = zone
                    historyUI.currentPage = 1
                    historyUI.needsRefetch = true
                end
            end
            ImGui.EndCombo()
        end

        ImGui.SameLine()

        -- Time frame dropdown
        ImGui.Text("Time")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        local timeFrames = {"All Time", "Today", "Yesterday", "This Week", "This Month", "Custom"}
        if ImGui.BeginCombo("##historyTime", historyUI.selectedTimeFrame) then
            for _, timeFrame in ipairs(timeFrames) do
                if ImGui.Selectable(timeFrame .. "##timeFrame", historyUI.selectedTimeFrame == timeFrame) then
                    historyUI.selectedTimeFrame = timeFrame
                    if timeFrame == "Custom" then
                         historyUI.startDate = historyUI.customStartDate
                         historyUI.endDate = historyUI.customEndDate
                    elseif timeFrame ~= "All Time" then
                        local timeFilters = database.getTimeFrameFilter(timeFrame)
                        historyUI.startDate = timeFilters.startDate or ""
                        historyUI.endDate = timeFilters.endDate or ""
                    else
                        historyUI.startDate = ""
                        historyUI.endDate = ""
                    end
                    historyUI.currentPage = 1
                    historyUI.needsRefetch = true
                end
            end
            ImGui.EndCombo()
        end
        
        if historyUI.selectedTimeFrame == "Custom" then
            ImGui.SameLine()
            ImGui.Text("From:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(100)
            local newStartDate, changedStartDate = ImGui.InputText("##customStartDate", historyUI.customStartDate, 32)
            if changedStartDate then
                historyUI.customStartDate = newStartDate
                historyUI.startDate = newStartDate
                historyUI.needsRefetch = true
            end
            ImGui.SameLine()
            ImGui.Text("To:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(100)
            local newEndDate, changedEndDate = ImGui.InputText("##customEndDate", historyUI.customEndDate, 32)
            if changedEndDate then
                historyUI.customEndDate = newEndDate
                historyUI.endDate = newEndDate
                historyUI.needsRefetch = true
            end
        end

        ImGui.SameLine()

        -- Action dropdown
        ImGui.Text("Action")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        local actions = {"All", "Looted", "Ignored", "Left Behind", "Destroyed"}
        if ImGui.BeginCombo("##historyAction", historyUI.selectedAction) then
            for _, action in ipairs(actions) do
                if ImGui.Selectable(action .. "##action", historyUI.selectedAction == action) then
                    historyUI.selectedAction = action
                    historyUI.currentPage = 1
                    historyUI.needsRefetch = true
                end
            end
            ImGui.EndCombo()
        end

        ImGui.EndGroup()

        if ImGui.Button("Clear Filters##clearFilters") then
            historyUI.searchFilter = ""
            historyUI.selectedLooter = "All"
            historyUI.selectedZone = "All"
            historyUI.selectedAction = "All"
            historyUI.selectedTimeFrame = "All Time"
            historyUI.startDate = ""
            historyUI.endDate = ""
            historyUI.customStartDate = os.date("%Y-%m-%d")
            historyUI.customEndDate = os.date("%Y-%m-%d")
            historyUI.currentPage = 1
            historyUI.needsRefetch = true
        end

        ImGui.Separator()

        if historyUI.selectedTimeFrame ~= "All Time" then
            ImGui.SameLine()
            ImGui.TextColored(1, 0.7, 0, 1, "Time filter: " .. historyUI.selectedTimeFrame)
        end

        -- Build filters for the query
        local filters = {
            itemName = historyUI.searchFilter,
            looter = historyUI.selectedLooter,
            zoneName = historyUI.selectedZone,
            action = (historyUI.selectedAction == "All") and nil or historyUI.selectedAction,
            startDate = historyUI.startDate,
            endDate = historyUI.endDate,
            itemsPerPage = historyUI.itemsPerPage,
            currentPage = historyUI.currentPage,
            sortColumn = historyUI.sortColumn,
            sortDirection = historyUI.sortDirection
        }

        -- Fetch data if needed
        if historyUI.needsRefetch then
            if historyUI.aggregatedView then
                historyUI.totalItems = database.getAggregatedHistoryCount(filters)
            else
                historyUI.totalItems = database.getHistoryCount(filters)
            end
            historyUI.totalItems = historyUI.totalItems or 0 
            historyUI.totalPages = math.max(1, math.ceil(historyUI.totalItems / (historyUI.itemsPerPage or 1)))
            
            historyUI.currentPage = math.max(1, math.min(historyUI.currentPage, historyUI.totalPages))
            
            filters.offset = (historyUI.currentPage - 1) * (historyUI.itemsPerPage or 0)
            
            if historyUI.aggregatedView then
                historyUI.historyData = database.getAggregatedHistory(filters)
            else
                historyUI.historyData = database.getHistory(filters)
            end
            
            -- Apply Lua-based sorting after data fetch
            sortTableData(historyUI.historyData, historyUI.sortColumn, historyUI.sortDirection)

            historyUI.needsRefetch = false
        end

        -- Pagination controls
        local displayStartItem = math.min(( (historyUI.currentPage or 1) - 1) * (historyUI.itemsPerPage or 0) + 1, (historyUI.totalItems or 0))
        local displayEndItem = math.min((historyUI.currentPage or 1) * (historyUI.itemsPerPage or 0), (historyUI.totalItems or 0))

        ImGui.Text(string.format("Showing %d-%d of %d items",
            displayStartItem,
            displayEndItem,
            (historyUI.totalItems or 0)))

        ImGui.SameLine(ImGui.GetWindowWidth() - 250)

        if ImGui.Button("<<##firstPage") and (historyUI.currentPage or 1) > 1 then
            historyUI.currentPage = 1
            historyUI.needsRefetch = true
        end
        ImGui.SameLine()
        if ImGui.Button("<##prevPage") and (historyUI.currentPage or 1) > 1 then
            historyUI.currentPage = (historyUI.currentPage or 1) - 1
            historyUI.needsRefetch = true
        end
        ImGui.SameLine()
        ImGui.Text(string.format("Page %d of %d", (historyUI.currentPage or 1), math.max(1, (historyUI.totalPages or 1))))
        ImGui.SameLine()
        if ImGui.Button(">##nextPage") and (historyUI.currentPage or 1) < (historyUI.totalPages or 1) then
            historyUI.currentPage = (historyUI.currentPage or 1) + 1
            historyUI.needsRefetch = true
        end
        ImGui.SameLine()
        if ImGui.Button(">>##lastPage") and (historyUI.currentPage or 1) < (historyUI.totalPages or 1) then
            historyUI.currentPage = (historyUI.totalPages or 1)
            historyUI.needsRefetch = true
        end

        -- History data table
        local child_opened = ImGui.BeginChild("LootHistoryChild", 0, 350, true)
        if child_opened then
            -- Toggle for aggregated view
            local newAggregatedView, changedAggregatedView = ImGui.Checkbox("Show Aggregated View##aggregatedView", historyUI.aggregatedView)
            if changedAggregatedView then
                historyUI.aggregatedView = newAggregatedView
                historyUI.currentPage = 1
                historyUI.needsRefetch = true
            end

            local table_flags = ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable
            local table_columns = historyUI.aggregatedView and 5 or 6

            local table_opened = ImGui.BeginTable("LootHistoryTableMain", table_columns, table_flags)
            if table_opened then
                -- Define columns with sortable flags and default sort order
                if historyUI.aggregatedView then
                    -- ImGui.TableSetupColumn for setting up column properties
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 30, 0)
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch, 0, "item_name")
                    ImGui.TableSetupColumn("Qty Looted", ImGuiTableColumnFlags.WidthFixed, 80, "looted_quantity")
                    ImGui.TableSetupColumn("Times Looted", ImGuiTableColumnFlags.WidthFixed, 90, "looted_count")
                    ImGui.TableSetupColumn("Times Ignored", ImGuiTableColumnFlags.WidthFixed, 90, "ignored_count")
                else
                    ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 30, 0)
                    ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch, 0, "item_name")
                    ImGui.TableSetupColumn("Looter", ImGuiTableColumnFlags.WidthFixed, 100, "looter")
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 80, "action")
                    ImGui.TableSetupColumn("Corpse", ImGuiTableColumnFlags.WidthFixed, 150, "corpse_name")
                    ImGui.TableSetupColumn("Date/Time", ImGuiTableColumnFlags.WidthFixed, 150, "timestamp")
                end
                
                ImGui.TableHeadersRow()

                if historyUI.aggregatedView then
                    for index, entry in ipairs(historyUI.historyData) do
                        ImGui.TableNextRow()

                        ImGui.TableSetColumnIndex(0)
                        local iconIdNum = tonumber(entry.icon_id)
                        if iconIdNum and iconIdNum > 0 then uiUtils.drawItemIcon(iconIdNum) else ImGui.Text("---") end

                        ImGui.TableSetColumnIndex(1)
                        local label = (entry.item_name or "Unknown") .. "##aggItem" .. tostring(index)
                        if ImGui.Selectable(label, false, ImGuiSelectableFlags.SpanAllColumns) then
                            historyUI.selectedItemDetails = entry
                            historyUI.selectedItemDetails.looterFilters = {
                                startDate = historyUI.startDate,
                                endDate = historyUI.endDate,
                            }
                            historyUI.showItemDetailsPopup = true
                        end
                        if ImGui.IsItemHovered() then
                            local idToShow = "N/A"; if entry.item_id ~= nil then idToShow = tostring(entry.item_id) end
                            ImGui.SetTooltip(string.format("Item ID: %s\nLast Seen: %s\nClick for looter details", idToShow, database.formatTimestamp(entry.unix_timestamp, entry.last_ts) ))
                        end

                        ImGui.TableSetColumnIndex(2)
                        local qtyLooted = entry.looted_quantity or 0
                        ImGui.Text(tostring(qtyLooted))

                        ImGui.TableSetColumnIndex(3)
                        local countLooted = entry.looted_count or 0
                        ImGui.Text(tostring(countLooted))

                        ImGui.TableSetColumnIndex(4)
                        local countIgnored = entry.ignored_count or 0
                        ImGui.Text(tostring(countIgnored))

                    end
                else -- Detailed view
                    for index, entry in ipairs(historyUI.historyData) do
                        ImGui.TableNextRow()

                        ImGui.TableSetColumnIndex(0)
                        local iconIdNum = tonumber(entry.icon_id)
                        if iconIdNum and iconIdNum > 0 then
                            uiUtils.drawItemIcon(iconIdNum)
                        else
                            ImGui.Text("---")
                        end

                        ImGui.TableSetColumnIndex(1)
                        local label = (entry.item_name or "Unknown") .. "##item" .. tostring(index)
                        if ImGui.Selectable(label, false, ImGuiSelectableFlags.SpanAllColumns) then
                            historyUI.selectedItemDetails = entry
                            historyUI.selectedItemDetails.looterFilters = {
                                startDate = historyUI.startDate,
                                endDate = historyUI.endDate,
                            }
                            historyUI.showItemDetailsPopup = true
                        end
                        if ImGui.IsItemHovered() then
                            local idToShow = "N/A"
                            if entry.item_id ~= nil then
                                idToShow = tostring(entry.item_id)
                            end
                            ImGui.SetTooltip(string.format("ID: %s", idToShow))
                        end

                        ImGui.TableSetColumnIndex(2)
                        ImGui.Text(entry.looter or "")

                        ImGui.TableSetColumnIndex(3)
                        local actionColor = {1, 1, 1, 1}
                        if entry.action == "Looted" then
                            actionColor = {0, 1, 0, 1}
                        elseif entry.action == "Ignored" then
                            actionColor = {1, 0, 0, 1}
                        elseif entry.action == "Left Behind" then
                            actionColor = {1, 0.7, 0, 1}
                        elseif entry.action == "Destroyed" then
                            actionColor = {0.6, 0.2, 0.8, 1}
                        end
                        ImGui.TextColored(actionColor[1], actionColor[2], actionColor[3], actionColor[4], entry.action or "")

                        ImGui.TableSetColumnIndex(4)
                        ImGui.Text(entry.corpse_name or "Unknown")
                        if ImGui.IsItemHovered() and entry.corpse_id then
                            ImGui.SetTooltip(string.format("Corpse ID: %s\nZone: %s", tostring(entry.corpse_id), entry.zone_name or "Unknown"))
                        end

                        ImGui.TableSetColumnIndex(5)
                        ImGui.Text(database.formatTimestamp(entry.unix_timestamp, entry.formatted_timestamp))
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip(entry.formatted_timestamp or "")
                        end
                    end
                end
                ImGui.EndTable()
            end
            ImGui.EndChild()
        end


        -- Item details window (non-modal)
        if historyUI.showItemDetailsPopup and historyUI.selectedItemDetails then
            ImGui.SetNextWindowSize(400, 300, ImGuiCond.FirstUseEver)
            local itemDetails = historyUI.selectedItemDetails
            local windowTitle = "Item Details: " .. (itemDetails.item_name or "Unknown Item")
            local windowOpen, p_open = ImGui.Begin(windowTitle, true, ImGuiWindowFlags.AlwaysAutoResize)

            if windowOpen then
                ImGui.BeginGroup()
                local iconIdNum = tonumber(itemDetails.icon_id)
                if iconIdNum and iconIdNum > 0 then
                    uiUtils.drawItemIcon(iconIdNum)
                    ImGui.SameLine()
                end
                ImGui.Text(itemDetails.item_name or "Unknown Item")
                ImGui.SameLine()
                ImGui.TextDisabled("(ID: " .. (itemDetails.item_id or 0) .. ")")
                ImGui.EndGroup()

                ImGui.Separator()

                local totalQuantity = itemDetails.total_quantity or itemDetails.looted_quantity or 0
                ImGui.Text("Total Quantity Looted: " .. totalQuantity)
                ImGui.Text("Total Times Looted: " .. (itemDetails.looted_count or 0))

                ImGui.Separator()

                ImGui.Text("Looted by:")
                if ImGui.BeginTable("LooterDetailsTable", 2, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                    ImGui.TableSetupColumn("Looter", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Times Looted", ImGuiTableColumnFlags.WidthFixed, 100)
                    ImGui.TableHeadersRow()

                    local looterDetails = database.getItemLooterDetails(itemDetails.item_name, itemDetails.looterFilters)
                    for _, detail in ipairs(looterDetails) do
                        ImGui.TableNextRow()

                        ImGui.TableSetColumnIndex(0)
                        ImGui.Text(detail.looter or "")

                        ImGui.TableSetColumnIndex(1)
                        local looterQuantity = detail.total_quantity or detail.times_looted or 0
                        ImGui.Text(tostring(looterQuantity))
                    end
                    ImGui.EndTable()
                end

                ImGui.Separator()

                if ImGui.Button("Close##itemDetailsClose", 120, 0) then
                    historyUI.showItemDetailsPopup = false
                    historyUI.selectedItemDetails = nil
                end
                ImGui.End()
            else
                historyUI.showItemDetailsPopup = false
                historyUI.selectedItemDetails = nil
            end
        end

        ImGui.EndTabItem()
    end
end

return uiLootHistory