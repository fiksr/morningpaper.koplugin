--[[--
MorningPaper Settings Manager.
Handles feed subscriptions, AI executive summary preferences, custom save paths, and in-app cache.
--]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

local DEFAULT_PRESET_FEEDS = {
    { id = "hn", name = "Hacker News Top", type = "rss", url = "https://news.ycombinator.com/rss", enabled = true },
    { id = "arstechnica", name = "Ars Technica", type = "rss", url = "https://feeds.arstechnica.com/arstechnica/index", enabled = true },
    { id = "bbc_world", name = "BBC World News", type = "rss", url = "https://feeds.bbci.co.uk/news/world/rss.xml", enabled = true },
    { id = "quanta", name = "Quanta Magazine", type = "rss", url = "https://api.quantamagazine.org/feed/", enabled = true },
    { id = "guardian_world", name = "The Guardian World", type = "rss", url = "https://www.theguardian.com/world/rss", enabled = true },
    { id = "lobsters", name = "Lobste.rs Tech", type = "rss", url = "https://lobste.rs/rss", enabled = true },
    { id = "pragmatic_eng", name = "The Pragmatic Engineer", type = "rss", url = "https://newsletter.pragmaticengineer.com/feed", enabled = false },
    { id = "n1_serbia", name = "N1 Srbija", type = "rss", url = "https://n1info.rs/feed/", enabled = false },
    { id = "danas_serbia", name = "Danas", type = "rss", url = "https://www.danas.rs/feed/", enabled = false },
}

local DEFAULT_MODELS = {
    groq = "openai/gpt-oss-120b",
    gemini = "gemini-3.5-flash-lite",
}

function Settings:new()
    local o = setmetatable({}, self)
    return o
end

function Settings:get(key, default)
    if not G_reader_settings then return default end
    local val = G_reader_settings:readSetting("morningpaper_" .. key)
    if val ~= nil then return val end
    return default
end

function Settings:save(key, val)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting("morningpaper_" .. key, val)
end

function Settings:isAiEnabled()
    return self:get("ai_enabled", true)
end

function Settings:setAiEnabled(b)
    self:save("ai_enabled", b)
end

function Settings:getLanguage()
    return self:get("language", "english")
end

function Settings:setLanguage(lang)
    self:save("language", lang)
end

function Settings:getProvider()
    return self:get("provider", "groq")
end

function Settings:setProvider(p)
    self:save("provider", p)
end

function Settings:getModel(prov)
    prov = prov or self:getProvider()
    return self:get("model_" .. prov, DEFAULT_MODELS[prov] or "openai/gpt-oss-120b")
end

function Settings:setModel(m, prov)
    prov = prov or self:getProvider()
    self:save("model_" .. prov, m)
end

function Settings:getApiKey(prov)
    prov = prov or self:getProvider()
    local direct = self:get("api_key_" .. prov, "")
    if #direct > 0 then return direct end

    if G_reader_settings then
        local k = G_reader_settings:readSetting("mindmap_api_key_" .. prov)
        if k and #k > 0 then return k end
        local legacy = G_reader_settings:readSetting("bookrecap_api_key")
        if legacy and #legacy > 0 then
            if prov == "groq" and legacy:sub(1, 4) == "gsk_" then return legacy end
            if prov == "gemini" and legacy:sub(1, 4) == "AIza" then return legacy end
        end
    end
    return ""
end

function Settings:setApiKey(key, prov)
    prov = prov or self:getProvider()
    self:save("api_key_" .. prov, key)
end

-- Feeds Management
local function sanitizeFeedName(name)
    if not name then return "" end
    local s = name:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
    s = s:gsub("\239\184[\144-\159]", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

function Settings:getPresetFeeds()
    local saved = self:get("preset_feeds")
    local feeds = saved or DEFAULT_PRESET_FEEDS
    for _, f in ipairs(feeds) do
        f.name = sanitizeFeedName(f.name)
    end
    return feeds
end

function Settings:savePresetFeeds(feeds)
    self:save("preset_feeds", feeds)
end

function Settings:togglePresetFeed(id)
    local feeds = self:getPresetFeeds()
    for _, f in ipairs(feeds) do
        if f.id == id then
            f.enabled = not f.enabled
            break
        end
    end
    self:savePresetFeeds(feeds)
end

function Settings:getCustomFeeds()
    local saved = self:get("custom_feeds") or {}
    for _, f in ipairs(saved) do
        f.name = sanitizeFeedName(f.name)
    end
    return saved
end

function Settings:addCustomFeed(name, feed_type, url_or_sub)
    local feeds = self:getCustomFeeds()
    local clean_name = sanitizeFeedName(name)
    table.insert(feeds, {
        id = "custom_" .. tostring(os.time()),
        name = clean_name,
        type = feed_type,
        url = (feed_type == "rss" and url_or_sub or nil),
        subreddit = (feed_type == "reddit" and url_or_sub or nil),
        enabled = true,
    })
    self:save("custom_feeds", feeds)
end

function Settings:getArticleLimit()
    return self:get("article_limit", 5)
end

function Settings:setArticleLimit(n)
    self:save("article_limit", n)
end

function Settings:getOutputDirectory()
    local default_dir = "/mnt/us/books/"
    if not lfs.attributes("/mnt/us", "mode") then
        default_dir = DataStorage:getDataDir() .. "/books/"
    end
    return self:get("custom_output_dir", default_dir)
end

function Settings:setOutputDirectory(dir)
    if dir and #dir > 0 then
        if dir:sub(-1) ~= "/" and dir:sub(-1) ~= "\\" then
            dir = dir .. "/"
        end
        self:save("custom_output_dir", dir)
    end
end

function Settings:importKeyFromFile()
    local search_dirs = { "/mnt/us/", "/mnt/us/koreader/", DataStorage:getDataDir() .. "/" }
    local key_map = {
        groq = { "groq_key.txt", "groq.txt", "groq_api_key.txt" },
        gemini = { "gemini_key.txt", "gemini.txt", "gemini_api_key.txt" },
    }
    local imported = {}
    for prov, filenames in pairs(key_map) do
        for _, dir in ipairs(search_dirs) do
            for _, fname in ipairs(filenames) do
                local full = dir .. fname
                local f = io.open(full, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    if content then
                        local key = content:gsub("[\r\n%s]+", "")
                        if #key > 0 then
                            self:setApiKey(key, prov)
                            imported[prov] = key
                            break
                        end
                    end
                end
            end
            if imported[prov] then break end
        end
    end
    return (next(imported) ~= nil), imported
end

return Settings
