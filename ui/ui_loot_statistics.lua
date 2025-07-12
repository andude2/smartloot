-- ui/ui_loot_statistics.lua - FIXED VERSION
local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local logging = require("modules.logging")
local database = require("modules.database")
local lootStats = require("modules.loot_stats")  -- ADD THIS LINE

local uiLootStatistics = {}

-- Color scheme constants
local COLORS = {
    HEADER_BG = {0.15, 0.25, 0.4, 0.9},
    SECTION_BG = {0.08, 0.08, 0.12, 0.8},
    DASHBOARD_BG = {0.1, 0.15, 0.2, 0.8},
    CONTROLS_BG = {0.12, 0.08, 0.15, 0.7},
    TABLE_BG = {0.08, 0.12, 0.08, 0.7},
    SUCCESS_COLOR = {0.2, 0.8, 0.2, 1},
    WARNING_COLOR = {0.8, 0.6, 0.2, 1},
    DANGER_COLOR = {0.8, 0.2, 0.2, 1},
    INFO_COLOR = {0.2, 0.6, 0.8, 1},
    ACCENT_COLOR = {0.6, 0.4, 0.8, 1},
    ZONE_COLOR = {0.2, 0.8, 0.2, 1},
    GLOBAL_COLOR = {0.2, 0.6, 0.8, 1}
}

-- Time frame utilities
local function getTimeFrameFilter(timeFrame)
    local now = os.time()
    local today = os.date("*t", now)
    
    if timeFrame == "Today" then
        local startOfDay = os.time({year = today.year, month = today.month, day = today.day, hour = 0, min = 0, sec = 0})
        return os.date("%Y-%m-%d", startOfDay), os.date("%Y-%m-%d", now)
    elseif timeFrame == "Yesterday" then
        local yesterday = now - 86400
        local yesterdayDate = os.date("*t", yesterday)
        local startOfYesterday = os.time({year = yesterdayDate.year, month = yesterdayDate.month, day = yesterdayDate.day, hour = 0, min = 0, sec = 0})
        local endOfYesterday = startOfYesterday + 86399
        return os.date("%Y-%m-%d", startOfYesterday), os.date("%Y-%m-%d", endOfYesterday)
    elseif timeFrame == "This Week" then
        local daysBack = (today.wday - 2) % 7 -- Monday as start of week
        local startOfWeek = now - (daysBack * 86400)
        return os.date("%Y-%m-%d", startOfWeek), os.date("%Y-%m-%d", now)
    elseif timeFrame == "This Month" then
        local startOfMonth = os.time({year = today.year, month = today.month, day = 1, hour = 0, min = 0, sec = 0})
        return os.date("%Y-%m-%d", startOfMonth), os.date("%Y-%m-%d", now)
    end
    
    return "", ""
end

-- Get cached zones list - FIXED TO USE LOOT_STATS MODULE
local function getCachedZones(lootUI)
    if lootStats and lootStats.getUniqueZones then
        local zones = lootStats.getUniqueZones()
        if zones and #zones > 0 then
            -- Ensure "All" is first
            local result = {"All"}
            for _, zone in ipairs(zones) do
                if zone ~= "All" then
                    table.insert(result, zone)
                end
            end
            return result
        end
    end
    return {"All"}
end

-- Draw time frame selector (matching C++ format)
local function drawTimeFrameSelector(lootUI)
    ImGui.Text("Time:")
    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)
    
    local timeFrames = {"All Time", "Today", "Yesterday", "This Week", "This Month", "Custom"}
    local currentTimeFrame = lootUI.selectedTimeFrame or "All Time"
    
    if ImGui.BeginCombo("##statsTimeFrame", currentTimeFrame) then
        for _, timeFrame in ipairs(timeFrames) do
            local isSelected = (currentTimeFrame == timeFrame)
            if ImGui.Selectable(timeFrame, isSelected) then
                if currentTimeFrame ~= timeFrame then
                    lootUI.selectedTimeFrame = timeFrame
                    lootUI.currentPage = 1
                    lootUI.needsRefetch = true
                    
                    -- Set date filters based on selection
                    if timeFrame == "Custom" then
                        -- Keep current custom dates
                        lootUI.customStartDate = lootUI.customStartDate or ""
                        lootUI.customEndDate = lootUI.customEndDate or ""
                    elseif timeFrame ~= "All Time" then
                        local startDate, endDate = getTimeFrameFilter(timeFrame)
                        lootUI.startDate = startDate
                        lootUI.endDate = endDate
                    else
                        lootUI.startDate = ""
                        lootUI.endDate = ""
                    end
                end
            end
            if isSelected then
                ImGui.SetItemDefaultFocus()
            end
        end
        ImGui.EndCombo()
    end
    
    -- Custom date inputs
    if currentTimeFrame == "Custom" then
        ImGui.SameLine()
        ImGui.Text("From:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(100)
        local startDate, changedStart = ImGui.InputText("##customStartDate", lootUI.customStartDate or "", 32)
        if changedStart then
            lootUI.customStartDate = startDate
            lootUI.startDate = startDate
            lootUI.needsRefetch = true
        end
        
        ImGui.SameLine()
        ImGui.Text("To:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(100)
        local endDate, changedEnd = ImGui.InputText("##customEndDate", lootUI.customEndDate or "", 32)
        if changedEnd then
            lootUI.customEndDate = endDate
            lootUI.endDate = endDate
            lootUI.needsRefetch = true
        end
    end
end

-- Main draw function - FIXED TO USE LOOT_STATS MODULE
function uiLootStatistics.draw(lootUI, lootStatsParam)
    if ImGui.BeginTabItem("Loot Statistics") then
        -- Initialize state
        lootUI.searchFilter = lootUI.searchFilter or ""
        lootUI.selectedZone = lootUI.selectedZone or "All"
        lootUI.selectedTimeFrame = lootUI.selectedTimeFrame or "All Time"
        lootUI.customStartDate = lootUI.customStartDate or ""
        lootUI.customEndDate = lootUI.customEndDate or ""
        lootUI.startDate = lootUI.startDate or ""
        lootUI.endDate = lootUI.endDate or ""
        lootUI.currentPage = lootUI.currentPage or 1
        lootUI.itemsPerPage = lootUI.itemsPerPage or 20
        
        -- Add debug info at the top
        if lootUI.showDebug then
            ImGui.TextColored(0.8, 0.8, 0.2, 1.0, "DEBUG INFO:")
            ImGui.Text("needsRefetch: " .. tostring(lootUI.needsRefetch))
            ImGui.Text("totalItems: " .. tostring(lootUI.totalItems or "nil"))
            ImGui.Text("statsData count: " .. tostring(lootUI.statsData and #lootUI.statsData or "nil"))
            ImGui.Separator()
        end
        
        -- Controls section (first row)
        ImGui.Text("Search:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(200)
        local searchBuffer = lootUI.searchFilter
        local newSearch, changedSearch = ImGui.InputText("##statsSearch", searchBuffer, 256)
        if changedSearch then
            lootUI.searchFilter = newSearch
            lootUI.currentPage = 1
            lootUI.needsRefetch = true
        end
        
        ImGui.SameLine()
        
        -- TIME FRAME SELECTOR
        drawTimeFrameSelector(lootUI)
        
        -- Second row
        ImGui.Text("Zone:")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        if ImGui.BeginCombo("##statsZone", lootUI.selectedZone) then
            local zones = getCachedZones(lootUI)
            for i, zone in ipairs(zones) do
                if ImGui.Selectable(zone .. "##statsZone" .. i, lootUI.selectedZone == zone) then
                    if lootUI.selectedZone ~= zone then
                        lootUI.selectedZone = zone
                        lootUI.currentPage = 1
                        lootUI.needsRefetch = true
                    end
                end
            end
            ImGui.EndCombo()
        end
        
        ImGui.SameLine()
        if ImGui.Button("Clear Filters##statsTab") then
            lootUI.searchFilter = ""
            lootUI.selectedZone = "All"
            lootUI.selectedTimeFrame = "All Time"
            lootUI.customStartDate = ""
            lootUI.customEndDate = ""
            lootUI.startDate = ""
            lootUI.endDate = ""
            lootUI.currentPage = 1
            lootUI.needsRefetch = true
        end
        
        ImGui.SameLine()
        if ImGui.Button("Refresh Stats##statsTab") then
            if lootStats.clearAllCache then
                lootStats.clearAllCache()
            end
            lootUI.needsRefetch = true
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Refresh dropdown lists and reload statistics data")
        end
        
        -- Add debug toggle button
        ImGui.SameLine()
        if ImGui.Button("Debug##statsTab") then
            lootUI.showDebug = not lootUI.showDebug
        end
        
        ImGui.Separator()
        
        -- Zone explanation
        if lootUI.selectedZone ~= "All" then
            ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Zone View: " .. lootUI.selectedZone)
            ImGui.TextColored(0.7, 0.7, 0.7, 1.0,
                "Zone columns show statistics for this zone only. Global columns show statistics across all zones.")
        else
            ImGui.TextColored(0.8, 0.6, 0.2, 1.0, "All Zones View")
            ImGui.TextColored(0.7, 0.7, 0.7, 1.0,
                "Zone columns show aggregated statistics. Global columns show the same data (all zones).")
        end
        
        ImGui.Separator()
        
        -- Fetch data if needed - FIXED TO USE LOOT_STATS MODULE
        if lootUI.needsRefetch then
            logging.log("[UI] Fetching loot statistics data...")
            
            local filters = {
                zoneName = lootUI.selectedZone ~= "All" and lootUI.selectedZone or nil,
                itemName = lootUI.searchFilter ~= "" and lootUI.searchFilter or nil,
                startDate = lootUI.startDate ~= "" and lootUI.startDate or nil,
                endDate = lootUI.endDate ~= "" and lootUI.endDate or nil,
                limit = lootUI.itemsPerPage,
                offset = (lootUI.currentPage - 1) * lootUI.itemsPerPage
            }
            
            -- Log the filters being used
            logging.log("[UI] Using filters: " .. tostring(filters.zoneName) .. ", " .. 
                       tostring(filters.itemName) .. ", " .. tostring(filters.startDate) .. ", " .. 
                       tostring(filters.endDate))
            
            -- Get total count - USE LOOT_STATS MODULE
            if lootStats.getLootStatsCount then
                local totalItems, err = lootStats.getLootStatsCount(filters)
                if err then
                    logging.log("[UI] Error getting stats count: " .. tostring(err))
                    lootUI.totalItems = 0
                else
                    lootUI.totalItems = totalItems or 0
                    logging.log("[UI] Total items found: " .. tostring(lootUI.totalItems))
                end
            else
                logging.log("[UI] lootStats.getLootStatsCount function not found!")
                lootUI.totalItems = 0
            end
            
            lootUI.totalPages = math.max(1, math.ceil(lootUI.totalItems / lootUI.itemsPerPage))
            lootUI.currentPage = math.max(1, math.min(lootUI.currentPage, lootUI.totalPages))
            
            -- Update offset after page correction
            filters.offset = (lootUI.currentPage - 1) * lootUI.itemsPerPage
            
            -- Get stats data - USE LOOT_STATS MODULE
            if lootStats.getLootStats then
                local statsData, err = lootStats.getLootStats(filters)
                if err then
                    logging.log("[UI] Error getting stats data: " .. tostring(err))
                    lootUI.statsData = {}
                else
                    lootUI.statsData = statsData or {}
                    logging.log("[UI] Retrieved " .. tostring(#lootUI.statsData) .. " stats records")
                end
            else
                logging.log("[UI] lootStats.getLootStats function not found!")
                lootUI.statsData = {}
            end
            
            lootUI.needsRefetch = false
        end
        
        -- Display data status
        local totalItems = tonumber(lootUI.totalItems) or 0
        local statsDataCount = lootUI.statsData and #lootUI.statsData or 0
        ImGui.Text(string.format("Data Status: %d total items, %d displayed", totalItems, statsDataCount))
        
        -- Pagination info (matching C++ format)
        local currentPage = tonumber(lootUI.currentPage) or 1
        local itemsPerPage = tonumber(lootUI.itemsPerPage) or 20
        local startItem = math.min((currentPage - 1) * itemsPerPage + 1, totalItems)
        local endItem = math.min(currentPage * itemsPerPage, totalItems)
        ImGui.Text(string.format("Showing %d-%d of %d items", startItem, endItem, totalItems))
        
        -- Pagination controls (right aligned)
        local windowWidth = ImGui.GetContentRegionAvail()
        ImGui.SameLine(windowWidth - 300)
        
        -- First page
        if ImGui.Button("<<##statsFirst") and currentPage > 1 then
            lootUI.currentPage = 1
            lootUI.needsRefetch = true
        end
        ImGui.SameLine()
        
        -- Previous page
        if ImGui.Button("<##statsPrev") and currentPage > 1 then
            lootUI.currentPage = currentPage - 1
            lootUI.needsRefetch = true
        end
        ImGui.SameLine()
        
        -- Page indicator
        local totalPages = tonumber(lootUI.totalPages) or 1
        ImGui.Text(string.format("Page %d of %d", currentPage, totalPages))
        ImGui.SameLine()
        
        -- Next page
        if ImGui.Button(">##statsNext") and currentPage < totalPages then
            lootUI.currentPage = currentPage + 1
            lootUI.needsRefetch = true
        end
        ImGui.SameLine()
        
        -- Last page
        if ImGui.Button(">>##statsLast") and currentPage < totalPages then
            lootUI.currentPage = totalPages
            lootUI.needsRefetch = true
        end
        
        ImGui.Separator()
        
        -- Enhanced statistics table with separate zone and global columns
        local tableFlags = ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg +
                          ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollY +
                          ImGuiTableFlags.BordersOuter
        
        ImGui.BeginChild("StatsTableRegion", 0, 450, false, ImGuiWindowFlags.HorizontalScrollbar)
        if ImGui.BeginTable("LootStatsTable", 8, tableFlags) then
            -- Setup columns with proper headers
            ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 35)
            ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
            
            -- Zone-specific columns
            ImGui.TableSetupColumn("Zone\nDrops", ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn("Zone\nCorpses", ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn("Zone\nRate %", ImGuiTableColumnFlags.WidthFixed, 60)
            
            -- Global columns
            ImGui.TableSetupColumn("Global\nDrops", ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn("Global\nCorpses", ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn("Global\nRate %", ImGuiTableColumnFlags.WidthFixed, 60)
            
            -- Custom header row with section separators
            ImGui.TableNextRow(ImGuiTableRowFlags.Headers)
            
            -- Basic columns
            ImGui.TableSetColumnIndex(0)
            ImGui.TableHeader("Icon")
            ImGui.TableSetColumnIndex(1)
            ImGui.TableHeader("Item")
            
            -- Zone section header (green)
            ImGui.TableSetColumnIndex(2)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Drops")
            ImGui.PopStyleColor()
            
            ImGui.TableSetColumnIndex(3)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Corpses")
            ImGui.PopStyleColor()
            
            ImGui.TableSetColumnIndex(4)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Rate %")
            ImGui.PopStyleColor()
            
            -- Global section header (blue)
            ImGui.TableSetColumnIndex(5)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4])
            ImGui.TableHeader("Global Drops")
            ImGui.PopStyleColor()
            
            ImGui.TableSetColumnIndex(6)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4])
            ImGui.TableHeader("Global Corpses")
            ImGui.PopStyleColor()
            
            ImGui.TableSetColumnIndex(7)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4])
            ImGui.TableHeader("Global Rate %")
            ImGui.PopStyleColor()
            
            -- Data rows
            for i, entry in ipairs(lootUI.statsData or {}) do
                ImGui.TableNextRow()
                
                -- Icon
                ImGui.TableSetColumnIndex(0)
                local iconID = tonumber(entry.icon_id) or 0
                if iconID > 0 and uiUtils.drawItemIcon then
                    uiUtils.drawItemIcon(iconID)
                else
                    ImGui.Text("")
                end
                
                -- Item name - MAKE IT CLICKABLE
                ImGui.TableSetColumnIndex(1)
                local itemName = entry.item_name or "Unknown"
                local selectableId = itemName .. "##statsItem" .. i
                
                -- Make the entire row selectable and clickable
                local isClicked = ImGui.Selectable(selectableId, false,
                    ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowItemOverlap)
                
                if isClicked then
                    -- Open item details popup
                    lootUI.itemDetailsPopup = lootUI.itemDetailsPopup or {}
                    lootUI.itemDetailsPopup.isOpen = true
                    lootUI.itemDetailsPopup.itemName = itemName
                    lootUI.itemDetailsPopup.itemID = entry.item_id
                    lootUI.itemDetailsPopup.iconID = iconID
                    lootUI.itemDetailsPopup.needsRefetch = true
                    -- Use the same date filters as the main stats view
                    lootUI.itemDetailsPopup.startDate = lootUI.startDate
                    lootUI.itemDetailsPopup.endDate = lootUI.endDate
                end
                
                -- Tooltip with detailed info
                if ImGui.IsItemHovered() then
                    local zoneDrops = tonumber(entry.drop_count) or 0
                    local zoneCorpses = tonumber(entry.corpse_count) or 0
                    local zoneRate = tonumber(entry.drop_rate) or 0
                    local itemID = tostring(entry.item_id or "Unknown")
                    local zoneName = tostring(lootUI.selectedZone or "Unknown")
                    
                    ImGui.SetTooltip(string.format(
                        "Item ID: %s\nZone: %s\n\nZone Stats:\n  Drops: %d\n  Corpses: %d\n  Rate: %.2f%%\n\nClick for detailed zone breakdown",
                        itemID, zoneName,
                        zoneDrops, zoneCorpses, zoneRate))
                end
                
                -- Zone statistics (green color scheme) - FIXED FIELD NAMES
                ImGui.TableSetColumnIndex(2)
                local zoneDrops = tonumber(entry.drop_count) or 0
                ImGui.TextColored(COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4], tostring(zoneDrops))
                
                ImGui.TableSetColumnIndex(3)
                local zoneCorpses = tonumber(entry.corpse_count) or 0
                ImGui.TextColored(COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4], tostring(zoneCorpses))
                
                ImGui.TableSetColumnIndex(4)
                -- Color code the zone drop rate
                local zoneRate = tonumber(entry.drop_rate) or 0
                local zoneRateColor = COLORS.ZONE_COLOR
                if zoneRate >= 50.0 then
                    zoneRateColor = {0.0, 1.0, 0.0, 1.0} -- Bright green for high rates
                elseif zoneRate >= 25.0 then
                    zoneRateColor = {0.8, 1.0, 0.2, 1.0} -- Yellow-green for medium rates
                elseif zoneRate > 0.0 then
                    zoneRateColor = {0.8, 0.6, 0.2, 1.0} -- Orange for low rates
                else
                    zoneRateColor = {0.5, 0.5, 0.5, 1.0} -- Gray for zero
                end
                ImGui.TextColored(zoneRateColor[1], zoneRateColor[2], zoneRateColor[3], zoneRateColor[4], string.format("%.2f", zoneRate))
                
                -- Global statistics (blue color scheme) - PLACEHOLDER FOR NOW
                ImGui.TableSetColumnIndex(5)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4], tostring(zoneDrops))
                
                ImGui.TableSetColumnIndex(6)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4], tostring(zoneCorpses))
                
                ImGui.TableSetColumnIndex(7)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3], COLORS.GLOBAL_COLOR[4], string.format("%.2f", zoneRate))
            end
            
            ImGui.EndTable()
        end
        ImGui.EndChild()
        
        -- Draw item details popup if it exists
        if lootUI.itemDetailsPopup and lootUI.itemDetailsPopup.isOpen then
            -- Set the popup to open state if not already shown
            if not lootUI.itemDetailsPopup.isShowing then
                ImGui.OpenPopup("Item Details##statsDetails")
                lootUI.itemDetailsPopup.isShowing = true
            end
            
            -- Simple popup implementation - can be enhanced later
            local shouldClose = false
            if ImGui.BeginPopupModal("Item Details##statsDetails", true, ImGuiWindowFlags.AlwaysAutoResize) then
                ImGui.Text("Item: " .. (lootUI.itemDetailsPopup.itemName or "Unknown"))
                ImGui.Text("Item ID: " .. tostring(lootUI.itemDetailsPopup.itemID or "Unknown"))
                
                if ImGui.Button("Close") then
                    shouldClose = true
                end
                
                ImGui.EndPopup()
            end
            
            -- Handle popup closing
            if shouldClose or not ImGui.IsPopupOpen("Item Details##statsDetails") then
                lootUI.itemDetailsPopup.isOpen = false
                lootUI.itemDetailsPopup.isShowing = false
            end
        end
        
        ImGui.EndTabItem()
    end
end

return uiLootStatistics