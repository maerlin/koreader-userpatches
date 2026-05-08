--[[
Userpatch: KOSync Sync All

Adds a "Sync all progress" action to the Progress Sync (KOSync) plugin.

Features:
  - Push reading progress for every book in history to the server at once
  - Progress indicator during sync (X / Y)
  - Summary with pushed / failed / skipped counts
  - Detail view listing each failure reason and skipped book
  - Respects the configured checksum method (filename or partial MD5)
  - Automatically skips the quickstart guide

Menu: Progress sync > Sync all progress from this device
]]

local userpatch = require("userpatch")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template
local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ReadHistory = require("readhistory")
local DocSettings = require("docsettings")
local util = require("util")
local FFIUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local lfs = require("libs/libkoreader-lfs")

local function showInfo(text, timeout, height)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
        height = height,
        show_icon = false,
    })
end

local function getServiceSpecPath()
    return lfs.currentdir() .. "/plugins/kosync.koplugin/api.json"
end

local function getKOSyncClient()
    local ok, client = pcall(require, "KOSyncClient")
    if ok and client then
        return client
    end
    local ok2, client2 = pcall(require, "plugins/kosync.koplugin/KOSyncClient")
    if ok2 and client2 then
        return client2
    end
    local base = lfs.currentdir()
    local plugin_path = base .. "/plugins/kosync.koplugin/?.lua"
    local old_path = package.path
    package.path = plugin_path .. ";" .. old_path
    local ok3, client3 = pcall(require, "KOSyncClient")
    package.path = old_path
    if ok3 and client3 then
        return client3
    end
end

local quickstart_path = nil
local function isQuickStartFile(file_path)
    if not file_path or file_path == "" then
        return false
    end
    if not quickstart_path then
        local ok, QuickStart = pcall(require, "ui/quickstart")
        if ok and QuickStart and QuickStart.getQuickStart then
            local ok2, path = pcall(QuickStart.getQuickStart, QuickStart)
            if ok2 and path then
                quickstart_path = path
            end
        end
    end
    if not quickstart_path then
        return false
    end
    local file_real = FFIUtil.realpath(file_path) or file_path
    local quick_real = FFIUtil.realpath(quickstart_path) or quickstart_path
    return file_real == quick_real
end

local function syncAllProgressImpl(settings, device_id, service_spec, ensure_networking, interactive)
    if not settings or not settings.username or not settings.userkey then
        if interactive then
            showInfo(_("Please register or login before using the progress synchronization feature."), 3)
        end
        return
    end

    ReadHistory:reload(true)
    local history = ReadHistory.hist or {}
    local queue = {}
    local skipped_missing = 0
    local skipped_no_progress = 0
    local skipped_no_digest = 0
    local skipped_entries = {}

    for _i, item in ipairs(history) do
        if not item or not item.file or not item.select_enabled then
            skipped_missing = skipped_missing + 1
            if item and item.file then
                table.insert(skipped_entries, { file = item.file, reason = _("Missing file") })
            end
        elseif isQuickStartFile(item.file) then
            -- Always ignore the quickstart guide
        else
            local ok, doc_settings = pcall(DocSettings.open, DocSettings, item.file)
            if ok and doc_settings then
                local percentage = doc_settings:readSetting("percent_finished")
                local progress = doc_settings:readSetting("last_xpointer")
                    or doc_settings:readSetting("last_page")
                if percentage ~= nil and progress ~= nil then
                    local digest
                    if settings.checksum_method == 1 then
                        local _path, file_name = util.splitFilePathName(item.file)
                        if file_name then
                            digest = md5(file_name)
                        end
                    else
                        digest = doc_settings:readSetting("partial_md5_checksum")
                        if not digest then
                            digest = util.partialMD5(item.file)
                        end
                    end
                    if digest then
                        table.insert(queue, {
                            file = item.file,
                            digest = digest,
                            progress = progress,
                            percentage = percentage,
                        })
                    else
                        skipped_no_digest = skipped_no_digest + 1
                        table.insert(skipped_entries, { file = item.file, reason = _("Missing checksum") })
                    end
                else
                    skipped_no_progress = skipped_no_progress + 1
                    table.insert(skipped_entries, { file = item.file, reason = _("No progress data") })
                end
            else
                skipped_no_progress = skipped_no_progress + 1
                table.insert(skipped_entries, { file = item.file, reason = _("No progress data") })
            end
        end
    end

    local skipped = skipped_missing + skipped_no_progress + skipped_no_digest
    if #queue == 0 then
        if interactive then
            showInfo(_("No progress data found to sync."), 3)
        end
        return
    end

    local function runQueue()
        local pushed = 0
        local failed = 0
        local idx = 0
        local failures = {}
        local info
        local KOSyncClient = getKOSyncClient()
        if not KOSyncClient then
            if interactive then
                showInfo(_("KOSync client not available. Please restart KOReader."), 4)
            end
            return
        end
        local client = KOSyncClient:new{
            custom_url = settings.custom_server,
            service_spec = service_spec,
        }

        local function updateProgressInfo()
            if not interactive then
                return
            end
            local text = T(_("Syncing progress: %1 / %2"), idx, #queue)
            if info then
                UIManager:close(info)
            end
            info = InfoMessage:new{
                text = text,
                dismissable = false,
                show_icon = false,
            }
            UIManager:show(info)
            UIManager:forceRePaint()
        end

        local function showSummary()
            if not interactive then
                return
            end
            local summary = T(_("Sync complete.\nPushed: %1\nFailed: %2\nSkipped: %3"),
                pushed, failed, skipped)
            if failed > 0 or skipped > 0 then
                UIManager:show(ConfirmBox:new{
                    text = summary,
                    ok_text = _("Details"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        local lines = {}
                        if failed > 0 then
                            table.insert(lines, _("Failed:"))
                            for _i, entry in ipairs(failures) do
                                local _path, file_name = util.splitFilePathName(entry.file)
                                local name = file_name or entry.file
                                local err = entry.error or _("Unknown error")
                                table.insert(lines, "- " .. name .. ": " .. err)
                            end
                        end
                        if skipped > 0 then
                            if #lines > 0 then
                                table.insert(lines, "")
                            end
                            table.insert(lines, _("Skipped:"))
                            for _i, entry in ipairs(skipped_entries) do
                                local _path, file_name = util.splitFilePathName(entry.file)
                                local name = file_name or entry.file
                                local reason = entry.reason or _("Unknown reason")
                                table.insert(lines, "- " .. name .. ": " .. reason)
                            end
                        end
                        showInfo(table.concat(lines, "\n"), nil, Device.screen:scaleBySize(400))
                    end,
                })
            else
                showInfo(summary, 4)
            end
        end

        local function pushNext()
            idx = idx + 1
            if idx > #queue then
                if info then
                    UIManager:close(info)
                    UIManager:forceRePaint()
                end
                showSummary()
                return
            end
            if idx == 1 or idx % 5 == 0 or idx == #queue then
                updateProgressInfo()
            end
            local entry = queue[idx]
            local ok, err = pcall(client.update_progress,
                client,
                settings.username,
                settings.userkey,
                entry.digest,
                entry.progress,
                entry.percentage,
                Device.model,
                device_id,
                function(ok_cb, body)
                    if ok_cb then
                        pushed = pushed + 1
                    else
                        failed = failed + 1
                        local message = body and body.message or (body and tostring(body)) or _("Unknown error")
                        table.insert(failures, { file = entry.file, error = message })
                    end
                    pushNext()
                end)
            if not ok then
                if err then
                    logger.dbg("KOSync syncAllProgress error:", err)
                end
                failed = failed + 1
                table.insert(failures, { file = entry.file, error = tostring(err) })
                pushNext()
            end
        end

        updateProgressInfo()
        pushNext()
    end

    if ensure_networking then
        NetworkMgr:goOnlineToRun(function()
            runQueue()
        end)
    else
        runQueue()
    end
end

local function patchKOSync(plugin)
    if plugin._sync_all_userpatch_applied then
        return
    end
    plugin._sync_all_userpatch_applied = true

    function plugin:syncAllProgress(ensure_networking, interactive)
        local service_spec = self.path and (self.path .. "/api.json") or getServiceSpecPath()
        syncAllProgressImpl(self.settings, self.device_id, service_spec, ensure_networking, interactive)
    end

    local original_addToMainMenu = plugin.addToMainMenu
    plugin.addToMainMenu = function(self, menu_items)
        original_addToMainMenu(self, menu_items)
        local menu = menu_items.progress_sync
        if not menu or type(menu.sub_item_table) ~= "table" then
            return
        end
        local sub = menu.sub_item_table
        local insert_index = #sub
        if insert_index < 1 then
            insert_index = 1
        end
        table.insert(sub, insert_index, {
            text = _("Sync all progress from this device"),
            enabled_func = function()
                return self.settings and self.settings.userkey ~= nil
            end,
            callback = function()
                self:syncAllProgress(true, true)
            end,
            separator = true,
        })
    end
end

userpatch.registerPatchPluginFunc("kosync", patchKOSync)

-- Intentionally not adding a File Manager menu entry.
