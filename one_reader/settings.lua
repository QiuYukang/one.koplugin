local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

local defaults = {
    content = {
        default_open = "today",      -- "today" | "menu"
        image_quality = "1080",      -- "orig" | "1080" | "900" | "600"
    },
    cache = {
        auto_cleanup = true,
        cleanup_days = 30,           -- 0 means "never clean"
        last_cleanup = 0,            -- os.time of last automatic cleanup
    },
    -- Cached index snapshot (today ids + recent lists), refreshed on fetch.
    index = {
        fetched_at = 0,
        images = {},
        articles = {},
        questions = {},
    },
    -- image_id -> { image_id, vol, iso_date, article_id, question_id, saved_at }
    cached = {},
    download_dir = "",               -- "" = use default_cache_dir
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function ensure_dir(path)
    if path and not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

-- Force the cache root to end in ".../one/cache". This makes it a plugin-owned
-- directory so "clear all cache" can never wipe unrelated user files, no matter
-- what folder the user picks. Idempotent when the path already ends correctly.
local function normalize_cache_dir(path)
    path = tostring(path or ""):gsub("/+$", "")
    if path == "" then
        return nil
    end
    if path:match("/one/cache$") then
        return path
    elseif path:match("/one$") then
        return path .. "/cache"
    end
    return path .. "/one/cache"
end

Settings.normalize_cache_dir = normalize_cache_dir

-- Create the cache dir and its parents. lfs.mkdir only makes one level, so walk
-- the path segment by segment.
local function ensure_dir_recursive(path)
    if not path or path == "" then
        return
    end
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    local current = prefix
    for segment in path:gmatch("[^/]+") do
        current = (current == "/" or current == "") and (current .. segment)
            or (current .. "/" .. segment)
        ensure_dir(current)
    end
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/one"
    ensure_dir(data_dir)
    local obj = setmetatable({
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache", -- already ends in one/cache
        settings_file = DataStorage:getSettingsDir() .. "/one.lua",
    }, self)
    obj.store = LuaSettings:open(obj.settings_file)

    -- cache_dir is the download root; user-overridable via download_dir. Always
    -- normalized to end in one/cache.
    local download_dir = obj.store:readSetting("download_dir", "")
    if type(download_dir) == "string" and download_dir ~= "" then
        obj.cache_dir = normalize_cache_dir(download_dir) or obj.default_cache_dir
    else
        obj.cache_dir = obj.default_cache_dir
    end
    ensure_dir_recursive(obj.cache_dir)
    return obj
end

-- Read a setting, merging stored values over defaults so newly-added keys in a
-- nested table always resolve to something sensible.
function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    local stored = self.store:readSetting(key, deepcopy(default))
    if type(stored) == "table" and type(default) == "table" then
        for dk, dv in pairs(default) do
            if stored[dk] == nil then
                stored[dk] = deepcopy(dv)
            end
        end
    end
    return stored
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
end

function Settings:flush()
    self.store:flush()
end

function Settings:get_cache_dir()
    return self.cache_dir
end

-- Change the cache root. The chosen path is normalized to end in one/cache, so
-- the stored/effective dir is always plugin-owned. Pass nil/"" to reset to the
-- default. Existing content stays in the old location (move it manually).
function Settings:set_cache_dir(path)
    local normalized = normalize_cache_dir(path)
    if not normalized then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", normalized)
        self.cache_dir = normalized
    end
    self:flush()
    ensure_dir_recursive(self.cache_dir)
    return self.cache_dir
end

return Settings
