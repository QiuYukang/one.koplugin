local Parser = require("lib.parser")
local DateIndex = require("lib.date_index")

-- v3 JSON API data source (http://v3.wufazhuce.com:8000). Maps the official JSON
-- into the same image/article/question tables the HTML parser produces, so the
-- rest of the plugin is source-agnostic. Every function returns nil (+err) on
-- failure so callers can fall back to the HTML path.

local V3 = {}

local function clean_text(s)
    if not s then
        return nil
    end
    s = Parser.decode_entities(tostring(s))
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function iso_of(makettime)
    -- "2026-07-07 06:00:00" -> "2026-07-07"
    return makettime and tostring(makettime):match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

-- ---------------------------------------------------------------------------
-- Detail endpoints -> normalized structures
-- ---------------------------------------------------------------------------

function V3.fetch_image(client, image_id)
    local data, err = client:get_json("/api/hp/detail/" .. tostring(image_id))
    if not data then
        return nil, err
    end
    return {
        type = "image",
        image_id = tostring(data.hpcontent_id or image_id),
        vol = data.hp_title and tostring(data.hp_title):match("VOL%.(%d+)") or nil,
        category = clean_text(data.hp_author),
        text = clean_text(data.hp_content),
        image_url = data.hp_img_url or data.hp_img_original_url,
        iso_date = iso_of(data.hp_makettime),
    }
end

function V3.fetch_article(client, article_id)
    local data, err = client:get_json("/api/essay/" .. tostring(article_id))
    if not data then
        return nil, err
    end
    return {
        type = "article",
        article_id = tostring(data.content_id or article_id),
        title = clean_text(data.hp_title),
        author = clean_text(data.hp_author),
        forward = clean_text(data.guide_word),
        blocks = Parser.html_to_blocks(data.hp_content or ""),
        iso_date = iso_of(data.hp_makettime),
        previous_id = data.previous_id,
        next_id = data.next_id,
    }
end

function V3.fetch_question(client, question_id)
    local data, err = client:get_json("/api/question/" .. tostring(question_id))
    if not data then
        return nil, err
    end
    local editor
    local answerer = data.answerer
    if type(answerer) == "table" and answerer.user_name then
        editor = clean_text(answerer.user_name)
        local desc = clean_text(answerer.desc)
        if editor and desc then
            editor = editor .. "（" .. desc .. "）"
        end
    end
    return {
        type = "question",
        question_id = tostring(data.question_id or question_id),
        title = clean_text(data.question_title),
        question_text = clean_text(data.question_content),
        answer_blocks = Parser.html_to_blocks(data.answer_content or ""),
        editor = editor,
        iso_date = iso_of(data.question_makettime),
        previous_id = data.previous_id,
        next_id = data.next_id,
    }
end

-- ---------------------------------------------------------------------------
-- Timeline (reading/index) -- essay + question by date
-- ---------------------------------------------------------------------------

function V3.reading_index(client, page)
    return client:get_json("/api/reading/index/" .. tostring(page))
end

-- Extract essay_id / question_id from a reading/index day group.
local function ids_from_group(group)
    local essay_id, question_id
    for _, it in ipairs(group.items or {}) do
        local c = it.content or {}
        if it.type == 1 and not essay_id then
            essay_id = c.content_id and tostring(c.content_id) or nil
        elseif it.type == 3 and not question_id then
            question_id = c.question_id and tostring(c.question_id) or nil
        end
    end
    return essay_id, question_id
end

-- Today's date + essay/question ids from reading/index/0. Returns a table
-- { date, article_id, question_id } or nil.
function V3.today(client)
    local data = V3.reading_index(client, 0)
    if type(data) ~= "table" or not data[1] then
        return nil
    end
    local group = data[1]
    local essay_id, question_id = ids_from_group(group)
    return { date = group.date, article_id = essay_id, question_id = question_id }
end

-- The N most recent days as { date, article_id, question_id }, newest first.
function V3.recent_days(client, n)
    local out = {}
    local page = 0
    while #out < n and page <= 3 do
        local data = V3.reading_index(client, page)
        if type(data) ~= "table" then
            break
        end
        for _, group in ipairs(data) do
            if #out >= n then
                break
            end
            local essay_id, question_id = ids_from_group(group)
            out[#out + 1] = { date = group.date, article_id = essay_id, question_id = question_id }
        end
        page = page + 1
    end
    return out
end

-- Locate essay_id / question_id for a target ISO date via paged scan. Returns
-- (essay_id, question_id) as strings (either may be nil), or nil if not found.
-- Tolerates empty-page clusters and 500s (guide §7).
function V3.ids_for_date(client, y, m, d, opts)
    opts = opts or {}
    local target = DateIndex.iso(y, m, d)
    local today = os.date("*t")
    local days_diff = DateIndex.days_between(y, m, d, today.year, today.month, today.day)
    if days_diff < 0 then
        return nil
    end
    local page = math.max(0, math.floor(days_diff / 5) - 2)
    local empty_streak = 0
    local guard = 0
    while page < 1200 and guard < 400 do
        guard = guard + 1
        if opts.on_progress then
            opts.on_progress(page)
        end
        local data = V3.reading_index(client, page)
        if type(data) ~= "table" or #data == 0 then
            empty_streak = empty_streak + 1
            if empty_streak >= 20 then
                return nil
            end
            page = page + 1
        else
            empty_streak = 0
            local first, last = data[1].date, data[#data].date
            if last <= target and target <= first then
                for _, group in ipairs(data) do
                    if group.date == target then
                        local essay_id, question_id = ids_from_group(group)
                        return essay_id, question_id
                    end
                end
                return nil -- date is within range but has no group (gap day)
            elseif first < target then
                page = math.max(0, page - 5) -- estimate went too deep
                if page == 0 then
                    -- avoid infinite loop at the boundary
                    local essay_id, question_id
                    for _, group in ipairs(data) do
                        if group.date == target then
                            essay_id, question_id = ids_from_group(group)
                        end
                    end
                    return essay_id, question_id
                end
            else
                page = page + 1 -- target is older
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Image by date via hp/idlist pagination (the reliable path for recent dates)
-- ---------------------------------------------------------------------------

-- hp/idlist/0 returns the 10 newest published issues, strictly date-descending
-- and date-contiguous (VOL never skips a day). Higher pages are reached by
-- passing the previous page's LAST id as the offset, each covering the next 10
-- older days in the same order. So a target date's image_id is found purely by
-- position -- no per-id probing -- which is what makes recent dates fast and
-- correct even though the ids themselves are scrambled (pre-allocated) in that
-- band. Verified against the live API 2026-07-10.
--
-- Returns image_id (string) or nil when the date is in the future, too old for
-- idlist (beyond opts.max_days, caller should probe instead), or on a gap/error.
function V3.image_id_by_date(client, y, m, d, opts)
    opts = opts or {}
    local today = opts.today_date
    if not today then
        local t = V3.today(client)
        today = t and t.date
    end
    if not today then
        return nil
    end
    local ty, tm, td = today:match("(%d+)-(%d+)-(%d+)")
    if not ty then
        return nil
    end
    local diff = DateIndex.days_between(y, m, d, tonumber(ty), tonumber(tm), tonumber(td))
    if diff < 0 then
        return nil -- future date
    end
    if diff > (opts.max_days or 90) then
        return nil -- too deep for page walking; let the caller probe
    end

    local page = math.floor(diff / 10)
    local within = diff % 10
    local offset = "0"
    local ids
    for p = 0, page do
        if opts.on_progress then
            opts.on_progress(p)
        end
        ids = client:get_json("/api/hp/idlist/" .. offset)
        if type(ids) ~= "table" or #ids == 0 then
            return nil
        end
        if p < page then
            if #ids < 10 then
                return nil -- ran out of pages before reaching the target day
            end
            offset = tostring(ids[#ids])
        end
    end
    local sid = ids[within + 1]
    return sid and tostring(sid) or nil
end

-- ---------------------------------------------------------------------------
-- Image by date (anchor interpolation + probe on hp_makettime) -- old dates
-- ---------------------------------------------------------------------------

function V3.find_image_id_by_date(client, y, m, d, opts)
    local function fetch_date(id)
        local data, err = client:get_json("/api/hp/detail/" .. tostring(id))
        if not data then
            return (err == "404") and "404" or nil
        end
        local iso = iso_of(data.hp_makettime)
        if not iso then
            return nil
        end
        local yy, mm, dd = iso:match("(%d+)-(%d+)-(%d+)")
        return { year = tonumber(yy), month = tonumber(mm), day = tonumber(dd) }
    end
    local id = DateIndex.resolve_date(fetch_date, y, m, d, opts or {})
    return id
end

return V3
