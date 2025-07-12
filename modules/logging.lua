-- modules/logging.lua - Enhanced with Debug Levels
local logging = {}
local mq = require("mq")

local logMessages = {}
local MAX_FILE_LINES = 10000
local TRIM_CHECK_INTERVAL = 250
local logCounter = 0
local LOG_FILENAME = "SmartLoot.log"

-- Debug levels and configuration
logging.DEBUG_LEVELS = {
    NONE = 0,     -- No debug output
    ERROR = 1,    -- Only errors
    WARN = 2,     -- Warnings and errors
    INFO = 3,     -- Info, warnings, and errors
    DEBUG = 4,    -- All messages including debug
    VERBOSE = 5   -- Everything including verbose debug
}

-- Current debug level (can be changed at runtime)
logging.currentDebugLevel = logging.DEBUG_LEVELS.INFO

-- Global debug mode toggle
logging.debugMode = true

local function getLogFilePath()
    return mq.TLO.MacroQuest.Path('resources')() .. "/" .. LOG_FILENAME
end

local function trimLogFileIfNeeded()
    local logFilePath = getLogFilePath()

    local lines = {}
    local lineCount = 0
    local readFile = io.open(logFilePath, "r")
    if readFile then
        for line in readFile:lines() do
            table.insert(lines, line)
            lineCount = lineCount + 1
        end
        readFile:close()
    end

    if lineCount > MAX_FILE_LINES then
        local trimmed = {}
        for i = lineCount - MAX_FILE_LINES + 1, lineCount do
            table.insert(trimmed, lines[i])
        end
        local writeFile = io.open(logFilePath, "w")
        if writeFile then
            writeFile:write(table.concat(trimmed, "\n") .. "\n")
            writeFile:close()
        end

        mq.cmdf("/echo \ag[SmartLoot]\ax Trimmed log file to last %d lines.", MAX_FILE_LINES)
    end
end

function logging.writeLogToFile(msg)
    local logFilePath = getLogFilePath()
    local file = io.open(logFilePath, "a")
    if file then
        file:write(msg .. "\n")
        file:close()
    end

    logCounter = logCounter + 1
    if logCounter >= TRIM_CHECK_INTERVAL then
        trimLogFileIfNeeded()
        logCounter = 0
    end
end

function logging.readLogFile()
    local file = io.open(getLogFilePath(), "r")
    if file then
        local content = file:read("*a")
        file:close()
        return content
    end
    return ""
end

-- Core logging function with level support
local function logWithLevel(msg, level, forceOutput)
    -- Skip if debug mode is off and not forced, and level is DEBUG or VERBOSE
    if not logging.debugMode and not forceOutput and level >= logging.DEBUG_LEVELS.DEBUG then
        return
    end
    
    -- Skip if current debug level is lower than message level
    if logging.currentDebugLevel < level and not forceOutput then
        return
    end

    local peer = mq.TLO.Me.Name() or "unknown"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    
    -- Add level prefix
    local levelPrefix = ""
    if level == logging.DEBUG_LEVELS.ERROR then
        levelPrefix = "[ERROR] "
    elseif level == logging.DEBUG_LEVELS.WARN then
        levelPrefix = "[WARN] "
    elseif level == logging.DEBUG_LEVELS.DEBUG then
        levelPrefix = "[DEBUG] "
    elseif level == logging.DEBUG_LEVELS.VERBOSE then
        levelPrefix = "[VERBOSE] "
    end
    
    local fullMsg = string.format("[%s] %s - %s%s", timestamp, peer, levelPrefix, msg)

    table.insert(logMessages, fullMsg)
    if #logMessages > 200 then
        table.remove(logMessages, 1)
    end

    logging.writeLogToFile(fullMsg)
end

-- Main logging functions (backward compatible)
function logging.log(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.INFO, false)
end

-- New level-specific logging functions
function logging.error(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.ERROR, true) -- Always show errors
end

function logging.warn(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.WARN, false)
end

function logging.info(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.INFO, false)
end

function logging.debug(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.DEBUG, false)
end

function logging.verbose(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.VERBOSE, false)
end

-- Force log (always outputs regardless of debug settings)
function logging.force(msg)
    logWithLevel(msg, logging.DEBUG_LEVELS.INFO, true)
end

-- Configuration functions
function logging.setDebugMode(enabled)
    logging.debugMode = enabled
    local status = enabled and "enabled" or "disabled"
    logging.force(string.format("[SmartLoot] Debug mode %s", status))
end

function logging.setDebugLevel(level)
    if type(level) == "string" then
        level = logging.DEBUG_LEVELS[level:upper()]
    end
    
    if level and level >= logging.DEBUG_LEVELS.NONE and level <= logging.DEBUG_LEVELS.VERBOSE then
        logging.currentDebugLevel = level
        
        local levelNames = {"NONE", "ERROR", "WARN", "INFO", "DEBUG", "VERBOSE"}
        local levelName = levelNames[level + 1] or "UNKNOWN"
        logging.force(string.format("[SmartLoot] Debug level set to %s (%d)", levelName, level))
    else
        logging.error("Invalid debug level. Use 0-5 or NONE/ERROR/WARN/INFO/DEBUG/VERBOSE")
    end
end

function logging.getDebugStatus()
    local levelNames = {"NONE", "ERROR", "WARN", "INFO", "DEBUG", "VERBOSE"}
    local levelName = levelNames[logging.currentDebugLevel + 1] or "UNKNOWN"
    
    return {
        debugMode = logging.debugMode,
        debugLevel = logging.currentDebugLevel,
        debugLevelName = levelName
    }
end

-- Helper functions for common debug patterns
function logging.debugUI(msg)
    logging.debug("[UI] " .. msg)
end

function logging.debugDatabase(msg)
    logging.debug("[Database] " .. msg)
end

function logging.debugLoot(msg)
    logging.debug("[Loot] " .. msg)
end

function logging.debugStats(msg)
    logging.debug("[Stats] " .. msg)
end

function logging.debugPeers(msg)
    logging.debug("[Peers] " .. msg)
end

-- Get log messages for UI display
function logging.getMessages()
    return logMessages
end

return logging