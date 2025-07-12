-- ui/ui_help.lua - SmartLoot Help Window
local ui_help = {}
local mq = require("mq")
local ImGui = require('ImGui')

-- Window state
local showHelpWindow = false
local windowFlags = bit32.bor(ImGuiWindowFlags.None)

-- State for parameter input
local parameterInputs = {}

-- Command categories for organized display
local commandCategories = {
    {
        name = "Getting Started",
        commands = {
            {cmd = "/sl_getstarted", params = "", desc = "Display comprehensive getting started guide with setup instructions, usage examples, and tips for new users.", hasOptionalParam = false}
        }
    },
    {
        name = "Engine Control",
        commands = {
            {cmd = "/sl_pause", params = "[on|off]", desc = "Pause or resume the SmartLoot engine. Without parameters, toggles the current state.", hasOptionalParam = true},
            {cmd = "/sl_doloot", params = "", desc = "Activate 'once' mode to loot all nearby corpses one time.", hasOptionalParam = false},
            {cmd = "/sl_rg_trigger", params = "", desc = "Trigger RGMain mode if currently in RGMain mode (used by RGMercs).", hasOptionalParam = false},
            {cmd = "/sl_emergency_stop", params = "", desc = "Immediately stop all loot operations (emergency stop).", hasOptionalParam = false},
            {cmd = "/sl_resume", params = "", desc = "Resume operations after an emergency stop.", hasOptionalParam = false},
            {cmd = "/sl_clearcache", params = "", desc = "Clear the processed corpse cache, treating all corpses as new.", hasOptionalParam = false}
        }
    },
    {
        name = "Chat & Chase Control",
        commands = {
            {cmd = "/sl_chat", params = "<mode>", desc = "Set chat output mode. Valid modes: raid, group, guild, custom, silent. Without parameters shows current mode.", hasRequiredParam = true},
            {cmd = "/sl_chase", params = "[on|off|pause|resume]", desc = "Control chase commands. on/off enables/disables, pause/resume manually triggers chase commands. Without parameters shows current status.", hasOptionalParam = true},
            {cmd = "/sl_chase_on", params = "", desc = "Enable chase pause/resume during looting (shortcut for /sl_chase on).", hasOptionalParam = false},
            {cmd = "/sl_chase_off", params = "", desc = "Disable chase pause/resume during looting (shortcut for /sl_chase off).", hasOptionalParam = false}
        }
    },
    {
        name = "User Interface",
        commands = {
            {cmd = "/sl_toggle_hotbar", params = "", desc = "Toggle the visibility of the SmartLoot hotbar.", hasOptionalParam = false},
            {cmd = "/sl_debug", params = "", desc = "Toggle the debug window showing detailed loot processing information.", hasOptionalParam = false},
            {cmd = "/sl_debug level", params = "[X]", desc = "Set or show debug logging level. X can be 0-5 or NONE/ERROR/WARN/INFO/DEBUG/VERBOSE.", hasOptionalParam = true},
            {cmd = "/sl_stats", params = "[show|hide|toggle|reset|compact]", desc = "Control the live statistics window. Parameters: show, hide, toggle visibility, reset position, or toggle compact mode.", hasOptionalParam = true},
            {cmd = "/sl_help", params = "", desc = "Show this help window.", hasOptionalParam = false}
        }
    },
    {
        name = "Status & Information",
        commands = {
            {cmd = "/sl_engine_status", params = "", desc = "Display detailed engine status including current state, mode, and session statistics.", hasOptionalParam = false},
            {cmd = "/sl_mode_status", params = "", desc = "Show current loot mode and peer order status.", hasOptionalParam = false},
            {cmd = "/sl_waterfall_status", params = "", desc = "Display waterfall (peer coordination) status.", hasOptionalParam = false},
            {cmd = "/sl_version", params = "", desc = "Show SmartLoot version and current state information.", hasOptionalParam = false}
        }
    },
    {
        name = "Peer Management",
        commands = {
            {cmd = "/sl_check_peers", params = "", desc = "Check which peers are connected and their current status.", hasOptionalParam = false},
            {cmd = "/sl_refresh_mode", params = "", desc = "Refresh loot mode based on current peer connections and loot order.", hasOptionalParam = false},
            {cmd = "/sl_peer_monitor", params = "[on|off]", desc = "Enable or disable automatic peer monitoring for mode switching.", hasOptionalParam = true}
        }
    },
    {
        name = "Advanced/Debug",
        commands = {
            {cmd = "/sl_waterfall_debug", params = "", desc = "Show detailed waterfall chain debugging information.", hasOptionalParam = false},
            {cmd = "/sl_waterfall_complete", params = "", desc = "Manually check and update waterfall completion status.", hasOptionalParam = false},
            {cmd = "/sl_test_peer_complete", params = "<peer>", desc = "Simulate a peer completion message for testing waterfall chains.", hasRequiredParam = true}
        }
    }
}

-- Quick reference section
local quickReference = {
    "Common Usage:",
    "- /sl_doloot - Loot all nearby corpses once",
    "- /sl_pause - Pause/resume looting",
    "- /sl_stats - Toggle statistics window",
    "- /sl_chat <mode> - Set chat output mode",
    "- /sl_chase on/off - Enable/disable chase control",
    "- /sl_help - Show this help window",
    "",
    "Loot Modes:",
    "- Background - Always running, low priority",
    "- Main - Primary looter in peer group",
    "- Once - Loot all corpses one time",
    "- RGMain - Integration with RGMercs",
    "- Disabled - Looting paused"
}

-- ============================================================================
-- RENDERING
-- ============================================================================

local function executeCommand(cmd, param)
    local fullCommand = cmd
    if param and param ~= "" then
        fullCommand = cmd .. " " .. param
    end
    mq.cmd(fullCommand)
end

local function renderHelpContent()
    -- Header
    ImGui.TextColored(ImVec4(0.4, 0.8, 1.0, 1.0), "SmartLoot Help")
    ImGui.Separator()
    ImGui.Spacing()
    
    -- Quick Reference Section
    if ImGui.CollapsingHeader("Quick Reference", ImGuiTreeNodeFlags.DefaultOpen) then
        ImGui.Indent()
        for _, line in ipairs(quickReference) do
            if line == "" then
                ImGui.Spacing()
            elseif line:sub(1,1) == "-" then
                ImGui.TextColored(ImVec4(0.8, 0.8, 0.8, 1.0), line)
            else
                ImGui.TextColored(ImVec4(1.0, 1.0, 0.6, 1.0), line)
            end
        end
        ImGui.Unindent()
        ImGui.Spacing()
    end
    
    ImGui.Separator()
    ImGui.Spacing()
    
    -- Command Categories
    ImGui.TextColored(ImVec4(0.4, 0.8, 1.0, 1.0), "All Commands")
    ImGui.Separator()
    ImGui.Spacing()
    
    for _, category in ipairs(commandCategories) do
        if ImGui.CollapsingHeader(category.name) then
            ImGui.Indent()
            
            -- Create a table for better formatting
            if ImGui.BeginTable(category.name .. "_table", 3, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.Borders, ImGuiTableFlags.Resizable)) then
                ImGui.TableSetupColumn("Command", ImGuiTableColumnFlags.WidthFixed, 280)
                ImGui.TableSetupColumn("Description", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Execute", ImGuiTableColumnFlags.WidthFixed, 150)
                ImGui.TableHeadersRow()
                
                for i, cmd in ipairs(category.commands) do
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    
                    -- Command column
                    ImGui.TextColored(ImVec4(0.6, 1.0, 0.6, 1.0), cmd.cmd)
                    if cmd.params ~= "" then
                        ImGui.SameLine()
                        ImGui.TextColored(ImVec4(0.8, 0.8, 0.8, 1.0), cmd.params)
                    end
                    
                    ImGui.TableNextColumn()
                    -- Description column
                    ImGui.TextWrapped(cmd.desc)
                    
                    ImGui.TableNextColumn()
                    -- Execute button column
                    local buttonId = cmd.cmd .. "##exec_" .. i
                    
                    if cmd.hasRequiredParam or cmd.hasOptionalParam then
                        -- Initialize parameter input if needed
                        if not parameterInputs[cmd.cmd] then
                            parameterInputs[cmd.cmd] = ""
                        end
                        
                        -- Show input field
                        ImGui.PushItemWidth(80)
                        local changed, newValue = ImGui.InputText("##param_" .. cmd.cmd, parameterInputs[cmd.cmd], 128)
                        if changed then
                            parameterInputs[cmd.cmd] = newValue
                        end
                        ImGui.PopItemWidth()
                        
                        ImGui.SameLine()
                        if ImGui.Button("Run##" .. buttonId) then
                            if cmd.hasRequiredParam and parameterInputs[cmd.cmd] == "" then
                                -- Show error for required parameter
                                mq.cmd("/echo SmartLoot: " .. cmd.cmd .. " requires a parameter!")
                            else
                                executeCommand(cmd.cmd, parameterInputs[cmd.cmd])
                            end
                        end
                    else
                        -- Simple execute button for commands without parameters
                        if ImGui.Button("Execute##" .. buttonId) then
                            executeCommand(cmd.cmd, nil)
                        end
                    end
                end
                
                ImGui.EndTable()
            end
            
            ImGui.Unindent()
            ImGui.Spacing()
        end
    end
    
    -- Footer
    ImGui.Separator()
    ImGui.Spacing()
    ImGui.TextColored(ImVec4(0.6, 0.6, 0.6, 1.0), "SmartLoot 2.0 State Engine")
    ImGui.TextColored(ImVec4(0.6, 0.6, 0.6, 1.0), "Use /sl_help to show this window")
end

function ui_help.render()
    if not showHelpWindow then return end
    
    -- Set window size constraints (wider to accommodate execute buttons)
    ImGui.SetNextWindowSizeConstraints(ImVec2(800, 400), ImVec2(1400, 800))
    
    -- Begin window
    local isOpen = true
    isOpen, showHelpWindow = ImGui.Begin("SmartLoot Help##SLHelp", showHelpWindow, windowFlags)
    
    if isOpen then
        renderHelpContent()
    end
    
    ImGui.End()
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

function ui_help.show()
    showHelpWindow = true
end

function ui_help.hide()
    showHelpWindow = false
end

function ui_help.toggle()
    showHelpWindow = not showHelpWindow
end

function ui_help.isVisible()
    return showHelpWindow
end

return ui_help