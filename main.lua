--[[--
MorningPaper Main Plugin for KOReader.
Coordinates daily morning newspaper fetching, AI executive summaries, and EPUB compilation.
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

-- Safe submodule loader
local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""
local Settings = dofile(plugin_dir .. "settings.lua")
local Parser = dofile(plugin_dir .. "parser.lua")
local Fetcher = dofile(plugin_dir .. "fetcher.lua")
local AIBriefing = dofile(plugin_dir .. "ai_briefing.lua")
local EpubBuilder = dofile(plugin_dir .. "epub_builder.lua")

-- Register into KOReader's menu order system
local function addToMenuOrder(module_path, section, name)
    local ok, order = pcall(require, module_path)
    if ok and order and order[section] then
        for idx, v in ipairs(order[section]) do
            if v == name then return end
        end
        table.insert(order[section], name)
    end
end
addToMenuOrder("ui/elements/reader_menu_order", "more_tools", "morningpaper")
addToMenuOrder("ui/elements/filemanager_menu_order", "more_tools", "morningpaper")

local MorningPaper = WidgetContainer:extend{
    name = "morningpaper",
    is_doc_only = false,
}

function MorningPaper:init()
    self.settings = Settings:new()
    self.fetcher = Fetcher:new(self.settings)
    self.ai = AIBriefing:new(self.settings)
    self.builder = EpubBuilder:new(self.settings)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function MorningPaper:addToMainMenu(menu_items)
    menu_items.morningpaper = {
        text = _("MorningPaper"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
        sub_item_table = self:getSubMenuItems(),
    }
end

function MorningPaper:onFetchPaper()
    local today_str = os.date("%Y-%m-%d")
    local info = InfoMessage:new{
        text = _("🗞️ Fetching Today's Morning Paper...\nConnecting to active news feeds over Wi-Fi."),
    }
    UIManager:show(info)

    UIManager:scheduleIn(0.2, function()
        -- 1. Fetch active sections
        local sections = self.fetcher:fetchAllActiveFeeds()
        UIManager:close(info)

        if not sections or #sections == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No articles could be fetched.\nPlease check your Wi-Fi connection and enabled feeds."),
                timeout = 5,
            })
            return
        end

        -- 2. Optional AI Executive Briefings
        local ai_enabled = self.settings:isAiEnabled()
        local ai_key = self.settings:getApiKey()
        if ai_enabled and #ai_key > 0 then
            local ai_info = InfoMessage:new{
                text = _("⚡ Generating AI Executive Briefings & Summaries..."),
            }
            UIManager:show(ai_info)

            for s_idx, sec in ipairs(sections) do
                for a_idx, art in ipairs(sec.articles) do
                    -- Summarize top 3 stories per section to save tokens and time
                    if a_idx <= 3 then
                        local summary, err = self.ai:summarizeArticle(art.title, art.summary)
                        if summary and #summary > 0 then
                            art.ai_summary = summary
                        end
                    end
                end
            end
            UIManager:close(ai_info)
        end

        -- 3. Compile EPUB
        local build_info = InfoMessage:new{
            text = _("📚 Compiling Morning Paper EPUB..."),
        }
        UIManager:show(build_info)

        local ok, epub_path = self.builder:buildEpub(sections, today_str)
        UIManager:close(build_info)

        if ok and epub_path then
            UIManager:show(InfoMessage:new{
                text = string.format(_("🗞️ Morning Paper Ready!\nSaved to:\n%s"), epub_path),
                timeout = 3,
            })

            -- Open the freshly compiled newspaper in KOReader immediately
            UIManager:scheduleIn(1.0, function()
                if self.ui and self.ui.onOpenFile then
                    self.ui:onOpenFile(epub_path)
                elseif self.ui and self.ui.openDocument then
                    self.ui:openDocument(epub_path)
                end
            end)
        else
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to compile EPUB:\n%s"), tostring(epub_path or "Unknown error")),
                timeout = 5,
            })
        end
    end)
end

function MorningPaper:getSubMenuItems()
    local items = {
        {
            text = _("🗞️ Fetch Today's Morning Paper"),
            callback = function()
                self:onFetchPaper()
            end,
        },
        {
            text = _("📰 Feed Subscriptions & Presets"),
            sub_item_table_func = function()
                return self:getFeedSubMenuItems()
            end,
        },
        {
            text = _("➕ Add Custom Feed (RSS / Substack / Reddit)"),
            callback = function()
                self:showAddCustomFeedDialog()
            end,
        },
        {
            text_func = function()
                local status = self.settings:isAiEnabled() and _("ON (3-Bullet Summaries)") or _("OFF (Raw Articles)")
                return string.format(_("🧠 AI Executive Briefing: %s"), status)
            end,
            checked_func = function() return self.settings:isAiEnabled() end,
            callback = function()
                self.settings:setAiEnabled(not self.settings:isAiEnabled())
            end,
        },
        {
            text_func = function()
                local lang = self.settings:getLanguage()
                local label = (lang == "serbian") and _("🇷🇸 Serbian (Srpski)") or _("🇬🇧 English")
                return string.format(_("🌐 Briefing Language: %s"), label)
            end,
            sub_item_table = {
                {
                    text = _("🇬🇧 English"),
                    checked_func = function() return self.settings:getLanguage() == "english" end,
                    callback = function() self.settings:setLanguage("english") end,
                },
                {
                    text = _("🇷🇸 Serbian (Srpski - Latin)"),
                    checked_func = function() return self.settings:getLanguage() == "serbian" end,
                    callback = function() self.settings:setLanguage("serbian") end,
                },
            },
        },
        {
            text_func = function()
                local prov = self.settings:getProvider()
                local key = self.settings:getApiKey(prov)
                local status = (#key > 0) and _("✓ configured") or _("✗ not set")
                return string.format(_("🤖 AI Provider: %s (%s)"), prov:upper(), status)
            end,
            sub_item_table = {
                {
                    text = _("Groq (Free & Blazing Fast)"),
                    checked_func = function() return self.settings:getProvider() == "groq" end,
                    callback = function() self.settings:setProvider("groq") end,
                },
                {
                    text = _("Google Gemini"),
                    checked_func = function() return self.settings:getProvider() == "gemini" end,
                    callback = function() self.settings:setProvider("gemini") end,
                },
            },
        },
        {
            text = _("📁 Browse Past Editions Archive"),
            callback = function()
                local out_dir = self.settings:getOutputDirectory()
                if self.ui and self.ui.onOpenFile then
                    self.ui:onOpenFile(out_dir)
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Past editions are stored in:\n%s"), out_dir),
                        timeout = 5,
                    })
                end
            end,
        },
    }
    return items
end

function MorningPaper:getFeedSubMenuItems()
    local sub = {}
    local presets = self.settings:getPresetFeeds()

    for idx, f in ipairs(presets) do
        table.insert(sub, {
            text = f.name,
            checked_func = function() return f.enabled end,
            callback = function()
                self.settings:togglePresetFeed(f.id)
            end,
        })
    end

    local customs = self.settings:getCustomFeeds()
    if #customs > 0 then
        table.insert(sub, { text = "--- " .. _("Custom Subscriptions") .. " ---", enabled = false })
        for idx, cf in ipairs(customs) do
            table.insert(sub, {
                text = cf.name .. " (" .. cf.type:upper() .. ")",
                checked_func = function() return cf.enabled end,
                callback = function()
                    cf.enabled = not cf.enabled
                    self.settings:save("custom_feeds", customs)
                end,
            })
        end
    end

    return sub
end

function MorningPaper:showAddCustomFeedDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Add RSS Feed, Substack, or Subreddit"),
        input_hint = _("e.g. r/books or https://blog.com/feed"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local val = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if #val == 0 then return end

                        if val:match("^r/[%w_]+") or not val:match("^https?://") then
                            local sub = val:gsub("^r/", "")
                            self.settings:addCustomFeed("r/" .. sub, "reddit", sub)
                            UIManager:show(InfoMessage:new{ text = string.format(_("Added r/%s!"), sub), timeout = 3 })
                        else
                            local name = val:match("https?://([^/]+)") or "Custom Feed"
                            self.settings:addCustomFeed(name, "rss", val)
                            UIManager:show(InfoMessage:new{ text = string.format(_("Added %s!"), name), timeout = 3 })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return MorningPaper
