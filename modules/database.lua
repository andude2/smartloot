-- modules/database.lua - SQLite Database Module
local database = {}
local mq       = require("mq")
local logging  = require("modules.logging")
local sqlite3  = require("lsqlite3")

local currentServerName = mq.TLO.EverQuest.Server()
local sanitizedServerName = currentServerName:lower():gsub(" ", "_")

-- Database Configuration
local DB_PATH = mq.TLO.MacroQuest.Path('resources')() .. "/smartloot_" .. sanitizedServerName .. ".db"

-- Enhanced cache structure supporting both itemID and name lookups
local lootRulesCache = {
    byItemID = {},      -- [toon][itemID] = rule data
    byName = {},        -- [toon][itemName] = rule data (fallback)
    itemMappings = {},  -- [itemID] = { name, iconID }
    loaded = {}         -- [toon] = true/false
}

-- Database connection
local db = nil

-- Create database tables
local function createDatabaseTables(conn)
    logging.debug("[Database] Creating database tables...")
    
    -- Create all required tables
    local createTables = [[
        -- ItemID-based table
        CREATE TABLE IF NOT EXISTS lootrules_v2 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            toon TEXT NOT NULL,
            item_id INTEGER NOT NULL,
            item_name TEXT NOT NULL,
            rule TEXT NOT NULL,
            icon_id INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(toon, item_id)
        );
        
        CREATE INDEX IF NOT EXISTS idx_lootrules_v2_toon_itemid ON lootrules_v2(toon, item_id);
        CREATE INDEX IF NOT EXISTS idx_lootrules_v2_itemid ON lootrules_v2(item_id);
        CREATE INDEX IF NOT EXISTS idx_lootrules_v2_toon ON lootrules_v2(toon);
        CREATE INDEX IF NOT EXISTS idx_lootrules_v2_item_name ON lootrules_v2(item_name);
        
        -- Name-based fallback table for items without IDs
        CREATE TABLE IF NOT EXISTS lootrules_name_fallback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            toon TEXT NOT NULL,
            item_name TEXT NOT NULL,
            rule TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(toon, item_name)
        );
        
        CREATE INDEX IF NOT EXISTS idx_lootrules_fallback_toon_name ON lootrules_name_fallback(toon, item_name);
        
        -- ItemID mapping table for tracking different items with same name
        CREATE TABLE IF NOT EXISTS item_id_mappings (
            item_id INTEGER PRIMARY KEY,
            item_name TEXT NOT NULL,
            icon_id INTEGER DEFAULT 0,
            first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
            last_seen DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE INDEX IF NOT EXISTS idx_item_mappings_name ON item_id_mappings(item_name);
    ]]
    
    local result = conn:exec(createTables)
    if result ~= sqlite3.OK then
        logging.error("[Database] Failed to create tables: " .. conn:errmsg())
        return false
    end
    
    logging.debug("[Database] Tables created successfully")
    return true
end

-- Initialize database connection and create tables
local function initializeDatabase()
    if db then
        return db
    end

    db = sqlite3.open(DB_PATH)
    if not db then
        logging.error("[Database] Failed to open SQLite database: " .. DB_PATH)
        return nil
    end

    -- Enable foreign keys and case-insensitive LIKE
    db:exec("PRAGMA foreign_keys = ON")
    db:exec("PRAGMA case_sensitive_like = OFF")
    
    -- Enable WAL mode for better concurrency and reduced locking
    db:exec("PRAGMA journal_mode = WAL")
    db:exec("PRAGMA synchronous = NORMAL") -- Better performance with WAL
    db:exec("PRAGMA wal_autocheckpoint = 1000") -- Checkpoint every 1000 pages
    db:exec("PRAGMA temp_store = MEMORY") -- Use memory for temp tables
    db:exec("PRAGMA busy_timeout = 5000") -- Handle SQLITE_BUSY errors (5 seconds)
    db:exec("PRAGMA journal_size_limit = 67108864") -- Limit WAL file size (64MB)
    db:exec("PRAGMA mmap_size = 268435456") -- Enable memory-mapped I/O (256MB)
    
    -- Create database tables
    if not createDatabaseTables(db) then
        logging.error("[Database] Failed to create database tables")
        db:close()
        db = nil
        return nil
    end
    
    -- Create other tables that remain unchanged
    local createOtherTables = [[
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

    local result = db:exec(createOtherTables)
    if result ~= sqlite3.OK then
        logging.error("[Database] Failed to create auxiliary tables: " .. db:errmsg())
        db:close()
        db = nil
        return nil
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
    
    local stmt, err = conn:prepare(sql)
    if not stmt then
        logging.error("[Database] Failed to prepare statement: " .. (err or "unknown error"))
        return nil, err
    end
    
    return stmt
end

-- ============================================================================
-- CACHE MANAGEMENT
-- ============================================================================

-- Load cache with dual lookup support
function database.refreshLootRuleCache()
    local toonName = mq.TLO.Me.Name() or "unknown"
    logging.debug(string.format("[Database] Refreshing loot rule cache for %s", toonName))
    
    -- Clear existing cache for this toon
    lootRulesCache.byItemID[toonName] = {}
    lootRulesCache.byName[toonName] = {}
    
    -- Load itemID-based rules
    local stmt1 = prepareStatement([[
        SELECT item_id, item_name, rule, icon_id 
        FROM lootrules_v2 
        WHERE toon = ?
    ]])
    
    if stmt1 then
        stmt1:bind(1, toonName)
        
        local count = 0
        for row in stmt1:nrows() do
            local data = {
                rule = row.rule,
                item_name = row.item_name,
                item_id = row.item_id,
                icon_id = row.icon_id,
                tableSource = "lootrules_v2"
            }
            lootRulesCache.byItemID[toonName][row.item_id] = data
            
            -- Also cache the mapping
            lootRulesCache.itemMappings[row.item_id] = {
                name = row.item_name,
                iconID = row.icon_id
            }
            count = count + 1
        end
        stmt1:finalize()
        logging.debug(string.format("[Database] Loaded %d itemID-based rules", count))
    end
    
    -- Load name-based fallback rules
    local stmt2 = prepareStatement([[
        SELECT item_name, rule 
        FROM lootrules_name_fallback 
        WHERE toon = ?
    ]])
    
    if stmt2 then
        stmt2:bind(1, toonName)
        
        local count = 0
        for row in stmt2:nrows() do
            lootRulesCache.byName[toonName][row.item_name] = {
                rule = row.rule,
                item_name = row.item_name,
                item_id = 0,
                icon_id = 0,
                tableSource = "lootrules_name_fallback"
            }
            count = count + 1
        end
        stmt2:finalize()
        logging.debug(string.format("[Database] Loaded %d name-based fallback rules", count))
    end
    
    lootRulesCache.loaded[toonName] = true
end

-- ============================================================================
-- CORE LOOKUP FUNCTIONS
-- ============================================================================

-- Get loot rule by itemID (primary lookup method)
function database.getLootRuleByItemID(itemID, toonName)
    toonName = toonName or mq.TLO.Me.Name()
    
    -- Check cache first
    if lootRulesCache.byItemID[toonName] and lootRulesCache.byItemID[toonName][itemID] then
        local data = lootRulesCache.byItemID[toonName][itemID]
        return data.rule, data.item_name, data.icon_id
    end
    
    -- Query database
    local stmt = prepareStatement([[
        SELECT rule, item_name, icon_id 
        FROM lootrules_v2 
        WHERE toon = ? AND item_id = ?
    ]])
    
    if not stmt then
        return nil
    end
    
    stmt:bind(1, toonName)
    stmt:bind(2, itemID)
    
    local row = stmt:step()
    if row == sqlite3.ROW then
        local rule = stmt:get_value(0)
        local itemName = stmt:get_value(1)
        local iconID = stmt:get_value(2)
        stmt:finalize()
        
        -- Update cache
        if not lootRulesCache.byItemID[toonName] then
            lootRulesCache.byItemID[toonName] = {}
        end
        lootRulesCache.byItemID[toonName][itemID] = {
            rule = rule,
            item_name = itemName,
            item_id = itemID,
            icon_id = iconID
        }
        
        return rule, itemName, iconID
    end
    stmt:finalize()
    
    return nil
end

-- Enhanced getLootRule with itemID priority and name fallback
function database.getLootRule(itemName, returnFull, itemID)
    local toonName = mq.TLO.Me.Name() or "unknown"
    
    -- Ensure cache is loaded
    if not lootRulesCache.loaded[toonName] then
        database.refreshLootRuleCache()
    end
    
    -- Strategy 1: Try by itemID first if available
    if itemID and itemID > 0 then
        local rule, storedName, iconID = database.getLootRuleByItemID(itemID, toonName)
        if rule then
            logging.debug(string.format("[Database] Found rule by itemID %d: %s -> %s", itemID, itemName, rule))
            if returnFull then
                return rule, itemID, iconID
            else
                return rule
            end
        end
    end
    
    -- Strategy 2: Check name-based cache
    if lootRulesCache.byName[toonName] and lootRulesCache.byName[toonName][itemName] then
        local data = lootRulesCache.byName[toonName][itemName]
        logging.debug(string.format("[Database] Found rule by name (cache): %s -> %s", itemName, data.rule))
        if returnFull then
            return data.rule, 0, 0
        else
            return data.rule
        end
    end
    
    -- Strategy 3: Case-insensitive search in name cache
    if lootRulesCache.byName[toonName] then
        local lowerName = itemName:lower()
        for cachedName, data in pairs(lootRulesCache.byName[toonName]) do
            if cachedName:lower() == lowerName then
                logging.debug(string.format("[Database] Found rule by name (case-insensitive): %s -> %s", itemName, data.rule))
                if returnFull then
                    return data.rule, 0, 0
                else
                    return data.rule
                end
            end
        end
    end
    
    -- Strategy 4: Database query for name-based fallback
    local stmt = prepareStatement([[
        SELECT rule 
        FROM lootrules_name_fallback 
        WHERE toon = ? AND item_name LIKE ?
    ]])
    
    if stmt then
        stmt:bind(1, toonName)
        stmt:bind(2, itemName)
        
        local row = stmt:step()
        if row == sqlite3.ROW then
            local rule = stmt:get_value(0)
            stmt:finalize()
            
            logging.debug(string.format("[Database] Found rule by name (database): %s -> %s", itemName, rule))
            
            -- Auto-upgrade: If we have an ItemID, upgrade the rule to the main table
            if itemID and itemID > 0 then
                local findItem = mq.TLO.FindItem(itemName)
                local iconID = 0
                if findItem and findItem.Icon() then
                    iconID = findItem.Icon()
                end
                
                -- Save to main table with ItemID
                local success = database.saveLootRuleFor(toonName, itemName, itemID, rule, iconID)
                if success then
                    logging.info(string.format("[Database] Auto-upgraded rule: %s (ID:%d) -> %s for %s", 
                        itemName, itemID, rule, toonName))
                    
                    -- Remove from fallback table
                    local deleteStmt = prepareStatement([[
                        DELETE FROM lootrules_name_fallback 
                        WHERE toon = ? AND item_name = ?
                    ]])
                    if deleteStmt then
                        deleteStmt:bind(1, toonName)
                        deleteStmt:bind(2, itemName)
                        deleteStmt:step()
                        deleteStmt:finalize()
                        logging.debug(string.format("[Database] Removed %s from fallback table after upgrade", itemName))
                    end
                    
                    -- Update cache to reflect the upgrade
                    if lootRulesCache.byName[toonName] then
                        lootRulesCache.byName[toonName][itemName] = nil
                    end
                    
                    if returnFull then
                        return rule, itemID, iconID
                    else
                        return rule
                    end
                else
                    logging.warn(string.format("[Database] Failed to auto-upgrade rule for %s", itemName))
                end
            end
            
            -- Update cache (fallback case or failed upgrade)
            if not lootRulesCache.byName[toonName] then
                lootRulesCache.byName[toonName] = {}
            end
            lootRulesCache.byName[toonName][itemName] = {
                rule = rule,
                item_name = itemName,
                item_id = 0,
                icon_id = 0
            }
            
            if returnFull then
                return rule, 0, 0
            else
                return rule
            end
        end
        stmt:finalize()
    end
    
    logging.debug(string.format("[Database] No rule found for '%s' (itemID: %s)", itemName, tostring(itemID)))
    return nil
end

-- ============================================================================
-- SAVE FUNCTIONS
-- ============================================================================

-- Save loot rule - SIMPLIFIED: itemID-based only
function database.saveLootRuleFor(toonName, itemName, itemID, rule, iconID)
    if not toonName or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    
    if not itemName or not rule then
        logging.error("[Database] saveLootRuleFor: missing itemName or rule")
        return false
    end
    
    itemID = tonumber(itemID) or 0
    iconID = tonumber(iconID) or 0
    
    -- REQUIRE valid itemID from game only
    if itemID <= 0 then
        -- Try to get from game
        local findItem = mq.TLO.FindItem(itemName)
        if findItem and findItem.ID() and findItem.ID() > 0 then
            itemID = findItem.ID()
            iconID = findItem.Icon() or iconID
        else
            logging.error(string.format("[Database] Cannot save rule for '%s' - no valid itemID available from game", itemName))
            return false
        end
    end
    
    logging.debug(string.format("[Database] Saving rule: %s (itemID:%d, iconID:%d) -> %s for %s", 
                  itemName, itemID, iconID, rule, toonName))
    
    -- Update item mapping
    local mappingStmt = prepareStatement([[
        INSERT OR REPLACE INTO item_id_mappings 
        (item_id, item_name, icon_id, last_seen)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if mappingStmt then
        mappingStmt:bind(1, itemID)
        mappingStmt:bind(2, itemName)
        mappingStmt:bind(3, iconID)
        mappingStmt:step()
        mappingStmt:finalize()
    end
    
    -- Save rule to itemID-based table ONLY
    local stmt = prepareStatement([[
        INSERT OR REPLACE INTO lootrules_v2 
        (toon, item_id, item_name, rule, icon_id, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if not stmt then
        return false
    end
    
    stmt:bind(1, toonName)
    stmt:bind(2, itemID)
    stmt:bind(3, itemName)
    stmt:bind(4, rule)
    stmt:bind(5, iconID)
    
    local result = stmt:step()
    stmt:finalize()
    
    if result == sqlite3.DONE then
        -- Update cache
        if not lootRulesCache.byItemID[toonName] then
            lootRulesCache.byItemID[toonName] = {}
        end
        lootRulesCache.byItemID[toonName][itemID] = {
            rule = rule,
            item_name = itemName,
            item_id = itemID,
            icon_id = iconID
        }
        
        -- Clean up any old fallback entries for this item
        local deleteStmt = prepareStatement([[
            DELETE FROM lootrules_name_fallback 
            WHERE toon = ? AND item_name LIKE ?
        ]])
        
        if deleteStmt then
            deleteStmt:bind(1, toonName)
            deleteStmt:bind(2, itemName)
            deleteStmt:step()
            deleteStmt:finalize()
            
            -- Remove from name cache
            if lootRulesCache.byName[toonName] then
                lootRulesCache.byName[toonName][itemName] = nil
            end
        end
        
        logging.info(string.format("[Database] Saved itemID-based rule: %s (ID:%d) -> %s for %s", itemName, itemID, rule, toonName))
        return true
    end
    
    logging.error(string.format("[Database] Failed to save rule for %s", itemName))
    return false
end

-- Save name-based rule for peer (no itemID required)
function database.saveLootRuleForNameBased(toonName, itemName, rule)
    if not toonName or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    
    if not itemName or not rule then
        logging.error("[Database] saveLootRuleForNameBased: missing itemName or rule")
        return false
    end
    
    logging.debug(string.format("[Database] Saving name-based rule: %s -> %s for %s", 
                  itemName, rule, toonName))
    
    -- Save to name-based fallback table
    local stmt = prepareStatement([[
        INSERT OR REPLACE INTO lootrules_name_fallback 
        (character_name, item_name, loot_rule, last_updated)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if stmt then
        stmt:bind(1, toonName)
        stmt:bind(2, itemName)
        stmt:bind(3, rule)
        
        local result = stmt:step()
        stmt:finalize()
        
        if result == sqlite3.DONE then
            -- Update cache
            if not lootRulesCache.byName[toonName] then
                lootRulesCache.byName[toonName] = {}
            end
            lootRulesCache.byName[toonName][itemName] = {
                rule = rule,
                tableSource = "lootrules_name_fallback"
            }
            
            logging.info(string.format("[Database] Saved name-based rule: %s -> %s for %s", itemName, rule, toonName))
            return true
        end
    end
    
    logging.error(string.format("[Database] Failed to save name-based rule for %s", itemName))
    return false
end

-- Convenience function for current character
function database.saveLootRule(itemName, itemID, rule, iconID)
    return database.saveLootRuleFor(mq.TLO.Me.Name(), itemName, itemID, rule, iconID)
end

-- Save name-based rule to fallback table (for items without known IDs)
function database.saveNameBasedRuleFor(toonName, itemName, rule)
    if not toonName or toonName == "Local" then
        toonName = mq.TLO.Me.Name() or "unknown"
    end
    
    if not itemName or not rule then
        logging.error("[Database] saveNameBasedRuleFor: missing itemName or rule")
        return false
    end
    
    local stmt = prepareStatement([[
        INSERT OR REPLACE INTO lootrules_name_fallback
        (toon, item_name, rule, created_at, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    ]])
    
    if stmt then
        stmt:bind(1, toonName)
        stmt:bind(2, itemName)
        stmt:bind(3, rule)
        
        local result = stmt:step()
        stmt:finalize()
        
        if result == sqlite3.DONE then
            logging.debug(string.format("[Database] Saved name-based rule: %s -> %s for %s", itemName, rule, toonName))
            
            -- Update cache
            if not lootRulesCache.byName[toonName] then
                lootRulesCache.byName[toonName] = {}
            end
            lootRulesCache.byName[toonName][itemName] = {
                rule = rule,
                itemID = 0,
                iconID = 0
            }
            
            return true
        end
    end
    
    logging.error(string.format("[Database] Failed to save name-based rule for %s", itemName))
    return false
end

-- Convenience function for current character (name-based)
function database.saveNameBasedRule(itemName, rule)
    return database.saveNameBasedRuleFor(mq.TLO.Me.Name(), itemName, rule)
end

-- ============================================================================
-- MAINTENANCE FUNCTIONS
-- ============================================================================

-- Function to check if an item exists in fallback and attempt to resolve its ID
function database.resolveItemIDFromFallback(itemName)
    -- Try to get itemID from game
    local findItem = mq.TLO.FindItem(itemName)
    if findItem and findItem.ID() and findItem.ID() > 0 then
        return findItem.ID(), findItem.Icon() or 0
    end
    
    -- Try to get from item mappings
    local stmt = prepareStatement([[
        SELECT item_id, icon_id 
        FROM item_id_mappings 
        WHERE item_name LIKE ? 
        ORDER BY last_seen DESC 
        LIMIT 1
    ]])
    
    if not stmt then
        return 0, 0
    end
    
    stmt:bind(1, itemName)
    local row = stmt:step()
    if row == sqlite3.ROW then
        local itemID = stmt:get_value(0)
        local iconID = stmt:get_value(1)
        stmt:finalize()
        return itemID, iconID
    end
    stmt:finalize()
    
    return 0, 0
end

-- Periodic task to migrate fallback entries when IDs become available
function database.migrateFallbackEntries()
    logging.debug("[Database] Checking for fallback entries to migrate...")
    
    local stmt = prepareStatement([[
        SELECT DISTINCT item_name 
        FROM lootrules_name_fallback
    ]])
    
    if not stmt then
        return
    end
    
    local itemsToMigrate = {}
    for row in stmt:nrows() do
        table.insert(itemsToMigrate, row.item_name)
    end
    stmt:finalize()
    
    local migratedCount = 0
    for _, itemName in ipairs(itemsToMigrate) do
        local itemID, iconID = database.resolveItemIDFromFallback(itemName)
        if itemID > 0 then
            -- Migrate all rules for this item
            local migrateStmt = prepareStatement([[
                INSERT OR REPLACE INTO lootrules_v2 (toon, item_id, item_name, rule, icon_id)
                SELECT toon, ?, item_name, rule, ?
                FROM lootrules_name_fallback
                WHERE item_name = ?
            ]])
            
            if migrateStmt then
                migrateStmt:bind(1, itemID)
                migrateStmt:bind(2, iconID)
                migrateStmt:bind(3, itemName)
                migrateStmt:step()
                migrateStmt:finalize()
                
                -- Remove from fallback
                local deleteStmt = prepareStatement([[
                    DELETE FROM lootrules_name_fallback 
                    WHERE item_name = ?
                ]])
                
                if deleteStmt then
                    deleteStmt:bind(1, itemName)
                    deleteStmt:step()
                    deleteStmt:finalize()
                end
                
                migratedCount = migratedCount + 1
                
                -- Clear cache to force reload
                lootRulesCache.loaded = {}
            end
        end
    end
    
    if migratedCount > 0 then
        logging.info(string.format("[Database] Migrated %d items from fallback to itemID-based storage", migratedCount))
        database.refreshLootRuleCache()
    end
end

-- ============================================================================
-- PEER FUNCTIONS
-- ============================================================================

function database.refreshLootRuleCacheForPeer(peerName)
    local peerKey = peerName
    logging.debug("[Database] refreshLootRuleCacheForPeer for " .. peerName)

    -- Mark cache as invalid first to force reload
    lootRulesCache.loaded[peerKey] = false

    -- Clear existing cache for this peer
    lootRulesCache.byItemID[peerKey] = {}
    lootRulesCache.byName[peerKey] = {}
    
    -- Load itemID-based rules
    local stmt1 = prepareStatement([[
        SELECT item_id, item_name, rule, icon_id
        FROM lootrules_v2
        WHERE toon = ?
    ]])

    if stmt1 then
        stmt1:bind(1, peerKey)
        
        local count = 0
        for row in stmt1:nrows() do
            lootRulesCache.byItemID[peerKey][row.item_id] = {
                rule = row.rule,
                item_name = row.item_name,
                item_id = row.item_id,
                icon_id = row.icon_id,
                tableSource = "lootrules_v2"
            }
            count = count + 1
        end
        stmt1:finalize()
        logging.debug(string.format("[Database] Cached %d itemID-based rules for peer %s", count, peerName))
    end
    
    -- Load name-based fallback rules
    local stmt2 = prepareStatement([[
        SELECT item_name, rule
        FROM lootrules_name_fallback
        WHERE toon = ?
    ]])

    if stmt2 then
        stmt2:bind(1, peerKey)
        
        local count = 0
        for row in stmt2:nrows() do
            lootRulesCache.byName[peerKey][row.item_name] = {
                rule = row.rule,
                item_name = row.item_name,
                item_id = 0,
                icon_id = 0,
                tableSource = "lootrules_name_fallback"
            }
            count = count + 1
        end
        stmt2:finalize()
        logging.debug(string.format("[Database] Cached %d name-based rules for peer %s", count, peerName))
    end
    
    lootRulesCache.loaded[peerKey] = true
    return true
end

-- Helper function to invalidate peer cache without reloading
function database.invalidatePeerCache(peerName)
    local peerKey = peerName
    logging.debug("[Database] Invalidating cache for peer " .. peerName)
    
    lootRulesCache.loaded[peerKey] = false
    lootRulesCache.byItemID[peerKey] = {}
    lootRulesCache.byName[peerKey] = {}
end

-- Clear all peer rule caches (used when receiving reload_rules message)
function database.clearPeerRuleCache()
    local currentToon = mq.TLO.Me.Name() or "unknown"
    logging.debug("[Database] Clearing all peer rule caches")
    
    for peerKey, _ in pairs(lootRulesCache.loaded) do
        if peerKey ~= currentToon then
            logging.debug("[Database] Clearing peer cache for: " .. peerKey)
            lootRulesCache.loaded[peerKey] = false
            lootRulesCache.byItemID[peerKey] = {}
            lootRulesCache.byName[peerKey] = {}
        end
    end
end

function database.getLootRulesForPeer(peerName)
    if not peerName or peerName == "Local" then
        return database.getAllLootRules()
    end

    local peerKey = peerName
    
    -- Ensure cache is loaded for this peer
    if not lootRulesCache.loaded[peerKey] then
        database.refreshLootRuleCacheForPeer(peerName)
    end
    
    local rules = {}
    
    -- Combine itemID and name-based rules for this peer
    if lootRulesCache.byItemID[peerKey] then
        for itemID, data in pairs(lootRulesCache.byItemID[peerKey]) do
            local key = string.format("%s_%d", data.item_name, itemID)
            rules[key] = data
        end
    end
    
    if lootRulesCache.byName[peerKey] then
        for itemName, data in pairs(lootRulesCache.byName[peerKey]) do
            rules[itemName] = data
        end
    end
    
    return rules
end

-- Get all loot rules for UI display with itemID support
function database.getAllLootRulesForUI()
    local allRules = {}
    
    -- Get all toons with rules
    local toons = {}
    local stmt1 = prepareStatement("SELECT DISTINCT toon FROM lootrules_v2 UNION SELECT DISTINCT toon FROM lootrules_name_fallback")
    if stmt1 then
        for row in stmt1:nrows() do
            table.insert(toons, row.toon)
        end
        stmt1:finalize()
    end
    
    -- Load rules for each toon
    for _, toon in ipairs(toons) do
        allRules[toon] = {}
        
        -- Load itemID-based rules
        local stmt2 = prepareStatement("SELECT item_name, rule, item_id, icon_id FROM lootrules_v2 WHERE toon = ?")
        if stmt2 then
            stmt2:bind(1, toon)
            for row in stmt2:nrows() do
                local key = string.format("%s_%d", row.item_name, row.item_id)
                allRules[toon][key] = {
                    rule = row.rule,
                    item_id = row.item_id,
                    icon_id = row.icon_id,
                    item_name = row.item_name
                }
            end
            stmt2:finalize()
        end
        
        -- Load name-based rules
        local stmt3 = prepareStatement("SELECT item_name, rule FROM lootrules_name_fallback WHERE toon = ?")
        if stmt3 then
            stmt3:bind(1, toon)
            for row in stmt3:nrows() do
                allRules[toon][row.item_name] = {
                    rule = row.rule,
                    item_id = 0,
                    icon_id = 0,
                    item_name = row.item_name
                }
            end
            stmt3:finalize()
        end
    end
    
    return allRules
end

-- Get all rules for current character
function database.getAllLootRules()
    local toonKey = mq.TLO.Me.Name() or "unknown"
    
    if not lootRulesCache.loaded[toonKey] then
        database.refreshLootRuleCache()
    end
    
    local rules = {}
    
    -- Combine itemID and name-based rules
    if lootRulesCache.byItemID[toonKey] then
        for itemID, data in pairs(lootRulesCache.byItemID[toonKey]) do
            local key = string.format("%s_%d", data.item_name, itemID)
            rules[key] = data
        end
    end
    
    if lootRulesCache.byName[toonKey] then
        for itemName, data in pairs(lootRulesCache.byName[toonKey]) do
            rules[itemName] = data
        end
    end
    
    return rules
end

-- ============================================================================
-- OTHER FUNCTIONS (kept for compatibility)
-- ============================================================================

-- Health check function for database initialization
function database.healthCheck()
    local conn = getConnection()
    if not conn then
        return false, "Failed to establish database connection"
    end
    
    -- Test basic functionality
    local stmt = prepareStatement("SELECT 1")
    if not stmt then
        return false, "Failed to prepare test statement"
    end
    
    local success = stmt:step() == sqlite3.ROW
    stmt:finalize()
    
    if success then
        logging.debug("[Database] Health check passed")
        return true, "Database is healthy"
    else
        return false, "Database test query failed"
    end
end

-- Alias for compatibility
database.fetchAllRulesFromDB = database.refreshLootRuleCache

function database.getAllCharactersWithRules()
    local characters = {}
    
    local stmt1 = prepareStatement("SELECT DISTINCT toon FROM lootrules_v2 ORDER BY toon")
    if stmt1 then
        for row in stmt1:nrows() do
            table.insert(characters, row.toon)
        end
        stmt1:finalize()
    end
    
    local stmt2 = prepareStatement("SELECT DISTINCT toon FROM lootrules_name_fallback ORDER BY toon")
    if stmt2 then
        for row in stmt2:nrows() do
            local found = false
            for _, existing in ipairs(characters) do
                if existing == row.toon then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(characters, row.toon)
            end
        end
        stmt2:finalize()
    end
    
    return characters
end

function database.deleteLootRule(itemName, itemID)
    local toonName = mq.TLO.Me.Name() or "unknown"
    itemID = tonumber(itemID) or 0
    
    local success = false
    
    -- Delete from itemID-based table if we have an ID
    if itemID > 0 then
        local stmt1 = prepareStatement("DELETE FROM lootrules_v2 WHERE toon = ? AND item_id = ?")
        if stmt1 then
            stmt1:bind(1, toonName)
            stmt1:bind(2, itemID)
            if stmt1:step() == sqlite3.DONE then
                success = true
            end
            stmt1:finalize()
        end
        
        -- Clear from cache
        if lootRulesCache.byItemID[toonName] then
            lootRulesCache.byItemID[toonName][itemID] = nil
        end
    end
    
    -- Delete from name-based fallback table
    local stmt2 = prepareStatement("DELETE FROM lootrules_name_fallback WHERE toon = ? AND item_name = ?")
    if stmt2 then
        stmt2:bind(1, toonName)
        stmt2:bind(2, itemName)
        if stmt2:step() == sqlite3.DONE then
            success = true
        end
        stmt2:finalize()
    end
    
    -- Clear from cache
    if lootRulesCache.byName[toonName] then
        lootRulesCache.byName[toonName][itemName] = nil
    end
    
    if success then
        logging.info(string.format("[Database] Deleted rule for %s (ID:%d)", itemName, itemID))
    end
    
    return success
end

function database.deleteLootRuleFor(toonName, itemName, itemID)
    if not toonName or toonName == "Local" then
        return database.deleteLootRule(itemName, itemID)
    end
    
    if not itemName then
        logging.error("[Database] deleteLootRuleFor: missing itemName")
        return false
    end
    
    itemID = tonumber(itemID) or 0
    
    logging.debug(string.format("[Database] Deleting rule for %s (ID:%d) from %s", itemName, itemID, toonName))
    
    local success = false
    
    -- Delete from itemID-based table if we have an ID
    if itemID > 0 then
        local stmt1 = prepareStatement("DELETE FROM lootrules_v2 WHERE toon = ? AND item_id = ?")
        if stmt1 then
            stmt1:bind(1, toonName)
            stmt1:bind(2, itemID)
            if stmt1:step() == sqlite3.DONE then
                success = true
            end
            stmt1:finalize()
        end
        
        -- Clear from cache
        if lootRulesCache.byItemID[toonName] then
            lootRulesCache.byItemID[toonName][itemID] = nil
        end
    end
    
    -- Delete from name-based fallback table
    local stmt2 = prepareStatement("DELETE FROM lootrules_name_fallback WHERE toon = ? AND item_name = ?")
    if stmt2 then
        stmt2:bind(1, toonName)
        stmt2:bind(2, itemName)
        if stmt2:step() == sqlite3.DONE then
            success = true
        end
        stmt2:finalize()
    end
    
    -- Clear from cache
    if lootRulesCache.byName[toonName] then
        lootRulesCache.byName[toonName][itemName] = nil
    end
    
    if success then
        logging.info(string.format("[Database] Deleted rule for %s (ID:%d) from %s", itemName, itemID, toonName))
    end
    
    return success
end

function database.saveLootHistory(looter, itemName, itemID, iconID, action, corpseName, corpseID, zoneName, quantity)
    local stmt = prepareStatement([[
        INSERT INTO loot_history
        (looter, item_name, item_id, icon_id, action, corpse_name, corpse_id, zone_name, quantity)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        return false
    end
    
    stmt:bind(1, looter or "")
    stmt:bind(2, itemName or "")
    stmt:bind(3, tonumber(itemID) or 0)
    stmt:bind(4, tonumber(iconID) or 0)
    stmt:bind(5, action or "")
    stmt:bind(6, corpseName or "")
    stmt:bind(7, tonumber(corpseID) or 0)
    stmt:bind(8, zoneName or "")
    stmt:bind(9, tonumber(quantity) or 1)
    
    local result = stmt:step()
    stmt:finalize()
    
    return result == sqlite3.DONE
end

function database.getLootHistory(days, limit)
    days = days or 7
    limit = limit or 1000
    
    local stmt = prepareStatement([[
        SELECT looter, item_name, item_id, icon_id, action, corpse_name, corpse_id, zone_name, quantity, timestamp
        FROM loot_history
        WHERE timestamp >= datetime('now', '-' || ? || ' days')
        ORDER BY timestamp DESC
        LIMIT ?
    ]])
    
    if not stmt then
        return {}
    end
    
    stmt:bind(1, days)
    stmt:bind(2, limit)
    
    local history = {}
    for row in stmt:nrows() do
        table.insert(history, {
            looter = row.looter,
            item_name = row.item_name,
            item_id = row.item_id,
            icon_id = row.icon_id,
            action = row.action,
            corpse_name = row.corpse_name,
            corpse_id = row.corpse_id,
            zone_name = row.zone_name,
            quantity = row.quantity,
            timestamp = row.timestamp
        })
    end
    stmt:finalize()
    
    return history
end

function database.saveGlobalLootOrder(lootOrder)
    -- Clear existing order
    local clearStmt = prepareStatement("DELETE FROM global_loot_order")
    if clearStmt then
        clearStmt:step()
        clearStmt:finalize()
    end
    
    -- Insert new order
    local stmt = prepareStatement([[
        INSERT INTO global_loot_order (peer_name, order_position)
        VALUES (?, ?)
    ]])
    
    if not stmt then
        return false
    end
    
    for position, peerName in ipairs(lootOrder) do
        stmt:bind(1, peerName)
        stmt:bind(2, position)
        stmt:step()
        stmt:reset()
    end
    stmt:finalize()
    
    return true
end

function database.getGlobalLootOrder()
    local stmt = prepareStatement([[
        SELECT peer_name 
        FROM global_loot_order 
        ORDER BY order_position
    ]])
    
    if not stmt then
        return {}
    end
    
    local order = {}
    for row in stmt:nrows() do
        table.insert(order, row.peer_name)
    end
    stmt:finalize()
    
    return order
end

function database.recordCorpseLooted(zoneName, corpseID, npcName, npcID, sessionId)
    local stmt = prepareStatement([[
        INSERT INTO loot_stats_corpses
        (zone_name, corpse_id, npc_name, npc_id, server_name, session_id)
        VALUES (?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        return false
    end
    
    stmt:bind(1, zoneName or "")
    stmt:bind(2, tonumber(corpseID) or 0)
    stmt:bind(3, npcName or "")
    stmt:bind(4, tonumber(npcID) or 0)
    stmt:bind(5, currentServerName)
    stmt:bind(6, sessionId or "")
    
    local result = stmt:step()
    stmt:finalize()
    
    return result == sqlite3.DONE
end

function database.recordItemDrop(itemName, itemID, iconID, zoneName, corpseID, npcName, npcID, droppedBy, quantity)
    local stmt = prepareStatement([[
        INSERT INTO loot_stats_drops
        (item_name, item_id, icon_id, zone_name, corpse_id, npc_name, npc_id, dropped_by, item_count, server_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        return false
    end
    
    stmt:bind(1, itemName or "")
    stmt:bind(2, tonumber(itemID) or 0)
    stmt:bind(3, tonumber(iconID) or 0)
    stmt:bind(4, zoneName or "")
    stmt:bind(5, tonumber(corpseID) or 0)
    stmt:bind(6, npcName or "")
    stmt:bind(7, tonumber(npcID) or 0)
    stmt:bind(8, droppedBy or "")
    stmt:bind(9, tonumber(quantity) or 1)
    stmt:bind(10, currentServerName)
    
    local result = stmt:step()
    stmt:finalize()
    
    return result == sqlite3.DONE
end

function database.checkRecentCorpseRecord(zoneName, corpseID, timeWindowMinutes)
    timeWindowMinutes = timeWindowMinutes or 10
    
    local stmt = prepareStatement([[
        SELECT id FROM loot_stats_corpses
        WHERE zone_name = ? AND corpse_id = ?
        AND timestamp > datetime('now', '-' || ? || ' minutes')
        LIMIT 1
    ]])
    
    if not stmt then
        return false
    end
    
    stmt:bind(1, zoneName)
    stmt:bind(2, corpseID)
    stmt:bind(3, timeWindowMinutes)
    
    local found = stmt:step() == sqlite3.ROW
    stmt:finalize()
    
    return found
end

-- Get zone breakdown for a specific item
function database.getItemZoneBreakdown(itemName, itemID, timeFrame)
    if not db then
        logging.error("[Database] Database not initialized")
        return {}
    end
    
    local timeFilter = ""
    if timeFrame and timeFrame ~= "All Time" then
        if timeFrame == "Today" then
            timeFilter = "AND d.timestamp >= date('now', 'start of day')"
        elseif timeFrame == "Yesterday" then
            timeFilter = "AND d.timestamp >= date('now', '-1 day', 'start of day') AND d.timestamp < date('now', 'start of day')"
        elseif timeFrame == "This Week" then
            timeFilter = "AND d.timestamp >= date('now', 'weekday 1', '-7 days')"
        elseif timeFrame == "This Month" then
            timeFilter = "AND d.timestamp >= date('now', 'start of month')"
        end
    end
    
    local query = string.format([[
        SELECT 
            d.zone_name,
            COUNT(d.id) as drop_count,
            SUM(d.item_count) as total_quantity,
            (
                SELECT COUNT(*) 
                FROM loot_stats_corpses c 
                WHERE c.zone_name = d.zone_name 
                %s
            ) as corpse_count
        FROM loot_stats_drops d
        WHERE (d.item_name = ? OR (d.item_id = ? AND d.item_id > 0))
        %s
        GROUP BY d.zone_name
        ORDER BY drop_count DESC
    ]], timeFilter:gsub("d%.timestamp", "c.timestamp"), timeFilter)
    
    local stmt = prepareStatement(query)
    if not stmt then
        return {}
    end
    
    stmt:bind_values(itemName, itemID or 0)
    
    local results = {}
    local totalDrops = 0
    
    -- First pass: collect data and calculate total drops
    for row in stmt:nrows() do
        local dropCount = tonumber(row.drop_count) or 0
        local corpseCount = tonumber(row.corpse_count) or 0
        totalDrops = totalDrops + dropCount
        
        -- Calculate proper drop rate: drops per corpse * 100
        local dropRate = corpseCount > 0 and (dropCount / corpseCount * 100) or 0
        
        table.insert(results, {
            zone_name = row.zone_name,
            drop_count = dropCount,
            corpse_count = corpseCount,
            drop_rate = math.floor(dropRate * 100 + 0.5) / 100, -- Round to 2 decimal places
            total_quantity = tonumber(row.total_quantity) or 0
        })
    end
    
    -- Second pass: calculate percentage of total drops per zone
    for _, result in ipairs(results) do
        result.zone_percentage = totalDrops > 0 and math.floor((result.drop_count / totalDrops) * 100 + 0.5) or 0
    end
    
    stmt:finalize()
    return results
end

-- Helper function to extract the core character name from DanNet complex names
local function extractCoreCharacterName(fullName)
    if not fullName or fullName == "" then
        return ""
    end
    
    -- Pattern 1: "Ez (linux) x4 exp_CharacterName" -> "CharacterName"
    local coreAfterUnderscore = string.match(fullName, ".*_([%w]+)$")
    if coreAfterUnderscore then
        return coreAfterUnderscore
    end
    
    -- Pattern 2: Simple character names like "CharacterName" or "charactername"
    local simpleName = string.match(fullName, "^([%w]+)$")
    if simpleName then
        return simpleName
    end
    
    -- Pattern 3: Names with spaces but no underscore - take the last word
    local lastWord = string.match(fullName, ".*%s([%w]+)$")
    if lastWord then
        return lastWord
    end
    
    -- Fallback: return the original name
    return fullName
end

-- Detect duplicate peer names caused by case differences and DanNet naming patterns
function database.detectDuplicatePeerNames()
    if not db then
        logging.error("[Database] Database not initialized")
        return {}
    end
    
    -- Get all toon names from both tables
    local getAllNamesStmt = prepareStatement([[
        SELECT DISTINCT toon FROM (
            SELECT toon FROM lootrules_v2 
            UNION 
            SELECT toon FROM lootrules_name_fallback
        ) AS all_toons
        ORDER BY toon
    ]])
    
    if not getAllNamesStmt then
        logging.error("[Database] Failed to prepare name retrieval query")
        return {}
    end
    
    local allNames = {}
    for row in getAllNamesStmt:nrows() do
        table.insert(allNames, row.toon)
    end
    getAllNamesStmt:finalize()
    
    -- Group names by their core character name (case-insensitive)
    local nameGroups = {}
    for _, fullName in ipairs(allNames) do
        local coreName = extractCoreCharacterName(fullName)
        local lowerCoreName = coreName:lower()
        
        if not nameGroups[lowerCoreName] then
            -- Use proper case for display name (first letter upper, rest lower)
            local properCaseName = coreName:sub(1,1):upper() .. coreName:sub(2):lower()
            nameGroups[lowerCoreName] = {
                coreName = properCaseName,  -- This will be used for display
                variants = {}
            }
        end
        
        table.insert(nameGroups[lowerCoreName].variants, fullName)
    end
    
    -- Filter to only groups with multiple variants and get detailed information
    local duplicates = {}
    for lowerCoreName, group in pairs(nameGroups) do
        if #group.variants > 1 then
            local variantDetails = {}
            
            for _, fullName in ipairs(group.variants) do
                -- Get all rules for this character name
                local rules = {}
                
                -- Get rules from lootrules_v2
                local v2Stmt = prepareStatement([[
                    SELECT item_name, item_id, rule, icon_id, updated_at 
                    FROM lootrules_v2 
                    WHERE toon = ?
                    ORDER BY item_name
                ]])
                if v2Stmt then
                    v2Stmt:bind(1, fullName)
                    for ruleRow in v2Stmt:nrows() do
                        table.insert(rules, {
                            itemName = ruleRow.item_name,
                            itemId = ruleRow.item_id or 0,
                            rule = ruleRow.rule,
                            iconId = ruleRow.icon_id or 0,
                            updatedAt = ruleRow.updated_at,
                            tableSource = "lootrules_v2"
                        })
                    end
                    v2Stmt:finalize()
                end
                
                -- Get rules from lootrules_name_fallback
                local fallbackStmt = prepareStatement([[
                    SELECT item_name, rule, icon_id, updated_at 
                    FROM lootrules_name_fallback 
                    WHERE toon = ?
                    ORDER BY item_name
                ]])
                if fallbackStmt then
                    fallbackStmt:bind(1, fullName)
                    for ruleRow in fallbackStmt:nrows() do
                        table.insert(rules, {
                            itemName = ruleRow.item_name,
                            itemId = 0, -- fallback table doesn't have item_id
                            rule = ruleRow.rule,
                            iconId = ruleRow.icon_id or 0,
                            updatedAt = ruleRow.updated_at,
                            tableSource = "lootrules_name_fallback"
                        })
                    end
                    fallbackStmt:finalize()
                end
                
                table.insert(variantDetails, {
                    fullName = fullName,
                    coreName = extractCoreCharacterName(fullName),
                    ruleCount = #rules,
                    rules = rules
                })
            end
            
            -- Sort variants by rule count (fewest to most)
            table.sort(variantDetails, function(a, b)
                return a.ruleCount < b.ruleCount
            end)
            
            table.insert(duplicates, {
                baseName = lowerCoreName,
                coreCharacterName = group.coreName,
                variants = variantDetails
            })
        end
    end
    
    return duplicates
end

-- Detect malformed singletons (names that normalize to a core name but have no sibling/clean counterpart)
function database.detectMalformedSingletonNames()
    if not db then
        logging.error("[Database] Database not initialized")
        return {}
    end

    -- Get all toon names
    local getAllNamesStmt = prepareStatement([[
        SELECT DISTINCT toon FROM (
            SELECT toon FROM lootrules_v2 
            UNION 
            SELECT toon FROM lootrules_name_fallback
        ) AS all_toons
        ORDER BY toon
    ]])

    if not getAllNamesStmt then
        logging.error("[Database] Failed to prepare name retrieval query (singletons)")
        return {}
    end

    local allNames = {}
    for row in getAllNamesStmt:nrows() do
        table.insert(allNames, row.toon)
    end
    getAllNamesStmt:finalize()

    -- Group by normalized core name
    local groups = {}
    for _, fullName in ipairs(allNames) do
        local coreName = extractCoreCharacterName(fullName)
        local lowerCore = coreName:lower()
        groups[lowerCore] = groups[lowerCore] or { coreName = coreName, variants = {} }
        table.insert(groups[lowerCore].variants, fullName)
    end

    local malformed = {}
    for _, group in pairs(groups) do
        if #group.variants == 1 then
            local fullName = group.variants[1]
            local coreName = group.coreName
            -- If the only variant differs from the core (e.g., DanNet-style), consider it malformed
            if fullName ~= coreName then
                -- Collect rules for this name
                local rules = {}
                local v2Stmt = prepareStatement([[
                    SELECT item_name, item_id, rule, icon_id, updated_at 
                    FROM lootrules_v2 
                    WHERE toon = ?
                    ORDER BY item_name
                ]])
                if v2Stmt then
                    v2Stmt:bind(1, fullName)
                    for ruleRow in v2Stmt:nrows() do
                        table.insert(rules, {
                            itemName = ruleRow.item_name,
                            itemId = ruleRow.item_id or 0,
                            rule = ruleRow.rule,
                            iconId = ruleRow.icon_id or 0,
                            updatedAt = ruleRow.updated_at,
                            tableSource = "lootrules_v2"
                        })
                    end
                    v2Stmt:finalize()
                end
                local fallbackStmt = prepareStatement([[
                    SELECT item_name, rule, icon_id, updated_at 
                    FROM lootrules_name_fallback 
                    WHERE toon = ?
                    ORDER BY item_name
                ]])
                if fallbackStmt then
                    fallbackStmt:bind(1, fullName)
                    for ruleRow in fallbackStmt:nrows() do
                        table.insert(rules, {
                            itemName = ruleRow.item_name,
                            itemId = 0,
                            rule = ruleRow.rule,
                            iconId = ruleRow.icon_id or 0,
                            updatedAt = ruleRow.updated_at,
                            tableSource = "lootrules_name_fallback"
                        })
                    end
                    fallbackStmt:finalize()
                end

                table.insert(malformed, {
                    coreCharacterName = coreName:sub(1,1):upper() .. coreName:sub(2):lower(),
                    variant = {
                        fullName = fullName,
                        coreName = coreName,
                        ruleCount = #rules,
                        rules = rules
                    }
                })
            end
        end
    end

    -- Sort by rule count descending (migrate heavier first)
    table.sort(malformed, function(a, b)
        return (a.variant.ruleCount or 0) > (b.variant.ruleCount or 0)
    end)

    return malformed
end

-- Convenience: rename a single peer to its core name (merge and delete source)
function database.renamePeerToCore(fullName)
    local core = extractCoreCharacterName(fullName)
    if not core or core == "" or core == fullName then
        return false
    end
    return database.mergePeerRules(fullName, core)
end

-- Copy a specific rule from one character to another
function database.copySpecificRule(fromName, toName, itemName, itemId, tableSource)
    if not db then
        logging.error("[Database] Database not initialized")
        return false
    end
    
    local success = false
    
    if tableSource == "lootrules_v2" then
        -- Copy from v2 table
        local copyStmt = prepareStatement([[
            INSERT OR REPLACE INTO lootrules_v2 
            (toon, item_id, item_name, rule, icon_id, updated_at)
            SELECT ?, item_id, item_name, rule, icon_id, CURRENT_TIMESTAMP
            FROM lootrules_v2 
            WHERE toon = ? AND item_name = ? AND item_id = ?
        ]])
        
        if copyStmt then
            copyStmt:bind(1, toName)
            copyStmt:bind(2, fromName)
            copyStmt:bind(3, itemName)
            copyStmt:bind(4, itemId or 0)
            success = copyStmt:step() == sqlite3.DONE
            copyStmt:finalize()
        end
        
    elseif tableSource == "lootrules_name_fallback" then
        -- Copy from fallback table
        local copyStmt = prepareStatement([[
            INSERT OR REPLACE INTO lootrules_name_fallback 
            (toon, item_name, rule, icon_id, updated_at)
            SELECT ?, item_name, rule, icon_id, CURRENT_TIMESTAMP
            FROM lootrules_name_fallback 
            WHERE toon = ? AND item_name = ?
        ]])
        
        if copyStmt then
            copyStmt:bind(1, toName)
            copyStmt:bind(2, fromName)
            copyStmt:bind(3, itemName)
            success = copyStmt:step() == sqlite3.DONE
            copyStmt:finalize()
        end
    end
    
    if success then
        logging.debug(string.format("[Database] Copied rule for '%s' from '%s' to '%s'", itemName, fromName, toName))
        
        -- Clear cache for target to force reload
        if lootRulesCache.loaded[toName] then
            lootRulesCache.loaded[toName] = false
        end
    end
    
    return success
end

-- Delete a specific rule for a character
function database.deleteSpecificRule(toonName, itemName, itemId, tableSource)
    if not db then
        logging.error("[Database] Database not initialized")
        return false
    end
    
    local success = false
    
    if tableSource == "lootrules_v2" then
        local deleteStmt = prepareStatement("DELETE FROM lootrules_v2 WHERE toon = ? AND item_name = ? AND item_id = ?")
        if deleteStmt then
            deleteStmt:bind(1, toonName)
            deleteStmt:bind(2, itemName)
            deleteStmt:bind(3, itemId or 0)
            success = deleteStmt:step() == sqlite3.DONE
            deleteStmt:finalize()
        end
        
        -- Clear from cache
        if lootRulesCache.byItemID[toonName] then
            lootRulesCache.byItemID[toonName][itemId or 0] = nil
        end
        
    elseif tableSource == "lootrules_name_fallback" then
        local deleteStmt = prepareStatement("DELETE FROM lootrules_name_fallback WHERE toon = ? AND item_name = ?")
        if deleteStmt then
            deleteStmt:bind(1, toonName)
            deleteStmt:bind(2, itemName)
            success = deleteStmt:step() == sqlite3.DONE
            deleteStmt:finalize()
        end
        
        -- Clear from cache
        if lootRulesCache.byName[toonName] then
            lootRulesCache.byName[toonName][itemName] = nil
        end
    end
    
    if success then
        logging.debug(string.format("[Database] Deleted rule for '%s' from '%s'", itemName, toonName))
    end
    
    return success
end

-- Delete all rules for a character (used after selective copying)
function database.deleteAllRulesForCharacter(toonName)
    if not db then
        logging.error("[Database] Database not initialized")
        return false
    end
    
    local success = true
    
    -- Delete from v2 table
    local deleteV2Stmt = prepareStatement("DELETE FROM lootrules_v2 WHERE toon = ?")
    if deleteV2Stmt then
        deleteV2Stmt:bind(1, toonName)
        if deleteV2Stmt:step() ~= sqlite3.DONE then
            success = false
        end
        deleteV2Stmt:finalize()
    end
    
    -- Delete from fallback table
    local deleteFallbackStmt = prepareStatement("DELETE FROM lootrules_name_fallback WHERE toon = ?")
    if deleteFallbackStmt then
        deleteFallbackStmt:bind(1, toonName)
        if deleteFallbackStmt:step() ~= sqlite3.DONE then
            success = false
        end
        deleteFallbackStmt:finalize()
    end
    
    -- Clear cache
    if lootRulesCache.byItemID[toonName] then
        lootRulesCache.byItemID[toonName] = nil
    end
    if lootRulesCache.byName[toonName] then
        lootRulesCache.byName[toonName] = nil
    end
    lootRulesCache.loaded[toonName] = nil
    
    if success then
        logging.info(string.format("[Database] Deleted all rules for character '%s'", toonName))
    end
    
    return success
end

-- Merge rules from one peer name to another and delete the source (legacy function)
function database.mergePeerRules(fromName, toName)
    if not db then
        logging.error("[Database] Database not initialized")
        return false
    end
    
    logging.info(string.format("[Database] Merging rules from '%s' to '%s'", fromName, toName))
    
    local mergedCount = 0
    
    -- Merge lootrules_v2 table
    local mergeV2Stmt = prepareStatement([[
        INSERT OR REPLACE INTO lootrules_v2 
        (toon, item_id, item_name, rule, icon_id, updated_at)
        SELECT ?, item_id, item_name, rule, icon_id, updated_at
        FROM lootrules_v2 
        WHERE toon = ?
    ]])
    
    if mergeV2Stmt then
        mergeV2Stmt:bind(1, toName)
        mergeV2Stmt:bind(2, fromName)
        if mergeV2Stmt:step() == sqlite3.DONE then
            mergedCount = mergedCount + 1
        end
        mergeV2Stmt:finalize()
    end
    
    -- Merge lootrules_name_fallback table
    local mergeFallbackStmt = prepareStatement([[
        INSERT OR REPLACE INTO lootrules_name_fallback 
        (toon, item_name, rule, icon_id, updated_at)
        SELECT ?, item_name, rule, icon_id, updated_at
        FROM lootrules_name_fallback 
        WHERE toon = ?
    ]])
    
    if mergeFallbackStmt then
        mergeFallbackStmt:bind(1, toName)
        mergeFallbackStmt:bind(2, fromName)
        if mergeFallbackStmt:step() == sqlite3.DONE then
            mergedCount = mergedCount + 1
        end
        mergeFallbackStmt:finalize()
    end
    
    -- Delete the old entries
    return database.deleteAllRulesForCharacter(fromName)
end

-- ============================================================================
-- LEGACY IMPORT FUNCTIONS
-- ============================================================================

-- Parse legacy INI file format (E3 Loot Files)
function database.parseLegacyLootFile(filePath)
    local file = io.open(filePath, "r")
    if not file then
        logging.error("[Database] Could not open legacy file: " .. filePath)
        return nil
    end
    
    local items = {
        alwaysLoot = {},
        alwaysLootContains = {}
    }
    
    local currentSection = nil
    local lineCount = 0
    
    for line in file:lines() do
        lineCount = lineCount + 1
        line = line:gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
        
        -- Skip empty lines and comments
        if line ~= "" and not line:match("^;") then
            -- Check for section headers
            if line:match("^%[(.+)%]$") then
                local sectionName = line:match("^%[(.+)%]$")
                if sectionName == "AlwaysLoot" then
                    currentSection = "alwaysLoot"
                elseif sectionName == "AlwaysLootContains" then
                    currentSection = "alwaysLootContains"
                else
                    currentSection = nil -- Unknown section, skip
                end
            -- Parse Entry= lines
            elseif line:match("^Entry%s*=%s*(.+)$") and currentSection then
                local itemName = line:match("^Entry%s*=%s*(.+)$")
                if itemName and itemName ~= "" then
                    table.insert(items[currentSection], itemName)
                end
            end
        end
    end
    
    file:close()
    
    logging.info(string.format("[Database] Parsed legacy file: %d AlwaysLoot, %d AlwaysLootContains items", 
        #items.alwaysLoot, #items.alwaysLootContains))
    
    return items
end

-- Import legacy loot rules into the database (smart import logic)
function database.importLegacyLootRules(parsedItems, targetCharacter, defaultRule, fileSource)
    if not parsedItems or not targetCharacter or not defaultRule then
        logging.error("[Database] importLegacyLootRules: missing required parameters")
        return false, 0
    end
    
    local importCount = 0
    local skippedCount = 0
    local errors = {}
    
    -- Get existing rules for this character
    local existingRules = database.getLootRulesForPeer(targetCharacter)
    
    -- Helper function to check if item should be imported
    local function shouldImportItem(itemName)
        local lowerName = itemName:lower()
        local existingRule = existingRules[lowerName] or existingRules[itemName]
        
        -- Also check by searching through all rules for name matches
        if not existingRule then
            for key, ruleData in pairs(existingRules) do
                if ruleData.item_name then
                    local ruleItemLower = string.lower(ruleData.item_name)
                    if ruleItemLower == lowerName or ruleData.item_name == itemName then
                        existingRule = ruleData
                        break
                    end
                end
            end
        end
        
        -- Skip if we already have an ItemID-based rule for this item
        if existingRule and existingRule.item_id and existingRule.item_id > 0 then
            logging.debug(string.format("[Database] Skipping '%s' - already has ItemID-based rule", itemName))
            return false
        end
        
        return true
    end
    
    -- Helper function to import a single item
    local function importSingleItem(itemName, section)
        if not shouldImportItem(itemName) then
            skippedCount = skippedCount + 1
            return true -- Not an error, just skipped
        end
        
        -- Use custom rule if provided, otherwise use default
        local rule = defaultRule
        if parsedItems.customRules and parsedItems.customRules[itemName] then
            rule = parsedItems.customRules[itemName]
        end
        
        -- Check if we have ItemID from inventory scan
        local itemID = 0
        local iconID = 0
        if parsedItems.inventoryData and parsedItems.inventoryData[itemName] then
            itemID = parsedItems.inventoryData[itemName].itemID
            iconID = parsedItems.inventoryData[itemName].iconID
        end
        
        -- Save to appropriate table based on whether we have ItemID
        if itemID > 0 then
            -- Save directly to main table with ItemID
            local success = database.saveLootRuleFor(targetCharacter, itemName, itemID, rule, iconID)
            if success then
                importCount = importCount + 1
                logging.info(string.format("[Database] Imported legacy rule with ItemID (%s): %s (ID:%d) -> %s for %s", 
                    section, itemName, itemID, rule, targetCharacter))
                return true
            else
                table.insert(errors, string.format("Failed to save ItemID rule for %s", itemName))
                return false
            end
        else
            -- Save to name-based fallback table
            local stmt = prepareStatement([[
                INSERT OR REPLACE INTO lootrules_name_fallback
                (toon, item_name, rule, created_at, updated_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ]])
            
            if stmt then
                stmt:bind(1, targetCharacter)
                stmt:bind(2, itemName)
                stmt:bind(3, rule)
                local result = stmt:step()
                stmt:finalize()
                
                if result == sqlite3.DONE then
                    importCount = importCount + 1
                    logging.debug(string.format("[Database] Imported legacy rule to fallback (%s): %s -> %s for %s", 
                        section, itemName, rule, targetCharacter))
                    return true
                else
                    table.insert(errors, string.format("Failed to import '%s' from %s", itemName, section))
                    return false
                end
            else
                table.insert(errors, string.format("Database error for '%s' from %s", itemName, section))
                return false
            end
        end
    end
    
    -- Process AlwaysLoot items
    for _, itemName in ipairs(parsedItems.alwaysLoot) do
        importSingleItem(itemName, "AlwaysLoot")
    end
    
    -- Process AlwaysLootContains items
    for _, itemName in ipairs(parsedItems.alwaysLootContains) do
        importSingleItem(itemName, "AlwaysLootContains")
    end
    
    -- Clear cache for target character
    if lootRulesCache.loaded[targetCharacter] then
        lootRulesCache.loaded[targetCharacter] = false
    end
    if lootRulesCache.byName[targetCharacter] then
        lootRulesCache.byName[targetCharacter] = {}
    end
    
    local totalProcessed = importCount + skippedCount
    if totalProcessed > 0 then
        if skippedCount > 0 then
            logging.info(string.format("[Database] Import summary for %s from %s: %d imported, %d skipped (already have ItemID rules)", 
                targetCharacter, fileSource or "unknown file", importCount, skippedCount))
        else
            logging.info(string.format("[Database] Successfully imported %d legacy loot rules for %s from %s", 
                importCount, targetCharacter, fileSource or "unknown file"))
        end
    end
    
    if #errors > 0 then
        logging.error(string.format("[Database] Import completed with %d errors: %s", 
            #errors, table.concat(errors, ", ")))
    end
    
    return importCount > 0 or skippedCount > 0, importCount
end

-- Scan inventory for ItemID and IconID of specific items
function database.scanInventoryForItems(itemList)
    local foundItems = {}
    
    for _, itemName in ipairs(itemList) do
        local findItem = mq.TLO.FindItem(itemName)
        if findItem and findItem.ID() and findItem.ID() > 0 then
            foundItems[itemName] = {
                itemID = findItem.ID(),
                iconID = findItem.Icon() or 0
            }
            logging.debug(string.format("[Database] Found in inventory: %s (ID:%d, Icon:%d)", 
                itemName, findItem.ID(), findItem.Icon() or 0))
        end
    end
    
    return foundItems
end

-- Check for conflicts with existing database rules
function database.checkLegacyImportConflicts(parsedItems, targetCharacter, defaultRule)
    if not parsedItems or not targetCharacter then
        return { conflicts = {}, skipped = {} }
    end
    
    local conflicts = {}  -- Items that will overwrite existing rules
    local skipped = {}    -- Items that will be skipped (already have ItemID rules)
    local existingRules = database.getLootRulesForPeer(targetCharacter)
    
    -- Helper function to find existing rule for an item
    local function findExistingRule(itemName)
        local lowerName = itemName:lower()
        local existingRule = existingRules[lowerName] or existingRules[itemName]
        
        -- Also check by searching through all rules for name matches
        if not existingRule then
            for key, ruleData in pairs(existingRules) do
                if ruleData.item_name then
                    local ruleItemLower = string.lower(ruleData.item_name)
                    if ruleItemLower == lowerName or ruleData.item_name == itemName then
                        logging.debug(string.format("[Database] Found existing rule for '%s': %s (ItemID: %s)", 
                            itemName, ruleData.rule, tostring(ruleData.item_id or "none")))
                        existingRule = ruleData
                        break
                    end
                end
            end
        end
        
        if not existingRule then
            logging.debug(string.format("[Database] No existing rule found for '%s'", itemName))
        end
        
        return existingRule
    end
    
    -- Helper function to check item conflicts
    local function checkItemConflicts(items, section)
        for _, itemName in ipairs(items) do
            local existingRule = findExistingRule(itemName)
            
            if existingRule then
                if existingRule.item_id and existingRule.item_id > 0 then
                    -- Skip items that already have ItemID-based rules
                    table.insert(skipped, {
                        itemName = itemName,
                        section = section,
                        existingRule = existingRule.rule,
                        reason = "Already has ItemID-based rule"
                    })
                else
                    -- Will overwrite name-only rules
                    table.insert(conflicts, {
                        itemName = itemName,
                        section = section,
                        existingRule = existingRule.rule,
                        newRule = defaultRule or "Keep",
                        hasItemID = false,
                        willOverwrite = true
                    })
                end
            end
        end
    end
    
    -- Check AlwaysLoot items for conflicts
    checkItemConflicts(parsedItems.alwaysLoot, "AlwaysLoot")
    
    -- Check AlwaysLootContains items for conflicts
    checkItemConflicts(parsedItems.alwaysLootContains, "AlwaysLootContains")
    
    return {
        conflicts = conflicts,
        skipped = skipped
    }
end

-- Get preview of what would be imported from a legacy file
function database.previewLegacyImport(filePath, targetCharacter, defaultRule)
    local parsedItems = database.parseLegacyLootFile(filePath)
    if not parsedItems then
        return nil
    end
    
    local preview = {
        fileName = filePath:match("([^/\\]+)$") or filePath, -- Extract filename
        totalItems = #parsedItems.alwaysLoot + #parsedItems.alwaysLootContains,
        alwaysLootCount = #parsedItems.alwaysLoot,
        alwaysLootContainsCount = #parsedItems.alwaysLootContains,
        sampleItems = {},
        parsedData = parsedItems, -- Keep for actual import
        conflicts = {} -- Will be populated if targetCharacter provided
    }
    
    -- Check for conflicts if target character is specified
    if targetCharacter then
        local conflictData = database.checkLegacyImportConflicts(parsedItems, targetCharacter, defaultRule)
        preview.conflicts = conflictData.conflicts
        preview.skipped = conflictData.skipped
        preview.conflictCount = #conflictData.conflicts
        preview.skippedCount = #conflictData.skipped
        preview.willImportCount = preview.totalItems - preview.skippedCount
    end
    
    -- Add sample items for preview (first 10 from each section)
    for i = 1, math.min(10, #parsedItems.alwaysLoot) do
        local itemName = parsedItems.alwaysLoot[i]
        local hasConflict = false
        local willBeSkipped = false
        
        -- Check if this item has a conflict or will be skipped
        if preview.conflicts then
            for _, conflict in ipairs(preview.conflicts) do
                if conflict.itemName == itemName then
                    hasConflict = true
                    break
                end
            end
        end
        
        if preview.skipped then
            for _, skipped in ipairs(preview.skipped) do
                if skipped.itemName == itemName then
                    willBeSkipped = true
                    break
                end
            end
        end
        
        table.insert(preview.sampleItems, {
            name = itemName,
            section = "AlwaysLoot",
            hasConflict = hasConflict,
            willBeSkipped = willBeSkipped
        })
    end
    
    for i = 1, math.min(10, #parsedItems.alwaysLootContains) do
        local itemName = parsedItems.alwaysLootContains[i]
        local hasConflict = false
        local willBeSkipped = false
        
        -- Check if this item has a conflict or will be skipped
        if preview.conflicts then
            for _, conflict in ipairs(preview.conflicts) do
                if conflict.itemName == itemName then
                    hasConflict = true
                    break
                end
            end
        end
        
        if preview.skipped then
            for _, skipped in ipairs(preview.skipped) do
                if skipped.itemName == itemName then
                    willBeSkipped = true
                    break
                end
            end
        end
        
        table.insert(preview.sampleItems, {
            name = itemName,
            section = "AlwaysLootContains",
            hasConflict = hasConflict,
            willBeSkipped = willBeSkipped
        })
    end
    
    return preview
end

function database.cleanup()
    if db then
        db:close()
        db = nil
    end
    
    -- Clear cache
    lootRulesCache = {
        byItemID = {},
        byName = {},
        itemMappings = {},
        loaded = {}
    }
    
    logging.debug("[Database] Database connection closed and cache cleared")
end

return database