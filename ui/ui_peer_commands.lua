-- ui_peer_commands.lua (Enhanced with prettier UI and conditional Emergency Stop All)
local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local SmartLootEngine = require("modules.SmartLootEngine")  -- NEW: For mode check

local uiPeerCommands = {}

function uiPeerCommands.draw(lootUI, loot, util)
    -- Set consistent window properties
    ImGui.SetNextWindowBgAlpha(0.85)
    ImGui.SetNextWindowSize(320, 450, ImGuiCond.FirstUseEver)
    
    local open, shouldClose = ImGui.Begin("Peer Commands", true, ImGuiWindowFlags.None)
    if open then
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
            
            -- Individual peer commands section
            ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1.0)  -- Green section header
            ImGui.Text("Individual Commands:")
            ImGui.PopStyleColor()
            
            local buttonWidth = (ImGui.GetContentRegionAvail() - 10) / 2 -- Two buttons per row with spacing
            
            -- Add rounded edges to all buttons
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            
            -- Row 1: Loot and Pause
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.8, 0.8)  -- Blue for Loot
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.9, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.7, 0.9)
            if ImGui.Button("Send Loot", buttonWidth, 30) then
                if util.sendPeerCommand(lootUI.selectedPeer, "/sl_doloot") then
                    logging.log("Sent loot command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Sent loot command to " .. lootUI.selectedPeer, "success")
                else
                    logging.log("Failed to send loot command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to send command to " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Trigger a one-time loot on the selected peer")
            end
            
            ImGui.SameLine()
            
            ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.6, 0.2, 0.8)  -- Yellow for Pause
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.7, 0.3, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.5, 0.1, 0.9)
            if ImGui.Button("Pause", buttonWidth, 30) then
                if util.sendPeerCommand(lootUI.selectedPeer, "/sl_pause on") then
                    logging.log("Sent pause command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Paused " .. lootUI.selectedPeer, "warning")
                else
                    logging.log("Failed to send pause command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to pause " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Pause SmartLoot on the selected peer")
            end
            
            ImGui.Spacing()
            
            -- Row 2: Resume and Clear Cache
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)  -- Green for Resume
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.9)
            if ImGui.Button("Resume", buttonWidth, 30) then
                if util.sendPeerCommand(lootUI.selectedPeer, "/sl_pause off") then
                    logging.log("Sent resume command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Resumed " .. lootUI.selectedPeer, "success")
                else
                    logging.log("Failed to send resume command to peer: " .. lootUI.selectedPeer)
                    util.printSmartLoot("Failed to resume " .. lootUI.selectedPeer, "error")
                end
            end
            ImGui.PopStyleColor(3)
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Resume SmartLoot on the selected peer")
            end
            
            ImGui.SameLine()
            
            ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.6, 0.8, 0.8)  -- Purple for Clear Cache
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.7, 0.9, 0.9)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.5, 0.7, 0.9)
            if ImGui.Button("Clear Cache", buttonWidth, 30) then
                mq.cmd('/sl_clearcache')
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
                
                -- Confirmation modal
                if ImGui.BeginPopupModal("Confirm Emergency Stop", nil, ImGuiWindowFlags.AlwaysAutoResize) then
                    ImGui.Text("Are you sure you want to emergency stop ALL peers?")
                    ImGui.Text("This will halt all SmartLoot activity immediately.")
                    ImGui.Spacing()
                    if ImGui.Button("Yes, Stop All", 120, 0) then
                        if util.broadcastCommand("/sl_emergency_stop") then
                            logging.log("Broadcasted emergency stop to all peers")
                            util.printSmartLoot("Emergency stop sent to all peers", "error")
                        else
                            logging.log("Failed to broadcast emergency stop")
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
        
        ImGui.End()
    end
    
    if shouldClose == false then
        lootUI.showPeerCommands = true
    end
end

return uiPeerCommands