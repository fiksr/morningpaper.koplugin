--[[--
MorningPaper EPUB Compiler.
Compiles fetched articles into a clean, physical-style Morning Newspaper EPUB.
Zero-dependency, pure-Lua ZIP implementation (works on all Kindle/Kobo devices without external zip binary).
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local bit = bit or require("bit")
local bxor = bit.bxor
local rshift = bit.rshift
local band = bit.band

local EpubBuilder = {}
EpubBuilder.__index = EpubBuilder

-- Precompute CRC32 lookup table
local crc_table = {}
for i = 0, 255 do
    local c = i
    for j = 1, 8 do
        if band(c, 1) ~= 0 then
            c = bxor(rshift(c, 1), 0xEDB88320)
        else
            c = rshift(c, 1)
        end
    end
    crc_table[i] = c
end

local function calc_crc32(str)
    local crc = 0xFFFFFFFF
    for i = 1, #str do
        local b = str:byte(i)
        local idx = band(bxor(crc, b), 0xFF)
        crc = bxor(rshift(crc, 8), crc_table[idx])
    end
    return bxor(crc, 0xFFFFFFFF)
end

local function pack16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function pack32(n)
    if n < 0 then n = n + 4294967296 end
    local b1 = n % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = math.floor(n / 65536) % 256
    local b4 = math.floor(n / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

local function writeZipFile(entries, output_path)
    local f, err = io.open(output_path, "wb")
    if not f then return false, err end

    local central_headers = {}
    local offset = 0

    for idx, e in ipairs(entries) do
        local filename = e[1]
        local data = e[2]
        local crc = calc_crc32(data)
        local size = #data

        local local_hdr = "PK\x03\x04"
            .. pack16(10)     -- version needed
            .. pack16(0)      -- flags
            .. pack16(0)      -- compression method: stored (0)
            .. pack16(0)      -- mod time
            .. pack16(0x5421) -- mod date
            .. pack32(crc)    -- crc32
            .. pack32(size)   -- comp size
            .. pack32(size)   -- uncomp size
            .. pack16(#filename)
            .. pack16(0)      -- extra len

        local local_offset = offset
        f:write(local_hdr)
        f:write(filename)
        f:write(data)

        local entry_size = #local_hdr + #filename + size
        offset = offset + entry_size

        local central_hdr = "PK\x01\x02"
            .. pack16(10)     -- ver made
            .. pack16(10)     -- ver need
            .. pack16(0)      -- flags
            .. pack16(0)      -- compression (0)
            .. pack16(0)      -- mod time
            .. pack16(0x5421) -- mod date
            .. pack32(crc)
            .. pack32(size)
            .. pack32(size)
            .. pack16(#filename)
            .. pack16(0)      -- extra len
            .. pack16(0)      -- comment len
            .. pack16(0)      -- disk start
            .. pack16(0)      -- int attr
            .. pack32(0)      -- ext attr
            .. pack32(local_offset)

        table.insert(central_headers, { central_hdr, filename })
    end

    local central_dir_offset = offset
    local central_dir_size = 0
    for idx, ch in ipairs(central_headers) do
        f:write(ch[1])
        f:write(ch[2])
        central_dir_size = central_dir_size + #ch[1] + #ch[2]
    end

    local num_entries = #entries
    local eocd = "PK\x05\x06"
        .. pack16(0) -- disk
        .. pack16(0) -- start disk
        .. pack16(num_entries)
        .. pack16(num_entries)
        .. pack32(central_dir_size)
        .. pack32(central_dir_offset)
        .. pack16(0) -- comment len

    f:write(eocd)
    f:close()
    return true
end

local function escapeXml(str)
    if not str then return "" end
    return (str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function formatBullets(text)
    if not text then return "" end
    local lines = {}
    for l in text:gmatch("[^\r\n]+") do
        local clean = l:gsub("^[•%-%*]%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #clean > 0 then
            table.insert(lines, string.format("<p>• %s</p>", escapeXml(clean)))
        end
    end
    return table.concat(lines, "\n")
end

local CSS_STYLE = [[
@page { margin: 20px 25px; }
body {
    font-family: serif;
    line-height: 1.45;
    color: #000000;
    margin: 0;
    padding: 0;
}
.masthead {
    text-align: center;
    border-bottom: 2px solid #000;
    padding-bottom: 12px;
    margin-bottom: 20px;
}
.masthead h1 {
    font-size: 2.2em;
    letter-spacing: 2px;
    margin: 0 0 6px 0;
    text-transform: uppercase;
    font-weight: 900;
}
.edition-bar {
    font-size: 0.85em;
    border-top: 1px solid #333;
    border-bottom: 1px solid #333;
    padding: 4px 0;
    margin-top: 8px;
    font-style: italic;
}
.section-title {
    font-size: 1.5em;
    border-bottom: 1px solid #888;
    padding-bottom: 4px;
    margin-top: 25px;
    margin-bottom: 15px;
    font-weight: bold;
}
.article {
    margin-bottom: 25px;
    padding-bottom: 15px;
    border-bottom: 1px dashed #bbb;
}
.article h2 {
    font-size: 1.25em;
    margin: 0 0 6px 0;
    line-height: 1.25;
}
.article-meta {
    font-size: 0.8em;
    color: #444;
    margin-bottom: 10px;
    font-style: italic;
}
.ai-summary {
    background-color: #f2f2f2;
    border-left: 3px solid #000;
    padding: 8px 12px;
    margin: 10px 0;
    font-size: 0.95em;
}
.ai-summary-title {
    font-weight: bold;
    margin-bottom: 4px;
    font-size: 0.85em;
    text-transform: uppercase;
    letter-spacing: 1px;
}
p {
    text-indent: 1em;
    margin: 0 0 8px 0;
}
h3 { font-size: 1.05em; margin: 12px 0 4px 0; }
a { color: #000; text-decoration: underline; }
]]

function EpubBuilder:new(settings)
    local o = setmetatable({}, self)
    o.settings = settings
    return o
end

function EpubBuilder:buildEpub(sections, date_str)
    date_str = date_str or os.date("%Y-%m-%d")
    local out_dir = self.settings:getOutputDirectory()
    local epub_filename = string.format("MorningPaper_%s.epub", date_str)
    local epub_path = out_dir .. "/" .. epub_filename

    local entries = {}

    -- 1. mimetype (first, uncompressed)
    table.insert(entries, { "mimetype", "application/epub+zip" })

    -- 2. META-INF/container.xml
    local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    table.insert(entries, { "META-INF/container.xml", container_xml })

    -- 3. OEBPS/style.css
    table.insert(entries, { "OEBPS/style.css", CSS_STYLE })

    -- 4. Front Page (OEBPS/cover.xhtml)
    local total_articles = 0
    for idx, s in ipairs(sections) do
        total_articles = total_articles + #s.articles
    end

    local cover_html = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>The Morning Paper</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <div class="masthead">
    <h1>The Morning Paper</h1>
    <div class="edition-bar">
      <span>Daily Edition • %s • %d Articles Curated</span>
    </div>
  </div>
  <div class="ai-summary">
    <div class="ai-summary-title">🗞️ Today's Table of Contents</div>
    <ul>
]], date_str, total_articles)

    for idx, s in ipairs(sections) do
        cover_html = cover_html .. string.format('<li><a href="section_%d.xhtml">%s (%d stories)</a></li>\n', idx, escapeXml(s.title), #s.articles)
    end
    cover_html = cover_html .. [[
    </ul>
  </div>
  <p style="text-align:center; font-style:italic; margin-top:30px; font-size:0.9em;">
    Compiled automatically by KOReader MorningPaper Edition.<br/>
    Swipe or turn page to begin reading.
  </p>
</body>
</html>]]
    table.insert(entries, { "OEBPS/cover.xhtml", cover_html })

    -- 5. Section Chapters (OEBPS/section_X.xhtml)
    for s_idx, sec in ipairs(sections) do
        local sec_html = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <div class="section-title">%s</div>
]], escapeXml(sec.title), escapeXml(sec.title))

        for a_idx, art in ipairs(sec.articles) do
            local meta_str = escapeXml(art.author and #art.author > 0 and art.author or sec.title)
            if art.date and #art.date > 0 then
                meta_str = meta_str .. " • " .. escapeXml(art.date)
            end

            sec_html = sec_html .. string.format([[
  <div class="article">
    <h2>%s</h2>
    <div class="article-meta">%s</div>
]], escapeXml(art.title), meta_str)

            if art.ai_summary and #art.ai_summary > 0 then
                sec_html = sec_html .. string.format([[
    <div class="ai-summary">
      <div class="ai-summary-title">⚡ Executive Briefing</div>
      %s
    </div>
]], formatBullets(art.ai_summary))
            end

            sec_html = sec_html .. string.format([[
    <div class="article-body">
      %s
    </div>
  </div>
]], art.content_html or "<p>(No content)</p>")
        end

        sec_html = sec_html .. "</body>\n</html>"
        table.insert(entries, { string.format("OEBPS/section_%d.xhtml", s_idx), sec_html })
    end

    -- 6. Table of Contents (OEBPS/toc.ncx)
    local ncx = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:morningpaper-%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>The Morning Paper (%s)</text></docTitle>
  <navMap>
    <navPoint id="navPoint-1" playOrder="1">
      <navLabel><text>Front Page</text></navLabel>
      <content src="cover.xhtml"/>
    </navPoint>
]], date_str, date_str)

    for idx, s in ipairs(sections) do
        ncx = ncx .. string.format([[
    <navPoint id="navPoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="section_%d.xhtml"/>
    </navPoint>
]], idx + 1, idx + 1, escapeXml(s.title), idx)
    end
    ncx = ncx .. "  </navMap>\n</ncx>"
    table.insert(entries, { "OEBPS/toc.ncx", ncx })

    -- 7. Package Descriptor (OEBPS/content.opf)
    local opf = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>The Morning Paper (%s)</dc:title>
    <dc:creator>MorningPaper for KOReader</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="BookID">urn:uuid:morningpaper-%s</dc:identifier>
    <dc:date>%s</dc:date>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="style" href="style.css" media-type="text/css"/>
    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
]], date_str, date_str, date_str)

    for idx, s in ipairs(sections) do
        opf = opf .. string.format('    <item id="sec_%d" href="section_%d.xhtml" media-type="application/xhtml+xml"/>\n', idx, idx)
    end
    opf = opf .. [[
  </manifest>
  <spine toc="ncx">
    <itemref idref="cover"/>
]]
    for idx, s in ipairs(sections) do
        opf = opf .. string.format('    <itemref idref="sec_%d"/>\n', idx)
    end
    opf = opf .. "  </spine>\n</package>"
    table.insert(entries, { "OEBPS/content.opf", opf })

    -- 8. Write ZIP archive directly to destination
    pcall(os.remove, epub_path)
    local ok, err = writeZipFile(entries, epub_path)

    if ok and lfs.attributes(epub_path, "mode") == "file" then
        return true, epub_path
    else
        return false, tostring(err or "Failed to write EPUB file")
    end
end

return EpubBuilder
