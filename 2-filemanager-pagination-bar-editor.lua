--[[
Userpatch: Pagination Bar Editor

Customizes the pagination bar in file browser and reader menus.

Features:
  - Text template with positional layout (buttons and text in any order)
  - Configurable font size and bold
  - Button style (icons or dots) and size
  - Bar alignment (left, center, right)
  - Adjustable spacer width between elements
  - Hide the bar entirely (swipe navigation still works)
  - {space} token for fine alignment control
  - Reset everything to default

Menu: Settings > Pagination bar
]]

local _ = require("gettext")
local T = require("ffi/util").template
local BD = require("ui/bidi")

local S = {
    hidden    = { key = "pagination_hidden",       default = false },
    template  = { key = "pagination_template",     default = "{first} {prev} Page {page} of {pages} {next} {last}" },
    font_size = { key = "pagination_font_size",    default = 20 },
    bold      = { key = "pagination_bold",          default = false },
    spacer    = { key = "pagination_spacer",        default = 32 },
    btn_style = { key = "pagination_btn_style",     default = "icons" },
    btn_size  = { key = "pagination_btn_size",      default = 0 },
    align     = { key = "pagination_align",          default = "center" },
}

local function get(s)
    local v = G_reader_settings:readSetting(s.key)
    if v == nil then return s.default end
    return v
end

local function set(s, v)
    G_reader_settings:saveSetting(s.key, v)
end

local BTN_STYLES = {
    { id = "icons", name = _("Icons (original)") },
    { id = "dots",  name = _("Dots:  •• • • ••"), labels = { "••", "•", "•", "••" } },
}

local function getStyleById(id)
    for _, s in ipairs(BTN_STYLES) do
        if s.id == id then return s end
    end
    return BTN_STYLES[1]
end

local DEFAULT_ICON_SIZE = 40

local function getEffectiveBtnSize()
    local v = tonumber(get(S.btn_size)) or 0
    if v > 0 then return v end
    if get(S.btn_style) == "icons" then return DEFAULT_ICON_SIZE end
    return tonumber(get(S.font_size)) or S.font_size.default
end

local BTN_TOKENS = {
    ["{first}"] = "first",
    ["{last}"]  = "last",
    ["{prev}"]  = "prev",
    ["{next}"]  = "next",
}

local function parseTemplate(tpl)
    if type(tpl) ~= "string" or tpl == "" then
        tpl = S.template.default
    end
    local segments = {}
    local pos = 1
    while pos <= #tpl do
        local best_start, best_end, best_id
        for token, id in pairs(BTN_TOKENS) do
            local s, e = tpl:find(token, pos, true)
            if s and (not best_start or s < best_start) then
                best_start, best_end, best_id = s, e, id
            end
        end
        if best_start then
            if best_start > pos then
                local frag = tpl:sub(pos, best_start - 1)
                frag = frag:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if frag ~= "" then
                    table.insert(segments, { type = "text", tpl = frag })
                end
            end
            table.insert(segments, { type = "button", id = best_id })
            pos = best_end + 1
        else
            local frag = tpl:sub(pos):gsub("%s+", " "):match("^%s*(.-)%s*$")
            if frag ~= "" then
                table.insert(segments, { type = "text", tpl = frag })
            end
            break
        end
    end
    return segments
end

local function renderText(text_tpl, page, page_num)
    if not text_tpl then return "" end
    local p = tonumber(page) or 1
    local total = tonumber(page_num) or 1
    local result = text_tpl
    result = result:gsub("{space}", " ")
    result = result:gsub("{remaining}", tostring(math.max(total - p, 0)))
    result = result:gsub("{pages}", tostring(total))
    result = result:gsub("{page}", tostring(p))
    return result
end

local Menu = require("ui/widget/menu")
local Button = require("ui/widget/button")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

local function askForRestart()
    UIManager:askForRestart(_("Restart to apply pagination changes"))
end

local function setAndRestart(s, v)
    set(s, v)
    askForRestart()
end

local function resetAllSettings()
    for _, s in pairs(S) do
        G_reader_settings:delSetting(s.key)
    end
    askForRestart()
end

local orig_recalculateDimen = Menu._recalculateDimen
function Menu:_recalculateDimen(no_recalculate_dimen)
    orig_recalculateDimen(self, no_recalculate_dimen)
    if no_recalculate_dimen or get(S.hidden) ~= true then
        return
    end
    local top_height = 0
    if self.title_bar and not self.no_title then
        top_height = self.title_bar:getHeight()
    end
    self.available_height = self.inner_dimen.h - top_height
    self.item_dimen.h = math.floor(self.available_height / self.perpage)
    if self.items_max_lines then
        self:setupItemHeights()
    end
    self.page_num = self:getPageNumber(#self.item_table)
    if self.page > self.page_num then
        self.page = self.page_num
    end
end

local orig_init = Menu.init
function Menu:init()
    self.show_parent = self.show_parent or self
    local hidden = get(S.hidden) == true
    local segments = parseTemplate(tostring(get(S.template) or S.template.default))
    local style = getStyleById(get(S.btn_style))
    local btn_size = getEffectiveBtnSize()

    local buttons = {}
    for _, seg in ipairs(segments) do
        if seg.type == "button" then buttons[seg.id] = true end
    end

    if not hidden then
        if style.id == "icons" then
            local icon_dim = Screen:scaleBySize(btn_size)
            local mirrored = BD.mirroredUILayout()
            local icon_first = mirrored and "chevron.last" or "chevron.first"
            local icon_prev  = mirrored and "chevron.right" or "chevron.left"
            local icon_next  = mirrored and "chevron.left" or "chevron.right"
            local icon_last  = mirrored and "chevron.first" or "chevron.last"
            local function iconBtn(icon, callback)
                return Button:new{
                    icon = icon,
                    icon_width = icon_dim,
                    icon_height = icon_dim,
                    callback = callback,
                    bordersize = 0,
                    show_parent = self.show_parent,
                }
            end
            if buttons.first then
                self.page_info_first_chev = iconBtn(icon_first, function() self:onFirstPage() end)
            end
            if buttons.prev then
                self.page_info_left_chev = iconBtn(icon_prev, function() self:onPrevPage() end)
            end
            if buttons.next then
                self.page_info_right_chev = iconBtn(icon_next, function() self:onNextPage() end)
            end
            if buttons.last then
                self.page_info_last_chev = iconBtn(icon_last, function() self:onLastPage() end)
            end
        else
            local labels = style.labels
            if BD.mirroredUILayout() then
                labels = { labels[4], labels[3], labels[2], labels[1] }
            end
            local function textBtn(text, callback)
                return Button:new{
                    text = text,
                    text_font_size = btn_size,
                    text_font_bold = false,
                    callback = callback,
                    bordersize = 0,
                    show_parent = self.show_parent,
                }
            end
            if buttons.first then
                self.page_info_first_chev = textBtn(labels[1], function() self:onFirstPage() end)
            end
            if buttons.prev then
                self.page_info_left_chev = textBtn(labels[2], function() self:onPrevPage() end)
            end
            if buttons.next then
                self.page_info_right_chev = textBtn(labels[3], function() self:onNextPage() end)
            end
            if buttons.last then
                self.page_info_last_chev = textBtn(labels[4], function() self:onLastPage() end)
            end
        end
    end

    orig_init(self)

    if hidden then
        if self.page_info then
            for i = #self.page_info, 1, -1 do self.page_info[i] = nil end
            self.page_info:resetLayout()
        end
        if self.return_button then
            for i = #self.return_button, 1, -1 do self.return_button[i] = nil end
            self.return_button:resetLayout()
        end
    else
        local font_size = tonumber(get(S.font_size)) or S.font_size.default
        local bold = get(S.bold) == true
        if self.page_info_text then
            self.page_info_text.text_font_size = font_size
            self.page_info_text.text_font_bold = bold
            local cur = self.page_info_text.text
            self.page_info_text.text = nil
            self.page_info_text:setText(cur or "")
        end
        self._pagination_text_segments = {}
        if self.page_info then
            local spacer_w = Screen:scaleBySize(tonumber(get(S.spacer)) or S.spacer.default)
            for i = #self.page_info, 1, -1 do self.page_info[i] = nil end
            local function add(widget)
                if #self.page_info > 0 and spacer_w > 0 then
                    table.insert(self.page_info, HorizontalSpan:new{ width = spacer_w })
                end
                table.insert(self.page_info, widget)
            end
            local btn_map = {
                first = self.page_info_first_chev,
                prev  = self.page_info_left_chev,
                next  = self.page_info_right_chev,
                last  = self.page_info_last_chev,
            }
            local used_main_text = false
            for _, seg in ipairs(segments) do
                if seg.type == "button" and btn_map[seg.id] then
                    add(btn_map[seg.id])
                elseif seg.type == "text" then
                    if not used_main_text and self.page_info_text then
                        used_main_text = true
                        add(self.page_info_text)
                        table.insert(self._pagination_text_segments,
                            { widget = self.page_info_text, tpl = seg.tpl })
                    else
                        local extra = Button:new{
                            text = "",
                            text_font_size = font_size,
                            text_font_bold = bold,
                            bordersize = 0,
                            padding = 0,
                            margin = 0,
                            callback = function() end,
                            show_parent = self.show_parent,
                        }
                        add(extra)
                        table.insert(self._pagination_text_segments,
                            { widget = extra, tpl = seg.tpl })
                    end
                end
            end
            self.page_info:resetLayout()
            local alignment = get(S.align)
            if alignment ~= "center" and self.inner_dimen then
                local inner_w = self.inner_dimen.w
                local orig_getSize = self.page_info.getSize
                local orig_paintTo = self.page_info.paintTo
                local content_w = 0
                self.page_info.getSize = function(group)
                    local size = orig_getSize(group)
                    content_w = size.w
                    size.w = inner_w
                    return size
                end
                if alignment == "left" then
                    self.page_info.paintTo = function(group, bb, x, y)
                        group:resetLayout()
                        group:getSize()
                        orig_paintTo(group, bb, x, y)
                    end
                elseif alignment == "right" then
                    self.page_info.paintTo = function(group, bb, x, y)
                        group:resetLayout()
                        group:getSize()
                        orig_paintTo(group, bb, x + inner_w - content_w, y)
                    end
                end
            end
        end
    end
end

local orig_updatePageInfo = Menu.updatePageInfo
function Menu:updatePageInfo(select_number)
    orig_updatePageInfo(self, select_number)
    if get(S.hidden) == true then return end
    if self._pagination_text_segments and self.page_num and self.page_num > 0 then
        for _, seg in ipairs(self._pagination_text_segments) do
            seg.widget:setText(renderText(seg.tpl, self.page, self.page_num))
        end
    end
end

-- Settings menu

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReaderMenu = require("apps/reader/modules/readermenu")
local InputDialog = require("ui/widget/inputdialog")

local function showTemplateDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Pagination text template"),
        input = tostring(get(S.template)),
        description = _(
            "Elements appear in the order you write them.\n"
            .. "Button tokens:\n"
            .. "  {first}  {prev}  {next}  {last}\n"
            .. "Text tokens:\n"
            .. "  {page}  {pages}  {remaining}  {space}\n"
            .. "Only buttons whose tokens are present will appear.\n"
            .. "{space} adds a literal space for fine alignment."
        ),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Default"),
                    callback = function()
                        setAndRestart(S.template, S.template.default)
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        if input == "" then input = S.template.default end
                        setAndRestart(S.template, input)
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function buildFontMenu()
    return {
        text = _("Font"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Size: %1"), get(S.font_size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Pagination text font size"),
                        value = tonumber(get(S.font_size)) or S.font_size.default,
                        value_min = 10,
                        value_max = 36,
                        default_value = S.font_size.default,
                        callback = function(spin)
                            setAndRestart(S.font_size, spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("Bold"),
                checked_func = function() return get(S.bold) == true end,
                callback = function()
                    setAndRestart(S.bold, not (get(S.bold) == true))
                end,
            },
        },
    }
end

local ALIGN_OPTIONS = {
    { id = "left",   name = _("Left") },
    { id = "center", name = _("Center") },
    { id = "right",  name = _("Right") },
}

local function buildBarMenu()
    local align_items = {}
    for _, a in ipairs(ALIGN_OPTIONS) do
        table.insert(align_items, {
            text = a.name,
            checked_func = function() return get(S.align) == a.id end,
            callback = function()
                setAndRestart(S.align, a.id)
            end,
            radio = true,
        })
    end
    return {
        text = _("Bar"),
        sub_item_table = {
            {
                text = _("Hide pagination bar"),
                help_text = _("Swipe navigation still works when hidden."),
                checked_func = function() return get(S.hidden) == true end,
                callback = function()
                    setAndRestart(S.hidden, not (get(S.hidden) == true))
                end,
            },
            {
                text = _("Alignment"),
                sub_item_table = align_items,
            },
            {
                text_func = function()
                    return T(_("Spacer width: %1"), get(S.spacer))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Spacer width between elements"),
                        value = tonumber(get(S.spacer)) or S.spacer.default,
                        value_min = 0,
                        value_max = 80,
                        default_value = S.spacer.default,
                        callback = function(spin)
                            setAndRestart(S.spacer, spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

local function buildButtonsMenu()
    local style_items = {}
    for _, s in ipairs(BTN_STYLES) do
        table.insert(style_items, {
            text = s.name,
            checked_func = function() return get(S.btn_style) == s.id end,
            callback = function()
                set(S.btn_style, s.id)
                set(S.btn_size, 0)
                askForRestart()
            end,
            radio = true,
        })
    end

    local function sizeLabel()
        local v = tonumber(get(S.btn_size)) or 0
        if v > 0 then return T(_("Size: %1"), v) end
        return T(_("Size: auto (%1)"), getEffectiveBtnSize())
    end

    return {
        text = _("Buttons"),
        sub_item_table = {
            {
                text = _("Style"),
                sub_item_table = style_items,
            },
            {
                text_func = sizeLabel,
                help_text = _("Button dimension. 0 = auto (40 for icons, follows font size for text). Also affects bar height."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Button size"),
                        value = tonumber(get(S.btn_size)) or 0,
                        value_min = 0,
                        value_max = 80,
                        default_value = 0,
                        callback = function(spin)
                            setAndRestart(S.btn_size, spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

local function buildSettingsMenu()
    local template_item = {
        text = _("Text template"),
        callback = function(touchmenu_instance)
            showTemplateDialog(touchmenu_instance)
        end,
        separator = true,
    }
    return {
        text = _("Pagination bar"),
        sub_item_table = {
            buildBarMenu(),
            buildFontMenu(),
            buildButtonsMenu(),
            template_item,
            {
                text = _("Reset everything to default"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    resetAllSettings()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        },
    }
end

local function addToMenu(self, order)
    self.menu_items.pagination_bar_settings = buildSettingsMenu()
    -- order is module-cached; only insert once per session
    for _, k in ipairs(order.setting) do
        if k == "pagination_bar_settings" then return end
    end
    table.insert(order.setting, "----------------------------")
    table.insert(order.setting, "pagination_bar_settings")
end

local orig_FM = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    addToMenu(self, require("ui/elements/filemanager_menu_order"))
    orig_FM(self)
end

local orig_RM = ReaderMenu.setUpdateItemTable
function ReaderMenu:setUpdateItemTable()
    addToMenu(self, require("ui/elements/reader_menu_order"))
    orig_RM(self)
end
