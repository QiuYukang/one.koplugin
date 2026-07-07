local lfs = require("libs/libkoreader-lfs")

-- Downloads ONE images to an explicit destination path chosen by the caller
-- (one.lua lays them out under per-date folders with readable names). EPUB
-- assembly reads bytes back from disk, so cached images rebuild EPUBs offline.

local ImageCache = {}

-- Qiniu CDN thumbnail params per quality tier (guide §6 / api-reference §6).
-- Keys match settings.content.image_quality.
local QUALITY_SUFFIX = {
    orig = nil,
    ["1080"] = "?imageMogr2/thumbnail/1080x/format/jpg",
    ["900"] = "?imageMogr2/thumbnail/900x/format/jpg",
    ["600"] = "?imageMogr2/thumbnail/600x/format/jpg",
}

-- Force https and drop any pre-existing query so we control sizing ourselves.
local function normalize_base(url)
    url = tostring(url or "")
    if url:match("^http://") then
        url = url:gsub("^http://", "https://")
    elseif url:match("^//") then
        url = "https:" .. url
    end
    return (url:gsub("[%?#].*$", ""))
end

-- Returns the request URL (with quality suffix) and the plain base URL.
function ImageCache.request_url(url, quality)
    local base = normalize_base(url)
    if base == "" then
        return nil
    end
    local suffix = QUALITY_SUFFIX[quality or "1080"]
    -- Only the qiniu-backed image host understands imageMogr2 params.
    if suffix and base:match("^https://image%.wufazhuce%.com/") then
        return base .. suffix, base
    end
    return base, base
end

local function ext_for(data)
    if not data or #data < 4 then
        return ".jpg"
    end
    if data:sub(1, 3) == "\255\216\255" then
        return ".jpg"
    elseif data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp"
    end
    return ".jpg"
end

function ImageCache.media_type(path)
    local lower = tostring(path or ""):lower()
    if lower:match("%.png$") then
        return "image/png"
    elseif lower:match("%.gif$") then
        return "image/gif"
    elseif lower:match("%.webp$") then
        return "image/webp"
    end
    return "image/jpeg"
end

-- Find an already-downloaded file matching `dir/stem.<ext>` for any known ext.
function ImageCache.existing(dir, stem)
    for _, ext in ipairs({ ".jpg", ".png", ".gif", ".webp" }) do
        local path = dir .. "/" .. stem .. ext
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
end

local function write_file(path, data)
    local file = io.open(path, "wb")
    if not file then
        return false
    end
    file:write(data)
    file:close()
    return true
end

-- Download `url` at `quality` into `dir` with base name `stem`. Reuses an
-- existing file if present. Returns the local absolute path, or nil on failure.
-- Falls back to the original-size URL if the thumbnail variant errors.
function ImageCache.get(client, dir, stem, url, quality)
    local existing = ImageCache.existing(dir, stem)
    if existing then
        return existing
    end
    local request_url, base_url = ImageCache.request_url(url, quality)
    if not request_url then
        return nil
    end
    local data = client:get_binary(request_url)
    if (not data or #data == 0) and request_url ~= base_url then
        data = client:get_binary(base_url)
    end
    if not data or #data == 0 then
        return nil
    end
    local path = dir .. "/" .. stem .. ext_for(data)
    if not write_file(path, data) then
        return nil
    end
    return path
end

-- Read raw bytes of a cached image file (for EPUB embedding).
function ImageCache.read_bytes(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

return ImageCache
