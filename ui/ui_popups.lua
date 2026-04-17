-- ui/ui_popups.lua (Enhanced with improved peer rule workflow)
local mq = require("mq")
local ImGui = require("ImGui")
local logging = require("modules.logging")
local uiUtils = require("ui.ui_utils")
local util = require("modules.util")
local database = require("modules.database")
local config = require("modules.config")
local json = require("dkjson")
local SmartLootEngine = require("modules.SmartLootEngine")

local uiPopups = {}
local uiUtils = require("ui.ui_utils")

local function formatCopperValue(value)
    value = tonumber(value) or 0
    local platValue = math.floor(value / 1000)
    local goldValue = math.floor((value % 1000) / 100)
    local silverValue = math.floor((value % 100) / 10)
    local copperValue = value % 10

    if platValue > 0 then
        if goldValue > 0 then
            return string.format("%dp %dg", platValue, goldValue)
        end
        return string.format("%dp", platValue)
    end
    if goldValue > 0 then
        if silverValue > 0 then
            return string.format("%dg %ds", goldValue, silverValue)
        end
        return string.format("%dg", goldValue)
    end
    if silverValue > 0 then
        if copperValue > 0 then
            return string.format("%ds %dc", silverValue, copperValue)
        end
        return string.format("%ds", silverValue)
    end
    return string.format("%dc", copperValue)
end

local function getFinalRuleForSelection(rule, threshold)
    if rule == "KeepIfFewerThan" then
        return "KeepIfFewerThan:" .. tostring(math.max(1, tonumber(threshold) or 1))
    elseif rule == "KeepThenIgnore" then
        return "KeepIfFewerThan:" .. tostring(math.max(1, tonumber(threshold) or 1)) .. ":AutoIgnore"
    end
    return rule
end

local RULE_COLORS = {
    Keep = {0.2, 0.8, 0.2, 1},
    Ignore = {0.8, 0.2, 0.2, 1},
    Destroy = {0.6, 0.2, 0.8, 1},
    KeepIfFewerThan = {0.8, 0.6, 0.2, 1},
    Unset = {0.5, 0.5, 0.5, 1},
}

local function getRuleColor(rule)
    return RULE_COLORS[rule] or RULE_COLORS.Unset
end

local function getRuleLabel(rule)
    if not rule or rule == "" then
        return "Unset"
    end
    local threshold = tonumber(rule:match("^KeepIfFewerThan:(%d+)"))
    if threshold then
        if rule:find(":AutoIgnore") then
            return string.format("KeepThenIgnore (%d)", threshold)
        end
        return string.format("KeepIfFewerThan (%d)", threshold)
    end
    return rule
end

local PEER_RULE_BULK_TARGETS = {
    { key = "all", label = "All Peers" },
    { key = "plate", label = "All Plate" },
    { key = "chain", label = "All Chain" },
    { key = "leather", label = "All Leather" },
    { key = "silk", label = "All Silk" },
    { key = "warrior", label = "All Warriors" },
    { key = "cleric", label = "All Clerics" },
    { key = "paladin", label = "All Paladins" },
    { key = "shadowknight", label = "All Shadow Knights" },
    { key = "ranger", label = "All Rangers" },
    { key = "bard", label = "All Bards" },
    { key = "rogue", label = "All Rogues" },
    { key = "shaman", label = "All Shamans" },
    { key = "berserker", label = "All Berserkers" },
    { key = "druid", label = "All Druids" },
    { key = "monk", label = "All Monks" },
    { key = "beastlord", label = "All Beastlords" },
    { key = "necromancer", label = "All Necromancers" },
    { key = "wizard", label = "All Wizards" },
    { key = "magician", label = "All Magicians" },
    { key = "enchanter", label = "All Enchanters" },
}

local PEER_RULE_CLASS_TARGETS = {
    war = "warrior", warrior = "warrior",
    clr = "cleric", cleric = "cleric",
    pal = "paladin", paladin = "paladin",
    shd = "shadowknight", shadowknight = "shadowknight",
    rng = "ranger", ranger = "ranger",
    brd = "bard", bard = "bard",
    rog = "rogue", rogue = "rogue",
    shm = "shaman", shaman = "shaman",
    ber = "berserker", berserker = "berserker",
    dru = "druid", druid = "druid",
    mnk = "monk", monk = "monk",
    bst = "beastlord", beastlord = "beastlord",
    nec = "necromancer", necromancer = "necromancer",
    wiz = "wizard", wizard = "wizard",
    mag = "magician", magician = "magician",
    enc = "enchanter", enchanter = "enchanter",
}

local function normalizePeerClassName(className)
    if not className or className == "" then
        return nil
    end
    return tostring(className):gsub("%s+", ""):lower()
end

local function getPeerRuleBulkTargetLabel(targetKey)
    for _, option in ipairs(PEER_RULE_BULK_TARGETS) do
        if option.key == targetKey then
            return option.label
        end
    end
    return "All Peers"
end

local function getPeerClassName(peerName, currentCharacter, connectedPeerSet)
    if not peerName or peerName == "" then
        return nil
    end
    if peerName == currentCharacter then
        return mq.TLO.Me.Class.ShortName() or mq.TLO.Me.Class.Name() or nil
    end
    if connectedPeerSet and connectedPeerSet[peerName] then
        local spawn = mq.TLO.Spawn(peerName)
        if spawn() then
            return spawn.Class.ShortName() or spawn.Class.Name() or nil
        end
    end
    return nil
end

local function doesPeerMatchBulkTarget(peerClassName, targetKey)
    if targetKey == "all" then
        return true
    end
    local normalizedClass = normalizePeerClassName(peerClassName)
    if not normalizedClass then
        return false
    end
    if targetKey == "plate" or targetKey == "chain" or targetKey == "leather" then
        return database.getArmorTypeByClass(normalizedClass) == targetKey
    end
    if targetKey == "silk" then
        local armorType = database.getArmorTypeByClass(normalizedClass)
        return armorType == "cloth" or armorType == "silk"
    end
    return PEER_RULE_CLASS_TARGETS[normalizedClass] == targetKey
end

local function savePeerPopupRuleFor(peer, itemName, itemID, iconID, newRuleValue, currentCharacter, connectedPeerSet, tableSource)
    local isFromFallback = (tableSource == "lootrules_name_fallback")
    local success = false
    if isFromFallback then
        success = database.saveNameBasedRuleFor(peer, itemName, newRuleValue)
    elseif peer == currentCharacter then
        success = database.saveLootRule(itemName, itemID, newRuleValue, iconID)
    else
        success = database.saveLootRuleFor(peer, itemName, itemID, newRuleValue, iconID)
    end

    if success then
        if peer == currentCharacter then
            database.refreshLootRuleCache()
        else
            database.refreshLootRuleCacheForPeer(peer)
        end
        if connectedPeerSet and connectedPeerSet[peer] then
            util.sendPeerCommandViaActor(peer, "reload_rules")
        end
    end
    return success
end

local function saveUnknownReviewRule(item, targetCharacter, finalRule)
    local success = false
    if targetCharacter == (mq.TLO.Me.Name() or "unknown") then
        success = database.saveLootRule(item.itemName, item.itemID or 0, finalRule, item.iconID or 0)
        if success then
            database.refreshLootRuleCache()
        end
    else
        success = database.saveLootRuleFor(targetCharacter, item.itemName, item.itemID or 0, finalRule, item.iconID or 0)
        if success then
            database.refreshLootRuleCacheForPeer(targetCharacter)
            util.sendPeerCommandViaActor(targetCharacter, "reload_rules")
        end
    end
    return success
end

local function applyUnknownReviewRuleToAll(item, finalRule, utilRef)
    local localToon = mq.TLO.Me.Name() or "unknown"
    local successCount = 0

    if saveUnknownReviewRule(item, localToon, finalRule) then
        successCount = successCount + 1
    end

    for _, peer in ipairs(utilRef.getConnectedPeers()) do
        if peer ~= localToon and saveUnknownReviewRule(item, peer, finalRule) then
            successCount = successCount + 1
        end
    end

    return successCount
end

-- Session Report Popup
function uiPopups.drawSessionReportPopup(lootUI, lootHistory, SmartLootEngine)
    if not lootUI.sessionReportPopup or not lootUI.sessionReportPopup.isOpen then return end

    local popup = lootUI.sessionReportPopup
    -- Defaults for live refresh behavior
    if popup.autoRefresh == nil then popup.autoRefresh = true end
    if popup.refreshIntervalMs == nil then popup.refreshIntervalMs = 1000 end
    if popup.lastRefreshAt == nil then popup.lastRefreshAt = 0 end
    ImGui.SetNextWindowSize(560, 420, ImGuiCond.FirstUseEver)
    local open = ImGui.Begin("SmartLoot - Session Report", true)
    if not open then
        lootUI.sessionReportPopup.isOpen = false
        ImGui.End()
        return
    end

    local s = SmartLootEngine.stats or {}
    local minutes = 0
    if s.sessionStartUnix and type(s.sessionStartUnix) == 'number' then
        minutes = math.floor(math.max(0, os.difftime(os.time(), s.sessionStartUnix)) / 60)
    end

    -- Info line
    local startIso = (SmartLootEngine.stats and SmartLootEngine.stats.sessionStartIsoUtc) or os.date("!%Y-%m-%d %H:%M:%S")
    ImGui.Text("Session Length: %d min", minutes)

    ImGui.Separator()

    -- Auto-refresh timer: mark for fetch at interval while open
    local nowMs = (mq and mq.gettime and mq.gettime()) or 0
    if popup.autoRefresh and nowMs > 0 and (nowMs - (popup.lastRefreshAt or 0)) >= (popup.refreshIntervalMs or 1000) then
        popup.needsFetch = true
    end

    -- Fetch data if needed
    if popup.needsFetch or not popup.rows then
        local filters = { startDate = startIso, orderBy = 'looted_quantity', orderDir = 'DESC' }
        if popup.scope == 'me' then
            filters.looter = mq.TLO.Me.Name() or 'All'
        end
        local ok, result = pcall(function() return lootHistory.getAggregatedHistory(filters) end)
        if ok then
            popup.rows = result or {}
            popup.zonesByItem = {} -- reset cache when refetching
        else
            popup.rows = {}
            logging.log("[SessionReport] Failed to fetch history: " .. tostring(result))
        end
        popup.needsFetch = false
        popup.lastRefreshAt = nowMs
    end

    ImGui.Text("Items Looted: %d | Corpses: %d", s.itemsLooted or 0, s.corpsesProcessed or 0)

    ImGui.Spacing()

    -- Table
    local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollY)
    if ImGui.BeginTable("SL_SessionReportTable", 3, flags) then
        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Qty", ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableHeadersRow()

        -- Stable, safe ordering without ImGui sort specs
        local rowsToDisplay = popup.rows or {}
        table.sort(rowsToDisplay, function(a, b)
            local qa = tonumber(a.looted_quantity) or 0
            local qb = tonumber(b.looted_quantity) or 0
            if qa ~= qb then return qa > qb end
            -- tie-breaker by item name
            local na = tostring(a.item_name or "")
            local nb = tostring(b.item_name or "")
            return na < nb
        end)

        -- Render the rows
        for _, row in ipairs(rowsToDisplay) do
            local qty = tonumber(row.looted_quantity) or 0
            if qty > 0 then
                ImGui.TableNextRow()

                -- Icon
                ImGui.TableSetColumnIndex(0)
                uiUtils.drawItemIcon(tonumber(row.icon_id) or 0)

                -- Item name
                ImGui.TableSetColumnIndex(1)
                ImGui.Text(row.item_name or "")

                -- Quantity
                ImGui.TableSetColumnIndex(2)
                ImGui.Text(tostring(qty))
            end
        end

        ImGui.EndTable()
    else
        ImGui.Text("No data.")
    end

    ImGui.Separator()
    if ImGui.Button("Close") then
        lootUI.sessionReportPopup.isOpen = false
    end

    ImGui.SameLine()
    ImGui.TextDisabled("Tip: Use /sl_engine_reset to reset session.")

    ImGui.End()
end

-- Whitelist Manager Popup (per-character)
function uiPopups.drawWhitelistManagerPopup(lootUI, database, util)
    if not lootUI.whitelistManagerPopup or not lootUI.whitelistManagerPopup.isOpen then return end

    local state = lootUI.whitelistManagerPopup
    ImGui.SetNextWindowSize(620, 520, ImGuiCond.FirstUseEver)
    local open = ImGui.Begin("SmartLoot - Whitelist Manager", true)
    if not open then
        lootUI.whitelistManagerPopup.isOpen = false
        ImGui.End()
        return
    end

    local toonName = mq.TLO.Me.Name() or "unknown"
    ImGui.Text("Character:")
    ImGui.SameLine()
    ImGui.TextColored(0.8, 1.0, 0.8, 1.0, toonName)
    ImGui.SameLine()
    ImGui.TextDisabled("(Keep/threshold rules = whitelisted)")

    ImGui.Separator()

    -- Add item section
    ImGui.Text("Add Item to Whitelist:")
    ImGui.SameLine()
    ImGui.PushItemWidth(260)
    local newName, nameChanged = ImGui.InputText("##WLAddItemName", state.addItemName or "", 128)
    if nameChanged then state.addItemName = newName end
    ImGui.PopItemWidth()

    ImGui.SameLine()
    ImGui.PushItemWidth(120)
    local ruleTypes = {"Keep", "KeepIfFewerThan"}
    local currentRule = state.addRuleType or "Keep"
    if ImGui.BeginCombo("##WLAddRuleType", currentRule) then
        for _, r in ipairs(ruleTypes) do
            local selected = (currentRule == r)
            if ImGui.Selectable(r, selected) then
                state.addRuleType = r
                currentRule = r
            end
            if selected then ImGui.SetItemDefaultFocus() end
        end
        ImGui.EndCombo()
    end
    ImGui.PopItemWidth()

    if currentRule ~= "Keep" then
        ImGui.SameLine()
        ImGui.Text("Threshold:")
        ImGui.SameLine()
        ImGui.PushItemWidth(70)
        local newThres, thChanged = ImGui.InputInt("##WLAddThreshold", state.addThreshold or 1)
        if thChanged then state.addThreshold = math.max(1, newThres) end
        ImGui.PopItemWidth()
    end

    ImGui.SameLine()
    if ImGui.Button("Add") then
        local itemName = (state.addItemName or ""):match("^%s*(.-)%s*$")
        if itemName ~= "" then
            local rule = currentRule
            if rule == "KeepIfFewerThan" then
                rule = string.format("KeepIfFewerThan:%d", state.addThreshold or 1)
            end
            -- Save as name-based rule so it applies even if itemID unknown yet
            local ok = database.saveNameBasedRuleFor(toonName, itemName, rule)
            if ok then
                util.printSmartLoot(string.format("Whitelisted '%s' with rule %s for %s", itemName, rule, toonName), "success")
                state.addItemName = ""
                state.entries = nil -- force refresh
            else
                util.printSmartLoot("Failed to add whitelist rule (check logs)", "error")
            end
        end
    end

    ImGui.SameLine()
    if ImGui.Button("Close") then
        lootUI.whitelistManagerPopup.isOpen = false
        ImGui.End()
        return
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Filter/search
    ImGui.Text("Filter:")
    ImGui.SameLine()
    ImGui.PushItemWidth(240)
    local newFilter, fChanged = ImGui.InputText("##WLFilter", state.filter or "", 120)
    if fChanged then state.filter = newFilter end
    ImGui.PopItemWidth()

    ImGui.SameLine()
    if ImGui.Button("Refresh") then
        state.entries = nil
    end

    ImGui.Spacing()

    -- Load entries lazily
    if not state.entries then
        local all = database.getAllLootRules()
        local list = {}
        for key, data in pairs(all or {}) do
            local rule = tostring(data.rule or "")
            if rule == "Keep" or rule:find("KeepIfFewerThan") then
                table.insert(list, {
                    item_name = data.item_name or key,
                    item_id = tonumber(data.item_id) or 0,
                    icon_id = tonumber(data.icon_id) or 0,
                    rule = rule,
                    is_name_fallback = (tonumber(data.item_id) or 0) == 0,
                })
            end
        end
        table.sort(list, function(a,b) return tostring(a.item_name) < tostring(b.item_name) end)
        state.entries = list
    end

    local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollY)
    if ImGui.BeginTable("SL_WhitelistTable", 4, flags) then
        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 150)
        ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 220)
        ImGui.TableHeadersRow()

        local filter = (state.filter or ""):lower()
        for _, row in ipairs(state.entries or {}) do
            if filter == "" or tostring(row.item_name):lower():find(filter, 1, true) then
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                uiUtils.drawItemIcon(row.icon_id or 0)
                ImGui.TableSetColumnIndex(1)
                ImGui.Text(row.item_name or "")
                ImGui.TableSetColumnIndex(2)
                ImGui.Text(row.rule or "")
                ImGui.TableSetColumnIndex(3)
                ImGui.PushID(row.item_name .. (row.item_id or 0))
                if ImGui.Button("Set Ignore") then
                    if row.item_id and row.item_id > 0 then
                        database.saveLootRuleFor(toonName, row.item_name, row.item_id, "Ignore", row.icon_id or 0)
                    else
                        database.saveNameBasedRuleFor(toonName, row.item_name, "Ignore")
                    end
                    state.entries = nil
                end
                ImGui.SameLine()
                if ImGui.Button("Delete Rule") then
                    if row.item_id and row.item_id > 0 then
                        database.deleteLootRuleFor(toonName, row.item_id)
                    else
                        database.deleteNameBasedRuleFor(toonName, row.item_name)
                    end
                    state.entries = nil
                end
                ImGui.PopID()
            end
        end

        ImGui.EndTable()
    else
        ImGui.Text("No whitelist entries.")
    end

    ImGui.End()
end

function uiPopups.drawUnknownItemsReviewPopup(lootUI, databaseRef, utilRef)
    local popup = lootUI.unknownItemsReviewPopup
    if not popup or not popup.isOpen then return end

    popup.ruleSelections = popup.ruleSelections or {}
    popup.ruleThresholds = popup.ruleThresholds or {}

    local items = SmartLootEngine.getUnknownReviewItems and SmartLootEngine.getUnknownReviewItems() or {}
    if #items == 0 then
        popup.isOpen = false
        return
    end

    ImGui.SetNextWindowSize(1180, 540, ImGuiCond.FirstUseEver)
    local open = ImGui.Begin("SmartLoot - Unknown Item Batch Review", true)
    if not open then
        popup.isOpen = false
        SmartLootEngine.cancelUnknownReview()
        ImGui.End()
        return
    end

    ImGui.TextWrapped("SmartLoot finished scanning nearby corpses. Review rules for unknown items below, including vendor plat value and tribute value, then replay only the items whose new local rule keeps them.")
    ImGui.Separator()

    local localToon = mq.TLO.Me.Name() or "unknown"
    local unresolvedLocal = 0
    local deferredActionLayout = config.getDeferredReviewActionLayout and config.getDeferredReviewActionLayout(localToon) or
        "selector"
    local deferredQuickButtons = config.getDeferredReviewQuickButtons and config.getDeferredReviewQuickButtons(localToon) or {
        allKeep = true,
        allIgnore = true,
        meKeep = true,
        meIgnore = true,
    }
    local flags = bit32.bor(
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.SizingStretchProp
    )

    if ImGui.BeginTable("SL_UnknownItemsReview", 8, flags, 0, 360) then
        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 34)
        ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch, 2.2)
        ImGui.TableSetupColumn("Corpses", ImGuiTableColumnFlags.WidthStretch, 1.8)
        ImGui.TableSetupColumn("Seen", ImGuiTableColumnFlags.WidthFixed, 42)
        ImGui.TableSetupColumn("Vendor", ImGuiTableColumnFlags.WidthFixed, 78)
        ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.WidthFixed, 72)
        ImGui.TableSetupColumn("Local Rule", ImGuiTableColumnFlags.WidthFixed, 132)
        ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthStretch, 2.5)
        ImGui.TableHeadersRow()

        for _, item in ipairs(items) do
            local key = item.key or item.itemName
            local localRule = databaseRef.getLootRule(item.itemName, true, item.itemID)
            if not localRule or localRule == "" or localRule == "Unset" then
                unresolvedLocal = unresolvedLocal + 1
            end

            popup.ruleSelections[key] = popup.ruleSelections[key] or
                (config.getDefaultPromptDropdown and config.getDefaultPromptDropdown(localToon) or "Keep")
            popup.ruleThresholds[key] = popup.ruleThresholds[key] or 1

            local corpseSummary = "Unknown corpse"
            if item.corpseRefs and #item.corpseRefs > 0 then
                corpseSummary = item.corpseRefs[1].corpseName or "Unknown corpse"
                if #item.corpseRefs > 1 then
                    corpseSummary = string.format("%s (+%d more)", corpseSummary, #item.corpseRefs - 1)
                end
            end

            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0)
            uiUtils.drawItemIcon(item.iconID or 0)

            ImGui.TableSetColumnIndex(1)
            ImGui.Text(item.itemName or "")
            ImGui.TextDisabled("ID: %d", tonumber(item.itemID) or 0)

            ImGui.TableSetColumnIndex(2)
            ImGui.TextWrapped(corpseSummary)

            ImGui.TableSetColumnIndex(3)
            ImGui.Text(tostring(item.occurrenceCount or #(item.corpseRefs or {})))

            ImGui.TableSetColumnIndex(4)
            ImGui.Text(formatCopperValue(item.itemValue or 0))

            ImGui.TableSetColumnIndex(5)
            ImGui.Text(tostring(item.tributeValue or 0))

            ImGui.TableSetColumnIndex(6)
            local localRuleLabel = getRuleLabel(localRule)
            if localRule and localRule ~= "" and localRule ~= "Unset" then
                ImGui.TextColored(0.55, 0.9, 0.55, 1.0, localRuleLabel)
            else
                ImGui.TextColored(0.95, 0.75, 0.35, 1.0, "Unset")
            end

            ImGui.TableSetColumnIndex(7)
            local function applyLocalRule(rule)
                if saveUnknownReviewRule(item, localToon, rule) then
                    popup.lastStatus = string.format("Saved %s locally for %s", getRuleLabel(rule), item.itemName)
                end
            end

            local function applyAllRule(rule)
                local successCount = applyUnknownReviewRuleToAll(item, rule, utilRef)
                popup.lastStatus = string.format("Saved %s for %d character(s) on %s",
                    getRuleLabel(rule), successCount, item.itemName)
            end

            if deferredActionLayout == "quick_buttons" then
                local drewButton = false
                if deferredQuickButtons.meKeep then
                    if drewButton then ImGui.SameLine() end
                    if ImGui.SmallButton("Me Keep##Unknown_" .. key) then
                        applyLocalRule("Keep")
                    end
                    drewButton = true
                end
                if deferredQuickButtons.meIgnore then
                    if drewButton then ImGui.SameLine() end
                    if ImGui.SmallButton("Me Ignore##Unknown_" .. key) then
                        applyLocalRule("Ignore")
                    end
                    drewButton = true
                end
                if deferredQuickButtons.allKeep then
                    if drewButton then ImGui.SameLine() end
                    if ImGui.SmallButton("All Keep##Unknown_" .. key) then
                        applyAllRule("Keep")
                    end
                    drewButton = true
                end
                if deferredQuickButtons.allIgnore then
                    if drewButton then ImGui.SameLine() end
                    if ImGui.SmallButton("All Ignore##Unknown_" .. key) then
                        applyAllRule("Ignore")
                    end
                end

                ImGui.SameLine()
                if ImGui.SmallButton("Peers##Unknown_" .. key) then
                    lootUI.peerItemRulesPopup = lootUI.peerItemRulesPopup or {}
                    lootUI.peerItemRulesPopup.isOpen = true
                    lootUI.peerItemRulesPopup.itemName = item.itemName
                    lootUI.peerItemRulesPopup.itemID = item.itemID or 0
                    lootUI.peerItemRulesPopup.iconID = item.iconID or 0
                end
            else
                ImGui.SetNextItemWidth(118)
                if ImGui.BeginCombo("##UnknownRule_" .. key, popup.ruleSelections[key]) then
                    for _, option in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}) do
                        local isSelected = popup.ruleSelections[key] == option
                        if ImGui.Selectable(option, isSelected) then
                            popup.ruleSelections[key] = option
                        end
                        if isSelected then ImGui.SetItemDefaultFocus() end
                    end
                    ImGui.EndCombo()
                end

                if popup.ruleSelections[key] == "KeepIfFewerThan" or popup.ruleSelections[key] == "KeepThenIgnore" then
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(50)
                    local newThreshold, changed = ImGui.InputInt("##UnknownThreshold_" .. key, popup.ruleThresholds[key], 0, 0)
                    if changed then
                        popup.ruleThresholds[key] = math.max(1, newThreshold)
                    end
                end

                local finalRule = getFinalRuleForSelection(popup.ruleSelections[key], popup.ruleThresholds[key])

                ImGui.SameLine()
                if ImGui.SmallButton("Me##Unknown_" .. key) then
                    applyLocalRule(finalRule)
                end

                ImGui.SameLine()
                if ImGui.SmallButton("All##Unknown_" .. key) then
                    applyAllRule(finalRule)
                end

                ImGui.SameLine()
                if ImGui.SmallButton("Peers##Unknown_" .. key) then
                    lootUI.peerItemRulesPopup = lootUI.peerItemRulesPopup or {}
                    lootUI.peerItemRulesPopup.isOpen = true
                    lootUI.peerItemRulesPopup.itemName = item.itemName
                    lootUI.peerItemRulesPopup.itemID = item.itemID or 0
                    lootUI.peerItemRulesPopup.iconID = item.iconID or 0
                end
            end
        end

        ImGui.EndTable()
    end

    ImGui.Separator()
    ImGui.Text("Items awaiting local rule: %d", unresolvedLocal)
    if popup.lastStatus and popup.lastStatus ~= "" then
        ImGui.SameLine()
        ImGui.TextColored(0.6, 0.85, 1.0, 1.0, popup.lastStatus)
    end

    if ImGui.Button("Loot Newly Kept Items", 200, 28) then
        SmartLootEngine.completeUnknownReview()
    end

    ImGui.SameLine()
    if ImGui.Button("Skip Review", 140, 28) then
        SmartLootEngine.cancelUnknownReview()
    end

    ImGui.End()
end


-- Loot Decision Popup - REDESIGNED with better layout and consistent button sizing
function uiPopups.drawLootDecisionPopup(lootUI, settings, loot)
    if lootUI.currentItem then
    local decisionKey = string.format("%s:%d:%s",
        tostring(lootUI.currentItem.name or ""),
        tonumber(lootUI.currentItem.itemID or 0),
        tostring(lootUI.currentItem.index or 0))

    if lootUI.pendingDecisionWindowKey ~= decisionKey then
        lootUI.pendingDecisionWindowKey = decisionKey
        lootUI.pendingDecisionWindowNeedsAttention = true
    end

    if lootUI.pendingDecisionWindowNeedsAttention then
        local io = ImGui.GetIO()
        if io and io.DisplaySize then
            ImGui.SetNextWindowPos(io.DisplaySize.x * 0.5, io.DisplaySize.y * 0.3, ImGuiCond.Always, 0.5, 0.0)
        end
        if ImGui.SetNextWindowCollapsed then
            ImGui.SetNextWindowCollapsed(false, ImGuiCond.Always)
        end
        if ImGui.SetNextWindowFocus then
            ImGui.SetNextWindowFocus()
        end
    end

    ImGui.SetNextWindowSize(520, 380, ImGuiCond.FirstUseEver)
    local decisionOpen = ImGui.Begin("SmartLoot - Loot Decision", true)
        if decisionOpen then
            lootUI.pendingDecisionWindowNeedsAttention = false
            -- Get current item info
            local itemName = lootUI.currentItem.name
            local itemID = lootUI.currentItem.itemID or 0
            local iconID = lootUI.currentItem.iconID or 0
            
            -- Get item value from corpse (in copper)
            local itemValue = 0
            local tributeValue = lootUI.currentItem.tributeValue or 0
            local itemIndex = lootUI.currentItem.index
            if itemIndex then
                local corpseItem = mq.TLO.Corpse.Item(itemIndex)
                if corpseItem and corpseItem() then
                    itemValue = corpseItem.Value() or 0
                    tributeValue = corpseItem.Tribute() or tributeValue
                end
            end
            
            -- Convert copper to platinum display (1000 copper = 1 platinum)
            local platValue = math.floor(itemValue / 1000)
            local goldValue = math.floor((itemValue % 1000) / 100)
            local silverValue = math.floor((itemValue % 100) / 10)
            local copperValue = itemValue % 10
            
            -- Build value string
            local valueStr = ""
            if platValue > 0 then
                valueStr = string.format("%dp", platValue)
                if goldValue > 0 then valueStr = valueStr .. string.format(" %dg", goldValue) end
            elseif goldValue > 0 then
                valueStr = string.format("%dg", goldValue)
                if silverValue > 0 then valueStr = valueStr .. string.format(" %ds", silverValue) end
            elseif silverValue > 0 then
                valueStr = string.format("%ds", silverValue)
                if copperValue > 0 then valueStr = valueStr .. string.format(" %dc", copperValue) end
            elseif copperValue > 0 then
                valueStr = string.format("%dc", copperValue)
            else
                valueStr = "0c"
            end
            
            -- Compact header row with icon + info
            local uiUtils = require("smartloot.ui.ui_utils")
            local iconSize = 42
            ImGui.BeginGroup()
            uiUtils.drawItemIcon(iconID or 0, iconSize, iconSize)
            ImGui.EndGroup()
            ImGui.SameLine()
            ImGui.BeginGroup()
            ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 0.6, 1)
            local itemLabel = itemName .. "##pendingItemLink"
            if ImGui.Selectable(itemLabel, false, ImGuiSelectableFlags.DontClosePopups) and itemIndex then
                pcall(function()
                    local corpseItem = mq.TLO.Corpse.Item(itemIndex)
                    if corpseItem and corpseItem() then
                        local itemLink = corpseItem.ItemLink()
                        if itemLink and itemLink ~= "" and itemLink ~= "NULL" then
                            local wrappedLink = string.format("\x12%s\x12", itemLink)
                            local links = mq.ExtractLinks(wrappedLink)
                            if links and #links > 0 then
                                mq.ExecuteTextLink(links[1])
                            else
                                links = mq.ExtractLinks(itemLink)
                                if links and #links > 0 then
                                    mq.ExecuteTextLink(links[1])
                                end
                            end
                        end
                    end
                end)
            end
            ImGui.PopStyleColor()
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Click to inspect item")
            end
            ImGui.TextDisabled("Item ID: %d", itemID)
            ImGui.SameLine()
            ImGui.TextDisabled("Corpse Slot: %s", tostring(itemIndex or "?"))
            local config = require("modules.config")
            local toonName = mq.TLO.Me.Name() or "unknown"
            local showTribute = config.isShowPendingDecisionTribute and config.isShowPendingDecisionTribute(toonName) or true
            ImGui.Text("Value:")
            ImGui.SameLine()
            local valueColor = {0.6, 0.4, 0.3, 1}
            if platValue > 0 then valueColor = {0.9, 0.85, 0.4, 1}
            elseif goldValue > 0 then valueColor = {0.9, 0.7, 0.3, 1}
            elseif silverValue > 0 then valueColor = {0.7, 0.7, 0.7, 1} end
            ImGui.TextColored(valueColor[1], valueColor[2], valueColor[3], valueColor[4], valueStr)
            if showTribute then
                ImGui.SameLine()
                ImGui.TextDisabled("|")
                ImGui.SameLine()
                ImGui.Text("Tribute:")
                ImGui.SameLine()
                ImGui.TextColored(0.7, 0.9, 1.0, 1.0, tostring(tributeValue or 0))
            end
            ImGui.EndGroup()
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()

            -- Quick pause/resume controls for this decision
            ImGui.Text("Processing control:")
            ImGui.SameLine()
            ImGui.TextDisabled("Pause SmartLoot while you decide")

            local pauseActive = lootUI.pendingDecisionPauseActive
            local pauseLabel = pauseActive and "Resume" or "Pause"
            local pauseColor = pauseActive and {0.2, 0.7, 0.2, 0.9} or {0.8, 0.3, 0.3, 0.9}
            local pauseHoverColor = pauseActive and {0.3, 0.8, 0.3, 1.0} or {0.9, 0.4, 0.4, 1.0}
            local pauseActiveColor = pauseActive and {0.1, 0.5, 0.1, 1.0} or {0.7, 0.2, 0.2, 1.0}

            ImGui.PushStyleColor(ImGuiCol.Button, pauseColor[1], pauseColor[2], pauseColor[3], pauseColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, pauseHoverColor[1], pauseHoverColor[2], pauseHoverColor[3], pauseHoverColor[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, pauseActiveColor[1], pauseActiveColor[2], pauseActiveColor[3], pauseActiveColor[4])

            if ImGui.Button(pauseLabel .. "##PendingDecisionPause", 80, 22) then
                if pauseActive then
                    if lootUI.resumeEngineAfterPendingDecision then
                        lootUI.resumeEngineAfterPendingDecision("Manual resume from pending decision window")
                    end
                else
                    if lootUI.pauseEngineForPendingDecision then
                        lootUI.pauseEngineForPendingDecision()
                    end
                end
            end

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(pauseActive and "Resume SmartLoot processing" or "Pause SmartLoot until you're ready")
            end
            ImGui.PopStyleColor(3)

            if pauseActive then
                ImGui.SameLine()
                ImGui.TextColored(1.0, 0.9, 0.4, 1.0, "Processing Paused")
            else
                ImGui.SameLine()
                ImGui.TextColored(0.7, 0.9, 0.7, 1.0, "Looting")
            end

            ImGui.Spacing()
            
            -- Rule selection section
            ImGui.Text("Select rule to apply:")
            ImGui.Separator()
            
            -- Initialize selected rule state
            -- Load default from config, with validation and fallback to "Keep"
            if not lootUI.pendingDecisionRule then
                local config = require("modules.config")
                local toonName = mq.TLO.Me.Name() or "unknown"
                local selection = "Keep"  -- default fallback
                if config.getDefaultPromptDropdown then
                    selection = config.getDefaultPromptDropdown(toonName)
                end
                -- Validate it's a known rule
                local validRules = {"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}
                local isValid = false
                for _, rule in ipairs(validRules) do
                    if selection == rule then
                        isValid = true
                        break
                    end
                end
                lootUI.pendingDecisionRule = isValid and selection or "Keep"
            end
            lootUI.pendingThreshold = lootUI.pendingThreshold or 1
            
            -- Rule selection (dropdown or buttons based on config)
            local toonName = mq.TLO.Me.Name() or "unknown"
            local useButtons = config.isUsePendingDecisionButtons and config.isUsePendingDecisionButtons(toonName) or false
            local actionLayout = config.getPendingDecisionActionLayout and config.getPendingDecisionActionLayout(toonName) or "selector"
            local quickButtons = config.getPendingDecisionQuickButtons and config.getPendingDecisionQuickButtons(toonName) or {
                allKeep = true,
                allIgnore = true,
                meKeep = true,
                meIgnore = true,
            }

            if useButtons then
                -- Button mode: row of small buttons
                local buttonRules = {
                    {rule = "Keep", label = "Keep", width = 45},
                    {rule = "Ignore", label = "Ignore", width = 45},
                    {rule = "Destroy", label = "Destroy", width = 50},
                    {rule = "KeepIfFewerThan", label = "K<N", width = 35},
                    {rule = "KeepThenIgnore", label = "KTI", width = 35}
                }
                for bi, btn in ipairs(buttonRules) do
                    if bi > 1 then ImGui.SameLine() end
                    local isSelected = (lootUI.pendingDecisionRule == btn.rule)
                    if isSelected then
                        ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 1.0)
                    end
                    if ImGui.Button(btn.label .. "##pendingBtn_" .. bi, btn.width, 0) then
                        lootUI.pendingDecisionRule = btn.rule
                    end
                    if isSelected then
                        ImGui.PopStyleColor()
                    end
                    if ImGui.IsItemHovered() then
                        ImGui.SetTooltip(btn.rule)
                    end
                end
            else
                -- Dropdown mode (default)
                ImGui.SetNextItemWidth(180)
                if ImGui.BeginCombo("##pendingRule", lootUI.pendingDecisionRule) then
                    for _, rule in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}) do
                        local isSelected = (lootUI.pendingDecisionRule == rule)
                        if ImGui.Selectable(rule, isSelected) then
                            lootUI.pendingDecisionRule = rule
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                    ImGui.EndCombo()
                end
            end
            
            -- Threshold input for KeepIfFewerThan
            if lootUI.pendingDecisionRule == "KeepIfFewerThan" or lootUI.pendingDecisionRule == "KeepThenIgnore" then
                ImGui.SameLine()
                ImGui.Text("Threshold:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(80)
                local newThreshold, changedThreshold = ImGui.InputInt("##pendingThreshold", lootUI.pendingThreshold)
                if changedThreshold then
                    lootUI.pendingThreshold = math.max(1, newThreshold)
                end
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Helper function to build final rule string
            local function getFinalRule()
                if lootUI.pendingDecisionRule == "KeepIfFewerThan" then
                    return "KeepIfFewerThan:" .. lootUI.pendingThreshold
                elseif lootUI.pendingDecisionRule == "KeepThenIgnore" then
                    return "KeepIfFewerThan:" .. lootUI.pendingThreshold .. ":AutoIgnore"
                else
                    return lootUI.pendingDecisionRule
                end
            end

            local function getRuleDisplayLabel()
                if lootUI.pendingDecisionRule == "KeepIfFewerThan" then
                    return string.format("Keep if < %d", lootUI.pendingThreshold or 1)
                elseif lootUI.pendingDecisionRule == "KeepThenIgnore" then
                    return string.format("Keep if < %d then Ignore", lootUI.pendingThreshold or 1)
                else
                    return lootUI.pendingDecisionRule or "Keep"
                end
            end

            local currentRuleLabel = getRuleDisplayLabel()

            ImGui.Spacing()
            if actionLayout == "selector" then
                ImGui.TextColored(0.9, 0.9, 0.6, 1.0, "Selected rule: %s", currentRuleLabel)
                ImGui.SameLine()
                ImGui.TextDisabled("(Click the buttons above to change)")
            else
                ImGui.TextColored(0.9, 0.9, 0.6, 1.0, "Quick action mode")
                ImGui.SameLine()
                ImGui.TextDisabled("(Configured in Settings)")
            end
            
            -- Helper function to apply rule and queue loot action
            local function applyRuleAndQueue(rule, skipAction)
                local itemID_from_current = lootUI.currentItem.itemID or 0
                local iconID_from_current = lootUI.currentItem.iconID or 0
                
                -- Save the rule locally
                database.saveLootRule(itemName, itemID_from_current, rule, iconID_from_current)
                
                -- Refresh local cache after saving rule
                database.refreshLootRuleCache()
                
                if not skipAction then
                    -- Queue the loot action
                    lootUI.pendingLootAction = {
                        item = lootUI.currentItem,
                        itemID = itemID_from_current,
                        iconID = iconID_from_current,
                        rule = rule,
                        numericCorpseID = lootUI.currentItem.numericCorpseID,
                        startTime = lootUI.currentItem.decisionStartTime
                    }
                end
                
                -- Clear currentItem for immediate processing
                lootUI.currentItem = nil
                lootUI.pendingDecisionWindowKey = nil
                lootUI.pendingDecisionWindowNeedsAttention = false
                lootUI.pendingDecisionRule = nil
                lootUI.pendingThreshold = 1
            end

            local function applyRuleToAllPeers(rule)
                local connectedPeers = util.getConnectedPeers()
                local currentCharacter = mq.TLO.Me.Name()
                local itemID_from_current = lootUI.currentItem.itemID or 0
                local iconID_from_current = lootUI.currentItem.iconID or 0

                logging.debug(string.format("[Popup] Apply All: itemName=%s, itemID=%d, iconID=%d",
                    itemName, itemID_from_current, iconID_from_current))

                local appliedCount = 0
                for _, peer in ipairs(connectedPeers) do
                    if peer ~= currentCharacter and database.saveLootRuleFor then
                        local success = database.saveLootRuleFor(peer, itemName, itemID_from_current, rule, iconID_from_current)
                        if success then
                            appliedCount = appliedCount + 1
                            util.sendPeerCommandViaActor(peer, "reload_rules")
                        end
                    end
                end

                logging.log(string.format("Applied rule '%s' for '%s' to %d connected peers", rule, itemName, appliedCount))
                database.refreshLootRuleCache()
                applyRuleAndQueue(rule)
            end
            
            -- Main action buttons - compact layout
            local buttonHeight = 22
            local roundingRadius = 5
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, roundingRadius)
            local style = ImGui.GetStyle()
            local spacing = style.ItemSpacing.x
            local primaryWidth = 100
            local function drawActionButton(label, width, colors, onClick, tooltip)
                ImGui.PushStyleColor(ImGuiCol.Button, colors[1], colors[2], colors[3], colors[4])
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, colors[5], colors[6], colors[7], colors[8])
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, colors[9], colors[10], colors[11], colors[12])
                if ImGui.Button(label, width, buttonHeight) then
                    onClick()
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip(tooltip)
                end
                ImGui.PopStyleColor(3)
            end

            if actionLayout == "quick_buttons" then
                local quickActionButtons = {
                    {
                        enabled = quickButtons.allKeep,
                        label = "All Keep",
                        width = 90,
                        colors = {0.2, 0.7, 0.2, 0.95, 0.3, 0.8, 0.3, 1.0, 0.1, 0.5, 0.1, 1.0},
                        onClick = function()
                            applyRuleToAllPeers("Keep")
                        end,
                        tooltip = "Apply Keep to every connected peer and resolve the item",
                    },
                    {
                        enabled = quickButtons.allIgnore,
                        label = "All Ignore",
                        width = 92,
                        colors = {0.75, 0.55, 0.2, 0.95, 0.85, 0.65, 0.3, 1.0, 0.6, 0.45, 0.1, 1.0},
                        onClick = function()
                            applyRuleToAllPeers("Ignore")
                        end,
                        tooltip = "Apply Ignore to every connected peer and resolve the item",
                    },
                    {
                        enabled = quickButtons.meKeep,
                        label = "Me Keep",
                        width = 88,
                        colors = {0.2, 0.5, 0.8, 0.95, 0.3, 0.6, 0.9, 1.0, 0.1, 0.4, 0.7, 1.0},
                        onClick = function()
                            logging.log(string.format("Setting rule '%s' for '%s' locally only and processing", "Keep", itemName))
                            applyRuleAndQueue("Keep", false)
                        end,
                        tooltip = "Apply Keep locally and resolve immediately",
                    },
                    {
                        enabled = quickButtons.meIgnore,
                        label = "Me Ignore",
                        width = 92,
                        colors = {0.55, 0.45, 0.75, 0.95, 0.65, 0.55, 0.85, 1.0, 0.45, 0.35, 0.65, 1.0},
                        onClick = function()
                            logging.log(string.format("Setting rule '%s' for '%s' locally only and processing", "Ignore", itemName))
                            applyRuleAndQueue("Ignore", false)
                        end,
                        tooltip = "Apply Ignore locally and resolve immediately",
                    },
                }

                local drewButton = false
                for _, button in ipairs(quickActionButtons) do
                    if button.enabled then
                        if drewButton then
                            ImGui.SameLine(0, spacing)
                        end
                        drawActionButton(button.label, button.width, button.colors, button.onClick, button.tooltip)
                        drewButton = true
                    end
                end

                if not drewButton then
                    drawActionButton("Me Keep", 88,
                        {0.2, 0.5, 0.8, 0.95, 0.3, 0.6, 0.9, 1.0, 0.1, 0.4, 0.7, 1.0},
                        function()
                            logging.log(string.format("Setting rule '%s' for '%s' locally only and processing", "Keep", itemName))
                            applyRuleAndQueue("Keep", false)
                        end,
                        "Apply Keep locally and resolve immediately")
                end
            else
                local applyAllLabel = string.format("All (%s)", currentRuleLabel)
                drawActionButton(applyAllLabel, primaryWidth,
                    {0.2, 0.7, 0.2, 0.95, 0.3, 0.8, 0.3, 1.0, 0.1, 0.5, 0.1, 1.0},
                    function()
                        applyRuleToAllPeers(getFinalRule())
                    end,
                    "Apply selected rule to every connected peer and resolve the item")

                ImGui.SameLine(0, spacing)

                local applyMeLabel = string.format("Me (%s)", currentRuleLabel)
                drawActionButton(applyMeLabel, primaryWidth,
                    {0.2, 0.5, 0.8, 0.95, 0.3, 0.6, 0.9, 1.0, 0.1, 0.4, 0.7, 1.0},
                    function()
                        local rule = getFinalRule()
                        logging.log(string.format("Setting rule '%s' for '%s' locally only and processing", rule, itemName))
                        applyRuleAndQueue(rule, false)
                    end,
                    "Apply selected rule locally and resolve immediately")
            end

            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()

            -- Advanced options section
            ImGui.Text("Advanced Options:")
            ImGui.Spacing()
            
            local advancedWidth = 80

            ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.4, 0.8, 0.85)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.5, 0.9, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.3, 0.7, 1.0)
            if ImGui.Button("Peers", advancedWidth, buttonHeight) then
                lootUI.peerItemRulesPopup = lootUI.peerItemRulesPopup or {}
                lootUI.peerItemRulesPopup.isOpen = true
                lootUI.peerItemRulesPopup.itemName = itemName
                lootUI.peerItemRulesPopup.itemID = lootUI.currentItem.itemID or 0
                lootUI.peerItemRulesPopup.iconID = lootUI.currentItem.iconID or 0
                logging.log(string.format("Opening peer rule editor for item: %s (itemID=%d, iconID=%d)",
                    itemName, lootUI.currentItem.itemID or 0, lootUI.currentItem.iconID or 0))
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Configure rules individually per character")
            end
            ImGui.PopStyleColor(3)

            ImGui.SameLine(0, spacing)

            ImGui.PushStyleColor(ImGuiCol.Button, 0.8, 0.6, 0.2, 0.85)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.9, 0.7, 0.3, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.7, 0.5, 0.1, 1.0)
            if ImGui.Button("Ignore", advancedWidth, buttonHeight) then
                local rule = "Ignore"
                logging.log(string.format("Processing '%s' as ignored - will trigger peer chain", itemName))
                applyRuleAndQueue(rule, false)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Resolve this item as ignored and continue chain")
            end
            ImGui.PopStyleColor(3)

            ImGui.SameLine(0, spacing)

            ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.55, 0.55, 0.85)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.65, 0.65, 0.65, 1.0)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.4, 0.4, 1.0)
            if ImGui.Button("Skip", advancedWidth, buttonHeight) then
                logging.log("Skipping item " .. itemName .. " - leaving rule unset, moving to next item")
                local itemID_from_current = lootUI.currentItem.itemID or 0
                local iconID_from_current = lootUI.currentItem.iconID or 0
                lootUI.pendingLootAction = {
                    item = lootUI.currentItem,
                    itemID = itemID_from_current,
                    iconID = iconID_from_current,
                    rule = "Ignore",
                    numericCorpseID = lootUI.currentItem.numericCorpseID,
                    startTime = lootUI.currentItem.decisionStartTime,
                    skipRuleSave = true
                }
                lootUI.currentItem = nil
                lootUI.pendingDecisionWindowKey = nil
                lootUI.pendingDecisionWindowNeedsAttention = false
                lootUI.pendingDecisionRule = nil
                lootUI.pendingThreshold = 1
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Skip without setting any rule (temporary ignore)")
            end
            ImGui.PopStyleColor(3)

            -- Pop the rounding style at the very end, after all buttons
            ImGui.PopStyleVar()

            ImGui.Spacing()
            ImGui.Separator()
            
        end
        ImGui.End()
        
        -- If window was closed, clean up state
        if not decisionOpen then
            lootUI.currentItem = nil
            lootUI.pendingDecisionWindowKey = nil
            lootUI.pendingDecisionWindowNeedsAttention = false
            lootUI.pendingDecisionRule = nil
            lootUI.pendingThreshold = 1
        end
    end
end

-- Peer Item Rules Popup (ENHANCED with better workflow integration)
function uiPopups.drawPeerItemRulesPopup(lootUI, database, util)
    if lootUI.peerItemRulesPopup and lootUI.peerItemRulesPopup.isOpen then
        local windowTitle = "SmartLoot - Peer Rules Manager"
        
        logging.debug(string.format("[PeerRulesPopup] Opened for: %s (itemID=%d, iconID=%d)", 
            lootUI.peerItemRulesPopup.itemName or "Unknown", 
            lootUI.peerItemRulesPopup.itemID or 0, 
            lootUI.peerItemRulesPopup.iconID or 0))
        
        -- Clear states if item changed
        if lootUI.peerItemRulesPopup.lastItemName and 
           lootUI.peerItemRulesPopup.lastItemName ~= lootUI.peerItemRulesPopup.itemName then
            lootUI.peerItemRulesPopup.peerStates = {}
        end
        lootUI.peerItemRulesPopup.lastItemName = lootUI.peerItemRulesPopup.itemName
        
        -- Clear recentlyChanged flags after a delay to allow database to update
        if lootUI.peerItemRulesPopup.peerStates then
            local currentTime = mq.gettime()
            for peer, peerState in pairs(lootUI.peerItemRulesPopup.peerStates) do
                if peerState.recentlyChanged and peerState.changeTime and 
                   (currentTime - peerState.changeTime) > 2000 then -- 2 second delay
                    peerState.recentlyChanged = false
                    peerState.changeTime = nil
                end
            end
        end
        
        ImGui.SetNextWindowSize(500, 400, ImGuiCond.FirstUseEver)
        local keepOpen = true
        local open, p_open = ImGui.Begin(windowTitle, true)
        if open then
            ImGui.Text("Configure rules for '" .. (lootUI.peerItemRulesPopup.itemName or "") .. "' across all peers.")
            ImGui.Separator()

            -- Build peer list outside of table scope so it's available for buttons
            local peerList = {}
            local currentCharacter = mq.TLO.Me.Name()
            if currentCharacter then
                table.insert(peerList, currentCharacter)
            end

            -- Add connected peers
            local connectedPeers = util.getConnectedPeers()
            local connectedPeerSet = {}
            for _, peer in ipairs(connectedPeers) do
                connectedPeerSet[peer] = true
                if peer ~= currentCharacter then
                    table.insert(peerList, peer)
                end
            end

            -- Add other characters that have rules in database
            local allCharacters = database.getAllCharactersWithRules()
            logging.debug(string.format("[PeerRules] getAllCharactersWithRules returned: %s", 
                                      table.concat(allCharacters or {}, ", ")))
            
            for _, charName in ipairs(allCharacters) do
                if charName ~= currentCharacter then
                    local alreadyAdded = false
                    for _, existingPeer in ipairs(peerList) do
                        if existingPeer == charName then
                            alreadyAdded = true
                            break
                        end
                    end
                    if not alreadyAdded then
                        table.insert(peerList, charName)
                        logging.debug(string.format("[PeerRules] Added character from DB: %s", charName))
                    end
                end
            end

            -- Sort peer list alphabetically, keeping current character first
            table.sort(peerList, function(a, b)
                if a == currentCharacter then return true end
                if b == currentCharacter then return false end
                return a < b
            end)
            
            logging.debug(string.format("[PeerRules] Final peer list: %s", table.concat(peerList, ", ")))

            lootUI.peerItemRulesPopup.bulkRule = lootUI.peerItemRulesPopup.bulkRule or "Keep"
            lootUI.peerItemRulesPopup.bulkThreshold = math.max(1, tonumber(lootUI.peerItemRulesPopup.bulkThreshold) or 1)
            lootUI.peerItemRulesPopup.bulkTarget = lootUI.peerItemRulesPopup.bulkTarget or "all"

            ImGui.Text("Bulk apply this item rule:")
            ImGui.SetNextItemWidth(170)
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            if ImGui.BeginCombo("##peerRulesBulkRule", lootUI.peerItemRulesPopup.bulkRule) then
                for _, option in ipairs({"Keep", "Ignore", "KeepIfFewerThan", "KeepThenIgnore", "Destroy", "Unset"}) do
                    local isSelected = (lootUI.peerItemRulesPopup.bulkRule == option)
                    local colorLabel = option == "KeepThenIgnore" and "KeepIfFewerThan" or option
                    local color = getRuleColor(colorLabel)
                    ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
                    if ImGui.Selectable(option, isSelected) then
                        lootUI.peerItemRulesPopup.bulkRule = option
                    end
                    ImGui.PopStyleColor()
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.PopStyleVar()

            local bulkRuleValue = getFinalRuleForSelection(lootUI.peerItemRulesPopup.bulkRule, lootUI.peerItemRulesPopup.bulkThreshold)
            if lootUI.peerItemRulesPopup.bulkRule == "Unset" then
                bulkRuleValue = ""
            end

            if lootUI.peerItemRulesPopup.bulkRule == "KeepIfFewerThan" or lootUI.peerItemRulesPopup.bulkRule == "KeepThenIgnore" then
                ImGui.SameLine()
                ImGui.SetNextItemWidth(90)
                ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
                local newBulkThreshold, thresholdChanged = ImGui.InputInt("##peerRulesBulkThreshold", lootUI.peerItemRulesPopup.bulkThreshold)
                ImGui.PopStyleVar()
                if thresholdChanged then
                    lootUI.peerItemRulesPopup.bulkThreshold = math.max(1, newBulkThreshold)
                end
                bulkRuleValue = getFinalRuleForSelection(lootUI.peerItemRulesPopup.bulkRule, lootUI.peerItemRulesPopup.bulkThreshold)
            end

            ImGui.SameLine()
            ImGui.Text("to")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(190)
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            if ImGui.BeginCombo("##peerRulesBulkTarget", getPeerRuleBulkTargetLabel(lootUI.peerItemRulesPopup.bulkTarget)) then
                for _, option in ipairs(PEER_RULE_BULK_TARGETS) do
                    local isSelected = (lootUI.peerItemRulesPopup.bulkTarget == option.key)
                    if ImGui.Selectable(option.label, isSelected) then
                        lootUI.peerItemRulesPopup.bulkTarget = option.key
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            ImGui.PopStyleVar()

            local matchingPeerCount = 0
            local unknownClassCount = 0
            for _, peer in ipairs(peerList) do
                local peerClassName = getPeerClassName(peer, currentCharacter, connectedPeerSet)
                if lootUI.peerItemRulesPopup.bulkTarget ~= "all" and not peerClassName then
                    unknownClassCount = unknownClassCount + 1
                elseif doesPeerMatchBulkTarget(peerClassName, lootUI.peerItemRulesPopup.bulkTarget) then
                    matchingPeerCount = matchingPeerCount + 1
                end
            end

            ImGui.SameLine()
            ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 8.0)
            if ImGui.Button("Apply") then
                local itemName = lootUI.peerItemRulesPopup.itemName or ""
                local itemID = lootUI.peerItemRulesPopup.itemID or 0
                local iconID = lootUI.peerItemRulesPopup.iconID or 0
                local updateCount = 0
                for _, peer in ipairs(peerList) do
                    local peerClassName = getPeerClassName(peer, currentCharacter, connectedPeerSet)
                    if doesPeerMatchBulkTarget(peerClassName, lootUI.peerItemRulesPopup.bulkTarget) then
                        if savePeerPopupRuleFor(peer, itemName, itemID, iconID, bulkRuleValue, currentCharacter, connectedPeerSet, lootUI.peerItemRulesPopup.tableSource) then
                            updateCount = updateCount + 1
                            if not lootUI.peerItemRulesPopup.peerStates then
                                lootUI.peerItemRulesPopup.peerStates = {}
                            end
                            lootUI.peerItemRulesPopup.peerStates[peer] = lootUI.peerItemRulesPopup.peerStates[peer] or {}
                            lootUI.peerItemRulesPopup.peerStates[peer].displayRule = (#bulkRuleValue > 0) and lootUI.peerItemRulesPopup.bulkRule or "Unset"
                            lootUI.peerItemRulesPopup.peerStates[peer].threshold = lootUI.peerItemRulesPopup.bulkThreshold
                            lootUI.peerItemRulesPopup.peerStates[peer].recentlyChanged = true
                            lootUI.peerItemRulesPopup.peerStates[peer].changeTime = mq.gettime()
                        end
                    end
                end
                logging.log(string.format("Applied '%s' to %d peers for %s", getRuleLabel(bulkRuleValue), updateCount, itemName))
            end
            ImGui.PopStyleVar()

            ImGui.SameLine()
            if ImGui.Button("Close") then
                keepOpen = false
            end

            ImGui.TextDisabled("Applies '%s' to %d peers.", getRuleLabel(bulkRuleValue), matchingPeerCount)
            if lootUI.peerItemRulesPopup.bulkTarget ~= "all" and unknownClassCount > 0 then
                ImGui.TextDisabled("%d peers skipped because class is unknown.", unknownClassCount)
            end

            ImGui.Separator()

            if ImGui.BeginTable("PeerItemRulesTable", 3, 
                ImGuiTableFlags.BordersInnerV + 
                ImGuiTableFlags.RowBg + 
                ImGuiTableFlags.Resizable) then
                
                ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()

                -- Initialize persistent state for peer rules if not exists
                if not lootUI.peerItemRulesPopup.peerStates then
                    lootUI.peerItemRulesPopup.peerStates = {}
                end

                for _, peer in ipairs(peerList) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    
                    if peer == currentCharacter then
                        -- Get current character's class
                        local myClass = mq.TLO.Me.Class.ShortName() or "Unknown"
                        ImGui.TextColored(0.2, 0.8, 0.2, 1, peer .. " (You - " .. myClass .. ")")
                    else
                        if connectedPeerSet[peer] then
                            -- Try to get peer's class information
                            local peerClass = mq.TLO.Spawn(peer).Class.ShortName()
                            if peerClass and peerClass ~= "" then
                                ImGui.TextColored(0.2, 0.6, 0.8, 1, peer .. " (" .. peerClass .. ")")
                            else
                                ImGui.TextColored(0.2, 0.6, 0.8, 1, peer .. " (Online)")
                            end
                        else
                            ImGui.TextColored(0.7, 0.7, 0.7, 1, peer .. " (Offline)")
                        end
                    end

                    ImGui.TableSetColumnIndex(1)
                    
                    -- Get current rule for this peer
                    local peerRules = database.getLootRulesForPeer(peer)
                    local itemName = lootUI.peerItemRulesPopup.itemName or ""
                    local lowerItemName = string.lower(itemName)
                    local itemID = lootUI.peerItemRulesPopup.itemID or 0
                    
                    -- Try to find the rule - first by composite key if we have an itemID, then by name
                    local ruleData = nil
                    if itemID > 0 then
                        local compositeKey = string.format("%s_%d", itemName, itemID)
                        ruleData = peerRules[compositeKey]
                    end
                    
                    -- Fallback to name-based lookup (exact match first, then case variations)
                    if not ruleData then
                        ruleData = peerRules[itemName] or peerRules[lowerItemName]
                    end
                    
                    -- Default if no rule found - assume fallback table for new rules without itemID
                    if not ruleData then
                        local defaultTableSource = (itemID > 0) and "lootrules_v2" or "lootrules_name_fallback"
                        ruleData = { 
                            rule = "", 
                            item_id = itemID, 
                            icon_id = lootUI.peerItemRulesPopup.iconID or 0,
                            tableSource = defaultTableSource
                        }
                    end
                    
                    local currentRuleStr = ruleData.rule or ""
                    
                    -- Initialize persistent state for this peer if not exists
                    if not lootUI.peerItemRulesPopup.peerStates[peer] then
                        lootUI.peerItemRulesPopup.peerStates[peer] = {
                            displayRule = currentRuleStr,
                            threshold = 1
                        }
                    end
                    
                    local peerState = lootUI.peerItemRulesPopup.peerStates[peer]
                    
                    -- Parse the current rule for display
                    local displayRule, threshold
                    if string.sub(currentRuleStr, 1, 15) == "KeepIfFewerThan" then
                        local th = currentRuleStr:match("^KeepIfFewerThan:(%d+)")
                        local auto = currentRuleStr:find(":AutoIgnore") ~= nil
                        displayRule = auto and "KeepThenIgnore" or "KeepIfFewerThan"
                        threshold = tonumber(th) or 1
                    elseif currentRuleStr == "" then
                        displayRule = "Unset"
                    else
                        displayRule = currentRuleStr
                    end
                    
                    -- Update persistent state if not recently changed
                    if not peerState.recentlyChanged then
                        peerState.displayRule = displayRule
                        peerState.threshold = threshold or 1
                    end

                    -- Rule combo box
                    if ImGui.BeginCombo("##ruleCombo_" .. peer, peerState.displayRule) then
                        for _, option in ipairs({"Keep", "Ignore", "KeepIfFewerThan", "KeepThenIgnore", "Destroy", "Unset"}) do
                            local isSelected = (peerState.displayRule == option)
                            if ImGui.Selectable(option, isSelected) then
                                local newRuleValue = option
                                if option == "KeepIfFewerThan" then
                                    newRuleValue = "KeepIfFewerThan:" .. (peerState.threshold or 1)
                                elseif option == "KeepThenIgnore" then
                                    newRuleValue = "KeepIfFewerThan:" .. (peerState.threshold or 1) .. ":AutoIgnore"
                                elseif option == "Unset" then
                                    newRuleValue = ""
                                end

                                if newRuleValue ~= currentRuleStr then
                                    -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                                    local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                                    local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                                    
                                    local success = savePeerPopupRuleFor(
                                        peer,
                                        itemName,
                                        itemID,
                                        iconID,
                                        newRuleValue,
                                        currentCharacter,
                                        connectedPeerSet,
                                        (lootUI.peerItemRulesPopup.tableSource == "lootrules_name_fallback") and "lootrules_name_fallback" or (ruleData and ruleData.tableSource)
                                    )
                                    
                                    if success then
                                        -- Update persistent state
                                        peerState.displayRule = (option == "KeepIfFewerThan") and "KeepIfFewerThan" or option
                                        peerState.recentlyChanged = true
                                        peerState.changeTime = mq.gettime()
                                        logging.debug(string.format("[PeerRules] Successfully saved rule '%s' for %s -> %s (itemID=%d, iconID=%d)", 
                                            newRuleValue, peer, itemName, itemID, iconID))

                                        -- Debug: Check if rule is in cache after refresh
                                        local testRules = database.getLootRulesForPeer(peer)
                                        local testKey = itemID > 0 and string.format("%s_%d", itemName, itemID) or itemName
                                        local testRule = testRules[testKey]
                                        if testRule then
                                            logging.debug(string.format("[PeerRules] Verified rule in cache: key=%s, rule=%s", testKey, testRule.rule))
                                        else
                                            logging.debug(string.format("[PeerRules] WARNING: Rule not found in cache after refresh! key=%s", testKey))
                                        end
                                    else
                                        logging.debug(string.format("[PeerRules] Failed to save rule '%s' for %s -> %s", newRuleValue, peer, itemName))
                                    end
                                end
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.EndCombo()
                    end

                    -- Threshold input for KeepIfFewerThan/KeepThenIgnore
                    if peerState.displayRule == "KeepIfFewerThan" or peerState.displayRule == "KeepThenIgnore" then
                        ImGui.SameLine()
                        local newThreshold, changedThreshold = ImGui.InputInt("##threshold_" .. peer, peerState.threshold)
                        if changedThreshold then
                            newThreshold = math.max(1, newThreshold)
                            if newThreshold ~= peerState.threshold then
                                local updatedRule
                                if peerState.displayRule == "KeepThenIgnore" then
                                    updatedRule = "KeepIfFewerThan:" .. newThreshold .. ":AutoIgnore"
                                else
                                    updatedRule = "KeepIfFewerThan:" .. newThreshold
                                end
                                -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                                local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                                local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                                
                                local success = savePeerPopupRuleFor(
                                    peer,
                                    itemName,
                                    itemID,
                                    iconID,
                                    updatedRule,
                                    currentCharacter,
                                    connectedPeerSet,
                                    (lootUI.peerItemRulesPopup.tableSource == "lootrules_name_fallback") and "lootrules_name_fallback" or (ruleData and ruleData.tableSource)
                                )
                                
                                if success then
                                    peerState.threshold = newThreshold
                                    peerState.recentlyChanged = true
                                    peerState.changeTime = mq.gettime()
                                    logging.debug(string.format("[PeerRules] Successfully updated threshold to %d for %s -> %s", newThreshold, peer, itemName))
                                else
                                    logging.debug(string.format("[PeerRules] Failed to update threshold to %d for %s -> %s", newThreshold, peer, itemName))
                                end
                            end
                        end
                    end

                    ImGui.TableSetColumnIndex(2)
                    if ImGui.Button("Unset##" .. peer) then
                        if currentRuleStr ~= "" then
                            -- Use the itemID and iconID from the popup if available, otherwise fall back to database values
                            local itemID = lootUI.peerItemRulesPopup.itemID or ruleData.item_id or 0
                            local iconID = lootUI.peerItemRulesPopup.iconID or ruleData.icon_id or 0
                            
                            local success = savePeerPopupRuleFor(
                                peer,
                                itemName,
                                itemID,
                                iconID,
                                "",
                                currentCharacter,
                                connectedPeerSet,
                                (lootUI.peerItemRulesPopup.tableSource == "lootrules_name_fallback") and "lootrules_name_fallback" or (ruleData and ruleData.tableSource)
                            )
                            
                            if success then
                                peerState.displayRule = "Unset"
                                peerState.recentlyChanged = true
                                peerState.changeTime = mq.gettime()
                                logging.debug(string.format("[PeerRules] Successfully unset rule for %s -> %s", peer, itemName))
                            else
                                logging.debug(string.format("[PeerRules] Failed to unset rule for %s -> %s", peer, itemName))
                            end
                        end
                    end
                end
                ImGui.EndTable()
            end
        else
            -- Window was closed by X button
            lootUI.peerItemRulesPopup.isOpen = false
            lootUI.peerItemRulesPopup.itemName = ""
            -- Don't clear peerStates - let them persist to remember dropdown selections
        end
        
        ImGui.End()
        
        if not keepOpen then
            lootUI.peerItemRulesPopup.isOpen = false
            lootUI.peerItemRulesPopup.itemName = ""
            -- Don't clear peerStates - let them persist to remember dropdown selections
        end
    end
end

-- Update ItemID/IconID Popup
function uiPopups.drawUpdateIDsPopup(lootUI, database, util)
    if lootUI.updateIDsPopup and lootUI.updateIDsPopup.isOpen then
        local windowTitle = "SmartLoot - Item ID Manager"
        
        ImGui.SetNextWindowSize(500, 350, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin(windowTitle, keepOpen) then
            local popup = lootUI.updateIDsPopup
            
            -- Header with item info
            ImGui.BeginGroup()
            if popup.currentIconID and popup.currentIconID > 0 then
                uiUtils.drawItemIcon(popup.currentIconID)
            else
                ImGui.Text("[No Icon]")
            end
            ImGui.SameLine()
            ImGui.BeginGroup()
            ImGui.Text("Item: " .. (popup.itemName or ""))
            ImGui.Text("Current ItemID: " .. (popup.currentItemID or 0))
            ImGui.Text("Current IconID: " .. (popup.currentIconID or 0))
            ImGui.EndGroup()
            ImGui.EndGroup()

            ImGui.Separator()

            -- Instructions
            ImGui.TextWrapped("This will update the ItemID and IconID for this item across ALL characters who have rules for it. " ..
                "This is useful when you have better item information (like from actually seeing the item in-game) " ..
                "that you want to propagate to all your characters.")

            ImGui.Separator()

            -- Input fields
            ImGui.Text("New Values:")

            -- ItemID input
            ImGui.Text("New ItemID:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            local newItemID, changedItemID = ImGui.InputInt("##newItemID", popup.newItemID or 0)
            if changedItemID then
                popup.newItemID = math.max(0, newItemID)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("The game's internal ItemID for this item")
            end

            -- Show change indicator for ItemID
            ImGui.SameLine()
            if (popup.newItemID or 0) ~= (popup.currentItemID or 0) then
                if (popup.newItemID or 0) == 0 then
                    ImGui.TextColored(0.8, 0.6, 0.2, 1, "(will clear ItemID)")
                else
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "(changed from " .. (popup.currentItemID or 0) .. ")")
                end
            else
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "(unchanged)")
            end

            -- IconID input with live preview
            ImGui.Text("New IconID:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            local newIconID, changedIconID = ImGui.InputInt("##newIconID", popup.newIconID or 0)
            if changedIconID then
                popup.newIconID = math.max(0, newIconID)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("The icon ID used to display this item's icon")
            end

            -- Live icon preview
            ImGui.SameLine()
            if popup.newIconID and popup.newIconID > 0 then
                uiUtils.drawItemIcon(popup.newIconID)
                ImGui.SameLine()
            end

            -- Show change indicator for IconID
            if (popup.newIconID or 0) ~= (popup.currentIconID or 0) then
                if (popup.newIconID or 0) == 0 then
                    ImGui.TextColored(0.8, 0.6, 0.2, 1, "(will clear IconID)")
                else
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "(changed from " .. (popup.currentIconID or 0) .. ")")
                end
            else
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "(unchanged)")
            end

            -- Icon comparison if changed
            if (popup.newIconID or 0) ~= (popup.currentIconID or 0) and 
               popup.newIconID and popup.newIconID > 0 and 
               popup.currentIconID and popup.currentIconID > 0 then
                ImGui.Separator()
                ImGui.Text("Icon Comparison:")

                -- Current icon
                ImGui.BeginGroup()
                ImGui.Text("Current (" .. popup.currentIconID .. "):")
                uiUtils.drawItemIcon(popup.currentIconID)
                ImGui.EndGroup()

                ImGui.SameLine()
                ImGui.Text(" -> ")
                ImGui.SameLine()

                -- New icon
                ImGui.BeginGroup()
                ImGui.Text("New (" .. popup.newIconID .. "):")
                uiUtils.drawItemIcon(popup.newIconID)
                ImGui.EndGroup()
            end

            ImGui.Separator()

            -- Get list of affected characters
            local allCharacters = database.getAllCharactersWithRules()
            local affectedCharacters = {}
            
            for _, character in ipairs(allCharacters) do
                local peerRules = database.getLootRulesForPeer(character)
                local lowerItemName = string.lower(popup.itemName or "")
                local itemName = popup.itemName or ""
                local currentItemID = popup.currentItemID or 0
                
                -- Check both name-based and composite key lookups
                local hasRule = false
                
                -- Try composite key first if we have an itemID
                if currentItemID > 0 then
                    local compositeKey = string.format("%s_%d", itemName, currentItemID)
                    if peerRules[compositeKey] then
                        hasRule = true
                    end
                end
                
                -- Try name-based lookup
                if not hasRule and (peerRules[lowerItemName] or peerRules[itemName]) then
                    hasRule = true
                end
                
                -- Also check all rules to find any that match the item name
                if not hasRule then
                    for key, ruleData in pairs(peerRules) do
                        if ruleData.item_name and 
                           (string.lower(ruleData.item_name) == lowerItemName or ruleData.item_name == itemName) then
                            hasRule = true
                            break
                        end
                    end
                end
                
                if hasRule then
                    table.insert(affectedCharacters, character)
                end
            end

            -- Show affected characters
            if #affectedCharacters > 0 then
                ImGui.Text("Characters with rules for this item (" .. #affectedCharacters .. "):")
                ImGui.BeginChild("AffectedCharactersList", 0, 80, true)
                for _, character in ipairs(affectedCharacters) do
                    local currentChar = mq.TLO.Me.Name()
                    if character == currentChar then
                        ImGui.TextColored(0.2, 0.8, 0.2, 1, character .. " (Current)")
                    else
                        ImGui.Text(character)
                    end
                end
                ImGui.EndChild()
            else
                ImGui.TextColored(0.8, 0.6, 0.2, 1, "No characters found with rules for this item.")
            end

            ImGui.Separator()

            -- Action buttons
            local hasChanges = ((popup.newItemID or 0) ~= (popup.currentItemID or 0)) or 
                              ((popup.newIconID or 0) ~= (popup.currentIconID or 0))

            if not hasChanges then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
            else
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
            end

            if ImGui.Button("Update All Characters", 150, 0) and hasChanges then
                -- Update all affected characters
                local updateCount = 0
                local itemName = popup.itemName or ""
                local newItemID = popup.newItemID or popup.currentItemID or 0
                local newIconID = popup.newIconID or popup.currentIconID or 0
                
                logging.debug(string.format("[UpdateIDs] Starting update for '%s': currentID=%d->%d, iconID=%d->%d, affected=%d", 
                                          itemName, popup.currentItemID or 0, newItemID, 
                                          popup.currentIconID or 0, newIconID, #affectedCharacters))

                for _, character in ipairs(affectedCharacters) do
                    local peerRules = database.getLootRulesForPeer(character)
                    local lowerItemName = string.lower(itemName)
                    local currentItemID = popup.currentItemID or 0
                    
                    -- Find the current rule using the same logic as detection
                    local currentRule = nil
                    local foundKey = nil
                    
                    -- Try composite key first if we have an itemID
                    if currentItemID > 0 then
                        local compositeKey = string.format("%s_%d", itemName, currentItemID)
                        if peerRules[compositeKey] then
                            currentRule = peerRules[compositeKey]
                            foundKey = compositeKey
                        end
                    end
                    
                    -- Try name-based lookup
                    if not currentRule then
                        currentRule = peerRules[lowerItemName] or peerRules[itemName]
                        foundKey = currentRule and (peerRules[lowerItemName] and lowerItemName or itemName)
                    end
                    
                    -- Search all rules if still not found
                    if not currentRule then
                        for key, ruleData in pairs(peerRules) do
                            if ruleData.item_name and 
                               (string.lower(ruleData.item_name) == lowerItemName or ruleData.item_name == itemName) then
                                currentRule = ruleData
                                foundKey = key
                                break
                            end
                        end
                    end
                    
                    if currentRule then
                        logging.debug(string.format("[UpdateIDs] Updating %s: found rule with key '%s', rule='%s'", 
                                                  character, foundKey or "unknown", currentRule.rule or ""))
                        
                        -- Save with new IDs
                        local success = database.saveLootRuleFor(character, itemName, newItemID, currentRule.rule, newIconID)
                        if success then
                            updateCount = updateCount + 1
                            
                            -- If the old key was different from what the new one will be, we might need to delete the old entry
                            if currentItemID > 0 and newItemID ~= currentItemID then
                                -- The saveLootRuleFor should handle this, but let's log it
                                logging.debug(string.format("[UpdateIDs] ItemID changed from %d to %d for %s", 
                                                          currentItemID, newItemID, character))
                            end
                        else
                            logging.debug(string.format("[UpdateIDs] Failed to update rule for %s", character))
                        end
                        
                        -- Send reload command to connected peers
                        local connectedPeers = util.getConnectedPeers()
                        for _, connectedPeer in ipairs(connectedPeers) do
                            if connectedPeer == character then
                                util.sendPeerCommandViaActor(character, "reload_rules", {})
                                break
                            end
                        end
                    else
                        logging.debug(string.format("[UpdateIDs] No rule found for %s (this shouldn't happen!)", character))
                    end
                end

                -- Refresh current character's rules if affected
                local currentChar = mq.TLO.Me.Name()
                for _, character in ipairs(affectedCharacters) do
                    if character == currentChar then
                        database.refreshLootRuleCache()
                        break
                    end
                end

                logging.log(string.format("SmartLoot: Updated ItemID/IconID for '%s' across %d characters", itemName, updateCount))
                keepOpen = false
            end
            ImGui.PopStyleColor(3)

            if not hasChanges and ImGui.IsItemHovered() then
                ImGui.SetTooltip("No changes detected. Modify ItemID or IconID to enable update.")
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 80, 0) then
                keepOpen = false
            end

            ImGui.SameLine()
            if ImGui.Button("Reset", 80, 0) then
                popup.newItemID = popup.currentItemID
                popup.newIconID = popup.currentIconID
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Reset values to current ItemID/IconID")
            end

            ImGui.Separator()

            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("You can get ItemID/IconID by examining items in-game")
            ImGui.BulletText("This update preserves all existing rules, only updating the IDs")
            ImGui.BulletText("Connected peers will automatically reload their rules")
        end
        ImGui.End()

        if not keepOpen then
            lootUI.updateIDsPopup.isOpen = false
            lootUI.updateIDsPopup.itemName = ""
            lootUI.updateIDsPopup.currentItemID = 0
            lootUI.updateIDsPopup.currentIconID = 0
            lootUI.updateIDsPopup.newItemID = 0
            lootUI.updateIDsPopup.newIconID = 0
        end
    end
end

-- Loot Stats Popup
function uiPopups.drawLootStatsPopup(lootUI, lootStats)
    if lootUI.selectedStatItem then
        ImGui.SetNextWindowSize(400, 300, ImGuiCond.FirstUseEver)
        local popupOpen = ImGui.Begin("SmartLoot - Item Statistics", true)
        if popupOpen then
            ImGui.Text("Statistics for: " .. (lootUI.selectedStatItem or "Unknown Item"))
            ImGui.Separator()
            local zoneStats = lootStats.getItemDropRates(lootUI.selectedStatItem) or {}
            if ImGui.BeginTable("ZoneStatsTable", 4, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                ImGui.TableSetupColumn("Zone", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Drops", ImGuiTableColumnFlags.WidthFixed, 50)
                ImGui.TableSetupColumn("Corpses", ImGuiTableColumnFlags.WidthFixed, 50)
                ImGui.TableSetupColumn("Drop Rate %", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()
                for _, zoneStat in ipairs(zoneStats) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(zoneStat.zone_name or "")
                    ImGui.TableSetColumnIndex(1)
                    ImGui.Text(tostring(zoneStat.drop_count or 0))
                    ImGui.TableSetColumnIndex(2)
                    ImGui.Text(tostring(zoneStat.corpse_count or 0))
                    ImGui.TableSetColumnIndex(3)
                    ImGui.Text("%.2f", zoneStat.drop_rate or 0)
                end
                ImGui.EndTable()
            else
                ImGui.Text("No detailed stats available.")
            end

            if ImGui.Button("Close") then
                lootUI.selectedStatItem = nil
            end
        end
        ImGui.End()
    end
end

-- Enhanced Loot Rules Popup with right-click context menu
function uiPopups.drawLootRulesPopup(lootUI, database, util)
    if lootUI.selectedItemForPopup then
        ImGui.SetNextWindowSize(400, 300, ImGuiCond.FirstUseEver)
        local popupOpen = ImGui.Begin("SmartLoot - Item Rules", true)
        if popupOpen then
            ImGui.Text("Rules for: " .. (lootUI.selectedItemForPopup or "Unknown Item"))
            ImGui.Separator()
            if ImGui.BeginTable("LootRulesPopupTable", 2, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg) then
                ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableHeadersRow()

                local peerList = { mq.TLO.Me.Name() or "Local" }
                local connectedPeers = util.getConnectedPeers()
                for _, peer in ipairs(connectedPeers) do
                    if peer ~= (mq.TLO.Me.Name() or "Local") then
                        table.insert(peerList, peer)
                    end
                end

                for _, peer in ipairs(peerList) do
                    ImGui.TableNextRow()

                    ImGui.TableSetColumnIndex(0)
                    -- Make the peer name selectable for right-click context menu
                    local selectableId = peer .. "##peer_" .. lootUI.selectedItemForPopup
                    local isRowSelected = ImGui.Selectable(selectableId, false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowItemOverlap)

                    -- Handle right-click context menu for Update IDs
                    if ImGui.BeginPopupContextItem("ContextMenu##" .. peer .. "_" .. lootUI.selectedItemForPopup) then
                        ImGui.Text("Actions for: " .. lootUI.selectedItemForPopup)
                        ImGui.Separator()

                        if ImGui.MenuItem("Update ItemID/IconID for All Peers") then
                            -- Set up the update IDs popup
                            lootUI.updateIDsPopup = lootUI.updateIDsPopup or {}
                            lootUI.updateIDsPopup.isOpen = true
                            lootUI.updateIDsPopup.itemName = lootUI.selectedItemForPopup
                            
                            -- Get current rule data to populate IDs
                            local ruleData = database.getLootRulesForPeer(peer)[string.lower(lootUI.selectedItemForPopup)] or 
                                           database.getLootRulesForPeer(peer)[lootUI.selectedItemForPopup] or 
                                           { rule = "", item_id = 0, icon_id = 0 }
                            
                            lootUI.updateIDsPopup.currentItemID = ruleData.item_id or 0
                            lootUI.updateIDsPopup.currentIconID = ruleData.icon_id or 0
                            lootUI.updateIDsPopup.newItemID = ruleData.item_id or 0
                            lootUI.updateIDsPopup.newIconID = ruleData.icon_id or 0
                        end

                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Update ItemID and IconID for this item across all characters/peers")
                        end

                        ImGui.EndPopup()
                    end

                    ImGui.TableSetColumnIndex(1)
                    local peerRules = database.getLootRulesForPeer(peer)
                    local ruleData = peerRules[lootUI.selectedItemForPopup] or 
                                   peerRules[string.lower(lootUI.selectedItemForPopup)] or 
                                   { rule = "Unset", tableSource = "lootrules_name_fallback" }
                    local currentRule = ruleData.rule
                    local displayRule = currentRule or "Unset"
                    local threshold = 1

                    if currentRule and string.sub(currentRule, 1, 15) == "KeepIfFewerThan" then
                        displayRule = "KeepIfFewerThan"
                        local t = currentRule:match(":(%d+)")
                        threshold = tonumber(t) or 1
                    end

                    if ImGui.BeginCombo("##ruleCombo_" .. peer, displayRule) then
                        for _, option in ipairs({"Keep", "Ignore", "KeepIfFewerThan", "Destroy"}) do
                            local isSelected = (displayRule == option)
                            if ImGui.Selectable(option, isSelected) then
                                local newRule = option
                                if option == "KeepIfFewerThan" then
                                    newRule = "KeepIfFewerThan:" .. threshold
                                end
                                -- Check if this item is from the fallback table (prefer original table source from popup)
                                local isFromFallback = (lootUI.peerItemRulesPopup and lootUI.peerItemRulesPopup.tableSource == "lootrules_name_fallback") or 
                                                      (ruleData and ruleData.tableSource == "lootrules_name_fallback")
                                if isFromFallback then
                                    -- Use name-based rule saving for fallback table items
                                    database.saveNameBasedRuleFor(peer, lootUI.selectedItemForPopup, newRule)
                                else
                                    -- Use itemID-based saving for regular items
                                    if peer == (mq.TLO.Me.Name() or "Local") then
                                        local itemID = ruleData.item_id or 0
                                        local iconID = ruleData.icon_id or 0
                                        database.saveLootRule(lootUI.selectedItemForPopup, itemID, newRule, iconID)
                                    end
                                end
                                currentRule = newRule
                                displayRule = (option == "KeepIfFewerThan") and "KeepIfFewerThan" or newRule
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.EndCombo()
                    end

                    if displayRule == "KeepIfFewerThan" then
                        ImGui.SameLine()
                        local newThreshold, changedThreshold = ImGui.InputInt("##threshold_" .. peer, threshold, 0, 0)
                        if changedThreshold then
                            newThreshold = math.max(1, newThreshold)
                            local newRule = "KeepIfFewerThan:" .. newThreshold
                            -- Check if this item is from the fallback table (prefer original table source from popup)
                            local isFromFallback = (lootUI.peerItemRulesPopup and lootUI.peerItemRulesPopup.tableSource == "lootrules_name_fallback") or 
                                                  (ruleData and ruleData.tableSource == "lootrules_name_fallback")
                            if isFromFallback then
                                -- Use name-based rule saving for fallback table items
                                database.saveNameBasedRuleFor(peer, lootUI.selectedItemForPopup, newRule)
                            else
                                -- Use itemID-based saving for regular items
                                if peer == (mq.TLO.Me.Name() or "Local") then
                                    database.saveLootRule(lootUI.selectedItemForPopup, ruleData.item_id, newRule, ruleData.icon_id)
                                end
                            end
                            currentRule = newRule
                            displayRule = "KeepIfFewerThan"
                            threshold = newThreshold
                        end
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Separator()
            if ImGui.Button("Close") then
                lootUI.selectedItemForPopup = nil
            end
        end
        ImGui.End()

        if not popupOpen then
            lootUI.selectedItemForPopup = nil
        end
    end
end

-- Broadcast New Rule Popup
function uiPopups.drawBroadcastNewRulePopup(lootUI, database, util)
    local pop = lootUI and lootUI.broadcastNewRulePopup
    if not pop or not pop.isOpen then return end

    ImGui.SetNextWindowSize(420, 170, ImGuiCond.Appearing)
    local keepOpen = true
    if ImGui.Begin("Broadcast New Rule?", keepOpen, ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.AlwaysAutoResize) then
        ImGui.Text("A new rule was created:")
        ImGui.BulletText("%s -> %s", pop.itemName or "?", pop.rule or "?")
        ImGui.Spacing()
        ImGui.Text("Broadcast this rule to all connected peers?")
        ImGui.Spacing()

        if ImGui.Button("Broadcast", 120, 0) then
            local peers = util.getConnectedPeers()
            for _, peer in ipairs(peers) do
                if peer ~= (mq.TLO.Me.Name() or "") then
                    pcall(function()
                        database.saveLootRuleFor(peer, pop.itemName, pop.itemID or 0, pop.rule, pop.iconID or 0)
                    end)
                end
            end
            -- Ask peers to refresh rules via actor mailbox
            pcall(function() util.broadcastRulesReload() end)
            util.printSmartLoot(string.format("Broadcasted rule %s -> %s to %d peer(s)", pop.itemName, pop.rule, math.max(0, #peers-1)), "success")
            pop.isOpen = false
        end
        
        ImGui.SameLine()
        if ImGui.Button("Don't Broadcast", 160, 0) then
            pop.isOpen = false
        end

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip("Keeps the rule only on this character")
        end

        ImGui.End()
    end
    if not keepOpen then pop.isOpen = false end
end

-- KeepIfFewerThan Threshold Popup
function uiPopups.drawThresholdPopup(lootUI, database)
    if lootUI.editingThresholdForPeer then
        ImGui.SetNextWindowSize(300, 150)
        ImGui.OpenPopup("KeepIfFewerThanThreshold")

        if ImGui.BeginPopup("KeepIfFewerThanThreshold") then
            ImGui.Text("Set threshold for:")
            ImGui.TextColored(1, 1, 0, 1, lootUI.editingThresholdForPeer.itemName)
            ImGui.Text("Peer: " .. lootUI.editingThresholdForPeer.peer)
            ImGui.Separator()

            ImGui.Text("Keep if fewer than:")
            ImGui.SameLine()
            local newThreshold, changedThreshold = ImGui.InputInt("##thresholdPopup", lootUI.editingThresholdForPeer.threshold, 1)
            if changedThreshold then
                lootUI.editingThresholdForPeer.threshold = math.max(1, newThreshold)
            end

            ImGui.Separator()

            if ImGui.Button("Apply", 120, 0) then
                local newRule = "KeepIfFewerThan:" .. lootUI.editingThresholdForPeer.threshold
                
                -- Determine if this item is from the fallback table
                local isFromFallback = false
                local peerName = lootUI.editingThresholdForPeer.peer == "Local" and mq.TLO.Me.Name() or lootUI.editingThresholdForPeer.peer
                local allRules = (peerName == mq.TLO.Me.Name()) and database.getAllLootRules() or database.getLootRulesForPeer(peerName)
                local ruleData = allRules[lootUI.editingThresholdForPeer.itemName]
                if ruleData and ruleData.tableSource == "lootrules_name_fallback" then
                    isFromFallback = true
                end
                
                if isFromFallback then
                    -- Use name-based rule saving for fallback table items
                    database.saveNameBasedRuleFor(peerName, lootUI.editingThresholdForPeer.itemName, newRule)
                else
                    -- Use itemID-based saving for regular items
                    local rule, itemID, iconID
                    if lootUI.editingThresholdForPeer.peer == "Local" then
                        rule, itemID, iconID = database.getLootRule(lootUI.editingThresholdForPeer.itemName, true)
                        database.saveLootRule(lootUI.editingThresholdForPeer.itemName, itemID, newRule, iconID)
                    else
                        rule, itemID, iconID = database.getLootRule(lootUI.editingThresholdForPeer.itemName, true)
                        database.saveLootRuleFor(
                            lootUI.editingThresholdForPeer.peer,
                            lootUI.editingThresholdForPeer.itemName,
                            itemID,
                            newRule,
                            iconID
                        )
                    end
                end
                logging.log("Set " .. newRule .. " rule for " .. lootUI.editingThresholdForPeer.itemName ..
                            " on " .. lootUI.editingThresholdForPeer.peer)
                lootUI.editingThresholdForPeer = nil
                ImGui.CloseCurrentPopup()
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 120, 0) then
                lootUI.editingThresholdForPeer = nil
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        end
    end
end

-- Add New Rule Popup
function uiPopups.drawAddNewRulePopup(lootUI, database, util)
    if lootUI.addNewRulePopup and lootUI.addNewRulePopup.isOpen then
        ImGui.SetNextWindowSize(400, 250, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin("Add New Loot Rule", keepOpen) then
            local popup = lootUI.addNewRulePopup
            
            ImGui.Text("Create a new loot rule:")
            ImGui.Separator()

            -- Item name input
            ImGui.Text("Item Name:")
            ImGui.SetNextItemWidth(300)
            local newItemName, changedItemName = ImGui.InputText("##newItemName", popup.itemName or "")
            if changedItemName then
                popup.itemName = newItemName
            end

            -- Rule selection
            ImGui.Text("Rule:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(120)
            if ImGui.BeginCombo("##newRule", popup.rule or "Keep") then
                for _, ruleOption in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan"}) do
                    local isSelected = (popup.rule == ruleOption)
                    if ImGui.Selectable(ruleOption, isSelected) then
                        popup.rule = ruleOption
                        if ruleOption == "KeepIfFewerThan" then
                            popup.threshold = popup.threshold or 1
                        end
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end

            -- Threshold input for KeepIfFewerThan
            if popup.rule == "KeepIfFewerThan" then
                ImGui.SameLine()
                ImGui.Text("Threshold:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(80)
                local newThreshold, changedThreshold = ImGui.InputInt("##newRuleThreshold", popup.threshold or 1)
                if changedThreshold then
                    popup.threshold = math.max(1, newThreshold)
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Keep item only if you have fewer than this amount in inventory")
                end
            end

            -- Character selector
            ImGui.Text("Character:")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150)
            
            local currentChar = mq.TLO.Me.Name() or "Local"
            popup.selectedCharacter = popup.selectedCharacter or currentChar
            
            if ImGui.BeginCombo("##selectedCharacter", popup.selectedCharacter) then
                -- Current character first
                local isSelected = (popup.selectedCharacter == currentChar)
                if ImGui.Selectable(currentChar, isSelected) then
                    popup.selectedCharacter = currentChar
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
                
                -- Other characters
                local allCharacters = database.getAllCharactersWithRules()
                for _, charName in ipairs(allCharacters) do
                    if charName ~= currentChar then
                        local isSelected = (popup.selectedCharacter == charName)
                        if ImGui.Selectable(charName, isSelected) then
                            popup.selectedCharacter = charName
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                end
                ImGui.EndCombo()
            end

            ImGui.Separator()

            -- Action buttons
            local canAdd = popup.itemName and popup.itemName ~= "" and popup.rule and popup.selectedCharacter
            
            if not canAdd then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
            else
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
                ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
            end

            if ImGui.Button("Add Rule", 120, 0) and canAdd then
                local finalRule = popup.rule
                if popup.rule == "KeepIfFewerThan" then
                    finalRule = "KeepIfFewerThan:" .. (popup.threshold or 1)
                end

                if popup.selectedCharacter == currentChar then
                    database.saveLootRule(popup.itemName, 0, finalRule, 0)
                else
                    database.saveLootRuleFor(popup.selectedCharacter, popup.itemName, 0, finalRule, 0)
                end

                logging.log(string.format("Added new loot rule: %s -> %s for character %s", 
                    popup.itemName, finalRule, popup.selectedCharacter))
                database.refreshLootRuleCacheForPeer(popup.selectedCharacter)

                -- Clear the form
                popup.itemName = ""
                popup.rule = "Keep"
                popup.threshold = 1
                popup.selectedCharacter = currentChar
            end
            ImGui.PopStyleColor(3)

            if not canAdd and ImGui.IsItemHovered() then
                ImGui.SetTooltip("Please fill in all required fields")
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 80, 0) then
                keepOpen = false
            end

            ImGui.SameLine()
            if ImGui.Button("Clear", 80, 0) then
                popup.itemName = ""
                popup.rule = "Keep"
                popup.threshold = 1
                popup.selectedCharacter = currentChar
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Clear all fields")
            end

            ImGui.Separator()

            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("Item names are case-sensitive")
            ImGui.BulletText("Rules apply immediately after creation")
            ImGui.BulletText("Connected peers will automatically reload their rules")
        end
        ImGui.End()

        if not keepOpen then
            lootUI.addNewRulePopup.isOpen = false
            lootUI.addNewRulePopup.itemName = ""
            lootUI.addNewRulePopup.rule = "Keep"
            lootUI.addNewRulePopup.threshold = 1
            lootUI.addNewRulePopup.selectedCharacter = mq.TLO.Me.Name() or "Local"
        end
    end
end

function uiPopups.drawIconUpdatePopup(lootUI, database, lootStats, lootHistory)
    if lootUI.iconUpdatePopup.isOpen then
        ImGui.OpenPopup("UpdateIconIDPopup")

        if not lootUI.iconUpdatePopup.inited then
            local _, currentItemID, currentIconID = database.getLootRule(lootUI.iconUpdatePopup.itemName, true)
            lootUI.iconUpdatePopup.currentItemID = currentItemID or 0
            lootUI.iconUpdatePopup.currentIconID = currentIconID or 0
            lootUI.iconUpdatePopup.newItemID = lootUI.iconUpdatePopup.currentItemID
            lootUI.iconUpdatePopup.newIconID = lootUI.iconUpdatePopup.currentIconID
            lootUI.iconUpdatePopup.inited = true
        end

        if ImGui.BeginPopup("UpdateIconIDPopup") then
            ImGui.Text("Update Icon ID and Item ID for:")
            ImGui.TextColored(1, 1, 0, 1, lootUI.iconUpdatePopup.itemName)
            ImGui.Separator()

            ImGui.Text("Current Item ID: " .. tostring(lootUI.iconUpdatePopup.currentItemID))
            ImGui.Text("Current Icon ID: " .. tostring(lootUI.iconUpdatePopup.currentIconID))
            if lootUI.iconUpdatePopup.currentIconID > 0 then
                ImGui.Text("Current Icon:")
                ImGui.SameLine()
                uiUtils.drawItemIcon(lootUI.iconUpdatePopup.currentIconID)
            else
                ImGui.Text("No icon currently set")
            end

            ImGui.Separator()

            local newItemID, changedItemID = ImGui.InputInt("New Item ID", lootUI.iconUpdatePopup.newItemID)
            if changedItemID then
                lootUI.iconUpdatePopup.newItemID = math.max(0, newItemID)
            end

            local newIconID, changedIcon = ImGui.InputInt("New Icon ID", lootUI.iconUpdatePopup.newIconID)
            if changedIcon then
                lootUI.iconUpdatePopup.newIconID = math.max(0, newIconID)
            end

            if lootUI.iconUpdatePopup.newIconID > 0 then
                ImGui.Text("Preview:")
                ImGui.SameLine()
                uiUtils.drawItemIcon(lootUI.iconUpdatePopup.newIconID)
            end

            ImGui.Separator()

            if ImGui.Button("Update", 120, 0) then
                local itemName = lootUI.iconUpdatePopup.itemName
                local newItemID = lootUI.iconUpdatePopup.newItemID or lootUI.iconUpdatePopup.currentItemID
                local newIconID = lootUI.iconUpdatePopup.newIconID or lootUI.iconUpdatePopup.currentIconID

                local success = database.updateItemAndIconForAll(itemName, newItemID, newIconID)

                if success then
                    database.refreshLootRuleCache()
                    if lootStats then lootStats.updateIconID(itemName, newIconID) end
                    if lootHistory then lootHistory.updateIconID(itemName, newIconID) end
                    logging.log("Successfully updated item ID to " .. newItemID .. " and icon ID for " .. itemName .. " to " .. newIconID .. " in database.")
                else
                    logging.log("Failed to update item and icon IDs for " .. itemName .. " in database.")
                end

                lootUI.iconUpdatePopup.isOpen = false
                lootUI.iconUpdatePopup.inited = false
                ImGui.CloseCurrentPopup()
            end

            ImGui.SameLine()
            if ImGui.Button("Cancel", 120, 0) then
                lootUI.iconUpdatePopup.isOpen = false
                lootUI.iconUpdatePopup.inited = false
                ImGui.CloseCurrentPopup()
            end

            ImGui.EndPopup()
        else
            lootUI.iconUpdatePopup.isOpen = false
            lootUI.iconUpdatePopup.inited = false
        end
    end
end

-- Duplicate Peer Cleanup Popup with per-rule selection
function uiPopups.drawDuplicateCleanupPopup(lootUI, database)
    if lootUI.duplicateCleanupPopup and lootUI.duplicateCleanupPopup.isOpen then
        ImGui.SetNextWindowSize(900, 600, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin("SmartLoot - Duplicate Peer Cleanup", keepOpen) then
            local popup = lootUI.duplicateCleanupPopup
            
            -- Header
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.7, 0.2, 1.0) -- Orange
            ImGui.Text("Duplicate Character Name Cleanup")
            ImGui.PopStyleColor()
            ImGui.Separator()
            
            local currentChar = mq.TLO.Me.Name() or "YourCharacter"
            ImGui.TextWrapped("This tool helps fix duplicate character entries caused by switching between DanNet and E3 command types. " ..
                "DanNet can create complex entries like 'Ez (linux) x4 exp_" .. currentChar:lower() .. "' while E3 creates simple entries like '" .. currentChar .. "'.")
            
            ImGui.Spacing()
            
            -- Scan button
            if ImGui.Button("Scan for Errors", 100, 0) then
                popup.duplicates = database.detectDuplicatePeerNames()
                popup.malformed = database.detectMalformedSingletonNames()
                popup.scanned = true
                popup.selectedGroup = nil
                popup.ruleSelections = {}
            end
            
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Search the database for character names that map to the same core character")
            end
            
            ImGui.SameLine()
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Found %d duplicate groups", 
                popup.duplicates and #popup.duplicates or 0)
            
            ImGui.Separator()
            
            -- Display duplicates if found
            if popup.scanned and popup.duplicates then
                if #popup.duplicates == 0 then
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "No duplicates found! Your database is clean.")
                else
                    ImGui.Text("Found %d groups of duplicate character names:", #popup.duplicates)
                    ImGui.Spacing()
                    
                    -- Group selection table
                    if ImGui.BeginTable("GroupsTable", 3, 
                        ImGuiTableFlags.BordersInnerV + 
                        ImGuiTableFlags.RowBg + 
                        ImGuiTableFlags.Resizable) then
                        
                        ImGui.TableSetupColumn("Character Base", ImGuiTableColumnFlags.WidthFixed, 120)
                        ImGui.TableSetupColumn("Variants Found", ImGuiTableColumnFlags.WidthStretch)
                        ImGui.TableSetupColumn("Actions", ImGuiTableColumnFlags.WidthFixed, 120)
                        ImGui.TableHeadersRow()
                        
                        for groupIdx, duplicate in ipairs(popup.duplicates) do
                            ImGui.TableNextRow()
                            ImGui.TableSetColumnIndex(0)
                            
                            -- Highlight selected group
                            if popup.selectedGroup == groupIdx then
                                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1)
                                ImGui.Text(duplicate.coreCharacterName)
                                ImGui.PopStyleColor()
                            else
                                ImGui.Text(duplicate.coreCharacterName)
                            end
                            
                            ImGui.TableSetColumnIndex(1)
                            local variantNames = {}
                            for _, variant in ipairs(duplicate.variants) do
                                table.insert(variantNames, string.format("%s (%d rules)", variant.fullName, variant.ruleCount))
                            end
                            ImGui.TextWrapped(table.concat(variantNames, ", "))
                            
                            ImGui.TableSetColumnIndex(2)
                            if ImGui.Button("Manage Rules##" .. groupIdx, 110, 0) then
                                popup.selectedGroup = groupIdx
                                -- Initialize rule selections for this group
                                if not popup.ruleSelections[groupIdx] then
                                    popup.ruleSelections[groupIdx] = {}
                                end
                            end
                        end
                        
                        ImGui.EndTable()
                    end
                    
                    -- Show detailed rule management for selected group
                    if popup.selectedGroup and popup.duplicates[popup.selectedGroup] then
                        local selectedDupe = popup.duplicates[popup.selectedGroup]
                        
                        ImGui.Spacing()
                        ImGui.Separator()
                        ImGui.Text("Managing rules for: %s", selectedDupe.coreCharacterName)
                        ImGui.Spacing()
                        
                        -- Target character selection
                        if not popup.targetCharacter then
                            popup.targetCharacter = selectedDupe.variants[1].fullName -- Default to first
                        end
                        
                        ImGui.Text("Target character (where rules will be moved):")
                        ImGui.SameLine()
                        ImGui.SetNextItemWidth(200)
                        if ImGui.BeginCombo("##targetChar", popup.targetCharacter) then
                            for _, variant in ipairs(selectedDupe.variants) do
                                local isSelected = (popup.targetCharacter == variant.fullName)
                                local displayText = string.format("%s (%d rules)", variant.fullName, variant.ruleCount)
                                
                                -- Color code the options
                                local isSimpleName = variant.fullName == variant.coreName
                                if isSimpleName then
                                    ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 0.8, 0.2, 1) -- Green for simple names
                                else
                                    ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.6, 0.2, 1) -- Orange for complex names
                                end
                                
                                if ImGui.Selectable(displayText, isSelected) then
                                    popup.targetCharacter = variant.fullName
                                end
                                ImGui.PopStyleColor()
                                
                                if isSelected then
                                    ImGui.SetItemDefaultFocus()
                                end
                            end
                            ImGui.EndCombo()
                        end
                        
                        ImGui.Spacing()
                        
                        -- Rules table
                        if ImGui.BeginTable("RulesTable", 6, 
                            ImGuiTableFlags.BordersInnerV + 
                            ImGuiTableFlags.RowBg + 
                            ImGuiTableFlags.Resizable + 
                            ImGuiTableFlags.ScrollY, 0, 300) then
                            
                            ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch)
                            ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableSetupColumn("ItemID", ImGuiTableColumnFlags.WidthFixed, 60)
                            ImGui.TableSetupColumn("Copy", ImGuiTableColumnFlags.WidthFixed, 50)
                            ImGui.TableSetupColumn("Delete", ImGuiTableColumnFlags.WidthFixed, 50)
                            ImGui.TableHeadersRow()
                            
                            for variantIdx, variant in ipairs(selectedDupe.variants) do
                                -- Add separator between variants
                                if variantIdx > 1 then
                                    ImGui.TableNextRow()
                                    for col = 0, 5 do
                                        ImGui.TableSetColumnIndex(col)
                                        ImGui.Text("---")
                                    end
                                end
                                
                                for ruleIdx, rule in ipairs(variant.rules) do
                                    ImGui.TableNextRow()
                                    
                                    local ruleKey = string.format("%d_%d", variantIdx, ruleIdx)
                                    
                                    ImGui.TableSetColumnIndex(0)
                                    -- Color code source names
                                    local isSimpleName = variant.fullName == variant.coreName
                                    if isSimpleName then
                                        ImGui.TextColored(0.2, 0.8, 0.2, 1, variant.coreName)
                                    else
                                        ImGui.TextColored(0.8, 0.6, 0.2, 1, variant.fullName)
                                    end
                                    
                                    ImGui.TableSetColumnIndex(1)
                                    ImGui.Text(rule.itemName)
                                    
                                    ImGui.TableSetColumnIndex(2)
                                    ImGui.Text(rule.rule)
                                    
                                    ImGui.TableSetColumnIndex(3)
                                    if rule.itemId > 0 then
                                        ImGui.Text(tostring(rule.itemId))
                                    else
                                        ImGui.TextColored(0.6, 0.6, 0.6, 1, "none")
                                    end
                                    
                                    ImGui.TableSetColumnIndex(4)
                                    -- Copy button (only if not already the target)
                                    if variant.fullName ~= popup.targetCharacter then
                                        if ImGui.Button("Copy##" .. ruleKey, 45, 0) then
                                            database.copySpecificRule(variant.fullName, popup.targetCharacter, 
                                                rule.itemName, rule.itemId, rule.tableSource)
                                            -- Refresh the data
                                            popup.duplicates = database.detectDuplicatePeerNames()
                                        end
                                        if ImGui.IsItemHovered() then
                                            ImGui.SetTooltip("Copy '%s' rule to %s", rule.itemName, popup.targetCharacter)
                                        end
                                    else
                                        ImGui.TextColored(0.6, 0.6, 0.6, 1, "Target")
                                    end
                                    
                                    ImGui.TableSetColumnIndex(5)
                                    -- Delete button
                                    if ImGui.Button("Del##" .. ruleKey, 40, 0) then
                                        database.deleteSpecificRule(variant.fullName, rule.itemName, rule.itemId, rule.tableSource)
                                        -- Refresh the data
                                        popup.duplicates = database.detectDuplicatePeerNames()
                                    end
                                    if ImGui.IsItemHovered() then
                                        ImGui.SetTooltip("Delete '%s' rule from %s", rule.itemName, variant.fullName)
                                    end
                                end
                            end
                            
                            ImGui.EndTable()
                        end
                        
                        ImGui.Spacing()
                        
                        -- Bulk actions
                        ImGui.Text("Bulk Actions:")
                        if ImGui.Button("Copy All to Target", 150, 0) then
                            for _, variant in ipairs(selectedDupe.variants) do
                                if variant.fullName ~= popup.targetCharacter then
                                    for _, rule in ipairs(variant.rules) do
                                        database.copySpecificRule(variant.fullName, popup.targetCharacter, 
                                            rule.itemName, rule.itemId, rule.tableSource)
                                    end
                                end
                            end
                            popup.duplicates = database.detectDuplicatePeerNames()
                        end
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Copy all rules from all variants to the target character")
                        end
                        
                        ImGui.SameLine()
                        if ImGui.Button("Delete Empty Variants", 150, 0) then
                            for _, variant in ipairs(selectedDupe.variants) do
                                if variant.fullName ~= popup.targetCharacter and #variant.rules == 0 then
                                    database.deleteAllRulesForCharacter(variant.fullName)
                                end
                            end
                            popup.duplicates = database.detectDuplicatePeerNames()
                            popup.selectedGroup = nil -- Go back to group list
                        end
                        if ImGui.IsItemHovered() then
                            ImGui.SetTooltip("Remove character entries that have no rules left")
                        end
                        
                        ImGui.SameLine()
                        if ImGui.Button("Back to Groups", 120, 0) then
                            popup.selectedGroup = nil
                            popup.targetCharacter = nil
                        end
                    end
                end
            elseif popup.scanned then
                ImGui.TextColored(0.8, 0.6, 0.2, 1, "Click 'Scan for Potential Errors' to check your database.")
            end

            -- Malformed singleton section
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.7, 0.2, 1.0) -- Orange header
            ImGui.Text("Malformed Names (no clean counterpart)")
            ImGui.PopStyleColor()

            if not popup.malformed then
                popup.malformed = {}
            end

            -- Migrate All button
            if popup.malformed and #popup.malformed > 0 then
                if ImGui.Button("Migrate All to Core Names", 220, 0) then
                    for _, entry in ipairs(popup.malformed) do
                        database.mergePeerRules(entry.variant.fullName, entry.coreCharacterName)
                    end
                    -- Re-scan
                    popup.duplicates = database.detectDuplicatePeerNames()
                    popup.malformed = database.detectMalformedSingletonNames()
                    popup.selectedGroup = nil
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Merge all malformed names into their core character names and delete the source entries")
                end
            else
                ImGui.TextColored(0.6, 0.6, 0.6, 1, "No malformed names found.")
            end

            if popup.malformed and #popup.malformed > 0 then
                if ImGui.BeginTable("MalformedTable", 4, ImGuiTableFlags.BordersInnerV + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollY, 0, 200) then
                    ImGui.TableSetupColumn("Source", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Core (Target)", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Rules", ImGuiTableColumnFlags.WidthFixed, 60)
                    ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.WidthFixed, 120)
                    ImGui.TableHeadersRow()

                    for _, entry in ipairs(popup.malformed) do
                        ImGui.TableNextRow()
                        ImGui.TableSetColumnIndex(0)
                        ImGui.Text(entry.variant.fullName)
                        ImGui.TableSetColumnIndex(1)
                        ImGui.Text(entry.coreCharacterName)
                        ImGui.TableSetColumnIndex(2)
                        ImGui.Text(tostring(entry.variant.ruleCount or 0))
                        ImGui.TableSetColumnIndex(3)
                        if ImGui.Button("Migrate##" .. entry.variant.fullName, 110, 0) then
                            database.mergePeerRules(entry.variant.fullName, entry.coreCharacterName)
                            popup.duplicates = database.detectDuplicatePeerNames()
                            popup.malformed = database.detectMalformedSingletonNames()
                        end
                    end

                    ImGui.EndTable()
                end
            end
            
            ImGui.Separator()
            
            -- Action buttons
            if ImGui.Button("Close", 100, 0) then
                keepOpen = false
            end
            
            ImGui.SameLine()
            if popup.scanned and popup.duplicates and #popup.duplicates > 0 then
                if ImGui.Button("Refresh Scan", 120, 0) then
                    popup.duplicates = database.detectDuplicatePeerNames()
                    popup.selectedGroup = nil
                    popup.ruleSelections = {}
                    popup.targetCharacter = nil
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Re-scan for duplicates after making changes")
                end
            end
            
            ImGui.Spacing()
            
            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("Green names are simple character names (usually correct)")
            ImGui.BulletText("Orange names are complex DanNet names (usually duplicates)")
            ImGui.BulletText("Copy rules to the target character, then delete empty variants")
            ImGui.BulletText("Use 'Copy All to Target' for quick consolidation")
        end
        ImGui.End()
        
        if not keepOpen then
            lootUI.duplicateCleanupPopup.isOpen = false
        end
    end
end

-- Legacy Loot Import Popup
function uiPopups.drawLegacyImportPopup(lootUI, database, util)
    
    if lootUI.legacyImportPopup and lootUI.legacyImportPopup.isOpen then
        ImGui.SetNextWindowSize(800, 600, ImGuiCond.FirstUseEver)
        local keepOpen = true
        if ImGui.Begin("SmartLoot - Legacy Loot Import", keepOpen) then
            local popup = lootUI.legacyImportPopup
            
            -- Header
            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0)
            ImGui.Text("Legacy Loot Rule Import")
            ImGui.PopStyleColor()
            ImGui.Separator()
            
            ImGui.TextWrapped("Import loot rules from legacy E3 Macro loot files (INI format). " ..
                "This will parse AlwaysLoot and AlwaysLootContains sections and import them as name-based rules.")
            
            ImGui.Spacing()
            
            -- File path input
            ImGui.Text("Legacy File Path:")
            ImGui.SetNextItemWidth(600)
            local newFilePath, changedPath = ImGui.InputText("##filePath", popup.filePath or "")
            if changedPath then
                popup.filePath = newFilePath
                popup.preview = nil -- Clear preview when path changes
            end
            
            -- Quick path helper section
            ImGui.Spacing()
            ImGui.Text("Common Paths (click to use):")
            
            -- E3 Macro Inis folder
            if ImGui.Button("E3 Macro Inis Folder") then
                popup.filePath = "/mnt/c/MQ-ROF2/Config/e3 Macro Inis/"
                popup.preview = nil
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Set path to E3 Macro Inis folder - you'll need to add the filename")
            end
            
            ImGui.SameLine()
            
            -- Config folder
            if ImGui.Button("Config Folder") then
                popup.filePath = "/mnt/c/MQ-ROF2/Config/"
                popup.preview = nil
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Set path to main Config folder")
            end
            
            -- Auto-generated path from MQ TLO (Option 3 format)
            local currentChar = mq.TLO.Me.Name() or "YourChar"
            local currentServer = mq.TLO.EverQuest.Server() or "YourServer"
            local configPath = mq.TLO.MacroQuest.Path('config')() or "/mnt/c/MQ-ROF2/Config"
            
            -- Generate the correct path format: Loot_Stackable_[Char]_EZ_(Linux)_x4_Exp.ini
            local correctPath = string.format("%s/e3 Macro Inis/Loot_Stackable_%s_EZ_(Linux)_x4_Exp.ini", configPath, currentChar)
            
            ImGui.Spacing()
            ImGui.Text("Auto-generated path for your character:")
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Character: %s, Server: %s", currentChar, currentServer)
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Config Path: %s", configPath)
            
            ImGui.Spacing()
            ImGui.Text("Recommended file:")
            ImGui.TextColored(0.8, 1.0, 0.8, 1, correctPath:match("([^/]+)$") or "unknown")
            
            ImGui.Spacing()
            if ImGui.Button("Use Auto-Generated Path", 200, 0) then
                popup.filePath = correctPath
                popup.preview = nil
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Use the auto-generated path for your character")
            end
            
            -- Common filename patterns
            ImGui.Spacing()
            ImGui.Text("Common filename patterns:")
            ImGui.BulletText("Loot_Stackable_[CharName]_[ServerName].ini")
            ImGui.BulletText("Loot_Stackable_[CharName]_[ServerName]_x4_Exp.ini")
            ImGui.BulletText("Check the 'e3 Macro Inis' folder for your specific file")
            
            ImGui.Spacing()
            
            -- Preview section
            if popup.filePath and popup.filePath ~= "" then
                if ImGui.Button("Preview Import", 120, 0) then
                    -- Pass target character to check for conflicts
                    local targetChar = popup.targetCharacter or (mq.TLO.Me.Name() or "Local")
                    popup.preview = database.previewLegacyImport(popup.filePath, targetChar, popup.defaultRule)
                    if not popup.preview then
                        popup.error = "Could not read or parse the specified file"
                    else
                        popup.error = nil
                    end
                end
                
                ImGui.SameLine()
                ImGui.TextColored(0.7, 0.7, 0.7, 1, "Click to analyze the file contents and check for conflicts")
            end
            
            -- Show error if any
            if popup.error then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.4, 0.4, 1.0)
                ImGui.TextWrapped("Error: " .. popup.error)
                ImGui.PopStyleColor()
            end
            
            -- Show preview if available
            if popup.preview then
                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Text("Import Preview")
                ImGui.Spacing()
                
                -- File info with conflict detection
                ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.2, 0.8)
                ImGui.BeginChild("FileInfo", 0, 100, true)
                ImGui.Text("File: " .. popup.preview.fileName)
                ImGui.Text("Total Items: %d", popup.preview.totalItems)
                ImGui.Text("AlwaysLoot: %d items, AlwaysLootContains: %d items", 
                    popup.preview.alwaysLootCount, popup.preview.alwaysLootContainsCount)
                
                -- Show conflict info
                if popup.preview.conflictCount and popup.preview.conflictCount > 0 then
                    ImGui.TextColored(1.0, 0.8, 0.2, 1, "⚠ Conflicts: %d items already have rules", popup.preview.conflictCount)
                else
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, "✓ No conflicts detected")
                end
                ImGui.EndChild()
                ImGui.PopStyleColor()
                
                -- Import settings
                ImGui.Spacing()
                ImGui.Text("Import Settings:")
                
                -- Target character selection
                ImGui.Text("Target Character:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(200)
                
                local currentChar = mq.TLO.Me.Name() or "Local"
                popup.targetCharacter = popup.targetCharacter or currentChar
                
                if ImGui.BeginCombo("##targetChar", popup.targetCharacter) then
                    -- Current character first
                    local isSelected = (popup.targetCharacter == currentChar)
                    if ImGui.Selectable(currentChar, isSelected) then
                        popup.targetCharacter = currentChar
                        -- Refresh preview to check conflicts for new target
                        if popup.filePath and popup.filePath ~= "" then
                            popup.preview = database.previewLegacyImport(popup.filePath, popup.targetCharacter, popup.defaultRule)
                        end
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                    
                    -- Other characters
                    local allCharacters = database.getAllCharactersWithRules()
                    for _, charName in ipairs(allCharacters) do
                        if charName ~= currentChar then
                            local isSelected = (popup.targetCharacter == charName)
                            if ImGui.Selectable(charName, isSelected) then
                                popup.targetCharacter = charName
                                -- Refresh preview to check conflicts for new target
                                if popup.filePath and popup.filePath ~= "" then
                                    popup.preview = database.previewLegacyImport(popup.filePath, popup.targetCharacter, popup.defaultRule)
                                end
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                    end
                    ImGui.EndCombo()
                end
                
                -- Default rule selection
                ImGui.Text("Default Rule:")
                ImGui.SameLine()
                ImGui.SetNextItemWidth(120)
                popup.defaultRule = popup.defaultRule or "Keep"
                
                if ImGui.BeginCombo("##defaultRule", popup.defaultRule) then
                    for _, rule in ipairs({"Keep", "Ignore", "Destroy"}) do
                        local isSelected = (popup.defaultRule == rule)
                        if ImGui.Selectable(rule, isSelected) then
                            popup.defaultRule = rule
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                    ImGui.EndCombo()
                end
                
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("All imported items will use this rule")
                end
                
                -- Import summary
                ImGui.Spacing()
                local importCount = popup.preview.totalItems - (popup.preview.skipped and #popup.preview.skipped or 0)
                local conflictCount = popup.preview.conflicts and #popup.preview.conflicts or 0
                local skippedCount = popup.preview.skipped and #popup.preview.skipped or 0
                
                ImGui.TextColored(0.2, 0.8, 0.2, 1, "✓ %d items will be imported", importCount)
                if skippedCount > 0 then
                    ImGui.TextColored(0.7, 0.7, 0.7, 1, "⊘ %d items will be skipped (already have ItemID rules)", skippedCount)
                end
                if conflictCount > 0 then
                    ImGui.TextColored(1.0, 0.8, 0.2, 1, "⚠ %d items will overwrite existing rules", conflictCount)
                end
                
                -- Sample items preview
                if #popup.preview.sampleItems > 0 then
                    ImGui.Spacing()
                    ImGui.Text("Sample Items (showing first 20):")
                    
                    if ImGui.BeginTable("SampleItemsTable", 4, 
                        ImGuiTableFlags.BordersInnerV + 
                        ImGuiTableFlags.RowBg + 
                        ImGuiTableFlags.ScrollY, 0, 200) then
                        
                        ImGui.TableSetupColumn("Section", ImGuiTableColumnFlags.WidthFixed, 120)
                        ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                        ImGui.TableSetupColumn("Status", ImGuiTableColumnFlags.WidthFixed, 100)
                        ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                        ImGui.TableHeadersRow()
                        
                        for _, item in ipairs(popup.preview.sampleItems) do
                            ImGui.TableNextRow()
                            
                            ImGui.TableSetColumnIndex(0)
                            if item.section == "AlwaysLoot" then
                                ImGui.TextColored(0.2, 0.8, 0.2, 1, "AlwaysLoot")
                            else
                                ImGui.TextColored(0.2, 0.6, 0.8, 1, "AlwaysLootContains")
                            end
                            
                            ImGui.TableSetColumnIndex(1)
                            ImGui.Text(item.name)
                            
                            ImGui.TableSetColumnIndex(2)
                            if item.willBeSkipped then
                                ImGui.TextColored(0.7, 0.7, 0.7, 1, "Skip")
                                if ImGui.IsItemHovered() then
                                    ImGui.SetTooltip("Already has ItemID rule - won't import")
                                end
                            elseif item.hasConflict then
                                ImGui.TextColored(1.0, 0.8, 0.2, 1, "Overwrite")
                                if ImGui.IsItemHovered() then
                                    ImGui.SetTooltip("Will overwrite existing name-only rule")
                                end
                            else
                                ImGui.TextColored(0.2, 0.8, 0.2, 1, "Import")
                                if ImGui.IsItemHovered() then
                                    ImGui.SetTooltip("New item - will be imported")
                                end
                            end
                            
                            ImGui.TableSetColumnIndex(3)
                            if not item.willBeSkipped then
                                ImGui.TextColored(0.8, 0.6, 0.2, 1, popup.defaultRule or "Keep")
                            else
                                ImGui.TextColored(0.5, 0.5, 0.5, 1, "-")
                            end
                        end
                        
                        ImGui.EndTable()
                    end
                    
                    if popup.preview.totalItems > #popup.preview.sampleItems then
                        ImGui.TextColored(0.7, 0.7, 0.7, 1, 
                            string.format("... and %d more items", 
                            popup.preview.totalItems - #popup.preview.sampleItems))
                    end
                end
                
                -- Show skipped items if there are any
                if popup.preview.skipped and #popup.preview.skipped > 0 then
                    ImGui.Spacing()
                    if ImGui.CollapsingHeader(string.format("Skipped Items (%d) - Already have ItemID rules", #popup.preview.skipped)) then
                        if ImGui.BeginTable("SkippedItemsTable", 3, 
                            ImGuiTableFlags.BordersInnerV + 
                            ImGuiTableFlags.RowBg + 
                            ImGuiTableFlags.ScrollY, 0, 120) then
                            
                            ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                            ImGui.TableSetupColumn("Current Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableSetupColumn("ItemID", ImGuiTableColumnFlags.WidthFixed, 60)
                            ImGui.TableHeadersRow()
                            
                            for _, skipped in ipairs(popup.preview.skipped) do
                                ImGui.TableNextRow()
                                
                                ImGui.TableSetColumnIndex(0)
                                ImGui.TextColored(0.7, 0.7, 0.7, 1, skipped.itemName)
                                
                                ImGui.TableSetColumnIndex(1)
                                ImGui.TextColored(0.6, 0.8, 1.0, 1, skipped.existingRule)
                                
                                ImGui.TableSetColumnIndex(2)
                                ImGui.TextColored(0.8, 0.6, 0.2, 1, tostring(skipped.itemID or "N/A"))
                            end
                            
                            ImGui.EndTable()
                        end
                    end
                end
                
                -- Show conflicts section if there are any
                if popup.preview.conflicts and #popup.preview.conflicts > 0 then
                    ImGui.Spacing()
                    if ImGui.CollapsingHeader(string.format("Conflicting Items (%d) - Will be overwritten", #popup.preview.conflicts)) then
                        if ImGui.BeginTable("ConflictsTable", 4, 
                            ImGuiTableFlags.BordersInnerV + 
                            ImGuiTableFlags.RowBg + 
                            ImGuiTableFlags.ScrollY, 0, 150) then
                            
                            ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                            ImGui.TableSetupColumn("Current Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableSetupColumn("New Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableSetupColumn("Has ItemID", ImGuiTableColumnFlags.WidthFixed, 80)
                            ImGui.TableHeadersRow()
                            
                            for _, conflict in ipairs(popup.preview.conflicts) do
                                ImGui.TableNextRow()
                                
                                ImGui.TableSetColumnIndex(0)
                                ImGui.TextColored(1.0, 0.8, 0.2, 1, conflict.itemName)
                                
                                ImGui.TableSetColumnIndex(1)
                                ImGui.TextColored(0.8, 0.4, 0.4, 1, conflict.existingRule)
                                
                                ImGui.TableSetColumnIndex(2)
                                ImGui.TextColored(0.4, 0.8, 0.4, 1, popup.defaultRule or "Keep")
                                
                                ImGui.TableSetColumnIndex(3)
                                if conflict.hasItemID then
                                    ImGui.TextColored(0.6, 0.8, 1.0, 1, "Yes")
                                    if ImGui.IsItemHovered() then
                                        ImGui.SetTooltip("This rule has an ItemID and is more specific")
                                    end
                                else
                                    ImGui.TextColored(0.7, 0.7, 0.7, 1, "No")
                                end
                            end
                            
                            ImGui.EndTable()
                        end
                        
                        ImGui.Spacing()
                        ImGui.TextColored(1.0, 0.8, 0.2, 1, "⚠ Warning: Import will overwrite the existing rules shown above")
                    end
                end
                
                ImGui.Spacing()
                ImGui.Separator()
                
                -- Import button
                local actualImportCount = popup.preview.totalItems - (popup.preview.skipped and #popup.preview.skipped or 0)
                local canImport = popup.targetCharacter and popup.defaultRule and actualImportCount > 0
                
                if not canImport then
                    ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
                else
                    ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
                end
                
                local buttonText = actualImportCount > 0 and string.format("Review & Import %d Items", actualImportCount) or "Nothing to Import"
                if ImGui.Button(buttonText, 180, 30) and canImport and not popup.showConfirmation then
                    
                    -- Open confirmation popup instead of direct import
                    popup.showConfirmation = true
                    popup.confirmationItems = {}
                    
                    -- Collect all items that will actually be imported (not skipped)
                    if popup.preview and popup.preview.parsedData and popup.preview.parsedData.alwaysLoot then
                        for _, itemName in ipairs(popup.preview.parsedData.alwaysLoot) do
                            local willSkip = false
                            if popup.preview.skipped then
                                for _, skipped in ipairs(popup.preview.skipped) do
                                    if skipped.itemName == itemName then
                                        willSkip = true
                                        break
                                    end
                                end
                            end
                            
                            if not willSkip then
                                table.insert(popup.confirmationItems, {
                                    name = itemName,
                                    section = "AlwaysLoot",
                                    rule = "Keep",
                                    threshold = "",
                                    willImport = true
                                })
                            end
                        end
                    end
                    
                    if popup.preview and popup.preview.parsedData and popup.preview.parsedData.alwaysLootContains then
                        for _, itemName in ipairs(popup.preview.parsedData.alwaysLootContains) do
                            local willSkip = false
                            if popup.preview.skipped then
                                for _, skipped in ipairs(popup.preview.skipped) do
                                    if skipped.itemName == itemName then
                                        willSkip = true
                                        break
                                    end
                                end
                            end
                            
                            if not willSkip then
                                table.insert(popup.confirmationItems, {
                                    name = itemName,
                                    section = "AlwaysLootContains", 
                                    rule = "Keep",
                                    threshold = "",
                                    willImport = true
                                })
                            end
                        end
                    end
                    
                end
                ImGui.PopStyleColor(3)
                
                if not canImport and ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Please select target character and default rule")
                end
                
                -- Show import result
                if popup.importResult then
                    ImGui.SameLine()
                    if popup.importResult.success then
                        ImGui.TextColored(0.2, 0.8, 0.2, 1, 
                            string.format("✓ Imported %d items to %s", 
                            popup.importResult.count, popup.importResult.character))
                    else
                        ImGui.TextColored(1.0, 0.4, 0.4, 1, "✗ " .. (popup.importResult.error or "Import failed"))
                    end
                end
            end
            
            ImGui.Separator()
            
            -- Action buttons
            if ImGui.Button("Close", 100, 0) then
                keepOpen = false
            end
            
            ImGui.SameLine()
            if popup.preview then
                if ImGui.Button("Clear Preview", 120, 0) then
                    popup.preview = nil
                    popup.importResult = nil
                    popup.error = nil
                end
                if ImGui.IsItemHovered() then
                    ImGui.SetTooltip("Clear current preview to select a different file")
                end
            end
            
            ImGui.Spacing()
            
            -- Help text
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Tips:")
            ImGui.BulletText("Only INI files with [AlwaysLoot] and [AlwaysLootContains] sections are supported")
            ImGui.BulletText("Items are imported as name-based rules (no ItemIDs)")
            ImGui.BulletText("Name-based rules will auto-upgrade to ItemID rules when items are encountered in-game")
            ImGui.BulletText("Example path: /mnt/c/MQ-ROF2/Config/e3 Macro Inis/Loot_Stackable_YourChar_Server.ini")
        end
        ImGui.End()
        
        if not keepOpen then
            lootUI.legacyImportPopup.isOpen = false
            -- Clear state when closing
            lootUI.legacyImportPopup.filePath = ""
            lootUI.legacyImportPopup.preview = nil
            lootUI.legacyImportPopup.importResult = nil
            lootUI.legacyImportPopup.error = nil
            lootUI.legacyImportPopup.targetCharacter = nil
            lootUI.legacyImportPopup.defaultRule = nil
        end
    end
    
end

-- Legacy Import Confirmation Popup
function uiPopups.drawLegacyImportConfirmationPopup(lootUI, database, util)
    local popup = lootUI.legacyImportPopup
    if not popup or not popup.showConfirmation or not popup.confirmationItems then
        return
    end
    
    ImGui.SetNextWindowSize(900, 600, ImGuiCond.FirstUseEver)
    -- Center the window (simplified positioning)
    ImGui.SetNextWindowPos(400, 300, ImGuiCond.FirstUseEver)
    
    local confirmKeepOpen = true
    if ImGui.Begin("Confirm Legacy Import", confirmKeepOpen, ImGuiWindowFlags.NoCollapse) then
        ImGui.TextColored(0.4, 0.8, 1.0, 1, "Confirm Import to: %s", popup.targetCharacter)
        ImGui.Separator()
        
        ImGui.Text("Review %d items that will be imported:", #popup.confirmationItems)
        ImGui.Text("You can uncheck items you don't want to import.")
        ImGui.Spacing()
        
        -- Buttons for select all/none
        if ImGui.Button("Select All", 100, 0) then
            for _, item in ipairs(popup.confirmationItems) do
                item.willImport = true
            end
        end
        ImGui.SameLine()
        if ImGui.Button("Select None", 100, 0) then
            for _, item in ipairs(popup.confirmationItems) do
                item.willImport = false
            end
        end
        
        ImGui.Spacing()
        
        -- Table with checkboxes for each item
        if ImGui.BeginTable("ConfirmImportTable", 5, 
            ImGuiTableFlags.BordersInnerV + 
            ImGuiTableFlags.RowBg + 
            ImGuiTableFlags.ScrollY, 0, 400) then
            
            ImGui.TableSetupColumn("Import", ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn("Section", ImGuiTableColumnFlags.WidthFixed, 120)
            ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 120)
            ImGui.TableSetupColumn("Threshold", ImGuiTableColumnFlags.WidthFixed, 80)
            ImGui.TableHeadersRow()
            
            for i, item in ipairs(popup.confirmationItems) do
                ImGui.TableNextRow()
                
                ImGui.TableSetColumnIndex(0)
                -- Use item name hash for stable ID
                local checkboxId = "##import_" .. tostring(item.name):gsub("[^%w]", "_") .. "_" .. i
                local newValue, pressed = ImGui.Checkbox(checkboxId, item.willImport or false)
                if pressed then
                    item.willImport = newValue
                end
                
                ImGui.TableSetColumnIndex(1)
                if item.section == "AlwaysLoot" then
                    ImGui.TextColored(0.2, 0.8, 0.2, 1, item.section)
                else
                    ImGui.TextColored(0.2, 0.6, 0.8, 1, item.section)
                end
                
                ImGui.TableSetColumnIndex(2)
                if item.willImport then
                    ImGui.Text(item.name)
                else
                    ImGui.TextColored(0.6, 0.6, 0.6, 1, item.name)
                end
                
                ImGui.TableSetColumnIndex(3)
                if item.willImport then
                    ImGui.SetNextItemWidth(110)
                    local comboId = "##rule_" .. tostring(item.name):gsub("[^%w]", "_") .. "_" .. i
                    if ImGui.BeginCombo(comboId, item.rule) then
                        for _, rule in ipairs({"Keep", "KeepIfFewerThan", "Ignore"}) do
                            local isSelected = (item.rule == rule)
                            if ImGui.Selectable(rule, isSelected) then
                                item.rule = rule
                                if rule == "Keep" or rule == "Ignore" then
                                    item.threshold = ""
                                end
                            end
                            if isSelected then
                                ImGui.SetItemDefaultFocus()
                            end
                        end
                        ImGui.EndCombo()
                    end
                else
                    ImGui.TextColored(0.5, 0.5, 0.5, 1, item.rule)
                end
                
                ImGui.TableSetColumnIndex(4)
                if item.willImport and item.rule == "KeepIfFewerThan" then
                    ImGui.SetNextItemWidth(70)
                    local thresholdId = "##threshold_" .. tostring(item.name):gsub("[^%w]", "_") .. "_" .. i
                    local changed, newThreshold = ImGui.InputText(thresholdId, item.threshold or "")
                    if changed then
                        item.threshold = newThreshold
                    end
                elseif item.willImport then
                    ImGui.TextColored(0.5, 0.5, 0.5, 1, "-")
                else
                    ImGui.TextColored(0.5, 0.5, 0.5, 1, "-")
                end
            end
            
            ImGui.EndTable()
        end
        
        ImGui.Spacing()
        ImGui.Separator()
        
        -- Count selected items
        local selectedCount = 0
        for _, item in ipairs(popup.confirmationItems) do
            if item.willImport then
                selectedCount = selectedCount + 1
            end
        end
        
        ImGui.Text("Selected: %d of %d items", selectedCount, #popup.confirmationItems)
        
        ImGui.Spacing()
        
        -- Action buttons
        if selectedCount > 0 then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.8, 0.2, 0.8)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.9, 0.3, 0.8)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.7, 0.1, 0.8)
        else
            ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 1)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 1)
        end
        
        if ImGui.Button(string.format("Import %d Items", selectedCount), 150, 30) and selectedCount > 0 then
            -- Create filtered list of items to import with custom rules
            local itemsToImport = {
                alwaysLoot = {},
                alwaysLootContains = {},
                customRules = {}  -- Store individual item rules
            }
            
            local allItemNames = {}  -- Collect all items for inventory scan
            
            for _, item in ipairs(popup.confirmationItems) do
                if item.willImport then
                    local finalRule = item.rule
                    if item.rule == "KeepIfFewerThan" and item.threshold and item.threshold ~= "" then
                        finalRule = "KeepIfFewerThan|" .. item.threshold
                    end
                    
                    itemsToImport.customRules[item.name] = finalRule
                    table.insert(allItemNames, item.name)
                    
                    if item.section == "AlwaysLoot" then
                        table.insert(itemsToImport.alwaysLoot, item.name)
                    else
                        table.insert(itemsToImport.alwaysLootContains, item.name)
                    end
                end
            end
            
            -- Scan inventory for ItemIDs and IconIDs
            itemsToImport.inventoryData = database.scanInventoryForItems(allItemNames)
            
            -- Perform the actual import
            local success, importCount = database.importLegacyLootRules(
                itemsToImport, 
                popup.targetCharacter, 
                "Keep", -- Default rule (not used when customRules provided)
                popup.preview.fileName
            )
            
            if success then
                popup.importResult = {
                    success = true,
                    count = importCount,
                    character = popup.targetCharacter
                }
                
                -- Refresh cache for target character
                local currentChar = mq.TLO.Me.Name()
                if popup.targetCharacter == currentChar then
                    database.refreshLootRuleCache()
                else
                    database.refreshLootRuleCacheForPeer(popup.targetCharacter)
                end
                
            else
                popup.importResult = {
                    success = false,
                    error = "Import failed. Check logs for details."
                }
            end
            
            -- Close confirmation popup
            popup.showConfirmation = false
            popup.confirmationItems = nil
        end
        ImGui.PopStyleColor(3)
        
        ImGui.SameLine()
        if ImGui.Button("Cancel", 100, 30) then
            popup.showConfirmation = false
            popup.confirmationItems = nil
        end
        
    end
    ImGui.End()
    
    if not confirmKeepOpen then
        popup.showConfirmation = false
        popup.confirmationItems = nil
    end
end

-- Remote Pending Decision Popup - for foreground character to handle decisions from background peers
function uiPopups.drawRemotePendingDecisionsPopup(lootUI, database, util)
    local remoteDecisions = _G.SMARTLOOT_REMOTE_DECISIONS or {}
    
    -- Debug: check remote decision queue
    if #remoteDecisions > 0 then
        local logging = require("modules.logging")
        local isForeground = util.isForeground()
        logging.debug(string.format("[RemotePopup] Have %d remote decisions, isForeground=%s", #remoteDecisions, tostring(isForeground)))
    end
    
    -- Only show on foreground character
    if not util.isForeground() then return end
    if #remoteDecisions == 0 then return end
    
    -- Initialize assignment state per decision
    lootUI.remotePendingAssignments = lootUI.remotePendingAssignments or {}
    for i, decision in ipairs(remoteDecisions) do
        if not lootUI.remotePendingAssignments[i] then
            lootUI.remotePendingAssignments[i] = {
                rule = "Keep",
                threshold = 1
            }
        end
    end

    local function formatCurrencyValue(valueInCopper)
        local value = tonumber(valueInCopper) or 0
        local platinum = math.floor(value / 1000)
        local gold = math.floor((value % 1000) / 100)
        local silver = math.floor((value % 100) / 10)
        local copper = value % 10

        if platinum > 0 then
            local text = string.format("%dp", platinum)
            if gold > 0 then text = text .. string.format(" %dg", gold) end
            return text
        elseif gold > 0 then
            local text = string.format("%dg", gold)
            if silver > 0 then text = text .. string.format(" %ds", silver) end
            return text
        elseif silver > 0 then
            local text = string.format("%ds", silver)
            if copper > 0 then text = text .. string.format(" %dc", copper) end
            return text
        end

        return string.format("%dc", copper)
    end
    
    ImGui.SetNextWindowSize(1080, 450, ImGuiCond.FirstUseEver)
    local keepOpen, shown = ImGui.Begin("SmartLoot - Remote Pending Decisions", true)
    
    if shown then
        -- Header
        ImGui.TextColored(1, 0.5, 0, 1, "Pending requests from peers (%d items)", #remoteDecisions)
        ImGui.Separator()
        ImGui.Spacing()
        
        -- Scrollable table
        local remoteListVisible = ImGui.BeginChild("RemotePendingList", 0, -50)
        if remoteListVisible then
            local tableFlags = ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.ScrollY
            local toonName = mq.TLO.Me.Name() or "unknown"
            local useButtons = config.isUseRemotePendingDecisionButtons and config.isUseRemotePendingDecisionButtons(toonName) or false
            local showValue = config.isShowRemotePendingDecisionValue and config.isShowRemotePendingDecisionValue(toonName) or true
            local showTribute = config.isShowRemotePendingDecisionTribute and config.isShowRemotePendingDecisionTribute(toonName) or true
            local columnCount = 6
            if showValue then columnCount = columnCount + 1 end
            if showTribute then columnCount = columnCount + 1 end

            if ImGui.BeginTable("RemotePendingTable", columnCount, tableFlags) then
                ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 100)
                ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 35)
                ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Item ID", ImGuiTableColumnFlags.WidthFixed, 80)
                if showValue then
                    ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.WidthFixed, 90)
                end
                if showTribute then
                    ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.WidthFixed, 80)
                end
                ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 180)
                ImGui.TableSetupColumn("Threshold", ImGuiTableColumnFlags.WidthFixed, 90)
                ImGui.TableHeadersRow()
                
                local uiUtils = require("smartloot.ui.ui_utils")

                for i, decision in ipairs(remoteDecisions) do
                    ImGui.TableNextRow()

                    local assignment = lootUI.remotePendingAssignments[i]

                    -- Column 1: Peer/Requester
                    ImGui.TableSetColumnIndex(0)
                    ImGui.TextColored(1, 0.5, 0, 1, decision.requester)

                    -- Column 2: Icon
                    ImGui.TableSetColumnIndex(1)
                    uiUtils.drawItemIcon(decision.iconID or 0)

                    -- Column 3: Item Name
                    ImGui.TableSetColumnIndex(2)
                    ImGui.TextColored(1, 1, 0, 1, decision.itemName)

                    -- Column 4: Item ID
                    ImGui.TableSetColumnIndex(3)
                    ImGui.Text(tostring(decision.itemID or 0))

                    local ruleColumnIndex = 4
                    if showValue then
                        ImGui.TableSetColumnIndex(ruleColumnIndex)
                        ImGui.Text(formatCurrencyValue(decision.itemValue or 0))
                        ruleColumnIndex = ruleColumnIndex + 1
                    end

                    if showTribute then
                        ImGui.TableSetColumnIndex(ruleColumnIndex)
                        ImGui.Text(tostring(decision.tributeValue or 0))
                        ruleColumnIndex = ruleColumnIndex + 1
                    end

                    -- Rule selection (dropdown or buttons based on config)
                    ImGui.TableSetColumnIndex(ruleColumnIndex)

                    if useButtons then
                        -- Button mode: row of small buttons
                        local buttonRules = {
                            {rule = "Keep", label = "Keep", width = 32},
                            {rule = "Ignore", label = "Ign", width = 28},
                            {rule = "Destroy", label = "Des", width = 28},
                            {rule = "KeepIfFewerThan", label = "K<N", width = 28},
                            {rule = "KeepThenIgnore", label = "KTI", width = 28}
                        }
                        for bi, btn in ipairs(buttonRules) do
                            if bi > 1 then ImGui.SameLine() end
                            local isSelected = (assignment.rule == btn.rule)
                            if isSelected then
                                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 1.0)
                            end
                            if ImGui.Button(btn.label .. "##btn_" .. i .. "_" .. bi, btn.width, 0) then
                                assignment.rule = btn.rule
                            end
                            if isSelected then
                                ImGui.PopStyleColor()
                            end
                            if ImGui.IsItemHovered() then
                                ImGui.SetTooltip(btn.rule)
                            end
                        end
                    else
                        -- Dropdown mode (default)
                        ImGui.SetNextItemWidth(-1)
                        if ImGui.BeginCombo("##remoteRule_" .. i, assignment.rule) then
                            for _, rule in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}) do
                                local isSelected = (assignment.rule == rule)
                                if ImGui.Selectable(rule .. "##sel_" .. i, isSelected) then
                                    assignment.rule = rule
                                end
                                if isSelected then
                                    ImGui.SetItemDefaultFocus()
                                end
                            end
                            ImGui.EndCombo()
                        end
                    end
                    
                    ImGui.TableSetColumnIndex(ruleColumnIndex + 1)
                    if assignment.rule == "KeepIfFewerThan" or assignment.rule == "KeepThenIgnore" then
                        ImGui.SetNextItemWidth(-1)
                        local newThreshold, changed = ImGui.InputInt("##remoteThreshold_" .. i, assignment.threshold)
                        if changed then
                            assignment.threshold = math.max(1, newThreshold)
                        end
                    else
                        ImGui.TextDisabled("N/A")
                    end
                end
                
                ImGui.EndTable()
            end
        end
        ImGui.EndChild()
        
        ImGui.Separator()
        
        -- Helper to build rule string
        local function getFinalRule(assignment)
            if assignment.rule == "KeepIfFewerThan" then
                return "KeepIfFewerThan:" .. assignment.threshold
            elseif assignment.rule == "KeepThenIgnore" then
                return "KeepIfFewerThan:" .. assignment.threshold .. ":AutoIgnore"
            else
                return assignment.rule
            end
        end
        
        -- Action buttons
        local Icons = require("mq.Icons")

        local toonName = mq.TLO.Me.Name() or "unknown"
        local actionLayout = config.getRemotePendingDecisionActionLayout and config.getRemotePendingDecisionActionLayout(toonName) or "selector"
        local quickButtons = config.getRemotePendingDecisionQuickButtons and config.getRemotePendingDecisionQuickButtons(toonName) or {
            allKeep = true,
            allIgnore = true,
            meKeep = true,
            meIgnore = true,
        }

        local function processRemoteDecisions(ruleResolver, applyToAllPeers)
            local actors = require("actors")
            local json = require("dkjson")
            local connectedPeers = applyToAllPeers and util.getConnectedPeers() or nil

            for i, decision in ipairs(remoteDecisions) do
                local assignment = lootUI.remotePendingAssignments[i]
                local rule = ruleResolver(assignment, decision)

                if applyToAllPeers then
                    for _, peer in ipairs(connectedPeers) do
                        database.saveLootRuleFor(peer, decision.itemName, decision.itemID, rule, decision.iconID)
                        util.sendPeerCommandViaActor(peer, "reload_rules")
                    end
                else
                    database.saveLootRuleFor(decision.requester, decision.itemName, decision.itemID, rule, decision.iconID)
                    util.sendPeerCommandViaActor(decision.requester, "reload_rules")
                end

                pcall(function()
                    local responseData = {
                        cmd = "pending_decision_response",
                        sender = mq.TLO.Me.Name(),
                        itemName = decision.itemName,
                        itemID = decision.itemID,
                        iconID = decision.iconID,
                        rule = rule
                    }
                    actors.send(
                        { mailbox = "smartloot_mailbox" },
                        json.encode(responseData)
                    )
                end)

                pcall(function()
                    local clearData = {
                        cmd = "clear_remote_decision",
                        sender = mq.TLO.Me.Name(),
                        requester = decision.requester,
                        itemName = decision.itemName,
                        itemID = decision.itemID
                    }
                    actors.send(
                        { mailbox = "smartloot_mailbox" },
                        json.encode(clearData)
                    )
                end)

                if applyToAllPeers then
                    logging.debug(string.format("Applied rule '%s' for '%s' to all peers", rule, decision.itemName))
                else
                    logging.debug(string.format("Applied rule '%s' for '%s' to %s", rule, decision.itemName, decision.requester))
                end
            end

            _G.SMARTLOOT_REMOTE_DECISIONS = {}
            lootUI.remotePendingAssignments = {}
        end

        local function drawStyledActionButton(label, width, colors, onClick, tooltip)
            ImGui.PushStyleColor(ImGuiCol.Button, colors[1], colors[2], colors[3], colors[4])
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, colors[5], colors[6], colors[7], colors[8])
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, colors[9], colors[10], colors[11], colors[12])
            if ImGui.Button(label, width, 30) then
                onClick()
            end
            if tooltip and ImGui.IsItemHovered() then
                ImGui.SetTooltip(tooltip)
            end
            ImGui.PopStyleColor(3)
        end

        if actionLayout == "quick_buttons" then
            local quickActionButtons = {
                {
                    enabled = quickButtons.allKeep,
                    label = "All Keep",
                    width = 120,
                    colors = {0.2, 0.7, 0.2, 0.95, 0.3, 0.8, 0.3, 1.0, 0.1, 0.5, 0.1, 1.0},
                    onClick = function()
                        processRemoteDecisions(function()
                            return "Keep"
                        end, true)
                    end,
                    tooltip = "Apply Keep to all pending items for every connected peer",
                },
                {
                    enabled = quickButtons.allIgnore,
                    label = "All Ignore",
                    width = 125,
                    colors = {0.75, 0.55, 0.2, 0.95, 0.85, 0.65, 0.3, 1.0, 0.6, 0.45, 0.1, 1.0},
                    onClick = function()
                        processRemoteDecisions(function()
                            return "Ignore"
                        end, true)
                    end,
                    tooltip = "Apply Ignore to all pending items for every connected peer",
                },
                {
                    enabled = quickButtons.meKeep,
                    label = "Peer Keep",
                    width = 120,
                    colors = {0.2, 0.5, 0.8, 0.95, 0.3, 0.6, 0.9, 1.0, 0.1, 0.4, 0.7, 1.0},
                    onClick = function()
                        processRemoteDecisions(function()
                            return "Keep"
                        end, false)
                    end,
                    tooltip = "Apply Keep to each requesting peer only",
                },
                {
                    enabled = quickButtons.meIgnore,
                    label = "Peer Ignore",
                    width = 125,
                    colors = {0.55, 0.45, 0.75, 0.95, 0.65, 0.55, 0.85, 1.0, 0.45, 0.35, 0.65, 1.0},
                    onClick = function()
                        processRemoteDecisions(function()
                            return "Ignore"
                        end, false)
                    end,
                    tooltip = "Apply Ignore to each requesting peer only",
                },
            }

            local drewButton = false
            for _, button in ipairs(quickActionButtons) do
                if button.enabled then
                    if drewButton then
                        ImGui.SameLine()
                    end
                    drawStyledActionButton(button.label, button.width, button.colors, button.onClick, button.tooltip)
                    drewButton = true
                end
            end
        else
            if ImGui.Button(Icons.FA_CHECK_CIRCLE .. " Apply All Rules", 180, 30) then
                processRemoteDecisions(function(assignment)
                    return getFinalRule(assignment)
                end, false)
            end

            ImGui.SameLine()

            if ImGui.Button(Icons.FA_USERS .. " Apply To All Peers", 180, 30) then
                processRemoteDecisions(function(assignment)
                    return getFinalRule(assignment)
                end, true)
            end
        end
        
        ImGui.SameLine()
        
        -- Clear All button
        if ImGui.Button(Icons.FA_TRASH .. " Clear All", 140, 30) then
            _G.SMARTLOOT_REMOTE_DECISIONS = {}
            lootUI.remotePendingAssignments = {}
            util.printSmartLoot("Cleared all pending decisions", "warning")
        end
        
        ImGui.SameLine()
        
        -- Close button
        if ImGui.Button(Icons.FA_TIMES .. " Close", 100, 30) then
            keepOpen = false
        end
    end
    
    ImGui.End()
end

-- Remote Batch Unknown Review Popup - for foreground character to handle batch unknown reviews from background peers
function uiPopups.drawRemoteBatchUnknownReviewPopup(lootUI, databaseRef, utilRef)
    -- Only show on foreground character
    if not utilRef.isForeground() then return end

    local remoteBatch = _G.SMARTLOOT_REMOTE_BATCH_UNKNOWN or {}
    if #remoteBatch == 0 then return end

    -- Build flat list of all items from all requesters, tracking which requester each item came from
    local allItems = {}
    for _, batch in ipairs(remoteBatch) do
        for _, item in ipairs(batch.items or {}) do
            table.insert(allItems, {
                requester = batch.requester,
                item = item,
                key = (item.itemName or "") .. "_" .. (item.itemID or 0) .. "_" .. batch.requester
            })
        end
    end

    if #allItems == 0 then return end

    -- Initialize selections per unique key
    lootUI.remoteBatchUnknownSelections = lootUI.remoteBatchUnknownSelections or {}
    lootUI.remoteBatchUnknownThresholds = lootUI.remoteBatchUnknownThresholds or {}

    for _, entry in ipairs(allItems) do
        local key = entry.key
        if not lootUI.remoteBatchUnknownSelections[key] then
            lootUI.remoteBatchUnknownSelections[key] = config.getDefaultPromptDropdown and config.getDefaultPromptDropdown(mq.TLO.Me.Name()) or "Keep"
        end
        if not lootUI.remoteBatchUnknownThresholds[key] then
            lootUI.remoteBatchUnknownThresholds[key] = 1
        end
    end

    ImGui.SetNextWindowSize(1180, 540, ImGuiCond.FirstUseEver)
    local keepOpen = ImGui.Begin("SmartLoot - Remote Batch Unknown Review", true)
    if not keepOpen then
        ImGui.End()
        return
    end

    ImGui.TextColored(1, 0.5, 0, 1, "Batch unknown review requests from peers (%d items from %d peer(s))", #allItems, #remoteBatch)
    ImGui.Separator()

    local flags = bit32.bor(
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.SizingStretchProp
    )

    if ImGui.BeginTable("SL_RemoteBatchUnknownReview", 9, flags, 0, 360) then
        ImGui.TableSetupColumn("Peer", ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableSetupColumn("Icon", ImGuiTableColumnFlags.WidthFixed, 34)
        ImGui.TableSetupColumn("Item", ImGuiTableColumnFlags.WidthStretch, 2.0)
        ImGui.TableSetupColumn("Corpses", ImGuiTableColumnFlags.WidthStretch, 1.6)
        ImGui.TableSetupColumn("Seen", ImGuiTableColumnFlags.WidthFixed, 42)
        ImGui.TableSetupColumn("Vendor", ImGuiTableColumnFlags.WidthFixed, 78)
        ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.WidthFixed, 72)
        ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthStretch, 1.5)
        ImGui.TableSetupColumn("Threshold", ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableHeadersRow()

        for i, entry in ipairs(allItems) do
            local item = entry.item
            local key = entry.key
            local selection = lootUI.remoteBatchUnknownSelections[key] or "Keep"
            local threshold = lootUI.remoteBatchUnknownThresholds[key] or 1

            ImGui.TableNextRow()

            ImGui.TableSetColumnIndex(0)
            ImGui.TextColored(0.6, 0.8, 1.0, 1.0, entry.requester or "")

            ImGui.TableSetColumnIndex(1)
            uiUtils.drawItemIcon(item.iconID or 0)

            ImGui.TableSetColumnIndex(2)
            ImGui.Text(item.itemName or "")
            ImGui.TextDisabled("ID: %d", tonumber(item.itemID) or 0)

            ImGui.TableSetColumnIndex(3)
            local corpseSummary = "Unknown"
            if item.corpseRefs and #item.corpseRefs > 0 then
                corpseSummary = item.corpseRefs[1].corpseName or "Unknown"
                if #item.corpseRefs > 1 then
                    corpseSummary = string.format("%s (+%d)", corpseSummary, #item.corpseRefs - 1)
                end
            end
            ImGui.TextWrapped(corpseSummary)

            ImGui.TableSetColumnIndex(4)
            ImGui.Text(tostring(item.occurrenceCount or #(item.corpseRefs or {})))

            ImGui.TableSetColumnIndex(5)
            ImGui.Text(formatCopperValue(item.itemValue or 0))

            ImGui.TableSetColumnIndex(6)
            ImGui.Text(tostring(item.tributeValue or 0))

            ImGui.TableSetColumnIndex(7)
            ImGui.SetNextItemWidth(-1)
            if ImGui.BeginCombo("##remoteBatchRule_" .. i, selection) then
                for _, rule in ipairs({"Keep", "Ignore", "Destroy", "KeepIfFewerThan", "KeepThenIgnore"}) do
                    local isSelected = (selection == rule)
                    if ImGui.Selectable(rule .. "##rb_" .. i, isSelected) then
                        lootUI.remoteBatchUnknownSelections[key] = rule
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end

            ImGui.TableSetColumnIndex(8)
            local currentSelection = lootUI.remoteBatchUnknownSelections[key]
            if currentSelection == "KeepIfFewerThan" or currentSelection == "KeepThenIgnore" then
                ImGui.SetNextItemWidth(-1)
                local newThresh, changed = ImGui.InputInt("##rbThresh_" .. i, threshold)
                if changed then
                    lootUI.remoteBatchUnknownThresholds[key] = math.max(1, newThresh)
                end
            else
                ImGui.TextDisabled("N/A")
            end
        end

        ImGui.EndTable()
    end

    ImGui.Separator()

    -- Helper to build final rule string
    local function getFinalRule(key)
        local sel = lootUI.remoteBatchUnknownSelections[key] or "Keep"
        local thresh = lootUI.remoteBatchUnknownThresholds[key] or 1
        if sel == "KeepIfFewerThan" then
            return "KeepIfFewerThan:" .. thresh
        elseif sel == "KeepThenIgnore" then
            return "KeepIfFewerThan:" .. thresh .. ":AutoIgnore"
        else
            return sel
        end
    end

    -- Quick action buttons
    if ImGui.Button("Apply All Keep", 140, 30) then
        for key, _ in pairs(lootUI.remoteBatchUnknownSelections) do
            lootUI.remoteBatchUnknownSelections[key] = "Keep"
        end
    end
    ImGui.SameLine()
    if ImGui.Button("Apply All Ignore", 150, 30) then
        for key, _ in pairs(lootUI.remoteBatchUnknownSelections) do
            lootUI.remoteBatchUnknownSelections[key] = "Ignore"
        end
    end

    ImGui.SameLine()

    -- Complete button - send responses to each requester
    if ImGui.Button("Complete & Send Decisions", 200, 30) then
        local actors = require("actors")
        local json = require("dkjson")

        -- Group items by requester
        local decisionsByRequester = {}
        for _, entry in ipairs(allItems) do
            local requester = entry.requester
            local item = entry.item
            local key = entry.key
            if not decisionsByRequester[requester] then
                decisionsByRequester[requester] = {}
            end
            table.insert(decisionsByRequester[requester], {
                itemName = item.itemName,
                itemID = item.itemID,
                iconID = item.iconID,
                rule = getFinalRule(key)
            })
        end

        -- Send response to each requester
        for requester, decisions in pairs(decisionsByRequester) do
            pcall(function()
                local responseData = {
                    cmd = "batch_unknown_review_response",
                    sender = mq.TLO.Me.Name(),
                    requester = requester,
                    decisions = decisions
                }
                actors.send(
                    { mailbox = "smartloot_mailbox" },
                    json.encode(responseData)
                )
            end)
            logging.debug(string.format("[RemoteBatch] Sent %d decisions to %s", #decisions, requester))
        end

        _G.SMARTLOOT_REMOTE_BATCH_UNKNOWN = {}
        lootUI.remoteBatchUnknownSelections = {}
        lootUI.remoteBatchUnknownThresholds = {}
        utilRef.printSmartLoot("Remote batch unknown review completed and decisions sent", "success")
    end

    ImGui.SameLine()

    -- Cancel / Clear button
    if ImGui.Button("Cancel & Clear", 140, 30) then
        _G.SMARTLOOT_REMOTE_BATCH_UNKNOWN = {}
        lootUI.remoteBatchUnknownSelections = {}
        lootUI.remoteBatchUnknownThresholds = {}
        utilRef.printSmartLoot("Remote batch unknown review cancelled", "warning")
    end

    ImGui.End()
end

function uiPopups.drawGettingStartedPopup(lootUI)
    if lootUI.showGettingStartedPopup then
        ImGui.SetNextWindowSize(700, 600, ImGuiCond.FirstUseEver)
        local visible, keepOpen = ImGui.Begin("SmartLoot - Getting Started Guide", lootUI.showGettingStartedPopup)

        if visible then
            -- Welcome header with a nice color
            ImGui.PushStyleColor(ImGuiCol.Text, 0.4, 0.8, 1.0, 1.0) -- Light blue
            ImGui.Text("Welcome to SmartLoot!")
            ImGui.PopStyleColor()
            ImGui.Separator()
            
            -- Softer white for main description text
            ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.9, 1.0) -- Soft white
            ImGui.TextWrapped("This guide will help you get set up and looting in no time.")
            ImGui.PopStyleColor()

            if ImGui.CollapsingHeader("Overview") then
                -- Slightly dimmed text for readability
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("SmartLoot is an intelligent auto-looting system that:")
                ImGui.PopStyleColor()
                
                -- Bullet points in a pleasant green
                ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.9, 0.7, 1.0) -- Light green
                ImGui.BulletText("Automatically loots corpses based on your predefined rules - if an item does not have a rule set, it will prompt you for a decision")
                ImGui.BulletText("Coordinates your looting order with other characters to avoid conflicts and corpse race conditions")
                ImGui.BulletText("Tracks loot history and statistics")
                ImGui.PopStyleColor()
            end

            if ImGui.CollapsingHeader("Quick Setup") then
                -- Step numbers in a nice orange
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.4, 1.0) -- Light orange
                ImGui.TextWrapped("1. Open UI: /smartloot, or left click the floating 'SL' button")
                ImGui.TextWrapped("2. Go to Peer Loot Order tab")
                ImGui.TextWrapped("3. Set a Looting Order based on priority - the first on the list will load as your 'Main' Looter")
                ImGui.TextWrapped("4. Go to the Settings Tab")
                ImGui.TextWrapped("5. Configure Behavior:")
                ImGui.PopStyleColor()
                
                ImGui.Indent()
                -- Sub-bullets in a softer blue
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 1.0, 1.0) -- Light blue
                ImGui.BulletText("Peer Coordination - This will determine how commands are sent between clients")
                ImGui.BulletText("Chat Output Settings - This will determine how you announce things")
                ImGui.BulletText("Chase Integration - if you use a chase module that leashes characters, you'll need to pause")
                ImGui.PopStyleColor()
                
                ImGui.Indent()
                ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.8, 0.8, 1.0) -- Dim gray for continuation
                ImGui.TextWrapped("or stop chasing/auto following so they can navigate to corpses")
                ImGui.PopStyleColor()
                ImGui.Unindent()
                ImGui.Unindent()
            end

            if ImGui.CollapsingHeader("Loot Rules") then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("Go to 'Loot Rules' tab to set up item rules")
                ImGui.PopStyleColor()
                
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.7, 0.9, 1.0) -- Light purple
                ImGui.BulletText("Rules: Keep, Ignore, Destroy, or assign to specific character")
                ImGui.BulletText("Use search and filters to find items quickly")
                ImGui.BulletText("Add rules as you encounter new items")
                ImGui.PopStyleColor()
            end

            if ImGui.CollapsingHeader("Basic Usage") then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.85, 0.85, 0.85, 1.0) -- Light gray
                ImGui.TextWrapped("Start script: /lua run smartloot")
                ImGui.PopStyleColor()
                
                ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.9, 0.7, 1.0) -- Light yellow
                ImGui.BulletText("Manual loot: /sl_doloot")
                ImGui.BulletText("Pause/Resume: /sl_pause")
                ImGui.BulletText("Emergency stop: /sl_emergency_stop")
                ImGui.PopStyleColor()
            end

            ImGui.Spacing()
            if ImGui.Button("Close", 100, 30) then
                lootUI.showGettingStartedPopup = false
            end
        end
        ImGui.End()
        lootUI.showGettingStartedPopup = keepOpen and visible
    end
end

-- Bulk Copy Rules Popup
function uiPopups.drawBulkCopyRulesPopup(lootUI, database, util)
    if lootUI.bulkCopyRulesPopup and lootUI.bulkCopyRulesPopup.isOpen then
        ImGui.SetNextWindowSize(700, 600, ImGuiCond.FirstUseEver)
        local keepOpen = true
        local open, p_open = ImGui.Begin("Bulk Copy Rules", true)
        
        if open then
            ImGui.Text("Copy all loot rules from one character to another")
            ImGui.Separator()
            
            -- Get all characters with rules
            if not lootUI.bulkCopyRulesPopup.allCharacters or #lootUI.bulkCopyRulesPopup.allCharacters == 0 then
                lootUI.bulkCopyRulesPopup.allCharacters = database.getAllCharactersWithRules() or {}
            end
            
            local characters = lootUI.bulkCopyRulesPopup.allCharacters
            local charNames = {}
            for _, char in ipairs(characters) do
                table.insert(charNames, char)
            end
            table.sort(charNames)
            
            -- Source character dropdown
            ImGui.Text("Source Character:")
            ImGui.SameLine(200)
            if ImGui.BeginCombo("##sourceChar", lootUI.bulkCopyRulesPopup.sourceCharacter or "Select...", ImGuiComboFlags.HeightLarge) then
                for _, charName in ipairs(charNames) do
                    local isSelected = (charName == lootUI.bulkCopyRulesPopup.sourceCharacter)
                    if ImGui.Selectable(charName, isSelected) then
                        lootUI.bulkCopyRulesPopup.sourceCharacter = charName
                        lootUI.bulkCopyRulesPopup.previewRules = nil  -- Clear preview
                    end
                    if isSelected then
                        ImGui.SetItemDefaultFocus()
                    end
                end
                ImGui.EndCombo()
            end
            
            -- Target character dropdown
            ImGui.Text("Target Character:")
            ImGui.SameLine(200)
            if ImGui.BeginCombo("##targetChar", lootUI.bulkCopyRulesPopup.targetCharacter or "Select...", ImGuiComboFlags.HeightLarge) then
                for _, charName in ipairs(charNames) do
                    -- Don't allow selecting source as target
                    if charName ~= lootUI.bulkCopyRulesPopup.sourceCharacter then
                        local isSelected = (charName == lootUI.bulkCopyRulesPopup.targetCharacter)
                        if ImGui.Selectable(charName, isSelected) then
                            lootUI.bulkCopyRulesPopup.targetCharacter = charName
                            lootUI.bulkCopyRulesPopup.previewRules = nil  -- Clear preview
                        end
                        if isSelected then
                            ImGui.SetItemDefaultFocus()
                        end
                    end
                end
                ImGui.EndCombo()
            end
            
            ImGui.Spacing()
            
            -- Preview button
            if ImGui.Button("Preview Rules##preview", 120, 0) then
                if lootUI.bulkCopyRulesPopup.sourceCharacter and lootUI.bulkCopyRulesPopup.sourceCharacter ~= "" then
                    lootUI.bulkCopyRulesPopup.previewRules = database.getLootRulesByCharacter(lootUI.bulkCopyRulesPopup.sourceCharacter)
                else
                    lootUI.bulkCopyRulesPopup.copyResult = "Please select a source character"
                end
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Load and display all rules for the selected source character")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Rules preview
            ImGui.Text("Rules Preview:")
            ImGui.TextColored(0.7, 0.7, 0.7, 1, "Items to be copied:")
            
            if lootUI.bulkCopyRulesPopup.previewRules then
                local rulesData = lootUI.bulkCopyRulesPopup.previewRules
                local totalRules = 0
                local addedRules = 0
                local changedRules = 0
                
                -- Get target character's existing rules for comparison
                local targetRules = {}
                if lootUI.bulkCopyRulesPopup.targetCharacter and lootUI.bulkCopyRulesPopup.targetCharacter ~= "" then
                    local targetRulesData = database.getLootRulesByCharacter(lootUI.bulkCopyRulesPopup.targetCharacter)
                    if targetRulesData.rules then
                        for _, rule in ipairs(targetRulesData.rules) do
                            local key = (rule.itemId and rule.itemId > 0) and tostring(rule.itemId) or rule.itemName
                            targetRules[key] = rule.rule
                        end
                    end
                end
                
                if ImGui.BeginTable("previewRulesTable", 3, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                    ImGui.TableSetupColumn("Item Name", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableSetupColumn("Item ID", ImGuiTableColumnFlags.WidthFixed, 80)
                    ImGui.TableSetupColumn("Rule", ImGuiTableColumnFlags.WidthFixed, 80)
                    ImGui.TableHeadersRow()
                    
                    -- Display rules
                    if rulesData.rules then
                        for _, rule in ipairs(rulesData.rules) do
                            local key = (rule.itemId and rule.itemId > 0) and tostring(rule.itemId) or rule.itemName
                            local existingRule = targetRules[key]
                            local isNew = not existingRule
                            local isChanged = existingRule and existingRule ~= rule.rule
                            
                            -- Determine row color
                            local rowColor = nil
                            local colorR, colorG, colorB, colorA = 1, 1, 1, 1
                            if isNew then
                                colorR, colorG, colorB, colorA = 0.2, 0.5, 0.2, 0.3  -- Green for new rules
                                rowColor = true
                                addedRules = addedRules + 1
                            elseif isChanged then
                                colorR, colorG, colorB, colorA = 0.5, 0.4, 0.2, 0.3  -- Orange/Yellow for changed rules
                                rowColor = true
                                changedRules = changedRules + 1
                            end
                            
                            ImGui.TableNextRow()
                            
                            -- Set row background color if needed
                            if rowColor then
                                ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, ImGui.GetColorU32(colorR, colorG, colorB, colorA))
                            end
                            
                            ImGui.TableSetColumnIndex(0)
                            ImGui.Text(rule.itemName or "Unknown")
                            
                            ImGui.TableSetColumnIndex(1)
                            if rule.itemId and rule.itemId > 0 then
                                ImGui.Text(tostring(rule.itemId))
                            else
                                ImGui.TextColored(0.6, 0.6, 0.6, 1, "N/A")
                            end
                            
                            ImGui.TableSetColumnIndex(2)
                            if isChanged then
                                ImGui.TextColored(1.0, 0.7, 0.2, 1, rule.rule .. " (was: " .. existingRule .. ")")
                            else
                                ImGui.Text(rule.rule or "Unknown")
                            end
                            
                            totalRules = totalRules + 1
                        end
                    end
                    
                    ImGui.EndTable()
                end
                
                ImGui.Spacing()
                ImGui.TextColored(0.7, 1.0, 0.7, 1, "Total Rules: " .. totalRules)
                if addedRules > 0 then
                    ImGui.SameLine()
                    ImGui.TextColored(0.3, 0.8, 0.3, 1, " | New: " .. addedRules)
                end
                if changedRules > 0 then
                    ImGui.SameLine()
                    ImGui.TextColored(1.0, 0.7, 0.2, 1, " | Changed: " .. changedRules)
                end
            else
                ImGui.TextColored(0.6, 0.6, 0.6, 1, "Click 'Preview Rules' to see what will be copied")
            end
            
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Spacing()
            
            -- Result message
            if lootUI.bulkCopyRulesPopup.copyResult and lootUI.bulkCopyRulesPopup.copyResult ~= "" then
                if string.match(lootUI.bulkCopyRulesPopup.copyResult, "Error") or 
                   string.match(lootUI.bulkCopyRulesPopup.copyResult, "Failed") then
                    ImGui.TextColored(1.0, 0.4, 0.4, 1, lootUI.bulkCopyRulesPopup.copyResult)
                else
                    ImGui.TextColored(0.4, 1.0, 0.4, 1, lootUI.bulkCopyRulesPopup.copyResult)
                end
                ImGui.Spacing()
            end
            
            -- Action buttons
            ImGui.Spacing()
            if ImGui.Button("Execute Copy", 150, 0) then
                if not lootUI.bulkCopyRulesPopup.sourceCharacter or lootUI.bulkCopyRulesPopup.sourceCharacter == "" then
                    lootUI.bulkCopyRulesPopup.copyResult = "Error: Please select a source character"
                elseif not lootUI.bulkCopyRulesPopup.targetCharacter or lootUI.bulkCopyRulesPopup.targetCharacter == "" then
                    lootUI.bulkCopyRulesPopup.copyResult = "Error: Please select a target character"
                else
                    lootUI.bulkCopyRulesPopup.copying = true
                    local success, result = database.copyAllRulesFromCharacter(
                        lootUI.bulkCopyRulesPopup.sourceCharacter,
                        lootUI.bulkCopyRulesPopup.targetCharacter
                    )
                    lootUI.bulkCopyRulesPopup.copying = false
                    
                    if success then
                        lootUI.bulkCopyRulesPopup.copyResult = string.format("Success! Copied %d rules from %s to %s", 
                            result, 
                            lootUI.bulkCopyRulesPopup.sourceCharacter,
                            lootUI.bulkCopyRulesPopup.targetCharacter)
                    else
                        lootUI.bulkCopyRulesPopup.copyResult = "Error: " .. (result or "Unknown error during copy")
                    end
                end
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip("Copy all rules from source to target character")
            end
            
            ImGui.SameLine()
            if ImGui.Button("Close", 100, 0) then
                lootUI.bulkCopyRulesPopup.isOpen = false
                keepOpen = false
            end
        end
        
        ImGui.End()
        lootUI.bulkCopyRulesPopup.isOpen = keepOpen and open
        lootUI.bulkCopyRulesPopup.isOpen = keepOpen and open
    end
end

return uiPopups
