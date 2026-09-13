--[[--
MorningPaper Parser & Sanitizer.
Extracts structured articles from RSS 2.0, Atom XML, and Reddit/HN JSON feeds.
Sanitizes raw HTML for clean E-Ink typography.
--]]--

local Parser = {}

local json = nil
local ok, mod = pcall(require, "json")
if ok and mod and mod.decode then
    json = mod
else
    ok, mod = pcall(require, "rapidjson")
    if ok and mod and mod.decode then json = mod end
end

local function unescapeXml(str)
    if not str then return "" end
    local s = str:gsub("<!%[CDATA%[([%s%S]-)%]%]%s*>", "%1")
    s = s:gsub("&amp;", "&")
         :gsub("&lt;", "<")
         :gsub("&gt;", ">")
         :gsub("&quot;", '"')
         :gsub("&apos;", "'")
         :gsub("&#39;", "'")
         :gsub("&#8217;", "'")
         :gsub("&#8216;", "'")
         :gsub("&#8220;", '"')
         :gsub("&#8221;", '"')
         :gsub("&#8212;", "—")
         :gsub("&#8211;", "–")
         :gsub("&#(%d+);", function(n)
             local num = tonumber(n)
             if num and num < 256 then return string.char(num) end
             return ""
         end)
    return s
end

function Parser.stripHtml(html)
    if not html then return "" end
    local s = unescapeXml(html)
    -- Remove scripts, styles, iframes
    s = s:gsub("<script.-</script>", "")
         :gsub("<style.-</style>", "")
         :gsub("<iframe.-</iframe>", "")
         :gsub("<noscript.-</noscript>", "")
    -- Convert block elements to spaces and newlines
    s = s:gsub("<br%s*/?>", "
")
         :gsub("</p>", "

")
         :gsub("</div>", "
")
         :gsub("</li>", "
")
         :gsub("<h%d.->", "

")
         :gsub("</h%d>", "

")
    -- Strip remaining HTML tags, replacing with a single space
    s = s:gsub("<[^>]+>", " ")
    -- Clean multiple whitespace & non-breaking spaces
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("[ 	]+", " ")
    s = s:gsub("
%s*
%s*
+", "

")
    local clean = s:gsub("^%s+", ""):gsub("%s+$", "")
    return clean
end

function Parser.cleanHtmlForEpub(html)
    if not html then return "<p></p>" end
    local clean_text = Parser.stripHtml(html)
    local paragraphs = {}
    for block in clean_text:gmatch("[^
]+") do
        local p = block:gsub("^%s+", ""):gsub("%s+$", "")
        if #p > 0 then
            table.insert(paragraphs, string.format("<p>%s</p>", p))
        end
    end
    if #paragraphs == 0 then
        return "<p>(No article body available)</p>"
    end
    return table.concat(paragraphs, "\n")
end

-- Parse RSS 2.0 / Atom XML
function Parser.parseRss(xml_text, max_items)
    max_items = max_items or 5
    local articles = {}

    -- Extract RSS 2.0 items using multi-line pattern [%s%S]
    for item_block in xml_text:gmatch("<item.->([%s%S]-)</item>") do
        local title = item_block:match("<title.->([%s%S]-)</title>")
        local link = item_block:match("<link.->([%s%S]-)</link>")
        local desc = item_block:match("<content:encoded.->([%s%S]-)</content:encoded>")
                  or item_block:match("<description.->([%s%S]-)</description>")
                  or ""
        local author = item_block:match("<dc:creator.->([%s%S]-)</dc:creator>")
                    or item_block:match("<author.->([%s%S]-)</author>")
                    or ""
        local pub_date = item_block:match("<pubDate.->([%s%S]-)</pubDate>") or ""

        if title and #title > 0 then
            local clean_title = Parser.stripHtml(title)
            local clean_desc = Parser.stripHtml(desc)
            if #clean_desc > 1200 then clean_desc = clean_desc:sub(1, 1200) .. "..." end

            table.insert(articles, {
                title = clean_title,
                link = unescapeXml(link or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                author = Parser.stripHtml(author),
                date = pub_date:gsub("%+.*$", ""):gsub("^%s+", ""):gsub("%s+$", ""),
                summary = clean_desc,
                content_html = Parser.cleanHtmlForEpub(desc),
            })
            if #articles >= max_items then break end
        end
    end

    -- If no RSS items found, check for Atom entries
    if #articles == 0 then
        for entry_block in xml_text:gmatch("<entry.->([%s%S]-)</entry>") do
            local title = entry_block:match("<title.->([%s%S]-)</title>")
            local link = entry_block:match('<link.-href="([^"]+)"')
                      or entry_block:match("<link.-href='([^']+)'")
                      or entry_block:match("<link.->([%s%S]-)</link>")
            local desc = entry_block:match("<content.->([%s%S]-)</content>")
                      or entry_block:match("<summary.->([%s%S]-)</summary>")
                      or ""
            local author = entry_block:match("<name.->([%s%S]-)</name>") or ""
            local date = entry_block:match("<updated.->([%s%S]-)</updated>")
                      or entry_block:match("<published.->([%s%S]-)</published>") or ""

            if title and #title > 0 then
                local clean_title = Parser.stripHtml(title)
                local clean_desc = Parser.stripHtml(desc)
                if #clean_desc > 1200 then clean_desc = clean_desc:sub(1, 1200) .. "..." end

                table.insert(articles, {
                    title = clean_title,
                    link = unescapeXml(link or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                    author = Parser.stripHtml(author),
                    date = date:sub(1, 10),
                    summary = clean_desc,
                    content_html = Parser.cleanHtmlForEpub(desc),
                })
                if #articles >= max_items then break end
            end
        end
    end

    return articles
end

-- Parse Reddit JSON Endpoint
function Parser.parseRedditJson(json_text, max_items)
    max_items = max_items or 5
    local articles = {}
    if not json then return articles end

    local ok, data = pcall(json.decode, json_text)
    if not ok or not data or not data.data or not data.data.children then
        return articles
    end

    for idx, child in ipairs(data.data.children) do
        local post = child.data
        if post and not post.stickied then
            local selftext = post.selftext or ""
            local clean_desc = Parser.stripHtml(selftext)
            if #clean_desc > 1200 then clean_desc = clean_desc:sub(1, 1200) .. "..." end
            if #clean_desc == 0 and post.url then
                clean_desc = "Link post: " .. post.url
            end

            table.insert(articles, {
                title = post.title or "Untitled Post",
                link = "https://reddit.com" .. (post.permalink or ""),
                author = "u/" .. (post.author or "unknown"),
                date = post.created_utc and os.date("%Y-%m-%d", post.created_utc) or "",
                summary = clean_desc,
                content_html = string.format("<p>%s</p><p><a href=\"%s\">%s</a></p>",
                    clean_desc, post.url or "", post.url or ""),
            })
            if #articles >= max_items then break end
        end
    end

    return articles
end

-- Parse Hacker News Firebase JSON
function Parser.parseHnItem(json_text)
    if not json then return nil end
    local ok, item = pcall(json.decode, json_text)
    if not ok or not item or item.deleted or item.dead then
        return nil
    end

    local clean_text = Parser.stripHtml(item.text or "")
    if #clean_text > 1200 then clean_text = clean_text:sub(1, 1200) .. "..." end
    if #clean_text == 0 and item.url then
        clean_text = "Article link: " .. item.url
    end

    return {
        title = item.title or "Untitled HN Story",
        link = item.url or ("https://news.ycombinator.com/item?id=" .. tostring(item.id)),
        author = item.by or "HN",
        date = item.time and os.date("%Y-%m-%d", item.time) or "",
        summary = clean_text,
        content_html = string.format("<p>%s</p><p><a href=\"%s\">%s</a></p>",
            clean_text, item.url or "", item.url or ""),
    }
end

return Parser
