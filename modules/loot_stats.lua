-- modules/loot_stats.lua - SQLite Version
local lootStats = {}
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
      logging.debug("[LootStats] Failed to open SQLite database: " .. DB_PATH)
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
    -- Convert numeric fields that might be returned as strings
    if row.item_id then row.item_id = tonumber(row.item_id) or row.item_id end
    if row.icon_id then row.icon_id = tonumber(row.icon_id) or row.icon_id end
    if row.drop_count then row.drop_count = tonumber(row.drop_count) or 0 end
    if row.corpse_count then row.corpse_count = tonumber(row.corpse_count) or 0 end
    if row.drop_rate then row.drop_rate = tonumber(row.drop_rate) or 0 end
    if row.global_drop_count then row.global_drop_count = tonumber(row.global_drop_count) or 0 end
    if row.global_corpse_count then row.global_corpse_count = tonumber(row.global_corpse_count) or 0 end
    if row.global_drop_rate then row.global_drop_rate = tonumber(row.global_drop_rate) or 0 end
    if row.count then row.count = tonumber(row.count) or 0 end

    table.insert(results, row)
  end

  stmt:finalize()
  return results, nil
end

-- Caching
local globalStatsCache = { data = nil, timestamp = 0 }
local GLOBAL_CACHE_DURATION_SECONDS = 60
local zoneCache = { list = nil, timestamp = 0 }
local ZONE_CACHE_DURATION_SECONDS = 300

function lootStats.getTotalCorpseCount()
  local result, err = executeSelect("SELECT COUNT(*) AS count FROM loot_stats_corpses")
  return result and tonumber(result[1].count) or 0
end

function lootStats.clearAllCache()
  globalStatsCache = { data = nil, timestamp = 0 }
  zoneCache = { list = nil, timestamp = 0 }
  logging.verbose("[LootStats] Caches cleared.")
end

-- Helper to build WHERE clause parts specific to stats queries
local function buildStatsWhereClause(filters)
  local clauses = {"d.item_id IS NOT NULL"}
  local params = {}

  if filters then
    -- Zone Filter (only if not 'All')
    if filters.zoneName and filters.zoneName ~= "All" then
      table.insert(clauses, "d.zone_name = ?")
      table.insert(params, filters.zoneName)
    end
    
    -- Item Name Filter (using LIKE)
    if filters.itemName and filters.itemName ~= "" then
      table.insert(clauses, "d.item_name LIKE ?")
      table.insert(params, "%" .. filters.itemName .. "%")
    end
    
    -- Time filters
    if filters.startDate and filters.startDate ~= "" then 
      table.insert(clauses, "d.timestamp >= ?")
      table.insert(params, filters.startDate)
    end
    if filters.endDate and filters.endDate ~= "" then 
      table.insert(clauses, "d.timestamp < ?")
      table.insert(params, filters.endDate)
    end
  end

  local whereClause = "WHERE " .. table.concat(clauses, " AND ")
  return whereClause, params
end

local function buildStatsOrderByLimitOffset(filters)
  local clause = ""
  -- Define valid columns for stats view
  local validCols = {item_name=true, drop_count=true, corpse_count=true, drop_rate=true}
  local validDirs = {ASC=true, DESC=true}

  -- Default sort: drop_count DESC, then item_name ASC for ties
  local orderBy = "ORDER BY drop_count DESC, item_name ASC"

  -- Check if user provided a valid sort order via filters, overriding the default
  if filters and filters.orderBy and filters.orderDir then
    if validCols[filters.orderBy] and validDirs[string.upper(filters.orderDir)] then
      local colName = filters.orderBy
      orderBy = string.format("ORDER BY %s %s", colName, string.upper(filters.orderDir))
      -- Add secondary sort for consistency unless sorting by name already
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

function lootStats.isCorpseAlreadySeen(zone_name, corpse_id)
  if not zone_name or not corpse_id then return false end
  
  local sql = "SELECT COUNT(*) AS count FROM loot_stats_corpses WHERE zone_name = ? AND corpse_id = ?"
  local result, err = executeSelect(sql, {zone_name, corpse_id})
  if err then
    logging.debug("[LootStats] isCorpseAlreadySeen failed: " .. tostring(err))
    return false
  end
  return result and result[1] and tonumber(result[1].count) > 0
end

function lootStats.recordItemDrop(itemName, itemID, iconID, zoneName, quantity, corpseID, npcName, npcID)
  local serverName = mq.TLO.EverQuest.Server()
 
  -- Check for recent drops (last 5 minutes) of the same item from the same corpse
  local recentCheck = [[
    SELECT COUNT(*) as count
    FROM loot_stats_drops
    WHERE item_id = ?
      AND corpse_id = ?
      AND zone_name = ?
      AND server_name = ?
      AND datetime(timestamp) > datetime('now', '-5 minutes')
  ]]
 
  local rows, err = lootStats.executeSelect(recentCheck, {itemID, corpseID, zoneName, serverName})
  
  -- Debug logging to see what we got back
  logging.verbose(string.format("[LootStats] Duplicate check query result: rows=%s, err=%s", 
                 tostring(rows and "table" or rows), tostring(err)))
  
  if rows then
    logging.verbose(string.format("[LootStats] Rows length: %d", #rows))
    if rows[1] then
      logging.verbose(string.format("[LootStats] First row: %s", tostring(rows[1])))
      if type(rows[1]) == "table" then
        for i, v in ipairs(rows[1]) do
          logging.verbose(string.format("[LootStats] Row[1][%d] = %s", i, tostring(v)))
        end
      end
    end
  end
  
  -- More robust way to check the count
  local isDuplicate = false
  if rows and #rows > 0 then
    local firstRow = rows[1]
    if firstRow then
      local count = nil
      
      -- Try different ways to access the count depending on how executeSelect returns data
      if type(firstRow) == "table" then
        -- If it's an array-like table
        count = firstRow[1] or firstRow.count or firstRow["COUNT(*)"]
      elseif type(firstRow) == "number" then
        -- If the first row is directly the number
        count = firstRow
      else
        -- If it's some other format
        count = tonumber(tostring(firstRow))
      end
      
      logging.verbose(string.format("[LootStats] Extracted count value: %s (type: %s)", 
                     tostring(count), type(count)))
      
      if count and tonumber(count) and tonumber(count) > 0 then
        isDuplicate = true
      end
    end
  end
  
  if isDuplicate then
    logging.verbose(string.format("[LootStats] Skipping duplicate drop record for %s from corpse %d (recorded within 5 minutes)",
                   itemName, corpseID))
    return true
  end
 
  -- Proceed with insert if no recent duplicate found
  local stmt, err = prepareStatement([[
    INSERT INTO loot_stats_drops
    (item_name, item_id, icon_id, zone_name, item_count, corpse_id, npc_name, npc_id, dropped_by, server_name)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]])
 
  if not stmt then
    logging.verbose(string.format("[LootStats] Error preparing recordItemDrop: %s", tostring(err)))
    return false
  end
 
  stmt:bind(1, itemName)
  stmt:bind(2, itemID)
  stmt:bind(3, iconID)
  stmt:bind(4, zoneName)
  stmt:bind(5, quantity)
  stmt:bind(6, corpseID)
  stmt:bind(7, npcName)
  stmt:bind(8, npcID)
  stmt:bind(9, npcName)
  stmt:bind(10, serverName)
 
  local result = stmt:step()
  stmt:finalize()
 
  if result ~= sqlite3.DONE then
    logging.verbose(string.format("[LootStats] Error recording drop: %s", getConnection():errmsg()))
    return false
  end
 
  logging.verbose(string.format("[LootStats] Successfully recorded drop: %s (ID:%d) from corpse %d", 
                 itemName, itemID, corpseID))
  return true
end

-- Alternative simpler approach - skip the duplicate check for now to avoid the error
function lootStats.recordItemDropSimple(itemName, itemID, iconID, zoneName, quantity, corpseID, npcName, npcID)
  local serverName = mq.TLO.EverQuest.Server()
 
  -- Skip duplicate check for now - just insert
  local stmt, err = prepareStatement([[
    INSERT INTO loot_stats_drops
    (item_name, item_id, icon_id, zone_name, item_count, corpse_id, npc_name, npc_id, dropped_by, server_name)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]])
 
  if not stmt then
    logging.verbose(string.format("[LootStats] Error preparing recordItemDrop: %s", tostring(err)))
    return false
  end
 
  stmt:bind(1, itemName)
  stmt:bind(2, itemID)
  stmt:bind(3, iconID)
  stmt:bind(4, zoneName)
  stmt:bind(5, quantity)
  stmt:bind(6, corpseID)
  stmt:bind(7, npcName)
  stmt:bind(8, npcID)
  stmt:bind(9, npcName)
  stmt:bind(10, serverName)
 
  local result = stmt:step()
  stmt:finalize()
 
  if result ~= sqlite3.DONE then
    logging.verbose(string.format("[LootStats] Error recording drop: %s", getConnection():errmsg()))
    return false
  end
 
  return true
end

-- If you want to add back duplicate checking later, you need to understand 
-- how your executeSelect function returns data. Add this debug function:
function lootStats.debugExecuteSelect()
  local testQuery = "SELECT COUNT(*) FROM loot_stats_drops LIMIT 1"
  local rows, err = lootStats.executeSelect(testQuery)
  
  logging.log("=== executeSelect Debug ===")
  logging.log("Query: " .. testQuery)
  logging.log("Error: " .. tostring(err))
  logging.log("Rows type: " .. type(rows))
  
  if rows then
    logging.log("Rows length: " .. #rows)
    if rows[1] then
      logging.log("First row type: " .. type(rows[1]))
      logging.log("First row value: " .. tostring(rows[1]))
      
      if type(rows[1]) == "table" then
        logging.log("First row is table with " .. #(rows[1]) .. " elements")
        for i, v in ipairs(rows[1]) do
          logging.log(string.format("  [%d] = %s (%s)", i, tostring(v), type(v)))
        end
        
        -- Check for named keys
        for k, v in pairs(rows[1]) do
          if type(k) ~= "number" then
            logging.log(string.format("  ['%s'] = %s (%s)", k, tostring(v), type(v)))
          end
        end
      end
    end
  end
  logging.log("=== End Debug ===")
end

function lootStats.getUniqueZones()
  local now = os.time()
  if zoneCache.list and (now - zoneCache.timestamp < ZONE_CACHE_DURATION_SECONDS) then
    return zoneCache.list
  end

  local sql = "SELECT DISTINCT zone_name FROM loot_stats_corpses WHERE zone_name IS NOT NULL ORDER BY zone_name ASC"
  local results, err = executeSelect(sql)

  if err or not results then
    logging.debug("[LootStats] Failed to fetch unique zones: " .. tostring(err))
    return zoneCache.list or {"All"}
  end

  local zones = {"All"}
  for _, row in ipairs(results) do
    if row.zone_name then 
      table.insert(zones, row.zone_name) 
    end
  end

  zoneCache.list = zones
  zoneCache.timestamp = now
  return zones
end

function lootStats.getTotalCorpseCount(zoneNameFilter)
    local sql = "SELECT COUNT(*) AS count FROM loot_stats_corpses"
    local params = {}
    if zoneNameFilter and zoneNameFilter ~= "All" then
        sql = sql .. " WHERE zone_name = ?"
        table.insert(params, zoneNameFilter)
    end
    local result, err = executeSelect(sql, params)
    return result and result[1] and tonumber(result[1].count) or 0
end

function lootStats.getGlobalStats()
  local now = os.time()
  -- Return cached data if fresh
  if globalStatsCache.data and (now - globalStatsCache.timestamp < GLOBAL_CACHE_DURATION_SECONDS) then
    return globalStatsCache.data
  end

  -- Calculate global stats using SQL
  local sql = [[
    SELECT
      item_id,
      MAX(item_name) AS item_name,
      MAX(icon_id) AS icon_id,
      SUM(item_count) AS global_drop_count
    FROM loot_stats_drops
    GROUP BY item_id
  ]]

  local results, err = executeSelect(sql)

  local totalCorpses = lootStats.getTotalCorpseCount()
  for _, row in ipairs(results or {}) do
    row.global_corpse_count = totalCorpses
    row.global_drop_rate = totalCorpses > 0 and (row.global_drop_count * 100.0 / totalCorpses) or 0
  end

  if err or not results then
    logging.debug("[LootStats] Failed to fetch global stats: " .. tostring(err))
    -- Return previous cache if available, otherwise empty
    return globalStatsCache.data or {}
  end

  -- Update cache
  globalStatsCache.data = results
  globalStatsCache.timestamp = now
  return results
end

local function buildCorpseTimeFilter(filters)
  local clauses = {}
  local params = {}
  
  if filters and filters.startDate and filters.startDate ~= "" then 
    table.insert(clauses, "timestamp >= ?")
    table.insert(params, filters.startDate)
  end
  if filters and filters.endDate and filters.endDate ~= "" then 
    table.insert(clauses, "timestamp < ?")
    table.insert(params, filters.endDate)
  end
  
  local whereClause = ""
  if #clauses > 0 then
    whereClause = "WHERE " .. table.concat(clauses, " AND ")
  end
  return whereClause, params
end

function lootStats.getLootStats(filters)
  filters = filters or {}
  
  -- Build WHERE clause using the updated helper function
  local whereClause, whereParams = buildStatsWhereClause(filters)
  local orderLimitOffsetClause = buildStatsOrderByLimitOffset(filters)

  -- Build corpse time filter for subquery
  local corpseTimeFilter, corpseParams = buildCorpseTimeFilter(filters)

  local sql = string.format([[
    SELECT
      d.item_id,
      MAX(d.item_name) AS item_name,
      MAX(d.icon_id) AS icon_id,
      COUNT(*) AS drop_count,
      z.total_corpses AS corpse_count,
      ROUND(COUNT(*) * 100.0 / NULLIF(z.total_corpses, 0), 2) AS drop_rate
    FROM loot_stats_drops d
    JOIN (
      SELECT 
        zone_name, 
        COUNT(*) AS total_corpses
      FROM loot_stats_corpses
      %s
      GROUP BY zone_name
    ) z ON z.zone_name = d.zone_name
    %s
    GROUP BY d.item_id
    %s
  ]], corpseTimeFilter, whereClause, orderLimitOffsetClause)

  -- Combine parameters for corpse filter and main filter
  local allParams = {}
  if corpseParams then
    for _, param in ipairs(corpseParams) do
      table.insert(allParams, param)
    end
  end
  if whereParams then
    for _, param in ipairs(whereParams) do
      table.insert(allParams, param)
    end
  end

  local results, err = executeSelect(sql, allParams)
  return results or {}, err
end

function lootStats.getLootStatsCount(filters)
  filters = filters or {}
  
  local clauses = {"item_id IS NOT NULL"}
  local params = {}

  if filters.zoneName and filters.zoneName ~= "All" then
    table.insert(clauses, "zone_name = ?")
    table.insert(params, filters.zoneName)
  end

  if filters.itemName and filters.itemName ~= "" then
    table.insert(clauses, "item_name LIKE ?")
    table.insert(params, "%" .. filters.itemName .. "%")
  end

  -- Add time filters
  if filters.startDate and filters.startDate ~= "" then 
    table.insert(clauses, "timestamp >= ?")
    table.insert(params, filters.startDate)
  end
  if filters.endDate and filters.endDate ~= "" then 
    table.insert(clauses, "timestamp < ?")
    table.insert(params, filters.endDate)
  end

  local sql = string.format([[
    SELECT COUNT(DISTINCT item_id) as count
    FROM loot_stats_drops
    WHERE %s
  ]], table.concat(clauses, " AND "))

  local results, err = executeSelect(sql, params)
  return results and results[1] and tonumber(results[1].count) or 0, err
end

-- Gets drop rate information per zone for a specific item name
function lootStats.getItemDropRates(itemName, filters)
  if not itemName or itemName == "" then return {} end

  filters = filters or {}
  local params = {itemName}
  
  -- Build time filter clauses
  local timeFilters = {}
  if filters.startDate and filters.startDate ~= "" then 
    table.insert(timeFilters, "d.timestamp >= ?")
    table.insert(params, filters.startDate)
  end
  if filters.endDate and filters.endDate ~= "" then 
    table.insert(timeFilters, "d.timestamp < ?")
    table.insert(params, filters.endDate)
  end
  
  local timeWhereClause = ""
  if #timeFilters > 0 then
    timeWhereClause = " AND " .. table.concat(timeFilters, " AND ")
  end
  
  -- Also apply time filters to corpse subquery for accurate rates
  local corpseTimeFilter = ""
  local corpseParams = {}
  if filters.startDate and filters.startDate ~= "" then 
    table.insert(corpseParams, filters.startDate)
    corpseTimeFilter = corpseTimeFilter .. " AND timestamp >= ?"
  end
  if filters.endDate and filters.endDate ~= "" then 
    table.insert(corpseParams, filters.endDate)
    corpseTimeFilter = corpseTimeFilter .. " AND timestamp < ?"
  end

  -- Construct the full query with proper parameter placeholders
  local corpseParamPlaceholders = string.rep("?,", #corpseParams):sub(1, -2)
  if #corpseParams > 0 then
    corpseParamPlaceholders = "AND timestamp >= ? " .. (filters.endDate and "AND timestamp < ?" or "")
  end

  local sql = string.format([[
    SELECT
      d.zone_name,
      COUNT(*) AS drop_count,
      (SELECT COUNT(*) FROM loot_stats_corpses c WHERE c.zone_name = d.zone_name%s) AS corpse_count,
      ROUND(COUNT(*) * 100.0 / NULLIF((SELECT COUNT(*) FROM loot_stats_corpses c WHERE c.zone_name = d.zone_name%s), 0), 2) AS drop_rate
    FROM loot_stats_drops d
    WHERE d.item_name = ?%s
    GROUP BY d.zone_name
    ORDER BY drop_rate DESC, d.zone_name ASC
  ]], corpseTimeFilter, corpseTimeFilter, timeWhereClause)

  -- Combine all parameters in correct order
  local allParams = {itemName}
  for _, param in ipairs(corpseParams) do
    table.insert(allParams, param)
  end
  for _, param in ipairs(corpseParams) do
    table.insert(allParams, param)
  end
  -- Add time filter params that come after the item name
  if filters.startDate and filters.startDate ~= "" then 
    table.insert(allParams, filters.startDate)
  end
  if filters.endDate and filters.endDate ~= "" then 
    table.insert(allParams, filters.endDate)
  end

  local results, err = executeSelect(sql, allParams)
  return results or {}, err
end

-- Execute non-query statements (INSERT, UPDATE, DELETE)
lootStats.executeNonQuery = function(sql, params)
  local stmt, err = prepareStatement(sql)
  if not stmt then
    logging.verbose(string.format("[LootStats] Failed to prepare statement: %s", tostring(err)))
    return false
  end

  -- Bind parameters if provided
  if params then
    for i, param in ipairs(params) do
      stmt:bind(i, param)
    end
  end

  local result = stmt:step()
  stmt:finalize()

  if result ~= sqlite3.DONE then
    logging.verbose(string.format("[LootStats] Failed to execute SQL: %s", getConnection():errmsg()))
    return false
  end

  return true
end

-- Export executeSelect for other modules that might need it
lootStats.executeSelect = executeSelect

function lootStats.close()
  if db then
    db:close()
    db = nil
    logging.debug("[LootStats] Closed SQLite database connection.")
  end
end

return lootStats