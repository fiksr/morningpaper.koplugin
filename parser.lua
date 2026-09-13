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
    if not str then return ""end
    str = str:gsub("<!%[CDATA%[(.-)%]%]%s*>", "%1")
    str = str:gsub("&amp;", "&")
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
    return str
end

function Parser.stripHtml(html)
    if not html then return ""end
    local s = unescapeXml(html)
    -- Remove scripts, styles, iframes
    s = s:gsub("<script.-</script>", "")
         :gsub("<style.-</style>", "")
         :gsub("<iframe.-</iframe>", "")
         :gsub("<noscript.-</noscript>", "")
    -- Convert block elements to newlines
    s = s:gsub("<br%s*/?>", "\n")
         :gsub("</p>", "\n\n")
         :gsub("</div>", "\n")
         :gsub("</li>", "\n")
         :gsub("<h%d.->", "\n\n### ")
         :gsub("</h%d>", "\n\n")
    -- Strip remaining tags
    s = s:gsub("<[^>]+>", "")
    -- Clean multiple whitespace
    s = s:gsub("&nbsp;", "")
    s = s:gsub("[ \t]+", "")
    s = s:gsub("\n%s*\n%s*\n+", "\n\n")
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function Parser.cleanHtmlForEpub(html)
    if not html then return "<p></p>"end
    local clean_text = Parser.stripHtml(html)
    -- Format into clean paragraphs
    local paragraphs = {}
    for block in clean_text:gmatch("[^\r\n]+") do
        local p = block:gsub("^%s+", ""):gsub("%s+$", "")
        if #p > 0 then
            if p:sub(1, 4) == "### "then
                table.insert(paragraphs, string.format("<h3>%s</h3>", p:sub(5)))
            else
                table.insert(paragraphs, string.format("<p>%s</p>", p))
            end
        end
    end
    if #paragraphs == 0 then
        return "<p>(No article body available)</p>"
    end
    return table.concat(paragraphs, "\n")
end

-- Parse RSS 2.0 XML
function Parser.parseRss(xml_text, max_items)
    max_items = max_items or 5
    local articles = {}

    -- Extract items
    for item_block in xml_text:gmatch("<item.->(.-)</item>") do
        local title = item_block:match("<title.->(.-)</title>")
        local link = item_block:match("<link.->(.-)</link>")
        local desc = item_block:match("<content:encoded.->(.-)</content:encoded>")
                  or item_block:match("<description.->(.-)</description>")
                  or ""
        local author = item_block:match("<dc:creator.->(.-)</dc:creator>")
                    or item_block:match("<author.->(.-)</author>")
                    or ""
        local pub_date = item_block:match("<pubDate.->(.-)</pubDate>") or ""

        if title and #title > 0 then
            table.insert(articles, {
                title = Parser.stripHtml(title),
                link = unescapeXml(link or ""),
                author = Parser.stripHtml(author),
                date = pub_date:gsub("%+.*$", ""):gsub("%s+$", ""),
                summary = Parser.stripHtml(desc):sub(1, 1200),
                content_html = Parser.cleanHtmlForEpub(desc),
            })
            if #articles >= max_items then break end
        end
    end

    -- If no <item>, check for Atom <entry>
    if #articles == 0 then
        for entry_block in xml_text:gmatch("<entry.->(.-)</entry>") do
            local title = entry_block:match("<title.->(.-)</title>")
            local link = entry_block:match('<link.-href="([^"]+)"')
                      or entry_block:match("<link.-href='([^']+)'")
                      or entry_block:match("<link.->(.-)</link>")
            local desc = entry_block:match("<content.->(.-)</content>")
                      or entry_block:match("<summary.->(.-)</summary>")
                      or ""
            local author = entry_block:match("<name.->(.-)</name>") or ""
            local date = entry_block:match("<updated.->(.-)</updated>")
                      or entry_block:match("<published.->(.-)</published>") or ""

            if title and #title > 0 then
                table.insert(articles, {
                    title = Parser.stripHtml(title),
                    link = unescapeXml(link or ""),
                    author = Parser.stripHtml(author),
                    date = date:sub(1, 10),
                    summary = Parser.stripHtml(desc):sub(1, 1200),
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

    if not json or not json.decode then
        return articles
    end

    local ok, data = pcall(json.decode, json_text)
    if not ok or not data or not data.data or not data.data.children then
        return articles
    end

    for idx, child in ipairs(data.data.children) do
        local post = child.data
        if post and not post.stickied and not post.over_18 then
            local title = post.title or "Untitled"
            local author = "u/".. tostring(post.author or "anonymous")
            local score = post.score or 0
            local num_comments = post.num_comments or 0
            local selftext = post.selftext or ""
            local url = post.url or ("https://reddit.com".. (post.permalink or ""))

            local body = selftext
            if #body == 0 and post.url then
                body = string.format("Link: %s\n\n(Top link post on Reddit with %d upvotes and %d comments)", post.url, score, num_comments)
            else
                body = string.format("%s\n\n[Reddit: %d upvotes • %d comments]", body, score, num_comments)
            end

            table.insert(articles, {
                title = title,
                link = url,
                author = author,
                date = "Reddit Top",
                score = score,
                summary = body:sub(1, 1200),
                content_html = Parser.cleanHtmlForEpub(body),
            })

            if #articles >= max_items then break end
        end
    end

    return articles
end

return Parser
