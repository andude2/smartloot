local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local database = require("modules.database")
local config = require("modules.config")
local SmartLootEngine = require("modules.SmartLootEngine")

local uiSettings = {}

local function draw_chat_settings(config)
    -- Chat Output Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.9, 1.0, 1.0) -- Light cyan header
    if ImGui.CollapsingHeader("Chat Output Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button that opens popup
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##ChatHelp") then
            ImGui.OpenPopup("ChatSettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for chat mode descriptions and testing options")
        end

        -- Chat Output Mode Selection
        ImGui.Text("Chat Output Mode:")
        ImGui.SameLine()
        ImGui.PushItemWidth(120)

        local chatModes = { "rsay", "group", "guild", "custom", "silent" }
        local chatModeNames = {
            ["rsay"] = "Raid Say",
            ["group"] = "Group",
            ["guild"] = "Guild",
            ["custom"] = "Custom",
            ["silent"] = "Silent"
        }

        -- Get current mode directly from config - ensure it's valid
        local currentMode = config.chatOutputMode or "group"

        -- Validate that currentMode is in our list
        local isValidMode = false
        for _, mode in ipairs(chatModes) do
            if mode == currentMode then
                isValidMode = true
                break
            end
        end

        -- If invalid mode, default to group
        if not isValidMode then
            currentMode = "group"
            config.chatOutputMode = currentMode
            if config.save then
                config.save()
            end
        end

        local currentIndex = 0

        -- Find current mode index
        for i, mode in ipairs(chatModes) do
            if mode == currentMode then
                currentIndex = i - 1
                break
            end
        end

        -- Display current mode name
        local displayName = chatModeNames[currentMode] or currentMode

        if ImGui.BeginCombo("##ChatMode", displayName) then
            for i, mode in ipairs(chatModes) do
                local isSelected = (currentIndex == i - 1)
                local modeDisplayName = chatModeNames[mode] or mode

                if ImGui.Selectable(modeDisplayName, isSelected) then
                    -- Immediately update the config when selected
                    config.chatOutputMode = mode

                    -- Try the new setChatMode function first
                    if config.setChatMode then
                        local success, errorMsg = config.setChatMode(mode)
                        if success then
                            logging.log("Chat output mode changed to: " ..
                                (config.getChatModeDescription and config.getChatModeDescription() or mode))
                        else
                            logging.log("Failed to set chat mode: " .. tostring(errorMsg))
                            -- Fallback: set directly and save
                            config.chatOutputMode = mode
                            if config.save then
                                config.save()
                            end
                        end
                    else
                        -- Fallback: directly set the mode and save
                        if config.save then
                            config.save()
                        end
                        logging.log("Chat output mode changed to: " .. mode)
                    end

                    -- Update currentMode for immediate UI feedback
                    currentMode = mode
                    currentIndex = i - 1
                end

                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()

        -- Show current chat command
        ImGui.SameLine()
        local chatCommand = ""
        if config.getChatCommand then
            chatCommand = config.getChatCommand() or ""
        else
            -- Fallback display based on mode
            if currentMode == "rsay" then
                chatCommand = "/rsay"
            elseif currentMode == "group" then
                chatCommand = "/g"
            elseif currentMode == "guild" then
                chatCommand = "/gu"
            elseif currentMode == "custom" then
                chatCommand = config.customChatCommand or "/say"
            elseif currentMode == "silent" then
                chatCommand = "No Output"
            end
        end

        if chatCommand and chatCommand ~= "" then
            if currentMode == "silent" then
                ImGui.Text("(No Output)")
            else
                ImGui.Text("(" .. chatCommand .. ")")
            end
        else
            ImGui.Text("(No Output)")
        end

        -- Custom chat command input (only show if custom mode is selected)
        if currentMode == "custom" then
            ImGui.Text("Custom Command:")
            ImGui.SameLine()
            ImGui.PushItemWidth(150)

            local customCommand = config.customChatCommand or "/say"
            local newCustomCommand, changed = ImGui.InputText("##CustomChatCommand", customCommand, 128)

            if changed then
                if config.setCustomChatCommand then
                    local success, errorMsg = config.setCustomChatCommand(newCustomCommand)
                    if success then
                        logging.log("Custom chat command set to: " .. newCustomCommand)
                    else
                        logging.log("Failed to set custom chat command: " .. tostring(errorMsg))
                    end
                else
                    -- Fallback: directly set the command
                    config.customChatCommand = newCustomCommand
                    if config.save then
                        config.save()
                    end
                    logging.log("Custom chat command set to: " .. newCustomCommand)
                end
            end

            ImGui.PopItemWidth()

            -- Help text for custom commands
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Enter any chat command (e.g., /say, /tell playername, /ooc, etc.)")
            end
        end

        -- Chat mode description
        local modeDescription = ""
        if config.getChatModeDescription then
            modeDescription = config.getChatModeDescription()
        else
            modeDescription = chatModeNames[currentMode] or currentMode
        end

        ImGui.Text("Current Mode: " .. modeDescription)

        -- Help Popup
        if ImGui.BeginPopup("ChatSettingsHelp") then
            ImGui.Text("Chat Mode Help & Testing")
            ImGui.Separator()

            -- Chat mode descriptions
            ImGui.Text("Chat Mode Descriptions:")
            ImGui.BulletText("Raid Say: Sends messages to raid chat (/rsay)")
            ImGui.BulletText("Group: Sends messages to group chat (/g)")
            ImGui.BulletText("Guild: Sends messages to guild chat (/gu)")
            ImGui.BulletText("Custom: Use your own chat command")
            ImGui.BulletText("Silent: No chat output (logs only)")

            ImGui.Separator()

            -- Test button
            if ImGui.Button("Test Chat Output") then
                local testMessage = "SmartLoot chat test from " .. (mq.TLO.Me.Name() or "Unknown")
                if config.sendChatMessage then
                    config.sendChatMessage(testMessage)
                    logging.log("Sent test message via " .. modeDescription)
                else
                    -- Fallback test
                    if currentMode == "rsay" then
                        mq.cmd("/rsay " .. testMessage)
                    elseif currentMode == "group" then
                        mq.cmd("/g " .. testMessage)
                    elseif currentMode == "guild" then
                        mq.cmd("/gu " .. testMessage)
                    elseif currentMode == "custom" then
                        mq.cmd((config.customChatCommand or "/say") .. " " .. testMessage)
                    elseif currentMode == "silent" then
                        logging.log("Silent mode - no chat output")
                    end

                    if currentMode ~= "silent" then
                        logging.log("Sent test message via " .. modeDescription)
                    end
                end
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Send a test message using the current chat output mode")
            end

            ImGui.SameLine()

            -- Debug button
            if ImGui.Button("Debug Chat Config") then
                if config.debugChatConfig then
                    config.debugChatConfig()
                else
                    logging.log("Chat Debug - Mode: " .. tostring(config.chatOutputMode))
                    logging.log("Chat Debug - Custom Command: " .. tostring(config.customChatCommand))
                end
            end

            ImGui.Separator()
            if ImGui.Button("Close") then
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor() -- Pop the color even if header is closed
    end
end

local function draw_timing_settings()
    -- Timing Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.9, 0.4, 1.0) -- Light yellow header
    if ImGui.CollapsingHeader("Timing Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##TimingHelp") then
            ImGui.OpenPopup("TimingSettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for timing setting descriptions and recommendations")
        end

        ImGui.Spacing()

        -- Get current persistent config and sync to engine
        local persistentConfig = config.getEngineTiming()
        config.syncTimingToEngine() -- Ensure engine is synced with persistent config

        -- Helper function for compact timing input
        local function drawTimingInput(label, value, setValue, minVal, maxVal, unit, tooltip, step1, step2)
            step1 = step1 or 1
            step2 = step2 or 10

            ImGui.AlignTextToFramePadding()
            ImGui.Text(label)
            ImGui.SameLine(125) -- Fixed alignment position
            ImGui.PushItemWidth(100)
            local newValue, changed = ImGui.InputInt("##" .. label:gsub(" ", ""), value, step1, step2)
            if changed and newValue >= minVal and newValue <= maxVal then
                setValue(newValue)
                config.syncTimingToEngine()
                logging.log(string.format("%s set to %d %s", label, newValue, unit))
            end
            ImGui.PopItemWidth()
            ImGui.SameLine()
            ImGui.Text(unit)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(tooltip)
            end
        end

        -- Compact timing settings in organized sections
        -- Helper function for compact timing input on same line
        local function drawTimingInputCompact(label, value, setValue, minVal, maxVal, unit, tooltip, step1, step2)
            step1 = step1 or 1
            step2 = step2 or 10

            ImGui.AlignTextToFramePadding()
            ImGui.Text(label)
            ImGui.SameLine(400) -- Shorter alignment for compact layout
            ImGui.PushItemWidth(100)
            local newValue, changed = ImGui.InputInt("##" .. label:gsub(" ", ""):gsub("/", ""), value, step1, step2)
            if changed and newValue >= minVal and newValue <= maxVal then
                setValue(newValue)
                config.syncTimingToEngine()
                logging.log(string.format("%s set to %d %s", label, newValue, unit))
            end
            ImGui.PopItemWidth()
            ImGui.SameLine()
            ImGui.Text(unit)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(tooltip)
            end
        end

        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow section headers
        ImGui.Text("Corpse Processing")
        ImGui.PopStyleColor()
        ImGui.Separator()

        -- Row 1: Open to Loot Start and Between Items
        drawTimingInput("Open to Loot", persistentConfig.itemPopulationDelayMs,
            config.setItemPopulationDelay, 10, 5000, "ms",
            "Time after opening corpse before starting to loot\nRecommended: 100-300ms")

        ImGui.SameLine(280) -- Position for second column
        drawTimingInputCompact("Between Items", persistentConfig.itemProcessingDelayMs,
            config.setItemProcessingDelay, 5, 2000, "ms",
            "Delay between processing each item slot\nRecommended: 25-100ms")

        -- Row 2: After Loot Action and Empty/Ignored Slots
        drawTimingInput("After Loot", persistentConfig.lootActionDelayMs,
            config.setLootActionDelay, 25, 3000, "ms",
            "Wait time after looting/destroying an item\nRecommended: 100-300ms")

        ImGui.SameLine(280) -- Position for second column
        drawTimingInputCompact("Ignored Slots", persistentConfig.ignoredItemDelayMs,
            config.setIgnoredItemDelay, 1, 500, "ms",
            "Fast processing for empty or ignored slots\nRecommended: 10-50ms", 1, 5)

        ImGui.Spacing()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.9, 0.9, 1.0) -- Light cyan section headers
        ImGui.Text("Navigation")
        ImGui.PopStyleColor()
        ImGui.Separator()

        drawTimingInput("Retry Delay", persistentConfig.navRetryDelayMs,
            config.setNavRetryDelay, 50, 5000, "ms",
            "Time between navigation attempts\nRecommended: 250-750ms", 10, 50)

        drawTimingInput("Timeout", persistentConfig.maxNavTimeMs / 1000,
            function(val) config.setMaxNavTime(val * 1000) end, 5, 300, "sec",
            "Maximum time to spend reaching a corpse\nRecommended: 15-45 seconds", 1, 5)

        ImGui.Spacing()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.7, 0.7, 1.0) -- Light red section headers
        ImGui.Text("Combat Detection")
        ImGui.PopStyleColor()
        ImGui.Separator()

        drawTimingInput("Wait Time", persistentConfig.combatWaitDelayMs,
            config.setCombatWaitDelay, 250, 10000, "ms",
            "Delay between combat detection checks\nRecommended: 1000-3000ms", 50, 100)

        ImGui.Spacing()

        -- Preset Buttons
        ImGui.Text("Timing Presets:")
        ImGui.SameLine()

        if ImGui.Button("Fast##TimingPreset") then
            config.applyTimingPreset("fast")
            config.syncTimingToEngine()
            logging.log("Applied Fast timing preset")
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Optimized for speed - may be less stable on slower connections")
        end

        ImGui.SameLine()
        if ImGui.Button("Balanced##TimingPreset") then
            config.applyTimingPreset("balanced")
            config.syncTimingToEngine()
            logging.log("Applied Balanced timing preset (default)")
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Default balanced settings - good for most situations")
        end

        ImGui.SameLine()
        if ImGui.Button("Conservative##TimingPreset") then
            config.applyTimingPreset("conservative")
            config.syncTimingToEngine()
            logging.log("Applied Conservative timing preset")
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Slower but more stable - recommended for high latency or unstable connections")
        end

        -- Help Popup
        if ImGui.BeginPopup("TimingSettingsHelp") then
            ImGui.Text("SmartLoot Timing Settings Help")
            ImGui.Separator()
            ImGui.BulletText("Corpse Open to Loot Start: Wait time after opening corpse")
            ImGui.BulletText("Between Item Processing: Delay between checking each item slot")
            ImGui.BulletText("After Loot Action: Wait time after looting/destroying items")
            ImGui.BulletText("Empty/Ignored Slots: Fast processing for empty slots")
            ImGui.BulletText("Navigation Retry: Time between navigation attempts")
            ImGui.BulletText("Navigation Timeout: Max time to reach a corpse")
            ImGui.BulletText("Combat Wait Time: Delay between combat checks")
            ImGui.Separator()
            ImGui.Text("Recommendations:")
            ImGui.BulletText("Fast: Good ping, stable connection")
            ImGui.BulletText("Balanced: Most users (default)")
            ImGui.BulletText("Conservative: High latency, unstable connection")
            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_speed_settings()
    -- Speed Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.9, 0.4, 1.0) -- Light green header
    if ImGui.CollapsingHeader("Processing Speed") then
        ImGui.PopStyleColor()
        ImGui.SameLine()
        -- Help button
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##SpeedHelp") then
            ImGui.OpenPopup("SpeedSettingsHelp")
        end
        ImGui.PopStyleColor(2)
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for speed setting descriptions")
        end

        -- Get current speed settings
        local speedMultiplier = config.getSpeedMultiplier()
        local speedPercentage = config.getSpeedPercentage()

        -- Display current speed as percentage
        local speedText = "Normal"
        local speedColor = { 0.9, 0.9, 0.9, 1.0 } -- White for normal
        if speedPercentage < 0 then
            speedText = string.format("%d%% Faster", -speedPercentage)
            speedColor = { 0.4, 0.9, 0.4, 1.0 } -- Green for faster
        elseif speedPercentage > 0 then
            speedText = string.format("%d%% Slower", speedPercentage)
            speedColor = { 0.9, 0.4, 0.4, 1.0 } -- Red for slower
        end

        ImGui.Text("Current Speed: ")
        ImGui.SameLine()
        ImGui.TextColored(speedColor[1], speedColor[2], speedColor[3], speedColor[4], speedText)

        -- Slider for speed adjustment
        ImGui.Text("Speed Adjustment:")
        ImGui.PushItemWidth(300)
        local newPercentage = ImGui.SliderInt("##SpeedSlider", speedPercentage, -75, 200, "%d%%")
        if newPercentage ~= speedPercentage then
            config.setSpeedPercentage(newPercentage)
            logging.log(string.format("Speed adjusted to %d%% (%s)",
                newPercentage,
                newPercentage < 0 and "faster" or (newPercentage > 0 and "slower" or "normal")))
        end
        ImGui.PopItemWidth()

        -- Preset buttons
        ImGui.Text("Speed Presets:")
        if ImGui.Button("Very Fast (50% faster)") then
            config.applySpeedPreset("very_fast")
            logging.log("Applied Very Fast speed preset (50% faster)")
        end
        ImGui.SameLine()
        if ImGui.Button("Fast (25% faster)") then
            config.applySpeedPreset("fast")
            logging.log("Applied Fast speed preset (25% faster)")
        end
        ImGui.SameLine()
        if ImGui.Button("Normal") then
            config.applySpeedPreset("normal")
            logging.log("Applied Normal speed preset")
        end
        ImGui.SameLine()
        if ImGui.Button("Slow (50% slower)") then
            config.applySpeedPreset("slow")
            logging.log("Applied Slow speed preset (50% slower)")
        end
        ImGui.SameLine()
        if ImGui.Button("Very Slow (100% slower)") then
            config.applySpeedPreset("very_slow")
            logging.log("Applied Very Slow speed preset (100% slower)")
        end

        -- Help Popup
        if ImGui.BeginPopup("SpeedSettingsHelp") then
            ImGui.Text("SmartLoot Speed Settings Help")
            ImGui.Separator()
            ImGui.BulletText("Speed affects all timing operations in SmartLoot")
            ImGui.BulletText("Negative percentages = faster processing")
            ImGui.BulletText("Positive percentages = slower processing")
            ImGui.BulletText("0% = normal speed (default)")
            ImGui.Separator()
            ImGui.Text("Recommendations:")
            ImGui.BulletText("Fast computers, good connection: Try 25-50% faster")
            ImGui.BulletText("Slower computers, high latency: Try 25-50% slower")
            ImGui.BulletText("If experiencing errors: Increase speed percentage")
            ImGui.EndPopup()
        end

        -- Show current timing values
        if ImGui.CollapsingHeader("Current Timing Values", ImGuiTreeNodeFlags.None) then
            ImGui.BeginTable("TimingValuesTable", 2, ImGuiTableFlags.Borders)
            ImGui.TableSetupColumn("Setting")
            ImGui.TableSetupColumn("Value (ms)")
            ImGui.TableHeadersRow()

            local function showTimingRow(name, value)
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.Text(name)
                ImGui.TableSetColumnIndex(1)
                ImGui.Text(tostring(value) .. " ms")
            end

            showTimingRow("Item Population Delay", config.engineTiming.itemPopulationDelayMs)
            showTimingRow("Item Processing Delay", config.engineTiming.itemProcessingDelayMs)
            showTimingRow("Loot Action Delay", config.engineTiming.lootActionDelayMs)
            showTimingRow("Ignored Item Delay", config.engineTiming.ignoredItemDelayMs)
            showTimingRow("Navigation Retry Delay", config.engineTiming.navRetryDelayMs)
            showTimingRow("Combat Wait Delay", config.engineTiming.combatWaitDelayMs)
            showTimingRow("Max Navigation Time", config.engineTiming.maxNavTimeMs)
            ImGui.EndTable()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_item_announce_settings(config)
    -- Item Announce Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.6, 0.9, 1.0) -- Light purple header
    if ImGui.CollapsingHeader("Item Announce Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##ItemAnnounceHelp") then
            ImGui.OpenPopup("ItemAnnounceSettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for item announce mode descriptions")
        end

        -- Item Announce Mode Selection
        ImGui.Text("Item Announce Mode:")
        ImGui.SameLine()
        ImGui.PushItemWidth(150)

        local announceModes = { "all", "ignored", "none" }
        local announceModeNames = {
            ["all"] = "All Items",
            ["ignored"] = "Ignored Items Only",
            ["none"] = "No Announcements"
        }

        -- Get current mode directly from config
        local currentMode = config.getItemAnnounceMode and config.getItemAnnounceMode() or "all"

        -- Display current mode name
        local displayName = announceModeNames[currentMode] or currentMode

        if ImGui.BeginCombo("##ItemAnnounceMode", displayName) then
            for i, mode in ipairs(announceModes) do
                local isSelected = (currentMode == mode)
                local modeDisplayName = announceModeNames[mode] or mode

                if ImGui.Selectable(modeDisplayName .. "##ItemAnnounce" .. i, isSelected) then
                    -- Only change if it's actually different
                    if currentMode ~= mode then
                        if config.setItemAnnounceMode then
                            local success, errorMsg = config.setItemAnnounceMode(mode)
                            if success then
                                logging.log("Item announce mode changed to: " ..
                                    (config.getItemAnnounceModeDescription and config.getItemAnnounceModeDescription() or mode))
                            else
                                logging.log("Failed to set item announce mode: " .. tostring(errorMsg))
                            end
                        else
                            -- Fallback: directly set the mode
                            config.itemAnnounceMode = mode
                            if config.save then
                                config.save()
                            end
                            logging.log("Item announce mode changed to: " .. mode)
                        end
                    end
                end

                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()

        -- Show current mode description
        local modeDescription = ""
        if config.getItemAnnounceModeDescription then
            modeDescription = config.getItemAnnounceModeDescription()
        else
            modeDescription = announceModeNames[currentMode] or currentMode
        end

        ImGui.Text("Current Mode: " .. modeDescription)

        -- Show examples based on current mode
        ImGui.Spacing()
        ImGui.Text("Examples:")
        if currentMode == "all" then
            ImGui.BulletText("Announces: 'Looted: Ancient Dragon Scale'")
            ImGui.BulletText("Announces: 'Ignored: Rusty Sword'")
            ImGui.BulletText("Announces: 'Destroyed: Tattered Cloth'")
        elseif currentMode == "ignored" then
            ImGui.BulletText("Announces: 'Ignored: Rusty Sword'")
            ImGui.BulletText("Silent: Looted items")
            ImGui.BulletText("Silent: Destroyed items")
        elseif currentMode == "none" then
            ImGui.BulletText("Silent: All item actions")
            ImGui.BulletText("Only logs to console/file")
        end

        -- Help Popup
        if ImGui.BeginPopup("ItemAnnounceSettingsHelp") then
            ImGui.Text("Item Announce Settings Help")
            ImGui.Separator()

            ImGui.Text("Announce Mode Descriptions:")
            ImGui.BulletText("All Items: Announces every loot action (keep, ignore, destroy)")
            ImGui.BulletText("Ignored Items Only: Only announces items that are ignored")
            ImGui.BulletText("No Announcements: Silent mode - no chat announcements")

            ImGui.Separator()
            ImGui.Text("Notes:")
            ImGui.BulletText("Uses the configured chat output mode (group, raid, etc.)")
            ImGui.BulletText("All actions are still logged to console regardless of setting")
            ImGui.BulletText("Useful for reducing chat spam in busy looting sessions")

            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_lore_check_settings(config)
    -- Lore Item Check Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow header
    if ImGui.CollapsingHeader("Lore Item Check Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##LoreCheckHelp") then
            ImGui.OpenPopup("LoreCheckSettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for Lore item check descriptions")
        end

        -- Lore Check Announcements
        ImGui.Text("Lore Item Checking is always enabled to prevent getting stuck on corpses.")
        ImGui.Spacing()
        
        local loreCheckAnnounce = config.loreCheckAnnounce
        if loreCheckAnnounce == nil then loreCheckAnnounce = true end
        local newLoreCheckAnnounce, changedLoreCheckAnnounce = ImGui.Checkbox("Announce Lore Conflicts", loreCheckAnnounce)
        if changedLoreCheckAnnounce then
            config.loreCheckAnnounce = newLoreCheckAnnounce
            if config.save then
                config.save()
            end
            logging.log("Lore conflict announcements " .. (newLoreCheckAnnounce and "enabled" or "disabled"))
        end

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("When enabled, announces when Lore items are skipped due to conflicts")
        end

        -- Status display
        ImGui.Spacing()
        ImGui.Text("Status:")
        ImGui.SameLine()
        ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Active")
        ImGui.Text("SmartLoot will check for Lore conflicts before looting items")
        if config.loreCheckAnnounce then
            ImGui.Text("Conflicts will be announced in chat")
        else
            ImGui.Text("Conflicts will be logged silently")
        end

        -- Help Popup
        if ImGui.BeginPopup("LoreCheckSettingsHelp") then
            ImGui.Text("Lore Item Check Settings Help")
            ImGui.Separator()

            ImGui.Text("What are Lore Items?")
            ImGui.BulletText("Lore items are unique items you can only have one of")
            ImGui.BulletText("Attempting to loot a Lore item you already have will fail")
            ImGui.BulletText("This can cause SmartLoot to get stuck on a corpse")

            ImGui.Separator()
            ImGui.Text("How Lore Checking Works:")
            ImGui.BulletText("Before looting any item with a 'Keep' rule, checks if it's Lore")
            ImGui.BulletText("If Lore and you already have one, changes action to 'Ignore'")
            ImGui.BulletText("Prevents the loot attempt that would cause an error")
            ImGui.BulletText("Allows SmartLoot to continue processing other items")

            ImGui.Separator()
            ImGui.Text("Settings:")
            ImGui.BulletText("Lore Item Checking: Always enabled to prevent getting stuck")
            ImGui.BulletText("Announce Lore Conflicts: Chat notifications when items are skipped")

            ImGui.Separator()
            ImGui.Text("Examples:")
            ImGui.BulletText("'Skipping Lore item Ancient Blade (already have 1)'")
            ImGui.BulletText("Works with all Keep rules including KeepIfFewerThan")

            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_communication_settings(config)
    -- Combined Communication Settings Section with 3 columns
    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.9, 1.0, 1.0) -- Light blue header
    if ImGui.CollapsingHeader("Communication Settings") then
        ImGui.PopStyleColor()
        
        -- Create table with 3 columns
        if ImGui.BeginTable("CommunicationSettings", 3, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.Resizable) then
            -- Setup columns
            ImGui.TableSetupColumn("Chat Output", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Item Announce", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Lore Check", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableHeadersRow()
            
            ImGui.TableNextRow()
            
            -- Column 1: Chat Output Settings
            ImGui.TableSetColumnIndex(0)
            ImGui.Text("Chat Output Mode:")
            ImGui.PushItemWidth(-1)
            
            local chatModes = { "rsay", "group", "guild", "custom", "silent" }
            local chatModeNames = {
                ["rsay"] = "Raid Say",
                ["group"] = "Group",
                ["guild"] = "Guild",
                ["custom"] = "Custom",
                ["silent"] = "Silent"
            }
            
            local currentMode = config.chatOutputMode or "group"
            local isValidMode = false
            for _, mode in ipairs(chatModes) do
                if mode == currentMode then
                    isValidMode = true
                    break
                end
            end
            
            if not isValidMode then
                currentMode = "group"
                config.chatOutputMode = currentMode
                if config.save then
                    config.save()
                end
            end
            
            local displayName = chatModeNames[currentMode] or currentMode
            if ImGui.BeginCombo("##ChatMode", displayName) then
                for i, mode in ipairs(chatModes) do
                    local isSelected = (mode == currentMode)
                    if ImGui.Selectable(chatModeNames[mode], isSelected) then
                        config.chatOutputMode = mode
                        if config.save then
                            config.save()
                        end
                        logging.log("Chat output mode changed to: " .. chatModeNames[mode])
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.PopItemWidth()
            
            -- Custom channel input for custom mode
            if currentMode == "custom" then
                ImGui.Spacing()
                ImGui.Text("Custom Channel:")
                ImGui.PushItemWidth(-1)
                local customChannel = config.customChannel or ""
                local newCustomChannel, changedCustomChannel = ImGui.InputText("##CustomChannel", customChannel)
                if changedCustomChannel then
                    config.customChannel = newCustomChannel
                    if config.save then
                        config.save()
                    end
                end
                ImGui.PopItemWidth()
            end
            
            -- Help button for Chat
            ImGui.Spacing()
            ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)
            if ImGui.Button("Help##ChatHelp") then
                ImGui.OpenPopup("ChatSettingsHelp")
            end
            ImGui.PopStyleColor(2)
            
            -- Column 2: Item Announce Settings
            ImGui.TableSetColumnIndex(1)
            ImGui.Text("Item Announce Mode:")
            ImGui.PushItemWidth(-1)
            
            local announceModes = { "all", "ignored", "none" }
            local announceModeNames = {
                ["all"] = "All Items",
                ["ignored"] = "Ignored Items Only",
                ["none"] = "No Announcements"
            }
            
            local currentAnnounceMode = config.getItemAnnounceMode and config.getItemAnnounceMode() or "all"
            local announceDisplayName = announceModeNames[currentAnnounceMode] or currentAnnounceMode
            
            if ImGui.BeginCombo("##ItemAnnounceMode", announceDisplayName) then
                for i, mode in ipairs(announceModes) do
                    local isSelected = (mode == currentAnnounceMode)
                    if ImGui.Selectable(announceModeNames[mode], isSelected) then
                        if config.setItemAnnounceMode then
                            config.setItemAnnounceMode(mode)
                        end
                        logging.log("Item announce mode changed to: " .. announceModeNames[mode])
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.PopItemWidth()
            
            -- Help button for Item Announce
            ImGui.Spacing()
            ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)
            if ImGui.Button("Help##ItemAnnounceHelp") then
                ImGui.OpenPopup("ItemAnnounceSettingsHelp")
            end
            ImGui.PopStyleColor(2)
            
            -- Column 3: Lore Check Settings
            ImGui.TableSetColumnIndex(2)
            ImGui.Text("Lore Item Checking:")
            ImGui.TextColored(0.7, 0.7, 0.7, 1.0, "Always enabled")
            ImGui.Spacing()
            
            local loreCheckAnnounce = config.loreCheckAnnounce
            if loreCheckAnnounce == nil then loreCheckAnnounce = true end
            local newLoreCheckAnnounce, changedLoreCheckAnnounce = ImGui.Checkbox("Announce Conflicts", loreCheckAnnounce)
            if changedLoreCheckAnnounce then
                config.loreCheckAnnounce = newLoreCheckAnnounce
                if config.save then
                    config.save()
                end
                logging.log("Lore conflict announcements " .. (newLoreCheckAnnounce and "enabled" or "disabled"))
            end
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Announces when Lore items are skipped due to conflicts")
            end
            
            -- Help button for Lore Check
            ImGui.Spacing()
            ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)
            if ImGui.Button("Help##LoreCheckHelp") then
                ImGui.OpenPopup("LoreCheckSettingsHelp")
            end
            ImGui.PopStyleColor(2)
            
            ImGui.EndTable()
        end
        
        -- Keep all the existing popup help dialogs here
        -- Chat Settings Help Popup
        if ImGui.BeginPopup("ChatSettingsHelp") then
            ImGui.Text("Chat Output Settings Help")
            ImGui.Separator()
            ImGui.Text("Available chat modes:")
            ImGui.BulletText("Raid Say - Sends messages to /rsay (raid)")
            ImGui.BulletText("Group - Sends messages to /g (group)")
            ImGui.BulletText("Guild - Sends messages to /gu (guild)")
            ImGui.BulletText("Custom - Specify your own channel")
            ImGui.BulletText("Silent - No chat output")
            ImGui.Separator()
            ImGui.Text("Test your settings:")
            ImGui.SameLine()
            if ImGui.Button("Send Test Message") then
                local testMessage = "SmartLoot test message - chat mode working!"
                local outputMode = config.chatOutputMode or "group"
                
                if outputMode == "rsay" then
                    mq.cmd("/rsay " .. testMessage)
                elseif outputMode == "group" then
                    mq.cmd("/g " .. testMessage)
                elseif outputMode == "guild" then
                    mq.cmd("/gu " .. testMessage)
                elseif outputMode == "custom" then
                    local customChannel = config.customChannel or "say"
                    mq.cmd("/" .. customChannel .. " " .. testMessage)
                elseif outputMode == "silent" then
                    logging.log("Test message (silent mode): " .. testMessage)
                end
            end
            ImGui.EndPopup()
        end
        
        -- Item Announce Settings Help Popup
        if ImGui.BeginPopup("ItemAnnounceSettingsHelp") then
            ImGui.Text("Item Announce Settings Help")
            ImGui.Separator()
            ImGui.Text("Item announce modes:")
            ImGui.BulletText("All Items - Announces every item looted and its rule")
            ImGui.BulletText("Ignored Items Only - Only announces items that are ignored")
            ImGui.BulletText("No Announcements - Silent item processing")
            ImGui.Separator()
            ImGui.Text("Examples:")
            ImGui.BulletText("All: 'Looted Ancient Blade (Keep)'")
            ImGui.BulletText("Ignored: 'Looted Rusty Sword (Ignore)'")
            ImGui.BulletText("None: No item messages in chat")
            ImGui.EndPopup()
        end
        
        -- Lore Check Settings Help Popup
        if ImGui.BeginPopup("LoreCheckSettingsHelp") then
            ImGui.Text("Lore Item Check Settings Help")
            ImGui.Separator()
            ImGui.Text("What it does:")
            ImGui.BulletText("Before looting any item with a 'Keep' rule, checks if it's Lore")
            ImGui.BulletText("If Lore and you already have one, changes action to 'Ignore'")
            ImGui.BulletText("Prevents the loot attempt that would cause an error")
            ImGui.BulletText("Allows SmartLoot to continue processing other items")
            ImGui.Separator()
            ImGui.Text("Settings:")
            ImGui.BulletText("Lore Item Checking: Always enabled to prevent getting stuck")
            ImGui.BulletText("Announce Lore Conflicts: Chat notifications when items are skipped")
            ImGui.Separator()
            ImGui.Text("Examples:")
            ImGui.BulletText("'Skipping Lore item Ancient Blade (already have 1)'")
            ImGui.BulletText("Works with all Keep rules including KeepIfFewerThan")
            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_inventory_settings(config)
    -- Inventory Space Check Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 1.0, 0.8, 1.0) -- Light green-cyan header
    if ImGui.CollapsingHeader("Inventory Space Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##InventoryHelp") then
            ImGui.OpenPopup("InventorySettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for inventory space check descriptions")
        end

        -- Enable/Disable inventory space check
        local enableInventoryCheck = SmartLootEngine.config.enableInventorySpaceCheck or true
        local newEnableInventoryCheck, changedEnableInventoryCheck = ImGui.Checkbox("Enable Inventory Space Check", enableInventoryCheck)
        if changedEnableInventoryCheck then
            SmartLootEngine.config.enableInventorySpaceCheck = newEnableInventoryCheck
            if config.save then
                config.save()
            end
            logging.log("Inventory space checking " .. (newEnableInventoryCheck and "enabled" or "disabled"))
        end

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("When enabled, prevents looting when inventory space is low")
        end

        -- Minimum free inventory slots (only show if inventory checking is enabled)
        if enableInventoryCheck then
            ImGui.Spacing()
            ImGui.Text("Minimum Free Slots:")
            ImGui.SameLine()
            ImGui.PushItemWidth(100)

            local minSlots = SmartLootEngine.config.minFreeInventorySlots or 5
            local newMinSlots, changedMinSlots = ImGui.InputInt("##MinFreeSlots", minSlots, 1, 5)
            if changedMinSlots then
                newMinSlots = math.max(1, math.min(30, newMinSlots)) -- Clamp between 1-30
                SmartLootEngine.config.minFreeInventorySlots = newMinSlots
                if config.save then
                    config.save()
                end
                logging.log("Minimum free inventory slots set to: " .. newMinSlots)
            end

            ImGui.PopItemWidth()

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Number of free inventory slots required before looting stops\nRange: 1-30 slots")
            end

            -- Auto-inventory on loot setting
            ImGui.Spacing()
            local autoInventory = SmartLootEngine.config.autoInventoryOnLoot or true
            local newAutoInventory, changedAutoInventory = ImGui.Checkbox("Auto-Inventory on Loot", autoInventory)
            if changedAutoInventory then
                SmartLootEngine.config.autoInventoryOnLoot = newAutoInventory
                if config.save then
                    config.save()
                end
                logging.log("Auto-inventory on loot " .. (newAutoInventory and "enabled" or "disabled"))
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Automatically move looted items to main inventory")
            end
        end

        -- Status display
        ImGui.Spacing()
        ImGui.Text("Status:")
        if enableInventoryCheck then
            ImGui.SameLine()
            ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Active")
            local currentFreeSlots = mq.TLO.Me.FreeInventory() or 0
            local minRequired = SmartLootEngine.config.minFreeInventorySlots or 5
            
            ImGui.Text(string.format("Current free slots: %d / %d required", currentFreeSlots, minRequired))
            
            if currentFreeSlots < minRequired then
                ImGui.TextColored(0.8, 0.2, 0.2, 1.0, "WARNING: Insufficient inventory space!")
            else
                ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Inventory space OK")
            end
        else
            ImGui.SameLine()
            ImGui.TextColored(0.8, 0.6, 0.2, 1.0, "Disabled")
            ImGui.Text("Inventory space will not be checked before looting")
        end

        -- Help Popup
        if ImGui.BeginPopup("InventorySettingsHelp") then
            ImGui.Text("Inventory Space Settings Help")
            ImGui.Separator()

            ImGui.Text("What does Inventory Space Check do?")
            ImGui.BulletText("Prevents looting when you have insufficient inventory space")
            ImGui.BulletText("Uses MQ's FreeInventory() function to check available slots")
            ImGui.BulletText("Skips corpse looting when space is below minimum threshold")

            ImGui.Separator()
            ImGui.Text("Settings:")
            ImGui.BulletText("Enable Inventory Space Check: Turn the feature on/off")
            ImGui.BulletText("Minimum Free Slots: Required free slots before stopping loot")
            ImGui.BulletText("Auto-Inventory on Loot: Move items to inventory automatically")

            ImGui.Separator()
            ImGui.Text("How it works:")
            ImGui.BulletText("Before looting each corpse, checks current free inventory")
            ImGui.BulletText("If free slots < minimum required, skips the corpse")
            ImGui.BulletText("Prevents getting stuck on corpses due to full inventory")
            ImGui.BulletText("Resumes looting when inventory space becomes available")

            ImGui.Separator()
            ImGui.Text("Recommended Settings:")
            ImGui.BulletText("Minimum Free Slots: 5-10 (allows for multiple items per corpse)")
            ImGui.BulletText("Enable Auto-Inventory: Helps manage cursor/inventory items")

            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor()
    end
    ImGui.Spacing()
end

local function draw_chase_settings(config)
    -- Chase Integration Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.6, 1.0) -- Light orange header
    if ImGui.CollapsingHeader("Chase Integration Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()

        -- Help button that opens popup
        ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)                -- Transparent background
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3) -- Slight highlight on hover
        if ImGui.Button("(?)##ChaseHelp") then
            ImGui.OpenPopup("ChaseSettingsHelp")
        end
        ImGui.PopStyleColor(2)

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Click for chase command examples and testing options")
        end

        -- Enable/Disable chase commands
        local useChase, chaseChanged = ImGui.Checkbox("Enable Chase Commands", config.useChaseCommands or false)
        if chaseChanged then
            config.useChaseCommands = useChase
            if config.save then
                config.save()
            end

            if config.useChaseCommands then
                logging.log("Chase commands enabled")
            else
                logging.log("Chase commands disabled")
            end
        end

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Enable custom chase pause/resume commands during looting")
        end

        -- Only show command inputs if chase commands are enabled
        if config.useChaseCommands then
            ImGui.Spacing()

            -- Chase Pause Command
            ImGui.Text("Chase Pause Command:")
            ImGui.SameLine()
            ImGui.PushItemWidth(200)

            local pauseCommand = config.chasePauseCommand or "/luachase pause on"
            local newPauseCommand, pauseChanged = ImGui.InputText("##ChasePauseCommand", pauseCommand, 128)

            if pauseChanged then
                -- Ensure command starts with /
                if not newPauseCommand:match("^/") then
                    newPauseCommand = "/" .. newPauseCommand
                end
                config.chasePauseCommand = newPauseCommand
                if config.save then
                    config.save()
                end
                logging.log("Chase pause command set to: " .. newPauseCommand)
            end

            ImGui.PopItemWidth()

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Command to pause chase/follow during looting")
            end

            -- Chase Resume Command
            ImGui.Text("Chase Resume Command:")
            ImGui.SameLine()
            ImGui.PushItemWidth(200)

            local resumeCommand = config.chaseResumeCommand or "/luachase pause off"
            local newResumeCommand, resumeChanged = ImGui.InputText("##ChaseResumeCommand", resumeCommand, 128)

            if resumeChanged then
                -- Ensure command starts with /
                if not newResumeCommand:match("^/") then
                    newResumeCommand = "/" .. newResumeCommand
                end
                config.chaseResumeCommand = newResumeCommand
                if config.save then
                    config.save()
                end
                logging.log("Chase resume command set to: " .. newResumeCommand)
            end

            ImGui.PopItemWidth()

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Command to resume chase/follow after looting")
            end

            -- Current configuration display
            ImGui.Spacing()
            ImGui.Text("Current Configuration:")
            ImGui.BulletText("Pause: " .. (config.chasePauseCommand or "None"))
            ImGui.BulletText("Resume: " .. (config.chaseResumeCommand or "None"))
        end

        -- Help Popup
        if ImGui.BeginPopup("ChaseSettingsHelp") then
            ImGui.Text("Chase Command Help & Testing")
            ImGui.Separator()

            -- Common chase commands
            ImGui.Text("Common Chase Commands:")
            ImGui.BulletText("LuaChase: /luachase pause on, /luachase pause off")
            ImGui.BulletText("RGMercs: /rgl chaseon, /rgl chaseoff")
            ImGui.BulletText("MQ2AdvPath: /afollow pause, /afollow unpause")
            ImGui.BulletText("MQ2Nav: /nav pause, /nav unpause")
            ImGui.BulletText("Custom: Any command you want to use")

            ImGui.Separator()

            -- Only show test buttons if chase commands are enabled
            if config.useChaseCommands then
                ImGui.Text("Test Chase Commands:")

                if ImGui.Button("Test Pause") then
                    if config.executeChaseCommand then
                        local success, msg = config.executeChaseCommand("pause")
                        if success then
                            logging.log("Chase pause test: " .. msg)
                        else
                            logging.log("Chase pause test failed: " .. msg)
                        end
                    else
                        -- Fallback test
                        mq.cmd(config.chasePauseCommand or "/luachase pause on")
                        logging.log("Chase pause test executed: " .. (config.chasePauseCommand or "/luachase pause on"))
                    end
                end

                ImGui.SameLine()

                if ImGui.Button("Test Resume") then
                    if config.executeChaseCommand then
                        local success, msg = config.executeChaseCommand("resume")
                        if success then
                            logging.log("Chase resume test: " .. msg)
                        else
                            logging.log("Chase resume test failed: " .. msg)
                        end
                    else
                        -- Fallback test
                        mq.cmd(config.chaseResumeCommand or "/luachase pause off")
                        logging.log("Chase resume test executed: " ..
                            (config.chaseResumeCommand or "/luachase pause off"))
                    end
                end
            else
                ImGui.TextDisabled("Enable chase commands to test")
            end

            ImGui.Separator()
            if ImGui.Button("Close") then
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        end
    else
        ImGui.PopStyleColor() -- Pop the color even if header is closed
    end
end

function uiSettings.draw(lootUI, settings, config)
    if ImGui.BeginTabItem("Settings") then
        -- Add proper spacing after tab header to prevent overlap
        ImGui.Spacing()
        
        -- Database info section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0) -- Gray text
        ImGui.Text("DB:")
        ImGui.PopStyleColor()
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.9, 1.0) -- Light text
        local dbPath = config.filePath or "smartloot_config.json"
        local dbName = dbPath:match("([^/\\]+)$") or dbPath     -- Extract filename from path
        ImGui.Text(dbName)
        ImGui.PopStyleColor()
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Database Config File:\n" .. dbPath)
        end

        ImGui.SameLine()
        ImGui.Text("  |  ")
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0) -- Gray text
        ImGui.Text("SQLite:")
        ImGui.PopStyleColor()
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 1.0, 0.6, 1.0) -- Light green text
        ImGui.Text("Connected")
        ImGui.PopStyleColor()
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Database Status: SQLite database is connected and operational")
        end
        
        -- Add spacing before main content
        ImGui.Spacing()
        ImGui.Separator()

        -- Core Performance Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0) -- Light blue header
        if ImGui.CollapsingHeader("Core Performance Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

            ImGui.Columns(2, nil, false) -- Two-column layout
            ImGui.SetColumnWidth(0, 300) -- Set a fixed width for column 1
            ImGui.SetColumnWidth(1, 300) -- Set a fixed width for column 2

            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Loop Delay:")
            ImGui.PopStyleColor()
            ImGui.SameLine(106)
            ImGui.PushItemWidth(150)
            local newLoop, changedLoop = ImGui.InputInt("##Loop Delay (ms)", settings.loopDelay)
            if changedLoop then settings.loopDelay = newLoop end
            if ImGui.IsItemHovered() then ImGui.SetTooltip("Delay between corpse scans (milliseconds)") end
            ImGui.PopItemWidth()

            ImGui.NextColumn()
            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Loot Radius:")
            ImGui.PopStyleColor()
            ImGui.SameLine(125)
            ImGui.PushItemWidth(150)
            local newRadius, changedRadius = ImGui.InputInt("##Loot Radius", settings.lootRadius)
            if changedRadius then settings.lootRadius = newRadius end
            if ImGui.IsItemHovered() then ImGui.SetTooltip("Corpse search radius") end
            ImGui.PopItemWidth()

            ImGui.NextColumn()
            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Combat Delay:")
            ImGui.PopStyleColor()
            ImGui.SameLine()
            ImGui.PushItemWidth(150)
            local newCombat, changedCombat = ImGui.InputInt("##Combat Wait Delay (ms)", settings.combatWaitDelay)
            if changedCombat then settings.combatWaitDelay = newCombat end
            if ImGui.IsItemHovered() then ImGui.SetTooltip("Delay after combat ends (milliseconds)") end
            ImGui.PopItemWidth()

            ImGui.NextColumn()
            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Main Toon Name:")
            ImGui.PopStyleColor()
            ImGui.SameLine()
            ImGui.PushItemWidth(150) -- Set input box width

            local newMainToonName, changedMainToonName = ImGui.InputText("##MainToonName", config.mainToonName or "", 128)
            if changedMainToonName then
                config.mainToonName = newMainToonName
                if config.save then
                    config.save() -- Save to config file
                end
            end

            ImGui.PopItemWidth()
            ImGui.Columns(1) -- End columns for this section
            ImGui.Spacing()
        else
            ImGui.PopStyleColor() -- Pop the color even if header is closed
        end

        -- Coordination Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 1.0, 0.6, 1.0) -- Light green header
        if ImGui.CollapsingHeader("Peer Coordination Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

            ImGui.Columns(3, nil, false) -- Three-column layout
            ImGui.SetColumnWidth(0, 200) -- Set a fixed width for column 1
            ImGui.SetColumnWidth(1, 200) -- Set a fixed width for column 2
            ImGui.SetColumnWidth(2, 200)

            -- **Row 1: Is Main Looter & Loot Command Type**
            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Is Main Looter:")
            ImGui.PopStyleColor()
            ImGui.SameLine(150) -- Ensure spacing for alignment
            local isMain, changedIsMain = ImGui.Checkbox("##IsMain", settings.isMain)
            if changedIsMain then settings.isMain = isMain end

            ImGui.NextColumn() -- Move to the second column

            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Loot Command Type:")
            ImGui.PopStyleColor()
            ImGui.SameLine()

            local commandOptions = { "DanNet", "E3", "EQBC" }
            local commandValues = { "dannet", "e3", "bc" } -- Internal values that match util.lua
            local commandNames = {
                ["dannet"] = "DanNet",
                ["e3"] = "E3",
                ["bc"] = "EQBC"
            }

            -- Get current mode directly from config - ensure it's valid (following ChatMode pattern)
            local currentCommandType = config.lootCommandType or "dannet"

            -- Validate that currentCommandType is in our list
            local isValidCommand = false
            for _, value in ipairs(commandValues) do
                if value == currentCommandType then
                    isValidCommand = true
                    break
                end
            end

            -- If invalid command, default to dannet (following ChatMode pattern)
            if not isValidCommand then
                currentCommandType = "dannet"
                config.lootCommandType = currentCommandType
                if config.save then
                    config.save()
                end
            end

            local currentIndex = 0 -- Use 0-based indexing like ChatMode

            -- Find current command type index (following ChatMode pattern)
            for i, value in ipairs(commandValues) do
                if value == currentCommandType then
                    currentIndex = i - 1 -- Convert to 0-based
                    break
                end
            end

            -- Display current command name (following ChatMode pattern)
            local displayName = commandNames[currentCommandType] or currentCommandType

            ImGui.PushItemWidth(120)
            if ImGui.BeginCombo("##LootCommandType", displayName) then
                for i, option in ipairs(commandOptions) do
                    local isSelected = (currentIndex == i - 1) -- 0-based comparison like ChatMode
                    if ImGui.Selectable(option, isSelected) then
                        -- Immediately update the config when selected (following ChatMode pattern)
                        local selectedValue = commandValues[i]
                        config.lootCommandType = selectedValue

                        logging.log("Loot command type changed to: " .. option .. " (" .. selectedValue .. ")")
                        if config.save then
                            config.save()
                        end

                        -- Update local variables for immediate UI feedback (following ChatMode pattern)
                        currentCommandType = selectedValue
                        currentIndex = i - 1
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.PopItemWidth()

            -- Add a quick fix button
            ImGui.SameLine()
            if ImGui.Button("Reset##ResetCommandType") then
                config.lootCommandType = "dannet"
                if config.save then
                    config.save()
                end
                logging.log("Command type FORCE reset to dannet")
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Force reset command type to DanNet")
            end

            -- Debug button to see what's in memory
            ImGui.SameLine()
            if ImGui.Button("Debug##DebugCommandType") then
                logging.log("=== COMMAND TYPE DEBUG ===")
                logging.log("config.lootCommandType = '" .. tostring(config.lootCommandType) .. "'")
                logging.log("Raw type: " .. type(config.lootCommandType))
                if config.debugPrint then
                    config.debugPrint()
                end
            end

            ImGui.NextColumn()                                      -- 3rd Column
            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Pause Peer Triggering:")
            ImGui.PopStyleColor()
            ImGui.SameLine(150) -- Ensure spacing for alignment
            local peerTriggerPaused, changedPausePeerTrigger = ImGui.Checkbox("##PausePeerTriggering",
                settings.peerTriggerPaused)
            if changedPausePeerTrigger then settings.peerTriggerPaused = peerTriggerPaused end
            ImGui.Columns(1) -- End columns for coordination section
            ImGui.Spacing()
        else
            ImGui.PopStyleColor() -- Pop the color even if header is closed
        end

        -- Timing Settings Section
        draw_timing_settings()

        -- Speed Settings Section
        draw_speed_settings()

        -- Decision Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 1.0, 1.0) -- Light purple header
        if ImGui.CollapsingHeader("Decision Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

            -- Add checkbox for auto-resolve unknown items
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0) -- Light yellow labels
            ImGui.Text("Auto Apply Rule:")
            ImGui.PopStyleColor()
            ImGui.SameLine(150)
            local autoResolve, autoResolveChanged = ImGui.Checkbox("##Auto-resolve unknown items",
                SmartLootEngine.config.autoResolveUnknownItems or false)
            if autoResolveChanged then
                SmartLootEngine.config.autoResolveUnknownItems = autoResolve
                if autoResolve then
                    logging.log("Auto-resolve unknown items enabled - will use default action after timeout")
                else
                    logging.log("Auto-resolve unknown items disabled - will ignore after timeout")
                end
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(
                    "When enabled, items without rules will be handled according to the default action after the timeout.\nWhen disabled, items will be ignored after timeout.")
            end

            -- Only show timeout setting if auto-resolve is enabled
            if SmartLootEngine.config.autoResolveUnknownItems then
                ImGui.Text("Pending Decision Timeout (s):")
                ImGui.SameLine()
                ImGui.PushItemWidth(100)

                local newTimeout, changedTimeout = ImGui.InputInt("##PendingDecisionTimeout",
                    settings.pendingDecisionTimeout / 1000, 0, 0)
                if changedTimeout then
                    settings.pendingDecisionTimeout = math.max(5, newTimeout) * 1000 -- Min 5 seconds, convert to ms
                    -- Update the engine's config
                    SmartLootEngine.config.pendingDecisionTimeoutMs = settings.pendingDecisionTimeout
                end

                ImGui.PopItemWidth()

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Time before auto-resolving items with no rule (minimum 5 seconds)")
                end

                -- Default action selector
                ImGui.Text("Default Action:")
                ImGui.SameLine()
                ImGui.PushItemWidth(120)

                local defaultActions = { "Keep", "Ignore", "Destroy" }
                -- Initialize settings value if not present
                if not settings.defaultUnknownItemAction then
                    settings.defaultUnknownItemAction = SmartLootEngine.config.defaultUnknownItemAction or "Ignore"
                end

                -- Use settings.defaultUnknownItemAction directly in BeginCombo
                if ImGui.BeginCombo("##DefaultAction", settings.defaultUnknownItemAction) then
                    for _, action in ipairs(defaultActions) do
                        -- Check against settings.defaultUnknownItemAction for selection
                        local isSelected = (settings.defaultUnknownItemAction == action)
                        if ImGui.Selectable(action, isSelected) then
                            -- Update both settings and engine config
                            settings.defaultUnknownItemAction = action
                            SmartLootEngine.config.defaultUnknownItemAction = action
                            logging.log("Default unknown item action set to: " .. action)

                            -- IMPORTANT: Save the configuration after changing a setting
                            if config.save then
                                config.save()
                            end
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                    ImGui.EndCombo()
                end

                ImGui.PopItemWidth()

                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Action to take for items without rules after timeout")
                end
            end

            ImGui.Spacing()
        else
            ImGui.PopStyleColor() -- Pop the color even if header is closed
        end

        draw_communication_settings(config)
        draw_inventory_settings(config)
        draw_chase_settings(config)
        
        -- Database Tools Section
        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()
        
        if ImGui.CollapsingHeader("Database Tools") then
            ImGui.Text("Import/Export Tools:")
            ImGui.Spacing()
            
            if ImGui.Button("Legacy Import", 120, 0) then
                lootUI.legacyImportPopup = lootUI.legacyImportPopup or {}
                lootUI.legacyImportPopup.isOpen = true
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Import loot rules from E3 Macro INI files")
            end
            
            ImGui.Spacing()
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Import legacy E3 loot rules from INI format files")
        end
        
        ImGui.EndTabItem()
    end
end

return uiSettings
