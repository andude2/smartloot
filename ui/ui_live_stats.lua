-- ui/ui_live_stats.lua - SmartLoot Live Statistics Window (IMPROVED STATE DISPLAY)
local ImGui = require("ImGui")
local mq = require("mq")
local configModule = require("modules.config")

local liveStatsWindow = {
    show = true,
    compactMode = false,
    alpha = 0.55,
    position = { x = 200, y = 200 },
    isDragging = false,
    dragOffset = { x = 0, y = 0 },
    lastUpdate = 0,
    updateInterval = 1000, -- Update every 1 second
    windowFlags = ImGuiWindowFlags.NoDecoration +
        ImGuiWindowFlags.AlwaysAutoResize +
        ImGuiWindowFlags.NoFocusOnAppearing +
        ImGuiWindowFlags.NoNav,

    -- State display improvements
    stateDisplay = {
        current = "Idle",
        lastState = "Idle",
        stateStartTime = 0,
        minDisplayTime = 500,      -- Minimum time to display a state (ms)
        lastUpdateTime = 0,
        stateHistory = {},         -- Track recent states
        maxHistory = 5,
        showDetailedState = false, -- Toggle for detailed vs simplified state
    }
}

-- Helper function to safely get position values
local function getPositionValues(pos)
    if type(pos) == "table" then
        return pos.x or pos[1] or 0, pos.y or pos[2] or 0
    else
        -- Assume separate return values
        return pos or 0, select(2, ImGui.GetWindowPos()) or 0
    end
end

-- Helper function to safely get mouse position values
local function getMousePositionValues()
    local mousePos = ImGui.GetMousePos()
    if type(mousePos) == "table" then
        return mousePos.x or mousePos[1] or 0, mousePos.y or mousePos[2] or 0
    else
        -- Assume separate return values
        return mousePos or 0, select(2, ImGui.GetMousePos()) or 0
    end
end

-- Helper function to get color for mode
local function getModeColor(mode)
    if mode == "main" then
        return 0.2, 0.8, 0.2, 1 -- Green
    elseif mode == "background" then
        return 0.2, 0.6, 0.8, 1 -- Blue
    elseif mode == "once" then
        return 0.8, 0.6, 0.2, 1 -- Orange
    elseif mode == "rgmain" then
        return 0.8, 0.2, 0.8, 1 -- Purple
    elseif mode == "rgonce" then
        return 0.6, 0.2, 0.8, 1 -- Dark Purple
    else
        return 0.6, 0.6, 0.6, 1 -- Gray for disabled
    end
end

-- Helper function to get simplified state name
local function getSimplifiedState(stateName)
    -- Group similar states together for less visual noise
    if stateName == "Idle" or stateName == "WaitingForCorpses" then
        return "Waiting"
    elseif stateName:find("Finding") or stateName:find("Searching") then
        return "Searching"
    elseif stateName:find("Navigating") or stateName:find("Moving") then
        return "Moving"
    elseif stateName:find("Opening") or stateName:find("Approaching") then
        return "Opening"
    elseif stateName:find("Processing") or stateName:find("Looting") then
        return "Looting"
    elseif stateName:find("Pending") or stateName:find("Decision") then
        return "Deciding"
    elseif stateName:find("Cleaning") then
        return "Cleaning"
    elseif stateName:find("Combat") then
        return "Combat"
    elseif stateName:find("Emergency") then
        return "Emergency"
    else
        return "Active"
    end
end

-- Helper function to get state color
local function getStateColor(stateName)
    local simplified = getSimplifiedState(stateName)

    if simplified == "Waiting" then
        return 0.7, 0.7, 0.7, 1 -- Gray
    elseif simplified == "Searching" then
        return 0.8, 0.6, 0.2, 1 -- Orange
    elseif simplified == "Moving" then
        return 0.2, 0.6, 0.8, 1 -- Blue
    elseif simplified == "Opening" then
        return 0.6, 0.2, 0.8, 1 -- Purple
    elseif simplified == "Looting" then
        return 0.2, 0.8, 0.2, 1 -- Green
    elseif simplified == "Deciding" then
        return 0.8, 0.8, 0.2, 1 -- Yellow
    elseif simplified == "Cleaning" then
        return 0.8, 0.4, 0.2, 1 -- Orange-red
    elseif simplified == "Combat" then
        return 1.0, 0.2, 0.2, 1 -- Red
    elseif simplified == "Emergency" then
        return 0.8, 0.0, 0.0, 1 -- Dark red
    else
        return 1.0, 1.0, 1.0, 1 -- White
    end
end

-- Update state display with debouncing
local function updateStateDisplay(currentStateName)
    local now = mq.gettime()
    local stateData = liveStatsWindow.stateDisplay

    -- If state changed
    if currentStateName ~= stateData.lastState then
        -- Only update if enough time has passed since last update
        if now - stateData.lastUpdateTime >= stateData.minDisplayTime then
            -- Add to history
            table.insert(stateData.stateHistory, 1, {
                state = stateData.current,
                duration = now - stateData.stateStartTime
            })

            -- Limit history size
            while #stateData.stateHistory > stateData.maxHistory do
                table.remove(stateData.stateHistory)
            end

            -- Update current state
            stateData.current = stateData.showDetailedState and currentStateName or getSimplifiedState(currentStateName)
            stateData.lastState = currentStateName
            stateData.stateStartTime = now
            stateData.lastUpdateTime = now
        end
    end
end

-- Helper function to format time duration
local function formatDuration(startTime)
    local duration = (mq.gettime() - startTime) / 1000 / 60 -- Convert to minutes
    if duration < 60 then
        return string.format("%.0fm", duration)
    else
        local hours = math.floor(duration / 60)
        local mins = duration % 60
        return string.format("%dh %.0fm", hours, mins)
    end
end

-- Helper function to calculate rates
local function calculateRates(stats, sessionStart)
    local sessionDuration = (mq.gettime() - sessionStart) / 1000 / 60 -- minutes
    if sessionDuration <= 0 then
        return 0, 0
    end

    local corpseRate = stats.corpsesProcessed / sessionDuration
    local itemRate = (stats.itemsLooted + stats.itemsIgnored + stats.itemsDestroyed) / sessionDuration

    return corpseRate, itemRate
end

function liveStatsWindow.toggle()
    liveStatsWindow.show = not liveStatsWindow.show
    configModule.liveStats.show = liveStatsWindow.show
    if configModule.save then configModule.save() end
end

function liveStatsWindow.setVisible(visible)
    liveStatsWindow.show = visible
    configModule.liveStats.show = visible
    if configModule.save then configModule.save() end
end

function liveStatsWindow.isVisible()
    return liveStatsWindow.show
end

function liveStatsWindow.draw(SmartLootEngine, config)
    if not liveStatsWindow.show then
        return
    end

    local now = mq.gettime()

    -- Set window transparency
    ImGui.SetNextWindowBgAlpha(0.55)

    -- Position window if not dragging
    if not liveStatsWindow.isDragging then
        ImGui.SetNextWindowPos(liveStatsWindow.position.x, liveStatsWindow.position.y, ImGuiCond.FirstUseEver)
    end

    local open, shouldClose = ImGui.Begin("SmartLoot Live Stats", true, liveStatsWindow.windowFlags)
    if open then
        -- Handle dragging - FIXED VERSION
        if ImGui.IsWindowHovered() and ImGui.IsMouseDragging(ImGuiMouseButton.Left) then
            if not liveStatsWindow.isDragging then
                liveStatsWindow.isDragging = true

                -- Get mouse and window positions safely
                local mouseX, mouseY = getMousePositionValues()
                local windowX, windowY = getPositionValues(ImGui.GetWindowPos())

                liveStatsWindow.dragOffset.x = mouseX - windowX
                liveStatsWindow.dragOffset.y = mouseY - windowY
            end
        end

        if liveStatsWindow.isDragging then
            if ImGui.IsMouseDragging(ImGuiMouseButton.Left) then
                -- Get current mouse position safely
                local mouseX, mouseY = getMousePositionValues()

                liveStatsWindow.position.x = mouseX - liveStatsWindow.dragOffset.x
                liveStatsWindow.position.y = mouseY - liveStatsWindow.dragOffset.y
                ImGui.SetWindowPos(liveStatsWindow.position.x, liveStatsWindow.position.y)
            else
                liveStatsWindow.isDragging = false
                -- Save position after dragging completes
                configModule.liveStats.position.x = liveStatsWindow.position.x
                configModule.liveStats.position.y = liveStatsWindow.position.y
                if configModule.save then configModule.save() end
            end
        end

        -- Store current position when not dragging - FIXED VERSION
        if not liveStatsWindow.isDragging then
            local posX, posY = getPositionValues(ImGui.GetWindowPos())
            liveStatsWindow.position.x = posX
            liveStatsWindow.position.y = posY
        end

        -- Get current engine state
        local state = SmartLootEngine.getState()
        local currentMode = SmartLootEngine.getLootMode()

        -- Update state display
        updateStateDisplay(state.currentStateName)

        local function titleCase(str)
            return str:gsub("(%a)([%w_']*)", function(first, rest)
                return first:upper() .. rest:lower()
            end)
        end
        -- Header with current mode
        local modeText = titleCase(currentMode)
        local r, g, b, a = getModeColor(currentMode)
        ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
        ImGui.Text("SmartLoot " .. modeText)
        ImGui.PopStyleColor()

        local tempRules = require("modules.temp_rules")
        local tempRuleCount = tempRules.getCount()
        if tempRuleCount > 0 then
            ImGui.Separator()
            ImGui.TextColored(0.8, 0.6, 0.2, 1, "AFK Farm Mode Active")
            ImGui.Text("Temp Rules: " .. tempRuleCount)

            if ImGui.IsItemHovered() then
                ImGui.BeginTooltip()
                ImGui.Text("Temporary rules waiting for items:")
                local rules = tempRules.getAll()
                for i = 1, math.min(5, #rules) do
                    ImGui.BulletText(rules[i].itemName)
                end
                if #rules > 5 then
                    ImGui.Text("... and " .. (#rules - 5) .. " more")
                end
                ImGui.EndTooltip()
            end
        end

        if not liveStatsWindow.compactMode then
            ImGui.Separator()

            -- Session Statistics in organized layout
            ImGui.Text("Session Stats:")

            -- Create mini-table for better organization
            if ImGui.BeginTable("StatsTable", 2, ImGuiTableFlags.SizingStretchProp) then
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.Text("Corpses:")
                ImGui.TableSetColumnIndex(1)
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)
                ImGui.Text(tostring(state.stats.corpsesProcessed))
                ImGui.PopStyleColor()

                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.Text("Looted:")
                ImGui.TableSetColumnIndex(1)
                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1.0)
                ImGui.Text(tostring(state.stats.itemsLooted))
                ImGui.PopStyleColor()

                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.Text("Ignored:")
                ImGui.TableSetColumnIndex(1)
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 0.2, 1.0)
                ImGui.Text(tostring(state.stats.itemsIgnored))
                ImGui.PopStyleColor()

                -- Connected peers count
                if config and config.getConnectedPeers then
                    local connectedPeers = config.getConnectedPeers()
                    local peerCount = connectedPeers and #connectedPeers or 0

                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text("Connected:")
                    ImGui.TableSetColumnIndex(1)
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.8, 1.0)
                    ImGui.Text(tostring(peerCount))
                    ImGui.PopStyleColor()
                end

                ImGui.EndTable()
            end

            -- Session duration and rates
            ImGui.Separator()
            if ImGui.BeginTable("SessionTable", 2, ImGuiTableFlags.SizingStretchProp) then
                if state.stats.sessionStart then
                    local duration = formatDuration(state.stats.sessionStart)
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text("Duration:")
                    ImGui.TableSetColumnIndex(1)
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.8, 1.0, 1.0)
                    ImGui.Text(duration)
                    ImGui.PopStyleColor()

                    -- Calculate and display rates
                    local corpseRate, itemRate = calculateRates(state.stats, state.stats.sessionStart)
                    if corpseRate > 0 then
                        ImGui.TableNextRow()
                        ImGui.TableSetColumnIndex(0)
                        ImGui.Text("C/min:")
                        ImGui.TableSetColumnIndex(1)
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)
                        ImGui.Text(string.format("%.1f", corpseRate))
                        ImGui.PopStyleColor()

                        ImGui.TableNextRow()
                        ImGui.TableSetColumnIndex(0)
                        ImGui.Text("I/min:")
                        ImGui.TableSetColumnIndex(1)
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.8, 1.0)
                        ImGui.Text(string.format("%.1f", itemRate))
                        ImGui.PopStyleColor()
                    end
                end

                -- Database connection status
                if config and config.isDatabaseConnected then
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text("Database:")
                    ImGui.TableSetColumnIndex(1)
                    if config.isDatabaseConnected() then
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1.0)
                        ImGui.Text("Connected")
                        ImGui.PopStyleColor()
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.2, 0.2, 1.0)
                        ImGui.Text("Disconnected")
                        ImGui.PopStyleColor()
                    end
                end

                ImGui.EndTable()
            end
        else
            -- Compact mode - single line display with simplified state
            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)
            ImGui.Text("| ")
            ImGui.PopStyleColor()

            -- Show simplified state in compact mode
            ImGui.SameLine()
            local sr, sg, sb, sa = getStateColor(liveStatsWindow.stateDisplay.current)
            ImGui.PushStyleColor(ImGuiCol.Text, sr, sg, sb, sa)
            ImGui.Text(liveStatsWindow.stateDisplay.current .. " |")
            ImGui.PopStyleColor()

            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)
            ImGui.Text("C:" .. tostring(state.stats.corpsesProcessed) .. " ")
            ImGui.PopStyleColor()

            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1.0)
            ImGui.Text("L:" .. tostring(state.stats.itemsLooted) .. " ")
            ImGui.PopStyleColor()

            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 0.2, 1.0)
            ImGui.Text("I:" .. tostring(state.stats.itemsIgnored) .. " ")
            ImGui.PopStyleColor()

            ImGui.SameLine()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.2, 0.8, 1.0)
            ImGui.Text("D:" .. tostring(state.stats.itemsDestroyed))
            ImGui.PopStyleColor()

            -- Add peer count in compact mode
            if config and config.getConnectedPeers then
                local connectedPeers = config.getConnectedPeers()
                local peerCount = connectedPeers and #connectedPeers or 0
                ImGui.SameLine()
                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.8, 1.0)
                ImGui.Text(" P:" .. tostring(peerCount))
                ImGui.PopStyleColor()
            end
        end

        -- Enhanced Farming Mode Button (only show in Main mode)
        if currentMode == "main" and config then
            ImGui.Separator()

            local isFarmingActive = configModule.isFarmingModeActive and configModule.isFarmingModeActive() or false

            -- Create enhanced farming mode button
            local buttonText = isFarmingActive and "Farming Mode ON" or "Farming Mode OFF"
            local buttonWidth = 160
            local buttonHeight = 28

            -- Custom button styling based on state
            if isFarmingActive then
                -- Pulsing orange effect for active state
                local pulse = (math.sin(mq.gettime() / 1000 * 4.0) + 1.0) * 0.5
                local intensity = 180 + 75 * pulse
                ImGui.PushStyleColor(ImGuiCol.Button, 1.0, 0.55, 0.0, intensity / 255)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1.0, 0.65, 0.1, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.9, 0.45, 0.0, 1.0)
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 1.0, 1.0)
            else
                -- Normal green state
                ImGui.PushStyleColor(ImGuiCol.Button, 0.13, 0.54, 0.13, 0.7)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.18, 0.62, 0.18, 0.9)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.10, 0.39, 0.10, 0.9)
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 1.0, 1.0)
            end

            if ImGui.Button(buttonText, buttonWidth, buttonHeight) then
                if configModule.toggleFarmingMode then
                    local newState = configModule.toggleFarmingMode()
                    mq.cmd('/echo \\aySmartLoot: Farming mode ' ..
                        (newState and 'ENABLED' or 'DISABLED') .. ' - bypasses corpse deduplication\\ax')
                else
                    mq.cmd('/echo \\arSmartLoot: Error - toggleFarmingMode function not found\\ax')
                end
            end

            ImGui.PopStyleColor(4)

            -- Enhanced tooltip
            if ImGui.IsItemHovered() then
                ImGui.BeginTooltip()
                if isFarmingActive then
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.6, 0.0, 1.0)
                    ImGui.Text("FARMING MODE ACTIVE")
                    ImGui.PopStyleColor()
                    ImGui.Separator()
                    ImGui.Text("Corpse deduplication bypassed")
                    ImGui.Text("Will re-loot same corpses")
                    ImGui.Text("Click to disable farming mode")
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1.0)
                    ImGui.Text("Farming Mode")
                    ImGui.PopStyleColor()
                    ImGui.Separator()
                    ImGui.Text("Toggle persistent farming mode")
                    ImGui.Text("Bypasses 10-minute corpse deduplication")
                    ImGui.Separator()
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 0.2, 1.0)
                    ImGui.Text("Use when:")
                    ImGui.PopStyleColor()
                    ImGui.BulletText("Repeatedly farming the same spawn")
                    ImGui.BulletText("Testing loot table changes")
                    ImGui.BulletText("Recording all corpse encounters")
                    ImGui.Separator()
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0)
                    ImGui.Text("Click to enable persistent farming mode")
                    ImGui.PopStyleColor()
                end
                ImGui.EndTooltip()
            end
        end

        -- Right-click context menu
        if ImGui.BeginPopupContextWindow("LiveStatsContext") then
            ImGui.Text("Live Stats Options")
            ImGui.Separator()

            if ImGui.MenuItem("Toggle Compact Mode", nil, liveStatsWindow.compactMode) then
                liveStatsWindow.compactMode = not liveStatsWindow.compactMode
                configModule.liveStats.compactMode = liveStatsWindow.compactMode
                if configModule.save then configModule.save() end
            end

            if ImGui.MenuItem("Show Detailed States", nil, liveStatsWindow.stateDisplay.showDetailedState) then
                liveStatsWindow.stateDisplay.showDetailedState = not liveStatsWindow.stateDisplay.showDetailedState
                -- Reset state display
                liveStatsWindow.stateDisplay.lastUpdateTime = 0
                configModule.liveStats.stateDisplay.showDetailedState = liveStatsWindow.stateDisplay.showDetailedState
                if configModule.save then configModule.save() end
            end

            ImGui.Separator()

            ImGui.Text("State Update Speed:")
            local newMinDisplayTime = ImGui.SliderInt("Min Display Time (ms)", liveStatsWindow.stateDisplay.minDisplayTime, 100, 2000)
            if newMinDisplayTime ~= liveStatsWindow.stateDisplay.minDisplayTime then
                liveStatsWindow.stateDisplay.minDisplayTime = newMinDisplayTime
                configModule.liveStats.stateDisplay.minDisplayTime = newMinDisplayTime
                if configModule.save then configModule.save() end
            end

            ImGui.Separator()

            local newAlpha = ImGui.SliderFloat("Transparency", liveStatsWindow.alpha, 0.1, 1.0, "%.1f")
            if newAlpha ~= liveStatsWindow.alpha then
                liveStatsWindow.alpha = newAlpha
                configModule.liveStats.alpha = newAlpha
                if configModule.save then configModule.save() end
            end

            ImGui.Separator()

            if ImGui.MenuItem("Reset Position") then
                liveStatsWindow.position.x = 200
                liveStatsWindow.position.y = 200
                ImGui.SetWindowPos(liveStatsWindow.position.x, liveStatsWindow.position.y)
                configModule.liveStats.position.x = 200
                configModule.liveStats.position.y = 200
                if configModule.save then configModule.save() end
            end

            if ImGui.MenuItem("Reset Stats") then
                if SmartLootEngine.resetStats then
                    SmartLootEngine.resetStats()
                end
            end

            ImGui.Separator()

            if ImGui.MenuItem("Hide Window") then
                liveStatsWindow.show = false
                configModule.liveStats.show = false
                if configModule.save then configModule.save() end
            end

            ImGui.EndPopup()
        end

        -- Enhanced tooltip on hover
        if ImGui.IsWindowHovered() then
            ImGui.BeginTooltip()
            ImGui.Text("SmartLoot Live Statistics")
            ImGui.Separator()

            -- Show current actual state if simplified
            if not liveStatsWindow.stateDisplay.showDetailedState then
                ImGui.Text("Actual State: " .. state.currentStateName)
            end

            -- Show session duration
            if state.stats.sessionStart then
                local duration = formatDuration(state.stats.sessionStart)
                ImGui.Text("Session Duration: " .. duration)

                -- Show rates if we have data
                local corpseRate, itemRate = calculateRates(state.stats, state.stats.sessionStart)
                if corpseRate > 0 then
                    ImGui.Text(string.format("Corpses/min: %.1f", corpseRate))
                    ImGui.Text(string.format("Items/min: %.1f", itemRate))
                end
            end

            -- Show state history
            if #liveStatsWindow.stateDisplay.stateHistory > 0 then
                ImGui.Separator()
                ImGui.Text("Recent States:")
                for i = 1, math.min(3, #liveStatsWindow.stateDisplay.stateHistory) do
                    local hist = liveStatsWindow.stateDisplay.stateHistory[i]
                    ImGui.BulletText(string.format("%s (%.1fs)", hist.state, hist.duration / 1000))
                end
            end

            ImGui.Separator()
            ImGui.Text("Right-click for options")
            ImGui.Text("Drag to move window")
            ImGui.Text("C=Corpses, L=Looted, I=Ignored, D=Destroyed, P=Connected")

            ImGui.EndTooltip()
        end
    end
    ImGui.End()

    if shouldClose == false then
        liveStatsWindow.show = false
    end
end

-- Configuration functions
function liveStatsWindow.setCompactMode(compact)
    liveStatsWindow.compactMode = compact
    configModule.liveStats.compactMode = compact
    if configModule.save then configModule.save() end
end

function liveStatsWindow.setAlpha(alpha)
    liveStatsWindow.alpha = math.max(0.1, math.min(1.0, alpha))
    configModule.liveStats.alpha = liveStatsWindow.alpha
    if configModule.save then configModule.save() end
end

function liveStatsWindow.setPosition(x, y)
    liveStatsWindow.position.x = x
    liveStatsWindow.position.y = y
    configModule.liveStats.position.x = x
    configModule.liveStats.position.y = y
    if configModule.save then configModule.save() end
end

function liveStatsWindow.getConfig()
    return {
        show = liveStatsWindow.show,
        compactMode = liveStatsWindow.compactMode,
        alpha = liveStatsWindow.alpha,
        position = liveStatsWindow.position,
        stateDisplay = {
            showDetailedState = liveStatsWindow.stateDisplay.showDetailedState,
            minDisplayTime = liveStatsWindow.stateDisplay.minDisplayTime
        }
    }
end

function liveStatsWindow.setConfig(config)
    if config.show ~= nil then liveStatsWindow.show = config.show end
    if config.compactMode ~= nil then liveStatsWindow.compactMode = config.compactMode end
    if config.alpha ~= nil then liveStatsWindow.alpha = config.alpha end
    if config.position then
        liveStatsWindow.position.x = config.position.x or liveStatsWindow.position.x
        liveStatsWindow.position.y = config.position.y or liveStatsWindow.position.y
    end
    if config.stateDisplay then
        if config.stateDisplay.showDetailedState ~= nil then
            liveStatsWindow.stateDisplay.showDetailedState = config.stateDisplay.showDetailedState
        end
        if config.stateDisplay.minDisplayTime ~= nil then
            liveStatsWindow.stateDisplay.minDisplayTime = config.stateDisplay.minDisplayTime
        end
    end
end

return liveStatsWindow
