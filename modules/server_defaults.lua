local mq = require("mq")

local serverDefaults = {}

local function sanitizeServerName(serverName)
    local name = serverName or mq.TLO.EverQuest.Server() or ""
    return tostring(name):lower():gsub(" ", "_")
end

local function getCurrentServerName()
    return mq.TLO.EverQuest.Server() or "unknown"
end

function serverDefaults.getCurrentServerKey()
    return sanitizeServerName(getCurrentServerName())
end

function serverDefaults.getModuleName(serverName)
    return string.format("data.defaults.%s", sanitizeServerName(serverName))
end

function serverDefaults.load(serverName)
    local moduleName = serverDefaults.getModuleName(serverName)
    local ok, data = pcall(require, moduleName)
    if not ok then
        if tostring(data):find("module '" .. moduleName .. "' not found", 1, true) then
            return nil, "No server defaults file found"
        end
        return nil, string.format("Failed to load defaults file: %s", tostring(data))
    end

    if type(data) ~= "table" then
        return nil, "Server defaults file must return a table"
    end

    data.server = data.server or getCurrentServerName()
    data.server_key = data.server_key or sanitizeServerName(data.server)
    data.version = tostring(data.version or "1")
    data.description = data.description or ""
    data.rules = data.rules or data.items or {}

    if type(data.rules) ~= "table" then
        return nil, "Server defaults rules must be a table"
    end

    for _, ruleEntry in ipairs(data.rules) do
        if type(ruleEntry) == "table" then
            local rawTags = ruleEntry.tags
            local normalizedTags = {}
            if type(rawTags) == "table" then
                for _, tag in ipairs(rawTags) do
                    local normalized = tostring(tag or ""):lower():gsub("^%s*(.-)%s*$", "%1")
                    if normalized ~= "" then
                        table.insert(normalizedTags, normalized)
                    end
                end
            end
            ruleEntry.tags = normalizedTags
        end
    end

    return data
end

return serverDefaults
