-- ui_peer_commands.lua (Enhanced with prettier UI and conditional Emergency Stop All)
local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local SmartLootEngine = require("modules.SmartLootEngine")
local config = require("modules.config")

local uiPeerCommands = {}

function uiPeerCommands.draw(lootUI, loot, util)
    if not lootUI then return end
    
    -- Set consistent window properties
    ImGui.SetNextWindowBgAlpha(0.85)
    -- Reset position/size on demand to recover from off-screen states
    if lootUI.resetPeerCommandsWindow then
        if ImGui.SetNextWindowPos then ImGui.SetNextWindowPos(200, 200, ImGuiCond.Always) end
        ImGui.SetNextWindowSize(320, 450, ImGuiCond.Always)
        if ImGui.SetNextWindowCollapsed then ImGui.SetNextWindowCollapsed(false, ImGuiCond.Always) end
    else
        ImGui.SetNextWindowSize(320, 450, ImGuiCond.FirstUseEver)
    end
    -- If requested, just uncollapse without resetting position/size
    if lootUI.uncollapsePeerCommandsOnNextOpen and ImGui.SetNextWindowCollapsed then
        ImGui.SetNextWindowCollapsed(false, ImGuiCond.Always)
    end
    
    -- Ensure we track ImGui's notion of the open state separately
    if lootUI.peerCommandsOpen == nil then
        lootUI.peerCommandsOpen = lootUI.showPeerCommands ~= false
    end

    -- Only draw if we want it open
    if not lootUI.peerCommandsOpen then
        return
    end

    -- Pass the tracked open state into ImGui so the close button can update it
    local windowOpen, p_open = ImGui.Begin("Peer Commands", lootUI.peerCommandsOpen)
    lootUI.peerCommandsOpen = p_open ~= false
    local isCollapsed = ImGui.IsWindowCollapsed and ImGui.IsWindowCollapsed() or false
    -- Clear one-shot flags after creating the window
    if lootUI.resetPeerCommandsWindow then lootUI.resetPeerCommandsWindow = false end
    if lootUI.uncollapsePeerCommandsOnNextOpen then lootUI.uncollapsePeerCommandsOnNextOpen = false end
    if windowOpen then
        local peerList = util.getConnectedPeers()
        
        if #peerList > 0 then
            -- Header section with styled text
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)  -- Yellowish header
            ImGui.Text("Connected Peers: " .. #peerList)
            ImGui.PopStyleColor()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Peer selection section
            ImGui.Text("Select Target Peer:")
            if lootUI.selectedPeer == "" and #peerList > 0 then
                lootUI.selectedPeer = peerList[1]
            end
            
            ImGui.SetNextItemWidth(-1) -- Full width
            if ImGui.BeginCombo("##PeerSelect", lootUI.selectedPeer) then
                for i, peer in ipairs(peerList) do
                    local selected = (lootUI.selectedPeer == peer)
                    if ImGui.Selectable(peer, selected) then
                        lootUI.selectedPeer = peer
                    end
                    if selected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Select a connected peer to send commands to")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
                        
            local buttonWidth = (ImGui.GetContentRegionAvail() - 10) / 2 -- Two buttons per row with spacing
            
            -- Add rounded edges to all buttons
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            
            -- Row 1: Loot and Pause
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.8, 0.8)  -- Blue for Loot
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.9, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.7, 0.9)
            if ImGui.Button("Peer Loot", buttonWidth, 30) then
                if util.sendPeerCommandViaActor(lootUI.selectedPeer, "start_once") then
                    logging.log("Sent loot command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Sent loot command to " .. lootUI.selectedPeer, "success")
                else
                    logging.log("Failed to send loot command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to send command to " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Trigger the selected peer to loot corpses")
            end
            
            ImGui.SameLine()
            
            -- Dynamic button text and colors
            local buttonText = (lootUI.peerTriggerPaused or false) and "Resume" or "Pause"
            local isPaused = lootUI.peerTriggerPaused or false

            if isPaused then
                -- Dark red for paused state
                ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)        -- Dark red
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.3, 0.3, 0.9)  -- Lighter red on hover
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 0.9)   -- Darker red when pressed
            else
                -- Yellow for active state
                ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.6, 0.2, 0.8)        -- Yellow
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.7, 0.3, 0.9)  -- Lighter yellow on hover
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.5, 0.1, 0.9)   -- Darker yellow when pressed
            end

            if ImGui.Button(buttonText, buttonWidth, 30) then
                local action = isPaused and "off" or "on"
                if util.sendPeerCommandViaActor(lootUI.selectedPeer, "pause", { action = action }) then
                    lootUI.peerTriggerPaused = not isPaused
                    local status = lootUI.peerTriggerPaused and "paused" or "resumed"
                    logging.log("Sent pause command to peer: " .. lootUI.selectedPeer .. " (" .. status .. ")")
                    util.printSmartLoot("Peer " .. lootUI.selectedPeer .. " " .. status, lootUI.peerTriggerPaused and "warning" or "info")
                else
                    logging.log("Failed to send pause command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to send pause command to " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Pause/Resume SmartLoot on the selected peer")
            end
            
            ImGui.Spacing()
            
            -- Row 2: Resume and Clear Cache
            -- Dynamic button text and colors based on chase state
            local buttonText = (lootUI.chasePaused or false) and "Resume Chase" or "Pause Chase"
            local isChasePaused = lootUI.chasePaused or false

            if isChasePaused then
                -- Green for resume
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.9)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.9)
            else
                -- Red for pause
                ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.2, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.3, 0.3, 0.9)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.1, 0.1, 0.9)
            end

            if ImGui.Button(buttonText, buttonWidth, 30) then
                local action = isChasePaused and "resume" or "pause"
                local success, message = config.executeChaseCommand(action)
                
                if success then
                    -- Toggle the CHASE state, not peer trigger state
                    lootUI.chasePaused = not isChasePaused
                    logging.log("Chase command executed: " .. message)
                    util.printSmartLoot("Chase " .. action .. "d", action == "pause" and "warning" or "success")
                else
                    logging.log("Failed to execute chase command: " .. message)
                    util.printSmartLoot("Chase command failed: " .. message, "error")
                end
            end
            ImGui.PopStyleColor(3)

            if ImGui.IsItemHovered() then
                local tooltipText = isChasePaused and "Resume chase mode" or "Pause chase mode"
                ImGui.SetTooltip(tooltipText)
            end
            
            ImGui.SameLine()
            
            ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.6, 0.8, 0.8)  -- Purple for Clear Cache
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.7, 0.9, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.5, 0.7, 0.9)
            if ImGui.Button("Clear Cache", buttonWidth, 30) then
                if util.sendPeerCommandViaActor(lootUI.selectedPeer, "clear_cache") then
                    logging.log("Sent cache clear command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Cleared cache on " .. lootUI.selectedPeer, "success")
                else
                    logging.log("Failed to send cache clear command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to clear cache on " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Clear processed corpse cache on the selected peer")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
                        
            -- NEW: Conditional Emergency Stop All (only in RGMain mode)
            local currentMode = SmartLootEngine.getLootMode()
            if currentMode == SmartLootEngine.LootMode.RGMain then
                -- Emergency actions section
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.3, 0.3, 1.0)  -- Reddish header
                ImGui.Text("Emergency Actions:")
                ImGui.PopStyleColor()
                ImGui.Spacing()
                
                local fullWidth = ImGui.GetContentRegionAvail()
                
                ImGui.PushStyleColor(ImGuiCol.Button, 0.9, 0.1, 0.1, 0.9)  -- Bright red for emergency
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1.0, 0.2, 0.2, 1.0)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.8, 0.0, 0.0, 1.0)
                if ImGui.Button("EMERGENCY STOP ALL", fullWidth, 40) then
                    -- Confirmation prompt
                    ImGui.OpenPopup("Confirm Emergency Stop")
                end
                ImGui.PopStyleColor(3)
                
                -- Confirmation popup
                if ImGui.BeginPopup("Confirm Emergency Stop") then
                    ImGui.Text("Are you sure you want to emergency stop ALL peers?")
                    ImGui.Text("This will halt all SmartLoot activity immediately.")
                    ImGui.Spacing()
                    if ImGui.Button("Yes, Stop All", 120, 0) then
                        if util.broadcastCommandViaActor("emergency_stop") then
                            logging.log("Broadcasted emergency stop to all peers via actor")
                            util.printSmartLoot("Emergency stop sent to all peers", "error")
                        else
                            logging.log("Failed to broadcast emergency stop via actor")
                            util.printSmartLoot("Failed to emergency stop all peers", "error")
                        end
                        ImGui.CloseCurrentPopup()
                    end
                    ImGui.SameLine()
                    if ImGui.Button("Cancel", 120, 0) then
                        ImGui.CloseCurrentPopup()
                    end
                    ImGui.EndPopup()
                end
                
                -- Emergency stop tooltip
                if ImGui.IsItemHovered() then
                    ImGui.BeginTooltip()
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.6, 0.6, 1.0)
                    ImGui.Text("EMERGENCY STOP")
                    ImGui.PopStyleColor()
                    ImGui.Separator()
                    ImGui.Text("Immediately halts all SmartLoot activity")
                    ImGui.Text("on all connected peers.")
                    ImGui.Spacing()
                    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.2, 1.0)
                    ImGui.Text("Use /sl_resume to restart after emergency stop")
                    ImGui.PopStyleColor()
                    ImGui.EndTooltip()
                end
            end
            
            -- Pop the rounding style at the end
            ImGui.PopStyleVar()
            
            ImGui.Spacing()
        else
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.3, 0.3, 1.0)  -- Red for no peers
            ImGui.Text("No connected peers found")
            ImGui.PopStyleColor()
        end
    end
    
    ImGui.End()
    
    -- Handle the close button (X) in the window header
    -- p_open will be false if the user clicked the X button
    -- Some docking setups report close by returning windowOpen == false without toggling p_open,
    -- so also treat a hidden-but-not-collapsed window as closed.
    local requestedClose = (p_open == false) or (windowOpen == false and not isCollapsed)
    if requestedClose then
        lootUI.peerCommandsOpen = false
        lootUI.showPeerCommands = false
        config.uiVisibility.showPeerCommands = false
        if config.save then config.save() end
    end
end

return uiPeerCommands
