local mq = require("mq")
local ImGui = require("ImGui")
local Icons = require("mq.Icons")
local json = require("dkjson")
local util = require("modules.util")
local database = require("modules.database")

local uiDirectedAssign = {}

uiDirectedAssign.state = {
    isOpen = false,
    assignments = {},  -- keyed by index of candidate: {peerName = "", quantity = n}
    peers = {},        -- cached connected peers
    lastPeerRefresh = 0,
}

local function refreshPeers()
    local now = mq.gettime()
    if now - (uiDirectedAssign.state.lastPeerRefresh or 0) > 2000 then
        -- Get peers from SmartLoot's util function
        uiDirectedAssign.state.peers = util.getConnectedPeers()
        
        -- Fallback: try to get peers from group/raid if util fails
        if #uiDirectedAssign.state.peers == 0 then
            local fallbackPeers = {}
            
            -- Try group members
            local groupSize = mq.TLO.Group.Members() or 0
            for i = 1, groupSize do
                local member = mq.TLO.Group.Member(i)
                if member and member.Name() then
                    local name = member.Name()
                    if name ~= mq.TLO.Me.Name() then
                        table.insert(fallbackPeers, name)
                    end
                end
            end
            
            -- Try raid members if no group
            if #fallbackPeers == 0 then
                local raidSize = mq.TLO.Raid.Members() or 0
                for i = 1, raidSize do
                    local member = mq.TLO.Raid.Member(i)
                    if member and member.Name() then
                        local name = member.Name()
                        if name ~= mq.TLO.Me.Name() then
                            table.insert(fallbackPeers, name)
                        end
                    end
                end
            end
            
            uiDirectedAssign.state.peers = fallbackPeers
        end
        
        uiDirectedAssign.state.lastPeerRefresh = now
    end
end

-- Build payload from selections
local function buildDirectedTasks(candidates, assignments)
    local perPeer = {}
    for idx, sel in pairs(assignments) do
        if sel.peerName and sel.peerName ~= "" then
            perPeer[sel.peerName] = perPeer[sel.peerName] or {}
            local c = candidates[idx]
            table.insert(perPeer[sel.peerName], {
                corpseSpawnID = c.corpseSpawnID,
                itemName = c.itemName,
                itemID = c.itemID,
                iconID = c.iconID,
                quantity = c.quantity or 1,
            })
        end
    end
    return perPeer
end

-- Broadcast tasks to peers
local function broadcastDirectedTasks(perPeerTasks)
    for peer, tasks in pairs(perPeerTasks) do
        local ok, payload = pcall(json.encode, tasks)
        if ok then
            -- Use Dannet/tells via command, since actors may not be cross-server
            mq.cmdf("/dex %s /sl_directed_tasks '%s'", peer, payload)
            util.printSmartLoot("Sent directed tasks to " .. peer, "info")
        else
            util.printSmartLoot("Failed to encode tasks for " .. peer .. ": " .. tostring(payload), "error")
        end
    end
end

function uiDirectedAssign.draw(SmartLootEngine)
    if not SmartLootEngine then return end
    if not SmartLootEngine.shouldShowDirectedAssignment or not SmartLootEngine.shouldShowDirectedAssignment() then
        return
    end

    local candidates = SmartLootEngine.getDirectedCandidates and SmartLootEngine.getDirectedCandidates() or {}
    if #candidates == 0 then
        return
    end

    -- Ensure peers list is populated before rendering
    refreshPeers()

    ImGui.SetNextWindowSize(600, 420, ImGuiCond.FirstUseEver)
    local open, _ = ImGui.Begin("SmartLoot Directed Assignment", true)
    if not open then
        SmartLootEngine.setDirectedAssignmentVisible(false)
        ImGui.End()
        return
    end

    ImGui.Text(Icons.FA_USERS .. " Assign ignored/left items from this session to connected peers")
    ImGui.Separator()

    -- Create scrollable child region for the table
    if ImGui.BeginChild("AssignmentList", 0, -50) then
        if ImGui.BeginTable("DirectedAssignTable", 3, ImGuiTableFlags.Borders) then
            -- Setup columns with explicit widths
            ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthFixed, 200)
            ImGui.TableSetupColumn("Corpse", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Assign To", ImGuiTableColumnFlags.WidthFixed, 150)
            ImGui.TableHeadersRow()

            for i, c in ipairs(candidates) do
                ImGui.TableNextRow()
                
                -- Item column
                ImGui.TableNextColumn()
                ImGui.Text(c.itemName)
                
                -- Corpse column
                ImGui.TableNextColumn()
                ImGui.Text(string.format("%s (%d)", c.corpseName or "Corpse", c.corpseSpawnID or 0))
                
                -- Assign To column
                ImGui.TableNextColumn()
                uiDirectedAssign.state.assignments[i] = uiDirectedAssign.state.assignments[i] or { peerName = "", quantity = c.quantity or 1 }
                local sel = uiDirectedAssign.state.assignments[i]

                -- Peer combo - fill column width
                ImGui.SetNextItemWidth(-1)
                local currentPeer = (sel.peerName and sel.peerName ~= "") and sel.peerName or "<select>"
                if ImGui.BeginCombo("##peer_" .. i, currentPeer) then
                    if ImGui.Selectable("<none>", sel.peerName == "") then
                        sel.peerName = ""
                    end
                    
                    -- Fetch peers for this frame to ensure it's populated
                    local peers = uiDirectedAssign.state.peers or {}
                    if #peers == 0 then
                        peers = util.getConnectedPeers() or {}
                        uiDirectedAssign.state.peers = peers
                    end

                    for idx, p in ipairs(peers) do
                        local label = tostring(p)
                        local selected = (sel.peerName ~= "" and sel.peerName:lower() == label:lower())
                        if ImGui.Selectable(label, selected) then
                            sel.peerName = label
                        end
                    end
                    ImGui.EndCombo()
                end
            end
            
            ImGui.EndTable()
        end
        ImGui.EndChild()
    end

    ImGui.Separator()

    -- Action buttons
    if ImGui.Button(Icons.FA_PAPER_PLANE .. " Execute Assignments") then
        local perPeer = buildDirectedTasks(candidates, uiDirectedAssign.state.assignments)
        if next(perPeer) ~= nil then
            broadcastDirectedTasks(perPeer)
            -- Clear assigned candidates so the UI doesn't re-open with old items
            if SmartLootEngine and SmartLootEngine.clearDirectedCandidates then
                SmartLootEngine.clearDirectedCandidates()
            end
            -- Reset UI state and hide
            uiDirectedAssign.state.assignments = {}
            SmartLootEngine.setDirectedAssignmentVisible(false)
            util.printSmartLoot("Directed tasks broadcasted to peers", "success")
        else
            util.printSmartLoot("No assignments selected", "warning")
        end
    end

    ImGui.SameLine()
    if ImGui.Button(Icons.FA_TIMES .. " Close") then
        SmartLootEngine.setDirectedAssignmentVisible(false)
    end

    ImGui.End()
end

return uiDirectedAssign
