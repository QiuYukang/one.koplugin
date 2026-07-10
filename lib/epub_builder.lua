local bit = require("bit")
local ImageCache = require("lib.image_cache")
local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

-- Assembles ONE issues into EPUB files. The zip layout follows the EPUB spec:
-- `mimetype` first and stored uncompressed, everything else stored too (crengine
-- reads stored zips fine and it keeps the writer tiny -- see guide §4.2).

local EpubBuilder = {}

-- ---------------------------------------------------------------------------
-- Minimal zip writer (STORE only)
-- ---------------------------------------------------------------------------

local crc32_table
local function crc32(data)
    if not crc32_table then
        crc32_table = {}
        for i = 0, 255 do
            local crc = i
            for _b = 1, 8 do
                if bit.band(crc, 1) ~= 0 then
                    crc = bit.bxor(bit.rshift(crc, 1), 0xedb88320)
                else
                    crc = bit.rshift(crc, 1)
                end
            end
            crc32_table[i] = crc
        end
    end
    local crc = 0xffffffff
    for i = 1, #data do
        local index = bit.band(bit.bxor(crc, data:byte(i)), 0xff)
        crc = bit.bxor(bit.rshift(crc, 8), crc32_table[index])
    end
    return bit.bxor(crc, 0xffffffff)
end

local function le16(n)
    return string.char(bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff))
end

local function le32(n)
    return string.char(
        bit.band(n, 0xff),
        bit.band(bit.rshift(n, 8), 0xff),
        bit.band(bit.rshift(n, 16), 0xff),
        bit.band(bit.rshift(n, 24), 0xff))
end

local function make_zip(entries)
    local out, central = {}, {}
    local offset = 0
    for _i = 1, #entries do
        local name = entries[_i].name
        local data = entries[_i].data or ""
        local crc = crc32(data)
        local local_header = table.concat({
            le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0),
            le32(crc), le32(#data), le32(#data), le16(#name), le16(0), name,
        })
        out[#out + 1] = local_header
        out[#out + 1] = data
        central[#central + 1] = table.concat({
            le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0),
            le16(0), le32(crc), le32(#data), le32(#data), le16(#name),
            le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
        })
        offset = offset + #local_header + #data
    end
    local central_data = table.concat(central)
    out[#out + 1] = central_data
    out[#out + 1] = table.concat({
        le32(0x06054b50), le16(0), le16(0), le16(#entries), le16(#entries),
        le32(#central_data), le32(offset), le16(0),
    })
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if value == "" then
        value = "one"
    end
    return value
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Register a local image file as an EPUB asset, deduping by path. Returns the
-- OEBPS-relative href ("images/img-001.jpg") or nil if the file is unreadable.
local function collect_asset(state, local_path)
    if not local_path then
        return nil
    end
    if state.by_path[local_path] then
        return state.by_path[local_path]
    end
    local data = ImageCache.read_bytes(local_path)
    if not data or #data == 0 then
        return nil
    end
    local ext = local_path:match("(%.[%w]+)$") or ".jpg"
    state.count = state.count + 1
    local href = string.format("images/img-%03d%s", state.count, ext)
    state.assets[#state.assets + 1] = {
        name = "OEBPS/" .. href,
        data = data,
    }
    state.manifest[#state.manifest + 1] = string.format(
        '<item id="img_%03d" href="%s" media-type="%s"/>',
        state.count, href, ImageCache.media_type(local_path))
    state.by_path[local_path] = href
    return href
end

-- Render ordered content blocks (text/img) into XHTML. Images use the "../"
-- prefix because chapter files live under OEBPS/text/.
local function render_blocks(blocks, asset_state)
    local parts = {}
    for _i = 1, #(blocks or {}) do
        local block = blocks[_i]
        if block.kind == "text" and block.text then
            parts[#parts + 1] = "<p>" .. xml_escape(block.text) .. "</p>"
        elseif block.kind == "img" then
            local href = collect_asset(asset_state, block.local_path)
            if href then
                parts[#parts + 1] = '<div class="img"><img src="../' .. href
                    .. '" alt=""/></div>'
            end
        end
    end
    return table.concat(parts, "\n")
end

local CSS = [[
body { line-height: 1.7; margin: 1em 5%; }
h1 { font-size: 1.4em; margin: 0 0 0.4em; }
p { margin: 0.6em 0; text-indent: 0; }
p.meta { color: #555; font-size: 0.85em; margin: 0 0 1em; }
p.cita { font-size: 1.1em; margin-top: 1em; }
p.editor { color: #555; font-size: 0.85em; margin-top: 1.5em; }
blockquote { margin: 1em 0; padding: 0 0 0 1em; border-left: 3px solid #999; color: #333; }
div.img { text-align: center; margin: 1em 0; }
div.img img { max-width: 100%; }
]]

local function chapter_document(title, body)
    return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body .. [[
</body>
</html>]]
end

-- ---------------------------------------------------------------------------
-- Chapter bodies for the three ONE content types
-- ---------------------------------------------------------------------------

local function image_chapter_body(issue, asset_state)
    local parts = { "<h1>" .. xml_escape(_("Image")) .. "</h1>" }
    local meta_bits = {}
    if issue.vol then
        meta_bits[#meta_bits + 1] = "VOL." .. tostring(issue.vol)
    end
    if issue.iso_date then
        meta_bits[#meta_bits + 1] = issue.iso_date
    end
    local img = issue.image or {}
    if img.category then
        meta_bits[#meta_bits + 1] = img.category
    end
    if #meta_bits > 0 then
        parts[#parts + 1] = '<p class="meta">' .. xml_escape(table.concat(meta_bits, " · ")) .. "</p>"
    end
    local href = collect_asset(asset_state, img.local_path)
    if href then
        parts[#parts + 1] = '<div class="img"><img src="../' .. href .. '" alt=""/></div>'
    end
    if img.text then
        parts[#parts + 1] = '<p class="cita">' .. xml_escape(img.text) .. "</p>"
    end
    return table.concat(parts, "\n")
end

local function article_chapter_body(article, asset_state)
    article = article or {}
    local title = article.title or _("Article")
    local parts = { "<h1>" .. xml_escape(title) .. "</h1>" }
    if article.author then
        parts[#parts + 1] = '<p class="meta">' .. xml_escape(article.author) .. "</p>"
    end
    if article.forward then
        parts[#parts + 1] = '<blockquote class="forward">' .. xml_escape(article.forward) .. "</blockquote>"
    end
    parts[#parts + 1] = render_blocks(article.blocks, asset_state)
    return table.concat(parts, "\n")
end

local function question_chapter_body(issue, asset_state)
    local question = issue.question or {}
    local title = question.title or _("Question")
    local parts = { "<h1>" .. xml_escape(title) .. "</h1>" }
    if question.question_text then
        parts[#parts + 1] = '<blockquote class="question">Q · '
            .. xml_escape(question.question_text) .. "</blockquote>"
    end
    parts[#parts + 1] = render_blocks(question.answer_blocks, asset_state)
    if question.editor then
        -- The parsed editor value already carries its "责任编辑：" prefix.
        parts[#parts + 1] = '<p class="editor">' .. xml_escape(question.editor) .. "</p>"
    end
    return table.concat(parts, "\n")
end

-- Build the three chapters for one issue. Returns a list of chapter descriptors
-- { nav_title, title } and fills entries/manifest/spine, given a filename prefix
-- so collections can namespace each issue's files.
local function build_issue_chapters(issue, asset_state, entries, manifest, spine, prefix)
    -- The image chapter is always present; article/question are optional so that
    -- date-addressable (image-only) historical issues still produce a valid book.
    local chapters = {
        { title = _("Image"), nav_title = _("Image"), body = image_chapter_body(issue, asset_state) },
    }
    -- New issues carry issue.articles (one or more essays); older caches carry a
    -- single issue.article. Render one chapter per essay either way.
    local articles = issue.articles or (issue.article and { issue.article }) or {}
    for _a = 1, #articles do
        local article = articles[_a]
        chapters[#chapters + 1] = {
            title = article.title or _("Article"),
            nav_title = _("Article") .. (article.title
                and (" · " .. article.title) or ""),
            body = article_chapter_body(article, asset_state),
        }
    end
    if issue.question then
        chapters[#chapters + 1] = {
            title = issue.question.title or _("Question"),
            nav_title = _("Question") .. (issue.question.title
                and (" · " .. issue.question.title) or ""),
            body = question_chapter_body(issue, asset_state),
        }
    end
    local nodes = {}
    for _i = 1, #chapters do
        local chapter = chapters[_i]
        local href = string.format("text/%sch-%d.xhtml", prefix or "", _i)
        local id = string.format("%sch_%d", (prefix or ""):gsub("[^%w]", "_"), _i)
        entries[#entries + 1] = {
            name = "OEBPS/" .. href,
            data = chapter_document(chapter.title, chapter.body),
        }
        manifest[#manifest + 1] = string.format(
            '<item id="%s" href="%s" media-type="application/xhtml+xml"/>', id, href)
        spine[#spine + 1] = string.format('<itemref idref="%s"/>', id)
        nodes[#nodes + 1] = { title = chapter.nav_title, href = href }
    end
    return nodes
end

-- ---------------------------------------------------------------------------
-- Navigation (nav.xhtml + toc.ncx) from an explicit tree
-- ---------------------------------------------------------------------------

local function build_nav(tree)
    local function render(nodes)
        local out = { "<ol>" }
        for _i = 1, #nodes do
            local node = nodes[_i]
            out[#out + 1] = '<li><a href="' .. xml_escape(node.href) .. '">'
                .. xml_escape(node.title) .. "</a>"
            if node.children and #node.children > 0 then
                out[#out + 1] = render(node.children)
            end
            out[#out + 1] = "</li>"
        end
        out[#out + 1] = "</ol>"
        return table.concat(out, "\n")
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc">
]] .. render(tree) .. [[
</nav>
</body>
</html>]]
end

local function build_ncx(tree, uid, title)
    local order = 0
    local function render(nodes)
        local out = {}
        for _i = 1, #nodes do
            local node = nodes[_i]
            order = order + 1
            local current = order
            out[#out + 1] = string.format(
                '<navPoint id="navPoint-%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/>',
                current, current, xml_escape(node.title), xml_escape(node.href))
            if node.children and #node.children > 0 then
                out[#out + 1] = render(node.children)
            end
            out[#out + 1] = "</navPoint>"
        end
        return table.concat(out, "\n")
    end
    local body = render(tree)
    return [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="]] .. xml_escape(uid) .. [["/>
<meta name="dtb:depth" content="2"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. xml_escape(title) .. [[</text></docTitle>
<navMap>
]] .. body .. [[
</navMap>
</ncx>]]
end

-- ---------------------------------------------------------------------------
-- Final package assembly
-- ---------------------------------------------------------------------------

local CONTAINER_XML = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]]

local function write_epub(path, meta, manifest, spine, toc_tree, entries)
    -- EPUB2-style cover pointer keeps KOReader's shelf thumbnail working.
    local cover_meta = meta.cover_href
        and ('\n<meta name="cover" content="cover-image"/>') or ""
    local extra = {}
    if meta.description and meta.description ~= "" then
        extra[#extra + 1] = "<dc:description>" .. xml_escape(meta.description) .. "</dc:description>"
    end
    if meta.subject and meta.subject ~= "" then
        extra[#extra + 1] = "<dc:subject>" .. xml_escape(meta.subject) .. "</dc:subject>"
    end
    if meta.source and meta.source ~= "" then
        extra[#extra + 1] = "<dc:source>" .. xml_escape(meta.source) .. "</dc:source>"
    end
    local extra_meta = #extra > 0 and ("\n" .. table.concat(extra, "\n")) or ""
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">]] .. xml_escape(meta.identifier) .. [[</dc:identifier>
<dc:title>]] .. xml_escape(meta.title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(meta.creator or "ONE · 一个") .. [[</dc:creator>
<dc:publisher>ONE · 一个</dc:publisher>
<dc:language>zh-CN</dc:language>
<dc:date>]] .. xml_escape(meta.date or "") .. [[</dc:date>]] .. extra_meta .. [[
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="style" href="style.css" media-type="text/css"/>
]] .. table.concat(manifest, "\n") .. [[
</manifest>
<spine toc="ncx">
]] .. table.concat(spine, "\n") .. [[
</spine>
</package>]]

    -- mimetype MUST be the first entry (guide §4.2 / §8).
    local all = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = CONTAINER_XML },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = build_nav(toc_tree) },
        { name = "OEBPS/toc.ncx", data = build_ncx(toc_tree, meta.identifier, meta.title) },
        { name = "OEBPS/style.css", data = CSS },
    }
    for _i = 1, #entries do
        all[#all + 1] = entries[_i]
    end
    write_file(path, make_zip(all))
    return path
end

-- Register the daily image as the book cover for the shelf thumbnail only: a
-- cover-image asset + <meta name="cover">, but NO cover page in the spine (the
-- image already appears in the image chapter, so a cover page would duplicate
-- it). Deduped via by_path so the image chapter reuses the same file. Returns
-- the cover href, or nil.
local function add_cover(asset_state, entries, manifest, spine, local_path)
    if not local_path then
        return nil
    end
    local data = ImageCache.read_bytes(local_path)
    if not data or #data == 0 then
        return nil
    end
    local ext = local_path:match("(%.[%w]+)$") or ".jpg"
    local href = "images/cover" .. ext
    entries[#entries + 1] = { name = "OEBPS/" .. href, data = data }
    manifest[#manifest + 1] = string.format(
        '<item id="cover-image" href="%s" media-type="%s" properties="cover-image"/>',
        href, ImageCache.media_type(local_path))
    -- Chapter images pointing at this same file reuse the cover asset.
    asset_state.by_path[local_path] = href
    return href
end

-- Build a single-issue EPUB (cover + image chapter + optional article/question)
-- to `out_path`. `issue` images must already be resolved to local_path. A
-- friendly title is derived from VOL/date. Returns the written path.
function EpubBuilder.build_issue(issue, out_path)
    local manifest, spine, entries = {}, {}, {}
    local asset_state = { assets = entries, manifest = manifest, by_path = {}, count = 0 }
    -- Cover first so it becomes spine[1] and the shelf thumbnail.
    local cover_href = add_cover(asset_state, entries, manifest, spine,
        issue.image and issue.image.local_path)
    local nodes = build_issue_chapters(issue, asset_state, entries, manifest, spine, "")

    local title = string.format("ONE VOL.%s · %s",
        tostring(issue.vol or "?"), tostring(issue.iso_date or ""))
    return write_epub(out_path, {
        identifier = "one-vol-" .. tostring(issue.vol or (issue.image and issue.image.image_id) or "x"),
        title = title,
        date = issue.iso_date,
        cover_href = cover_href,
        description = issue.image and issue.image.text,
        subject = issue.image and issue.image.category,
        source = issue.image and issue.image.image_id
            and ("https://wufazhuce.com/one/" .. tostring(issue.image.image_id)) or nil,
    }, manifest, spine, nodes, entries)
end

-- Build a collection EPUB with a two-level TOC (VOL/date -> image/article/question)
-- to `out_path`. `issues` is an ordered list; `range_label` names the book.
function EpubBuilder.build_collection(issues, range_label, out_path)
    local manifest, spine, entries = {}, {}, {}
    local asset_state = { assets = entries, manifest = manifest, by_path = {}, count = 0 }
    -- Use the first (newest) issue's daily image as the collection cover.
    local first_image = issues[1] and issues[1].image and issues[1].image.local_path
    local cover_href = add_cover(asset_state, entries, manifest, spine, first_image)
    local toc_tree = {}
    for i = 1, #issues do
        local issue = issues[i]
        local prefix = string.format("i%d-", i)
        local child_nodes = build_issue_chapters(issue, asset_state, entries, manifest, spine, prefix)
        local group_title = string.format("VOL.%s · %s",
            tostring(issue.vol or "?"), tostring(issue.iso_date or ""))
        toc_tree[#toc_tree + 1] = {
            title = group_title,
            href = child_nodes[1].href, -- clicking the group opens its image chapter
            children = child_nodes,
        }
    end
    local title = "ONE " .. _("Collection") .. " · " .. tostring(range_label or "")
    return write_epub(out_path, {
        identifier = "one-collection-" .. filename_safe(range_label or tostring(#issues)),
        title = title,
        date = issues[#issues] and issues[#issues].iso_date,
        cover_href = cover_href,
    }, manifest, spine, toc_tree, entries)
end

EpubBuilder.filename_safe = filename_safe

return EpubBuilder
