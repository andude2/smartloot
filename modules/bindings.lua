-- modules/bindings.lua - SmartLoot Command Bindings Module
local bindings = {}
local mq = require("mq")
local logging = require("modules.logging")
local util = require("modules.util")
local config = require("modules.config")

-- Module will be initialized with references to required components
local SmartLootEngine = nil
local lootUI = nil
local modeHandler = nil
local waterfallTracker = nil
local uiLiveStats = nil
local uiHelp = nil

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function bindings.initialize(engineRef, lootUIRef, modeHandlerRef, waterfallTrackerRef, uiLiveStatsRef, uiHelpRef)
    SmartLootEngine = engineRef
    lootUI = lootUIRef
    modeHandler = modeHandlerRef
    waterfallTracker = waterfallTrackerRef
    uiLiveStats = uiLiveStatsRef
    uiHelp = uiHelpRef

    -- Register all command bindings
    bindings.registerAllBindings()

    logging.log("[Bindings] Command bindings module initialized")
end

-- ============================================================================
-- COMMAND BINDING FUNCTIONS
-- ============================================================================

local function bindHotbarToggle()
    mq.bind("/sl_toggle_hotbar", function()
        if lootUI then
            lootUI.showHotbar = not lootUI.showHotbar
            util.printSmartLoot("Hotbar " .. (lootUI.showHotbar and "shown" or "hidden"), "info")
        end
    end)
end

local function bindPauseResume()
    mq.bind("/sl_pause", function(action)
        if not SmartLootEngine then return end

        if action == "on" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Manual pause")
            util.printSmartLoot("SmartLoot engine paused", "warning")
        elseif action == "off" then
            SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Manual resume")
            util.printSmartLoot("SmartLoot engine resumed", "success")
        else
            local currentMode = SmartLootEngine.getLootMode()
            if currentMode == SmartLootEngine.LootMode.Disabled then
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Background, "Manual toggle")
                util.printSmartLoot("SmartLoot engine resumed", "success")
            else
                SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Disabled, "Manual toggle")
                util.printSmartLoot("SmartLoot engine paused", "warning")
            end
        end
    end)
end

local function bindLiveStats()
    mq.bind("/sl_stats", function(action)
        if not uiLiveStats then
            util.printSmartLoot("Live stats module not available", "warning")
            return
        end

        if action == "show" then
            uiLiveStats.setVisible(true)
            util.printSmartLoot("Live stats window shown", "success")
        elseif action == "hide" then
            uiLiveStats.setVisible(false)
            util.printSmartLoot("Live stats window hidden", "warning")
        elseif action == "toggle" then
            uiLiveStats.toggle()
            local isVisible = uiLiveStats.isVisible()
            util.printSmartLoot("Live stats window " .. (isVisible and "shown" or "hidden"),
                isVisible and "success" or "warning")
        elseif action == "reset" then
            uiLiveStats.setPosition(200, 200)
            util.printSmartLoot("Live stats position reset", "info")
        elseif action == "compact" then
            local config = uiLiveStats.getConfig()
            uiLiveStats.setCompactMode(not config.compactMode)
            util.printSmartLoot("Live stats compact mode " .. (not config.compactMode and "enabled" or "disabled"),
                "info")
        else
            -- Default to toggle if no action specified
            uiLiveStats.toggle()
            local isVisible = uiLiveStats.isVisible()
            util.printSmartLoot("Live stats window " .. (isVisible and "shown" or "hidden"),
                isVisible and "success" or "warning")
        end
    end)
end

local function bindPeerCommands()
    mq.bind("/sl_peer_commands", function()
        if lootUI then
            lootUI.showPeerCommands = not (lootUI.showPeerCommands or false)
            util.printSmartLoot("Peer Commands window " .. (lootUI.showPeerCommands and "shown" or "hidden"), "info")
        end
    end)

    mq.bind("/sl_check_peers", function()
        if modeHandler and modeHandler.debugPeerStatus then
            modeHandler.debugPeerStatus()
        else
            util.printSmartLoot("Mode handler not available", "warning")
        end
    end)

    mq.bind("/sl_refresh_mode", function()
        if not modeHandler then
            util.printSmartLoot("Mode handler not available", "warning")
            return
        end

        local changed = modeHandler.refreshModeBasedOnPeers()
        if changed then
            util.printSmartLoot("Mode refreshed based on current peer status", "success")
        else
            util.printSmartLoot("Mode is already appropriate for current peer status", "info")
        end
    end)

    mq.bind("/sl_mode", function(mode)
        if not modeHandler then
            util.printSmartLoot("Mode handler not available", "warning")
            return
        end

        if not mode or mode == "" then
            util.printSmartLoot("Usage: /sl_mode <mode>", "error")
            util.printSmartLoot("Valid modes: main, background, rgmain, rgonce, once", "info")

            -- Show current mode
            local status = modeHandler.getPeerStatus()
            util.printSmartLoot("Current mode: " .. (status.currentMode or "unknown"), "info")
            return
        end

        mode = mode:lower()
        local validModes = { main = true, background = true, rgmain = true, rgonce = true, once = true }

        if not validModes[mode] then
            util.printSmartLoot("Invalid mode: " .. mode, "error")
            util.printSmartLoot("Valid modes: main, background, rgmain, rgonce, once", "info")
            return
        end

        util.printSmartLoot("Setting mode to: " .. mode, "info")

        -- Set the SmartLoot engine mode directly (this is what actually controls behavior)
        if SmartLootEngine and SmartLootEngine.LootMode then
            local engineMode
            if mode == "main" and SmartLootEngine.LootMode.Main then
                engineMode = SmartLootEngine.LootMode.Main
            elseif mode == "background" and SmartLootEngine.LootMode.Background then
                engineMode = SmartLootEngine.LootMode.Background
            elseif mode == "rgmain" and SmartLootEngine.LootMode.RGMain then
                engineMode = SmartLootEngine.LootMode.RGMain
            elseif mode == "rgonce" and SmartLootEngine.LootMode.RGOnce then
                engineMode = SmartLootEngine.LootMode.RGOnce
            elseif mode == "once" and SmartLootEngine.LootMode.Once then
                engineMode = SmartLootEngine.LootMode.Once
            end

            if engineMode and SmartLootEngine.setLootMode then
                SmartLootEngine.setLootMode(engineMode, "Manual /sl_mode command")
                util.printSmartLoot("SmartLoot engine mode set to: " .. mode, "success")
            else
                util.printSmartLoot("Failed to set engine mode", "error")
            end
        else
            util.printSmartLoot("SmartLootEngine not available", "warning")
        end

        -- Also update mode handler for consistency
        if modeHandler then
            modeHandler.setMode(mode, "Manual /sl_mode command")
        end

        util.printSmartLoot("Mode set to: " .. mode, "success")
    end)

    mq.bind("/sl_peer_monitor", function(action)
        if not modeHandler then
            util.printSmartLoot("Mode handler not available", "warning")
            return
        end

        if action == "on" or action == "start" then
            if modeHandler.startPeerMonitoring() then
                util.printSmartLoot("Peer monitoring started", "success")
            else
                util.printSmartLoot("Peer monitoring already active", "info")
            end
        elseif action == "off" or action == "stop" then
            modeHandler.stopPeerMonitoring()
            util.printSmartLoot("Peer monitoring stopped", "warning")
        else
            -- Toggle
            if modeHandler.state.peerMonitoringActive then
                modeHandler.stopPeerMonitoring()
                util.printSmartLoot("Peer monitoring stopped", "warning")
            else
                modeHandler.startPeerMonitoring()
                util.printSmartLoot("Peer monitoring started", "success")
            end
        end
    end)
end

local function bindStatusCommands()
    mq.bind("/sl_mode_status", function()
        if not modeHandler then
            util.printSmartLoot("Mode handler not available", "warning")
            return
        end

        local status = modeHandler.getPeerStatus()
        util.printSmartLoot("=== SmartLoot Mode Status ===", "system")
        util.printSmartLoot("Current Character: " .. (status.currentCharacter or "unknown"), "info")
        util.printSmartLoot("Current Mode: " .. (status.currentMode or "unknown"), "info")
        util.printSmartLoot("Should Be Main: " .. tostring(status.shouldBeMain), "info")
        util.printSmartLoot("Recommended Mode: " .. (status.recommendedMode or "unknown"), "info")
        util.printSmartLoot("Peer Monitoring: " .. (modeHandler.state.peerMonitoringActive and "Active" or "Inactive"),
            "info")

        if status.currentMode ~= status.recommendedMode then
            util.printSmartLoot("WARNING: Current mode doesn't match peer order!", "warning")
            util.printSmartLoot("Use /sl_refresh_mode to auto-correct", "warning")
        end
    end)

    mq.bind("/sl_engine_status", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        local state = SmartLootEngine.getState()
        local perf = SmartLootEngine.getPerformanceMetrics()
        util.printSmartLoot("=== SmartLoot Engine Status ===", "system")
        util.printSmartLoot("Mode: " .. state.mode, "info")
        util.printSmartLoot("State: " .. state.currentStateName, "info")
        util.printSmartLoot(
        "Current Corpse: " .. (state.currentCorpseID > 0 and tostring(state.currentCorpseID) or "None"), "info")
        util.printSmartLoot("Current Item: " .. (state.currentItemName ~= "" and state.currentItemName or "None"), "info")
        util.printSmartLoot("Pending Decision: " .. (state.needsPendingDecision and "YES" or "NO"), "info")
        util.printSmartLoot("Session Stats:", "system")
        util.printSmartLoot("  Corpses Processed: " .. state.stats.corpsesProcessed, "info")
        util.printSmartLoot("  Items Looted: " .. state.stats.itemsLooted, "info")
        util.printSmartLoot("  Items Ignored: " .. state.stats.itemsIgnored, "info")
        util.printSmartLoot("  Items Destroyed: " .. state.stats.itemsDestroyed, "info")
        util.printSmartLoot("Performance:", "system")
        util.printSmartLoot("  Avg Tick Time: " .. string.format("%.2fms", perf.averageTickTime), "info")
        util.printSmartLoot("  Corpses/Min: " .. string.format("%.1f", perf.corpsesPerMinute), "info")
        util.printSmartLoot("  Items/Min: " .. string.format("%.1f", perf.itemsPerMinute), "info")
    end)
end

local function bindEngineCommands()
    mq.bind("/sl_rg_trigger", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        logging.log("RGMercs trigger received - activating loot engine")

        -- Determine appropriate mode based on current context
        local currentMode = SmartLootEngine.getLootMode()

        if currentMode == SmartLootEngine.LootMode.RGMain then
            -- Trigger RGMain mode
            if SmartLootEngine.triggerRGMain() then
                util.printSmartLoot("RGMain triggered", "success")
            end
        else
            --util.printSmartLoot("RG trigger ignored - not in RGMain mode", "warning")
        end
    end)

    mq.bind("/sl_doloot", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        logging.log("Manual loot command - setting once mode")
        mq.cmd('/luachase pause on')
        SmartLootEngine.setLootMode(SmartLootEngine.LootMode.Once, "Manual /sl_doloot command")
        util.printSmartLoot("Loot once mode activated", "success")
    end)

    mq.bind("/sl_clearcache", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        SmartLootEngine.resetProcessedCorpses()
        util.printSmartLoot("SmartLoot cache cleared. All corpses will be treated as new.", "success")
    end)

    mq.bind("/sl_rulescache", function()
        local database = require("modules.database")
        if not database then
            util.printSmartLoot("Database module not available", "warning")
            return
        end

        util.printSmartLoot("Refreshing loot rules cache...", "info")

        -- Refresh local character's rules cache
        database.refreshLootRuleCache()

        -- Clear all peer rule caches to force reload on next access
        database.clearPeerRuleCache()

        -- Also refresh our own entry in the peer cache for UI consistency
        local currentToon = mq.TLO.Me.Name()
        if currentToon then
            database.refreshLootRuleCacheForPeer(currentToon)
        end

        util.printSmartLoot("Loot rules cache refreshed for local and all peers", "success")
        util.printSmartLoot("Peer rules will reload fresh data on next access", "info")
    end)

    mq.bind("/sl_emergency_stop", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        SmartLootEngine.emergencyStop("Manual command")
        util.printSmartLoot("EMERGENCY STOP ACTIVATED", "error")
    end)

    mq.bind("/sl_resume", function()
        if not SmartLootEngine then
            util.printSmartLoot("SmartLoot engine not available", "warning")
            return
        end

        SmartLootEngine.resume()
        util.printSmartLoot("Emergency stop cleared - engine resumed", "success")
    end)
end

local function bindWaterfallCommands()
    mq.bind("/sl_waterfall_status", function()
        if waterfallTracker and waterfallTracker.printStatus then
            waterfallTracker.printStatus()
        else
            util.printSmartLoot("Waterfall tracker not available", "warning")
        end
    end)

    mq.bind("/sl_waterfall_debug", function()
        if not waterfallTracker then
            util.printSmartLoot("Waterfall tracker not available", "warning")
            return
        end

        local status = waterfallTracker.getStatus()
        util.printSmartLoot("=== Waterfall Debug Info ===", "system")
        util.printSmartLoot("Raw Status: " .. tostring(status), "info")

        if SmartLootEngine then
            local engineState = SmartLootEngine.getState()
            util.printSmartLoot("Engine Waterfall Active: " .. tostring(engineState.waterfallActive), "info")
            util.printSmartLoot("Engine Waiting for Waterfall: " .. tostring(engineState.waitingForWaterfall), "info")
            util.printSmartLoot("Current State: " .. engineState.currentStateName, "info")
        end
    end)

    mq.bind("/sl_waterfall_complete", function()
        if not waterfallTracker then
            util.printSmartLoot("Waterfall tracker not available", "warning")
            return
        end

        util.printSmartLoot("Manually triggering waterfall completion check", "info")
        local completed = waterfallTracker.checkWaterfallProgress()

        if completed then
            util.printSmartLoot("Waterfall marked as complete", "success")
        else
            util.printSmartLoot("Waterfall still active - peers pending completion", "warning")
        end
    end)

    mq.bind("/sl_test_peer_complete", function(peerName)
        if not waterfallTracker then
            util.printSmartLoot("Waterfall tracker not available", "warning")
            return
        end

        if not peerName or peerName == "" then
            util.printSmartLoot("Usage: /sl_test_peer_complete <peerName>", "error")
            return
        end

        -- Simulate a peer completion message
        local testMessage = {
            cmd = "waterfall_completion",
            sessionId = "test_session_" .. peerName,
            peerName = peerName,
            sender = peerName,
            completionData = {
                status = "completed",
                sessionDuration = 5000,
                itemsProcessed = 3
            }
        }

        util.printSmartLoot("Simulating completion from " .. peerName, "info")
        waterfallTracker.handleMailboxMessage(testMessage)
    end)
end

local function bindDebugCommands()
    mq.bind("/sl_debug", function(action, level)
        -- Handle original behavior (toggle debug window)
        if not action or action == "" then
            if not lootUI then
                util.printSmartLoot("Loot UI not available", "warning")
                return
            end

            lootUI.showDebugWindow = not lootUI.showDebugWindow
            if lootUI.showDebugWindow then
                lootUI.forceDebugWindowVisible = true
                util.printSmartLoot("Debug window opened", "info")
            else
                util.printSmartLoot("Debug window closed", "info")
            end
            return
        end

        -- Handle debug level commands
        if action:lower() == "level" then
            if not level then
                -- Show current debug level
                local status = logging.getDebugStatus()
                util.printSmartLoot("Current debug level: " .. status.debugLevelName .. " (" .. status.debugLevel .. ")",
                    "info")
                util.printSmartLoot("Debug mode: " .. (status.debugMode and "ENABLED" or "DISABLED"), "info")
                util.printSmartLoot("Usage: /sl_debug level <0-5 or NONE/ERROR/WARN/INFO/DEBUG/VERBOSE>", "info")
                return
            end

            -- Convert level to number if it's a string number
            local numLevel = tonumber(level)
            if numLevel then
                logging.setDebugLevel(numLevel)
            else
                -- Try as string level name
                logging.setDebugLevel(level)
            end
            return
        end

        -- Unknown action
        util.printSmartLoot("Usage: /sl_debug - Toggle debug window", "info")
        util.printSmartLoot("Usage: /sl_debug level [0-5 or level name] - Set/show debug level", "info")
    end)
end

local function bindChatCommands()
    mq.bind("/sl_chat", function(mode)
        if not mode or mode == "" then
            util.printSmartLoot("Usage: /sl_chat <mode>", "error")
            util.printSmartLoot("Valid modes: raid, group, guild, custom, silent", "info")

            -- Show current mode
            local config = require("modules.config")
            local currentMode = config.chatOutputMode or "group"
            local modeMapping = {
                ["rsay"] = "raid",
                ["group"] = "group",
                ["guild"] = "guild",
                ["custom"] = "custom",
                ["silent"] = "silent"
            }
            local displayMode = modeMapping[currentMode] or currentMode
            util.printSmartLoot("Current chat mode: " .. displayMode, "info")
            return
        end

        -- Normalize the input
        mode = mode:lower()

        -- Map user-friendly names to internal config values
        local modeMapping = {
            ["raid"] = "rsay",
            ["group"] = "group",
            ["guild"] = "guild",
            ["custom"] = "custom",
            ["silent"] = "silent"
        }

        local configMode = modeMapping[mode]
        if not configMode then
            util.printSmartLoot("Invalid chat mode: " .. mode, "error")
            util.printSmartLoot("Valid modes: raid, group, guild, custom, silent", "info")
            return
        end

        -- Get config module
        local config = require("modules.config")

        -- Update the chat mode
        config.chatOutputMode = configMode

        -- Update the config directly first
        config.chatOutputMode = configMode

        -- Save the configuration
        if config.save then
            config.save()
        end

        util.printSmartLoot("Chat output mode changed to: " .. mode, "success")
        logging.log("[Bindings] Chat mode changed to " .. configMode .. " via command")

        -- Show the actual chat command that will be used
        local chatCommand = ""
        if config.getChatCommand then
            chatCommand = config.getChatCommand() or ""
        else
            -- Fallback display
            if configMode == "rsay" then
                chatCommand = "/rsay"
            elseif configMode == "group" then
                chatCommand = "/g"
            elseif configMode == "guild" then
                chatCommand = "/gu"
            elseif configMode == "custom" then
                chatCommand = config.customChatCommand or "/say"
            elseif configMode == "silent" then
                chatCommand = "No Output"
            end
        end

        if chatCommand and chatCommand ~= "" then
            util.printSmartLoot("Chat command: " .. chatCommand, "info")
        end
    end)
end

local function bindChaseCommands()
    -- Single command with on/off parameter
    mq.bind("/sl_chase", function(action)
        local config = require("modules.config")

        if not action or action == "" then
            -- Show current status
            local isEnabled = config.useChaseCommands or false
            util.printSmartLoot("Chase commands are currently: " .. (isEnabled and "ENABLED" or "DISABLED"), "info")
            util.printSmartLoot("Usage: /sl_chase <on|off>", "info")
            if isEnabled then
                util.printSmartLoot("Pause command: " .. (config.chasePauseCommand or "not set"), "info")
                util.printSmartLoot("Resume command: " .. (config.chaseResumeCommand or "not set"), "info")
            end
            return
        end

        action = action:lower()

        if action == "on" then
            config.useChaseCommands = true
            if config.save then
                config.save()
            end
            util.printSmartLoot("Chase commands ENABLED", "success")
            util.printSmartLoot("Pause command: " .. (config.chasePauseCommand or "/luachase pause on"), "info")
            util.printSmartLoot("Resume command: " .. (config.chaseResumeCommand or "/luachase pause off"), "info")
            logging.log("[Bindings] Chase commands enabled via command")
        elseif action == "off" then
            config.useChaseCommands = false
            if config.save then
                config.save()
            end
            util.printSmartLoot("Chase commands DISABLED", "warning")
            logging.log("[Bindings] Chase commands disabled via command")
        elseif action == "pause" then
            -- Execute pause command if chase is enabled
            if config.useChaseCommands then
                if config.executeChaseCommand then
                    local success, msg = config.executeChaseCommand("pause")
                    if success then
                        util.printSmartLoot("Chase pause executed: " .. msg, "success")
                    else
                        util.printSmartLoot("Chase pause failed: " .. msg, "error")
                    end
                else
                    -- Fallback
                    local pauseCmd = config.chasePauseCommand or "/luachase pause on"
                    mq.cmd(pauseCmd)
                    util.printSmartLoot("Chase pause executed: " .. pauseCmd, "success")
                end
            else
                util.printSmartLoot("Chase commands are disabled. Use /sl_chase on to enable.", "warning")
            end
        elseif action == "resume" then
            -- Execute resume command if chase is enabled
            if config.useChaseCommands then
                if config.executeChaseCommand then
                    local success, msg = config.executeChaseCommand("resume")
                    if success then
                        util.printSmartLoot("Chase resume executed: " .. msg, "success")
                    else
                        util.printSmartLoot("Chase resume failed: " .. msg, "error")
                    end
                else
                    -- Fallback
                    local resumeCmd = config.chaseResumeCommand or "/luachase pause off"
                    mq.cmd(resumeCmd)
                    util.printSmartLoot("Chase resume executed: " .. resumeCmd, "success")
                end
            else
                util.printSmartLoot("Chase commands are disabled. Use /sl_chase on to enable.", "warning")
            end
        else
            util.printSmartLoot("Invalid parameter: " .. action, "error")
            util.printSmartLoot("Usage: /sl_chase <on|off|pause|resume>", "info")
        end
    end)

    -- Add separate shortcut commands for convenience
    mq.bind("/sl_chase_on", function()
        mq.cmd("/sl_chase on")
    end)

    mq.bind("/sl_chase_off", function()
        mq.cmd("/sl_chase off")
    end)
end

local function bindTempRuleCommands()
    mq.bind("/sl_addtemp", function(...)
        local args = { ... }
        if #args < 2 then
            util.printSmartLoot("Usage: /sl_addtemp <itemname> <rule> [threshold]", "error")
            util.printSmartLoot("Rules: Keep, Ignore, Destroy, KeepIfFewerThan", "info")
            util.printSmartLoot("Example: /sl_addtemp \"Short Sword\" Keep", "info")
            util.printSmartLoot("Example: /sl_addtemp \"Rusty Dagger\" KeepIfFewerThan 5", "info")
            return
        end

        local itemName = args[1]
        local rule = args[2]
        local threshold = tonumber(args[3]) or 1

        -- Validate rule
        local validRules = { "Keep", "Ignore", "Destroy", "KeepIfFewerThan" }
        local isValidRule = false
        for _, validRule in ipairs(validRules) do
            if rule:lower() == validRule:lower() then
                rule = validRule -- Normalize case
                isValidRule = true
                break
            end
        end

        if not isValidRule then
            util.printSmartLoot("Invalid rule: " .. rule, "error")
            util.printSmartLoot("Valid rules: Keep, Ignore, Destroy, KeepIfFewerThan", "info")
            return
        end

        local tempRules = require("modules.temp_rules")
        local success, err = tempRules.add(itemName, rule, threshold)
        if success then
            if rule == "KeepIfFewerThan" then
                util.printSmartLoot("Added temporary rule: " .. itemName .. " -> " .. rule .. " (" .. threshold .. ")",
                    "success")
            else
                util.printSmartLoot("Added temporary rule: " .. itemName .. " -> " .. rule, "success")
            end
        else
            util.printSmartLoot("Failed to add temporary rule: " .. tostring(err), "error")
        end
    end)

    mq.bind("/sl_listtemp", function()
        local tempRules = require("modules.temp_rules")
        local rules = tempRules.getAll()

        if #rules == 0 then
            util.printSmartLoot("No temporary rules active", "info")
            util.printSmartLoot("AFK Farming Mode: INACTIVE", "warning")
            return
        end

        util.printSmartLoot("=== Temporary Rules (" .. #rules .. " active) ===", "system")
        util.printSmartLoot("AFK Farming Mode: ACTIVE", "success")

        for _, rule in ipairs(rules) do
            local displayRule, threshold = tempRules.parseRule(rule.rule)
            if displayRule == "KeepIfFewerThan" then
                util.printSmartLoot(
                "  " ..
                rule.itemName ..
                " -> " .. displayRule .. " (" .. threshold .. ") [Added: " .. (rule.addedAt or "unknown") .. "]", "info")
            else
                util.printSmartLoot(
                "  " .. rule.itemName .. " -> " .. displayRule .. " [Added: " .. (rule.addedAt or "unknown") .. "]",
                    "info")
            end
        end
    end)

    mq.bind("/sl_removetemp", function(itemName)
        if not itemName or itemName == "" then
            util.printSmartLoot("Usage: /sl_removetemp <itemname>", "error")
            return
        end

        local tempRules = require("modules.temp_rules")
        if tempRules.remove(itemName) then
            util.printSmartLoot("Removed temporary rule for: " .. itemName, "success")
        else
            util.printSmartLoot("No temporary rule found for: " .. itemName, "warning")
        end
    end)

    mq.bind("/sl_cleartemp", function()
        -- Confirm before clearing
        util.printSmartLoot("Are you sure you want to clear ALL temporary rules?", "warning")
        util.printSmartLoot("Type: /sl_cleartemp_confirm to confirm", "warning")
    end)

    mq.bind("/sl_cleartemp_confirm", function()
        local tempRules = require("modules.temp_rules")
        local count = tempRules.getCount()
        tempRules.clearAll()
        util.printSmartLoot("Cleared " .. count .. " temporary rules", "success")
        util.printSmartLoot("AFK Farming Mode: INACTIVE", "warning")
    end)

    mq.bind("/sl_afkfarm", function(action)
        local tempRules = require("modules.temp_rules")

        if not action or action == "" then
            -- Show status
            local isActive = tempRules.isAFKFarmingActive()
            local count = tempRules.getCount()

            util.printSmartLoot("=== AFK Farming Mode Status ===", "system")
            util.printSmartLoot("Status: " .. (isActive and "ACTIVE" or "INACTIVE"), isActive and "success" or "warning")
            util.printSmartLoot("Temporary Rules: " .. count, "info")
            util.printSmartLoot("Usage: /sl_afkfarm status|list|help", "info")
        elseif action:lower() == "status" then
            local count = tempRules.getCount()
            local isActive = count > 0

            util.printSmartLoot("AFK Farming Mode: " .. (isActive and "ACTIVE" or "INACTIVE"),
                isActive and "success" or "warning")
            util.printSmartLoot("Temporary Rules: " .. count, "info")

            if isActive then
                util.printSmartLoot("When items are encountered:", "info")
                util.printSmartLoot("  1. Temporary rule will be applied", "info")
                util.printSmartLoot("  2. Rule converts to permanent with discovered Item ID", "info")
                util.printSmartLoot("  3. Temporary rule is removed", "info")
            end
        elseif action:lower() == "list" then
            mq.cmd("/sl_listtemp")
        elseif action:lower() == "help" then
            util.printSmartLoot("=== AFK Farming Mode Help ===", "system")
            util.printSmartLoot("Commands:", "info")
            util.printSmartLoot("  /sl_addtemp <item> <rule> [threshold] - Add temporary rule", "info")
            util.printSmartLoot("  /sl_listtemp - List all temporary rules", "info")
            util.printSmartLoot("  /sl_removetemp <item> - Remove specific rule", "info")
            util.printSmartLoot("  /sl_cleartemp - Clear all temporary rules", "info")
            util.printSmartLoot("  /sl_afkfarm [status|list|help] - AFK farm status/help", "info")
            util.printSmartLoot("Examples:", "info")
            util.printSmartLoot("  /sl_addtemp \"Short Sword\" Keep", "info")
            util.printSmartLoot("  /sl_addtemp \"Rusty Dagger\" KeepIfFewerThan 5", "info")
            util.printSmartLoot("  /sl_addtemp \"Cloth Cap\" Destroy", "info")
        else
            util.printSmartLoot("Unknown action: " .. action, "error")
            util.printSmartLoot("Valid actions: status, list, help", "info")
        end
    end)
end

local function bindUtilityCommands()
    mq.bind("/sl_help", function()
        if uiHelp then
            uiHelp.toggle()
            local isVisible = uiHelp.isVisible()
            util.printSmartLoot("Help window " .. (isVisible and "opened" or "closed"), isVisible and "success" or "info")
        else
            -- Fallback to text help if UI module not available
            util.printSmartLoot("=== SmartLoot Command Help ===", "system")
            util.printSmartLoot("Getting Started:", "info")
            util.printSmartLoot("  /sl_getstarted - Complete getting started guide", "info")
            util.printSmartLoot("Engine Control:", "info")
            util.printSmartLoot("  /sl_pause [on|off] - Pause/resume engine", "info")
            util.printSmartLoot("  /sl_doloot - Trigger once mode", "info")
            util.printSmartLoot("  /sl_rg_trigger - Trigger RGMain mode", "info")
            util.printSmartLoot("  /sl_emergency_stop - Emergency stop", "info")
            util.printSmartLoot("  /sl_resume - Resume from emergency stop", "info")
            util.printSmartLoot("UI Control:", "info")
            util.printSmartLoot("  /sl_toggle_hotbar - Toggle hotbar visibility", "info")
            util.printSmartLoot("  /sl_debug - Toggle debug window", "info")
            util.printSmartLoot("  /sl_debug level [X] - Set/show debug level (0-5 or name)", "info")
            util.printSmartLoot("  /sl_stats [show|hide|toggle|reset|compact] - Live stats", "info")
            util.printSmartLoot("Status & Debug:", "info")
            util.printSmartLoot("  /sl_engine_status - Show engine status", "info")
            util.printSmartLoot("  /sl_mode_status - Show mode status", "info")
            util.printSmartLoot("  /sl_waterfall_status - Show waterfall status", "info")
            util.printSmartLoot("  /sl_waterfall_debug - Waterfall debug info", "info")
            util.printSmartLoot("  /sl_waterfall_complete - Manually check waterfall completion", "info")
            util.printSmartLoot("Testing:", "info")
            util.printSmartLoot("  /sl_test_peer_complete <peer> - Simulate peer completion", "info")
            util.printSmartLoot("Peer Management:", "info")
            util.printSmartLoot("  /sl_check_peers - Check peer connections", "info")
            util.printSmartLoot("  /sl_refresh_mode - Refresh mode based on peers", "info")
            util.printSmartLoot("  /sl_mode <mode> - Set loot mode (main|background|rgmain|rgonce|once)", "info")
            util.printSmartLoot("  /sl_peer_monitor [on|off] - Toggle peer monitoring", "info")
            util.printSmartLoot("Maintenance:", "info")
            util.printSmartLoot("  /sl_clearcache - Clear corpse cache", "info")
            util.printSmartLoot("  /sl_rulescache - Refresh loot rules cache", "info")
            util.printSmartLoot("  /sl_help - Show this help", "info")
            util.printSmartLoot("Chat & Chase Control:", "info")
            util.printSmartLoot("  /sl_chat <mode> - Set chat output (raid|group|guild|custom|silent)", "info")
            util.printSmartLoot("  /sl_chase <on|off|pause|resume> - Control chase commands", "info")
            util.printSmartLoot("  /sl_chase_on - Enable chase commands", "info")
            util.printSmartLoot("  /sl_chase_off - Disable chase commands", "info")
            util.printSmartLoot("AFK Farming:", "info")
            util.printSmartLoot("  /sl_addtemp <item> <rule> [threshold] - Add temporary rule", "info")
            util.printSmartLoot("  /sl_listtemp - List all temporary rules", "info")
            util.printSmartLoot("  /sl_removetemp <item> - Remove specific rule", "info")
            util.printSmartLoot("  /sl_cleartemp - Clear all temporary rules", "info")
            util.printSmartLoot("  /sl_afkfarm [status|list|help] - AFK farm status/help", "info")
        end
    end)

    mq.bind("/sl_getstarted", function()
        if lootUI then
            lootUI.showGettingStartedPopup = not lootUI.showGettingStartedPopup
        end
    end)

    mq.bind("/sl_save", function()
        config.save()
    end)
end

-- ============================================================================
-- MAIN REGISTRATION FUNCTION
-- ============================================================================

function bindings.registerAllBindings()
    bindHotbarToggle()
    bindPauseResume()
    bindLiveStats()
    bindPeerCommands()
    bindStatusCommands()
    bindEngineCommands()
    bindWaterfallCommands()
    bindDebugCommands()
    bindChatCommands()
    bindChaseCommands()
    bindTempRuleCommands()
    bindUtilityCommands()

    logging.log("[Bindings] All command bindings registered")
end

-- ============================================================================
-- CLEANUP FUNCTION
-- ============================================================================

function bindings.cleanup()
    -- MQ2 doesn't have explicit unbind, but we can clear references
    SmartLootEngine = nil
    lootUI = nil
    modeHandler = nil
    waterfallTracker = nil
    uiLiveStats = nil
    uiHelp = nil

    logging.log("[Bindings] Module cleaned up")
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

function bindings.listBindings()
    local commands = {
        "/sl_pause", "/sl_doloot", "/sl_rg_trigger", "/sl_emergency_stop", "/sl_resume",
        "/sl_toggle_hotbar", "/sl_debug", "/sl_stats",
        "/sl_engine_status", "/sl_mode_status", "/sl_waterfall_status", "/sl_waterfall_debug", "/sl_waterfall_complete",
        "/sl_test_peer_complete",
        "/sl_check_peers", "/sl_refresh_mode", "/sl_mode", "/sl_peer_monitor",
        "/sl_chat", "/sl_chase", "/sl_chase_on", "/sl_chase_off",
        "/sl_addtemp", "/sl_removetemp", "/sl_cleartemp", "/sl_afkfarm",
        "/sl_clearcache", "/sl_rulescache", "/sl_help", "/sl_getstarted", "/sl_version"
    }

    util.printSmartLoot("=== Registered SmartLoot Commands ===", "system")
    for _, cmd in ipairs(commands) do
        util.printSmartLoot("  " .. cmd, "info")
    end
    util.printSmartLoot("Use /sl_help for detailed command help", "info")
end

return bindings
