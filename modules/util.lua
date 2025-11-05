local util = {}
local mq = require("mq")
local config = require("modules.config")   -- Load the config module

function util.printSmartLoot(message, msgType)
    printf('[SmartLoot] %s', message)
end

-- **Get Peers Dynamically Based on Selected Command Type**

local mq2monoLoaded = mq.TLO.Plugin("MQ2Mono").IsLoaded()

-- Helper function to normalize peer names to proper case
local function normalizePeerName(peerName)
    if not peerName or peerName == "" then
        return peerName
    end
    
    -- Convert to lowercase, then capitalize first letter
    local normalized = peerName:lower()
    normalized = normalized:sub(1,1):upper() .. normalized:sub(2)
    
    return normalized
end

-- Actor-based peer discovery using presence heartbeats
function util.getConnectedPeersViaActor()
    local peers = {}
    
    -- Access the global presence tracker
    local presence = _G.SMARTLOOT_PRESENCE
    if not presence or not presence.peers then
        return peers
    end
    
    local now = os.time()
    local staleAfter = presence.staleAfter or 12
    
    -- Get all peers that have sent a heartbeat recently
    for peerName, entry in pairs(presence.peers) do
        if entry.lastSeen and (now - entry.lastSeen) <= staleAfter then
            table.insert(peers, peerName)
        end
    end
    
    -- Include the local peer (self) in the list
    local myName = mq.TLO.Me.Name()
    if myName and myName ~= "" then
        table.insert(peers, myName)
    end
    
    -- Sort alphabetically
    table.sort(peers, function(a, b) return a < b end)
    
    return peers
end

-- Legacy peer discovery via DanNet/EQBC/E3 (kept for backward compatibility)
function util.getConnectedPeersLegacy()
    local peers = {}
    
    -- Convert config value to lowercase for consistent comparison
    local lootType = (config.lootCommandType or ""):lower()
    
    if lootType == "dannet" then
        -- Use DanNet to get connected peers
        local peersStr = mq.TLO.DanNet.Peers()
        if peersStr then
            -- DanNet.Peers() returns a pipe-separated list of peers
            for peer in string.gmatch(peersStr, "([^|]+)") do
                -- Trim whitespace and add to list
                peer = peer:match("^%s*(.-)%s*$")
                if peer and peer ~= "" then
                    peer = normalizePeerName(peer)
                    table.insert(peers, peer)
                end
            end
        end
        
    elseif lootType == "e3" and mq2monoLoaded then
        -- Use MQ2Mono to get connected E3 peers
        local peersStr = mq.TLO.MQ2Mono.Query("e3,E3Bots.ConnectedClients")()
        if peersStr then
            for peer in string.gmatch(peersStr, "([^,]+)") do
                peer = peer:match("^%s*(.-)%s*$") -- Trim whitespace
                if peer and peer ~= "" then
                    -- Normalize to proper case
                    peer = normalizePeerName(peer)
                    table.insert(peers, peer)
                end
            end
        end
        
    elseif lootType == "bc" then
        -- Use EQBC to get connected peers (check if plugin is loaded first)
        if mq.TLO.EQBC then
            local peersStr = mq.TLO.EQBC.Names()
            if peersStr then
                for peer in string.gmatch(peersStr, "([^%s,]+)") do
                    peer = peer:match("^%s*(.-)%s*$") -- Trim whitespace
                    if peer and peer ~= "" then
                        -- Normalize to proper case
                        peer = normalizePeerName(peer)
                        table.insert(peers, peer)
                    end
                end
            end
        -- Note: Don't spam warnings about EQBC not loaded
        end
    end
    
    -- Ensure list is sorted and remove duplicates
    local uniquePeers = {}
    local seen = {}
    for _, peer in ipairs(peers) do
        if not seen[peer] then
            seen[peer] = true
            table.insert(uniquePeers, peer)
        end
    end

    table.sort(uniquePeers, function(a, b) return a < b end)
    return uniquePeers
end

-- Main peer discovery function - uses actor-based presence by default
function util.getConnectedPeers()
    -- Use actor-based presence detection
    return util.getConnectedPeersViaActor()
end

-- Helper function to check if DanNet is available and loaded
function util.isDanNetAvailable()
    return mq.TLO.Plugin("MQ2DanNet").IsLoaded()
end

-- Helper function to check if a specific peer is connected via DanNet
function util.isDanNetPeerConnected(peerName)
    if not util.isDanNetAvailable() then
        return false
    end
    
    local peers = util.getConnectedPeers()
    for _, peer in ipairs(peers) do
        if peer == peerName then
            return true
        end
    end
    return false
end

-- Helper function to send a command via the configured communication method (LEGACY)
function util.sendPeerCommand(peerName, command)
    -- Convert config value to lowercase for consistent comparison
    local lootType = (config.lootCommandType or ""):lower()
    
    -- Debug output to help troubleshoot
    --util.printSmartLoot(string.format("Debug: Sending command '%s' to '%s' using type '%s' (raw: '%s')", command, peerName, lootType, config.lootCommandType or "nil"), "debug")
    
    if lootType == "dannet" then
        -- Send command via DanNet using /dex
        if util.isDanNetPeerConnected(peerName) then
            mq.cmdf("/dex %s %s", peerName, command)
            return true
        else
            util.printSmartLoot("DanNet peer " .. peerName .. " is not connected", "error")
            return false
        end
        
    elseif lootType == "e3" then
        -- Send command via E3
        mq.cmdf("/e3bct %s %s", peerName, command)
        return true
        
    elseif lootType == "bc" then
        -- Send command via EQBC (check if plugin is loaded first)
        if mq.TLO.EQBC then
            mq.cmdf("/bct %s //%s", peerName, command)
            return true
        else
            util.printSmartLoot("EQBC plugin not loaded - cannot send command to " .. peerName, "error")
            return false
        end
    end
    
    util.printSmartLoot("Unknown loot command type: " .. tostring(config.lootCommandType), "error")
    return false
end

-- Actor-based peer command - sends via mailbox system
function util.sendPeerCommandViaActor(peerName, commandType, args)
    local actors = require("actors")
    local json = require("dkjson")
    
    args = args or {}
    
    local success, err = pcall(function()
        actors.send(
            { mailbox = "smartloot_command" },
            { type = "command", command = commandType, args = args, target = peerName }
        )
    end)
    
    if not success then
        util.printSmartLoot(string.format("Failed to send command to %s: %s", peerName, tostring(err)), "error")
        return false
    end
    
    return true
end

-- Actor-based broadcast command - sends to all peers via mailbox
function util.broadcastCommandViaActor(commandType, args)
    local actors = require("actors")
    local json = require("dkjson")
    
    args = args or {}
    
    -- Broadcast via smartloot_command mailbox (no target means everyone receives it)
    local success, err = pcall(function()
        actors.send(
            { mailbox = "smartloot_command" },
            { type = "command", command = commandType, args = args, target = nil }
        )
    end)
    
    if not success then
        util.printSmartLoot(string.format("Failed to broadcast command: %s", tostring(err)), "error")
        return false
    end
    
    return true
end

-- Broadcast rules reload to all peers via actor mailbox
function util.broadcastRulesReload()
    return util.broadcastCommandViaActor("reload_rules", {})
end

-- Helper function to broadcast a command to all connected peers
function util.broadcastCommand(command)
    -- Convert config value to lowercase for consistent comparison
    local lootType = (config.lootCommandType or ""):lower()
    
    if lootType == "dannet" then
        -- Broadcast via DanNet using the selected group or raid channel
        local channel = (config.dannetBroadcastChannel or "group")
        local prefix = channel == "raid" and "/dgra" or "/dgga"
        mq.cmdf("%s %s", prefix, command)
        return true
        
    elseif lootType == "e3" then
        -- Broadcast via E3
        mq.cmdf("/e3bcaa %s", command)
        return true
        
    elseif lootType == "bc" then
        -- Broadcast via EQBC (check if plugin is loaded first)
        if mq.TLO.EQBC then
            mq.cmdf("/bcaa //%s", command)
            return true
        else
            util.printSmartLoot("EQBC plugin not loaded - cannot broadcast command", "error")
            return false
        end
    end
    
    util.printSmartLoot("Unknown loot command type: " .. tostring(config.lootCommandType), "error")
    return false
end

function util.getCurrentToon()
    return mq.TLO.Me.Name() or "unknown"
end

-- Get the name of the character that is currently /foreground
function util.getForegroundCharacter()
    -- Check if this character is foreground
    if mq.TLO.MacroQuest.Foreground() then
        return mq.TLO.Me.Name()
    end
    
    -- If not, we can't directly detect who is foreground from this session
    -- Return nil to indicate we're not foreground
    return nil
end

-- Check if current character is foreground
function util.isForeground()
    return mq.TLO.MacroQuest.Foreground() == true
end

-- Debug function to show peer discovery information
function util.debugPeerDiscovery()
    print("=== SmartLoot Peer Discovery Debug ===")
    print("Loot Command Type: " .. tostring(config.lootCommandType))
    
    local lootType = (config.lootCommandType or ""):lower()
    
    if lootType == "dannet" then
        print("DanNet Plugin Loaded: " .. tostring(util.isDanNetAvailable()))
        if util.isDanNetAvailable() then
            local rawPeers = mq.TLO.DanNet.Peers()
            print("Raw DanNet Peers String: " .. tostring(rawPeers))
        end
    elseif lootType == "e3" then
        print("MQ2Mono Plugin Loaded: " .. tostring(mq2monoLoaded))
        if mq2monoLoaded then
            local rawPeers = mq.TLO.MQ2Mono.Query("e3,E3Bots.ConnectedClients")()
            print("Raw E3 Peers String: " .. tostring(rawPeers))
        end
    elseif lootType == "bc" then
        print("EQBC Plugin Loaded: " .. tostring(mq.TLO.EQBC ~= nil))
        if mq.TLO.EQBC then
            local rawPeers = mq.TLO.EQBC.Names()
            print("Raw EQBC Peers String: " .. tostring(rawPeers))
        else
            print("EQBC plugin not loaded - cannot get peer names")
        end
    end
    
    local peers = util.getConnectedPeers()
    print("Discovered Peers: " .. (#peers > 0 and table.concat(peers, ", ") or "(none)"))
end

function util.sendChatMessage(message, messageType)
    util.printSmartLoot(message, messageType)
end

function util.sendGroupMessage(message)
    if config and config.sendChatMessage then
        config.sendChatMessage(message)
    else
        mq.cmdf('/g %s', message)
    end
end

-- Create an item link using mq.TLO.Corpse.Item.ItemLink for clickable item links in chat
function util.createItemLink(itemName, itemID, corpseSlot)
    if not itemName or itemName == "" then
        return ""
    end
    
    -- Try to create a proper item link using Corpse.Item.ItemLink if we have a corpse slot
    -- Wrap in pcall to prevent crashes
    if corpseSlot then
        local success, itemLink = pcall(function()
            local corpseItem = mq.TLO.Corpse.Item(corpseSlot)
            if corpseItem and corpseItem.ItemLink then
                return corpseItem.ItemLink()
            end
            return nil
        end)
        
        if success and itemLink and itemLink ~= "" then
            -- Format the raw link data for chat display with \x12 delimiters
            return string.format("\x12%s\x12", itemLink)
        end
    end
    
    -- Fallback: try using mq.TLO.Item if we have an itemID
    if itemID and itemID > 0 then
        local success, itemLink = pcall(function()
            local item = mq.TLO.Item(itemID)
            if item and item.ItemLink then
                return item.ItemLink()
            end
            return nil
        end)
        
        if success and itemLink and itemLink ~= "" then
            -- Format the raw link data for chat display with \x12 delimiters
            return string.format("\x12%s\x12", itemLink)
        end
    end
    
    -- Final fallback to simple brackets if all other methods fail
    return string.format("[%s]", itemName)
end

_G.printSmartLoot = util.printSmartLoot

return util