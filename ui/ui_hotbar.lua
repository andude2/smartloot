-- ui/ui_hotbar.lua (Enhanced version with floating button integration)
local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local logging = require("modules.logging")

local uiHotbar = {}

-- Hotbar state management
local hotbarState = {
    show = true,
    position = { x = 100, y = 300 },
    vertical = false,
    alpha = 0.8,
    buttonSize = 50,
    spacing = 5,
    isDragging = false,
    dragOffset = { x = 0, y = 0 },
    showLabels = false,
    compactMode = false,
}

function uiHotbar.draw(lootUI, settings, toggle_ui, loot, util)
    if not hotbarState.show then return end

    -- Don't show hotbar if floating button is being used
    if lootUI.useFloatingButton then return end

    local windowFlags = ImGuiWindowFlags.NoTitleBar +
                       ImGuiWindowFlags.NoScrollbar +
                       ImGuiWindowFlags.NoBackground +
                       ImGuiWindowFlags.AlwaysAutoResize +
                       ImGuiWindowFlags.NoFocusOnAppearing

    -- Set transparency
    ImGui.SetNextWindowBgAlpha(hotbarState.alpha)
    
    -- Set position
    ImGui.SetNextWindowPos(hotbarState.position.x, hotbarState.position.y, ImGuiCond.Always)

    local open = true
    if ImGui.Begin("SmartLoot Hotbar", open, windowFlags) then
        -- Handle dragging
        local windowPos = ImGui.GetWindowPos()
        local mousePos = ImGui.GetMousePos()
        
        if ImGui.IsWindowHovered() and ImGui.IsMouseDragging(ImGuiMouseButton.Left) then
            if not hotbarState.isDragging then
                hotbarState.isDragging = true
                hotbarState.dragOffset = mousePos - windowPos
            end
        end

        if hotbarState.isDragging then
            if ImGui.IsMouseDragging(ImGuiMouseButton.Left) then
                hotbarState.position.x = mousePos - hotbarState.dragOffset.x
                hotbarState.position.y = mousePos - hotbarState.dragOffset.y
            else
                hotbarState.isDragging = false
            end
        end

        if not hotbarState.isDragging then
            hotbarState.position.x = windowPos
            hotbarState.position.y = windowPos
        end

        local buttonSize = hotbarState.buttonSize
        local spacing = hotbarState.spacing

        -- Helper function to add button with optional label
        local function addHotbarButton(icon, tooltip, action, color, enabled)
            enabled = enabled ~= false -- default to true
            
            if color then
                ImGui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4] or 0.7)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] + 0.1, color[2] + 0.1, color[3] + 0.1, 0.9)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, color[1] - 0.1, color[2] - 0.1, color[3] - 0.1, 1.0)
            end
            
            if not enabled then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
            end
            
            local buttonText = icon or "?"
            local buttonPressed = false
            
            if hotbarState.compactMode then
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
            
            if color then
                ImGui.PopStyleColor(3)
            end
            
            if not enabled then
                ImGui.PopStyleColor(3)
            end
            
            -- Add spacing between buttons
            if not hotbarState.vertical then
                ImGui.SameLine(0, spacing)
            end
            
            return buttonPressed
        end

        -- === HOTBAR BUTTONS ===
        
        -- Start BG Loot Button
        addHotbarButton(
            uiUtils.UI_ICONS.UP_ARROW or "▶",
            "Start Background Loot on All Peers",
            function()
                mq.cmd('/dgae /lua run smartloot background')
                logging.log("Started background loot on all peers")
            end,
            {0, 0.8, 0} -- Green
        )

        -- Stop BG Loot Button
        addHotbarButton(
            uiUtils.UI_ICONS.REMOVE or "■",
            "Stop Background Loot on All Peers",
            function()
                mq.cmd('/sl_stop_background all')
                logging.log("Stopped background loot on all peers")
            end,
            {0.8, 0.2, 0} -- Red
        )

        -- Clear Cache Button
        addHotbarButton(
            uiUtils.UI_ICONS.REFRESH or "↻",
            "Clear Loot Cache",
            function()
                mq.cmd('/sl_clearcache')
            end,
            {0.2, 0.6, 0.8} -- Blue
        )

        -- Loot All Button
        addHotbarButton(
            uiUtils.UI_ICONS.LIGHTNING or "⚡",
            "Broadcast Loot Command to All Peers",
            function()
                mq.cmd('/say #corpsefix')
                mq.cmd('/sl_doloot_all')
            end,
            {0.8, 0.8, 0.2} -- Yellow
        )

        -- Auto Loot Known Button
        addHotbarButton(
            uiUtils.UI_ICONS.GEAR or "⚙",
            "Broadcast Auto Loot Known Items Command to All Peers",
            function()
                mq.cmd('/e3bcz /slautolootknown')
                logging.log("Broadcast auto loot known command")
            end,
            {0.6, 0.4, 0.8} -- Purple
        )

        -- Pause Peer Trigger Button
        local pauseIcon = settings.peerTriggerPaused and (uiUtils.UI_ICONS.PLAY or "▶") or (uiUtils.UI_ICONS.PAUSE or "⏸")
        local pauseColor = settings.peerTriggerPaused and {0, 1, 0} or {1, 0.7, 0}
        addHotbarButton(
            pauseIcon,
            settings.peerTriggerPaused and "Resume Peer Triggering" or "Pause Peer Triggering",
            function()
                settings.peerTriggerPaused = not settings.peerTriggerPaused
                logging.log(settings.peerTriggerPaused and "Peer triggering paused" or "Peer triggering resumed")
            end,
            pauseColor
        )

        -- Toggle UI Button
        addHotbarButton(
            uiUtils.UI_ICONS.INFO or "ℹ",
            "Toggle SmartLoot Main UI",
            function()
                toggle_ui()
            end,
            {0.4, 0.7, 0.9} -- Light blue
        )

        -- Add New Rule Button (NEW)
        addHotbarButton(
            uiUtils.UI_ICONS.ADD or "+",
            "Add New Loot Rule",
            function()
                lootUI.addNewRulePopup = lootUI.addNewRulePopup or {}
                lootUI.addNewRulePopup.isOpen = true
                lootUI.addNewRulePopup.itemName = ""
                lootUI.addNewRulePopup.rule = "Keep"
                lootUI.addNewRulePopup.threshold = 1
                lootUI.addNewRulePopup.selectedCharacter = mq.TLO.Me.Name() or "Local"
            end,
            {0.2, 0.8, 0.4} -- Green
        )

        -- Peer Commands Toggle Button (NEW)
        local showingPeerCommands = lootUI.showPeerCommands or false
        addHotbarButton(
            "PC",
            showingPeerCommands and "Hide Peer Commands" or "Show Peer Commands",
            function()
                lootUI.showPeerCommands = not showingPeerCommands
            end,
            showingPeerCommands and {0.8, 0.4, 0.2} or {0.4, 0.6, 0.8}
        )

        -- Settings Button (NEW)
        addHotbarButton(
            uiUtils.UI_ICONS.SETTINGS or "⚙",
            "Open SmartLoot Settings",
            function()
                toggle_ui()
                lootUI.showSettingsTab = true
            end,
            {0.7, 0.7, 0.7} -- Gray
        )

        -- Right-click context menu for hotbar configuration
        if ImGui.BeginPopupContextWindow("HotbarContext") then
            ImGui.Text("SmartLoot Hotbar Options")
            ImGui.Separator()
            
            if ImGui.MenuItem("Vertical Layout", nil, hotbarState.vertical) then
                hotbarState.vertical = not hotbarState.vertical
            end
            
            if ImGui.MenuItem("Show Labels", nil, hotbarState.showLabels) then
                hotbarState.showLabels = not hotbarState.showLabels
            end
            
            if ImGui.MenuItem("Compact Mode", nil, hotbarState.compactMode) then
                hotbarState.compactMode = not hotbarState.compactMode
            end
            
            ImGui.Separator()
            
            -- Size options
            if ImGui.BeginMenu("Button Size") then
                if ImGui.MenuItem("Small", nil, hotbarState.buttonSize == 35) then
                    hotbarState.buttonSize = 35
                end
                if ImGui.MenuItem("Medium", nil, hotbarState.buttonSize == 50) then
                    hotbarState.buttonSize = 50
                end
                if ImGui.MenuItem("Large", nil, hotbarState.buttonSize == 65) then
                    hotbarState.buttonSize = 65
                end
                ImGui.EndMenu()
            end
            
            -- Transparency options
            if ImGui.BeginMenu("Transparency") then
                if ImGui.MenuItem("Opaque", nil, hotbarState.alpha >= 0.95) then
                    hotbarState.alpha = 1.0
                end
                if ImGui.MenuItem("Semi-transparent", nil, math.abs(hotbarState.alpha - 0.7) < 0.1) then
                    hotbarState.alpha = 0.7
                end
                if ImGui.MenuItem("Very transparent", nil, math.abs(hotbarState.alpha - 0.4) < 0.1) then
                    hotbarState.alpha = 0.4
                end
                ImGui.EndMenu()
            end
            
            ImGui.Separator()
            
            if ImGui.MenuItem("Reset Position") then
                hotbarState.position.x = 100
                hotbarState.position.y = 300
            end
            
            if ImGui.MenuItem("Hide Hotbar") then
                hotbarState.show = false
            end
            
            if ImGui.MenuItem("Switch to Floating Button") then
                hotbarState.show = false
                lootUI.useFloatingButton = true
            end
            
            ImGui.Separator()
            
            -- Status display
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Status:")
            ImGui.Text("Peers Connected: " .. #(util.getConnectedPeers()))
            ImGui.Text("SmartLoot: " .. (lootUI.paused and "Paused" or "Active"))
            
            ImGui.EndPopup()
        end
        
        -- Show labels if enabled
        if hotbarState.showLabels and not hotbarState.compactMode then
            if not hotbarState.vertical then
                ImGui.NewLine()
            end
            
            -- Create a second row/column with labels
            local labels = {
                "Start BG", "Stop BG", "Clear", "Loot All", 
                "Auto Known", "Pause", "UI", "New Rule", "Peers", "Settings"
            }
            
            for i, label in ipairs(labels) do
                if hotbarState.vertical then
                    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + buttonSize + 5)
                    ImGui.SetCursorPosY(ImGui.GetCursorPosY() - buttonSize - 5)
                end
                
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1)
                ImGui.Text(label)
                ImGui.PopStyleColor()
                
                if not hotbarState.vertical then
                    ImGui.SameLine(0, spacing)
                end
            end
        end
    end
    ImGui.End()
    
    if not open then
        hotbarState.show = false
    end
end

-- Public functions to control the hotbar
function uiHotbar.show()
    hotbarState.show = true
end

function uiHotbar.hide()
    hotbarState.show = false
end

function uiHotbar.toggle()
    hotbarState.show = not hotbarState.show
end

function uiHotbar.isVisible()
    return hotbarState.show
end

function uiHotbar.setVertical(vertical)
    hotbarState.vertical = vertical
end

function uiHotbar.isVertical()
    return hotbarState.vertical
end

function uiHotbar.setShowLabels(show)
    hotbarState.showLabels = show
end

function uiHotbar.getShowLabels()
    return hotbarState.showLabels
end

function uiHotbar.setCompactMode(compact)
    hotbarState.compactMode = compact
end

function uiHotbar.isCompactMode()
    return hotbarState.compactMode
end

function uiHotbar.setPosition(x, y)
    hotbarState.position.x = x
    hotbarState.position.y = y
end

function uiHotbar.getPosition()
    return hotbarState.position.x, hotbarState.position.y
end

function uiHotbar.setAlpha(alpha)
    hotbarState.alpha = math.max(0.1, math.min(1.0, alpha))
end

function uiHotbar.getAlpha()
    return hotbarState.alpha
end

function uiHotbar.setButtonSize(size)
    hotbarState.buttonSize = math.max(25, math.min(80, size))
end

function uiHotbar.getButtonSize()
    return hotbarState.buttonSize
end

-- Save/load settings functions
function uiHotbar.saveSettings()
    logging.log("Hotbar settings should be saved: " ..
        "pos(" .. hotbarState.position.x .. "," .. hotbarState.position.y .. ") " ..
        "size(" .. hotbarState.buttonSize .. ") " ..
        "alpha(" .. hotbarState.alpha .. ") " ..
        "vertical(" .. tostring(hotbarState.vertical) .. ") " ..
        "show(" .. tostring(hotbarState.show) .. ")")
end

function uiHotbar.loadSettings(settings)
    if settings then
        hotbarState.position.x = settings.x or hotbarState.position.x
        hotbarState.position.y = settings.y or hotbarState.position.y
        hotbarState.buttonSize = settings.size or hotbarState.buttonSize
        hotbarState.alpha = settings.alpha or hotbarState.alpha
        hotbarState.vertical = settings.vertical or hotbarState.vertical
        hotbarState.showLabels = settings.showLabels or hotbarState.showLabels
        hotbarState.compactMode = settings.compactMode or hotbarState.compactMode
        hotbarState.show = settings.show ~= false
    end
end

return uiHotbar