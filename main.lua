--[[--
MorningPaper Main Plugin for KOReader.
Coordinates daily morning newspaper fetching, in-app reading, and EPUB compilation.
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
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


function MorningPaper:onDispatcherRegisterActions()
    Dispatcher:registerAction("morningpaper", {
        category = "none",
        event = "ShowMorningPaper",
        title = _("🗞️ Morning Paper"),
        general = true,
    })
    Dispatcher:registerAction("morningpaper_read", {
        category = "none",
        event = "ReadMorningPaper",
        title = _("🗞️ Read Today's News"),
        general = true,
    })
    Dispatcher:registerAction("morningpaper_generate", {
        category = "none",
        event = "GenerateMorningPaper",
        title = _("⚡ Generate Today's Newspaper"),
        general = true,
    })
end

function MorningPaper:onShowMorningPaper()
    local Menu = require("ui/widget/menu")
    local menu = Menu:new{
        title = _("🗞️ Morning Paper"),
        item_table = self:getSubMenuItems(),
        is_borderless = true,
    }
    UIManager:show(menu)
end

function MorningPaper:onReadMorningPaper()
    self:onReadInApp()
end

function MorningPaper:onGenerateMorningPaper()
    self:onGenerateDailyEdition()
end

function MorningPaper:init()
    self.settings = Settings:new()
    self.fetcher = Fetcher:new(self.settings)
    self.ai = AIBriefing:new(self.settings)
    self.builder = EpubBuilder:new(self.settings)
    self:onDispatcherRegisterActions()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function MorningPaper:addToMainMenu(menu_items)
    menu_items.morningpaper = {
        text = _("🗞️ Morning Paper"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
        sub_item_table = self:getSubMenuItems(),
    }
end

-- Fetch and return sections with optional AI summaries
function MorningPaper:fetchSections(on_done)
    local info = InfoMessage:new{
        text = _("Fetching Today's News...\nConnecting to active news feeds over Wi-Fi."),
    }
    UIManager:show(info)

    UIManager:scheduleIn(0.2, function()
        local sections = self.fetcher:fetchAllActiveFeeds()
        UIManager:close(info)

        if not sections or #sections == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No articles could be fetched.\nPlease check your Wi-Fi connection and enabled feeds."),
                timeout = 5,
            })
            return
        end

        local ai_enabled = self.settings:isAiEnabled()
        local ai_key = self.settings:getApiKey()
        if ai_enabled and #ai_key > 0 then
            local ai_info = InfoMessage:new{
                text = _("Generating AI Executive Briefings..."),
            }
            UIManager:show(ai_info)

            for s_idx, sec in ipairs(sections) do
                for a_idx, art in ipairs(sec.articles) do
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

        if on_done then
            on_done(sections)
        end
    end)
end

-- 1. In-App Interactive Reader (No EPUB needed)
function MorningPaper:onReadInApp()
    self:fetchSections(function(sections)
        self:showSectionBrowser(sections)
    end)
end

function MorningPaper:showSectionBrowser(sections)
    local out = {}
    local today_str = os.date("%Y-%m-%d")
    table.insert(out, "==================================================")
    table.insert(out, "🗞️ THE MORNING PAPER: " .. today_str)
    table.insert(out, "Daily Curated News & Executive Briefing")
    table.insert(out, "==================================================\n")

    for s_idx, sec in ipairs(sections) do
        table.insert(out, string.format("\n=== SECTION %d: %s (%d stories) ===\n", s_idx, sec.title:upper(), #sec.articles))

        for a_idx, art in ipairs(sec.articles) do
            table.insert(out, string.format("[%d.%d] %s", s_idx, a_idx, art.title))
            if art.author and #art.author > 0 then
                table.insert(out, "Source: " .. art.author .. (art.date and (" • " .. art.date) or ""))
            end

            if art.ai_summary and #art.ai_summary > 0 then
                table.insert(out, "\nEXECUTIVE BRIEFING:")
                for line in art.ai_summary:gmatch("[^\r\n]+") do
                    local clean = line:gsub("^[•%-%*]%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if #clean > 0 then
                        table.insert(out, "  • " .. clean)
                    end
                end
            end

            if art.summary and #art.summary > 0 then
                table.insert(out, "\nSUMMARY:")
                table.insert(out, "  " .. art.summary:gsub("\n+", " "))
            end
            table.insert(out, "\n--------------------------------------------------\n")
        end
    end

    local full_text = table.concat(out, "\n")
    local viewer = TextViewer:new{
        title = _("Today's Morning Paper"),
        text = full_text,
        text_type = "general",
    }
    UIManager:show(viewer)
end

-- 2. Compile & Save EPUB to designated folder
function MorningPaper:onCompileEpub()
    local today_str = os.date("%Y-%m-%d")
    self:fetchSections(function(sections)
        local build_info = InfoMessage:new{
            text = _("Compiling Morning Paper EPUB..."),
        }
        UIManager:show(build_info)

        local ok, epub_path = self.builder:buildEpub(sections, today_str)
        UIManager:close(build_info)

        if ok and epub_path then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Morning Paper Ready!\nSaved to:\n%s"), epub_path),
                timeout = 4,
            })

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

function MorningPaper:showSetFolderDialog()
    local cur_dir = self.settings:getOutputDirectory()
    local dialog
    dialog = InputDialog:new{
        title = _("Set News EPUB Save Folder"),
        input = cur_dir,
        input_hint = _("e.g. /mnt/us/books or /mnt/us/"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local val = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if #val > 0 then
                            self.settings:setOutputDirectory(val)
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Save folder updated to:\n%s"), val),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MorningPaper:getSubMenuItems()
    local cur_dir = self.settings:getOutputDirectory()
    local items = {
        {
            text = _("🗞️ Read Today's News (In-App Reader)"),
            callback = function()
                self:onReadInApp()
            end,
        },
        {
            text = _("⚡ Download & Open Today's EPUB"),
            callback = function()
                self:onCompileEpub()
            end,
        },
        {
            text = _("📡 Feed Subscriptions & Presets"),
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
                return string.format(_("AI Executive Briefing: %s"), status)
            end,
            checked_func = function() return self.settings:isAiEnabled() end,
            callback = function()
                self.settings:setAiEnabled(not self.settings:isAiEnabled())
            end,
        },
        {
            text_func = function()
                local lang = self.settings:getLanguage()
                local label = (lang == "serbian") and _("Serbian (Srpski - Latin)") or _("English")
                return string.format(_("Briefing Language: %s"), label)
            end,
            sub_item_table = {
                {
                    text = _("English"),
                    checked_func = function() return self.settings:getLanguage() == "english" end,
                    callback = function() self.settings:setLanguage("english") end,
                },
                {
                    text = _("Serbian (Srpski - Latin)"),
                    checked_func = function() return self.settings:getLanguage() == "serbian" end,
                    callback = function() self.settings:setLanguage("serbian") end,
                },
            },
        },
        {
            text_func = function()
                return string.format(_("Save Folder: %s"), self.settings:getOutputDirectory())
            end,
            sub_item_table = {
                {
                    text = _("/mnt/us/books (Kindle Books Folder)"),
                    checked_func = function() return self.settings:getOutputDirectory() == "/mnt/us/books" end,
                    callback = function() self.settings:setOutputDirectory("/mnt/us/books") end,
                },
                {
                    text = _("/mnt/us/ (Kindle Root Directory)"),
                    checked_func = function() return self.settings:getOutputDirectory() == "/mnt/us" end,
                    callback = function() self.settings:setOutputDirectory("/mnt/us") end,
                },
                {
                    text = _("/mnt/us/documents (Kindle Documents)"),
                    checked_func = function() return self.settings:getOutputDirectory() == "/mnt/us/documents" end,
                    callback = function() self.settings:setOutputDirectory("/mnt/us/documents") end,
                },
                {
                    text = _("Custom Folder Path..."),
                    callback = function() self:showSetFolderDialog() end,
                },
            },
        },
        {
            text_func = function()
                local prov = self.settings:getProvider()
                local key = self.settings:getApiKey(prov)
                local status = (#key > 0) and _("configured") or _("not set")
                return string.format(_("AI Provider: %s (%s)"), prov:upper(), status)
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
            text = _("Browse Past Editions Archive"),
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
