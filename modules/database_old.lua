-- modules/database.lua - SQLite Version with Proper Case Handling
local database = {}
local mq       = require("mq")
local logging  = require("modules.logging")
local sqlite3  = require("lsqlite3")

local currentServerName = mq.TLO.EverQuest.Server()
local sanitizedServerName = currentServerName:lower():gsub(" ", "_")

-- Database Configuration
local DB_PATH = mq.TLO.MacroQuest.Path('resources')() .. "/smartloot_" .. sanitizedServerName .. ".db"

-- Module‐level cache - NOW USES ORIGINAL CASE
local lootRulesCache  = {}
local fullCacheLoaded = false

-- Database connection
local db = nil

-- Database migration function
local function migrateDatabase(conn)
  logging.debug("[Database] Running schema migration...")
  
  -- Check if we need to add new columns to existing tables
  local migrations = {
    -- Add server_name column to loot_stats_corpses if it doesn't exist
    "ALTER TABLE loot_stats_corpses ADD COLUMN server_name TEXT",
    -- Add session_id column to loot_stats_corpses if it doesn't exist  
    "ALTER TABLE loot_stats_corpses ADD COLUMN session_id TEXT",
    -- Add server_name column to loot_stats_drops if it doesn't exist
    "ALTER TABLE loot_stats_drops ADD COLUMN server_name TEXT"
  }
  
  for _, migration in ipairs(migrations) do
    local result = conn:exec(migration)
    if result ~= sqlite3.OK then
      local error = conn:errmsg()
      -- Ignore "duplicate column name" errors (column already exists)
      if not string.find(error, "duplicate column name") then
        logging.debug("[Database] Migration failed: " .. migration .. " - " .. error)
        return false
      else
        logging.debug("[Database] Column already exists (skipping): " .. migration)
      end
    else
      logging.debug("[Database] Migration successful: " .. migration)
    end
  end
  
  logging.debug("[Database] Schema migration completed")
  return true
end

-- Initialize database connection and create tables
local function initializeDatabase()
  if db then
    return db
  end

  db = sqlite3.open(DB_PATH)
  if not db then
    logging.debug("[Database] Failed to open SQLite database: " .. DB_PATH)
    return nil
  end

  -- Enable foreign keys and case-insensitive LIKE
  db:exec("PRAGMA foreign_keys = ON")
  db:exec("PRAGMA case_sensitive_like = OFF")
  
  -- Create tables if they don't exist
  local createTables = [[
    CREATE TABLE IF NOT EXISTS lootrules (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      toon TEXT NOT NULL,
      item_name TEXT NOT NULL,
      rule TEXT NOT NULL,
      item_id INTEGER DEFAULT 0,
      icon_id INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(toon, item_name)
    );
    
    CREATE INDEX IF NOT EXISTS idx_lootrules_toon ON lootrules(toon);
    CREATE INDEX IF NOT EXISTS idx_lootrules_item_name ON lootrules(item_name);
    
    CREATE TABLE IF NOT EXISTS loot_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      looter TEXT NOT NULL,
      item_name TEXT NOT NULL,
      item_id INTEGER DEFAULT 0,
      icon_id INTEGER DEFAULT 0,
      action TEXT NOT NULL CHECK(action IN ('Looted', 'Ignored', 'Left Behind', 'Destroyed')),
      corpse_name TEXT,
      corpse_id INTEGER DEFAULT 0,
      zone_name TEXT,
      quantity INTEGER DEFAULT 1,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    
    CREATE INDEX IF NOT EXISTS idx_loot_history_looter ON loot_history(looter);
    CREATE INDEX IF NOT EXISTS idx_loot_history_item_name ON loot_history(item_name);
    CREATE INDEX IF NOT EXISTS idx_loot_history_action ON loot_history(action);
    CREATE INDEX IF NOT EXISTS idx_loot_history_zone ON loot_history(zone_name);
    CREATE INDEX IF NOT EXISTS idx_loot_history_timestamp ON loot_history(timestamp);
    
    CREATE TABLE IF NOT EXISTS loot_stats_corpses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      zone_name TEXT NOT NULL,
      corpse_id INTEGER NOT NULL,
      npc_name TEXT,
      npc_id INTEGER DEFAULT 0,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
      server_name TEXT,
      session_id TEXT
    );
    
    CREATE INDEX IF NOT EXISTS idx_loot_stats_corpses_zone ON loot_stats_corpses(zone_name);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_corpses_timestamp ON loot_stats_corpses(timestamp);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_corpses_server ON loot_stats_corpses(server_name);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_corpses_lookup ON loot_stats_corpses(zone_name, corpse_id, timestamp);
    
    CREATE TABLE IF NOT EXISTS loot_stats_drops (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      item_name TEXT NOT NULL,
      item_id INTEGER DEFAULT 0,
      icon_id INTEGER DEFAULT 0,
      zone_name TEXT NOT NULL,
      item_count INTEGER DEFAULT 1,
      corpse_id INTEGER DEFAULT 0,
      npc_name TEXT,
      npc_id INTEGER DEFAULT 0,
      dropped_by TEXT,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
      server_name TEXT
    );
    
    CREATE INDEX IF NOT EXISTS idx_loot_stats_drops_item_name ON loot_stats_drops(item_name);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_drops_item_id ON loot_stats_drops(item_id);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_drops_zone ON loot_stats_drops(zone_name);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_drops_timestamp ON loot_stats_drops(timestamp);
    CREATE INDEX IF NOT EXISTS idx_loot_stats_drops_server ON loot_stats_drops(server_name);
    
    CREATE TABLE IF NOT EXISTS global_loot_order (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      peer_name TEXT NOT NULL,
      order_position INTEGER NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(peer_name),
      UNIQUE(order_position)
    );
    
    CREATE INDEX IF NOT EXISTS idx_global_loot_order_position ON global_loot_order(order_position);
    
    CREATE TRIGGER IF NOT EXISTS update_global_loot_order_timestamp 
    AFTER UPDATE ON global_loot_order
    BEGIN
      UPDATE global_loot_order SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
    END;
  ]]

  local result = db:exec(createTables)
  if result ~= sqlite3.OK then
    logging.debug("[Database] Failed to create tables: " .. db:errmsg())
    
    -- Try to migrate the database schema
    logging.debug("[Database] Attempting schema migration...")
    local migrationResult = migrateDatabase(db)
    if not migrationResult then
      logging.debug("[Database] Schema migration failed")
      db:close()
      db = nil
      return nil
    end
    
    -- Try creating tables again after migration
    result = db:exec(createTables)
    if result ~= sqlite3.OK then
      logging.debug("[Database] Failed to create tables after migration: " .. db:errmsg())
      db:close()
      db = nil
      return nil
    end
  end

  logging.debug("[Database] SQLite database initialized: " .. DB_PATH)
  return db
end

-- Get database connection
local function getConnection()
  if not db then
    return initializeDatabase()
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

-- Fetch every rule in the DB and repopulate the full cache - PROPER CASE
function database.fetchAllRulesFromDB()
  logging.debug("[Database] fetchAllRulesFromDB")
  
  local stmt, err = prepareStatement([[
    SELECT toon, item_name, rule, item_id, icon_id
    FROM lootrules
  ]])
  
  if not stmt then
    logging.debug("[Database] fetchAllRulesFromDB error: " .. tostring(err))
    return false
  end

  local temp = {}
  local total = 0
  
  for row in stmt:nrows() do
    local toonKey = row.toon  -- KEEP ORIGINAL CASE FOR TOON TOO
    local itemName = row.item_name   -- KEEP ORIGINAL CASE

    temp[toonKey] = temp[toonKey] or {}
    temp[toonKey][itemName] = {  -- Use original case as key
      rule    = row.rule,
      item_id = tonumber(row.item_id),
      icon_id = tonumber(row.icon_id),
    }
    total = total + 1
  end

  stmt:finalize()

  lootRulesCache  = temp
  fullCacheLoaded = true
  logging.debug(("[Database] Full cache loaded (%d rules)"):format(total))
  return true
end

-- Fetch only the current toon's rules into the cache - PROPER CASE
function database.refreshLootRuleCache()
  local toonKey = mq.TLO.Me.Name() or "unknown"  -- KEEP ORIGINAL CASE
  logging.debug("[Database] refreshLootRuleCache for " .. toonKey)

  local stmt, err = prepareStatement([[
    SELECT item_name, rule, item_id, icon_id 
    FROM lootrules 
    WHERE toon = ?
  ]])
  
  if not stmt then
    logging.debug(("[Database] refreshLootRuleCache error for %s: %s"):format(toonKey, tostring(err)))
    return false
  end

  stmt:bind(1, toonKey)
  logging.debug(string.format("[Database] Querying with toon='%s'", toonKey))
  
  lootRulesCache[toonKey] = {}
  local count = 0
  
  for row in stmt:nrows() do
    local itemName = row.item_name  -- KEEP ORIGINAL CASE
    logging.debug(string.format("[Database] Found rule: item='%s', rule='%s'", itemName, row.rule))
    lootRulesCache[toonKey][itemName] = {  -- Use original case as key
      rule    = row.rule,
      item_id = tonumber(row.item_id),
      icon_id = tonumber(row.icon_id),
    }
    count = count + 1
  end

  stmt:finalize()
  logging.debug(("[Database] Cached %d rules for %s"):format(count, toonKey))
  return true
end

-- ENHANCED: Save with proper case and better ID handling
function database.saveLootRuleFor(toonName, itemName, itemID, rule, iconID)
  if not toonName or toonName == "Local" then
    toonName = mq.TLO.Me.Name() or "unknown"
  end
  local toonKey = toonName  -- KEEP ORIGINAL CASE
  if not itemName or not rule then
    logging.debug("[Database] saveLootRuleFor: missing itemName or rule")
    return false
  end
  
  -- IMPORTANT: Try to get existing itemID from database first (by item name)
  if not itemID or itemID == 0 then
    local stmt, err = prepareStatement([[
      SELECT item_id, icon_id FROM lootrules 
      WHERE item_name LIKE ? AND item_id > 0 
      ORDER BY updated_at DESC LIMIT 1
    ]])
    
    if stmt then
      stmt:bind(1, itemName)
      local row = stmt:step()
      if row == sqlite3.ROW then
        local existingItemID = stmt:get_value(0)
        local existingIconID = stmt:get_value(1)
        if existingItemID and existingItemID > 0 then
          itemID = existingItemID
          if not iconID or iconID == 0 then
            iconID = existingIconID
          end
          logging.debug(string.format("[Database] Using existing itemID %d for '%s'", itemID, itemName))
        end
      end
      stmt:finalize()
    end
  end
  
  -- If still no itemID, try to get from game
  if not itemID or itemID == 0 then
    local findItem = mq.TLO.FindItem(itemName)
    if findItem and findItem.ID() then
      itemID = findItem.ID()
      if not iconID or iconID == 0 then
        iconID = findItem.Icon() or 0
      end
      logging.debug(string.format("[Database] Got itemID %d from game for '%s'", itemID, itemName))
    end
  end
  
  -- Ensure we have valid IDs
  itemID = tonumber(itemID) or 0
  iconID = tonumber(iconID) or 0

  local stmt, err = prepareStatement([[
    INSERT OR REPLACE INTO lootrules 
    (item_id, item_name, toon, rule, icon_id, updated_at)
    VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
  ]])
  
  if not stmt then
    logging.debug(("[Database] saveLootRuleFor prepare error: %s"):format(tostring(err)))
    return false
  end

  stmt:bind(1, itemID)
  stmt:bind(2, itemName)  -- STORE ORIGINAL CASE
  stmt:bind(3, toonKey)   -- STORE ORIGINAL CASE
  stmt:bind(4, rule)
  stmt:bind(5, iconID)

  local result = stmt:step()
  stmt:finalize()
  
  if result ~= sqlite3.DONE then
    logging.debug(("[Database] saveLootRuleFor error: %s"):format(getConnection():errmsg()))
    return false
  end

  -- update local cache - USE ORIGINAL CASE
  lootRulesCache[toonKey] = lootRulesCache[toonKey] or {}
  lootRulesCache[toonKey][itemName] = {  -- Use original case as key
    rule    = rule,
    item_id = itemID,
    icon_id = iconID,
  }
  logging.debug(("[Database] Saved rule for %s: %s → %s (itemID: %d, iconID: %d)"):format(toonKey, itemName, rule, itemID, iconID))
  return true
end

-- Convenience wrapper for CURRENT toon
function database.saveLootRule(itemName, itemID, rule, iconID)
  return database.saveLootRuleFor(mq.TLO.Me.Name(), itemName, itemID, rule, iconID)
end

-- ENHANCED: Get rule with itemID priority and case-insensitive fallback
function database.getLootRule(itemName, returnFull)
  local toonKey = mq.TLO.Me.Name() or "unknown"  -- KEEP ORIGINAL CASE

  -- first, ensure we have something in cache
  if not lootRulesCache[toonKey] then
    database.refreshLootRuleCache()
  end

  -- STRATEGY 1: Try exact case match first
  local rd = lootRulesCache[toonKey] and lootRulesCache[toonKey][itemName]
  
  -- STRATEGY 2: If no exact match, try case-insensitive search in cache
  if not rd and lootRulesCache[toonKey] then
    local lowerItemName = itemName:lower()
    for cachedItemName, cachedRule in pairs(lootRulesCache[toonKey]) do
      if cachedItemName:lower() == lowerItemName then
        rd = cachedRule
        logging.debug(string.format("[Database] Found rule via case-insensitive match: '%s' -> '%s'", cachedItemName, itemName))
        break
      end
    end
  end

  -- STRATEGY 3: If still no match, try loading all rules and search again
  if not rd and not fullCacheLoaded then
    database.fetchAllRulesFromDB()
    -- Try exact match again
    rd = lootRulesCache[toonKey] and lootRulesCache[toonKey][itemName]
    
    -- Try case-insensitive again
    if not rd and lootRulesCache[toonKey] then
      local lowerItemName = itemName:lower()
      for cachedItemName, cachedRule in pairs(lootRulesCache[toonKey]) do
        if cachedItemName:lower() == lowerItemName then
          rd = cachedRule
          break
        end
      end
    end
  end

  -- STRATEGY 4: If still no match, query database directly with LIKE
  if not rd then
    local stmt, err = prepareStatement([[
      SELECT rule, item_id, icon_id FROM lootrules 
      WHERE toon = ? AND item_name LIKE ? 
      ORDER BY updated_at DESC LIMIT 1
    ]])
    
    if stmt then
      stmt:bind(1, toonKey)
      stmt:bind(2, itemName)
      local row = stmt:step()
      if row == sqlite3.ROW then
        rd = {
          rule = stmt:get_value(0),
          item_id = tonumber(stmt:get_value(1)),
          icon_id = tonumber(stmt:get_value(2))
        }
        logging.debug(string.format("[Database] Found rule via database LIKE search for '%s'", itemName))
      end
      stmt:finalize()
    end
  end

  if rd then
    logging.debug(string.format("[Database] Found rule for '%s': '%s'", itemName, rd.rule))
  else
    logging.debug(string.format("[Database] No rule found for '%s' for toon '%s'", itemName, toonKey))
  end

  if returnFull then
    return rd and rd.rule   or nil,
           rd and rd.item_id or nil,
           rd and rd.icon_id or nil
  else
    return rd and rd.rule or nil
  end
end

function database.refreshLootRuleCacheForPeer(peerName)
  local peerKey = peerName  -- KEEP ORIGINAL CASE
  logging.debug("[Database] refreshLootRuleCacheForPeer for " .. peerName)

  local stmt, err = prepareStatement([[
    SELECT item_name, rule, item_id, icon_id
    FROM lootrules
    WHERE toon = ?
  ]])

  if not stmt then
    logging.debug(("[Database] refreshLootRuleCacheForPeer error for %s: %s"):format(peerName, tostring(err)))
    return false
  end

  stmt:bind(1, peerKey)

  lootRulesCache[peerKey] = {} -- Clear existing cache for this peer
  local count = 0

  for row in stmt:nrows() do
    local itemName = row.item_name  -- KEEP ORIGINAL CASE
    lootRulesCache[peerKey][itemName] = {  -- Use original case as key
      rule    = row.rule,
      item_id = tonumber(row.item_id),
      icon_id = tonumber(row.icon_id),
    }
    count = count + 1
  end

  stmt:finalize()
  logging.debug(("[Database] Cached %d rules for peer %s"):format(count, peerName))
  return true
end

function database.getLootRulesForPeer(peerName)
  if not peerName or peerName == "Local" then
    return database.getAllLootRules()
  end

  local peerKey = peerName:lower()

  -- First, try to get from cache
  if lootRulesCache[peerKey] then
      logging.debug(("[Database] Returning cached rules for peer %s"):format(peerName))
      return lootRulesCache[peerKey]
  end

  -- If not in cache, fetch from DB and populate cache
  logging.debug(("[Database] Fetching rules for peer %s from DB (not in cache)"):format(peerName))
  database.refreshLootRuleCacheForPeer(peerName) -- This will populate the cache

  return lootRulesCache[peerKey] or {}
end

-- Return the entire per‐toon rule table (for UI) - PROPER CASE
function database.getAllLootRulesForUI()
  if not fullCacheLoaded then
    database.fetchAllRulesFromDB()
  end
  return lootRulesCache
end

-- Return just the current toon's full table - PROPER CASE
function database.getAllLootRules()
  local toonKey = mq.TLO.Me.Name() or "unknown"  -- KEEP ORIGINAL CASE
  logging.debug(string.format("[Database] getAllLootRules for toonKey='%s'", toonKey))
  
  if not lootRulesCache[toonKey] then
    logging.debug("[Database] Cache miss, calling refreshLootRuleCache()")
    database.refreshLootRuleCache()
  else
    logging.debug("[Database] Cache hit")
  end
  
  local rules = lootRulesCache[toonKey] or {}
  local count = 0
  for _ in pairs(rules) do count = count + 1 end
  logging.debug(string.format("[Database] Returning %d rules from cache", count))
  
  return rules
end

-- ENHANCED: Fetch a peer's rules with proper case handling
function database.getLootRulesForPeer(peerName)
  if not peerName or peerName == "Local" then
    return database.getAllLootRules()
  end

  local peerKey = peerName  -- KEEP ORIGINAL CASE
  
  local stmt, err = prepareStatement([[
    SELECT item_name, rule, item_id, icon_id 
    FROM lootrules 
    WHERE toon = ?
  ]])
  
  if not stmt then
    logging.debug(("[Database] getLootRulesForPeer error: %s"):format(tostring(err)))
    return {}
  end

  stmt:bind(1, peerKey)
  
  local out = {}
  for row in stmt:nrows() do
    local itemName = row.item_name  -- KEEP ORIGINAL CASE
    out[itemName] = {  -- Use original case as key
      rule    = row.rule,
      item_id = tonumber(row.item_id),
      icon_id = tonumber(row.icon_id),
    }
  end

  stmt:finalize()
  return out
end

-- Get all character names that have loot rules
function database.getAllCharactersWithRules()
  local stmt, err = prepareStatement([[
    SELECT DISTINCT toon FROM lootrules ORDER BY toon
  ]])
  
  if not stmt then
    logging.debug("[Database] getAllCharactersWithRules error: " .. tostring(err))
    return {}
  end

  local characters = {}
  for row in stmt:nrows() do
    -- Convert back to proper case for display
    local displayName = row.toon
    -- Capitalize first letter if it's all lowercase
    if displayName == displayName:lower() then
      displayName = displayName:sub(1,1):upper() .. displayName:sub(2)
    end
    table.insert(characters, displayName)
  end

  stmt:finalize()
  return characters
end

-- Update item & icon IDs for *all* matching rules by item name
function database.updateItemAndIconForAll(itemName, newItemID, newIconID)
  if not itemName then
    logging.debug("[Database] updateItemAndIconForAll: missing itemName")
    return false
  end

  local stmt, err = prepareStatement([[
    UPDATE lootrules 
    SET item_id = ?, icon_id = ?, updated_at = CURRENT_TIMESTAMP 
    WHERE item_name LIKE ?
  ]])
  
  if not stmt then
    logging.debug(("[Database] updateItemAndIconForAll prepare error: %s"):format(tostring(err)))
    return false
  end

  stmt:bind(1, tonumber(newItemID))
  stmt:bind(2, tonumber(newIconID))
  stmt:bind(3, itemName)

  local result = stmt:step()
  stmt:finalize()
  
  if result ~= sqlite3.DONE then
    logging.debug(("[Database] updateItemAndIconForAll error: %s"):format(getConnection():errmsg()))
    return false
  end

  -- clear cache so next time we re‐pull fresh
  fullCacheLoaded = false
  lootRulesCache  = {}
  logging.debug(("[Database] updateItemAndIconForAll: cleared cache for %s"):format(itemName))
  return true
end

-- Fix existing entries with itemID = 0 by finding valid itemIDs
function database.fixZeroItemIDs()
  logging.debug("[Database] Starting fix for zero itemIDs...")
  
  -- Get all unique item names that have both 0 and non-0 itemIDs
  local stmt, err = prepareStatement([[
    SELECT DISTINCT item_name 
    FROM lootrules 
    WHERE item_name IN (
      SELECT item_name FROM lootrules WHERE item_id > 0
    ) AND item_id = 0
  ]])
  
  if not stmt then
    logging.debug("[Database] fixZeroItemIDs query error: " .. tostring(err))
    return false
  end
  
  local itemsToFix = {}
  for row in stmt:nrows() do
    table.insert(itemsToFix, row.item_name)
  end
  stmt:finalize()
  
  local fixedCount = 0
  for _, itemName in ipairs(itemsToFix) do
    -- Get a valid itemID and iconID for this item
    local getValidIDStmt, err = prepareStatement([[
      SELECT item_id, icon_id FROM lootrules 
      WHERE item_name LIKE ? AND item_id > 0 
      ORDER BY updated_at DESC LIMIT 1
    ]])
    
    if getValidIDStmt then
      getValidIDStmt:bind(1, itemName)
      local row = getValidIDStmt:step()
      if row == sqlite3.ROW then
        local validItemID = getValidIDStmt:get_value(0)
        local validIconID = getValidIDStmt:get_value(1)
        
        -- Update all entries with itemID = 0 for this item
        local updateStmt, err = prepareStatement([[
          UPDATE lootrules 
          SET item_id = ?, icon_id = COALESCE(NULLIF(icon_id, 0), ?), updated_at = CURRENT_TIMESTAMP
          WHERE item_name LIKE ? AND item_id = 0
        ]])
        
        if updateStmt then
          updateStmt:bind(1, validItemID)
          updateStmt:bind(2, validIconID)
          updateStmt:bind(3, itemName)
          
          local result = updateStmt:step()
          if result == sqlite3.DONE then
            local changes = getConnection():changes()
            fixedCount = fixedCount + changes
            logging.debug(string.format("[Database] Fixed %d entries for '%s' with itemID %d", 
                                    changes, itemName, validItemID))
          end
          updateStmt:finalize()
        end
      end
      getValidIDStmt:finalize()
    end
  end
  
  logging.debug(string.format("[Database] Fixed %d total entries with zero itemIDs", fixedCount))
  
  -- Clear cache so it gets reloaded with fixed data
  fullCacheLoaded = false
  lootRulesCache = {}
  
  return fixedCount > 0
end

-- Cleanup function to close database
function database.close()
  logging.debug("[Database] Closing SQLite database...")
  
  if db then
    db:close()
    db = nil
    logging.debug("[Database] SQLite database closed")
  end
  
  -- Clear caches
  lootRulesCache = {}
  fullCacheLoaded = false
  
  logging.debug("[Database] All resources cleaned up")
end

-- Health check function
function database.healthCheck()
  local conn = getConnection()
  if not conn then
    return false, "No database connection"
  end
  
  local stmt, err = prepareStatement("SELECT 1 as test")
  if not stmt then
    return false, err
  end
  
  local result = stmt:step()
  stmt:finalize()
  
  if result == sqlite3.ROW then
    return true
  else
    return false, "Health check query failed"
  end
end

-- Get database status for debugging
function database.getStatus()
  local status = {
    dbPath = DB_PATH,
    isOpen = db ~= nil,
    cacheLoaded = fullCacheLoaded,
    cachedToons = next(lootRulesCache) and table.concat(vim.tbl_keys(lootRulesCache), ", ") or "none"
  }
  
  -- Add statistics about zero itemIDs
  if db then
    local stmt = db:prepare("SELECT COUNT(*) FROM lootrules WHERE item_id = 0")
    if stmt then
      local row = stmt:step()
      if row == sqlite3.ROW then
        status.zeroItemIDs = stmt:get_value(0)
      end
      stmt:finalize()
    end
    
    local stmt2 = db:prepare("SELECT COUNT(DISTINCT item_name) FROM lootrules WHERE item_id > 0")
    if stmt2 then
      local row = stmt2:step()
      if row == sqlite3.ROW then
        status.itemsWithValidIDs = stmt2:get_value(0)
      end
      stmt2:finalize()
    end
  end
  
  return status
end

return database