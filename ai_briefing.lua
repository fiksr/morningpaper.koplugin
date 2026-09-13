--[[--
MorningPaper AI Executive Briefing Engine.
Generates 3-bullet executive takeaways and translations using Groq or Gemini.
--]]--

local AIBriefing = {}
AIBriefing.__index = AIBriefing

local json = nil
local ok, mod = pcall(require, "json")
if ok and mod and mod.decode then json = mod
else
    ok, mod = pcall(require, "rapidjson")
    if ok and mod and mod.decode then json = mod end
end

local function encodeJSON(val)
    if json and json.encode then return json.encode(val) end
    if type(val) == "string" then
        return string.format('"%s"', val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', ''))
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    elseif type(val) == "table" then
        local is_array = (#val > 0)
        local parts = {}
        if is_array then
            for idx, v in ipairs(val) do
                table.insert(parts, encodeJSON(v))
            end
            return "[".. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, string.format('"%s":%s', k, encodeJSON(v)))
            end
            return "{".. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function decodeJSON(str)
    if json and json.decode then
        local ok_dec, res = pcall(json.decode, str)
        if ok_dec and res then return res end
    end
    return nil
end

function AIBriefing:new(settings)
    local o = setmetatable({}, self)
    o.settings = settings
    return o
end

function AIBriefing:sendChat(messages, system_prompt)
    local provider = self.settings:getProvider()
    local api_key = self.settings:getApiKey(provider)
    local model = self.settings:getModel()

    if #api_key == 0 then
        return nil, "API key not configured"
    end

    local url
    local headers = { "Content-Type: application/json", "Authorization: Bearer ".. api_key }
    local all_messages = {}
    if system_prompt and #system_prompt > 0 then
        table.insert(all_messages, { role = "system", content = system_prompt })
    end
    for idx, m in ipairs(messages) do
        table.insert(all_messages, m)
    end

    if provider == "groq" then
        url = "https://api.groq.com/openai/v1/chat/completions"
    else -- gemini
        url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    end

    local payload = {
        model = model,
        messages = all_messages,
        temperature = 0.2,
        max_tokens = 300,
    }

    local body_str = encodeJSON(payload)
    local safe_body = body_str:gsub("'", "'\\''")
    local header_args = ""
    for idx, h in ipairs(headers) do
        header_args = header_args .. string.format(' -H "%s"', h)
    end

    local cmd = string.format("curl -s -k -m 15 -X POST %s -d '%s' '%s' 2>/dev/null", header_args, safe_body, url)
    local handle = io.popen(cmd)
    if not handle then return nil, "Network execution failed" end
    local raw = handle:read("*a")
    handle:close()

    if not raw or #raw == 0 then return nil, "No response from AI server" end
    local res = decodeJSON(raw)
    if not res then return nil, "Invalid JSON from AI" end
    if res.error then
        local msg = (type(res.error) == "table" and res.error.message) or tostring(res.error)
        return nil, msg
    end
    if res.choices and res.choices[1] and res.choices[1].message then
        return res.choices[1].message.content
    end
    return nil, "Unexpected response format"
end

function AIBriefing:summarizeArticle(title, text)
    local lang = self.settings:getLanguage()
    local lang_instruction = (lang == "serbian")
        and "Respond strictly in natural Serbian (Latin alphabet). Provide a 3-bullet executive summary focusing on key facts."
        or "Respond in concise English. Provide a 3-bullet executive summary focusing on key facts."

    local system_prompt = string.format([[
You are an executive news editor compiling a morning briefing.
STRICT RULES:
1. Provide exactly 3 high-impact bullet points summarizing the core news, key facts, and significance.
2. Be direct, factual, and informative.
3. %s
]], lang_instruction)

    local user_prompt = string.format("Headline: %s\n\nArticle text/excerpt:\n%s", title, text:sub(1, 1500))
    return self:sendChat({ { role = "user", content = user_prompt } }, system_prompt)
end

return AIBriefing
