--[[--
MorningPaper Network Fetcher.
Retrieves RSS feeds, Substack newsletters, and Reddit top posts with robust curl handling.
--]]--

local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*[/\])") or ""
local Parser = dofile(plugin_dir .. "parser.lua")

local Fetcher = {}
Fetcher.__index = Fetcher

function Fetcher:new(settings)
    local o = setmetatable({}, self)
    o.settings = settings
    return o
end

local function executeCurl(url, custom_ua)
    local ua = custom_ua or "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    local safe_url = url:gsub("'", "'\\''")
    local cmd = string.format("curl -s -k -L -m 12 -A '%s' '%s' 2>/dev/null", ua, safe_url)

    local handle = io.popen(cmd)
    if not handle then return nil, "Failed to start network request" end
    local output = handle:read("*a")
    handle:close()

    if not output or #output == 0 then
        return nil, "No response from server"
    end
    return output
end

function Fetcher:fetchRssFeed(feed_url, max_items)
    local raw, err = executeCurl(feed_url)
    if not raw then return nil, err end
    return Parser.parseRss(raw, max_items)
end

function Fetcher:fetchReddit(subreddit, max_items)
    -- 1. Try old.reddit.com JSON endpoint (bypasses www.reddit.com 403 blocks)
    local url = string.format("https://old.reddit.com/r/%s/top.json?t=day&limit=10", subreddit)
    local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    local raw, err = executeCurl(url, ua)
    if raw and #raw > 0 then
        local articles = Parser.parseRedditJson(raw, max_items)
        if articles and #articles > 0 then
            return articles
        end
    end

    -- 2. Fallback to old.reddit.com RSS feed
    local rss_url = string.format("https://old.reddit.com/r/%s/.rss", subreddit)
    return self:fetchRssFeed(rss_url, max_items)
end

function Fetcher:fetchFeed(feed_obj, max_items)
    max_items = max_items or self.settings:getArticleLimit()
    if feed_obj.type == "reddit" then
        local sub = feed_obj.subreddit or (feed_obj.url and feed_obj.url:match("r/([%w_]+)")) or "technology"
        return self:fetchReddit(sub, max_items)
    else
        return self:fetchRssFeed(feed_obj.url, max_items)
    end
end

-- Fetch all active feeds and return grouped sections
function Fetcher:fetchAllActiveFeeds(progress_callback)
    local sections = {}
    local max_items = self.settings:getArticleLimit()

    -- 1. Presets
    local presets = self.settings:getPresetFeeds()
    for idx, f in ipairs(presets) do
        if f.enabled then
            if progress_callback then
                progress_callback(f.name)
            end
            local articles, err = self:fetchFeed(f, max_items)
            if articles and #articles > 0 then
                table.insert(sections, {
                    id = f.id,
                    title = f.name,
                    articles = articles,
                })
            end
        end
    end

    -- 2. Custom feeds
    local customs = self.settings:getCustomFeeds()
    for idx, f in ipairs(customs) do
        if f.enabled then
            if progress_callback then
                progress_callback(f.name)
            end
            local articles, err = self:fetchFeed(f, max_items)
            if articles and #articles > 0 then
                table.insert(sections, {
                    id = f.id,
                    title = f.name,
                    articles = articles,
                })
            end
        end
    end

    return sections
end

return Fetcher
