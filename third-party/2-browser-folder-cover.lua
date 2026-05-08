local AlphaContainer = require("ui/widget/container/alphacontainer")
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local userpatch = require("userpatch")
local util = require("util")

local _ = require("gettext")
local Screen = Device.screen
local list_scale_by_size = Screen:scaleBySize(1000000) * (1/1000000)

-- Stretched covers: consistent aspect ratio across all mosaic tiles
local aspect_ratio = 2 / 3
local stretch_limit = 50

local FolderCover = {
    name = ".cover",
    exts = { ".jpg", ".jpeg", ".png", ".webp", ".gif" },
}

local function findCover(dir_path)
    local path = dir_path .. "/" .. FolderCover.name
    for _, ext in ipairs(FolderCover.exts) do
        local fname = path .. ext
        if util.fileExists(fname) then return fname end
    end
end

local function getMenuItem(menu, ...) -- path
    local function findItem(sub_items, texts)
        local find = {}
        local texts = type(texts) == "table" and texts or { texts }
        -- stylua: ignore
        for _, text in ipairs(texts) do find[text] = true end
        for _, item in ipairs(sub_items) do
            local text = item.text or (item.text_func and item.text_func())
            if text and find[text] then return item end
        end
    end

    local sub_items, item
    for _, texts in ipairs { ... } do -- walk path
        sub_items = (item or menu).sub_item_table
        if not sub_items then return end
        item = findItem(sub_items, texts)
        if not item then return end
    end
    return item
end

local function toKey(...)
    local keys = {}
    for _, key in pairs { ... } do
        if type(key) == "table" then
            table.insert(keys, "table")
            for k, v in pairs(key) do
                table.insert(keys, tostring(k))
                table.insert(keys, tostring(v))
            end
        else
            table.insert(keys, tostring(key))
        end
    end
    return table.concat(keys, "")
end

local orig_FileChooser_getListItem = FileChooser.getListItem
local cached_list = {}
local cached_count = 0
local CACHE_MAX = 500

function FileChooser:getListItem(dirpath, f, fullpath, attributes, collate)
    local filter_status = self.show_filter and self.show_filter.status
    local key = toKey(dirpath, f, fullpath, attributes, collate, filter_status)
    if cached_list[key] == nil then
        if cached_count >= CACHE_MAX then
            cached_list = {}
            cached_count = 0
        end
        cached_list[key] = orig_FileChooser_getListItem(self, dirpath, f, fullpath, attributes, collate)
        cached_count = cached_count + 1
    end
    return cached_list[key]
end

local function capitalize(sentence)
    local words = {}
    for word in sentence:gmatch("%S+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2):lower())
    end
    return table.concat(words, " ")
end

local Folder = {
    edge = {
        thick = Screen:scaleBySize(2.5),
        margin = Size.line.medium,
        color = Blitbuffer.COLOR_GRAY_4,
        width = 0.97,
    },
    face = {
        border_size = Size.border.thick,
        alpha = 0.75,
        nb_items_font_size = 20,
        nb_items_margin = Screen:scaleBySize(5),
        nb_items_badge_padding = Screen:scaleBySize(4),
        dir_max_font_size = 25,
    },
}

local function patchCoverBrowser(plugin)
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not MosaicMenuItem then return end -- Protect against remnants of project title
    local BookInfoManager = userpatch.getUpValue(MosaicMenuItem.update, "BookInfoManager")
    local original_update = MosaicMenuItem.update

    -- Stretched covers: replace ImageWidget in the original update closure so book covers
    -- also get a consistent aspect ratio (folders are handled separately in _setFolderCover).
    -- Wrapped in pcall: if this fails, folder covers and menus still work.
    local stretch_ok, stretch_err = pcall(function()
        local local_ImageWidget, iw_n
        local n = 1
        while true do
            local name, value = debug.getupvalue(original_update, n)
            if not name then break end
            if name == "ImageWidget" then
                local_ImageWidget = value
                iw_n = n
                break
            end
            n = n + 1
        end

        if local_ImageWidget and iw_n then
            local orig_init = MosaicMenuItem.init
            local max_img_w, max_img_h

            function MosaicMenuItem:init()
                if self.width and self.height then
                    local border_size = Size.border.thin
                    max_img_w = self.width - 2 * border_size
                    max_img_h = self.height - 2 * border_size
                end
                if orig_init then orig_init(self) end
            end

            local Stretched = local_ImageWidget:extend{}
            function Stretched:init()
                if local_ImageWidget.init then local_ImageWidget.init(self) end
                if not max_img_w or not max_img_h then return end
                self.scale_factor = nil
                self.stretch_limit_percentage = stretch_limit
                local ratio = aspect_ratio
                if max_img_w / max_img_h > ratio then
                    self.height = max_img_h
                    self.width = math.floor(max_img_h * ratio)
                else
                    self.width = max_img_w
                    self.height = math.floor(max_img_w / ratio)
                end
            end

            debug.setupvalue(original_update, iw_n, Stretched)
        end
    end)
    if not stretch_ok then
        require("logger").warn("2-browser-folder-cover: stretched covers failed:", stretch_err)
    end

    local badge_size_default = 26
    local badge_border_default = 1
    local function getBadgeSizeNominal()
        return BookInfoManager:getSetting("folder_badge_size") or badge_size_default
    end
    local function getBadgeSize()
        return Screen:scaleBySize(getBadgeSizeNominal())
    end
    local function getBadgeBorderNominal()
        return BookInfoManager:getSetting("folder_badge_border") or badge_border_default
    end
    local function getBadgeBorder()
        return Screen:scaleBySize(getBadgeBorderNominal())
    end
    local function getBadgeFontSize()
        return math.max(8, math.floor(getBadgeSizeNominal() * Folder.face.nb_items_font_size / badge_size_default + 0.5))
    end

    -- setting
    local function BooleanSetting(text, name, default)
        local setting_item = { text = text }
        setting_item.get = function()
            local setting = BookInfoManager:getSetting(name)
            if default then return not setting end -- false is stored as nil, so we need or own logic for boolean default
            return setting
        end
        setting_item.toggle = function() return BookInfoManager:toggleSetting(name) end
        return setting_item
    end

    local settings = {
        crop_to_fit = BooleanSetting(_("Crop folder custom image"), "folder_crop_custom_image", true),
        name_centered = BooleanSetting(_("Folder name centered"), "folder_name_centered", true),
        show_folder_name = BooleanSetting(_("Show folder name"), "folder_name_show", true),
    }

    -- cover item
    function MosaicMenuItem:update(...)
        original_update(self, ...)
        if self._foldercover_processed or self.menu.no_refresh_covers or not self.do_cover_image then return end

        if self.entry.is_go_up then
            self._foldercover_processed = true
            self:_setUpFolderTile()
            return
        end

        if self.entry.is_file or self.entry.file or not self.mandatory then return end -- it's a file
        local dir_path = self.entry and self.entry.path
        if not dir_path then return end

        self._foldercover_processed = true

        local cover_file = findCover(dir_path) --custom
        if cover_file then
            local success, w, h = pcall(function()
                local tmp_img = ImageWidget:new { file = cover_file, scale_factor = 1 }
                tmp_img:_render()
                local orig_w = tmp_img:getOriginalWidth()
                local orig_h = tmp_img:getOriginalHeight()
                tmp_img:free()
                return orig_w, orig_h
            end)
            if success then
                self:_setFolderCover { file = cover_file, w = w, h = h, scale_to_fit = settings.crop_to_fit.get() }
                return
            end
        end

        self.menu._dummy = true
        local entries = self.menu:genItemTableFromPath(dir_path) -- sorted
        self.menu._dummy = false
        if not entries then return end

        for _, entry in ipairs(entries) do
            if entry.is_file or entry.file then
                local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                if
                    bookinfo
                    and bookinfo.cover_bb
                    and bookinfo.has_cover
                    and bookinfo.cover_fetched
                    and not bookinfo.ignore_cover
                    and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
                then
                    self:_setFolderCover { data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                    break
                end
            end
        end
    end

    function MosaicMenuItem:_setFolderCover(img)
        local top_h = 2 * (Folder.edge.thick + Folder.edge.margin)
        local target = {
            w = self.width - 2 * Folder.face.border_size,
            h = self.height - 2 * Folder.face.border_size - top_h,
        }

        if target.w / target.h > aspect_ratio then
            target.w = math.floor(target.h * aspect_ratio)
        else
            target.h = math.floor(target.w / aspect_ratio)
        end

        local img_options = { file = img.file, image = img.data }
        if img.scale_to_fit then
            img_options.scale_factor = math.max(target.w / img.w, target.h / img.h)
            img_options.width = target.w
            img_options.height = target.h
        else
            img_options.width = target.w
            img_options.height = target.h
            img_options.stretch_limit_percentage = stretch_limit
        end

        local image = ImageWidget:new(img_options)
        local size = image:getSize()
        local dimen = { w = size.w + 2 * Folder.face.border_size, h = size.h + 2 * Folder.face.border_size }

        local image_widget = FrameContainer:new {
            padding = 0,
            bordersize = Folder.face.border_size,
            image,
            overlap_align = "center",
        }

        local directory, nbitems = self:_getTextBoxes({ w = size.w, h = size.h }, getBadgeFontSize())

        local folder_name_widget
        if settings.show_folder_name.get() then
            folder_name_widget = (settings.name_centered.get() and CenterContainer or TopContainer):new {
                dimen = dimen,
                FrameContainer:new {
                    padding = 0,
                    bordersize = Folder.face.border_size,
                    AlphaContainer:new { alpha = Folder.face.alpha, directory },
                },
                overlap_align = "center",
            }
        else
            folder_name_widget = VerticalSpan:new { width = 0 }
        end

        local nbitems_widget
        if tonumber(nbitems.text) ~= 0 then
            local badge_h = getBadgeSize()
            local badge_margin = Folder.face.nb_items_margin
            local badge_padding = Folder.face.nb_items_badge_padding
            local text_w = nbitems:getSize().w
            local badge_w = math.max(badge_h, text_w + badge_padding * 2)
            nbitems_widget = BottomContainer:new {
                dimen = dimen,
                RightContainer:new {
                    dimen = {
                        w = dimen.w - badge_margin,
                        h = badge_h + badge_margin * 2,
                    },
                    FrameContainer:new {
                        padding = 0,
                        bordersize = getBadgeBorder(),
                        radius = 0,
                        background = Blitbuffer.COLOR_WHITE,
                        CenterContainer:new { dimen = { w = badge_w, h = badge_h }, nbitems },
                    },
                },
                overlap_align = "center",
            }
        else
            nbitems_widget = VerticalSpan:new { width = 0 }
        end

        local widget = CenterContainer:new {
            dimen = { w = self.width, h = self.height },
            VerticalGroup:new {
                VerticalSpan:new { width = math.max(0, math.ceil((self.height - (top_h + dimen.h)) * 0.5)) },
                LineWidget:new {
                    background = Folder.edge.color,
                    dimen = { w = math.floor(dimen.w * (Folder.edge.width ^ 2)), h = Folder.edge.thick },
                },
                VerticalSpan:new { width = Folder.edge.margin },
                LineWidget:new {
                    background = Folder.edge.color,
                    dimen = { w = math.floor(dimen.w * Folder.edge.width), h = Folder.edge.thick },
                },
                VerticalSpan:new { width = Folder.edge.margin },
                OverlapGroup:new {
                    dimen = { w = self.width, h = self.height - top_h },
                    image_widget,
                    folder_name_widget,
                    nbitems_widget,
                },
            },
        }
        if self._underline_container[1] then
            local previous_widget = self._underline_container[1]
            previous_widget:free()
        end

        self._underline_container[1] = widget
    end

    function MosaicMenuItem:_getTextBoxes(dimen, badge_font_size)
        local nbitems = TextWidget:new {
            text = self.mandatory:match("(%d+) \u{F016}") or "", -- nb books
            face = Font:getFace("cfont", badge_font_size or Folder.face.nb_items_font_size),
            bold = true,
            padding = 0,
        }

        local text = self.text
        if text:match("/$") then text = text:sub(1, -2) end -- remove "/"
        text = BD.directory(capitalize(text))
        local available_height = dimen.h - 2 * nbitems:getSize().h
        local dir_font_size = Folder.face.dir_max_font_size
        local directory

        while true do
            if directory then directory:free(true) end
            directory = TextBoxWidget:new {
                text = text,
                face = Font:getFace("cfont", dir_font_size),
                width = dimen.w,
                alignment = "center",
                bold = true,
            }
            if directory:getSize().h <= available_height then break end
            dir_font_size = dir_font_size - 1
            if dir_font_size < 10 then -- don't go too low
                directory:free()
                directory.height = available_height
                directory.height_adjust = true
                directory.height_overflow_show_ellipsis = true
                directory:init()
                break
            end
        end

        return directory, nbitems
    end

    function MosaicMenuItem:_setUpFolderTile()
        local margin = Screen:scaleBySize(5)
        local padding = Screen:scaleBySize(5)
        local border_size = Size.border.thick
        local dimen_in = {
            w = self.width - (margin + padding + border_size) * 2,
            h = self.height - (margin + padding + border_size) * 2,
        }

        local icon_size = math.floor(math.min(dimen_in.w, dimen_in.h) * 0.5)
        local icon = IconWidget:new{
            icon = BD.mirroredUILayout() and "back.top.rtl" or "back.top",
            width = icon_size,
            height = icon_size,
        }

        local widget = FrameContainer:new{
            width = self.width,
            height = self.height,
            margin = margin,
            padding = padding,
            bordersize = border_size,
            radius = Screen:scaleBySize(10),
            CenterContainer:new{
                dimen = dimen_in,
                icon,
            },
        }

        if self._underline_container[1] then
            local previous_widget = self._underline_container[1]
            previous_widget:free()
        end
        self._underline_container[1] = widget
    end

    -- List view folder covers
    local ListMenu = require("listmenu")
    local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if ListMenuItem then
        local original_list_update = ListMenuItem.update

        function ListMenuItem:update(...)
            original_list_update(self, ...)
            if self._foldercover_processed or self.menu.no_refresh_covers or not self.do_cover_image then return end
            if self.entry.is_file or self.entry.file or not self.mandatory then return end
            local dir_path = self.entry and self.entry.path
            if not dir_path then return end

            self._foldercover_processed = true

            local cover_file = findCover(dir_path)
            if cover_file then
                local success, w, h = pcall(function()
                    local tmp_img = ImageWidget:new { file = cover_file, scale_factor = 1 }
                    tmp_img:_render()
                    local orig_w = tmp_img:getOriginalWidth()
                    local orig_h = tmp_img:getOriginalHeight()
                    tmp_img:free()
                    return orig_w, orig_h
                end)
                if success then
                    self:_setListFolderCover { file = cover_file, w = w, h = h, scale_to_fit = settings.crop_to_fit.get() }
                    return
                end
            end

            self.menu._dummy = true
            local entries = self.menu:genItemTableFromPath(dir_path)
            self.menu._dummy = false
            if not entries then return end

            for _, entry in ipairs(entries) do
                if entry.is_file or entry.file then
                    local bookinfo = BookInfoManager:getBookInfo(entry.path, true)
                    if
                        bookinfo
                        and bookinfo.cover_bb
                        and bookinfo.has_cover
                        and bookinfo.cover_fetched
                        and not bookinfo.ignore_cover
                        and not BookInfoManager.isCachedCoverInvalid(bookinfo, self.menu.cover_specs)
                    then
                        self:_setListFolderCover { data = bookinfo.cover_bb, w = bookinfo.cover_w, h = bookinfo.cover_h }
                        break
                    end
                end
            end
        end

        function ListMenuItem:_setListFolderCover(img)
            local dimen = {
                w = self.width,
                h = self.height - 2 * self.underline_h,
            }

            local border_size = Size.border.thin
            local max_img_w = dimen.h - 2 * border_size
            local max_img_h = dimen.h - 2 * border_size
            local wleft_width = dimen.h

            local img_options = { file = img.file, image = img.data }
            if img.scale_to_fit then
                img_options.scale_factor = math.max(max_img_w / img.w, max_img_h / img.h)
                img_options.width = max_img_w
                img_options.height = max_img_h
            else
                img_options.scale_factor = math.min(max_img_w / img.w, max_img_h / img.h)
            end

            local image = ImageWidget:new(img_options)
            image:_render()
            local image_size = image:getSize()

            local wleft = CenterContainer:new{
                dimen = { w = wleft_width, h = dimen.h },
                FrameContainer:new{
                    width = image_size.w + 2 * border_size,
                    height = image_size.h + 2 * border_size,
                    margin = 0,
                    padding = 0,
                    bordersize = border_size,
                    image,
                },
            }

            local function _fontSize(nominal, max)
                local font_size = math.floor(nominal * dimen.h * (1 / 64) / list_scale_by_size)
                if max and font_size >= max then return max end
                return font_size
            end

            local pad_width = Screen:scaleBySize(10)
            local wright = TextWidget:new{
                text = self.mandatory or "",
                face = Font:getFace("infont", _fontSize(14, 18)),
            }
            local wright_width = wright:getWidth()

            local wmain_left_padding = Screen:scaleBySize(5)
            local wmain_width = dimen.w - wleft_width - wmain_left_padding - pad_width - wright_width - pad_width

            local text = self.text
            if text:match("/$") then text = text:sub(1, -2) end
            text = BD.directory(capitalize(text))

            local wname = TextBoxWidget:new{
                text = text,
                face = Font:getFace("cfont", _fontSize(20, 24)),
                width = wmain_width,
                alignment = "left",
                bold = true,
                height = dimen.h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }

            local widget = OverlapGroup:new{
                dimen = { w = dimen.w, h = dimen.h },
            }
            table.insert(widget, wleft)
            table.insert(widget, LeftContainer:new{
                dimen = { w = dimen.w, h = dimen.h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = wleft_width },
                    HorizontalSpan:new{ width = wmain_left_padding },
                    wname,
                },
            })
            table.insert(widget, RightContainer:new{
                dimen = { w = dimen.w, h = dimen.h },
                HorizontalGroup:new{
                    wright,
                    HorizontalSpan:new{ width = pad_width },
                },
            })

            self.menu._has_cover_images = true
            self._has_cover_image = true

            if self._underline_container[1] then
                local previous_widget = self._underline_container[1]
                previous_widget:free()
            end
            self._underline_container[1] = VerticalGroup:new{
                VerticalSpan:new{ width = self.underline_h },
                widget,
            }
        end
    end

    -- menu
    local orig_CoverBrowser_addToMainMenu = plugin.addToMainMenu

    function plugin:addToMainMenu(menu_items)
        orig_CoverBrowser_addToMainMenu(self, menu_items)
        if menu_items.filebrowser_settings == nil then return end

        local item = getMenuItem(menu_items.filebrowser_settings, _("Mosaic and detailed list settings"))
        if item then
            item.sub_item_table[#item.sub_item_table].separator = true
            for _k, setting in pairs(settings) do
                if
                    not getMenuItem( -- already exists ?
                        menu_items.filebrowser_settings,
                        _("Mosaic and detailed list settings"),
                        setting.text
                    )
                then
                    table.insert(item.sub_item_table, {
                        text = setting.text,
                        checked_func = function() return setting.get() end,
                        callback = function()
                            setting.toggle()
                            self.ui.file_chooser:updateItems()
                        end,
                    })
                end
            end

            local badge_text = _("Badge size")
            local badge_found = false
            for _, sub_item in ipairs(item.sub_item_table) do
                local t = sub_item.text_func and sub_item.text_func() or sub_item.text
                if t and t:find(badge_text, 1, true) then badge_found = true; break end
            end
            if not badge_found then
                table.insert(item.sub_item_table, {
                    text_func = function()
                        return badge_text .. ": " .. tostring(BookInfoManager:getSetting("folder_badge_size") or badge_size_default)
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = badge_text,
                            value = BookInfoManager:getSetting("folder_badge_size") or badge_size_default,
                            value_min = 16,
                            value_max = 48,
                            value_step = 2,
                            default_value = badge_size_default,
                            callback = function(spin)
                                BookInfoManager:saveSetting("folder_badge_size", spin.value)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                self.ui.file_chooser:updateItems()
                            end,
                        })
                    end,
                })
            end

            local border_text = _("Badge border")
            local border_found = false
            for _, sub_item in ipairs(item.sub_item_table) do
                local t = sub_item.text_func and sub_item.text_func() or sub_item.text
                if t and t:find(border_text, 1, true) then border_found = true; break end
            end
            if not border_found then
                table.insert(item.sub_item_table, {
                    text_func = function()
                        return border_text .. ": " .. tostring(BookInfoManager:getSetting("folder_badge_border") or badge_border_default)
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        UIManager:show(SpinWidget:new{
                            title_text = border_text,
                            value = BookInfoManager:getSetting("folder_badge_border") or badge_border_default,
                            value_min = 0,
                            value_max = 8,
                            value_step = 1,
                            default_value = badge_border_default,
                            callback = function(spin)
                                BookInfoManager:saveSetting("folder_badge_border", spin.value)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                self.ui.file_chooser:updateItems()
                            end,
                        })
                    end,
                })
            end
        end
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)
