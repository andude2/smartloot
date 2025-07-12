-- ui/ui_floating_button.lua
local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local logging = require("modules.logging")
local database = require("modules.database")

local uiFloatingButton = {}

-- Initialize floating button state
local floatingButtonState = {
    show = true,
    position = { x = 100, y = 100 },
    expanded = false,
    buttonSize = 60,
    expandedWidth = 320,
    expandedHeight = 240,
    alpha = 0.95,
    isDragging = false,
    dragOffset = { x = 0, y = 0 },
    SmartLootEngine = nil, -- Store reference to SmartLootEngine
}

-- Helper function to calculate distance between two points
local function distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

-- Helper function to convert RGB to ImGui color (Lua 5.1 compatible)
local function colorToU32(r, g, b, a)
    local rInt = math.floor(r * 255)
    local gInt = math.floor(g * 255)
    local bInt = math.floor(b * 255)
    local aInt = math.floor(a * 255)
    return aInt * 16777216 + bInt * 65536 + gInt * 256 + rInt
end

-- Helper function to create gradient button with standard ImGui
local function createModernButton(text, width, height, baseColor, hoverColor, activeColor)
    -- Apply global alpha to button colors
    local alpha = floatingButtonState.alpha
    ImGui.PushStyleColor(ImGuiCol.Button, baseColor.r, baseColor.g, baseColor.b, baseColor.a * alpha)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, hoverColor.r, hoverColor.g, hoverColor.b, hoverColor.a * alpha)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, activeColor.r, activeColor.g, activeColor.b, activeColor.a * alpha)
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
    
    local result = ImGui.Button(text, width, height)
    
    ImGui.PopStyleVar(1)
    ImGui.PopStyleColor(3)
    return result
end

function uiFloatingButton.draw(lootUI, settings, toggle_ui, loot, util, SmartLootEngine)
    if not floatingButtonState.show then return end
    
    -- Store SmartLootEngine reference for mode switching
    floatingButtonState.SmartLootEngine = SmartLootEngine

    -- === MAIN BUTTON WINDOW (Always visible) ===
    local buttonWindowFlags = ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.AlwaysAutoResize + 
                             ImGuiWindowFlags.NoFocusOnAppearing + ImGuiWindowFlags.NoNav
    
    -- Make background fully transparent for the button
    ImGui.SetNextWindowBgAlpha(0.0)
    
    -- Set position for the button
    if not floatingButtonState.isDragging then
        ImGui.SetNextWindowPos(floatingButtonState.position.x, floatingButtonState.position.y, ImGuiCond.FirstUseEver)
    end

    local buttonOpen = true
    if ImGui.Begin("SmartLoot Button", buttonOpen, buttonWindowFlags) then
        -- Get and update window position
        local windowPosX, windowPosY = ImGui.GetWindowPos()
        floatingButtonState.position.x = windowPosX
        floatingButtonState.position.y = windowPosY

        -- === COMPACT BUTTON RENDERING (Always shown) ===
        local buttonSize = floatingButtonState.buttonSize
        
        -- Get current SmartLoot status
        local isActive = not (lootUI.paused or false)
        local hasDatabase = database and database.isConnected and type(database.isConnected) == "function" and database.isConnected() or false
        
        if not hasDatabase and database then
            hasDatabase = (database.healthCheck ~= nil) or (database.saveLootRule ~= nil)
        end
        
        -- Get draw list for custom rendering
        local drawList = ImGui.GetWindowDrawList()
        local buttonPosX, buttonPosY = ImGui.GetCursorScreenPos()
        local buttonCenter = { x = buttonPosX + buttonSize * 0.5, y = buttonPosY + buttonSize * 0.5 }
        local radius = buttonSize * 0.4
        
        -- Check if button is hovered
        local mousePosX, mousePosY = ImGui.GetMousePos()
        local distanceToCenter = distance(mousePosX, mousePosY, buttonCenter.x, buttonCenter.y)
        local isHovered = distanceToCenter <= radius and ImGui.IsWindowHovered()
        local isPressed = isHovered and ImGui.IsMouseDown(ImGuiMouseButton.Left)
        
        -- Determine colors based on state
        local baseColor, glowColor, textColor, modeText
        local alpha = floatingButtonState.alpha
        
        if floatingButtonState.expanded then
            -- Green when expanded
            baseColor = isPressed and {r=0.18, g=0.55, b=0.18, a=0.8 * alpha} or
                       isHovered and {r=0.24, g=0.71, b=0.24, a=0.9 * alpha} or {r=0.20, g=0.63, b=0.20, a=0.7 * alpha}
            glowColor = {r=0.31, g=1.0, b=0.31, a=0.4 * alpha}
            modeText = "SL"
        elseif hasDatabase and isActive then
            -- Blue for active
            baseColor = isPressed and {r=0.18, g=0.39, b=0.71, a=0.8 * alpha} or
                       isHovered and {r=0.24, g=0.51, b=0.86, a=0.9 * alpha} or {r=0.20, g=0.47, b=0.78, a=0.7 * alpha}
            glowColor = {r=0.31, g=0.59, b=1.0, a=0.5 * alpha}
            modeText = "SL"
        elseif hasDatabase and not isActive then
            -- Orange for paused
            baseColor = isPressed and {r=0.71, g=0.47, b=0.18, a=0.8 * alpha} or
                       isHovered and {r=0.86, g=0.59, b=0.24, a=0.9 * alpha} or {r=0.78, g=0.55, b=0.20, a=0.7 * alpha}
            glowColor = {r=1.0, g=0.71, b=0.31, a=0.4 * alpha}
            modeText = "||"
        else
            -- Gray for disabled
            baseColor = isPressed and {r=0.31, g=0.31, b=0.31, a=0.8 * alpha} or
                       isHovered and {r=0.39, g=0.39, b=0.39, a=0.9 * alpha} or {r=0.35, g=0.35, b=0.35, a=0.7 * alpha}
            glowColor = {r=0.59, g=0.59, b=0.59, a=0.2 * alpha}
            modeText = "X"
        end
        textColor = {r=1.0, g=1.0, b=1.0, a=1.0 * alpha}
        
        -- Draw glow effect when hovered
        if isHovered then
            local glowRadius = radius + 6.0
            local glowColorU32 = colorToU32(glowColor.r, glowColor.g, glowColor.b, glowColor.a * 0.5)
            drawList:AddCircleFilled(ImVec2(buttonCenter.x, buttonCenter.y), glowRadius, glowColorU32, 0)
        end
        
        -- Draw main button circle
        local baseColorU32 = colorToU32(baseColor.r, baseColor.g, baseColor.b, baseColor.a)
        drawList:AddCircleFilled(ImVec2(buttonCenter.x, buttonCenter.y), radius, baseColorU32, 0)
        
        -- Add mode indicator ring for active states
        if hasDatabase and isActive then
            local ringColor = colorToU32(0.39, 0.78, 1.0, 0.6 * alpha)
            drawList:AddCircle(ImVec2(buttonCenter.x, buttonCenter.y), radius + 2.0, ringColor, 0, 2.0)
        end
        
        -- Add inner highlight/shadow
        if isPressed then
            local shadowColor = colorToU32(0, 0, 0, 0.3 * alpha)
            drawList:AddCircleFilled(ImVec2(buttonCenter.x, buttonCenter.y), radius * 0.7, shadowColor, 0)
        else
            local highlightColor = colorToU32(1.0, 1.0, 1.0, 0.2 * alpha)
            drawList:AddCircleFilled(ImVec2(buttonCenter.x - radius * 0.2, buttonCenter.y - radius * 0.2), radius * 0.3, highlightColor, 0)
        end
        
        -- Draw border
        local borderAlpha = (isHovered and 0.6 or 0.31) * alpha
        local borderColor = colorToU32(1.0, 1.0, 1.0, borderAlpha)
        drawList:AddCircle(ImVec2(buttonCenter.x, buttonCenter.y), radius, borderColor, 0, 1.5)
        
        -- Create invisible button for interaction
        ImGui.SetCursorScreenPos(buttonPosX, buttonPosY)
        local clicked = ImGui.InvisibleButton("SmartLootToggle", buttonSize, buttonSize)
        
        -- Draw text centered
        local textSize = ImGui.CalcTextSize(modeText)
        local textPos = { x = buttonCenter.x - textSize * 0.5, y = buttonCenter.y - textSize * 0.5 }
        
        -- Draw text shadow
        local shadowColor = colorToU32(0, 0, 0, 0.5 * alpha)
        drawList:AddText(ImVec2(textPos.x + 1, textPos.y + 1), shadowColor, modeText)
        
        -- Draw main text
        local textColorU32 = colorToU32(textColor.r, textColor.g, textColor.b, textColor.a)
        drawList:AddText(ImVec2(textPos.x, textPos.y), textColorU32, modeText)
        
        -- Add small database status indicator
        local indicatorPos = { x = buttonCenter.x + radius * 0.6, y = buttonCenter.y - radius * 0.6 }
        local indicatorColor = hasDatabase and colorToU32(0, 1.0, 0, 0.8 * alpha) or colorToU32(1.0, 0.4, 0, 0.8 * alpha)
        drawList:AddCircleFilled(ImVec2(indicatorPos.x, indicatorPos.y), 4.0, indicatorColor, 0)
        local indicatorBorder = colorToU32(1.0, 1.0, 1.0, 0.6 * alpha)
        drawList:AddCircle(ImVec2(indicatorPos.x, indicatorPos.y), 4.0, indicatorBorder, 0, 1.0)
        
        -- Handle click - SIMPLIFIED: Just toggle main UI
        if clicked then
            toggle_ui()
        end
        
        -- Enhanced tooltip
        if ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            ImGui.Text("SmartLoot Control")
            ImGui.Separator()
            
            local statusText = hasDatabase and (isActive and "Active" or "Paused") or "Database Disconnected"
            local statusColor = hasDatabase and (isActive and {0.2, 0.8, 0.2, 1} or {0.8, 0.6, 0.2, 1}) or {0.8, 0.2, 0.2, 1}
            
            ImGui.Text("Status: ")
            ImGui.SameLine()
            ImGui.TextColored(statusColor[1], statusColor[2], statusColor[3], statusColor[4], statusText)
            
            ImGui.Text("Database: ")
            ImGui.SameLine()
            ImGui.TextColored(hasDatabase and 0.2 or 0.8, hasDatabase and 0.8 or 0.2, 0.2, 1, hasDatabase and "Connected" or "Disconnected")
            
            ImGui.Separator()
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Click: Toggle main UI")
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Right-click: Quick options")
            ImGui.EndTooltip()
        end

        -- Right-click context menu for the button
        if ImGui.BeginPopupContextWindow("SmartLootButtonContext") then
            ImGui.Text("SmartLoot Options")
            ImGui.Separator()
            
            if ImGui.MenuItem(floatingButtonState.expanded and "Hide Control Panel" or "Show Control Panel", nil, floatingButtonState.expanded) then
                floatingButtonState.expanded = not floatingButtonState.expanded
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Open Main UI") then
                toggle_ui()
            end
            
            if ImGui.MenuItem(lootUI.paused and "Resume SmartLoot" or "Pause SmartLoot") then
                lootUI.paused = not lootUI.paused
                if util and util.printSmartLoot then
                    util.printSmartLoot(lootUI.paused and "SmartLoot paused" or "SmartLoot resumed", lootUI.paused and "warning" or "info")
                else
                    print(lootUI.paused and "SmartLoot paused" or "SmartLoot resumed")
                end
            end
            
            ImGui.Separator()
            
            -- Mode Selection Menu
            if ImGui.BeginMenu("Select Mode") then
                -- Get current mode from SmartLootEngine if available
                local currentMode = "unknown"
                if floatingButtonState.SmartLootEngine then
                    currentMode = floatingButtonState.SmartLootEngine.getLootMode()
                end
                
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "Current: " .. currentMode)
                ImGui.Separator()
                
                if ImGui.MenuItem("Main Mode", nil, currentMode == "main") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.Main, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("Switched to Main mode", "info")
                        end
                    else
                        mq.cmd('/sl_mode main')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Active looting mode - processes corpses continuously")
                end
                
                if ImGui.MenuItem("Background Mode", nil, currentMode == "background") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.Background, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("Switched to Background mode", "info")
                        end
                    else
                        mq.cmd('/sl_mode background')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Autonomous looting in the background")
                end
                
                if ImGui.MenuItem("Once Mode", nil, currentMode == "once") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.Once, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("Switched to Once mode", "info")
                        end
                    else
                        mq.cmd('/sl_mode once')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Loot all current corpses then stop")
                end
                
                ImGui.Separator()
                
                if ImGui.MenuItem("RGMain Mode", nil, currentMode == "rgmain") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.RGMain, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("Switched to RGMain mode", "info")
                        end
                    else
                        mq.cmd('/sl_mode rgmain')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("RGMercs main looter - waits for triggers")
                end
                
                if ImGui.MenuItem("RGOnce Mode", nil, currentMode == "rgonce") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.RGOnce, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("Switched to RGOnce mode", "info")
                        end
                    else
                        mq.cmd('/sl_mode rgonce')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("RGMercs once mode - single loot pass")
                end
                
                ImGui.Separator()
                
                if ImGui.MenuItem("Disable", nil, currentMode == "disabled") then
                    if floatingButtonState.SmartLootEngine then
                        floatingButtonState.SmartLootEngine.setLootMode(floatingButtonState.SmartLootEngine.LootMode.Disabled, "UI Selection")
                        if util and util.printSmartLoot then
                            util.printSmartLoot("SmartLoot disabled", "warning")
                        end
                    else
                        mq.cmd('/sl_mode disabled')
                    end
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Completely disable SmartLoot")
                end
                
                ImGui.EndMenu()
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Loot Once") then
                if loot and loot.lootCorpses then
                    if util and util.printSmartLoot then
                        util.printSmartLoot("Manual loot pass initiated from floating UI", "info")
                    end
                    loot.lootCorpses(lootUI, settings)
                else
                    mq.cmd('/sl_doloot')
                end
            end
            
            if ImGui.MenuItem("Clear Cache") then
                mq.cmd('/sl_clearcache')
            end
            
            if ImGui.MenuItem("Auto Known") then
                mq.cmd('/slautolootknown')
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Reset Position") then
                floatingButtonState.position.x = 100
                floatingButtonState.position.y = 100
                ImGui.SetWindowPos("SmartLoot Button", 100, 100)
            end
            
            if ImGui.BeginMenu("Button Size") then
                if ImGui.MenuItem("Small", nil, floatingButtonState.buttonSize == 50) then
                    floatingButtonState.buttonSize = 50
                end
                if ImGui.MenuItem("Medium", nil, floatingButtonState.buttonSize == 60) then
                    floatingButtonState.buttonSize = 60
                end
                if ImGui.MenuItem("Large", nil, floatingButtonState.buttonSize == 80) then
                    floatingButtonState.buttonSize = 80
                end
                ImGui.EndMenu()
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Hide Interface") then
                floatingButtonState.show = false
            end
            
            ImGui.EndPopup()
        end
    end
    ImGui.End()

    -- === EXPANDED PANEL WINDOW (Only when expanded) ===
    if floatingButtonState.expanded then
        local panelWindowFlags = ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.AlwaysAutoResize + 
                                ImGuiWindowFlags.NoFocusOnAppearing + ImGuiWindowFlags.NoNav
        
        -- Position the panel next to the button
        local panelX = floatingButtonState.position.x + floatingButtonState.buttonSize + 10
        local panelY = floatingButtonState.position.y
        ImGui.SetNextWindowPos(panelX, panelY, ImGuiCond.Always)
        
        -- Apply alpha to expanded mode background
        ImGui.SetNextWindowBgAlpha(floatingButtonState.alpha)
        
        local panelOpen = true
        if ImGui.Begin("SmartLoot Panel", panelOpen, panelWindowFlags) then
            local alpha = floatingButtonState.alpha
            
            -- Push styles at the beginning and track count
            local styleVarCount = 0
            local styleColorCount = 0
            
            ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 12.0)
            styleVarCount = styleVarCount + 1
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            styleVarCount = styleVarCount + 1
            
            ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.13, 0.13, 0.13, 0.95 * alpha)
            styleColorCount = styleColorCount + 1
            ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.95, 0.95, 1.0 * alpha)
            styleColorCount = styleColorCount + 1
            ImGui.PushStyleColor(ImGuiCol.Separator, 0.5, 0.5, 0.5, 0.8 * alpha)
            styleColorCount = styleColorCount + 1
            ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 0.5 * alpha)
            styleColorCount = styleColorCount + 1
            
            -- Header
            ImGui.TextColored(0.29, 0.73, 0.96, 1.0 * alpha, "SmartLoot Control Center")
            ImGui.SameLine()
            ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 35)
            
            -- Close button
            local closeColors = {
                base = {r=0.91, g=0.30, b=0.28, a=0.8},
                hover = {r=0.95, g=0.40, b=0.38, a=0.9},
                active = {r=0.87, g=0.26, b=0.24, a=1.0}
            }
            if createModernButton("X##CollapsePanel", 25, 25, closeColors.base, closeColors.hover, closeColors.active) then
                floatingButtonState.expanded = false
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Close panel")
            end
            
            ImGui.Spacing()
            
            -- Status display
            local isActive = not (lootUI.paused or false)
            local hasDatabase = database and database.isConnected and type(database.isConnected) == "function" and database.isConnected() or false
            if not hasDatabase and database then
                hasDatabase = (database.healthCheck ~= nil) or (database.saveLootRule ~= nil)
            end
            
            local statusText, statusColor, statusIcon
            if hasDatabase and isActive then
                statusText = "Active"
                statusColor = {0.20, 0.76, 0.51, 1.0 * alpha}
                statusIcon = ">"
            elseif hasDatabase and not isActive then
                statusText = "Paused" 
                statusColor = {0.95, 0.61, 0.22, 1.0 * alpha}
                statusIcon = "||"
            else
                statusText = "Database Disconnected"
                statusColor = {0.91, 0.30, 0.28, 1.0 * alpha}
                statusIcon = "!"
            end
            
            ImGui.Text("Status: ")
            ImGui.SameLine()
            ImGui.TextColored(statusColor[1], statusColor[2], statusColor[3], statusColor[4], "[" .. statusIcon .. "] " .. statusText)
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Action buttons
            local buttonWidth = 140
            local buttonHeight = 32
            
            -- Define color schemes
            local colors = {
                success = {
                    base = {r=0.20, g=0.76, b=0.51, a=0.8},
                    hover = {r=0.25, g=0.81, b=0.56, a=0.9},
                    active = {r=0.15, g=0.71, b=0.46, a=1.0}
                },
                warning = {
                    base = {r=0.95, g=0.61, b=0.22, a=0.8},
                    hover = {r=1.0, g=0.66, b=0.27, a=0.9},
                    active = {r=0.90, g=0.56, b=0.17, a=1.0}
                },
                primary = {
                    base = {r=0.29, g=0.73, b=0.96, a=0.8},
                    hover = {r=0.34, g=0.78, b=1.0, a=0.9},
                    active = {r=0.24, g=0.68, b=0.91, a=1.0}
                },
                secondary = {
                    base = {r=0.22, g=0.31, b=0.42, a=0.8},
                    hover = {r=0.27, g=0.36, b=0.47, a=0.9},
                    active = {r=0.17, g=0.26, b=0.37, a=1.0}
                }
            }
            
            -- Row 1: Primary Actions
            if lootUI.paused then
                if createModernButton("RESUME", buttonWidth, buttonHeight, colors.success.base, colors.success.hover, colors.success.active) then
                    lootUI.paused = false
                    if util and util.printSmartLoot then
                        util.printSmartLoot("SmartLoot resumed")
                    end
                end
            else
                if createModernButton("PAUSE", buttonWidth, buttonHeight, colors.warning.base, colors.warning.hover, colors.warning.active) then
                    lootUI.paused = true
                    if util and util.printSmartLoot then
                        util.printSmartLoot("SmartLoot paused", "warning")
                    end
                end
            end
            
            ImGui.SameLine()
            if createModernButton("MAIN UI", buttonWidth, buttonHeight, colors.primary.base, colors.primary.hover, colors.primary.active) then
                toggle_ui()
            end
            
            -- Row 2: Utility Actions
            if createModernButton("CLEAR CACHE", buttonWidth, buttonHeight, colors.secondary.base, colors.secondary.hover, colors.secondary.active) then
                mq.cmd('/sl_clearcache')
            end
            
            ImGui.SameLine()
            if createModernButton("LOOT ONCE", buttonWidth, buttonHeight, colors.primary.base, colors.primary.hover, colors.primary.active) then
                if loot and loot.lootCorpses then
                    if util and util.printSmartLoot then
                        util.printSmartLoot("Manual loot pass initiated from floating UI", "info")
                    end
                    loot.lootCorpses(lootUI, settings)
                else
                    mq.cmd('/sl_doloot')
                end
            end
            
            -- Row 3: Advanced Actions
            if createModernButton("PEER CMDS", buttonWidth, buttonHeight, colors.secondary.base, colors.secondary.hover, colors.secondary.active) then
                lootUI.showPeerCommands = not (lootUI.showPeerCommands or false)
            end
            
            ImGui.SameLine()
            if createModernButton("AUTO KNOWN", buttonWidth, buttonHeight, colors.primary.base, colors.primary.hover, colors.primary.active) then
                mq.cmd('/slautolootknown')
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Connected Peers Section
            ImGui.TextColored(0.29, 0.73, 0.96, 1.0 * alpha, "Connected Peers")
            local connectedPeers = util and util.getConnectedPeers and util.getConnectedPeers() or {}
            
            if #connectedPeers > 0 then
                ImGui.BeginChild("PeersList", 0, 80, true)
                for i = 1, math.min(#connectedPeers, 4) do
                    local peer = connectedPeers[i]
                    ImGui.Text("• " .. peer)
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 60)
                
                    if createModernButton("LOOT##" .. peer, 50, 20, colors.primary.base, colors.primary.hover, colors.primary.active) then
                        -- Use the centralized communication system from config
                        local config = require("modules.config")
                        local lootType = (config.lootCommandType or ""):lower()
                        
                        if lootType == "dannet" then
                            mq.cmdf('/dex %s /smartloot_doloot', peer)
                            if util and util.printSmartLoot then
                                util.printSmartLoot("Sent DanNet loot command to " .. peer, "info")
                            end
                            
                        elseif lootType == "e3" then
                            mq.cmdf('/e3bct %s /smartloot_doloot', peer)
                            if util and util.printSmartLoot then
                                util.printSmartLoot("Sent E3 loot command to " .. peer, "info")
                            end
                            
                        elseif lootType == "bc" then
                            mq.cmdf('/bct %s /smartloot_doloot', peer)
                            if util and util.printSmartLoot then
                                util.printSmartLoot("Sent EQBC loot command to " .. peer, "info")
                            end
                            
                        else
                            -- Fallback to util function if available
                            if util and util.sendPeerCommand then
                                util.sendPeerCommand(peer, "/smartloot_doloot")
                                if util and util.printSmartLoot then
                                    util.printSmartLoot("Sent loot command to " .. peer, "info")
                                end
                            else
                                -- Last resort fallback (assume e3 for backward compatibility)
                                mq.cmdf('/e3bct %s /smartloot_doloot', peer)
                                if util and util.printSmartLoot then
                                    util.printSmartLoot("Sent fallback loot command to " .. peer, "warning")
                                end
                            end
                        end
                    end
                end
                ImGui.EndChild()
            else
                ImGui.TextColored(0.6, 0.6, 0.6, 1.0, "No connected peers found")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Quick Settings
            ImGui.TextColored(0.29, 0.73, 0.96, 1.0 * alpha, "Quick Settings")
            ImGui.Text("Transparency:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(120)
            local newAlpha, changedAlpha = ImGui.SliderFloat("##AlphaSlider", floatingButtonState.alpha, 0.3, 1.0, "%.1f")
            if changedAlpha then
                floatingButtonState.alpha = newAlpha
            end
            
            -- Pop styles at the end, before ImGui.End()
            ImGui.PopStyleColor(styleColorCount)
            ImGui.PopStyleVar(styleVarCount)
        end
        ImGui.End()
        
        if not panelOpen then
            floatingButtonState.expanded = false
        end
    end
    
    if not buttonOpen then
        floatingButtonState.show = false
    end
end

-- Public functions (keeping the same API)
function uiFloatingButton.show()
    floatingButtonState.show = true
end

function uiFloatingButton.hide()
    floatingButtonState.show = false
end

function uiFloatingButton.toggle()
    floatingButtonState.show = not floatingButtonState.show
end

function uiFloatingButton.isVisible()
    return floatingButtonState.show
end

function uiFloatingButton.expand()
    floatingButtonState.expanded = true
end

function uiFloatingButton.collapse()
    floatingButtonState.expanded = false
end

function uiFloatingButton.toggleExpansion()
    floatingButtonState.expanded = not floatingButtonState.expanded
end

function uiFloatingButton.isExpanded()
    return floatingButtonState.expanded
end

function uiFloatingButton.setPosition(x, y)
    floatingButtonState.position.x = x
    floatingButtonState.position.y = y
end

function uiFloatingButton.getPosition()
    return floatingButtonState.position.x, floatingButtonState.position.y
end

function uiFloatingButton.setAlpha(alpha)
    floatingButtonState.alpha = math.max(0.1, math.min(1.0, alpha))
end

function uiFloatingButton.getAlpha()
    return floatingButtonState.alpha
end

function uiFloatingButton.setButtonSize(size)
    floatingButtonState.buttonSize = math.max(40, math.min(120, size))
end

function uiFloatingButton.getButtonSize()
    return floatingButtonState.buttonSize
end

function uiFloatingButton.saveSettings()
    if util and util.printSmartLoot then
        util.printSmartLoot("Modern floating button settings saved: " ..
            "pos(" .. floatingButtonState.position.x .. "," .. floatingButtonState.position.y .. ") " ..
            "size(" .. floatingButtonState.buttonSize .. ") " ..
            "alpha(" .. floatingButtonState.alpha .. ") " ..
            "show(" .. tostring(floatingButtonState.show) .. ")", "info")
    end
end

function uiFloatingButton.loadSettings(settings)
    if settings then
        floatingButtonState.position.x = settings.x or floatingButtonState.position.x
        floatingButtonState.position.y = settings.y or floatingButtonState.position.y
        floatingButtonState.buttonSize = settings.size or floatingButtonState.buttonSize
        floatingButtonState.alpha = settings.alpha or floatingButtonState.alpha
        floatingButtonState.show = settings.show ~= false
    end
end

return uiFloatingButton