-- modules/temp_rules.lua - Temporary rule management for AFK farming
local tempRules = {}
local mq = require("mq")
local logging = require("modules.logging")
local database = require("modules.database")
local json = require("dkjson")

-- In-memory storage for temporary rules
-- Structure: { ["item name lowercase"] = { rule = "Keep", originalName = "Item Name", threshold = 1, assignedPeer = nil } }
local temporaryRules = {}
local tempRulesFile = mq.TLO.MacroQuest.Path("config")() .. "/smartloot_temp_rules.json"

-- Load temporary rules from file
function tempRules.load()
    local file = io.open(tempRulesFile, "r")
    if file then
        local contents = file:read("*a")
        file:close()
        
        local decoded = json.decode(contents)
        if decoded then
            temporaryRules = decoded
            logging.log("[TempRules] Loaded " .. tempRules.getCount() .. " temporary rules")
        end
    end
end

-- Save temporary rules to file
function tempRules.save()
    local file = io.open(tempRulesFile, "w")
    if file then
        file:write(json.encode(temporaryRules, { indent = true }))
        file:close()
        logging.log("[TempRules] Saved " .. tempRules.getCount() .. " temporary rules")
        return true
    end
    return false
end

-- Add a temporary rule with optional peer assignment
function tempRules.add(itemName, rule, threshold, assignedPeer)
    if not itemName or itemName == "" then
        return false, "Item name cannot be empty"
    end
    
    if not rule or rule == "" then
        return false, "Rule cannot be empty"
    end
    
    local lowerName = itemName:lower()
    
    -- Build the rule string
    local finalRule = rule
    if rule == "KeepIfFewerThan" and threshold then
        finalRule = "KeepIfFewerThan:" .. threshold
    end
    
    temporaryRules[lowerName] = {
        rule = finalRule,
        originalName = itemName,  -- Preserve the original case for display
        threshold = threshold or 1,
        assignedPeer = assignedPeer,  -- NEW: Store assigned peer
        addedAt = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    tempRules.save()
    
    if assignedPeer then
        logging.log("[TempRules] Added temporary rule: " .. itemName .. " -> " .. finalRule .. " (assigned to " .. assignedPeer .. ")")
    else
        logging.log("[TempRules] Added temporary rule: " .. itemName .. " -> " .. finalRule)
    end
    
    return true
end

-- Remove a temporary rule
function tempRules.remove(itemName)
    local lowerName = itemName:lower()
    
    if temporaryRules[lowerName] then
        local originalName = temporaryRules[lowerName].originalName
        temporaryRules[lowerName] = nil
        tempRules.save()
        logging.log("[TempRules] Removed temporary rule for: " .. originalName)
        return true
    end
    
    return false
end

-- Check if an item has a temporary rule
function tempRules.getRule(itemName)
    if not itemName then return nil end
    
    local lowerName = itemName:lower()
    local tempRule = temporaryRules[lowerName]
    
    if tempRule then
        return tempRule.rule, tempRule.originalName, tempRule.assignedPeer
    end
    
    return nil
end

-- NEW: Add a specific function for peer assignment
function tempRules.assignToPeer(itemName, peerName)
    if not itemName or itemName == "" then
        return false, "Item name cannot be empty"
    end
    
    if not peerName or peerName == "" then
        return false, "Peer name cannot be empty"
    end
    
    -- Add as Ignore for self, but assign to peer
    local lowerName = itemName:lower()
    
    temporaryRules[lowerName] = {
        rule = "Ignore",  -- Main looter ignores
        originalName = itemName,
        threshold = 1,
        assignedPeer = peerName,  -- Will trigger this peer
        addedAt = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    tempRules.save()
    logging.log("[TempRules] Added peer assignment: " .. itemName .. " -> " .. peerName)
    
    -- Also notify via chat
    local config = require("modules.config")
    if config and config.sendChatMessage then
        config.sendChatMessage(string.format("AFK Farm: %s assigned to %s", itemName, peerName))
    end
    
    return true
end

-- NEW: Get peer assignment for an item
function tempRules.getPeerAssignment(itemName)
    if not itemName then return nil end
    
    local lowerName = itemName:lower()
    local tempRule = temporaryRules[lowerName]
    
    if tempRule and tempRule.assignedPeer then
        return tempRule.assignedPeer
    end
    
    return nil
end

-- Convert a temporary rule to permanent when item is encountered
function tempRules.convertToPermanent(itemName, itemID, iconID)
    local lowerName = itemName:lower()
    local tempRule = temporaryRules[lowerName]
    
    if not tempRule then
        return false, "No temporary rule found"
    end
    
    local finalRule = tempRule.rule
    local assignedPeer = tempRule.assignedPeer
    
    -- If there's a peer assignment, the rule for the current character should be "Ignore"
    if assignedPeer and assignedPeer ~= "" then
    -- Save "Ignore" for self
        database.saveLootRule(itemName, itemID, "Ignore", iconID)

        -- Save the appropriate rule for the peer
        database.saveLootRuleFor(assignedPeer, itemName, itemID, tempRule.rule, iconID)
        
        -- Optional: refresh in-memory cache
        database.refreshLootRuleCacheForPeer(assignedPeer)
        
        logging.log(string.format("[TempRules] Rule converted: %s -> Ignore (self), %s -> %s", itemName, assignedPeer, tempRule.rule))
    else
        database.saveLootRule(itemName, itemID, finalRule, iconID)
    end
    
    if assignedPeer and assignedPeer ~= "" then
    logging.log(string.format("[TempRules] Converted to permanent: %s (ID: %d) -> Ignore (leaving for %s)", 
                              itemName, itemID, assignedPeer))
    local config = require("modules.config")
    if config and config.sendChatMessage then
        config.sendChatMessage(string.format("AFK Farm: Learned %s (ID: %d) -> Ignoring (leaving for %s)", 
                                             itemName, itemID, assignedPeer))
    end
    -- Remove from temporary rules
    temporaryRules[lowerName] = nil
    tempRules.save()
end

return true
end

-- Get all temporary rules
function tempRules.getAll()
    local rules = {}
    
    for lowerName, data in pairs(temporaryRules) do
        table.insert(rules, {
            itemName = data.originalName,
            rule = data.rule,
            threshold = data.threshold,
            assignedPeer = data.assignedPeer,
            addedAt = data.addedAt
        })
    end
    
    -- Sort by original name
    table.sort(rules, function(a, b) return a.itemName < b.itemName end)
    
    return rules
end

-- Get count of temporary rules
function tempRules.getCount()
    local count = 0
    for _ in pairs(temporaryRules) do
        count = count + 1
    end
    return count
end

-- Clear all temporary rules
function tempRules.clearAll()
    temporaryRules = {}
    tempRules.save()
    logging.log("[TempRules] Cleared all temporary rules")
end

-- Check if AFK farming mode is effectively enabled (has temp rules)
function tempRules.isAFKFarmingActive()
    return tempRules.getCount() > 0
end

-- Parse rule string to get display rule and threshold
function tempRules.parseRule(ruleString)
    if not ruleString then return "Unset", 1 end
    
    if string.find(ruleString, "KeepIfFewerThan:") then
        local threshold = ruleString:match("KeepIfFewerThan:(%d+)")
        return "KeepIfFewerThan", tonumber(threshold) or 1
    end
    
    return ruleString, 1
end

-- Initialize by loading saved rules
tempRules.load()

return tempRules