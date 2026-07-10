local DateIndex = require("one_reader.date_index")

-- Piecewise "breakpoint" index mapping VOL -> image_id (hpcontent_id).
--
-- image_id increases monotonically and gains ~1 per published day, but skips
-- ~3% of ids. Between two confirmed points A < B, if id_B - id_A == vol_B - vol_A
-- the whole span is contiguous (no skips) and every VOL inside resolves EXACTLY
-- with zero network. Otherwise the span hides >=1 skip: we interpolate a tight
-- guess, let the caller probe, then record the confirmed (vol, id) so the table
-- densifies and self-corrects over time.
--
-- Kept as a flat array sorted by VOL. At most a few hundred entries even fully
-- populated, so it lives entirely in memory and is scanned linearly -- no binary
-- search needed at this size (guide: date_index anchors were the coarse version).
--
-- Two sources merged on load:
--   * SEED  -- measured anchors shipped with the plugin (read-only, upgradable).
--   * learned -- points confirmed at runtime, persisted to
--     <data_dir>/hp_index.lua (writable, survives plugin upgrades).

local HpIndex = {}
HpIndex.__index = HpIndex

-- Measured (VOL -> image_id) anchors, sorted by VOL (docs/one-api-reference §8.2,
-- date_index anchors). Contiguous spans between adjacent seeds already resolve
-- with zero probes -- e.g. VOL.86..486 (id 100..500) is skip-free.
local SEED = {
    { vol = 8,    id = 14 },
    { vol = 9,    id = 15 },
    { vol = 14,   id = 20 },
    { vol = 24,   id = 30 },
    { vol = 44,   id = 50 },
    { vol = 86,   id = 100 },
    { vol = 486,  id = 500 },
    { vol = 980,  id = 1000 },
    { vol = 1970, id = 2000 },
    { vol = 2958, id = 3000 },
    { vol = 3896, id = 4000 },
    { vol = 4348, id = 4500 },
    { vol = 4876, id = 5000 },
    { vol = 4936, id = 5100 },
    { vol = 5022, id = 5147 },
}

-- Within this many days of today, ids are pre-allocated for scheduled content and
-- are NOT monotonic with date (measured 2026-07-10: id 5150 = 2026-06-07 sits
-- among ids for early July). Never hand out a *derived* exact hit in this band --
-- callers resolve it via idlist instead. A direct hit on a confirmed point is
-- still trusted (it is ground truth, recorded from a real fetch).
local RECENT_GUARD_DAYS = 45

function HpIndex.new(settings)
    local self = setmetatable({}, HpIndex)
    self.path = (settings and settings.data_dir or ".") .. "/hp_index.lua"
    self.learned = {}
    local chunk = loadfile(self.path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            for _, p in ipairs(data) do
                if type(p) == "table" and p.vol and p.id then
                    self.learned[#self.learned + 1] = { vol = p.vol, id = p.id }
                end
            end
        end
    end
    -- VOL of "today"; the recent-band floor below which derived exactness is off.
    local t = os.date("*t")
    local today_vol = DateIndex.vol_from_date(t.year, t.month, t.day)
    self.recent_floor_vol = today_vol - RECENT_GUARD_DAYS
    self:_rebuild()
    return self
end

-- Merge SEED + learned (learned wins on VOL collisions -- it is confirmed) into
-- a single VOL-sorted array.
function HpIndex:_rebuild()
    local by_vol = {}
    for _, p in ipairs(SEED) do
        by_vol[p.vol] = p.id
    end
    for _, p in ipairs(self.learned) do
        by_vol[p.vol] = p.id
    end
    local arr = {}
    for vol, id in pairs(by_vol) do
        arr[#arr + 1] = { vol = vol, id = id }
    end
    table.sort(arr, function(a, b) return a.vol < b.vol end)
    self.points = arr
end

-- Look up the image_id for a VOL.
-- Returns (id, exact): exact=true means id is trustworthy with no network;
-- exact=false means id is only a starting guess for a probe.
function HpIndex:lookup(vol)
    local pts = self.points
    local n = #pts
    if n == 0 then
        return nil, false
    end
    local function may_be_exact(v)
        return v < self.recent_floor_vol
    end

    if vol <= pts[1].vol then
        if vol == pts[1].vol then
            return pts[1].id, true
        end
        return pts[1].id - (pts[1].vol - vol), false -- extrapolate below first anchor
    end
    if vol >= pts[n].vol then
        if vol == pts[n].vol then
            return pts[n].id, true
        end
        return pts[n].id + (vol - pts[n].vol), false -- extrapolate past last anchor
    end

    for i = 1, n - 1 do
        local a, b = pts[i], pts[i + 1]
        if vol >= a.vol and vol <= b.vol then
            if vol == a.vol then return a.id, true end
            if vol == b.vol then return b.id, true end
            if b.id - a.id == b.vol - a.vol then
                -- Skip-free span: exact, unless it sits in the recent band.
                return a.id + (vol - a.vol), may_be_exact(vol)
            end
            local ratio = (vol - a.vol) / (b.vol - a.vol)
            return math.floor(a.id + ratio * (b.id - a.id) + 0.5), false
        end
    end
    return nil, false
end

-- Record a confirmed (VOL -> image_id) mapping and persist it. No-op if already
-- present with the same id.
function HpIndex:record(vol, id)
    vol, id = tonumber(vol), tonumber(id)
    if not vol or not id then
        return
    end
    for _, p in ipairs(self.learned) do
        if p.vol == vol then
            if p.id == id then return end
            p.id = id -- correct a stale learned point
            self:_rebuild()
            self:_save()
            return
        end
    end
    -- Skip if a seed already covers it with the same id (keeps learned file lean).
    for _, p in ipairs(SEED) do
        if p.vol == vol and p.id == id then
            return
        end
    end
    self.learned[#self.learned + 1] = { vol = vol, id = id }
    self:_rebuild()
    self:_save()
end

function HpIndex:_save()
    local f = io.open(self.path, "w")
    if not f then
        return
    end
    table.sort(self.learned, function(a, b) return a.vol < b.vol end)
    f:write("-- ONE hp VOL->image_id points confirmed at runtime. Auto-generated.\n")
    f:write("return {\n")
    for _, p in ipairs(self.learned) do
        f:write(string.format("  { vol = %d, id = %d },\n", p.vol, p.id))
    end
    f:write("}\n")
    f:close()
end

HpIndex.SEED = SEED
return HpIndex
