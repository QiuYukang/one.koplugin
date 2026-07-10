local ConfirmBox = require("ui/widget/confirmbox")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local PathChooser = require("ui/widget/pathchooser")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("ffi/util").template

local Client = require("one_reader.client")
local Cleanup = require("one_reader.cleanup")
local DateIndex = require("one_reader.date_index")
local I18n = require("one_reader.i18n")
local One = require("one_reader.one")
local Settings = require("one_reader.settings")

-- `_` is the translation function; never reuse it as a loop placeholder here.
local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[ONE]"
local PROJECT_URL = "https://github.com/qiuyukang/one.koplugin"

local function log_error(err)
    return (tostring(err):gsub("[%c]+", " ")):sub(1, 400)
end

local function display_error(err)
    local text = tostring(err):match("^[^\r\n]+") or tostring(err)
    return #text > 200 and (text:sub(1, 200) .. "...") or text
end

local OnePlugin = WidgetContainer:extend{
    name = "one",
    is_doc_only = false,
    version = "0.2.0",
}

function OnePlugin:init()
    self.settings = Settings:new()
    self.client = Client:new()
    self._current_issue = nil
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:maybeAutoCleanup()
    logger.info(LOG_MODULE, "initialized v" .. self.version)
end

-- ---------------------------------------------------------------------------
-- Dispatcher actions (gestures / in-book navigation)
-- ---------------------------------------------------------------------------

function OnePlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("one_show", {
        category = "none", event = "ShowOne", title = _("ONE · 一个"),
        filemanager = true, reader = true,
    })
    Dispatcher:registerAction("one_next_issue", {
        category = "none", event = "OneNextIssue", title = _("Next issue"),
        reader = true,
    })
    Dispatcher:registerAction("one_prev_issue", {
        category = "none", event = "OnePrevIssue", title = _("Previous issue"),
        reader = true,
    })
end

function OnePlugin:onShowOne()
    local quick = self.settings:get("content").default_open == "today"
    if quick then
        self:fetchTodayAndOpen()
    else
        self:showMainMenuWidget()
    end
    return true
end

function OnePlugin:onOneNextIssue()
    self:openAdjacentIssue(1)
    return true
end

function OnePlugin:onOnePrevIssue()
    self:openAdjacentIssue(-1)
    return true
end

-- ---------------------------------------------------------------------------
-- Menu registration
-- ---------------------------------------------------------------------------

function OnePlugin:addToMainMenu(menu_items)
    menu_items.one = {
        text = _("ONE · 一个"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function OnePlugin:getMainMenuItems()
    return {
        {
            text = _("Today's issue"),
            keep_menu_open = false,
            callback = function() self:fetchTodayAndOpen() end,
        },
        {
            text = _("Recent 7 days"),
            keep_menu_open = false,
            callback = function() self:showRecent() end,
        },
        {
            text = _("Browse by date"),
            sub_item_table_func = function() return self:getBrowseByDateItems() end,
        },
        {
            text = _("Cached content"),
            keep_menu_open = false,
            callback = function() self:showCached() end,
        },
        {
            text = _("Settings"),
            sub_item_table_func = function() return self:getSettingsItems() end,
        },
        {
            text = T(_("About (v%1)"), self.version),
            keep_menu_open = true,
            callback = function() self:showAbout() end,
        },
    }
end

-- Standalone menu for the gesture entry point.
function OnePlugin:showMainMenuWidget()
    local menu = Menu:new{
        title = _("ONE · 一个"),
        item_table = self:getMainMenuItems(),
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- UI helpers (busy / info / network) -- mirrors the weread.koplugin pattern
-- ---------------------------------------------------------------------------

function OnePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function OnePlugin:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function() return NetworkMgr:isOnline() end)
    if not ok_online then
        return true
    end
    return online == true
end

-- Map a (stage, cur, total) progress tick to a display string. Runs in the child
-- (to write the progress file) so it must not touch `self`.
local function progress_text(stage, cur, total)
    if stage == "index" then
        return _("Locating date...")
    elseif stage == "image" then
        return _("Fetching image...")
    elseif stage == "article" then
        return _("Fetching article...")
    elseif stage == "question" then
        return _("Fetching question...")
    elseif stage == "images" and total and total > 0 then
        return T(_("Downloading images (%1/%2)..."), cur, total)
    elseif stage == "collect" and total then
        return T(_("Fetching %1/%2..."), cur, total)
    elseif stage == "build" then
        return _("Building EPUB...")
    end
    return _("Please wait...")
end

-- Run a network fetch with a working Cancel button AND live progress.
--
-- KOReader's socket I/O blocks the whole Lua VM, so a stuck request freezes the
-- UI and no in-process "cancel" tap can ever be handled. The only reliable way
-- to interrupt it is to run the work in a subprocess and kill it. We fork `job`
-- (modelled on Trapper:dismissableRunInSubprocess), poll it from the UI-alive
-- parent, and terminate the child if the user taps the progress box. The child
-- reports progress by writing a small file that the parent reads each tick and
-- shows in a normal centered InfoMessage.
--
--   job(progress)  runs in the CHILD. Calls progress(stage, cur, total) for UI
--                  updates and returns the result EPUB path as a string ("" =
--                  nothing found). Touches disk/network only -- never the UI.
--   on_done(path)  runs in the PARENT after success, with the returned path.
function OnePlugin:runFetch(label, busy_text, job, on_done)
    if not self:isNetworkOnline() then
        self:showInfo(T(_("%1 failed:\n%2"), label,
            _("No network connection. Please connect Wi-Fi and try again.")))
        return
    end
    local ffiutil = require("ffi/util")
    local progress_path = self.settings.cache_dir .. "/.one_progress"
    os.remove(progress_path)

    local co, cancelled, widget, current_text

    -- Show/refresh the progress box. Recreated only when the text changes (so
    -- e-ink refreshes match progress steps, as before). Tapping it cancels.
    local function set_text(text)
        if not text or text == "" then text = busy_text end
        if text == current_text and widget then
            return
        end
        current_text = text
        local new = InfoMessage:new{
            text = text .. "\n\n" .. _("Tap to cancel"),
            dismiss_callback = function() coroutine.resume(co, false) end,
        }
        UIManager:show(new)
        if widget then
            widget.dismiss_callback = nil
            UIManager:close(widget)
        end
        widget = new
        UIManager:forceRePaint()
    end

    local function reap(pid, read_fd)
        local collect
        collect = function()
            if read_fd and ffiutil.getNonBlockingReadSize(read_fd) ~= 0 then
                ffiutil.readAllFromFD(read_fd) -- unblock child's write() so it can exit
                read_fd = nil
            end
            if ffiutil.isSubProcessDone(pid) then
                if read_fd then ffiutil.readAllFromFD(read_fd) end
            else
                UIManager:scheduleIn(1, collect)
            end
        end
        UIManager:scheduleIn(1, collect)
    end

    co = coroutine.create(function()
        set_text(busy_text)
        local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
            local function progress(stage, cur, total)
                local tmp = progress_path .. ".tmp"
                local f = io.open(tmp, "w")
                if f then
                    f:write(progress_text(stage, cur, total))
                    f:close()
                    os.rename(tmp, progress_path) -- atomic: parent never reads a half file
                end
            end
            local ok, res = xpcall(function() return job(progress) end, debug.traceback)
            local out
            if ok then
                out = type(res) == "string" and res or ""
            else
                out = "ERR:" .. log_error(res)
            end
            ffiutil.writeToFD(write_fd, out, true)
        end, true)

        local result
        if not pid then
            -- No fork on this platform: run in-process (blocking, not cancelable).
            local ok, res = xpcall(function() return job(function() end) end, debug.traceback)
            result = ok and (type(res) == "string" and res or "") or ("ERR:" .. log_error(res))
        else
            while true do
                local tick = function()
                    if coroutine.status(co) == "suspended" then coroutine.resume(co, true) end
                end
                UIManager:scheduleIn(0.4, tick)
                local go_on = coroutine.yield() -- resumed by tick (true) or a tap (false)
                if not go_on then
                    UIManager:unschedule(tick)
                    cancelled = true
                    ffiutil.terminateSubProcess(pid)
                    reap(pid, read_fd)
                    break
                end
                local done = ffiutil.isSubProcessDone(pid)
                local ready = read_fd and ffiutil.getNonBlockingReadSize(read_fd) ~= 0
                if done or ready then
                    if read_fd then result = ffiutil.readAllFromFD(read_fd) end
                    if not done then reap(pid, nil) end
                    break
                end
                local f = io.open(progress_path, "r")
                if f then
                    local t = f:read("*a")
                    f:close()
                    set_text(t)
                end
            end
        end

        if widget then
            widget.dismiss_callback = nil
            UIManager:close(widget)
            widget = nil
        end
        os.remove(progress_path)

        if cancelled then
            logger.info(LOG_MODULE, "fetch cancelled:", label)
            return
        end
        result = result or ""
        if result:sub(1, 4) == "ERR:" then
            local err = result:sub(5)
            logger.err(LOG_MODULE, "fetch failed:", label, err)
            self:showInfo(T(_("%1 failed:\n%2"), label, self:friendlyError(err)))
            return
        end
        if result == "" then
            self:showInfo(_("No content."))
            return
        end
        One.rebuild_cache_index(self.settings) -- pick up the child's cache writes
        on_done(result)
    end)

    -- Start on the next tick so the triggering menu can close first.
    UIManager:nextTick(function() coroutine.resume(co) end)
end

-- Translate internal error tags into user-facing messages.
function OnePlugin:friendlyError(err)
    local text = tostring(err)
    if text:match("PARSE_") or text:match("Could not") then
        return _("The site structure may have changed. Please wait for a plugin update.")
    end
    return display_error(err)
end

function OnePlugin:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No content."))
        return
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

-- ---------------------------------------------------------------------------
-- Today
-- ---------------------------------------------------------------------------

function OnePlugin:fetchTodayAndOpen()
    -- If today's issue is already cached, open it straight from disk (no network).
    local t = os.date("*t")
    local iso = DateIndex.iso(t.year, t.month, t.day)
    local cached_path, cached_issue = One.build_cached_by_date(self.settings, iso)
    if cached_path then
        self._current_issue = cached_issue
        self:openFile(cached_path)
        return
    end
    self:runFetch(_("Today's issue"), _("Fetching today's issue..."), function(progress)
        local ids = One.today_ids(self.client, self.settings)
        return (One.prepare_issue(self.client, self.settings, ids,
            self.settings:get("content").image_quality, progress))
    end, function(path)
        self._current_issue = One.load_issue_by_path(path)
        self:openFile(path)
    end)
end

-- ---------------------------------------------------------------------------
-- Recent 7 days
-- ---------------------------------------------------------------------------

function OnePlugin:showRecent()
    -- The last 7 calendar days are known locally (ONE publishes one issue a day),
    -- so the list itself needs no network: we show it instantly, mark which days
    -- are already cached, and only go online when opening a not-yet-cached day.
    local t = os.date("*t")
    local base = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
    local entries = {}
    for i = 0, 6 do
        local dt = os.date("*t", base - i * 86400)
        entries[i + 1] = { date = DateIndex.iso(dt.year, dt.month, dt.day) }
    end
    local items = self:buildRecentItems(entries)
    UIManager:show(Menu:new{
        title = _("Recent 7 days"),
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    })
end

function OnePlugin:buildRecentItems(entries)
    local items = {}
    for i = 1, #entries do
        local entry = entries[i]
        local text
        if entry.date then
            -- VOL is a pure function of the date, so label it even when not cached.
            local y, m, d = entry.date:match("(%d+)-(%d+)-(%d+)")
            local vol = y and DateIndex.vol_from_date(tonumber(y), tonumber(m), tonumber(d))
            text = vol and (T(_("VOL.%1"), vol) .. " · " .. entry.date) or entry.date
        else
            text = "one/" .. tostring(entry.image_id)
        end
        local cached = entry.date and One.is_cached_by_date(self.settings, entry.date)
        items[i] = {
            text = text,
            mandatory = cached and _("cached") or nil,
            keep_menu_open = false,
            callback = function()
                self:openRecentEntry(entry)
            end,
        }
    end
    items[#items + 1] = {
        text = "▶ " .. T(_("Combine these %1 issues into one collection"), #entries),
        keep_menu_open = false,
        callback = function()
            self:downloadCollection(entries, _("Recent 7 days"))
        end,
    }
    return items
end

-- Open a recent-list entry, resolving its image by date first if needed.
function OnePlugin:openRecentEntry(entry)
    -- Already cached for this date? Open it straight from disk, no network.
    if entry.date then
        local cached_path, cached_issue = One.build_cached_by_date(self.settings, entry.date)
        if cached_path then
            self._current_issue = cached_issue
            self:openFile(cached_path)
            return
        end
    end
    self:runFetch(_("Today's issue"), _("Please wait..."), function(progress)
        local ids = One.ids_from_entry(self.client, self.settings, entry, progress)
        if not ids or not ids.image_id then
            return ""
        end
        return (One.prepare_issue(self.client, self.settings, ids,
            self.settings:get("content").image_quality, progress))
    end, function(path)
        self._current_issue = One.load_issue_by_path(path)
        self:openFile(path)
    end)
end

-- Fetch (or reuse cache) a full issue and open it.
function OnePlugin:openIssueByIds(ids)
    self:runFetch(_("Today's issue"), _("Please wait..."), function(progress)
        return (One.prepare_issue(self.client, self.settings, ids,
            self.settings:get("content").image_quality, progress))
    end, function(path)
        self._current_issue = One.load_issue_by_path(path)
        self:openFile(path)
    end)
end

-- ---------------------------------------------------------------------------
-- Browse by date
-- ---------------------------------------------------------------------------

-- Top level: a direct date picker plus one entry per month (newest first) back to
-- VOL.1's month. Each month drills into a day list; each day opens that single
-- issue. No range downloads -- browsing is pure single-day selection.
function OnePlugin:getBrowseByDateItems()
    local items = {
        {
            text = _("Pick a date..."),
            keep_menu_open = false,
            callback = function() self:showDatePicker() end,
        },
    }
    local today = os.date("*t")
    local y, m = today.year, today.month
    while (y > 2012) or (y == 2012 and m >= 10) do -- ONE began 2012-10
        local yy, mm = y, m
        items[#items + 1] = {
            text = string.format("%04d-%02d", yy, mm),
            sub_item_table_func = function() return self:getMonthDayItems(yy, mm) end,
        }
        m = m - 1
        if m == 0 then m = 12; y = y - 1 end
    end
    return items
end

-- Day list for one month, newest first. Future days and pre-launch days are
-- skipped. Each row shows VOL + date and whether it is already cached.
function OnePlugin:getMonthDayItems(y, m)
    local today = os.date("*t")
    local last = os.date("*t", os.time({ year = y, month = m + 1, day = 0, hour = 12 })).day
    local items = {}
    for d = last, 1, -1 do
        local future = DateIndex.days_between(today.year, today.month, today.day, y, m, d) > 0
        if not future and DateIndex.vol_from_date(y, m, d) >= 1 then
            local iso = DateIndex.iso(y, m, d)
            local vol = DateIndex.vol_from_date(y, m, d)
            -- This is a TouchMenu submenu, which does NOT render the `mandatory`
            -- field (unlike the Menu widget used by the recent list), so the
            -- cached mark has to go into the item text itself.
            local label = T(_("VOL.%1"), vol) .. " · " .. iso
            if One.is_cached_by_date(self.settings, iso) then
                label = label .. "  ✓ " .. _("cached")
            end
            items[#items + 1] = {
                text = label,
                keep_menu_open = false,
                callback = function() self:openByDate(y, m, d) end,
            }
        end
    end
    return items
end

function OnePlugin:showDatePicker()
    local today = os.date("*t")
    UIManager:show(DateTimeWidget:new{
        year = today.year, month = today.month, day = today.day,
        ok_text = _("OK"),
        title_text = _("Select date"),
        callback = function(time)
            self:openByDate(time.year, time.month, time.day)
        end,
    })
end

-- Validate a target date; returns true or shows an error and returns false.
function OnePlugin:validateDate(y, m, d)
    local today = os.date("*t")
    if DateIndex.days_between(today.year, today.month, today.day, y, m, d) > 0 then
        self:showInfo(_("This date is in the future."))
        return false
    end
    if DateIndex.vol_from_date(y, m, d) < 1 then
        self:showInfo(_("ONE started on 2012-10-07; earlier dates do not exist."))
        return false
    end
    return true
end

function OnePlugin:openByDate(y, m, d)
    if not self:validateDate(y, m, d) then
        return
    end
    -- Already cached for this date? Open it straight from disk, no network.
    local iso = DateIndex.iso(y, m, d)
    local cached_path, cached_issue = One.build_cached_by_date(self.settings, iso)
    if cached_path then
        self._current_issue = cached_issue
        self:openFile(cached_path)
        return
    end
    self:runFetch(_("Browse by date"), _("Locating date..."), function(progress)
        -- v3 gives full essay+question for a date; HTML fallback is image-only.
        local ids = One.ids_for_date(self.client, self.settings, y, m, d, progress)
        if not ids or not ids.image_id then
            return ""
        end
        return (One.prepare_issue(self.client, self.settings, ids,
            self.settings:get("content").image_quality, progress))
    end, function(path)
        self._current_issue = One.load_issue_by_path(path)
        self:openFile(path)
    end)
end


-- Combine a list of recent entries into a collection EPUB.
function OnePlugin:downloadCollection(entries, label)
    self:runFetch(label, T(_("Downloading %1 issues..."), #entries), function(progress)
        local quality = self.settings:get("content").image_quality
        local issues = {}
        for i = 1, #entries do
            progress("collect", i, #entries)
            local ids = One.ids_from_entry(self.client, self.settings, entries[i])
            if ids and ids.image_id then
                issues[#issues + 1] = One.fetch_issue(self.client, self.settings, ids, quality)
            end
        end
        if #issues == 0 then
            return ""
        end
        progress("build")
        local first = issues[1]
        local last = issues[#issues]
        local range_label = (last.iso_date or "") .. " – " .. (first.iso_date or "")
        return One.build_collection(self.settings, issues, range_label)
    end, function(path)
        self:openFile(path)
    end)
end

-- ---------------------------------------------------------------------------
-- Cached content
-- ---------------------------------------------------------------------------

function OnePlugin:showCached()
    -- Repair the index from disk first so the list always matches the folders.
    local cached = One.rebuild_cache_index(self.settings)
    local list = {}
    for _id, info in pairs(cached) do
        list[#list + 1] = info
    end
    if #list == 0 then
        self:showInfo(_("No cached content yet."))
        return
    end
    -- Newest issue first (by issue date, falling back to save time).
    table.sort(list, function(a, b)
        if a.iso_date and b.iso_date and a.iso_date ~= b.iso_date then
            return a.iso_date > b.iso_date
        end
        return (a.saved_at or 0) > (b.saved_at or 0)
    end)

    local stats = Cleanup.stats(self.settings)
    local items = {}
    for _i = 1, #list do
        local info = list[_i]
        items[_i] = {
            text = T(_("VOL.%1"), info.vol or "?") .. " · " .. tostring(info.iso_date or ""),
            mandatory = self:relativeDayLabel(info.iso_date),
            keep_menu_open = false,
            callback = function() self:openCachedIssue(info.image_id) end,
            hold_callback = function() self:confirmDeleteIssue(info.image_id) end,
        }
    end
    self._cached_menu = Menu:new{
        title = _("Cached content"),
        subtitle = T(_("%1 issues · %2"), #list, Cleanup.human_size(stats.total_bytes)),
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(self._cached_menu)
end

function OnePlugin:openCachedIssue(image_id)
    local path, issue = One.build_cached_issue(self.settings, image_id)
    if not path then
        -- Metadata gone (cleared): re-fetch if online.
        self:openIssueByIds({ image_id = image_id })
        return
    end
    self._current_issue = issue
    self:openFile(path)
end

function OnePlugin:confirmDeleteIssue(image_id)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this issue?"),
        ok_text = _("Delete"),
        ok_callback = function()
            One.delete_issue(self.settings, image_id)
            if self._cached_menu then
                UIManager:close(self._cached_menu)
                self._cached_menu = nil
            end
            self:showCached()
        end,
    })
end

function OnePlugin:relativeDayLabel(iso_date)
    if not iso_date then return nil end
    local y, m, d = iso_date:match("(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    local today = os.date("*t")
    local diff = DateIndex.days_between(tonumber(y), tonumber(m), tonumber(d),
        today.year, today.month, today.day)
    if diff <= 0 then
        return _("today")
    elseif diff == 1 then
        return _("1 day ago")
    end
    return T(_("%1 days ago"), diff)
end

-- ---------------------------------------------------------------------------
-- In-book adjacent-issue navigation
-- ---------------------------------------------------------------------------

function OnePlugin:openAdjacentIssue(direction)
    local issue = self._current_issue
    if not issue or not issue.iso_date then
        self:showInfo(_("No content."))
        return
    end
    local y, m, d = issue.iso_date:match("(%d+)-(%d+)-(%d+)")
    if not y then
        self:showInfo(_("No content."))
        return
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local dt = os.date("*t", t + direction * 86400)
    local today = os.date("*t")
    if direction > 0 and DateIndex.days_between(today.year, today.month, today.day, dt.year, dt.month, dt.day) > 0 then
        self:showInfo(_("This is the latest issue."))
        return
    end
    self:openByDate(dt.year, dt.month, dt.day)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function OnePlugin:getSettingsItems()
    return {
        {
            text = _("Content settings"),
            sub_item_table_func = function() return self:getContentSettingsItems() end,
        },
        {
            text = _("Cache management"),
            sub_item_table_func = function() return self:getCacheItems() end,
        },
    }
end

function OnePlugin:getContentSettingsItems()
    local content = self.settings:get("content")
    local function set_quality(q)
        content.image_quality = q
        self.settings:set("content", content)
        self.settings:flush()
    end
    return {
        {
            text = _("Open plugin to today's issue"),
            checked_func = function()
                return self.settings:get("content").default_open == "today"
            end,
            callback = function()
                local c = self.settings:get("content")
                c.default_open = (c.default_open == "today") and "menu" or "today"
                self.settings:set("content", c)
                self.settings:flush()
            end,
            keep_menu_open = true,
        },
        {
            text = _("Image quality"),
            sub_item_table = {
                {
                    text = _("600px"),
                    checked_func = function() return self.settings:get("content").image_quality == "600" end,
                    callback = function() set_quality("600") end,
                    keep_menu_open = true,
                },
                {
                    text = _("900px"),
                    checked_func = function() return self.settings:get("content").image_quality == "900" end,
                    callback = function() set_quality("900") end,
                    keep_menu_open = true,
                },
                {
                    text = _("1080px"),
                    checked_func = function() return self.settings:get("content").image_quality == "1080" end,
                    callback = function() set_quality("1080") end,
                    keep_menu_open = true,
                },
                {
                    text = _("Original"),
                    checked_func = function() return self.settings:get("content").image_quality == "orig" end,
                    callback = function() set_quality("orig") end,
                    keep_menu_open = true,
                },
            },
        },
    }
end

function OnePlugin:getCacheItems()
    return {
        {
            text_func = function()
                return T(_("Cache directory: %1"), self.settings:get_cache_dir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showCacheDirPicker(touchmenu_instance)
            end,
        },
        {
            text = _("Auto cleanup on start"),
            checked_func = function() return self.settings:get("cache").auto_cleanup end,
            callback = function()
                local c = self.settings:get("cache")
                c.auto_cleanup = not c.auto_cleanup
                self.settings:set("cache", c)
                self.settings:flush()
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                local days = self.settings:get("cache").cleanup_days
                local value = (days == 0) and _("Never clean") or T(_("%1 days"), days)
                return _("Cleanup threshold") .. ": " .. value
            end,
            enabled_func = function() return self.settings:get("cache").auto_cleanup end,
            sub_item_table_func = function() return self:getCleanupThresholdItems() end,
        },
        {
            text_func = function()
                return T(_("Last auto cleanup: %1"), self:lastCleanupLabel())
            end,
            enabled_func = function() return false end,
            keep_menu_open = true,
        },
        {
            text = _("Run cleanup now"),
            keep_menu_open = true,
            callback = function() self:runCleanupNow() end,
        },
        {
            text_func = function()
                return T(_("Clear all cache (%1)"),
                    Cleanup.human_size(Cleanup.stats(self.settings).total_bytes))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("Clear everything, including metadata JSON? This cannot be undone."),
                    ok_callback = function()
                        Cleanup.clear_all(self.settings)
                        self.settings:set("cached", {})
                        self.settings:flush()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        self:showInfo(_("Cleared."))
                    end,
                })
            end,
        },
    }
end

function OnePlugin:getCleanupThresholdItems()
    local function set_days(days)
        local c = self.settings:get("cache")
        c.cleanup_days = days
        self.settings:set("cache", c)
        self.settings:flush()
    end
    local items = {}
    for _i, days in ipairs({ 7, 15, 30, 60, 90, 180 }) do
        items[#items + 1] = {
            text = T(_("%1 days"), days),
            checked_func = function() return self.settings:get("cache").cleanup_days == days end,
            callback = function() set_days(days) end,
            keep_menu_open = true,
        }
    end
    items[#items + 1] = {
        text = _("Custom days..."),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                value = self.settings:get("cache").cleanup_days,
                value_min = 1, value_max = 3650,
                ok_text = _("OK"),
                title_text = _("Keep how long?"),
                callback = function(spin)
                    set_days(spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = _("Never clean"),
        checked_func = function() return self.settings:get("cache").cleanup_days == 0 end,
        callback = function() set_days(0) end,
        keep_menu_open = true,
    }
    return items
end

-- ---------------------------------------------------------------------------
-- Cleanup orchestration
-- ---------------------------------------------------------------------------

-- Validate a candidate cache directory: create if missing, confirm writable.
function OnePlugin:validateCacheDir(path)
    local lfs = require("libs/libkoreader-lfs")
    if type(path) ~= "string" or path == "" then
        return false
    end
    if not lfs.attributes(path, "mode") then
        os.execute("mkdir -p " .. string.format("%q", path))
        if not lfs.attributes(path, "mode") then
            return false
        end
    end
    local test = path .. "/.one_write_test"
    local f = io.open(test, "w")
    if not f then
        return false
    end
    f:close()
    os.remove(test)
    return true
end

function OnePlugin:showCacheDirPicker(touchmenu_instance)
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self.settings:get_cache_dir(),
        onConfirm = function(path)
            if not self:validateCacheDir(path) then
                self:showInfo(T(_("%1 failed:\n%2"), _("Cache directory"), _("Directory is not writable.")))
                return
            end
            self.settings:set_cache_dir(path)
            logger.info(LOG_MODULE, "cache directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:showInfo(T(_("Cache directory set to:\n%1"), path))
        end,
    }
    UIManager:show(chooser)
end

function OnePlugin:lastCleanupLabel()
    local last = self.settings:get("cache").last_cleanup or 0
    if last == 0 then
        return _("never")
    end
    return os.date("%Y-%m-%d %H:%M", last)
end

-- Run automatic cleanup at most once per ~12h on startup.
function OnePlugin:maybeAutoCleanup()
    local cache = self.settings:get("cache")
    if not cache.auto_cleanup then
        return
    end
    if os.time() - (cache.last_cleanup or 0) < 12 * 3600 then
        return
    end
    local summary = Cleanup.run(self.settings, cache.cleanup_days)
    cache.last_cleanup = os.time()
    self.settings:set("cache", cache)
    self.settings:flush()
    if summary.images_removed + summary.epubs_removed > 0 then
        -- Defer: init() runs before the UI event loop is fully ready.
        local text = T(_("Cleaned cache older than %1 days.\nRemoved %2 images, %3 EPUBs, freed %4."),
            cache.cleanup_days, summary.images_removed, summary.epubs_removed,
            Cleanup.human_size(summary.bytes_freed))
        UIManager:scheduleIn(2, function()
            Notification:notify(text)
        end)
    end
end

function OnePlugin:runCleanupNow()
    local cache = self.settings:get("cache")
    local summary = Cleanup.run(self.settings, cache.cleanup_days)
    cache.last_cleanup = os.time()
    self.settings:set("cache", cache)
    self.settings:flush()
    if summary.images_removed + summary.epubs_removed > 0 then
        self:showInfo(T(_("Cleaned cache older than %1 days.\nRemoved %2 images, %3 EPUBs, freed %4."),
            cache.cleanup_days, summary.images_removed, summary.epubs_removed,
            Cleanup.human_size(summary.bytes_freed)))
    else
        self:showInfo(_("Nothing to clean."))
    end
end

-- ---------------------------------------------------------------------------
-- About
-- ---------------------------------------------------------------------------

function OnePlugin:showAbout()
    self:showInfo(T(_("ONE · 一个 v%1\n\nOffline reader for wufazhuce.com daily content.\nThis project is for personal learning only. Please respect ONE's terms of use and applicable laws.\n\nData source: wufazhuce.com\nLicense: MIT"), self.version)
        .. "\n" .. PROJECT_URL)
end

return OnePlugin
