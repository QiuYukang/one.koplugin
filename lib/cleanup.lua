local lfs = require("libs/libkoreader-lfs")

-- Cache accounting and cleanup over the per-date folder layout
-- (<cache_dir>/<iso_date>/... and <cache_dir>/collections/...). Images and
-- generated EPUBs are disposable and age out; the small issue.lua metadata is
-- kept so any EPUB can be rebuilt offline (guide §4.5).

local Cleanup = {}

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true }

local function is_image(name)
    local ext = name:match("%.([%w]+)$")
    return ext ~= nil and IMAGE_EXT[ext:lower()] == true
end

local function is_epub(name)
    return name:lower():match("%.epub$") ~= nil
end

local function subdirs(root)
    local dirs = {}
    if not lfs.attributes(root, "mode") then
        return dirs
    end
    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." then
            local path = root .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                dirs[#dirs + 1] = { name = name, path = path }
            end
        end
    end
    return dirs
end

local function files_in(dir)
    local files = {}
    if not lfs.attributes(dir, "mode") then
        return files
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                files[#files + 1] = {
                    name = name, path = path,
                    size = attr.size or 0, mtime = attr.modification or 0,
                }
            end
        end
    end
    return files
end

-- Days since an ISO-named folder's date; nil if the name isn't a date.
local function folder_age_days(name)
    local y, m, d = name:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then
        return nil
    end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    return math.floor((os.time() - t) / 86400 + 0.5)
end

function Cleanup.human_size(bytes)
    bytes = bytes or 0
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    elseif bytes >= 1024 * 1024 then
        return string.format("%.0f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return tostring(bytes) .. " B"
end

-- Aggregate stats used by the settings/cache screens.
function Cleanup.stats(settings)
    local img_bytes, epub_bytes, total_bytes = 0, 0, 0
    local issue_count = 0
    for _, dir in ipairs(subdirs(settings.cache_dir)) do
        local has_meta = false
        for _, f in ipairs(files_in(dir.path)) do
            total_bytes = total_bytes + f.size
            if is_image(f.name) then
                img_bytes = img_bytes + f.size
            elseif is_epub(f.name) then
                epub_bytes = epub_bytes + f.size
            elseif f.name == "issue.lua" then
                has_meta = true
            end
        end
        if has_meta and dir.name ~= "collections" then
            issue_count = issue_count + 1
        end
    end
    return {
        img_bytes = img_bytes,
        epub_bytes = epub_bytes,
        total_bytes = total_bytes,
        issue_count = issue_count,
    }
end

function Cleanup.issue_count(settings)
    return Cleanup.stats(settings).issue_count
end

-- Delete image + EPUB files older than `days`, keeping issue.lua. Date-named
-- folders use their date; other folders (collections, id-*) use file mtime.
-- `days <= 0` means "never clean" -> no-op.
function Cleanup.run(settings, days)
    local summary = { images_removed = 0, epubs_removed = 0, bytes_freed = 0 }
    days = tonumber(days) or 0
    if days <= 0 then
        return summary
    end
    local cutoff = os.time() - days * 86400
    for _, dir in ipairs(subdirs(settings.cache_dir)) do
        local age = folder_age_days(dir.name)
        for _, f in ipairs(files_in(dir.path)) do
            local old
            if age ~= nil then
                old = age > days
            else
                old = f.mtime < cutoff
            end
            if old then
                if is_image(f.name) and os.remove(f.path) then
                    summary.images_removed = summary.images_removed + 1
                    summary.bytes_freed = summary.bytes_freed + f.size
                elseif is_epub(f.name) and os.remove(f.path) then
                    summary.epubs_removed = summary.epubs_removed + 1
                    summary.bytes_freed = summary.bytes_freed + f.size
                end
            end
        end
    end
    return summary
end

-- Enforce an image-cache size cap by deleting the oldest images until under
-- `max_mb`. Returns count removed and bytes freed.
function Cleanup.enforce_limit(settings, max_mb)
    max_mb = tonumber(max_mb) or 0
    if max_mb <= 0 then
        return 0, 0
    end
    local limit = max_mb * 1024 * 1024
    local images = {}
    local total = 0
    for _, dir in ipairs(subdirs(settings.cache_dir)) do
        for _, f in ipairs(files_in(dir.path)) do
            if is_image(f.name) then
                images[#images + 1] = f
                total = total + f.size
            end
        end
    end
    if total <= limit then
        return 0, 0
    end
    table.sort(images, function(a, b) return a.mtime < b.mtime end)
    local removed, freed = 0, 0
    for _, f in ipairs(images) do
        if total <= limit then
            break
        end
        if os.remove(f.path) then
            removed = removed + 1
            freed = freed + f.size
            total = total - f.size
        end
    end
    return removed, freed
end

-- Remove files across all folders matching a predicate. Returns count, bytes.
local function clear_matching(settings, predicate)
    local removed, bytes = 0, 0
    for _, dir in ipairs(subdirs(settings.cache_dir)) do
        for _, f in ipairs(files_in(dir.path)) do
            if predicate(f.name) and os.remove(f.path) then
                removed = removed + 1
                bytes = bytes + f.size
            end
        end
    end
    return removed, bytes
end

function Cleanup.clear_images(settings)
    return clear_matching(settings, is_image)
end

function Cleanup.clear_epubs(settings)
    return clear_matching(settings, is_epub)
end

-- Clear everything, including metadata JSON and folders (irreversible).
function Cleanup.clear_all(settings)
    local removed = clear_matching(settings, function() return true end)
    -- Remove now-empty folders (best effort).
    for _, dir in ipairs(subdirs(settings.cache_dir)) do
        os.remove(dir.path)
    end
    return removed
end

return Cleanup
