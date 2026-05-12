--[[
Userpatch: File Manager Navbar

Minimal bottom navigation bar for the File Manager.

Heavily trimmed fork of the original "navbar-vos" patch by SeriousHornet:
  https://github.com/SeriousHornet/KOReader.patches
All credit for the original design, layout, and approach goes to the
upstream author. This version strips out plugin integrations, kaleido
colors, custom tabs, standalone-view injection, and most config knobs
in favor of a small, fixed four-button bar.

Four fixed tabs:
  - Page left
  - Books (home)
  - Configurable action (OPDS / History / Favorites / Collections / Search / Settings)
  - Page right

Menu: Settings > Navbar settings
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")

-- === Config ===

local config_default = {
    show_labels = true,
    show_top_border = true,
    show_top_gap = false,
    navbar_size = "medium",
    action_id = "opds",
    -- Icon name overrides. Empty/nil falls back to the built-in defaults.
    -- KOReader's IconWidget searches the data dir's `icons/` folder first,
    -- so custom SVG/PNG files placed there can be referenced by name.
    icons = {
        left = nil,
        books = nil,
        right = nil,
        action = {}, -- keyed by action_id
    },
}

local function loadConfig()
    local c = G_reader_settings:readSetting("bottom_navbar", config_default)
    for k, v in pairs(config_default) do
        if c[k] == nil then c[k] = v end
    end
    if type(c.icons) ~= "table" then c.icons = { action = {} } end
    if type(c.icons.action) ~= "table" then c.icons.action = {} end
    return c
end

local config = loadConfig()

local function saveConfig()
    G_reader_settings:saveSetting("bottom_navbar", config)
end

-- === Layout ===

local size_presets = {
    tiny   = { icon = 16, font = "xx_smallinfofont", font_size = 12, padding = 2 },
    small  = { icon = 22, font = "xx_smallinfofont", font_size = 14, padding = 3 },
    medium = { icon = 30, font = "x_smallinfofont",  font_size = 18, padding = 4 },
    large  = { icon = 40, font = "smallinfofont",    font_size = 22, padding = 6 },
    huge   = { icon = 50, font = "infofont",         font_size = 26, padding = 8 },
}

local NAVBAR_H_PADDING = Screen:scaleBySize(10)
local NAVBAR_TOP_GAP = Screen:scaleBySize(10)
local CORNER_DEAD_ZONE = math.floor(Screen:getWidth() / 12)

local navbar_icon_size, navbar_font, navbar_v_padding

local function updateLayoutConstants()
    local p = size_presets[config.navbar_size] or size_presets.medium
    navbar_icon_size = Screen:scaleBySize(p.icon)
    navbar_font = Font:getFace(p.font, p.font_size)
    navbar_v_padding = Screen:scaleBySize(p.padding)
end
updateLayoutConstants()

-- === Configurable action registry ===

local function openOpdsCatalog()
    local fm = FileManager.instance
    if not fm then return end
    local opds = fm.opds
    if not opds then
        UIManager:show(InfoMessage:new{
            text = _("OPDS plugin is not enabled.\nEnable it in Settings > Plugins."),
            timeout = 4,
        })
        return
    end
    local servers = opds.servers or {}

    local function openServer(server)
        local OPDSBrowser = require("opdsbrowser")
        local browser
        browser = OPDSBrowser:new{
            servers = opds.servers,
            downloads = opds.downloads,
            settings = opds.settings,
            pending_syncs = opds.pending_syncs,
            title = server.title,
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            _manager = opds,
            file_downloaded_callback = function(file)
                opds:showFileDownloadedDialog(file)
            end,
            close_callback = function()
                if browser.download_list then
                    browser.download_list.close_callback()
                end
                UIManager:close(browser)
                opds.opds_browser = nil
                if opds.last_downloaded_file then
                    if fm.file_chooser then
                        local util = require("util")
                        local pathname = util.splitFilePathName(opds.last_downloaded_file)
                        fm.file_chooser:changeToPath(pathname, opds.last_downloaded_file)
                    end
                    opds.last_downloaded_file = nil
                end
            end,
        }
        opds.opds_browser = browser
        UIManager:show(browser)
        -- HTTP auth is read from root_catalog_username/password on the instance,
        -- not from updateCatalog args.
        browser.root_catalog_title = server.title
        browser.root_catalog_username = server.username
        browser.root_catalog_password = server.password
        browser.root_catalog_raw_names = server.raw_names
        browser.catalog_title = server.title
        browser:updateCatalog(server.url)
    end

    if #servers == 0 then
        opds:onShowOPDSCatalog()
        return
    end
    if #servers == 1 then
        openServer(servers[1])
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _, server in ipairs(servers) do
        local s = server
        table.insert(buttons, {{
            text = s.title,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                openServer(s)
            end,
        }})
    end
    table.insert(buttons, {})
    table.insert(buttons, {{
        text = _("All catalogs"),
        align = "left",
        callback = function()
            UIManager:close(dialog)
            opds:onShowOPDSCatalog()
        end,
    }})
    dialog = ButtonDialog:new{
        title = _("Open OPDS catalog"),
        title_align = "center",
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

local ACTIONS = {
    opds = {
        title = _("OPDS"),
        icon = "appbar.search",
        handler = openOpdsCatalog,
    },
    history = {
        title = _("History"),
        icon = "appbar.menu",
        handler = function()
            local fm = FileManager.instance
            if fm and fm.history then fm.history:onShowHist() end
        end,
    },
    favorites = {
        title = _("Favorites"),
        icon = "star.full",
        handler = function()
            local fm = FileManager.instance
            if fm and fm.collections then fm.collections:onShowColl("favorites") end
        end,
    },
    collections = {
        title = _("Collections"),
        icon = "appbar.menu",
        handler = function()
            local fm = FileManager.instance
            if fm and fm.collections then fm.collections:onShowCollList() end
        end,
    },
    search = {
        title = _("Search"),
        icon = "appbar.search",
        handler = function()
            UIManager:sendEvent(Event:new("ShowFileSearch"))
        end,
    },
    settings = {
        title = _("Settings"),
        icon = "appbar.settings",
        handler = function()
            local fm = FileManager.instance
            if fm and fm.menu then fm.menu:onShowMenu() end
        end,
    },
}

local ACTION_ORDER = { "opds", "history", "favorites", "collections", "search", "settings" }

local function getActiveAction()
    return ACTIONS[config.action_id] or ACTIONS.opds
end

-- === Tab callbacks ===

local function onTabPageLeft()
    local fm = FileManager.instance
    if fm and fm.file_chooser then fm.file_chooser:onPrevPage() end
end

local function onTabPageRight()
    local fm = FileManager.instance
    if fm and fm.file_chooser then fm.file_chooser:onNextPage() end
end

local function onTabBooks()
    local fm = FileManager.instance
    if not fm or not fm.file_chooser then return end
    local home_dir = G_reader_settings:readSetting("home_dir")
        or require("apps/filemanager/filemanagerutil").getDefaultDir()
    fm.file_chooser.path_items[home_dir] = nil
    fm.file_chooser:changeToPath(home_dir)
end

local function onTabAction()
    getActiveAction().handler()
end

local ICON_DEFAULTS = {
    left  = "chevron.left",
    books = "home",
    right = "chevron.right",
}

local function pickIcon(slot, fallback)
    local v = config.icons and config.icons[slot]
    if v and v ~= "" then return v end
    return fallback
end

local function pickActionIcon(action_id, fallback)
    local v = config.icons and config.icons.action and config.icons.action[action_id]
    if v and v ~= "" then return v end
    return fallback
end

local function getTabs()
    local action = getActiveAction()
    return {
        { icon = pickIcon("left",  ICON_DEFAULTS.left),  label = _("Prev"),    callback = onTabPageLeft },
        { icon = pickIcon("books", ICON_DEFAULTS.books), label = _("Books"),   callback = onTabBooks },
        { icon = pickActionIcon(config.action_id, action.icon), label = action.title, callback = onTabAction },
        { icon = pickIcon("right", ICON_DEFAULTS.right), label = _("Next"),    callback = onTabPageRight },
    }
end

-- === Build navbar ===

local function createTabWidget(tab, tab_w)
    local icon = IconWidget:new{
        icon = tab.icon,
        width = navbar_icon_size,
        height = navbar_icon_size,
    }
    local children = { align = "center", VerticalSpan:new{ width = navbar_v_padding }, icon }
    if config.show_labels then
        table.insert(children, TextWidget:new{ text = tab.label, face = navbar_font })
    end
    table.insert(children, VerticalSpan:new{ width = navbar_v_padding })
    local group = VerticalGroup:new(children)
    return CenterContainer:new{
        dimen = Geom:new{ w = tab_w, h = group:getSize().h },
        group,
    }
end

local function createNavbar()
    local tabs = getTabs()
    local screen_w = Screen:getWidth()
    local inner_w = screen_w - NAVBAR_H_PADDING * 2
    local tab_w = math.floor(inner_w / #tabs)

    local row = HorizontalGroup:new{}
    for _, t in ipairs(tabs) do
        table.insert(row, createTabWidget(t, tab_w))
    end
    local row_with_pad = HorizontalGroup:new{
        HorizontalSpan:new{ width = NAVBAR_H_PADDING },
        row,
        HorizontalSpan:new{ width = NAVBAR_H_PADDING },
    }

    local visual_children = {}
    if config.show_top_gap then
        table.insert(visual_children, VerticalSpan:new{ width = NAVBAR_TOP_GAP })
    end
    if config.show_top_border then
        local row_h = row_with_pad:getSize().h
        local separator = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
        table.insert(visual_children, OverlapGroup:new{
            dimen = Geom:new{ w = screen_w, h = row_h },
            allow_mirroring = false,
            CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = Size.line.medium },
                separator,
            },
            row_with_pad,
        })
    else
        table.insert(visual_children, row_with_pad)
    end
    local visual = VerticalGroup:new(visual_children)

    local navbar = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = visual:getSize().h },
        ges_events = {
            TapNavBar = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = screen_w, h = Screen:getHeight() },
                },
            },
        },
    }
    navbar.onTapNavBar = function(self, _, ges)
        if not self.dimen or not self.dimen:contains(ges.pos) then return false end
        if ges.pos.x < CORNER_DEAD_ZONE or ges.pos.x > screen_w - CORNER_DEAD_ZONE then
            return false
        end
        local tap_x = ges.pos.x - NAVBAR_H_PADDING
        local idx = math.floor(tap_x / tab_w) + 1
        idx = math.max(1, math.min(#tabs, idx))
        tabs[idx].callback()
        return true
    end
    navbar[1] = visual
    return navbar
end

-- === Menu height reduction ===

local function getNavbarHeight()
    return createNavbar():getSize().h
end

local orig_menu_init = Menu.init
function Menu:init()
    if self.name == "filemanager" and not self.height then
        self.height = Screen:getHeight() - getNavbarHeight()
    end
    orig_menu_init(self)
end

-- === Inject navbar into FileManager ===

local function injectNavbar(fm)
    local fm_ui = fm[1]
    if not fm_ui then return end
    local file_chooser
    if fm._navbar_injected then
        file_chooser = fm_ui[1] and fm_ui[1][1]
    else
        file_chooser = fm_ui[1]
    end
    if not file_chooser then return end
    fm._navbar_injected = true

    local navbar = createNavbar()
    local nb_h = navbar:getSize().h
    local new_h = Screen:getHeight() - nb_h
    if file_chooser.height ~= new_h then
        local chrome = file_chooser.dimen.h - file_chooser.inner_dimen.h
        file_chooser.height = new_h
        file_chooser.dimen.h = new_h
        file_chooser.inner_dimen.h = new_h - chrome
        file_chooser:updateItems()
    end
    fm_ui[1] = VerticalGroup:new{ align = "left", file_chooser, navbar }
end

local orig_setupLayout = FileManager.setupLayout
function FileManager:setupLayout()
    orig_setupLayout(self)
    self._navbar_injected = false
    local fm = self
    UIManager:nextTick(function()
        injectNavbar(fm)
        UIManager:setDirty(fm, "ui")
    end)
end

-- === Settings menu ===

local function refreshNavbar()
    local fm = FileManager.instance
    if fm then
        injectNavbar(fm)
        UIManager:setDirty(fm, "ui")
    end
end

local function buildToggle(label, key)
    return {
        text = label,
        checked_func = function() return config[key] end,
        callback = function()
            config[key] = not config[key]
            saveConfig()
            refreshNavbar()
        end,
    }
end

local function buildRadio(label, key, options, on_change)
    local items = {}
    for _, opt in ipairs(options) do
        table.insert(items, {
            text = opt.text,
            radio = true,
            checked_func = function() return config[key] == opt.id end,
            callback = function()
                config[key] = opt.id
                saveConfig()
                if on_change then on_change() end
                refreshNavbar()
            end,
        })
    end
    return { text = label, sub_item_table = items }
end

local function promptIcon(title, current, default_value, on_save)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = default_value,
        description = _("Icon name (without .svg/.png). Custom icons live in KOReader's `icons/` data folder. Leave empty to use the default."),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Reset"),
                callback = function()
                    UIManager:close(dialog)
                    on_save(nil)
                end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local v = dialog:getInputText()
                    UIManager:close(dialog)
                    on_save(v ~= "" and v or nil)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function iconRow(label, slot, default_value)
    return {
        text_func = function()
            local v = config.icons and config.icons[slot]
            return label .. ": " .. (v and v ~= "" and v or default_value)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            promptIcon(label, config.icons and config.icons[slot], default_value, function(value)
                config.icons[slot] = value
                saveConfig()
                refreshNavbar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    }
end

local function actionIconRow()
    return {
        text_func = function()
            local aid = config.action_id
            local override = config.icons and config.icons.action and config.icons.action[aid]
            local effective = override and override ~= "" and override or ACTIONS[aid].icon
            return _("Action icon") .. " (" .. ACTIONS[aid].title .. "): " .. effective
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local aid = config.action_id
            local default_value = ACTIONS[aid].icon
            local current = config.icons.action[aid]
            promptIcon(_("Action icon"), current, default_value, function(value)
                config.icons.action[aid] = value
                saveConfig()
                refreshNavbar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    }
end

local function buildSettingsMenu()
    local size_opts = {
        { id = "tiny",   text = _("Tiny") },
        { id = "small",  text = _("Small") },
        { id = "medium", text = _("Medium") },
        { id = "large",  text = _("Large") },
        { id = "huge",   text = _("Huge") },
    }
    local action_opts = {}
    for _, id in ipairs(ACTION_ORDER) do
        table.insert(action_opts, { id = id, text = ACTIONS[id].title })
    end

    return {
        text = _("Navbar settings"),
        sub_item_table = {
            buildRadio(_("Action button"), "action_id", action_opts),
            buildRadio(_("Size"), "navbar_size", size_opts, updateLayoutConstants),
            buildToggle(_("Show labels"), "show_labels"),
            buildToggle(_("Show top border"), "show_top_border"),
            buildToggle(_("Show top gap"), "show_top_gap"),
            {
                text = _("Icons"),
                sub_item_table = {
                    iconRow(_("Prev"), "left", ICON_DEFAULTS.left),
                    iconRow(_("Books"), "books", ICON_DEFAULTS.books),
                    iconRow(_("Next"), "right", ICON_DEFAULTS.right),
                    actionIconRow(),
                },
            },
        },
    }
end

local orig_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
function FileManagerMenu:setUpdateItemTable()
    local fs_order = FileManagerMenuOrder.filemanager_settings
    local present = false
    for _, k in ipairs(fs_order) do
        if k == "navbar_settings" then present = true; break end
    end
    if not present then
        table.insert(fs_order, "navbar_settings")
    end
    self.menu_items.navbar_settings = buildSettingsMenu()
    orig_setUpdateItemTable(self)
end
