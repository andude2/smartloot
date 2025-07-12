-- ui/ui_utils.lua
local mq = require("mq")
local ImGui = require("ImGui")
local Icons = require("mq.icons")

local uiUtils = {}

-- Shared UI_ICONS
uiUtils.UI_ICONS = {
    UP_ARROW = Icons.FA_ARROW_UP,
    DOWN_ARROW = Icons.FA_ARROW_DOWN,
    REMOVE = Icons.FA_TIMES,
    MOVE = Icons.FA_ARROWS,
    ADD = Icons.FA_PLUS,
    EDIT = Icons.FA_PENCIL,
    SORT = Icons.FA_SORT,
    CONFIRM = Icons.FA_CHECK,
    CANCEL = Icons.FA_BAN,
    SETTINGS = Icons.FA_COG,
    TRASH = Icons.FA_TRASH,
    REFRESH = Icons.FA_REFRESH,
    INFO = Icons.FA_INFO_CIRCLE,
    PAUSE = Icons.FA_PAUSE,
    PLAY = Icons.FA_PLAY,
    LIGHTNING = Icons.FA_BOLT
}

-- Constants for icon drawing
local EQ_ICON_OFFSET = 500
local ICON_WIDTH = 20
local ICON_HEIGHT = 20
local animItems = mq.FindTextureAnimation("A_DragItem")

-- Function to draw an item icon
function uiUtils.drawItemIcon(iconID)
    if iconID and iconID > 0 then
        animItems:SetTextureCell(iconID - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, ICON_WIDTH, ICON_HEIGHT)
    else
        ImGui.Text("...")
    end
end

return uiUtils