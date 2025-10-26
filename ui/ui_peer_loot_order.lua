local mq = require("mq")
local ImGui = require("ImGui")
local uiUtils = require("ui.ui_utils")
local config = require("modules.config")
local util = require("modules.util")

local uiPeerLootOrder = {}

function uiPeerLootOrder.draw(lootUI, config, util)
    if ImGui.BeginTabItem("Peer Loot Order") then
        -- Display current server information
        local currentServer = mq.TLO.EverQuest.Server()
        ImGui.TextColored(0.2, 0.8, 0.2, 1.0, "Server: " .. currentServer)
        ImGui.Text("Configure the order in which peers are triggered for looting on this server")
        
        -- Debug section at the top (expanded by default if no peers are found)
        local connectedPeers = util.getConnectedPeers()
        local showDebugByDefault = (#connectedPeers == 0)
        
        if ImGui.CollapsingHeader("Peer Discovery Debug", showDebugByDefault and ImGuiTreeNodeFlags.DefaultOpen or 0) then
            ImGui.TextColored(0.0, 1.0, 1.0, 1.0, "Peer Discovery Method: Actor Mailbox (Heartbeat-based)")
            ImGui.TextWrapped("SmartLoot now uses an actor-based presence system. Peers broadcast heartbeats every 5 seconds.")
            ImGui.Separator()
            
            -- Show actor presence status
            local presence = _G.SMARTLOOT_PRESENCE
            if presence then
                ImGui.TextColored(0.0, 1.0, 0.0, 1.0, "Actor Presence System: Active")
                ImGui.Text("Heartbeat Interval: " .. tostring(presence.heartbeatInterval) .. " seconds")
                ImGui.Text("Stale Threshold: " .. tostring(presence.staleAfter) .. " seconds")
                
                -- Show raw peer data
                if presence.peers then
                    local peerCount = 0
                    for _ in pairs(presence.peers) do peerCount = peerCount + 1 end
                    ImGui.Text("Active Peer Entries: " .. tostring(peerCount))
                    
                    if peerCount > 0 then
                        ImGui.Spacing()
                        ImGui.Text("Raw Peer Data:")
                        local now = os.time()
                        for peerName, entry in pairs(presence.peers) do
                            local age = now - (entry.lastSeen or 0)
                            local color = age <= presence.staleAfter and {0, 1, 0, 1} or {1, 0.5, 0, 1}
                            ImGui.TextColored(color[1], color[2], color[3], color[4], 
                                string.format("  %s (last seen: %ds ago, mode: %s)", 
                                    peerName, age, entry.mode or "unknown"))
                        end
                    end
                end
            else
                ImGui.TextColored(1.0, 0.0, 0.0, 1.0, "Actor Presence System: Not Available")
            end
            
            ImGui.Separator()
            ImGui.Text("Discovered Peers Count: " .. tostring(#connectedPeers))
            if #connectedPeers > 0 then
                ImGui.Text("Discovered Peers: " .. table.concat(connectedPeers, ", "))
            else
                ImGui.TextColored(1.0, 0.5, 0.0, 1.0, "No peers discovered!")
                ImGui.TextWrapped("If you expect to see peers here:")
                ImGui.BulletText("Ensure other SmartLoot instances are running")
                ImGui.BulletText("Wait up to 5 seconds for heartbeats to be received")
                ImGui.BulletText("Check that the actor system is working correctly")
            end
            
            ImGui.Spacing()
            if ImGui.Button("Show Legacy Discovery (DanNet/EQBC/E3)") then
                local legacyPeers = util.getConnectedPeersLegacy()
                if #legacyPeers > 0 then
                    util.printSmartLoot("Legacy Discovery Found: " .. table.concat(legacyPeers, ", "), "info")
                else
                    util.printSmartLoot("No peers found via legacy discovery", "warning")
                end
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Test legacy DanNet/EQBC/E3 peer discovery (for debugging)")
            end
        end
        
        ImGui.Separator()

        -- Display current order
        ImGui.Text("Current Loot Order:")

        -- Get the list of connected peers
        local connectedPeersMap = {}
        for _, peer in ipairs(connectedPeers) do
            connectedPeersMap[peer] = true
        end

        -- Create a copy of the current order for UI operations, ensuring it's from the current server
        if not lootUI.peerOrderList then
            lootUI.peerOrderList = {}
            local currentOrder = config.getPeerOrder()
            
            if #currentOrder > 0 then
                for _, peer in ipairs(currentOrder) do
                    table.insert(lootUI.peerOrderList, peer)
                end
            else
                -- Default to currently connected peers if no order is saved
                for _, peer in ipairs(connectedPeers) do
                    table.insert(lootUI.peerOrderList, peer)
                end
                if #lootUI.peerOrderList > 0 then
                    config.savePeerOrder(lootUI.peerOrderList)
                end
            end
        end

        -- Create a table for the peer order
        if ImGui.BeginTable("PeerOrderTable", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
            ImGui.TableSetupColumn("Order", ImGuiTableColumnFlags.WidthFixed, 50)
            ImGui.TableSetupColumn("Peer Name", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthFixed, 80)
            ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 150)
            ImGui.TableHeadersRow()

            if #lootUI.peerOrderList == 0 then
                -- Show a message if no peers are in the order
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                ImGui.Text("")
                ImGui.TableNextColumn()
                ImGui.TextColored(0.7, 0.7, 0.7, 1.0, "No peers in loot order")
                ImGui.TableNextColumn()
                ImGui.Text("")
                ImGui.TableNextColumn()
                ImGui.Text("")
            else
                -- Display the ordered peers
                for i, peer in ipairs(lootUI.peerOrderList) do
                    ImGui.TableNextRow()

                    -- Column 1: Order number
                    ImGui.TableNextColumn()
                    ImGui.Text(tostring(i))

                    -- Column 2: Peer name
                    ImGui.TableNextColumn()
                    ImGui.Text(peer)

                    -- Column 3: Status (highlighted if connected)
                    ImGui.TableNextColumn()
                    if connectedPeersMap[peer] then
                        ImGui.TextColored(0, 1, 0, 1, "Online")
                    else
                        ImGui.TextColored(0.7, 0.7, 0.7, 1, "Offline")
                    end

                    -- Column 4: Move up/down/remove buttons with icons
                    ImGui.TableNextColumn()
                    if i > 1 then
                        if ImGui.Button(uiUtils.UI_ICONS.UP_ARROW .. "##" .. i) then
                            local temp = lootUI.peerOrderList[i-1]
                            lootUI.peerOrderList[i-1] = lootUI.peerOrderList[i]
                            lootUI.peerOrderList[i] = temp
                            config.savePeerOrder(lootUI.peerOrderList)
                        end
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Move Up")
                        end
                        ImGui.SameLine()
                    else
                        ImGui.Dummy(23, 0)  -- Placeholder for button space
                        ImGui.SameLine()
                    end

                    if i < #lootUI.peerOrderList then
                        if ImGui.Button(uiUtils.UI_ICONS.DOWN_ARROW .. "##" .. i) then
                            local temp = lootUI.peerOrderList[i+1]
                            lootUI.peerOrderList[i+1] = lootUI.peerOrderList[i]
                            lootUI.peerOrderList[i] = temp
                            config.savePeerOrder(lootUI.peerOrderList)
                        end
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Move Down")
                        end
                        ImGui.SameLine()
                    else
                        ImGui.Dummy(23, 0)  -- Placeholder for button space
                        ImGui.SameLine()
                    end

                    if ImGui.Button(uiUtils.UI_ICONS.REMOVE .. "##" .. i) then
                        table.remove(lootUI.peerOrderList, i)
                        config.savePeerOrder(lootUI.peerOrderList)
                    end
                    if ImGui.IsItemHovered() then
                        ImGui.SetTooltip("Remove")
                    end
                end
            end

            ImGui.EndTable()
        end

        -- Add new peer to order
        ImGui.Separator()
        ImGui.Text("Add Peer to Order:")

        -- Get peers not in the order yet
        local availablePeers = {}
        for _, peer in ipairs(connectedPeers) do
            local found = false
            for _, orderedPeer in ipairs(lootUI.peerOrderList) do
                if peer == orderedPeer then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(availablePeers, peer)
            end
        end

        -- Show available peers section
        if #availablePeers > 0 then
            if not lootUI.selectedPeerToAdd then
                lootUI.selectedPeerToAdd = availablePeers[1]
            end

            if ImGui.BeginCombo("##SelectPeerToAdd", lootUI.selectedPeerToAdd) then
                for _, peer in ipairs(availablePeers) do
                    local isSelected = (lootUI.selectedPeerToAdd == peer)
                    if ImGui.Selectable(peer, isSelected) then
                        lootUI.selectedPeerToAdd = peer
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end

            ImGui.SameLine()
            if ImGui.Button(uiUtils.UI_ICONS.ADD .. " Add to Order") then
                table.insert(lootUI.peerOrderList, lootUI.selectedPeerToAdd)
                config.savePeerOrder(lootUI.peerOrderList)
                lootUI.selectedPeerToAdd = nil  -- Reset selection
            end
        else
            if #connectedPeers == 0 then
                ImGui.TextColored(1.0, 0.5, 0.0, 1.0, "No connected peers detected!")
                ImGui.TextWrapped("Check the debug section above for troubleshooting steps.")
            else
                ImGui.TextColored(0.0, 1.0, 0.0, 1.0, "All connected peers are already in the order")
            end
        end

        -- Manual peer addition section
        ImGui.Separator()
        ImGui.Text("Manual Peer Addition:")
        ImGui.TextWrapped("Add a peer manually (useful for offline peers or testing):")
        
        -- Manual peer input
        if not lootUI.manualPeerName then
            lootUI.manualPeerName = ""
        end
        
        ImGui.PushItemWidth(150)
        local newManualPeer, changedManualPeer = ImGui.InputText("##ManualPeerName", lootUI.manualPeerName, 64)
        if changedManualPeer then
            lootUI.manualPeerName = newManualPeer
        end
        ImGui.PopItemWidth()
        
        ImGui.SameLine()
        if ImGui.Button(uiUtils.UI_ICONS.ADD .. " Add Manual") then
            if lootUI.manualPeerName and lootUI.manualPeerName:match("%S") then
                -- Check if peer is already in the list
                local alreadyExists = false
                for _, peer in ipairs(lootUI.peerOrderList) do
                    if peer == lootUI.manualPeerName then
                        alreadyExists = true
                        break
                    end
                end
                
                if not alreadyExists then
                    table.insert(lootUI.peerOrderList, lootUI.manualPeerName)
                    config.savePeerOrder(lootUI.peerOrderList)
                    lootUI.manualPeerName = ""  -- Clear input
                end
            end
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Manually add a peer name to the loot order")
        end

        -- Button to sort peers alphabetically
        ImGui.Separator()
        if ImGui.Button(uiUtils.UI_ICONS.SORT .. " Sort Alphabetically") then
            table.sort(lootUI.peerOrderList)
            config.savePeerOrder(lootUI.peerOrderList)
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Sort the peer list alphabetically")
        end

        ImGui.SameLine()
        if ImGui.Button(uiUtils.UI_ICONS.TRASH .. " Clear Order") then
            ImGui.OpenPopup("Confirm Clear Order")
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Remove all peers from the order (for this server only)")
        end

        ImGui.SameLine()
        if ImGui.Button(uiUtils.UI_ICONS.REFRESH .. " Refresh from Config") then
            -- Force reload from config file
            lootUI.peerOrderList = {}
            local currentOrder = config.getPeerOrder()
            for i, peer in ipairs(currentOrder) do
                table.insert(lootUI.peerOrderList, peer)
            end
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Reload peer order from saved configuration")
        end

        -- Confirmation popup
        if ImGui.BeginPopup("Confirm Clear Order") then
            ImGui.Text("Are you sure you want to clear the entire loot order")
            ImGui.Text("for server: " .. currentServer .. "?")
            ImGui.Text("This will revert to alphabetical order for this server only.")

            if ImGui.Button(uiUtils.UI_ICONS.CONFIRM .. " Yes, Clear Order") then
                lootUI.peerOrderList = {}
                config.clearPeerOrder()
                ImGui.CloseCurrentPopup()
            end

            ImGui.SameLine()
            if ImGui.Button(uiUtils.UI_ICONS.CANCEL .. " Cancel") then
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        end

        -- Multi-server management section
        ImGui.Separator()
        ImGui.TextColored(0.8, 0.8, 0.0, 1.0, "Multi-Server Management:")
        
        local configuredServers = config.getConfiguredServers()
        if #configuredServers > 1 then
            ImGui.Text("Other configured servers:")
            for _, serverName in ipairs(configuredServers) do
                if serverName ~= currentServer:lower():gsub(" ", "_") then
                    local serverConfig = config.getServerConfig(serverName)
                    local peerOrder = serverConfig.peerLootOrder or {}
                    local displayName = serverName:gsub("_", " ")
                    ImGui.BulletText(displayName .. ": " .. (#peerOrder > 0 and table.concat(peerOrder, ", ") or "(no order set)"))
                end
            end
        else
            ImGui.Text("Only " .. currentServer .. " is configured")
        end

        -- Config debug section (collapsible)
        if ImGui.CollapsingHeader("Configuration Debug") then
            if ImGui.Button("Show Config Debug") then
                config.debugPrint()
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Print configuration debug info to console")
            end
            
            ImGui.SameLine()
            if ImGui.Button("Migrate Legacy Config") then
                local success, message = config.migrateFromLegacy()
                if success then
                    printf("[Config] %s", message)
                else
                    printf("[Config] Migration not needed: %s", message)
                end
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Migrate from old single-server configuration format")
            end
        end

        -- Help text
        ImGui.Separator()
        ImGui.TextColored(0.8, 0.8, 0.0, 1.0, uiUtils.UI_ICONS.INFO .. " How this works:")
        ImGui.TextWrapped("When an item is left on a corpse, the system will try to trigger peers in the order listed above. Only online peers with a loot rule other than 'Ignore' for the specific item will be triggered.")
        ImGui.TextColored(0.7, 0.7, 0.7, 1.0, "Note: Peer loot order is saved per-server. Each server you play on will have its own independent peer order.")

        ImGui.EndTabItem()
    end
end

return uiPeerLootOrder