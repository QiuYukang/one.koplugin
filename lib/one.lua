local lfs = require("libs/libkoreader-lfs")
local Parser = require("lib.parser")
local DateIndex = require("lib.date_index")
local ImageCache = require("lib.image_cache")
local EpubBuilder = require("lib.epub_builder")
local HpIndex = require("lib.hp_index")
local V3 = require("lib.v3")

-- Service layer: fetch ONE content, cache it under per-date folders, resolve
-- images and build EPUBs. No UI here -- callers pass a `progress(stage, cur,
-- total)` closure and handle errors. Network functions raise on hard failure.
--
-- On-disk layout (root = settings.cache_dir):
--   <cache_dir>/<iso_date>/issue.lua        metadata (kept on cleanup)
--   <cache_dir>/<iso_date>/image.jpg        图文主图
--   <cache_dir>/<iso_date>/article-N.jpg    文章内嵌图
--   <cache_dir>/<iso_date>/question-N.jpg   问答内嵌图
--   <cache_dir>/<iso_date>/ONE VOL.xxxx.epub
--   <cache_dir>/collections/<range>.epub

local One = {}

local BASE = "https://wufazhuce.com"

-- One hp VOL->image_id index, created lazily per data dir and reused so lookups
-- and learned points share a single in-memory table.
local _hp_index_cache = {}
local function hp_index_for(settings)
    if not settings then
        return nil
    end
    local key = settings.data_dir or "default"
    local idx = _hp_index_cache[key]
    if not idx then
        idx = HpIndex.new(settings)
        _hp_index_cache[key] = idx
    end
    return idx
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function ensure_dir(path)
    if path and not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
    return path
end

-- Folder name for an issue: its ISO date, falling back to the image id.
local function issue_folder_name(issue_or_info)
    local iso = issue_or_info.iso_date
    if iso and iso ~= "" then
        return iso
    end
    local image_id = issue_or_info.image_id
        or (issue_or_info.image and issue_or_info.image.image_id)
    return "id-" .. tostring(image_id or "unknown")
end

local function issue_dir(settings, issue_or_info)
    return settings.cache_dir .. "/" .. issue_folder_name(issue_or_info)
end

-- Resolve the folder for a cached image id via the index snapshot.
local function dir_for_image_id(settings, image_id)
    local info = settings:get("cached", {})[tostring(image_id)]
    if info then
        return issue_dir(settings, info), info
    end
    return settings.cache_dir .. "/id-" .. tostring(image_id), nil
end

local function epub_name(issue)
    return EpubBuilder.filename_safe("ONE VOL." .. tostring(issue.vol or "x")) .. ".epub"
end

local function file_exists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- ---------------------------------------------------------------------------
-- Metadata persistence (small Lua chunks, no json dependency)
-- ---------------------------------------------------------------------------

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "table" then
        local parts = { "{\n" }
        local next_indent = indent .. "  "
        local is_array = true
        local n = 0
        for k in pairs(value) do
            n = n + 1
            if type(k) ~= "number" then
                is_array = false
            end
        end
        if is_array and n == #value then
            for _i = 1, #value do
                parts[#parts + 1] = next_indent .. serialize(value[_i], next_indent) .. ",\n"
            end
        else
            for k, v in pairs(value) do
                local key
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key = k
                else
                    key = "[" .. serialize(k, next_indent) .. "]"
                end
                parts[#parts + 1] = next_indent .. key .. " = " .. serialize(v, next_indent) .. ",\n"
            end
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts)
    end
    return "nil"
end

-- Deep-copy an issue while dropping volatile local_path fields, so issue.lua stays
-- portable if the cache dir moves (paths are recomputed from folder+stem on load).
local function without_local_paths(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        if k ~= "local_path" then
            out[k] = without_local_paths(v)
        end
    end
    return out
end

function One.save_issue(settings, issue)
    local image_id = issue.image and issue.image.image_id
    if not image_id then
        return
    end
    local dir = ensure_dir(issue_dir(settings, issue))
    local file = io.open(dir .. "/issue.lua", "w")
    if file then
        file:write("return " .. serialize(without_local_paths(issue)))
        file:close()
    end

    -- Maintain a lightweight index for fast cached-list rendering / lookup.
    local cached = settings:get("cached", {})
    cached[tostring(image_id)] = {
        image_id = tostring(image_id),
        vol = issue.vol,
        iso_date = issue.iso_date,
        article_id = issue.article and issue.article.article_id,
        question_id = issue.question and issue.question.question_id,
        saved_at = os.time(),
    }
    settings:set("cached", cached)
    settings:flush()
end

function One.load_issue(settings, image_id)
    local dir = dir_for_image_id(settings, image_id)
    local path = dir .. "/issue.lua"
    if not file_exists(path) then
        return nil
    end
    local ok, chunk = pcall(loadfile, path)
    if not ok or not chunk then
        return nil
    end
    local ok2, issue = pcall(chunk)
    if not ok2 or type(issue) ~= "table" then
        return nil
    end
    return issue
end

-- Load an issue's metadata from the issue.lua next to its EPUB. Used by the
-- parent process to recover the issue object (for adjacent-issue navigation)
-- after a subprocess fetch that only returns the EPUB path. Returns nil for
-- collection EPUBs (no per-issue metadata).
function One.load_issue_by_path(path)
    local dir = tostring(path or ""):match("^(.*)/[^/]+$")
    if not dir then
        return nil
    end
    local meta = dir .. "/issue.lua"
    if not file_exists(meta) then
        return nil
    end
    local ok, chunk = pcall(loadfile, meta)
    local issue = ok and chunk and select(2, pcall(chunk)) or nil
    return type(issue) == "table" and issue or nil
end

-- Rebuild the cached-issue index from disk truth. Each issue folder is
-- self-consistent (its name and issue.lua share one iso_date), but the settings
-- index can drift when a bad date resolution overwrote an image_id entry. Walking
-- the folders and reindexing by the issue's own image_id repairs that: it drops
-- phantom entries whose folder is gone and adds folders missing from the index.
function One.rebuild_cache_index(settings)
    local root = settings.cache_dir
    local cached = {}
    if lfs.attributes(root, "mode") == "directory" then
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." and name ~= "collections" then
                local path = root .. "/" .. name .. "/issue.lua"
                if file_exists(path) then
                    local ok, chunk = pcall(loadfile, path)
                    local issue = ok and chunk and select(2, pcall(chunk)) or nil
                    local image_id = type(issue) == "table" and issue.image and issue.image.image_id
                    if image_id then
                        cached[tostring(image_id)] = {
                            image_id = tostring(image_id),
                            vol = issue.vol,
                            iso_date = issue.iso_date,
                            article_id = issue.article and issue.article.article_id,
                            question_id = issue.question and issue.question.question_id,
                            saved_at = lfs.attributes(path, "modification") or os.time(),
                        }
                    end
                end
            end
        end
    end
    settings:set("cached", cached)
    settings:flush()
    return cached
end

-- ---------------------------------------------------------------------------
-- Fetching
-- ---------------------------------------------------------------------------

-- HTML index (fallback path only): today's ids + recent lists.
function One.fetch_index(client, settings)
    local body, code = client:get_text(BASE .. "/")
    if not body then
        error("index HTTP " .. tostring(code))
    end
    local index = Parser.parse_index(body)
    if not index.today.image_id then
        error("PARSE_INDEX")
    end
    index.fetched_at = os.time()
    if settings then
        settings:set("index", index)
        settings:flush()
    end
    return index
end

-- Detail fetchers: try the v3 JSON API first, fall back to HTML scraping.

function One.fetch_image(client, image_id)
    local img = V3.fetch_image(client, image_id)
    if img then
        return img
    end
    local body, code = client:get_text(BASE .. "/one/" .. tostring(image_id))
    if not body then
        return nil, (code == 404) and "404" or ("HTTP " .. tostring(code))
    end
    return Parser.parse_image(body, image_id)
end

function One.fetch_article(client, article_id)
    local art = V3.fetch_article(client, article_id)
    if art then
        return art
    end
    local body, code = client:get_text(BASE .. "/article/" .. tostring(article_id))
    if not body then
        return nil, (code == 404) and "404" or ("HTTP " .. tostring(code))
    end
    return Parser.parse_article(body, article_id)
end

function One.fetch_question(client, question_id)
    local q = V3.fetch_question(client, question_id)
    if q then
        return q
    end
    local body, code = client:get_text(BASE .. "/question/" .. tostring(question_id))
    if not body then
        return nil, (code == 404) and "404" or ("HTTP " .. tostring(code))
    end
    return Parser.parse_question(body, question_id)
end

-- Collect every image reference of an issue, each tagged with a readable stem
-- (image / article-N / question-N) and its owning block.
local function issue_image_refs(issue)
    local refs = {}
    if issue.image and issue.image.image_url then
        refs[#refs + 1] = { owner = issue.image, url = issue.image.image_url, stem = "image" }
    end
    local a = 0
    for _, block in ipairs(issue.article and issue.article.blocks or {}) do
        if block.kind == "img" and block.url then
            a = a + 1
            refs[#refs + 1] = { owner = block, url = block.url, stem = "article-" .. a }
        end
    end
    local q = 0
    for _, block in ipairs(issue.question and issue.question.answer_blocks or {}) do
        if block.kind == "img" and block.url then
            q = q + 1
            refs[#refs + 1] = { owner = block, url = block.url, stem = "question-" .. q }
        end
    end
    return refs
end

-- Download all images into the issue's folder, attaching local_path to each
-- owner. Missing downloads are skipped (that picture just won't render).
function One.resolve_images(client, settings, issue, quality, progress)
    local dir = ensure_dir(issue_dir(settings, issue))
    local refs = issue_image_refs(issue)
    local total = #refs
    for i = 1, total do
        if progress then
            progress("images", i, total)
        end
        local ref = refs[i]
        local path = ImageCache.get(client, dir, ref.stem, ref.url, quality)
        if path then
            ref.owner.local_path = path
        end
    end
end

-- Reattach local_path from disk for an already-loaded issue (opening cached
-- content). Returns count of images found.
function One.reattach_cached_images(settings, issue)
    local dir = issue_dir(settings, issue)
    local found = 0
    for _, ref in ipairs(issue_image_refs(issue)) do
        local path = ImageCache.existing(dir, ref.stem)
        if path then
            ref.owner.local_path = path
            found = found + 1
        end
    end
    return found
end

-- Fetch a full issue given its ids. article_id/question_id may be nil for
-- image-only historical issues. Downloads images and persists metadata.
function One.fetch_issue(client, settings, ids, quality, progress)
    if progress then progress("image") end
    local image, err = One.fetch_image(client, ids.image_id)
    if not image then
        error("IMAGE:" .. tostring(err))
    end

    local issue = {
        vol = image.vol,
        -- v3 image carries iso_date directly; HTML image derives it from day/month.
        iso_date = image.iso_date or DateIndex.iso_from_image(image.day, image.month_year),
        image = image,
    }

    if ids.article_id then
        if progress then progress("article") end
        local article = One.fetch_article(client, ids.article_id)
        if article and (article.title or #(article.blocks or {}) > 0) then
            issue.article = article
        end
    end

    if ids.question_id then
        if progress then progress("question") end
        local question = One.fetch_question(client, ids.question_id)
        if question and (question.title or #(question.answer_blocks or {}) > 0) then
            issue.question = question
        end
    end

    One.resolve_images(client, settings, issue, quality, progress)
    One.save_issue(settings, issue)
    return issue
end

-- ---------------------------------------------------------------------------
-- Building / reuse
-- ---------------------------------------------------------------------------

-- Path of the cached EPUB for an image id, if it already exists on disk.
function One.cached_epub_path(settings, image_id)
    local dir, info = dir_for_image_id(settings, image_id)
    if not info then
        return nil
    end
    local path = dir .. "/" .. EpubBuilder.filename_safe("ONE VOL." .. tostring(info.vol or "x")) .. ".epub"
    return file_exists(path) and path or nil
end

-- Full pipeline for a set of ids: reuse a cached EPUB if present, otherwise
-- fetch, build and cache. Returns epub path and the issue.
function One.prepare_issue(client, settings, ids, quality, progress)
    -- Fast path: today/recent may already be built.
    local cached_path = One.cached_epub_path(settings, ids.image_id)
    if cached_path then
        return cached_path, One.load_issue(settings, ids.image_id)
    end
    local issue = One.fetch_issue(client, settings, ids, quality, progress)
    if progress then progress("build") end
    local dir = ensure_dir(issue_dir(settings, issue))
    local out = dir .. "/" .. epub_name(issue)
    return EpubBuilder.build_issue(issue, out), issue
end

-- Rebuild (or reuse) an EPUB for a cached issue without network. Returns path
-- and issue, or nil if no metadata is cached.
function One.build_cached_issue(settings, image_id)
    local issue = One.load_issue(settings, image_id)
    if not issue then
        return nil
    end
    local dir = issue_dir(settings, issue)
    local out = dir .. "/" .. epub_name(issue)
    if file_exists(out) then
        return out, issue
    end
    One.reattach_cached_images(settings, issue)
    return EpubBuilder.build_issue(issue, out), issue
end

-- Open a cached issue by ISO date with NO network. The folder is named by the
-- issue's own iso_date, so a cached day lives at <cache_dir>/<iso>/. Returns
-- (path, issue) reusing the built EPUB if present, or nil if not cached.
function One.build_cached_by_date(settings, iso)
    if not iso or iso == "" then
        return nil
    end
    local dir = settings.cache_dir .. "/" .. iso
    local path = dir .. "/issue.lua"
    if not file_exists(path) then
        return nil
    end
    local ok, chunk = pcall(loadfile, path)
    local issue = ok and chunk and select(2, pcall(chunk)) or nil
    if type(issue) ~= "table" or not (issue.image and issue.image.image_id) then
        return nil
    end
    local out = dir .. "/" .. epub_name(issue)
    if file_exists(out) then
        return out, issue
    end
    One.reattach_cached_images(settings, issue)
    return EpubBuilder.build_issue(issue, out), issue
end

-- Delete a cached issue: its whole date folder plus its index entry.
function One.delete_issue(settings, image_id)
    local dir, info = dir_for_image_id(settings, image_id)
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                os.remove(dir .. "/" .. name)
            end
        end
        os.remove(dir)
    end
    local cached = settings:get("cached", {})
    cached[tostring(image_id)] = nil
    settings:set("cached", cached)
    settings:flush()
    return info
end

-- Build a collection EPUB from a list of (already fetched/loaded) issues.
function One.build_collection(settings, issues, range_label)
    local dir = ensure_dir(settings.cache_dir .. "/collections")
    local out = dir .. "/" .. EpubBuilder.filename_safe(range_label or "collection") .. ".epub"
    return EpubBuilder.build_collection(issues, range_label, out)
end

-- Resolve a target date to an image_id. Consults the VOL->image_id breakpoint
-- index first: an exact hit returns with zero network; otherwise the index's
-- interpolated guess seeds a probe + bounded scan, and the confirmed id is
-- recorded back so the index densifies. Works over both v3 (image.iso_date) and
-- HTML (image.day/month_year) since fetch_image is source-agnostic. Returns
-- image_id (string) or nil.
function One.resolve_date(client, settings, y, m, d, progress, today_date)
    local index = hp_index_for(settings)
    local vol = DateIndex.vol_from_date(y, m, d)
    local guess
    if index then
        local exact
        guess, exact = index:lookup(vol)
        if exact and guess then
            return tostring(guess) -- confirmed / stable contiguous span: zero network
        end
    end

    -- Recent band: ids are scrambled, so date-diff probing thrashes and fails.
    -- hp/idlist enumerates strictly by date, so it resolves recent dates cheaply.
    if client.has_json then
        local id = V3.image_id_by_date(client, y, m, d, {
            today_date = today_date,
            on_progress = function(p) if progress then progress("index", p) end end,
        })
        if id then
            if index then index:record(vol, tonumber(id)) end
            return id
        end
    end

    -- Older/stable band: index-guided interpolation + probe + bounded scan.
    local function fetch_date(id)
        local image, err = One.fetch_image(client, id)
        if not image then
            return (err == "404") and "404" or nil
        end
        local yy, mm, dd
        if image.iso_date then
            yy, mm, dd = image.iso_date:match("(%d+)-(%d+)-(%d+)")
            yy, mm, dd = tonumber(yy), tonumber(mm), tonumber(dd)
        else
            yy, mm, dd = DateIndex.date_from_image(image.day, image.month_year)
        end
        if not yy then
            return nil
        end
        return { year = yy, month = mm, day = dd }
    end

    -- idlist already covers recent dates; the probe only runs for the older,
    -- monotonic band where it converges in a few steps, so a small budget is enough.
    local opts = { on_progress = progress, scan_budget = 20, guess = guess }
    local id = DateIndex.resolve_date(fetch_date, y, m, d, opts)
    if id and index then
        index:record(vol, tonumber(id))
    end
    return id
end

-- ---------------------------------------------------------------------------
-- Id discovery (v3 timeline first, HTML index fallback)
-- ---------------------------------------------------------------------------

-- Today's issue ids. v3: reading/index/0 (essay+question date) + hp/idlist/0 for
-- the image (its first entry is always today -- idlist is date-descending). This
-- avoids the scrambled-band probe entirely, so today opens in ~2 requests.
-- Fallback: HTML homepage index. Returns { image_id, article_id, question_id, date }.
function One.today_ids(client, settings)
    local t = V3.today(client)
    if t and t.date then
        local y, m, d = t.date:match("(%d+)-(%d+)-(%d+)")
        local image_id = One.resolve_date(client, settings, tonumber(y), tonumber(m), tonumber(d), nil, t.date)
        if image_id then
            return {
                image_id = image_id,
                article_id = t.article_id,
                question_id = t.question_id,
                date = t.date,
            }
        end
    end
    local index = One.fetch_index(client, settings)
    return {
        image_id = index.today.image_id,
        article_id = index.today.article_id,
        question_id = index.today.question_id,
    }
end

-- Ids for an arbitrary date. v3: essay/question via reading/index timeline +
-- image via date probe. Fallback: HTML image-only (essay/question aren't
-- date-addressable without v3). Returns ids table or nil.
function One.ids_for_date(client, settings, y, m, d, progress)
    local iso = DateIndex.iso(y, m, d)
    local essay_id, question_id
    if client.has_json then
        essay_id, question_id = V3.ids_for_date(client, y, m, d, {
            on_progress = function() if progress then progress("index") end end,
        })
    end
    local image_id = One.resolve_date(client, settings, y, m, d, progress)
    if not image_id and not essay_id and not question_id then
        return nil
    end
    return {
        image_id = image_id,
        article_id = essay_id,
        question_id = question_id,
        date = iso,
    }
end

-- The N most recent days for the "recent" list. v3 entries carry a date (image
-- resolved lazily on open); HTML entries carry ids directly.
function One.recent_days(client, settings, n)
    local days = V3.recent_days(client, n)
    if days and #days > 0 then
        return days
    end
    local index = One.fetch_index(client, settings)
    local out = {}
    for i = 1, math.min(n, #index.images) do
        out[i] = {
            image_id = index.images[i],
            article_id = index.articles[i],
            question_id = index.questions[i],
        }
    end
    return out
end

-- Turn a recent-list entry into concrete ids. Entries that already carry ids use
-- them; a date-only entry (locally-built recent list) is resolved in full via
-- ids_for_date so its essay AND question are fetched, not just the image.
function One.ids_from_entry(client, settings, entry, progress)
    if entry.image_id then
        return {
            image_id = entry.image_id,
            article_id = entry.article_id,
            question_id = entry.question_id,
            date = entry.date,
        }
    end
    if entry.date then
        local y, m, d = entry.date:match("(%d+)-(%d+)-(%d+)")
        if not (entry.article_id or entry.question_id) then
            -- No ids attached: resolve the whole issue (image + essay + question).
            return One.ids_for_date(client, settings, tonumber(y), tonumber(m), tonumber(d), progress)
        end
        local image_id = One.resolve_date(client, settings, tonumber(y), tonumber(m), tonumber(d), progress)
        return {
            image_id = image_id,
            article_id = entry.article_id,
            question_id = entry.question_id,
            date = entry.date,
        }
    end
    return nil
end

-- Find a cached issue's index entry by ISO date (for recent-list status marks).
function One.cached_by_date(settings, iso)
    if not iso then
        return nil
    end
    for _, info in pairs(settings:get("cached", {})) do
        if info.iso_date == iso then
            return info
        end
    end
    return nil
end

One.BASE = BASE
return One
