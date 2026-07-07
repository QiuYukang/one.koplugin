-- HTML parsers for wufazhuce.com, ported from scripts/one_api_probe.py.
-- Lua patterns differ from Python regex: `.-` is non-greedy, `.*` greedy,
-- `%s` is whitespace and literal `.` must be written `%.`.

local Parser = {}

-- ---------------------------------------------------------------------------
-- Entity decoding / tag stripping
-- ---------------------------------------------------------------------------

local named_entities = {
    amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'",
    nbsp = " ", ldquo = "\226\128\156", rdquo = "\226\128\157",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    mdash = "\226\128\148", ndash = "\226\128\147",
    hellip = "\226\128\166", middot = "\194\183",
    copy = "\194\169", reg = "\194\174", times = "\195\151",
    deg = "\194\176", laquo = "\194\171", raquo = "\194\187",
}

-- Encode a Unicode code point as UTF-8 (LuaJIT string, no utf8 lib on 5.1).
local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
end

function Parser.decode_entities(s)
    if not s then
        return nil
    end
    s = s:gsub("&#x(%x+);", function(hex)
        return utf8_char(tonumber(hex, 16) or 0)
    end)
    s = s:gsub("&#(%d+);", function(dec)
        return utf8_char(tonumber(dec, 10) or 0)
    end)
    s = s:gsub("&(%a+);", function(name)
        return named_entities[name] or ("&" .. name .. ";")
    end)
    return s
end

local function strip_tags(s)
    return (s:gsub("<[^>]*>", ""))
end

-- Decode + strip tags + collapse whitespace. Returns nil for empty results so
-- callers can use `or` fallbacks.
function Parser.clean(s)
    if s == nil then
        return nil
    end
    s = strip_tags(s)
    s = Parser.decode_entities(s)
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

-- ---------------------------------------------------------------------------
-- HTML rich-text -> ordered blocks
-- Each block is { kind = "text", text = "..." } or { kind = "img", url = "..." }.
-- This keeps images in reading order while producing XML-safe plain paragraphs.
-- ---------------------------------------------------------------------------

local IMG_OPEN = "\001"
local IMG_CLOSE = "\002"

local function image_url_from_tag(tag)
    local src = tag:match('src%s*=%s*"([^"]*)"') or tag:match("src%s*=%s*'([^']*)'")
    if not src or src == "" or not src:match("^https?://") then
        src = tag:match('data%-original%-src%s*=%s*"([^"]*)"')
            or tag:match("data%-original%-src%s*=%s*'([^']*)'")
            or src
    end
    return src
end

function Parser.html_to_blocks(html)
    local blocks = {}
    if not html or html == "" then
        return blocks
    end

    -- 0. Drop <script>/<style> blocks entirely. Stripping only tags would leave
    -- the JS/CSS *text* behind (e.g. ONE's inline weibo share script), which then
    -- leaks into the article body. `.` matches newlines in Lua patterns.
    html = html:gsub("<[sS][cC][rR][iI][pP][tT].-</[sS][cC][rR][iI][pP][tT]>", "")
    html = html:gsub("<[sS][tT][yY][lL][eE].-</[sS][tT][yY][lL][eE]>", "")

    -- 1. Extract images into sentinel markers, preserving position.
    local marked = html:gsub("<[iI][mM][gG][^>]*>", function(tag)
        local url = image_url_from_tag(tag)
        if url and url ~= "" then
            return IMG_OPEN .. url .. IMG_CLOSE
        end
        return ""
    end)

    -- 2. Turn line/paragraph structure into newlines.
    marked = marked:gsub("<[bB][rR]%s*/?>", "\n")
    marked = marked:gsub("</[pP]>", "\n")
    marked = marked:gsub("</[dD][iI][vV]>", "\n")
    marked = marked:gsub("</[hH][1-6]>", "\n")
    marked = marked:gsub("</[lL][iI]>", "\n")

    -- 3. Remove every remaining tag, then decode entities.
    marked = strip_tags(marked)
    marked = Parser.decode_entities(marked)

    local function push_text(chunk)
        for raw_line in chunk:gmatch("[^\n]+") do
            local line = raw_line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if line ~= "" then
                blocks[#blocks + 1] = { kind = "text", text = line }
            end
        end
    end

    local pos = 1
    while true do
        local s, e, url = marked:find(IMG_OPEN .. "(.-)" .. IMG_CLOSE, pos)
        local chunk = marked:sub(pos, (s and s - 1) or #marked)
        push_text(chunk)
        if not s then
            break
        end
        if url and url ~= "" then
            blocks[#blocks + 1] = { kind = "img", url = url }
        end
        pos = e + 1
    end

    return blocks
end

-- ---------------------------------------------------------------------------
-- Index page: today's ids + recent lists
-- ---------------------------------------------------------------------------

local function find_ids(body, pattern)
    local seen, out = {}, {}
    for id in body:gmatch(pattern) do
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

function Parser.parse_index(body)
    local images = find_ids(body, "/one/(%d+)")
    local articles = find_ids(body, "/article/(%d+)")
    local questions = find_ids(body, "/question/(%d+)")
    return {
        images = images,
        articles = articles,
        questions = questions,
        today = {
            image_id = images[1],
            article_id = articles[1],
            question_id = questions[1],
        },
    }
end

-- ---------------------------------------------------------------------------
-- Image page: /one/<id>
-- ---------------------------------------------------------------------------

function Parser.parse_image(body, image_id)
    local vol = body:match("<title>%s*VOL%.(%d+)")
    local img = body:match('class="one%-imagen">%s*<img[^>]-src="([^"]+)"')
    local category = body:match('class="one%-imagen%-leyenda">%s*(.-)%s*<')
    local text = body:match('class="one%-cita">%s*(.-)%s*</div>')
    local dom = body:match('class="dom">%s*(%d+)%s*</p>')
    local mon = body:match('class="may">%s*(.-)%s*</p>')
    return {
        type = "image",
        image_id = tostring(image_id),
        vol = vol,
        category = Parser.clean(category),
        text = Parser.clean(text),
        image_url = img,
        day = dom,
        month_year = Parser.clean(mon),
    }
end

-- ---------------------------------------------------------------------------
-- Article page: /article/<id>
-- ---------------------------------------------------------------------------

function Parser.parse_article(body, article_id)
    local title = body:match('<h2 class="articulo%-titulo">%s*(.-)%s*</h2>')
    local author = body:match('<p class="articulo%-autor">%s*(.-)%s*</p>')
    local forward = body:match('class="comilla%-cerrar">%s*(.-)%s*</div>')
    -- Non-greedy `.-` plus the trailing anchor stops at the correct closing </div>.
    local content_html = body:match('<div class="articulo%-contenido">(.-)</div>%s*<div class="articulo%-extra">')
        or body:match('<div class="articulo%-contenido">(.-)</div>%s*<script')
    return {
        type = "article",
        article_id = tostring(article_id),
        title = Parser.clean(title),
        author = Parser.clean(author),
        forward = Parser.clean(forward),
        blocks = Parser.html_to_blocks(content_html or ""),
    }
end

-- ---------------------------------------------------------------------------
-- Question page: /question/<id>
-- The page has two divs with the same class; split on <hr /> first (guide §6).
-- ---------------------------------------------------------------------------

function Parser.parse_question(body, question_id)
    local title = body:match("<h4>%s*(.-)%s*</h4>")

    local hr_start, hr_end = body:find("<hr%s*/?>")
    local pre, post
    if hr_start then
        pre = body:sub(1, hr_start - 1)
        post = body:sub(hr_end + 1)
    else
        pre, post = body, body
    end

    local question_html = pre:match('<div class="cuestion%-contenido">(.-)</div>')
    -- Greedy `.*` backtracks to the last </div> before the editor/share/comments.
    local answer_html = post:match('<div class="cuestion%-contenido">(.*)</div>%s*<p class="cuestion%-editor"')
        or post:match('<div class="cuestion%-contenido">(.*)</div>%s*<div class="cuestion%-compartir"')
        or post:match('<div class="cuestion%-contenido">(.*)</div>%s*<div class="one%-comentarios"')
        or post:match('<div class="cuestion%-contenido">(.-)</div>')
    local editor = post:match('<p class="cuestion%-editor">%s*(.-)%s*</p>')

    return {
        type = "question",
        question_id = tostring(question_id),
        title = Parser.clean(title),
        editor = Parser.clean(editor),
        question_text = Parser.clean(strip_tags(question_html or "")),
        answer_blocks = Parser.html_to_blocks(answer_html or ""),
    }
end

return Parser
