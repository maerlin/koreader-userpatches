--[[
Userpatch: Top Bar Editor

Customizes the File Manager top bar.

Features:
  - Replace "KOReader" title with the current folder name
  - Configurable font size, bold, and italic styling for the folder name
  - Remap right button (plus) tap to any dispatcher action
  - Configurable right button icon

Menu: Settings > Top bar
]]

local BD = require("ui/bidi")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local userpatch = require("userpatch")
local Screen = Device.screen

local _ = require("gettext")
local T = require("ffi/util").template

-- Settings

local S = {
    folder_as_title = { key = "topbar_folder_as_title", default = true },
    font_size       = { key = "topbar_title_font_size", default = nil },
    bold            = { key = "topbar_title_bold",       default = false },
    italic          = { key = "topbar_title_italic",     default = false },
    right_action    = { key = "topbar_right_action",     default = nil },
    right_icon      = { key = "topbar_right_icon",       default = nil },
}

local function get(s)
    local v = G_reader_settings:readSetting(s.key)
    if v == nil then return s.default end
    return v
end

local function set(s, v)
    G_reader_settings:saveSetting(s.key, v)
end

local function applyAndRefresh()
    local fm = FileManager.instance
    if fm then
        fm:reinit(fm.file_chooser.path)
    end
end

-- "smalltfont" maps to NotoSans-Bold.ttf, so the title font is inherently bold.
-- To actually control weight/style, we switch between font files:
--   Regular: cfont file (NotoSans-Regular.ttf)
--   Bold:    smalltfont file (NotoSans-Bold.ttf)
--   Italic/BoldItalic: derived from Regular via filename substitution
-- This stays compatible with the UI font patch (2--ui-font.lua).
local function getTitleFace(font_size)
    local size = font_size or Font.sizemap.smalltfont
    local is_bold = get(S.bold)
    local is_italic = get(S.italic)

    local regular_file = Font.fontmap.cfont
    local bold_file = Font.fontmap.smalltfont

    if is_italic then
        local suffix = is_bold and "-BoldItalic." or "-Italic."
        local italic_file = regular_file:gsub("%-Regular%.", suffix)
        if italic_file ~= regular_file then
            local face = Font:getFace(italic_file, size)
            if face then return face end
        end
    end

    return Font:getFace(is_bold and bold_file or regular_file, size)
end

-- Patch: setupLayout

local orig_FileManager_setupLayout = FileManager.setupLayout
function FileManager:setupLayout()
    local do_folder_title = get(S.folder_as_title)

    if do_folder_title then
        self._topbar_saved_title = self.title
        self.title = ""
    end

    orig_FileManager_setupLayout(self)

    if do_folder_title then
        self.title = self._topbar_saved_title
    end

    local needs_reinit = false

    if do_folder_title then
        local path = self.file_chooser.path
        local text = BD.directory(filemanagerutil.abbreviate(path))
        if self.folder_shortcuts and self.folder_shortcuts:hasFolderShortcut(path) then
            text = "☆ " .. text
        end

        local face = getTitleFace(get(S.font_size))

        -- Center text vertically within the icon area
        local face_height = face.ftsize:getHeightAndAscender()
        local text_h = math.ceil(face_height)
        local icon_size = Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE"))
        local btn_padding = self.title_bar.button_padding
        local centered_padding = math.floor(btn_padding + math.max(0, icon_size - text_h) / 2 + 0.5)

        self.title_bar.title = text
        self.title_bar.subtitle = nil
        self.title_bar.title_face = face
        self.title_bar.title_top_padding = centered_padding
        needs_reinit = true
    end

    local right_action = get(S.right_action)
    if right_action then
        local fm = self
        self.title_bar.right_icon_tap_callback = function()
            if fm.selected_files then
                fm:onShowPlusMenu()
            else
                Dispatcher:init()
                Dispatcher:execute({ [right_action] = true })
            end
        end
        needs_reinit = true
    end

    local right_icon = get(S.right_icon)
    if right_icon and not self.selected_files then
        self.title_bar.right_icon = right_icon
        needs_reinit = true
    end

    if needs_reinit then
        self.title_bar:clear()
        self.title_bar:init()
    end
end

-- Patch: updateTitleBarPath (use title instead of subtitle for folder name)

local orig_FileManager_updateTitleBarPath = FileManager.updateTitleBarPath
function FileManager:updateTitleBarPath(path)
    if not get(S.folder_as_title) then
        return orig_FileManager_updateTitleBarPath(self, path)
    end

    local text = BD.directory(filemanagerutil.abbreviate(path))
    if self.folder_shortcuts and self.folder_shortcuts:hasFolderShortcut(path) then
        text = "☆ " .. text
    end
    self.title_bar:setTitle(text)
end

-- The original source aliases onPathChanged = updateTitleBarPath BEFORE our patch,
-- so the event still calls the original. Re-establish the alias to our version.
FileManager.onPathChanged = FileManager.updateTitleBarPath

-- Patch: onToggleSelectMode (restore custom icon when exiting select mode)

local orig_FileManager_onToggleSelectMode = FileManager.onToggleSelectMode
function FileManager:onToggleSelectMode(do_refresh)
    orig_FileManager_onToggleSelectMode(self, do_refresh)
    if not self.selected_files then
        local icon = get(S.right_icon)
        if icon then
            self.title_bar:setRightIcon(icon)
        end
    end
end

-- Menu

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReaderMenu = require("apps/reader/modules/readermenu")

local ICON_OPTIONS = {
    { id = nil,                  name = _("Plus (default)") },
    { id = "appbar.settings",    name = _("Settings gear") },
    { id = "appbar.menu",        name = _("Menu") },
    { id = "appbar.search",      name = _("Search") },
    { id = "appbar.navigation",  name = _("Navigation") },
    { id = "appbar.filebrowser", name = _("File browser") },
    { id = "appbar.tools",       name = _("Tools") },
    { id = "star.white",         name = _("Star") },
}

local function getIconName(id)
    for _, opt in ipairs(ICON_OPTIONS) do
        if opt.id == id then return opt.name end
    end
    return id or _("Plus (default)")
end

local function buildFolderNameMenu()
    return {
        text = _("Folder name"),
        sub_item_table = {
            {
                text = _("Show as title"),
                help_text = _("Replace \"KOReader\" text with the current folder name."),
                checked_func = function() return get(S.folder_as_title) end,
                callback = function()
                    set(S.folder_as_title, not get(S.folder_as_title))
                    applyAndRefresh()
                end,
            },
            {
                text_func = function()
                    local size = get(S.font_size)
                    return size and T(_("Font size: %1"), size) or _("Font size: default")
                end,
                help_text = _("Long-press to reset to default."),
                enabled_func = function() return get(S.folder_as_title) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Folder name font size"),
                        value = get(S.font_size) or Font.sizemap.smalltfont,
                        value_min = 10,
                        value_max = 36,
                        default_value = Font.sizemap.smalltfont,
                        callback = function(spin)
                            set(S.font_size, spin.value)
                            applyAndRefresh()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                hold_callback = function(touchmenu_instance)
                    set(S.font_size, nil)
                    applyAndRefresh()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Bold"),
                enabled_func = function() return get(S.folder_as_title) end,
                checked_func = function() return get(S.bold) end,
                callback = function()
                    set(S.bold, not get(S.bold))
                    applyAndRefresh()
                end,
            },
            {
                text = _("Italic"),
                enabled_func = function() return get(S.folder_as_title) end,
                checked_func = function() return get(S.italic) end,
                callback = function()
                    set(S.italic, not get(S.italic))
                    applyAndRefresh()
                end,
            },
        },
    }
end

local function buildActionSubItems()
    Dispatcher:init()
    local settingsList = userpatch.getUpValue(Dispatcher._addItem, "settingsList")
    local dispatcher_menu_order = userpatch.getUpValue(Dispatcher._addItem, "dispatcher_menu_order")

    local items = {
        {
            text = _("Default (Plus menu)"),
            checked_func = function() return get(S.right_action) == nil end,
            radio = true,
            callback = function()
                set(S.right_action, nil)
                applyAndRefresh()
            end,
            separator = true,
        },
    }

    if not settingsList or not dispatcher_menu_order then
        return items
    end

    local sections = {
        { "general",     _("General") },
        { "device",      _("Device") },
        { "screen",      _("Screen and lights") },
        { "filemanager", _("File browser") },
    }

    for _, section in ipairs(sections) do
        local section_key, section_name = section[1], section[2]
        local section_items = {}

        for _, k in ipairs(dispatcher_menu_order) do
            local entry = settingsList[k]
            if entry and entry[section_key] == true
               and entry.condition ~= false
               and entry.category == "none" then
                table.insert(section_items, {
                    text = entry.title,
                    checked_func = function() return get(S.right_action) == k end,
                    radio = true,
                    callback = function()
                        set(S.right_action, k)
                        applyAndRefresh()
                    end,
                    separator = entry.separator,
                })
            end
        end

        if #section_items > 0 then
            table.insert(items, {
                text = section_name,
                sub_item_table = section_items,
            })
        end
    end

    return items
end

local function buildRightButtonMenu()
    local icon_items = {}
    for _, opt in ipairs(ICON_OPTIONS) do
        table.insert(icon_items, {
            text = opt.name,
            checked_func = function() return get(S.right_icon) == opt.id end,
            radio = true,
            callback = function()
                set(S.right_icon, opt.id)
                applyAndRefresh()
            end,
        })
    end

    return {
        text = _("Right button"),
        separator = true,
        sub_item_table = {
            {
                text = _("Action"),
                sub_item_table_func = buildActionSubItems,
            },
            {
                text_func = function()
                    return T(_("Icon: %1"), getIconName(get(S.right_icon)))
                end,
                sub_item_table = icon_items,
            },
        },
    }
end

local function buildSettingsMenu()
    return {
        text = _("Top bar"),
        sub_item_table = {
            buildFolderNameMenu(),
            buildRightButtonMenu(),
            {
                text = _("Reset to defaults"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    for _, s in pairs(S) do
                        G_reader_settings:delSetting(s.key)
                    end
                    applyAndRefresh()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        },
    }
end

local function addToMenu(self, order)
    table.insert(order.setting, "----------------------------")
    table.insert(order.setting, "topbar_settings")
    self.menu_items.topbar_settings = buildSettingsMenu()
end

local orig_FM_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    addToMenu(self, require("ui/elements/filemanager_menu_order"))
    orig_FM_setUpdateItemTable(self)
end

local orig_RM_setUpdateItemTable = ReaderMenu.setUpdateItemTable
function ReaderMenu:setUpdateItemTable()
    addToMenu(self, require("ui/elements/reader_menu_order"))
    orig_RM_setUpdateItemTable(self)
end
