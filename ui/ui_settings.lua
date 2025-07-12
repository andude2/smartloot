local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local database = require("modules.database")
local config = require("modules.config")
local SmartLootEngine = require("modules.SmartLootEngine")

local uiSettings = {}

local function draw_memory_settings(settings)
    -- Memory Management Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.6, 0.8, 1.0)  -- Light pink header
    if ImGui.CollapsingHeader("Memory Management Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()
    
    -- Help button
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)
    if ImGui.Button("(?)##MemoryHelp") then
        ImGui.OpenPopup("MemorySettingsHelp")
    end
    ImGui.PopStyleColor(2)
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Session tracking memory cleanup settings")
    end
    
    -- Memory Settings Help Popup
    if ImGui.BeginPopup("MemorySettingsHelp") then
        ImGui.Text("Memory Management Settings")
        ImGui.Separator()
        ImGui.BulletText("Cleanup Interval: How often to check for old session data")
        ImGui.BulletText("Max Age: How long to keep session tracking data")
        ImGui.BulletText("Max Entries: Force cleanup when this many entries exist")
        ImGui.Separator()
        ImGui.Text("Session tracking prevents processing the same items/corpses")
        ImGui.Text("repeatedly, but uses memory. These settings control cleanup.")
        ImGui.EndPopup()
    end
    
    ImGui.Columns(2, nil, false)
    ImGui.SetColumnWidth(0, 300)
    ImGui.SetColumnWidth(1, 300)
    
    -- Cleanup Interval
    ImGui.AlignTextToFramePadding()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
    ImGui.Text("Session Cleanup Interval:")
    ImGui.PopStyleColor()
    ImGui.SameLine()
    ImGui.PushItemWidth(100)
    local newInterval, changedInterval = ImGui.InputInt("##SessionCleanupInterval", settings.sessionCleanupIntervalMinutes, 1, 5)
    if changedInterval then 
        settings.sessionCleanupIntervalMinutes = math.max(1, math.min(60, newInterval))
    end
    ImGui.PopItemWidth()
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)  -- Light gray for units
    ImGui.Text("minutes")
    ImGui.PopStyleColor()
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("How often to check for old session data (1-60 minutes)")
    end
    
    ImGui.NextColumn()
    
    -- Max Age
    ImGui.AlignTextToFramePadding()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
    ImGui.Text("Session Data Max Age:")
    ImGui.PopStyleColor()
    ImGui.SameLine()
    ImGui.PushItemWidth(100)
    local newMaxAge, changedMaxAge = ImGui.InputInt("##SessionMaxAge", settings.sessionTrackingMaxAgeMinutes, 5, 15)
    if changedMaxAge then 
        settings.sessionTrackingMaxAgeMinutes = math.max(5, math.min(480, newMaxAge))
    end
    ImGui.PopItemWidth()
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0)  -- Light gray for units
    ImGui.Text("minutes")
    ImGui.PopStyleColor()
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("How long to keep session tracking data (5-480 minutes)")
    end
    
    ImGui.NextColumn()
    
    -- Max Entries
    ImGui.AlignTextToFramePadding()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
    ImGui.Text("Max Session Entries:")
    ImGui.PopStyleColor()
    ImGui.SameLine()
    ImGui.PushItemWidth(100)
    local newMaxEntries, changedMaxEntries = ImGui.InputInt("##MaxSessionEntries", settings.maxSessionTrackingEntries, 100, 500)
    if changedMaxEntries then 
        settings.maxSessionTrackingEntries = math.max(100, math.min(10000, newMaxEntries))
    end
    ImGui.PopItemWidth()
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Force cleanup when this many entries exist (100-10000)")
    end
    
    ImGui.NextColumn()
    
    -- Manual Cleanup Button
    ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.3, 0.3, 1.0)  -- Red button
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.4, 0.4, 1.0)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.2, 0.2, 1.0)
    
    if ImGui.Button("Clean Session Data Now") then
        SmartLootEngine.cleanupSessionTracking(true)
        logging.log("Manual session tracking cleanup performed")
    end
    ImGui.PopStyleColor(3)
    
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip("Immediately clean up old session tracking data")
    end
    
        ImGui.Columns(1)
    else
        ImGui.PopStyleColor()  -- Pop the color even if header is closed
    end
end

local function draw_chat_settings(config)
    -- Chat Output Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 0.9, 1.0, 1.0)  -- Light cyan header
    if ImGui.CollapsingHeader("Chat Output Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()
    
    -- Help button that opens popup
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)  -- Transparent background
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)  -- Slight highlight on hover
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
    
    local chatModes = {"rsay", "group", "guild", "custom", "silent"}
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
                        logging.log("Chat output mode changed to: " .. (config.getChatModeDescription and config.getChatModeDescription() or mode))
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
        ImGui.PopStyleColor()  -- Pop the color even if header is closed
    end
end

local function draw_chase_settings(config)
    -- Chase Integration Settings Section
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.6, 1.0)  -- Light orange header
    if ImGui.CollapsingHeader("Chase Integration Settings") then
        ImGui.PopStyleColor()
        ImGui.SameLine()
    
    -- Help button that opens popup
    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)  -- Transparent background
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.3)  -- Slight highlight on hover
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
                    logging.log("Chase resume test executed: " .. (config.chaseResumeCommand or "/luachase pause off"))
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
        ImGui.PopStyleColor()  -- Pop the color even if header is closed
    end
end

function uiSettings.draw(lootUI, settings, config)
    if ImGui.BeginTabItem("Settings") then
        -- Header section with pause/resume button
        ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.4, 0.8, 1.0)  -- Blue button
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.5, 0.9, 1.0)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.3, 0.7, 1.0)
        
        if ImGui.Button(lootUI.paused and "Resume" or "Pause") then
            mq.cmd("/smartloot_pause " .. (lootUI.paused and "off" or "on"))
        end
        ImGui.PopStyleColor(3)
        
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip(lootUI.paused and "Resume loot processing" or "Pause loot processing")
        end
        
        -- Core Performance Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0)  -- Light blue header
        if ImGui.CollapsingHeader("⚙ Core Performance Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

            ImGui.Columns(2, nil, false)  -- Two-column layout
            ImGui.SetColumnWidth(0, 300)  -- Set a fixed width for column 1
            ImGui.SetColumnWidth(1, 300)  -- Set a fixed width for column 2

            ImGui.AlignTextToFramePadding()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
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
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
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
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
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
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
            ImGui.Text("Main Toon Name:")
            ImGui.PopStyleColor()
            ImGui.SameLine()
            ImGui.PushItemWidth(150)  -- Set input box width

            local newMainToonName, changedMainToonName = ImGui.InputText("##MainToonName", config.mainToonName or "", 128)
            if changedMainToonName then
                config.mainToonName = newMainToonName
                if config.save then
                    config.save()  -- Save to config file
                end
            end

            ImGui.PopItemWidth()
            ImGui.Columns(1)  -- End columns for this section
            ImGui.Spacing()
        else
            ImGui.PopStyleColor()  -- Pop the color even if header is closed
        end
        
        -- Coordination Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.6, 1.0, 0.6, 1.0)  -- Light green header
        if ImGui.CollapsingHeader("Peer Coordination Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

            ImGui.Columns(3, nil, false)  -- Three-column layout
            ImGui.SetColumnWidth(0, 200)  -- Set a fixed width for column 1
            ImGui.SetColumnWidth(1, 200)  -- Set a fixed width for column 2
            ImGui.SetColumnWidth(2, 300)
        
        -- **Row 1: Is Main Looter & Loot Command Type**
        ImGui.AlignTextToFramePadding()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
        ImGui.Text("Is Main Looter:")
        ImGui.PopStyleColor()
        ImGui.SameLine(150)  -- Ensure spacing for alignment
        local isMain, changedIsMain = ImGui.Checkbox("##IsMain", settings.isMain)
        if changedIsMain then settings.isMain = isMain end
        
        ImGui.NextColumn()  -- Move to the second column
        
        ImGui.AlignTextToFramePadding()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
        ImGui.Text("Loot Command Type:")
        ImGui.PopStyleColor()
        ImGui.SameLine()
        
        local commandOptions = { "DanNet", "E3", "EQBC" }
        local commandValues = { "dannet", "e3", "bc" }  -- Internal values that match util.lua
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
        
        local currentIndex = 0  -- Use 0-based indexing like ChatMode
        
        -- Find current command type index (following ChatMode pattern)
        for i, value in ipairs(commandValues) do
            if value == currentCommandType then
                currentIndex = i - 1  -- Convert to 0-based
                break
            end
        end
        
        -- Display current command name (following ChatMode pattern)
        local displayName = commandNames[currentCommandType] or currentCommandType
        
        ImGui.PushItemWidth(120)
        if ImGui.BeginCombo("##LootCommandType", displayName) then
            for i, option in ipairs(commandOptions) do
                local isSelected = (currentIndex == i - 1)  -- 0-based comparison like ChatMode
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
        
            ImGui.NextColumn()  -- 3rd Column
            ImGui.Columns(1)  -- End columns for coordination section
            ImGui.Spacing()
        else
            ImGui.PopStyleColor()  -- Pop the color even if header is closed
        end
        
        -- Decision Settings Section
        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 1.0, 1.0)  -- Light purple header
        if ImGui.CollapsingHeader("Decision Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()

        -- Add checkbox for auto-resolve unknown items
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
        ImGui.Text("Auto Apply Rule:")
        ImGui.PopStyleColor()
        ImGui.SameLine(150)
        local autoResolve, autoResolveChanged = ImGui.Checkbox("##Auto-resolve unknown items", SmartLootEngine.config.autoResolveUnknownItems or false)
        if autoResolveChanged then
            SmartLootEngine.config.autoResolveUnknownItems = autoResolve
            if autoResolve then
                logging.log("Auto-resolve unknown items enabled - will use default action after timeout")
            else
                logging.log("Auto-resolve unknown items disabled - will ignore after timeout")
            end
        end

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("When enabled, items without rules will be handled according to the default action after the timeout.\nWhen disabled, items will be ignored after timeout.")
        end

        -- Only show timeout setting if auto-resolve is enabled
        if SmartLootEngine.config.autoResolveUnknownItems then
            ImGui.Text("Pending Decision Timeout (s):")
            ImGui.SameLine()
            ImGui.PushItemWidth(100)
        
            local newTimeout, changedTimeout = ImGui.InputInt("##PendingDecisionTimeout", settings.pendingDecisionTimeout / 1000, 0, 0)
            if changedTimeout then
                settings.pendingDecisionTimeout = math.max(5, newTimeout) * 1000  -- Min 5 seconds, convert to ms
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

            local defaultActions = {"Keep", "Ignore", "Destroy"}
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
            ImGui.PopStyleColor()  -- Pop the color even if header is closed
        end
        
        -- Additional Settings Section  
        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.4, 1.0)  -- Orange header
        if ImGui.CollapsingHeader("Additional Settings", ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.PopStyleColor()
            ImGui.Spacing()
            
            ImGui.Columns(2, nil, false)  -- Two-column layout
            ImGui.SetColumnWidth(0, 300)
            ImGui.SetColumnWidth(1, 300)
        
        -- **Row 2: Pause Peer Triggering & Show Log Window**
        ImGui.AlignTextToFramePadding()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
        ImGui.Text("Pause Peer Triggering:")
        ImGui.PopStyleColor()
        ImGui.SameLine(150)  -- Ensure spacing for alignment
        local peerTriggerPaused, changedPausePeerTrigger = ImGui.Checkbox("##PausePeerTriggering", settings.peerTriggerPaused)
        if changedPausePeerTrigger then settings.peerTriggerPaused = peerTriggerPaused end
        
        ImGui.NextColumn()  -- Move to second column
        
        ImGui.AlignTextToFramePadding()
        ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.6, 1.0)  -- Light yellow labels
        ImGui.Text("Show Log Window:")
        ImGui.PopStyleColor()
        ImGui.SameLine()
        
        -- **Ensure perfect alignment by reserving the same vertical space as the dropdown**
        ImGui.Dummy(0, ImGui.GetFrameHeight() * 0.25)  
        ImGui.SameLine(150)
        local newShowLog, changedShowLog = ImGui.Checkbox("##ShowLogWindow", settings.showLogWindow)
        if changedShowLog then 
            settings.showLogWindow = newShowLog 
        end

            ImGui.Columns(1)  -- End the column layout for additional settings
            ImGui.Spacing()
        else
            ImGui.PopStyleColor()  -- Pop the color even if header is closed
        end
        
        -- NEW: Draw settings sections
        draw_memory_settings(settings)
        draw_chat_settings(config)
        draw_chase_settings(config)
        ImGui.EndTabItem()
    end
end

return uiSettings