-- modules/loot_history.lua - SQLite Version
local lootHistory = {}
local mq = require("mq")
local logging = require("modules.logging")
local sqlite3 = require("lsqlite3")

local currentServerName = mq.TLO.EverQuest.Server()
local sanitizedServerName = currentServerName:lower():gsub(" ", "_")

-- Database path (shared with main database)
local DB_PATH = mq.TLO.MacroQuest.Path('resources')() .. "/smartloot_" .. sanitizedServerName .. ".db"

-- Database connection
local db = nil

-- Get database connection
local function getConnection()
  if not db then
    db = sqlite3.open(DB_PATH)
    if not db then
      logging.debug("[LootHistory] Failed to open SQLite database: " .. DB_PATH)
      return nil
    end
    db:exec("PRAGMA foreign_keys = ON")
  end
  return db
end

-- Prepare statement helper
local function prepareStatement(sql)
  local conn = getConnection()
  if not conn then
    return nil, "No database connection"
  end
  
  local stmt = conn:prepare(sql)
  if not stmt then
    return nil, "Failed to prepare statement: " .. conn:errmsg()
  end
  
  return stmt
end

-- Helper to build WHERE clause string from filters
local function buildWhereClause(filters)
  local whereClauses = {}
  local params = {}
  local hasWhere = false

  if filters then
    -- Looter: Only add if not nil AND not "All"
    if filters.looter and filters.looter ~= "All" then
      table.insert(whereClauses, "looter = ?")
      table.insert(params, filters.looter)
      hasWhere = true
    end

    -- Zone: Only add if not nil AND not "All"
    if filters.zoneName and filters.zoneName ~= "All" then
      table.insert(whereClauses, "zone_name = ?")
      table.insert(params, filters.zoneName)
      hasWhere = true
    end

    -- Item Name: Only add if not nil AND not empty string. Use LIKE for searching.
    if filters.itemName and filters.itemName ~= "" then
      table.insert(whereClauses, "item_name LIKE ?")
      table.insert(params, "%" .. filters.itemName .. "%")
      hasWhere = true
    end

    -- Action: Only add if not nil AND not "All"
    if filters.action and filters.action ~= "All" then
      table.insert(whereClauses, "action = ?")
      table.insert(params, filters.action)
      hasWhere = true
    end

    -- Start Date: Only add if not nil AND not empty string
    if filters.startDate and filters.startDate ~= "" then
      table.insert(whereClauses, "timestamp >= ?")
      table.insert(params, filters.startDate)
      hasWhere = true
    end

    -- End Date: Only add if not nil AND not empty string
    if filters.endDate and filters.endDate ~= "" then
      table.insert(whereClauses, "timestamp < ?")
      table.insert(params, filters.endDate)
      hasWhere = true
    end
  end

  local whereSql = ""
  if hasWhere then
    whereSql = "WHERE " .. table.concat(whereClauses, " AND ")
  end

  return whereSql, params
end

-- Helper to build ORDER BY, LIMIT, OFFSET clauses
local function buildOrderByLimitOffset(filters, isAggregatedView)
  local clause = ""
  
  -- Define valid columns based on the view type
  local validCols = {}
  if isAggregatedView then
    validCols = {item_name=true, looted_quantity=true, looted_count=true, ignored_count=true, last_ts=true}
  else
    validCols = {timestamp=true, item_name=true, looter=true, zone_name=true, action=true, quantity=true}
  end
  local validDirs = {ASC=true, DESC=true}

  local orderBy = ""
  -- Set View-Specific Defaults
  if isAggregatedView then
    -- Default sort for Aggregated View: Qty Looted DESC, then Item Name ASC
    orderBy = "ORDER BY looted_quantity DESC, item_name ASC"
  else
    -- Default sort for Detailed View: Timestamp DESC
    orderBy = "ORDER BY timestamp DESC"
  end

  -- Check if user provided a valid sort order via filters, overriding the default
  if filters and filters.orderBy and filters.orderDir then
    -- Validate against allowed columns for the current view
    if validCols[filters.orderBy] and validDirs[string.upper(filters.orderDir)] then
      local colName = filters.orderBy
      orderBy = string.format("ORDER BY %s %s", colName, string.upper(filters.orderDir))
      -- Add a consistent secondary sort if user sorts by something other than name
      if colName ~= 'item_name' then
        orderBy = orderBy .. ", item_name ASC"
      end
    end
  end
  clause = clause .. " " .. orderBy

  -- Append LIMIT and OFFSET
  if filters and filters.limit and tonumber(filters.limit) then
    clause = clause .. " LIMIT " .. tonumber(filters.limit)
  end
  if filters and filters.offset and tonumber(filters.offset) then
    if filters.limit then 
      clause = clause .. " OFFSET " .. tonumber(filters.offset) 
    end
  end
  return clause
end

-- Generic function to execute SELECT queries with parameters
local function executeSelect(sql, params)
  local stmt, err = prepareStatement(sql)
  if not stmt then
    return nil, err
  end

  -- Bind parameters if provided
  if params then
    for i, param in ipairs(params) do
      stmt:bind(i, param)
    end
  end

  local results = {}
  for row in stmt:nrows() do
    -- Convert timestamp to unix timestamp for compatibility
    if row.timestamp then
      row.unix_timestamp = os.time({
        year = tonumber(row.timestamp:sub(1,4)),
        month = tonumber(row.timestamp:sub(6,7)),
        day = tonumber(row.timestamp:sub(9,10)),
        hour = tonumber(row.timestamp:sub(12,13)),
        min = tonumber(row.timestamp:sub(15,16)),
        sec = tonumber(row.timestamp:sub(18,19))
      })
    end
    table.insert(results, row)
  end

  stmt:finalize()
  return results
end

function lootHistory.recordLoot(itemName, itemID, iconID, action, corpseName, corpseID, quantity)
  local looter = mq.TLO.Me.Name() or "Unknown"
  local zoneName = mq.TLO.Zone.ShortName() or "Unknown"
  corpseID = corpseID or "Unknown"
  corpseName = corpseName or "Unknown"
  quantity = tonumber(quantity) or 1

  local stmt, err = prepareStatement([[
    INSERT INTO loot_history
    (item_name, item_id, icon_id, looter, corpse_id, corpse_name, zone_name, action, quantity)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]])
  
  if not stmt then
    logging.debug(string.format("[LootHistory] Error preparing recordLoot: %s", tostring(err)))
    return false
  end

  stmt:bind(1, itemName)
  stmt:bind(2, tonumber(itemID))
  stmt:bind(3, tonumber(iconID))
  stmt:bind(4, looter)
  stmt:bind(5, tostring(corpseID))
  stmt:bind(6, corpseName)
  stmt:bind(7, zoneName)
  stmt:bind(8, action)
  stmt:bind(9, quantity)

  local result = stmt:step()
  stmt:finalize()

  if result ~= sqlite3.DONE then
    logging.debug(string.format("[LootHistory] Error recording loot: %s", getConnection():errmsg()))
    return false
  end
  return true
end

function lootHistory.getHistory(filters)
  local whereSql, params = buildWhereClause(filters)
  local orderLimitOffsetSql = buildOrderByLimitOffset(filters)
  local sql = "SELECT *, timestamp as unix_timestamp FROM loot_history " .. whereSql .. " " .. orderLimitOffsetSql

  local results, err = executeSelect(sql, params)
  return results or {}
end

function lootHistory.getHistoryCount(filters)
  local whereSql, params = buildWhereClause(filters)
  local sql = "SELECT COUNT(*) as count FROM loot_history " .. whereSql

  local results, err = executeSelect(sql, params)
  if results and results[1] and results[1].count then
    return tonumber(results[1].count) or 0
  end
  return 0
end

function lootHistory.getAggregatedHistory(filters)
  local whereSql, params = buildWhereClause(filters)
  local orderLimitOffsetSql = buildOrderByLimitOffset(filters, true) -- Indicate aggregated view for sorting

  local sql = [[
    SELECT
      item_name,
      MAX(item_id) as item_id,
      MAX(icon_id) as icon_id,
      SUM(CASE WHEN action = 'Looted' THEN quantity ELSE 0 END) as looted_quantity,
      COUNT(CASE WHEN action = 'Looted' THEN 1 ELSE NULL END) as looted_count,
      COUNT(CASE WHEN action = 'Ignored' THEN 1 ELSE NULL END) as ignored_count,
      MAX(timestamp) as last_ts,
      MAX(timestamp) as unix_timestamp
    FROM loot_history
  ]] .. whereSql .. [[
    GROUP BY item_name
  ]] .. orderLimitOffsetSql

  local results, err = executeSelect(sql, params)
  if not results then
    logging.debug("[LootHistory] Error executing getAggregatedHistory: " .. tostring(err))
    return {}
  end
  
  -- Add drop rate calculation
  local corpseCount = lootHistory.getDedupedCorpseCount(filters)
  for _, row in ipairs(results) do
    row.corpse_count = corpseCount
    row.drop_rate = corpseCount > 0 and (row.looted_count * 100.0 / corpseCount) or 0
    row.drop_count = row.looted_count or 0
  end
  return results
end

function lootHistory.getAggregatedHistoryCount(filters)
  local whereSql, params = buildWhereClause(filters)
  local sql = "SELECT COUNT(DISTINCT item_name) as count FROM loot_history " .. whereSql

  local results, err = executeSelect(sql, params)
  if results and results[1] and results[1].count then
    return tonumber(results[1].count) or 0
  end
  if err then
    logging.debug("[LootHistory] Error executing getAggregatedHistoryCount: " .. tostring(err))
  end
  return 0
end

function lootHistory.getItemLooterDetails(itemName, filters)
  filters = filters or {}
  
  -- Create a copy of filters for exact item match
  local localFilters = {}
  for k, v in pairs(filters) do
    localFilters[k] = v
  end
  
  -- Use exact match for item name
  localFilters.itemName = itemName
  localFilters.exactItemMatch = true
  
  local whereClauses = {}
  local params = {}
  
  -- Build WHERE clause with exact item match
  table.insert(whereClauses, "item_name = ?")
  table.insert(params, itemName)
  
  -- Add other filters
  if localFilters.zoneName and localFilters.zoneName ~= "All" then
    table.insert(whereClauses, "zone_name = ?")
    table.insert(params, localFilters.zoneName)
  end
  
  if localFilters.startDate and localFilters.startDate ~= "" then
    table.insert(whereClauses, "timestamp >= ?")
    table.insert(params, localFilters.startDate)
  end
  
  if localFilters.endDate and localFilters.endDate ~= "" then
    table.insert(whereClauses, "timestamp < ?")
    table.insert(params, localFilters.endDate)
  end

  local whereSql = "WHERE " .. table.concat(whereClauses, " AND ")
  local orderLimitOffsetSql = buildOrderByLimitOffset(localFilters)
  
  local sql = string.format([[
    SELECT looter, SUM(quantity) as total_quantity, COUNT(*) as count, 
           MAX(timestamp) as last_ts, 
           MAX(timestamp) as unix_timestamp
    FROM loot_history
    %s
    GROUP BY looter
    %s
  ]], whereSql, orderLimitOffsetSql)

  local results, err = executeSelect(sql, params)
  if err then
    logging.debug("[LootHistory] Error in getItemLooterDetails: " .. tostring(err))
  end
  
  return results or {}
end

function lootHistory.getUniqueLooters()
  local sql = "SELECT DISTINCT looter FROM loot_history WHERE looter IS NOT NULL AND looter <> '' ORDER BY looter ASC"
  local results, err = executeSelect(sql)
  local looters = {"All"}
  if results then
    for _, row in ipairs(results) do
      if row.looter then 
        table.insert(looters, row.looter) 
      end
    end
  end
  return looters
end

function lootHistory.getUniqueZones()
  local sql = "SELECT DISTINCT zone_name FROM loot_history WHERE zone_name IS NOT NULL AND zone_name <> '' ORDER BY zone_name ASC"
  local results, err = executeSelect(sql)
  local zones = {"All"}
  if results then
    for _, row in ipairs(results) do
      if row.zone_name then 
        table.insert(zones, row.zone_name) 
      end
    end
  end
  return zones
end

function lootHistory.getTimeFrameFilter(timeFrame)
  local filters = {}
  local now = os.time()
  local function getStartOfDay(daysAgo)
    local t = os.date("*t", now - (daysAgo * 86400))
    t.hour = 0; t.min = 0; t.sec = 0
    return os.date("%Y-%m-%d %H:%M:%S", os.time(t))
  end

  if timeFrame == "Today" then
    filters.startDate = getStartOfDay(0)
  elseif timeFrame == "Yesterday" then
    filters.startDate = getStartOfDay(1)
    filters.endDate = getStartOfDay(0)
  elseif timeFrame == "This Week" then
    local dayOfWeek = tonumber(os.date("%w", now)) -- 0=Sunday, 1=Monday,...
    filters.startDate = getStartOfDay(dayOfWeek)
  elseif timeFrame == "This Month" then
    local t = os.date("*t", now)
    t.day = 1; t.hour = 0; t.min = 0; t.sec = 0
    filters.startDate = os.date("%Y-%m-%d %H:%M:%S", os.time(t))
  end
  return filters
end

function lootHistory.formatTimestamp(unix_timestamp, raw_timestamp_str)
  if not unix_timestamp or type(unix_timestamp) ~= "number" then
    return raw_timestamp_str or "Invalid Date"
  end
  local itemTime = tonumber(unix_timestamp)
  local now = os.time()
  local diff = os.difftime(now, itemTime)
  if diff < 0 then diff = 0 end
  if diff < 60 then return "Just now" end
  if diff < 3600 then return math.floor(diff / 60) .. " min ago" end
  if diff < 86400 then return math.floor(diff / 3600) .. " hrs ago" end
  if diff < 172800 then return "Yesterday " .. os.date("%I:%M%p", itemTime):lower() end
  if diff < 604800 then return os.date("%a %b %d", itemTime) end
  return os.date("%b %d, %Y", itemTime)
end

function lootHistory.getDedupedCorpseCount(filters)
  local whereClauses = {}
  local params = {}

  if filters and filters.zoneName and filters.zoneName ~= "All" then
    table.insert(whereClauses, "zone_name = ?")
    table.insert(params, filters.zoneName)
  end

  local whereSQL = ""
  if #whereClauses > 0 then
    whereSQL = "WHERE " .. table.concat(whereClauses, " AND ")
  end

  local sql = string.format([[
    SELECT COUNT(DISTINCT (strftime('%%s', timestamp)/600 || '|' || corpse_id)) AS count
    FROM loot_history
    %s
  ]], whereSQL)

  local results, err = executeSelect(sql, params)
  return results and results[1] and tonumber(results[1].count) or 0
end

function lootHistory.close()
  if db then
    db:close()
    db = nil
    logging.debug("[LootHistory] Closed SQLite database connection.")
  end
end

return lootHistory