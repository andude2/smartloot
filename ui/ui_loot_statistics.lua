-- ui/ui_loot_statistics.lua - FIXED VERSION
local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local logging = require("modules.logging")
local database = require("modules.database")
local lootStats = require("modules.loot_stats") -- ADD THIS LINE

local uiLootStatistics = {}

-- Color scheme constants
local COLORS = {
    HEADER_BG = { 0.15, 0.25, 0.4, 0.9 },
    SECTION_BG = { 0.08, 0.08, 0.12, 0.8 },
    DASHBOARD_BG = { 0.1, 0.15, 0.2, 0.8 },
    CONTROLS_BG = { 0.12, 0.08, 0.15, 0.7 },
    TABLE_BG = { 0.08, 0.12, 0.08, 0.7 },
    SUCCESS_COLOR = { 0.2, 0.8, 0.2, 1 },
    WARNING_COLOR = { 0.8, 0.6, 0.2, 1 },
    DANGER_COLOR = { 0.8, 0.2, 0.2, 1 },
    INFO_COLOR = { 0.2, 0.6, 0.8, 1 },
    ACCENT_COLOR = { 0.6, 0.4, 0.8, 1 },
    ZONE_COLOR = { 0.2, 0.8, 0.2, 1 },
    GLOBAL_COLOR = { 0.2, 0.6, 0.8, 1 }
}

-- Time frame utilities
local function getTimeFrameFilter(timeFrame)
    local now = os.time()
    local today = os.date("*t", now) -- Use LOCAL time for user's "today"

    if timeFrame == "Today" then
        -- Create local time boundaries
        local startOfDay = os.time({ year = today.year, month = today.month, day = today.day, hour = 0, min = 0, sec = 0 })
        local endOfDay = startOfDay + 86399 -- End of today
        -- Convert to UTC for database comparison
        return os.date("!%Y-%m-%d %H:%M:%S", startOfDay), os.date("!%Y-%m-%d %H:%M:%S", endOfDay)
    elseif timeFrame == "Yesterday" then
        local yesterday = now - 86400
        local yesterdayDate = os.date("*t", yesterday) -- Use LOCAL time
        local startOfYesterday = os.time({
            year = yesterdayDate.year,
            month = yesterdayDate.month,
            day = yesterdayDate.day,
            hour = 0,
            min = 0,
            sec = 0
        })
        local endOfYesterday = startOfYesterday + 86399
        -- Convert to UTC for database comparison
        return os.date("!%Y-%m-%d %H:%M:%S", startOfYesterday), os.date("!%Y-%m-%d %H:%M:%S", endOfYesterday)
    elseif timeFrame == "This Week" then
        local daysBack = (today.wday - 2) % 7 -- Monday as start of week
        local startOfWeek = now - (daysBack * 86400)
        local startOfWeekDay = os.time({
            year = os.date("*t", startOfWeek).year,
            month = os.date("*t", startOfWeek).month,
            day = os.date("*t", startOfWeek).day,
            hour = 0,
            min = 0,
            sec = 0
        })
        -- Convert to UTC for database comparison
        return os.date("!%Y-%m-%d %H:%M:%S", startOfWeekDay), os.date("!%Y-%m-%d %H:%M:%S", now)
    elseif timeFrame == "This Month" then
        local startOfMonth = os.time({ year = today.year, month = today.month, day = 1, hour = 0, min = 0, sec = 0 })
        -- Convert to UTC for database comparison
        return os.date("!%Y-%m-%d %H:%M:%S", startOfMonth), os.date("!%Y-%m-%d %H:%M:%S", now)
    end

    return "", ""
end

-- Get cached zones list - FIXED TO USE LOOT_STATS MODULE
local function getCachedZones(lootUI)
    if lootStats and lootStats.getUniqueZones then
        local zones = lootStats.getUniqueZones()
        if zones and #zones > 0 then
            -- Ensure "All" is first
            local result = { "All" }
            for _, zone in ipairs(zones) do
                if zone ~= "All" then
                    table.insert(result, zone)
                end
            end
            return result
        end
    end
    return { "All" }
end

-- Draw time frame selector (matching C++ format)
local function drawTimeFrameSelector(lootUI)
    ImGui.Text("Time:")
    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)

    local timeFrames = { "All Time", "Today", "Yesterday", "This Week", "This Month", "Custom" }
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

            -- Debug logging for zone name with apostrophes
            if filters.zoneName and string.find(filters.zoneName, "'") then
                logging.log("[DEBUG] Zone name contains apostrophe: '" .. tostring(filters.zoneName) .. "'")
            end

            -- Log the filters being used
            logging.log("[UI] Using filters: zoneName='" .. tostring(filters.zoneName) .. "', " ..
                "itemName='" .. tostring(filters.itemName) .. "', startDate='" .. tostring(filters.startDate) .. "', " ..
                "endDate='" .. tostring(filters.endDate) .. "', timeFrame='" .. tostring(lootUI.selectedTimeFrame) .. "'")

            -- Get total count - USE LOOT_STATS MODULE
            if lootStats.getLootStatsCount then
                local totalItems, err = lootStats.getLootStatsCount(filters)
                if err then
                    logging.log("[UI] Error getting stats count: " .. tostring(err))
                    lootUI.totalItems = 0
                else
                    lootUI.totalItems = totalItems or 0
                    logging.log("[UI] Total items found: " .. tostring(lootUI.totalItems))
                    
                    -- If no items found with time filter, check what dates exist for this zone
                    if lootUI.totalItems == 0 and filters.zoneName and (filters.startDate or filters.endDate) then
                        logging.log("[DEBUG] No items found with time filter. Checking available dates for zone: " .. tostring(filters.zoneName))
                        -- Check recent dates in this zone
                        local recentFilters = { zoneName = filters.zoneName, limit = 5 }
                        local recentData, recentErr = lootStats.getLootStats(recentFilters)
                        if recentData and #recentData > 0 then
                            logging.log("[DEBUG] Recent loot dates in this zone:")
                            for i, item in ipairs(recentData) do
                                logging.log("[DEBUG]   " .. tostring(item.item_name) .. " - Last seen: " .. tostring(item.last_timestamp or "unknown"))
                            end
                        else
                            logging.log("[DEBUG] No recent loot data found for this zone")
                        end
                    end
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

        ImGui.BeginChild("StatsTableRegion", 0, 450, ImGuiWindowFlags.HorizontalScrollbar)
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
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3],
                COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Drops")
            ImGui.PopStyleColor()

            ImGui.TableSetColumnIndex(3)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3],
                COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Corpses")
            ImGui.PopStyleColor()

            ImGui.TableSetColumnIndex(4)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3],
                COLORS.ZONE_COLOR[4])
            ImGui.TableHeader("Zone Rate %")
            ImGui.PopStyleColor()

            -- Global section header (blue)
            ImGui.TableSetColumnIndex(5)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                COLORS.GLOBAL_COLOR[4])
            ImGui.TableHeader("Global Drops")
            ImGui.PopStyleColor()

            ImGui.TableSetColumnIndex(6)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                COLORS.GLOBAL_COLOR[4])
            ImGui.TableHeader("Global Corpses")
            ImGui.PopStyleColor()

            ImGui.TableSetColumnIndex(7)
            ImGui.PushStyleColor(ImGuiCol.Text, COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                COLORS.GLOBAL_COLOR[4])
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
                    ImGuiSelectableFlags.SpanAllColumns)

                if isClicked then
                    -- Open zone breakdown popup
                    lootUI.zoneBreakdownPopup = lootUI.zoneBreakdownPopup or {}
                    lootUI.zoneBreakdownPopup.isOpen = true
                    lootUI.zoneBreakdownPopup.itemName = itemName
                    lootUI.zoneBreakdownPopup.itemID = tonumber(entry.item_id) or 0
                    lootUI.zoneBreakdownPopup.iconID = iconID
                    lootUI.zoneBreakdownPopup.needsRefetch = true
                    lootUI.zoneBreakdownPopup.timeFrame = lootUI.selectedTimeFrame or "All Time"
                    logging.log("Opening zone breakdown for item: " .. itemName)
                end

                -- Tooltip with detailed info
                if ImGui.IsItemHovered() then
                    local zoneDrops = tonumber(entry.drop_count) or 0
                    local zoneCorpses = tonumber(entry.corpse_count) or 0
                    local zoneRate = tonumber(entry.drop_rate) or 0
                    local itemID = tostring(entry.item_id or "Unknown")
                    local zoneName = tostring(lootUI.selectedZone or "Unknown")

                    ImGui.SetTooltip(string.format(
                        "Item ID: %s\nZone: %s\n\nZone Stats:\n  Drops: %d\n  Corpses: %d\n  Rate: %s\n\nClick for detailed zone breakdown",
                        itemID, zoneName,
                        zoneDrops, zoneCorpses, zoneRate, "%"))
                end

                -- Zone statistics (green color scheme) - FIXED FIELD NAMES
                ImGui.TableSetColumnIndex(2)
                local zoneDrops = tonumber(entry.drop_count) or 0
                ImGui.TextColored(COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4],
                    tostring(zoneDrops))

                ImGui.TableSetColumnIndex(3)
                local zoneCorpses = tonumber(entry.corpse_count) or 0
                ImGui.TextColored(COLORS.ZONE_COLOR[1], COLORS.ZONE_COLOR[2], COLORS.ZONE_COLOR[3], COLORS.ZONE_COLOR[4],
                    tostring(zoneCorpses))

                ImGui.TableSetColumnIndex(4)
                -- Color code the zone drop rate
                local zoneRate = tonumber(entry.drop_rate) or 0
                local zoneRateColor = COLORS.ZONE_COLOR
                if zoneRate >= 50.0 then
                    zoneRateColor = { 0.0, 1.0, 0.0, 1.0 } -- Bright green for high rates
                elseif zoneRate >= 25.0 then
                    zoneRateColor = { 0.8, 1.0, 0.2, 1.0 } -- Yellow-green for medium rates
                elseif zoneRate > 0.0 then
                    zoneRateColor = { 0.8, 0.6, 0.2, 1.0 } -- Orange for low rates
                else
                    zoneRateColor = { 0.5, 0.5, 0.5, 1.0 } -- Gray for zero
                end
                ImGui.TextColored(zoneRateColor[1], zoneRateColor[2], zoneRateColor[3], zoneRateColor[4],
                    string.format("%.2f", zoneRate))

                -- Global statistics (blue color scheme) - PLACEHOLDER FOR NOW
                ImGui.TableSetColumnIndex(5)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                    COLORS.GLOBAL_COLOR[4], tostring(zoneDrops))

                ImGui.TableSetColumnIndex(6)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                    COLORS.GLOBAL_COLOR[4], tostring(zoneCorpses))

                ImGui.TableSetColumnIndex(7)
                ImGui.TextColored(COLORS.GLOBAL_COLOR[1], COLORS.GLOBAL_COLOR[2], COLORS.GLOBAL_COLOR[3],
                    COLORS.GLOBAL_COLOR[4], string.format("%.2f", zoneRate))
            end

            ImGui.EndTable()
        end
        ImGui.EndChild()

        -- Draw zone breakdown popup with comprehensive error handling
        if lootUI.zoneBreakdownPopup and lootUI.zoneBreakdownPopup.isOpen then
            -- Validate popup data structure
            if type(lootUI.zoneBreakdownPopup) ~= "table" then
                logging.log("[ERROR] Zone breakdown popup data is corrupted, resetting...")
                lootUI.zoneBreakdownPopup = nil
                return
            end

            -- Set the popup to open state if not already shown
            if not lootUI.zoneBreakdownPopup.isShowing then
                ImGui.OpenPopup("Zone Breakdown##zoneBreakdown")
                lootUI.zoneBreakdownPopup.isShowing = true
            end

            -- Fetch zone breakdown data if needed
            if lootUI.zoneBreakdownPopup.needsRefetch then
                local itemName = tostring(lootUI.zoneBreakdownPopup.itemName or "Unknown")
                local itemID = tonumber(lootUI.zoneBreakdownPopup.itemID) or 0
                local timeFrame = tostring(lootUI.zoneBreakdownPopup.timeFrame or "All Time")

                logging.log(string.format("Fetching zone breakdown for item: %s (ID: %d, TimeFrame: %s)",
                    itemName, itemID, timeFrame))

                -- Safely fetch data with error handling
                local success, zoneData = pcall(function()
                    if database and database.getItemZoneBreakdown then
                        return database.getItemZoneBreakdown(itemName, itemID, timeFrame)
                    else
                        logging.log("[ERROR] Database or getItemZoneBreakdown function not available")
                        return {}
                    end
                end)

                if success and zoneData then
                    lootUI.zoneBreakdownPopup.zoneData = zoneData
                    logging.log(string.format("Retrieved %d zone records for item breakdown", #zoneData))
                else
                    logging.log("[ERROR] Failed to fetch zone breakdown data: " .. tostring(zoneData))
                    lootUI.zoneBreakdownPopup.zoneData = {}
                end

                lootUI.zoneBreakdownPopup.needsRefetch = false
            end

            -- Zone breakdown popup
            local shouldClose = false
            local popupFlags = ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoCollapse
            
            if ImGui.BeginPopupModal("Zone Breakdown##zoneBreakdown", true, popupFlags) then
                local popup = lootUI.zoneBreakdownPopup

                -- Validate popup structure before proceeding
                if type(popup) ~= "table" then
                    ImGui.TextColored(1.0, 0.2, 0.2, 1.0, "Error: Popup data corrupted")
                    if ImGui.Button("Close##errorClose") then
                        shouldClose = true
                    end
                    ImGui.EndPopup()
                else
                    -- Header with item info (with safe string conversion)
                    local itemName = tostring(popup.itemName or "Unknown")
                    local itemID = tonumber(popup.itemID) or 0
                    local timeFrame = tostring(popup.timeFrame or "All Time")

                    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)
                    ImGui.Text("Zone Breakdown: " .. itemName)
                    ImGui.PopStyleColor()

                    ImGui.Text("Item ID: " .. tostring(itemID))
                    ImGui.Text("Time Frame: " .. timeFrame)
                    ImGui.Separator()

                    -- Zone breakdown table with safe data handling
                    local zoneData = popup.zoneData
                    if type(zoneData) == "table" and #zoneData > 0 then
                        -- Simple table without sorting to avoid crashes
                        local tableFlags = ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg +
                                        ImGuiTableFlags.Resizable + ImGuiTableFlags.BordersOuter +
                                        ImGuiTableFlags.ScrollY

                        ImGui.BeginChild("ZoneBreakdownScrollRegion", 0, 120, ImGuiWindowFlags.HorizontalScrollbar)
                        
                        if ImGui.BeginTable("ZoneBreakdownTable", 5, tableFlags) then
                            -- Setup columns (no sorting for now to prevent crashes)
                            ImGui.TableSetupColumn("Zone", ImGuiTableColumnFlags.WidthStretch)
                            ImGui.TableSetupColumn("Drops", ImGuiTableColumnFlags.WidthFixed, 60)
                            ImGui.TableSetupColumn("Corpses", ImGuiTableColumnFlags.WidthFixed, 60)
                            ImGui.TableSetupColumn("Rate %", ImGuiTableColumnFlags.WidthFixed, 60)
                            ImGui.TableSetupColumn("% of Total", ImGuiTableColumnFlags.WidthFixed, 80)

                            -- Draw the header row
                            ImGui.TableHeadersRow()

                            -- Data rows with comprehensive safety checks
                            for i = 1, #zoneData do
                                local zone = zoneData[i]
                                
                                -- Validate each zone entry
                                if type(zone) == "table" then
                                    ImGui.TableNextRow()

                                    -- Zone name
                                    ImGui.TableSetColumnIndex(0)
                                    local zoneName = tostring(zone.zone_name or "Unknown")
                                    ImGui.Text(zoneName)

                                    -- Drop count
                                    ImGui.TableSetColumnIndex(1)
                                    local dropCount = tonumber(zone.drop_count) or 0
                                    if COLORS and COLORS.SUCCESS_COLOR then
                                        ImGui.TextColored(COLORS.SUCCESS_COLOR[1], COLORS.SUCCESS_COLOR[2],
                                            COLORS.SUCCESS_COLOR[3], COLORS.SUCCESS_COLOR[4],
                                            tostring(dropCount))
                                    else
                                        ImGui.Text(tostring(dropCount))
                                    end

                                    -- Corpse count
                                    ImGui.TableSetColumnIndex(2)
                                    local corpseCount = tonumber(zone.corpse_count) or 0
                                    if COLORS and COLORS.INFO_COLOR then
                                        ImGui.TextColored(COLORS.INFO_COLOR[1], COLORS.INFO_COLOR[2],
                                            COLORS.INFO_COLOR[3], COLORS.INFO_COLOR[4],
                                            tostring(corpseCount))
                                    else
                                        ImGui.Text(tostring(corpseCount))
                                    end

                                    -- Drop rate
                                    ImGui.TableSetColumnIndex(3)
                                    local dropRate = tonumber(zone.drop_rate) or 0
                                    local rateText = string.format("%.1f", dropRate)
                                    
                                    if COLORS then
                                        local rateColor = COLORS.WARNING_COLOR or {0.8, 0.6, 0.2, 1.0}
                                        if dropRate >= 50.0 then
                                            rateColor = COLORS.SUCCESS_COLOR or {0.2, 0.8, 0.2, 1.0}
                                        elseif dropRate >= 25.0 then
                                            rateColor = COLORS.WARNING_COLOR or {0.8, 0.6, 0.2, 1.0}
                                        else
                                            rateColor = COLORS.DANGER_COLOR or {0.8, 0.2, 0.2, 1.0}
                                        end
                                        ImGui.TextColored(rateColor[1], rateColor[2], rateColor[3], rateColor[4], rateText)
                                    else
                                        ImGui.Text(rateText)
                                    end

                                    -- Percentage of total drops
                                    ImGui.TableSetColumnIndex(4)
                                    local zonePercentage = tonumber(zone.zone_percentage) or 0
                                    local percentText = string.format("%.1f%%", zonePercentage)
                                    
                                    if COLORS and COLORS.ACCENT_COLOR then
                                        ImGui.TextColored(COLORS.ACCENT_COLOR[1], COLORS.ACCENT_COLOR[2],
                                            COLORS.ACCENT_COLOR[3], COLORS.ACCENT_COLOR[4], percentText)
                                    else
                                        ImGui.Text(percentText)
                                    end
                                else
                                    -- Handle invalid zone data
                                    ImGui.TableNextRow()
                                    ImGui.TableSetColumnIndex(0)
                                    ImGui.TextColored(1.0, 0.2, 0.2, 1.0, "Invalid data row " .. tostring(i))
                                end
                            end

                            ImGui.EndTable()
                        end
                        
                        ImGui.EndChild()
                    else
                        -- No data available
                        if COLORS and COLORS.WARNING_COLOR then
                            ImGui.TextColored(COLORS.WARNING_COLOR[1], COLORS.WARNING_COLOR[2],
                                COLORS.WARNING_COLOR[3], COLORS.WARNING_COLOR[4],
                                "No zone data found for this item.")
                        else
                            ImGui.Text("No zone data found for this item.")
                        end
                        
                        -- Debug info
                        if lootUI.showDebug then
                            ImGui.Separator()
                            ImGui.Text("Debug: zoneData type = " .. type(zoneData))
                            if type(zoneData) == "table" then
                                ImGui.Text("Debug: zoneData length = " .. tostring(#zoneData))
                            end
                        end
                    end

                    ImGui.Separator()

                    -- Close button
                    if ImGui.Button("Close##zoneBreakdownClose") then
                        shouldClose = true
                    end

                    ImGui.EndPopup()
                end
            end

            -- Handle popup closing
            if shouldClose or not ImGui.IsPopupOpen("Zone Breakdown##zoneBreakdown") then
                lootUI.zoneBreakdownPopup.isOpen = false
                lootUI.zoneBreakdownPopup.isShowing = false
                -- Clear data to prevent memory issues
                if lootUI.zoneBreakdownPopup then
                    lootUI.zoneBreakdownPopup.zoneData = nil
                end
            end
        end

        ImGui.EndTabItem()
    end
end

return uiLootStatistics
