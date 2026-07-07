-- image_id <-> VOL <-> date conversions (guide §4.4, api-reference §11).
--
-- Facts we rely on:
--   * VOL increments by exactly 1 every day; VOL.1 == 2012-10-08.
--   * image_id increases monotonically but skips ~3% of ids, so it cannot be
--     computed from a date directly -- we interpolate then probe-and-adjust.

local DateIndex = {}

-- VOL.1 publication date.
DateIndex.EPOCH = { year = 2012, month = 10, day = 8 }

-- Measured (image_id -> VOL) anchors, sorted by image_id.
DateIndex.ANCHORS = {
    { id = 20, vol = 14 },
    { id = 100, vol = 86 },
    { id = 500, vol = 486 },
    { id = 1000, vol = 980 },
    { id = 2000, vol = 1970 },
    { id = 3000, vol = 2958 },
    { id = 4000, vol = 3896 },
    { id = 4500, vol = 4348 },
    { id = 5000, vol = 4876 },
    { id = 5100, vol = 4936 },
    { id = 5147, vol = 5022 },
}

-- Noon avoids DST / timezone edge cases when diffing whole days.
local function to_time(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
end

local SECONDS_PER_DAY = 86400

function DateIndex.days_between(y1, m1, d1, y2, m2, d2)
    local diff = to_time(y2, m2, d2) - to_time(y1, m1, d1)
    return math.floor(diff / SECONDS_PER_DAY + 0.5)
end

function DateIndex.vol_from_date(y, m, d)
    local e = DateIndex.EPOCH
    return 1 + DateIndex.days_between(e.year, e.month, e.day, y, m, d)
end

-- Returns year, month, day for a VOL number.
function DateIndex.date_from_vol(vol)
    vol = tonumber(vol)
    if not vol then
        return nil
    end
    local e = DateIndex.EPOCH
    local t = to_time(e.year, e.month, e.day) + (vol - 1) * SECONDS_PER_DAY
    local dt = os.date("*t", t)
    return dt.year, dt.month, dt.day
end

function DateIndex.iso_from_vol(vol)
    local y, m, d = DateIndex.date_from_vol(vol)
    if not y then
        return nil
    end
    return string.format("%04d-%02d-%02d", y, m, d)
end

function DateIndex.iso(y, m, d)
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- English month abbreviations as shown on the image page ("Jul 2026").
DateIndex.MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- Convert the image page's own date fields ("7", "Jul 2026") into y, m, d.
-- This is per-issue ground truth and avoids VOL<->date formula drift.
function DateIndex.date_from_image(day, month_year)
    local d = tonumber(day)
    if not d or not month_year then
        return nil
    end
    local mon_abbr, year = month_year:match("(%a+)%s+(%d+)")
    if not mon_abbr then
        return nil
    end
    local m = DateIndex.MONTHS[mon_abbr]
    local y = tonumber(year)
    if not m or not y then
        return nil
    end
    return y, m, d
end

function DateIndex.iso_from_image(day, month_year)
    local y, m, d = DateIndex.date_from_image(day, month_year)
    if not y then
        return nil
    end
    return DateIndex.iso(y, m, d)
end

-- Localized weekday for a VOL (0=Sunday..6). Caller maps to a display string.
function DateIndex.weekday_from_vol(vol)
    local y, m, d = DateIndex.date_from_vol(vol)
    if not y then
        return nil
    end
    return tonumber(os.date("*t", to_time(y, m, d)).wday) - 1
end

-- Linear interpolation of image_id from a target VOL using the nearest anchors.
function DateIndex.interpolate_id(target_vol)
    local anchors = DateIndex.ANCHORS
    if target_vol <= anchors[1].vol then
        return anchors[1].id
    end
    if target_vol >= anchors[#anchors].vol then
        -- Extrapolate past the last anchor at ~1.02 ids/day.
        local last = anchors[#anchors]
        return math.floor(last.id + (target_vol - last.vol) * 1.02 + 0.5)
    end
    for i = 1, #anchors - 1 do
        local a, b = anchors[i], anchors[i + 1]
        if target_vol >= a.vol and target_vol <= b.vol then
            local ratio = (target_vol - a.vol) / (b.vol - a.vol)
            return math.floor(a.id + ratio * (b.id - a.id) + 0.5)
        end
    end
    return anchors[#anchors].id
end

-- Locate the image_id for a target date by interpolating an initial guess then
-- adjusting against the actual date parsed from each fetched page. Comparing
-- real dates (not VOL numbers) is immune to VOL<->date formula drift.
--
--   fetch_date(id) must return: {year=, month=, day=} on success,
--                               "404" on a skipped id, or nil on other failure.
--
-- Returns image_id (string) and its {y,m,d}, or nil plus an error tag.
function DateIndex.find_image_id_by_date(fetch_date, y, m, d, opts)
    opts = opts or {}
    local max_attempts = opts.max_attempts or 10
    local target_vol = DateIndex.vol_from_date(y, m, d)
    if target_vol < 1 then
        return nil, "before_epoch"
    end

    local guess = DateIndex.interpolate_id(target_vol)
    local consecutive_404 = 0
    for _i = 1, max_attempts do
        if guess < 1 then
            return nil, "underflow"
        end
        local result = fetch_date(guess)
        if result == "404" then
            -- Skipped id: step forward once and keep the attempt budget alive.
            guess = guess + 1
            consecutive_404 = consecutive_404 + 1
            if consecutive_404 > 20 then
                return nil, "too_many_gaps"
            end
        elseif type(result) == "table" and result.year then
            consecutive_404 = 0
            local diff = DateIndex.days_between(
                result.year, result.month, result.day, y, m, d)
            if diff == 0 then
                return tostring(guess), result
            end
            guess = guess + diff
        else
            return nil, "fetch_failed"
        end
    end
    return nil, "not_converged"
end

-- Bounded expanding scan around a center id. Recent issues live in the highest
-- id band where ids are scrambled (the site pre-allocates ids for scheduled
-- content), so date-diff probing oscillates there. We instead sweep ids outward
-- from the interpolated center, capped by a request budget, and return the id
-- whose page date matches the target.
--
--   fetch_date(id) has the same contract as find_image_id_by_date.
--   opts.on_progress(tried, budget) is called before each fetch (optional).
--
-- Returns image_id (string) and {y,m,d}, or nil plus an error tag.
function DateIndex.scan_for_date(fetch_date, y, m, d, center, opts)
    opts = opts or {}
    local budget = opts.scan_budget or 30
    local max_radius = opts.max_radius or 45
    local tried = 0
    for radius = 0, max_radius do
        local ids = radius == 0 and { center } or { center + radius, center - radius }
        for _j = 1, #ids do
            local id = ids[_j]
            if id >= 1 then
                tried = tried + 1
                if tried > budget then
                    return nil, "scan_budget"
                end
                if opts.on_progress then
                    opts.on_progress(tried, budget)
                end
                local result = fetch_date(id)
                if type(result) == "table" and result.year
                    and DateIndex.days_between(result.year, result.month, result.day, y, m, d) == 0 then
                    return tostring(id), result
                end
            end
        end
    end
    return nil, "scan_not_found"
end

-- High-level resolver: interpolate + probe (cheap, reliable for old dates), then
-- fall back to a bounded scan for the recent scrambled band. Returns
-- image_id (string), {y,m,d}, method ("probe"|"scan"), or nil + error tag.
function DateIndex.resolve_date(fetch_date, y, m, d, opts)
    opts = opts or {}
    local target_vol = DateIndex.vol_from_date(y, m, d)
    if target_vol < 1 then
        return nil, nil, nil, "before_epoch"
    end
    local id, res = DateIndex.find_image_id_by_date(fetch_date, y, m, d, opts)
    if id then
        return id, res, "probe"
    end
    local center = DateIndex.interpolate_id(target_vol)
    local scan_id, scan_res = DateIndex.scan_for_date(fetch_date, y, m, d, center, opts)
    if scan_id then
        return scan_id, scan_res, "scan"
    end
    return nil, nil, nil, scan_res or res
end

return DateIndex
