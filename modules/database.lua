-- modules/database_v2.lua - ItemID-based SQLite Database Module
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

-- Database migration function
local function migrateToItemIDBasedSchema(conn)
    logging.debug("[Database] Running migration to itemID-based schema...")
    
    -- Check if we need to migrate
    local checkStmt = conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='lootrules_v2'")
    local hasNewTable = false
    if checkStmt:step() == sqlite3.ROW then
        hasNewTable = true
    end
    checkStmt:finalize()
    
    if hasNewTable then
        logging.debug("[Database] ItemID-based schema already exists, skipping migration")
        return true
    end
    
    -- Create new tables
    local createNewTables = [[
        -- New itemID-based table
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
    
    local result = conn:exec(createNewTables)
    if result ~= sqlite3.OK then
        logging.error("[Database] Failed to create new tables: " .. conn:errmsg())
        return false
    end
    
    -- Migrate existing data if old table exists
    local checkOldStmt = conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='lootrules'")
    local hasOldTable = false
    if checkOldStmt:step() == sqlite3.ROW then
        hasOldTable = true
    end
    checkOldStmt:finalize()
    
    if hasOldTable then
        logging.debug("[Database] Migrating data from old schema...")
        
        -- First, let's check what data exists in the old table
        local checkStmt = conn:prepare("SELECT COUNT(*) as total, COUNT(CASE WHEN item_id > 0 THEN 1 END) as with_ids FROM lootrules")
        if checkStmt then
            if checkStmt:step() == sqlite3.ROW then
                local total = checkStmt:get_value(0)
                local withIds = checkStmt:get_value(1)
                logging.debug(string.format("[Database] Found %d total rules, %d with itemIDs", total, withIds))
            end
            checkStmt:finalize()
        end
        
        -- Migrate items with valid itemIDs (including 0 values, we'll handle them differently)
        local migrateWithIDs = [[
            INSERT OR IGNORE INTO lootrules_v2 (toon, item_id, item_name, rule, icon_id, created_at, updated_at)
            SELECT toon, 
                   CASE WHEN item_id IS NULL OR item_id = 0 THEN 
                       -- Try to get a unique fake ID for migration, using row hash
                       ABS(CAST(SUBSTR(HEX(RANDOMBLOB(4)), 1, 8) AS INTEGER)) 
                   ELSE item_id END,
                   item_name, rule, 
                   COALESCE(icon_id, 0), 
                   created_at, updated_at
            FROM lootrules
            WHERE item_id IS NOT NULL AND item_id > 0
        ]]
        
        result = conn:exec(migrateWithIDs)
        if result ~= sqlite3.OK then
            logging.error("[Database] Failed to migrate items with IDs: " .. conn:errmsg())
        else
            local migratedStmt = conn:prepare("SELECT COUNT(*) FROM lootrules_v2")
            if migratedStmt then
                if migratedStmt:step() == sqlite3.ROW then
                    local migrated = migratedStmt:get_value(0)
                    logging.debug(string.format("[Database] Migrated %d rules with itemIDs", migrated))
                end
                migratedStmt:finalize()
            end
        end
        
        -- Migrate items without itemIDs to fallback table
        local migrateWithoutIDs = [[
            INSERT OR IGNORE INTO lootrules_name_fallback (toon, item_name, rule, created_at, updated_at)
            SELECT toon, item_name, rule, created_at, updated_at
            FROM lootrules
            WHERE item_id IS NULL OR item_id = 0
        ]]
        
        result = conn:exec(migrateWithoutIDs)
        if result ~= sqlite3.OK then
            logging.error("[Database] Failed to migrate items without IDs: " .. conn:errmsg())
        else
            local fallbackStmt = conn:prepare("SELECT COUNT(*) FROM lootrules_name_fallback")
            if fallbackStmt then
                if fallbackStmt:step() == sqlite3.ROW then
                    local fallback = fallbackStmt:get_value(0)
                    logging.debug(string.format("[Database] Migrated %d rules to fallback table", fallback))
                end
                fallbackStmt:finalize()
            end
        end
        
        -- Build item mappings from successfully migrated data
        local buildMappings = [[
            INSERT OR IGNORE INTO item_id_mappings (item_id, item_name, icon_id)
            SELECT DISTINCT item_id, item_name, icon_id
            FROM lootrules_v2
        ]]
        
        result = conn:exec(buildMappings)
        if result ~= sqlite3.OK then
            logging.error("[Database] Failed to build item mappings: " .. conn:errmsg())
        else
            local mappingsStmt = conn:prepare("SELECT COUNT(*) FROM item_id_mappings")
            if mappingsStmt then
                if mappingsStmt:step() == sqlite3.ROW then
                    local mappings = mappingsStmt:get_value(0)
                    logging.debug(string.format("[Database] Created %d item mappings", mappings))
                end
                mappingsStmt:finalize()
            end
        end
        
        logging.debug("[Database] Migration completed successfully")
    end
    
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
    
    -- Run migration to new schema
    if not migrateToItemIDBasedSchema(db) then
        logging.error("[Database] Schema migration failed")
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

    logging.debug("[Database] SQLite database initialized with itemID-based schema: " .. DB_PATH)
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
                icon_id = row.icon_id
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
                icon_id = 0
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
            
            -- Update cache
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

-- Convenience function for current character
function database.saveLootRule(itemName, itemID, rule, iconID)
    return database.saveLootRuleFor(mq.TLO.Me.Name(), itemName, itemID, rule, iconID)
end

-- ============================================================================
-- MIGRATION AND MAINTENANCE
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
                icon_id = row.icon_id
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
                icon_id = 0
            }
            count = count + 1
        end
        stmt2:finalize()
        logging.debug(string.format("[Database] Cached %d name-based rules for peer %s", count, peerName))
    end
    
    lootRulesCache.loaded[peerKey] = true
    return true
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

-- Debug function to show what's in all rule tables
function database.debugAllTables()
    local conn = getConnection()
    if not conn then
        logging.error("[Database] No database connection")
        return
    end
    
    -- Check which tables exist
    local tablesStmt = conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%lootrules%'")
    if tablesStmt then
        logging.log("[Database] Available loot rule tables:")
        for row in tablesStmt:nrows() do
            logging.log("  - " .. row.name)
        end
        tablesStmt:finalize()
    end
    
    -- Show original table if it exists
    local oldStmt = conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='lootrules'")
    if oldStmt and oldStmt:step() == sqlite3.ROW then
        oldStmt:finalize()
        local countStmt = conn:prepare("SELECT COUNT(*) FROM lootrules")
        if countStmt and countStmt:step() == sqlite3.ROW then
            local count = countStmt:get_value(0)
            logging.log(string.format("[Database] Original 'lootrules' table has %d rules", count))
            countStmt:finalize()
            
            -- Show sample data
            local sampleStmt = conn:prepare("SELECT toon, item_name, rule, item_id FROM lootrules LIMIT 5")
            if sampleStmt then
                logging.log("[Database] Sample from original table:")
                for row in sampleStmt:nrows() do
                    logging.log(string.format("  %s: %s -> %s (itemID=%s)", 
                                            row.toon, row.item_name, row.rule, tostring(row.item_id)))
                end
                sampleStmt:finalize()
            end
        end
    else
        if oldStmt then oldStmt:finalize() end
        logging.log("[Database] Original 'lootrules' table no longer exists")
    end
    
    -- Show v2 table
    local v2Stmt = conn:prepare("SELECT COUNT(*) FROM lootrules_v2")
    if v2Stmt and v2Stmt:step() == sqlite3.ROW then
        local count = v2Stmt:get_value(0)
        logging.log(string.format("[Database] 'lootrules_v2' table has %d rules", count))
        v2Stmt:finalize()
    end
    
    -- Show fallback table
    local fallbackStmt = conn:prepare("SELECT COUNT(*) FROM lootrules_name_fallback")
    if fallbackStmt and fallbackStmt:step() == sqlite3.ROW then
        local count = fallbackStmt:get_value(0)
        logging.log(string.format("[Database] 'lootrules_name_fallback' table has %d rules", count))
        fallbackStmt:finalize()
    end
end

-- Force re-migration of data (for debugging/fixing migration issues)
function database.forceMigration()
    local conn = getConnection()
    if not conn then
        logging.error("[Database] No database connection for forced migration")
        return false
    end
    
    logging.info("[Database] Starting forced migration...")
    
    -- Clear existing new tables
    conn:exec("DELETE FROM lootrules_v2")
    conn:exec("DELETE FROM lootrules_name_fallback") 
    conn:exec("DELETE FROM item_id_mappings")
    
    -- Check if old table exists
    local checkOldStmt = conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='lootrules'")
    local hasOldTable = false
    if checkOldStmt:step() == sqlite3.ROW then
        hasOldTable = true
    end
    checkOldStmt:finalize()
    
    if not hasOldTable then
        logging.warn("[Database] No old 'lootrules' table found for migration")
        return false
    end
    
    -- Show what we're working with
    local dataStmt = conn:prepare([[
        SELECT toon, item_name, rule, item_id, icon_id 
        FROM lootrules 
        LIMIT 5
    ]])
    
    if dataStmt then
        logging.debug("[Database] Sample data from old table:")
        while dataStmt:step() == sqlite3.ROW do
            local toon = dataStmt:get_value(0)
            local itemName = dataStmt:get_value(1) 
            local rule = dataStmt:get_value(2)
            local itemId = dataStmt:get_value(3)
            local iconId = dataStmt:get_value(4)
            logging.debug(string.format("  %s: %s -> %s (ID:%s, Icon:%s)", 
                         toon, itemName, rule, tostring(itemId), tostring(iconId)))
        end
        dataStmt:finalize()
    end
    
    -- Migrate ALL items with any itemID > 0 to itemID table
    local migrateWithIDs = [[
        INSERT INTO lootrules_v2 (toon, item_id, item_name, rule, icon_id, created_at, updated_at)
        SELECT toon, item_id, item_name, rule, COALESCE(icon_id, 0), created_at, updated_at
        FROM lootrules
        WHERE item_id > 0
    ]]
    
    local result = conn:exec(migrateWithIDs)
    if result == sqlite3.OK then
        local countStmt = conn:prepare("SELECT COUNT(*) FROM lootrules_v2")
        if countStmt:step() == sqlite3.ROW then
            local count = countStmt:get_value(0)
            logging.info(string.format("[Database] Migrated %d rules with itemIDs", count))
        end
        countStmt:finalize()
    else
        logging.error("[Database] Failed to migrate itemID rules: " .. conn:errmsg())
    end
    
    -- Migrate items without valid itemIDs to fallback
    local migrateWithoutIDs = [[
        INSERT INTO lootrules_name_fallback (toon, item_name, rule, created_at, updated_at)
        SELECT toon, item_name, rule, created_at, updated_at
        FROM lootrules
        WHERE item_id IS NULL OR item_id = 0
    ]]
    
    result = conn:exec(migrateWithoutIDs)
    if result == sqlite3.OK then
        local countStmt = conn:prepare("SELECT COUNT(*) FROM lootrules_name_fallback")
        if countStmt:step() == sqlite3.ROW then
            local count = countStmt:get_value(0)
            logging.info(string.format("[Database] Migrated %d rules to fallback table", count))
        end
        countStmt:finalize()
    else
        logging.error("[Database] Failed to migrate fallback rules: " .. conn:errmsg())
    end
    
    -- Build item mappings
    local buildMappings = [[
        INSERT INTO item_id_mappings (item_id, item_name, icon_id, first_seen, last_seen)
        SELECT DISTINCT item_id, item_name, COALESCE(icon_id, 0), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM lootrules_v2
    ]]
    
    result = conn:exec(buildMappings)
    if result == sqlite3.OK then
        local countStmt = conn:prepare("SELECT COUNT(*) FROM item_id_mappings")
        if countStmt:step() == sqlite3.ROW then
            local count = countStmt:get_value(0)
            logging.info(string.format("[Database] Created %d item mappings", count))
        end
        countStmt:finalize()
    else
        logging.error("[Database] Failed to build item mappings: " .. conn:errmsg())
    end
    
    -- Clear cache to force reload
    lootRulesCache = {
        byItemID = {},
        byName = {},
        itemMappings = {},
        loaded = {}
    }
    
    logging.info("[Database] Forced migration completed")
    return true
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