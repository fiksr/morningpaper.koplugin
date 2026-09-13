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
    local val = G_reader_settings:readSetting("morningpaper_".. key)
    if val ~= nil then return val end
    return default
end

function Settings:save(key, val)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting("morningpaper_".. key, val)
end

function Settings:isAiEnabled()
    return self:get("ai_enabled", true)
end

function Settings:setAiEnabled(b)
    self:save("ai_enabled", b)
end

function Settings:getLanguage()
    return self:get("language", "english") -- "english" or "serbian"
end

function Settings:setLanguage(lang)
    self:save("language", lang)
end

function Settings:getArticleLimit()
    return self:get("article_limit", 5)
end

function Settings:setArticleLimit(n)
    self:save("article_limit", n)
end

function Settings:getProvider()
    return self:get("provider", "groq")
end

function Settings:setProvider(p)
    self:save("provider", p)
end

function Settings:getModel()
    local prov = self:getProvider()
    return self:get("model_".. prov, DEFAULT_MODELS[prov] or "openai/gpt-oss-120b")
end

function Settings:setModel(m)
    local prov = self:getProvider()
    self:save("model_".. prov, m)
end

function Settings:getApiKey(prov)
    prov = prov or self:getProvider()
    local val = self:get("api_key_".. prov, "")
    if val and #val > 0 then return val end

    if G_reader_settings then
        local shared = G_reader_settings:readSetting("bookrecap_api_key_".. prov)
        if shared and #shared > 0 then return shared end

        local shared_mm = G_reader_settings:readSetting("mindmap_api_key_".. prov)
        if shared_mm and #shared_mm > 0 then return shared_mm end

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
    self:save("api_key_".. prov, key)
end

-- Feeds Management
function Settings:getPresetFeeds()
    local saved = self:get("preset_feeds", nil)
    if saved and type(saved) == "table" then
        return saved
    end
    return DEFAULT_PRESET_FEEDS
end

function Settings:savePresetFeeds(feeds)
    self:save("preset_feeds", feeds)
end

function Settings:togglePresetFeed(feed_id)
    local feeds = self:getPresetFeeds()
    for idx, f in ipairs(feeds) do
        if f.id == feed_id then
            f.enabled = not f.enabled
            break
        end
    end
    self:savePresetFeeds(feeds)
end

function Settings:getCustomFeeds()
    return self:get("custom_feeds", {})
end

function Settings:addCustomFeed(name, feed_type, url_or_sub)
    local customs = self:getCustomFeeds()
    table.insert(customs, {
        id = "custom_".. os.time() .. "_".. math.random(100, 999),
        name = name,
        type = feed_type,
        url = url_or_sub,
        subreddit = (feed_type == "reddit") and url_or_sub or nil,
        enabled = true,
    })
    self:save("custom_feeds", customs)
end

function Settings:removeCustomFeed(feed_id)
    local customs = self:getCustomFeeds()
    local updated = {}
    for idx, f in ipairs(customs) do
        if f.id ~= feed_id then
            table.insert(updated, f)
        end
    end
    self:save("custom_feeds", updated)
end

-- Output Directory Configuration
function Settings:getOutputDirectory()
    local custom_dir = self:get("custom_output_dir", nil)
    if custom_dir and #custom_dir > 0 then
        pcall(lfs.mkdir, custom_dir)
        return custom_dir
    end

    -- Smart default search for Kindle / Kobo
    if lfs.attributes("/mnt/us/books", "mode") == "directory" then
        return "/mnt/us/books"
    elseif lfs.attributes("/mnt/us/documents", "mode") == "directory" then
        return "/mnt/us/documents"
    elseif lfs.attributes("/mnt/us", "mode") == "directory" then
        return "/mnt/us"
    end

    local data_dir = DataStorage:getFullDataDir() .. "/documents"
    pcall(lfs.mkdir, data_dir)
    return data_dir
end

function Settings:setOutputDirectory(dir)
    self:save("custom_output_dir", dir)
end

return Settings
