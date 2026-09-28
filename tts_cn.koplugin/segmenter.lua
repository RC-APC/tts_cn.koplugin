--[[
  segmenter.lua —— tts_cn 断句核心
  纯 Lua 5.1 / LuaJIT 实现，不依赖 KOReader 内部模块，可独立单元测试。

  设计目标（中文为主，英文作为纯英文书支持）：
    1. 保护 URL / 邮箱，避免其中的 . / ? 触发断句。
    2. 强句末：。！？!?  -> 断句（保留标点）。
    3. 软句末：；;      -> 断句（保留标点）。
    4. 句内停顿（不强制断）：……  —— ，、：: 及空格；仅当句长超过 max_len 时
       才在上一个句内停顿处软断，避免一次性读过长。
    5. CJK 引号/括号配对：句末标点若落在未闭合的引号/括号内，暂不切，
       待配对闭合且上一字符是句末标点时再补断（避免拦腰截断引语）。
    6. 英文缩写/缩略语保护：Mr. Dr. e.g. i.e. etc. fig. 以及 U.S. J.K. 等
       首字母缩写后不误断。
    7. 小数保护：数字.数字 不误断。
    8. 仅把 CJK 引号当作引号配对；ASCII " ' 当作普通字符（避免 don't 误判）。

  用法：
    local Segmenter = require("segmenter")
    local sentences = Segmenter.split(page_text, 80)
]]

local Segmenter = {}

-- 强句末标点（切句并保留）
local STRONG = { ["。"] = true, ["！"] = true, ["？"] = true, ["!"] = true, ["?"] = true }
-- 软句末标点（切句并保留）
local SOFT_TERMINAL = { ["；"] = true, [";"] = true }
-- 句内停顿（仅超长时软断用）
local WEAK = { ["，"] = true, ["、"] = true, ["："] = true, [":"] = true,
               ["—"] = true, ["…"] = true, [" "] = true }

-- 仅 CJK 引号 + 括号参与配对；ASCII 引号不作为引号，避免破坏英文缩写/所有格
local OPEN = { ["“"] = "”", ["‘"] = "’", ["「"] = "」", ["『"] = "』",
               ["（"] = "）", ["("] = ")", ["["] = "]", ["【"] = "】", ["《"] = "》" }
local CLOSE = { ["”"] = true, ["’"] = true, ["」"] = true, ["』"] = true,
                ["）"] = true, [")"] = true, ["]"] = true, ["】"] = true, ["》"] = true }

-- 已知缩写（小写形式）
local ABBR = {
    mr = true, mrs = true, ms = true, dr = true, prof = true, sr = true, jr = true,
    vs = true, etc = true, ["e.g"] = true, ["i.e"] = true, no = true, st = true,
    co = true, inc = true, ltd = true, fig = true, al = true, de = true, von = true,
    van = true, ["u.s"] = true, ["u.k"] = true, ["ph.d"] = true, eq = true,
}

-- ---------- 字符类别辅助（仅 ASCII 相关，CJK 不命中） ----------
local function is_alnum(ch) return ch:match("%w") ~= nil end
local function is_alpha(ch) return ch:match("%a") ~= nil end
local function is_digit(ch) return ch:match("%d") ~= nil end
local function is_upper(ch) return is_alpha(ch) and ch:upper() == ch end

-- ---------- UTF-8 码点拆分（Lua 5.1 字符串按字节，需手写） ----------
local function to_codepoints(s)
    local cps = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = string.byte(s, i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        cps[#cps + 1] = string.sub(s, i, i + len - 1)
        i = i + len
    end
    return cps
end

-- 取 buf 末尾连续的 [字母/数字/'./''] 片段（保留原始大小写）
local function last_word_raw(buf)
    local s = ""
    local i = #buf
    while i >= 1 do
        local c = buf[i]
        if is_alnum(c) or c == "'" or c == "." then
            s = c .. s
            i = i - 1
        else
            break
        end
    end
    return s
end

-- 返回（句点后的首个字母, 该字母紧邻的下一字符），用于判断 e.g. / U.S. 型缩写
local function next_alpha_and_following(cps, idx)
    local j = idx + 1
    local n = #cps
    while j <= n and cps[j] == " " do j = j + 1 end
    if j > n or not is_alpha(cps[j]) then return nil, nil end
    local nxt = cps[j]
    local k = j + 1
    local after = (k <= n) and cps[k] or nil
    return nxt, after
end

-- 去除首尾空白（含全角空格 E3 80 80）
local function trim(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^[\226\128\128]+", ""):gsub("[\226\128\128]+$", "")
    return s
end

-- 保护 URL / 邮箱，返回（文本, 占位符表）
local function protect(text)
    local placeholders = {}
    local function repl(m)
        local key = "\0" .. tostring(#placeholders) .. "\0"
        placeholders[key] = m
        return key
    end
    text = text:gsub("https?://[^%s%c]+", repl)
    text = text:gsub("[%w.%%+-]+@[%w%-]+%.%a+", repl)
    return text, placeholders
end

-- 把占位符还原（占位符含 NUL 字节，模式里用 %z 表示）
local function restore(sentences, placeholders)
    if not next(placeholders) then return sentences end
    for idx = 1, #sentences do
        local s = sentences[idx]
        for k, v in pairs(placeholders) do
            local pat = k:gsub("%z", "%%z")
            local kv = v  -- 闭包捕获当前值
            s = s:gsub(pat, function() return kv end)  -- 函数式替换，避免 % 转义/捕获陷阱
        end
        sentences[idx] = s
    end
    return sentences
end

--[[
  主入口：把文本切成句子数组（保留句末标点，已 trim）。
  max_len：单句最大长度，超过则在最近一个句内停顿处软断。
]]
function Segmenter.split(text, max_len)
    if not text or text == "" then return {} end
    max_len = max_len or 80

    local ptxt, placeholders = protect(text)
    local cps = to_codepoints(ptxt)
    local n = #cps
    local sentences = {}
    local buf = {}
    local quote_stack = {}

    local function finalize()
        local s = trim(table.concat(buf))
        if s ~= "" then sentences[#sentences + 1] = s end
        for k = #buf, 1, -1 do buf[k] = nil end
    end

    for i = 1, n do
        local ch = cps[i]

        if OPEN[ch] then
            quote_stack[#quote_stack + 1] = OPEN[ch]
            buf[#buf + 1] = ch

        elseif CLOSE[ch] then
            if #quote_stack > 0 and quote_stack[#quote_stack] == ch then
                quote_stack[#quote_stack] = nil
            end
            buf[#buf + 1] = ch
            -- 配对闭合且上一字符是句末标点 -> 补断
            if #quote_stack == 0 and #buf >= 2 then
                local prev = buf[#buf - 1]
                if STRONG[prev] or SOFT_TERMINAL[prev] then
                    finalize()
                end
            end

        else
            local is_term = false
            if STRONG[ch] or SOFT_TERMINAL[ch] or ch == "\n" then
                is_term = true
            elseif ch == "." then
                local w = last_word_raw(buf)
                local wl = w:lower()
                if ABBR[wl] then
                    is_term = false
                elseif #w == 1 and is_alpha(w) then
                    local nxt, after = next_alpha_and_following(cps, i)
                    if nxt ~= nil and (after == "." or (is_upper(nxt) and #nxt == 1)) then
                        is_term = false
                    else
                        local before = (i > 1) and cps[i - 1] or ""
                        local after_d = (i + 1 <= n) and cps[i + 1] or ""
                        is_term = not (is_digit(before) and is_digit(after_d))
                    end
                else
                    local before = (i > 1) and cps[i - 1] or ""
                    local after_d = (i + 1 <= n) and cps[i + 1] or ""
                    is_term = not (is_digit(before) and is_digit(after_d))
                end
            end

            if is_term then
                buf[#buf + 1] = ch
                if #quote_stack == 0 then
                    finalize()
                end
                -- 引号/括号内：仅入栈，暂不切
            else
                buf[#buf + 1] = ch
                if WEAK[ch] and #buf >= max_len then
                    finalize()
                end
            end
        end
    end

    if #buf > 0 then
        local s = trim(table.concat(buf))
        if s ~= "" then sentences[#sentences + 1] = s end
    end

    return restore(sentences, placeholders)
end

return Segmenter
