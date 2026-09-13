--[[--
MorningPaper EPUB Compiler.
Compiles fetched articles into a clean, physical-style Morning Newspaper EPUB.
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local EpubBuilder = {}
EpubBuilder.__index = EpubBuilder

local function escapeXml(str)
    if not str then return "" end
    return str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
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

    local build_dir = "/tmp/morningpaper_build"
    if lfs.attributes("/tmp", "mode") ~= "directory" then
        build_dir = DataStorage:getFullDataDir() .. "/cache/morningpaper_build"
        pcall(lfs.mkdir, DataStorage:getFullDataDir() .. "/cache")
    end

    pcall(os.execute, "rm -rf '" .. build_dir .. "'")
    pcall(lfs.mkdir, build_dir)
    pcall(lfs.mkdir, build_dir .. "/META-INF")
    pcall(lfs.mkdir, build_dir .. "/OEBPS")

    -- 1. mimetype (MUST be first and uncompressed)
    local f_mime = io.open(build_dir .. "/mimetype", "w")
    if f_mime then
        f_mime:write("application/epub+zip")
        f_mime:close()
    end

    -- 2. container.xml
    local f_cont = io.open(build_dir .. "/META-INF/container.xml", "w")
    if f_cont then
        f_cont:write([[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]])
        f_cont:close()
    end

    -- 3. style.css
    local f_css = io.open(build_dir .. "/OEBPS/style.css", "w")
    if f_css then
        f_css:write(CSS_STYLE)
        f_css:close()
    end

    -- 4. Front Page (cover.xhtml)
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

    local f_cover = io.open(build_dir .. "/OEBPS/cover.xhtml", "w")
    if f_cover then
        f_cover:write(cover_html)
        f_cover:close()
    end

    -- 5. Section Chapters
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

            -- AI Summary box if generated
            if art.ai_summary and #art.ai_summary > 0 then
                sec_html = sec_html .. string.format([[
    <div class="ai-summary">
      <div class="ai-summary-title">⚡ Executive Briefing</div>
      %s
    </div>
]], formatBullets(art.ai_summary))
            end

            -- Body text
            sec_html = sec_html .. string.format([[
    <div class="article-body">
      %s
    </div>
  </div>
]], art.content_html or "<p>(No content)</p>")
        end

        sec_html = sec_html .. "</body>\n</html>"

        local f_sec = io.open(string.format("%s/OEBPS/section_%d.xhtml", build_dir, s_idx), "w")
        if f_sec then
            f_sec:write(sec_html)
            f_sec:close()
        end
    end

    -- 6. Table of Contents (toc.ncx)
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

    local f_ncx = io.open(build_dir .. "/OEBPS/toc.ncx", "w")
    if f_ncx then
        f_ncx:write(ncx)
        f_ncx:close()
    end

    -- 7. content.opf
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

    local f_opf = io.open(build_dir .. "/OEBPS/content.opf", "w")
    if f_opf then
        f_opf:write(opf)
        f_opf:close()
    end

    -- 8. Zip into final EPUB file
    pcall(os.remove, epub_path)
    local zip_cmd = string.format(
        "cd '%s' && zip -q -0 -X '%s' mimetype && zip -q -9 -r '%s' META-INF OEBPS",
        build_dir, epub_path, epub_path
    )
    local ret = os.execute(zip_cmd)

    -- Cleanup build dir
    pcall(os.execute, "rm -rf '" .. build_dir .. "'")

    if lfs.attributes(epub_path, "mode") == "file" then
        return true, epub_path
    else
        return false, "Failed to package EPUB file via zip utility"
    end
end

return EpubBuilder
