-- ui/ui_hotbar.lua (Enhanced version with floating button integration)
local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local logging = require("modules.logging")
local util = require("modules.util")

local uiHotbar = {}
local config = require("modules.config")

-- Hotbar state management - now uses config system
local hotbarState = {
    spacing = 5,
    isDragging = false,
    dragOffset = { x = 0, y = 0 },
    configMode = false, -- Configuration mode for button visibility (not saved)
}

-- Helper function to get current hotbar settings from config
local function getHotbarConfig()
    return config.getHotbarSettings()
end

-- Button configuration - defines all available buttons
local buttonConfig = {
    startBG = {
        id = "startBG",
        name = "Start BG Loot",
        icon = uiUtils.UI_ICONS.UP_ARROW or "▶",
        text = "Start",
        tooltip = "Start Background Loot on All Peers",
        color = {0, 0.8, 0}, -- Green
        visible = true,
        action = function()
            mq.cmd('/dgae /lua run smartloot background')
            logging.log("Started background loot on all peers")
        end
    },
    stopBG = {
        id = "stopBG",
        name = "Stop BG Loot",
        icon = uiUtils.UI_ICONS.REMOVE or "■",
        text = "Stop",
        tooltip = "Stop Background Loot on All Peers",
        color = {0.8, 0.2, 0}, -- Red
        visible = true,
        action = function()
            mq.cmd('/sl_stop_background all')
            logging.log("Stopped background loot on all peers")
        end
    },
    clearCache = {
        id = "clearCache",
        name = "Clear Cache",
        icon = uiUtils.UI_ICONS.REFRESH or "↻",
        text = "Clear",
        tooltip = "Clear Loot Cache",
        color = {0.2, 0.6, 0.8}, -- Blue
        visible = true,
        action = function()
            mq.cmd('/sl_clearcache')
        end
    },
    lootAll = {
        id = "lootAll",
        name = "Loot All",
        icon = uiUtils.UI_ICONS.LIGHTNING or "⚡",
        text = "Loot",
        tooltip = "Broadcast Loot Command to All Peers",
        color = {0.8, 0.8, 0.2}, -- Yellow
        visible = true,
        action = function()
            mq.cmd('/say #corpsefix')
            if util and util.broadcastCommand then
                util.broadcastCommand('/sl_doloot')
            end
        end
    },
    autoKnown = {
        id = "autoKnown",
        name = "Auto Known",
        icon = uiUtils.UI_ICONS.GEAR or "⚙",
        text = "Auto",
        tooltip = "Broadcast Auto Loot Known Items Command to All Peers",
        color = {0.6, 0.4, 0.8}, -- Purple
        visible = true,
        action = function()
            mq.cmd('/e3bcz /slautolootknown')
            logging.log("Broadcast auto loot known command")
        end
    },
    pausePeer = {
        id = "pausePeer",
        name = "Pause/Resume",
        icon = function(settings) return settings.peerTriggerPaused and (uiUtils.UI_ICONS.PLAY or "▶") or (uiUtils.UI_ICONS.PAUSE or "⏸") end,
        text = function(settings) return settings.peerTriggerPaused and "Resume" or "Pause" end,
        tooltip = function(settings) return settings.peerTriggerPaused and "Resume Peer Triggering" or "Pause Peer Triggering" end,
        color = function(settings) return settings.peerTriggerPaused and {0, 1, 0} or {1, 0.7, 0} end,
        visible = true,
        action = function(settings)
            settings.peerTriggerPaused = not settings.peerTriggerPaused
            logging.log(settings.peerTriggerPaused and "Peer triggering paused" or "Peer triggering resumed")
        end
    },
    toggleUI = {
        id = "toggleUI",
        name = "Toggle UI",
        icon = uiUtils.UI_ICONS.INFO or "ℹ",
        text = "UI",
        tooltip = "Toggle SmartLoot Main UI",
        color = {0.4, 0.7, 0.9}, -- Light blue
        visible = true,
        action = function(settings, toggle_ui)
            toggle_ui()
        end
    },
    addRule = {
        id = "addRule",
        name = "Add Rule",
        icon = uiUtils.UI_ICONS.ADD or "+",
        text = "Add",
        tooltip = "Add New Loot Rule",
        color = {0.2, 0.8, 0.4}, -- Green
        visible = true,
        action = function(settings, toggle_ui, lootUI)
            lootUI.addNewRulePopup = lootUI.addNewRulePopup or {}
            lootUI.addNewRulePopup.isOpen = true
            lootUI.addNewRulePopup.itemName = ""
            lootUI.addNewRulePopup.rule = "Keep"
            lootUI.addNewRulePopup.threshold = 1
            lootUI.addNewRulePopup.selectedCharacter = mq.TLO.Me.Name() or "Local"
        end
    },
    peerCommands = {
        id = "peerCommands",
        name = "Peer Commands",
        icon = "PC",
        text = "Peers",
        tooltip = function(lootUI) return (lootUI.showPeerCommands and "Hide Peer Commands" or "Show Peer Commands") end,
        color = function(lootUI) return lootUI.showPeerCommands and {0.8, 0.4, 0.2} or {0.4, 0.6, 0.8} end,
        visible = true,
        action = function(settings, toggle_ui, lootUI)
            local wasVisible = lootUI.showPeerCommands or false
            lootUI.showPeerCommands = not wasVisible
            if lootUI.showPeerCommands and not wasVisible then
                lootUI.peerCommandsOpen = true
                lootUI.uncollapsePeerCommandsOnNextOpen = true
            elseif not lootUI.showPeerCommands then
                lootUI.peerCommandsOpen = false
            end
        end
    },
    settings = {
        id = "settings",
        name = "Settings",
        icon = uiUtils.UI_ICONS.SETTINGS or "⚙",
        text = "Set",
        tooltip = "Open SmartLoot Settings",
        color = {0.7, 0.7, 0.7}, -- Gray
        visible = true,
        action = function(settings, toggle_ui, lootUI)
            toggle_ui()
            lootUI.showSettingsTab = true
        end
    }
}

-- Initialize button visibility from config (defined after buttonConfig)
local function initializeButtonVisibility()
    local hotbarConfig = getHotbarConfig()
    if not hotbarConfig or not hotbarConfig.buttonVisibility then
        return -- Config not ready yet
    end
    
    for buttonId, button in pairs(buttonConfig) do
        if hotbarConfig.buttonVisibility[buttonId] ~= nil then
            button.visible = hotbarConfig.buttonVisibility[buttonId]
        end
    end
end

function uiHotbar.draw(lootUI, settings, toggle_ui, loot, util)
    if not lootUI.showHotbar then return end 
    
    local hotbarConfig = getHotbarConfig()
    if not hotbarConfig.show then return end
    
    -- Initialize button visibility from config on first draw
    initializeButtonVisibility()

    local windowFlags = ImGuiWindowFlags.NoTitleBar +
                       ImGuiWindowFlags.NoScrollbar +
                       ImGuiWindowFlags.NoBackground +
                       ImGuiWindowFlags.AlwaysAutoResize +
                       ImGuiWindowFlags.NoFocusOnAppearing

    -- Set transparency
    ImGui.SetNextWindowBgAlpha(hotbarConfig.alpha)
    
    if not hotbarState.isDragging then
        ImGui.SetNextWindowPos(hotbarConfig.position.x, hotbarConfig.position.y, ImGuiCond.FirstUseEver)
    end

    local open = true
    if ImGui.Begin("SmartLoot Hotbar", open, windowFlags) then

        local buttonSize = hotbarConfig.buttonSize
        local spacing = hotbarState.spacing

        -- Helper function to add button with optional label
        local function addHotbarButton(icon, tooltip, action, color, enabled)
            enabled = enabled ~= false -- default to true
            
            local colorPushed = false
            local disabledPushed = false
            local roundingPushed = false
            
            -- Push rounded corners style
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            roundingPushed = true
            
            -- Handle disabled state (overrides color)
            if not enabled then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
                disabledPushed = true
            elseif color then
                ImGui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4] or 0.7)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] + 0.1, color[2] + 0.1, color[3] + 0.1, 0.9)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, color[1] - 0.1, color[2] - 0.1, color[3] - 0.1, 1.0)
                colorPushed = true
            end
            
            local buttonText = icon or "?"
            local buttonPressed = false
            
            if hotbarConfig.compactMode then
                buttonPressed = ImGui.Button(buttonText, buttonSize * 0.7, buttonSize * 0.7)
            else
                buttonPressed = ImGui.Button(buttonText, buttonSize, buttonSize)
            end
            
            if buttonPressed and enabled and action then
                action()
            end
            
            if ImGui.IsItemHovered() and tooltip then
                ImGui.SetTooltip(tooltip)
            end
            
            -- Pop style colors in reverse order
            if disabledPushed then
                ImGui.PopStyleColor(3)
            elseif colorPushed then
                ImGui.PopStyleColor(3)
            end
            
            -- Pop rounding style
            if roundingPushed then
                ImGui.PopStyleVar(1)
            end
            
            -- Add spacing between buttons
            if not hotbarConfig.vertical then
                ImGui.SameLine(0, spacing)
            end
            
            return buttonPressed
        end

        -- === CONFIGURABLE HOTBAR BUTTONS ===
        
        -- Helper function to resolve dynamic values (functions or static values)
        local function resolveValue(value, ...)
            if type(value) == "function" then
                return value(...)
            else
                return value
            end
        end



        -- Render configured buttons
        for buttonId, button in pairs(buttonConfig) do
            if button.visible or hotbarState.configMode then
                -- Get dynamic values
                local icon = resolveValue(button.icon, settings, lootUI)
                local text = resolveValue(button.text, settings, lootUI)
                local tooltip = resolveValue(button.tooltip, settings, lootUI)
                local color = resolveValue(button.color, settings, lootUI)
                
                -- Choose display text based on mode
                local displayText = hotbarConfig.useTextLabels and text or icon
                
                -- In config mode, show visibility toggle
                if hotbarState.configMode then
                    local visibilityChanged = false
                    button.visible, visibilityChanged = ImGui.Checkbox("##vis_" .. buttonId, button.visible)
                    
                    -- Save to config when checkbox changes
                    if visibilityChanged then
                        config.setHotbarButtonVisible(buttonId, button.visible)
                    end
                    
                    if not hotbarConfig.vertical then
                        ImGui.SameLine(0, 2)
                    end
                end
                
                -- Only show button if visible or in config mode
                if button.visible or hotbarState.configMode then
                    local buttonEnabled = button.visible
                    
                    addHotbarButton(
                        displayText,
                        tooltip,
                        function()
                            if button.action then
                                button.action(settings, toggle_ui, lootUI)
                            end
                        end,
                        color,
                        buttonEnabled
                    )
                end
            end
        end

        -- Right-click context menu for hotbar configuration
        if ImGui.BeginPopupContextWindow("HotbarContext") then
            ImGui.Text("SmartLoot Hotbar Options")
            ImGui.Separator()
            
            -- Display Mode Options
            if ImGui.MenuItem("Use Text Labels", nil, hotbarConfig.useTextLabels) then
                config.setHotbarUseTextLabels(not hotbarConfig.useTextLabels)
            end
            
            if ImGui.MenuItem("Configuration Mode", nil, hotbarState.configMode) then
                hotbarState.configMode = not hotbarState.configMode
            end
            
            ImGui.Separator()
            
            -- Layout Options
            if ImGui.MenuItem("Vertical Layout", nil, hotbarConfig.vertical) then
                config.setHotbarVertical(not hotbarConfig.vertical)
            end
            
            if ImGui.MenuItem("Show Labels", nil, hotbarConfig.showLabels) then
                config.setHotbarShowLabels(not hotbarConfig.showLabels)
            end
            
            if ImGui.MenuItem("Compact Mode", nil, hotbarConfig.compactMode) then
                config.setHotbarCompactMode(not hotbarConfig.compactMode)
            end
            
            ImGui.Separator()
            
            -- Button Visibility Submenu
            if ImGui.BeginMenu("Button Visibility") then
                for buttonId, button in pairs(buttonConfig) do
                    if ImGui.MenuItem(button.name, nil, button.visible) then
                        button.visible = not button.visible
                        config.setHotbarButtonVisible(buttonId, button.visible)
                    end
                end
                ImGui.EndMenu()
            end
            
            ImGui.Separator()
            
            -- Size options
            if ImGui.BeginMenu("Button Size") then
                if ImGui.MenuItem("Small", nil, hotbarConfig.buttonSize == 35) then
                    config.setHotbarButtonSize(35)
                end
                if ImGui.MenuItem("Medium", nil, hotbarConfig.buttonSize == 50) then
                    config.setHotbarButtonSize(50)
                end
                if ImGui.MenuItem("Large", nil, hotbarConfig.buttonSize == 65) then
                    config.setHotbarButtonSize(65)
                end
                ImGui.EndMenu()
            end
            
            -- Transparency options
            if ImGui.BeginMenu("Transparency") then
                if ImGui.MenuItem("Opaque", nil, hotbarConfig.alpha >= 0.95) then
                    config.setHotbarAlpha(1.0)
                end
                if ImGui.MenuItem("Semi-transparent", nil, math.abs(hotbarConfig.alpha - 0.7) < 0.1) then
                    config.setHotbarAlpha(0.7)
                end
                if ImGui.MenuItem("Very transparent", nil, math.abs(hotbarConfig.alpha - 0.4) < 0.1) then
                    config.setHotbarAlpha(0.4)
                end
                ImGui.EndMenu()
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Reset Position") then
                config.setHotbarPosition(100, 300)
            end
            
            if ImGui.MenuItem("Hide Hotbar") then
                config.setHotbarShow(false)
            end
            
            -- Status display
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Status:")
            ImGui.Text("Peers Connected: " .. #(util.getConnectedPeers()))
            ImGui.Text("SmartLoot: " .. (lootUI.paused and "Paused" or "Active"))
            
            ImGui.EndPopup()
        end
        
        -- Show labels if enabled (dynamic based on visible buttons)
        if hotbarConfig.showLabels and not hotbarConfig.compactMode then
            if not hotbarConfig.vertical then
                ImGui.NewLine()
            end
            
            -- Create labels for visible buttons
            local firstLabel = true
            for buttonId, button in pairs(buttonConfig) do
                if button.visible then
                    if hotbarConfig.vertical then
                        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + buttonSize + 5)
                        ImGui.SetCursorPosY(ImGui.GetCursorPosY() - buttonSize - 5)
                    end
                    
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1)
                    ImGui.Text(button.name)
                    ImGui.PopStyleColor()
                    
                    if not hotbarConfig.vertical and not firstLabel then
                        ImGui.SameLine(0, spacing)
                    end
                    firstLabel = false
                end
            end
        end
    end
    ImGui.End()
    
    if not open then
        config.setHotbarShow(false)
    end
end

-- Public functions to control the hotbar (now use config system)
function uiHotbar.show()
    config.setHotbarShow(true)
end

function uiHotbar.hide()
    config.setHotbarShow(false)
end

function uiHotbar.toggle()
    local hotbarConfig = getHotbarConfig()
    config.setHotbarShow(not hotbarConfig.show)
end

function uiHotbar.isVisible()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.show
end

function uiHotbar.setVertical(vertical)
    config.setHotbarVertical(vertical)
end

function uiHotbar.isVertical()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.vertical
end

function uiHotbar.setShowLabels(show)
    config.setHotbarShowLabels(show)
end

function uiHotbar.getShowLabels()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.showLabels
end

function uiHotbar.setCompactMode(compact)
    config.setHotbarCompactMode(compact)
end

function uiHotbar.isCompactMode()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.compactMode
end

function uiHotbar.setPosition(x, y)
    config.setHotbarPosition(x, y)
end

function uiHotbar.getPosition()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.position.x, hotbarConfig.position.y
end

function uiHotbar.setAlpha(alpha)
    config.setHotbarAlpha(alpha)
end

function uiHotbar.getAlpha()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.alpha
end

function uiHotbar.setButtonSize(size)
    config.setHotbarButtonSize(size)
end

function uiHotbar.getButtonSize()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.buttonSize
end

-- New functions for text label mode
function uiHotbar.setUseTextLabels(useText)
    config.setHotbarUseTextLabels(useText)
end

function uiHotbar.getUseTextLabels()
    local hotbarConfig = getHotbarConfig()
    return hotbarConfig.useTextLabels
end

function uiHotbar.toggleTextLabels()
    local hotbarConfig = getHotbarConfig()
    config.setHotbarUseTextLabels(not hotbarConfig.useTextLabels)
end

-- Configuration mode functions (not saved to config)
function uiHotbar.setConfigMode(configMode)
    hotbarState.configMode = configMode
end

function uiHotbar.getConfigMode()
    return hotbarState.configMode
end

function uiHotbar.toggleConfigMode()
    hotbarState.configMode = not hotbarState.configMode
end

-- Button visibility functions
function uiHotbar.setButtonVisible(buttonId, visible)
    if buttonConfig[buttonId] then
        buttonConfig[buttonId].visible = visible
        config.setHotbarButtonVisible(buttonId, visible)
    end
end

function uiHotbar.getButtonVisible(buttonId)
    return config.getHotbarButtonVisible(buttonId)
end

function uiHotbar.toggleButtonVisible(buttonId)
    local currentVisible = config.getHotbarButtonVisible(buttonId)
    uiHotbar.setButtonVisible(buttonId, not currentVisible)
end

function uiHotbar.getButtonConfig()
    return buttonConfig
end

function uiHotbar.resetButtonsToDefault()
    config.resetHotbarToDefaults()
    initializeButtonVisibility()
end

-- Legacy save/load functions (now use config system)
function uiHotbar.saveSettings()
    -- Settings are automatically saved through config system
    local hotbarConfig = getHotbarConfig()
    logging.log("Hotbar settings saved via config system: " ..
        "pos(" .. hotbarConfig.position.x .. "," .. hotbarConfig.position.y .. ") " ..
        "size(" .. hotbarConfig.buttonSize .. ") " ..
        "alpha(" .. hotbarConfig.alpha .. ") " ..
        "vertical(" .. tostring(hotbarConfig.vertical) .. ") " ..
        "useTextLabels(" .. tostring(hotbarConfig.useTextLabels) .. ") " ..
        "show(" .. tostring(hotbarConfig.show) .. ")")
    
    return hotbarConfig
end

function uiHotbar.loadSettings(settings)
    -- Settings are automatically loaded through config system
    if settings then
        logging.log("Legacy loadSettings called - settings now managed by config system")
    end
    initializeButtonVisibility()
end

return uiHotbar
