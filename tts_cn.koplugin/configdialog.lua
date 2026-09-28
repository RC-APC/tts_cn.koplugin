--[[
  configdialog.lua —— 设置界面
  用 KOReader 原生控件（Menu / InputDialog / SpinWidget）构建设置页。
  所有控件均懒加载 + pcall 保护：即使某个控件名随版本变化，也不会让插件崩溃，
  只会在该项提示无法加载。
]]

local UIManager = require("ui/uimanager")
local ConfigDialog = {}

function ConfigDialog:show(plugin)
    self.plugin = plugin
    self:show_menu()
end

function ConfigDialog:show_menu()
    local s = self.plugin.settings
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok then
        self.plugin:show_msg("无法加载 Menu 组件")
        return
    end
    local function short(v, n)
        v = tostring(v or "")
        if #v > n then return v:sub(1, n) .. "…" end
        return v ~= "" and v or "（未设置）"
    end
    local host, port = self:parse_host_port(s.http_url)
    local item_table = {
        { text = "朗读后端：" .. ((s.backend == "http") and "在线流式" or "本地 espeak"), action = "backend" },
        -- v1.62：键盘免输入的中继地址填法（4 段 IP + 端口用加减按钮，5-way/物理按键即可），
        -- 彻底绕开 KOReader 在 Kindle 上不弹软键盘、物理键盘又喂不进 InputDialog 的死穴。
        { text = "中继地址(免键盘填)：" .. (host and (host .. ":" .. port) or "（未设置）"),
          action = "relay_ip" },
        { text = "测试中继连通性（看原因）", action = "test_relay" },
        -- 高级：仍保留完整 URL 手工编辑（需要键盘，桌面 KOReader 调试用）
        { text = "在线接口地址(手动URL)：" .. short(s.http_url, 30), action = "http_url" },
        { text = "在线请求方式：" .. tostring(s.http_method), action = "http_method" },
        { text = "在线音频播放命令：" .. short(s.player_cmd, 30), action = "player_cmd" },
        { text = "音色（点选 3 种）：" .. short(s.voice, 20), action = "voice" },
        { text = "语速：" .. tostring(s.rate) .. "（菜单加减）", action = "rate" },
        { text = "音调：" .. tostring(s.pitch) .. "（菜单加减）", action = "pitch" },
        { text = "音量：" .. tostring(s.volume) .. "%（菜单加减）", action = "volume" },
        { text = "长句软断阈值：" .. tostring(s.max_len) .. "（菜单加减）", action = "max_len" },
        { text = "关于 / 帮助", action = "about" },
    }
    -- 关键：KOReader 的 Menu 只认每一项自己的 callback，构造参数 callback 无效
    for _, it in ipairs(item_table) do
        it.callback = function() self:on_item(it.action) end
    end
    local menu = Menu:new{
        title = "中文朗读 设置",
        show_parent = self.plugin.ui,
        item_table = item_table,
    }
    UIManager:show(menu)
end

function ConfigDialog:on_item(action)
    local s = self.plugin.settings
    if action == "backend" then
        s.backend = (s.backend == "http") and "espeak" or "http"
        self.plugin:save_settings(); self:show_menu()
    elseif action == "about" then
        self.plugin:show_msg("tts_cn：中文朗读（高质量断句 + 可插拔 TTS）。\n\n"
            .. "后端 espeak 离线免费；http 在线流式需 WiFi 与自建/云服务。\n"
            .. "详见插件目录 README.md。", 8)
    elseif action == "relay_ip" then
        -- v1.62：键盘免输入。用 5-way / 物理按键的加减填 4 段 IP + 端口，不需软键盘。
        self:edit_relay_ip()
    elseif action == "test_relay" then
        self.plugin:test_relay()
    elseif action == "http_url" then
        self:input("在线接口地址（用 {text}{voice} 占位）", s.http_url,
            function(v) s.http_url = v; self.plugin:save_settings(); self:show_menu() end)
    elseif action == "player_cmd" then
        self:input("在线音频播放命令（%s = 文件路径）", s.player_cmd,
            function(v) s.player_cmd = v; self.plugin:save_settings(); self:show_menu() end)
    elseif action == "voice" then
        -- v1.80：音色改为「点选 3 种」菜单（绕开 Kindle 3 不弹软键盘、物理键盘喂不进 InputDialog 的死穴）。
        -- 仍保留「手动输入其他音色」入口，供桌面 KOReader / 有键盘的环境使用。
        self:select_voice()
    elseif action == "http_method" then
        s.http_method = (s.http_method == "POST") and "GET" or "POST"
        self.plugin:save_settings(); self:show_menu()
    elseif action == "rate" then
        -- v1.80：语速改为菜单加减（±20/±10/±1），无需软键盘。
        self:step_value("语速（词/分）", s.rate, 80, 400,
            { { "+20", 20 }, { "+10", 10 }, { "+1", 1 }, { "-1", -1 }, { "-10", -10 }, { "-20", -20 } },
            function(v) return tostring(v) end,
            function(v) s.rate = v; self.plugin:save_settings(); self:show_menu() end)
    elseif action == "pitch" then
        self:step_value("音调（0-99）", s.pitch, 0, 99,
            { { "+10", 10 }, { "+1", 1 }, { "-1", -1 }, { "-10", -10 } },
            function(v) return tostring(v) end,
            function(v) s.pitch = v; self.plugin:save_settings(); self:show_menu() end)
    elseif action == "volume" then
        self:step_value("音量（0-300% 软件增益；100=原声，200=2倍）", s.volume, 0, 300,
            { { "+50", 50 }, { "+10", 10 }, { "+1", 1 }, { "-1", -1 }, { "-10", -10 }, { "-50", -50 } },
            function(v) return tostring(v) .. "%" end,
            function(v) s.volume = v; self.plugin:save_settings(); self.plugin:apply_volume(v); self:show_menu() end)
    elseif action == "max_len" then
        self:step_value("长句软断阈值（字符）", s.max_len, 40, 240,
            { { "+20", 20 }, { "+10", 10 }, { "+1", 1 }, { "-1", -1 }, { "-10", -10 }, { "-20", -20 } },
            function(v) return tostring(v) end,
            function(v) s.max_len = v; self.plugin:save_settings(); self:show_menu() end)
    end
end

-- v1.80：通用「菜单加减」数值编辑器（键盘免输入）。
-- 用 KOReader 原生 Menu 列出一组「+步/-步」条目，5-way 上下选 + 回车即改值，每次重绘实时回显；
-- 彻底绕开 KOReader 在 Kindle 3 上不弹软键盘、SpinWidget/InputDialog 喂不进数字的死穴。
--   title  菜单标题
--   value  当前值
--   min/max 取值边界（clamp）
--   steps  {{label, delta}, ...} 步进按钮
--   fmt    把当前值格式化成回显文本
--   cb     保存回调（已 clamp；用户取消不调用）
function ConfigDialog:step_value(title, value, min, max, steps, fmt, cb)
    local cur = math.max(min, math.min(max, value))
    local mw = nil
    local function close_menu()
        if mw then pcall(function() UIManager:close(mw) end); mw = nil end
    end
    local function build()
        close_menu()
        local items = {}
        table.insert(items, { text = "当前：" .. fmt(cur), action = "show" })
        for _, st in ipairs(steps) do
            -- v1.81 修复：steps 是位置数组 {label, delta}，必须用 st[1]/st[2] 取值；
            -- 之前误用 st.label/st.delta（字段访问）导致 nil 拼接崩溃，一点菜单加减就崩出。
            table.insert(items, { text = "    " .. st[1], action = "step", delta = st[2] })
        end
        table.insert(items, { text = "★ 保存", action = "save" })
        table.insert(items, { text = "✕ 取消", action = "cancel" })
        for _, it in ipairs(items) do
            it.callback = function()
                if it.action == "save" then
                    close_menu(); cb(cur); self:show_menu()
                elseif it.action == "cancel" then
                    close_menu(); self:show_menu()
                else
                    cur = math.max(min, math.min(max, cur + (it.delta or 0)))
                    build()
                end
            end
        end
        local ok, Menu = pcall(require, "ui/widget/menu")
        if not ok or not Menu then
            self.plugin:show_msg("无法加载 Menu 组件", 2); return
        end
        mw = Menu:new{
            title = title,
            show_parent = self.plugin.ui,
            item_table = items,
        }
        UIManager:show(mw)
    end
    build()
end

-- v1.80：音色点选菜单（键盘免输入）。列出 3 种常用 edge-tts 中文音色，当前选中的打 ✓；
-- 额外保留「手动输入其他音色」入口（需软键盘，桌面 KOReader / 有键盘环境用）。
function ConfigDialog:select_voice()
    local voices = {
        { name = "晓晓（女·温暖）",        id = "zh-CN-XiaoxiaoNeural" },
        { name = "云希（男·亲切）",        id = "zh-CN-YunxiNeural" },
        { name = "云扬（男·沉稳·新闻）",    id = "zh-CN-YunyangNeural" },
    }
    local items = {}
    for _, vv in ipairs(voices) do
        local mark = (self.plugin.settings.voice == vv.id) and "  ✓" or ""
        table.insert(items, { text = vv.name .. mark, action = "set", id = vv.id })
    end
    table.insert(items, { text = "手动输入其他音色（需键盘）", action = "manual" })
    for _, it in ipairs(items) do
        it.callback = function()
            if it.action == "set" then
                self.plugin.settings.voice = it.id
                self.plugin:save_settings(); self:show_menu()
            else
                self:input("音色 ID（如 zh-CN-XiaoxiaoNeural）", self.plugin.settings.voice,
                    function(v) self.plugin.settings.voice = v; self.plugin:save_settings(); self:show_menu() end)
            end
        end
    end
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok or not Menu then
        self.plugin:show_msg("无法加载 Menu 组件", 2); return
    end
    local mw = Menu:new{
        title = "选择音色",
        show_parent = self.plugin.ui,
        item_table = items,
    }
    UIManager:show(mw)
end

-- v1.62：从 URL 解析出 主机 + 端口（缺省 192.168.0.1:5000）
function ConfigDialog:parse_host_port(url)
    url = url or ""
    local host = url:match("^https?://([^:/]+)")
    local port = tonumber((url:match(":(%d+)")) or "") or 5000
    if host then
        local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        if a then return host, port end
    end
    return "192.168.0.1", port
end

-- v1.80：键盘免输入的中继地址填法（纯 Menu 步进器，彻底弃用 SpinWidget/InputDialog）。
-- 相对 v1.70 的改动：
--   ① 每段 IP 都加 ±100（之前只有端口有），跨网段改第 3/4 段时免键盘也能大幅跳。
--   ② 菜单顺序改为「第3段 → 第4段 → 第1段 → 第2段 → 端口」：
--      用户反馈 Kindle 3 上长菜单「选完第二项就弹回第一项（第一页）」，把最常改的
--      第3、4段放最前（顶部），即使每次重绘从顶部开始，视觉跳动也最小。
--   ③ 保存的 URL 改用 voice={voice} 占位符（与 build_url 的 {voice} 替换对齐），
--      让「音色」菜单的选择真正生效（v1.70 写死 Xiaoxiao，音色选择对 http 后端无效）。
function ConfigDialog:edit_relay_ip()
    local host, port = self:parse_host_port(self.plugin.settings.http_url)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    local oct = { tonumber(a) or 192, tonumber(b) or 168, tonumber(c) or 0, tonumber(d) or 1 }
    local cur_port = port

    local mw = nil
    local function close_menu()
        if mw then pcall(function() UIManager:close(mw) end); mw = nil end
    end
    local function save()
        close_menu()
        -- v1.80：voice 用 {voice} 占位符，由 TTSengine:build_url 替换为 settings.voice，
        -- 使「音色」菜单的选择对 http 后端生效（不再写死 Xiaoxiao）。
        local u = string.format(
            "http://%d.%d.%d.%d:%d/tts?voice={voice}&text={text}",
            oct[1], oct[2], oct[3], oct[4], cur_port)
        self.plugin.settings.http_url = u
        self.plugin:save_settings()
        self:show_menu()
    end
    local function adj(oct_i, delta)
        if oct_i then
            oct[oct_i] = math.max(0, math.min(255, oct[oct_i] + delta))
        else
            cur_port = math.max(1, math.min(65535, cur_port + delta))
        end
    end

    local function build()
        close_menu()
        local items = {}
        -- v1.80：第3、4段放最前（用户最常改、且 Kindle 3 长菜单有弹回顶部现象，放在顶部跳动最小）。
        local order = { 3, 4, 1, 2 }
        for _, i in ipairs(order) do
            table.insert(items, { text = "第" .. i .. "段： " .. oct[i], action = "show", oct = i })
            table.insert(items, { text = "    ▲ +100", action = "up100", oct = i })
            table.insert(items, { text = "    ▲ +10 ", action = "up10",  oct = i })
            table.insert(items, { text = "    ▲ +1  ", action = "up1",   oct = i })
            table.insert(items, { text = "    ▼ -1  ", action = "dn1",   oct = i })
            table.insert(items, { text = "    ▼ -10 ", action = "dn10",  oct = i })
            table.insert(items, { text = "    ▼ -100", action = "dn100", oct = i })
        end
        table.insert(items, { text = "端口： " .. cur_port, action = "show" })
        table.insert(items, { text = "    ▲ +100", action = "pup100" })
        table.insert(items, { text = "    ▲ +10 ", action = "pup10" })
        table.insert(items, { text = "    ▲ +1  ", action = "pup1" })
        table.insert(items, { text = "    ▼ -1  ", action = "pdn1" })
        table.insert(items, { text = "    ▼ -10 ", action = "pdn10" })
        table.insert(items, { text = "    ▼ -100", action = "pdn100" })
        table.insert(items, { text = "★ 保存并使用当前地址", action = "save" })
        table.insert(items, { text = "✕ 取消", action = "cancel" })

        for _, it in ipairs(items) do
            it.callback = function()
                if it.action == "save" then
                    save()
                elseif it.action == "cancel" then
                    close_menu(); self:show_menu()
                elseif it.action == "show" then
                    build()
                elseif it.oct then
                    if it.action == "up100" then adj(it.oct, 100) end
                    if it.action == "up10"  then adj(it.oct, 10) end
                    if it.action == "up1"   then adj(it.oct, 1) end
                    if it.action == "dn1"   then adj(it.oct, -1) end
                    if it.action == "dn10"  then adj(it.oct, -10) end
                    if it.action == "dn100" then adj(it.oct, -100) end
                    build()
                else
                    if it.action == "pup100" then adj(nil, 100) end
                    if it.action == "pup10"  then adj(nil, 10) end
                    if it.action == "pup1"   then adj(nil, 1) end
                    if it.action == "pdn1"   then adj(nil, -1) end
                    if it.action == "pdn10"  then adj(nil, -10) end
                    if it.action == "pdn100" then adj(nil, -100) end
                    build()
                end
            end
        end

        local ok, Menu = pcall(require, "ui/widget/menu")
        if not ok or not Menu then
            self.plugin:show_msg("无法加载 Menu 组件", 2); return
        end
        mw = Menu:new{
            title = "中继地址（菜单加减，无需键盘）",
            show_parent = self.plugin.ui,
            item_table = items,
        }
        UIManager:show(mw)
    end
    build()
end

-- v1.62：单个数值的 SpinWidget 封装（键盘免输入）。
-- KOReader v2026.07.1 的 SpinWidget 用 value_min/value_max（旧版 minimum/maximum 会崩），
-- callback 收到的是 spin 控件本身，从 spin.value 取整数值。
function ConfigDialog:spin_octet(title, value, vmin, vmax, cb)
    local ok, Spin = pcall(require, "ui/widget/spinwidget")
    if not ok or not Spin then
        self.plugin:show_msg("无法加载 SpinWidget，请用 SSH 改设置文件", 3)
        return
    end
    local spin = Spin:new{
        title = title,
        value = value,
        value_min = vmin,
        value_max = vmax,
        value_step = 1,
        value_hold_step = (vmax <= 255) and 10 or 100,
        -- v1.69：default_value 故意设成与当前值不同，强制「确定」按钮始终可点。
        -- 背景：KOReader 的 SpinWidget 在 value==default_value（未改动）时会把「确定」按钮
        -- 置灰禁用，导致点不动、无法跳到下一段（用户原话"没改所以灰色"）。
        -- 这里把 default 拉到相邻值（不超出 [vmin,vmax]），value 永远是"已改动"态，按钮常亮。
        default_value = (value < vmax) and (value + 1) or (value - 1),
        ok_text = "确定",
        cancel_text = "取消",
        callback = function(val)
            local v = (type(val) == "number") and val or (val and val.value)
            if v == nil then return end
            v = math.floor(v + 0.5)
            if v < vmin then v = vmin end
            if v > vmax then v = vmax end
            if cb then cb(v) end
        end,
        close_callback = function() end,
    }
    UIManager:show(spin)
end

function ConfigDialog:input(title, value, cb)
    local ok, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok then self.plugin:show_msg("无法加载 InputDialog"); return end
    local d
    -- 取输入框文本：v2026.07.1 是 getInputText()，更早版本是 getInputValue()，二者都试以兼容。
    local function getval()
        if not d then return "" end
        local v = ""
        pcall(function()
            if type(d.getInputText) == "function" then v = d:getInputText()
            elseif type(d.getInputValue) == "function" then v = d:getInputValue() end
        end)
        return v or ""
    end
    -- v1.54 关键修复：显式传 buttons，每个按钮写死非 nil 的 callback。
    -- 本机（MiuRead/KOReader v2026.07.1）的 InputDialog 简化回调模式（只传 callback 字段）
    -- 会把「确定」按钮的 callback 生成成 nil，一点击即 buttontable.lua:82
    -- "attempt to call field 'callback' (a nil value)" 把阅读器拖崩（v1.53 崩溃根因）。
    -- 显式 buttons 后按钮回调由我们掌控，绝不可能是 nil。
    d = InputDialog:new{
        title = title,
        input = value,
        input_type = "string",
        para = true,
        ok_text = "确定",
        cancel_text = "取消",
        buttons = {
            {
                {
                    text = "确定",
                    callback = function()
                        local v = getval()
                        pcall(function() UIManager:close(d) end)
                        if cb then cb(v) end
                    end,
                },
                {
                    text = "取消",
                    callback = function()
                        pcall(function() UIManager:close(d) end)
                    end,
                },
            },
        },
    }
    UIManager:show(d)
end

-- v1.53：数值设置改用「输入框 + 数字解析」，彻底绕开 KOReader SpinWidget 在本机
-- numberpickerwidget.lua 的字段兼容坑（旧版传 minimum/maximum 导致 picker 收到非法值、
-- format 拿到 table 直接把阅读器带崩）。输入框已在 http_url 等项验证可用，解析后 clamp 到 [min,max]。
function ConfigDialog:number_input(title, value, min, max, cb)
    self:input(title .. "（范围 " .. min .. "–" .. max .. "，输入数字）", tostring(value),
        function(raw)
            if not raw then return end
            local v = tonumber(raw)
            if not v then
                self.plugin:show_msg("请输入数字", 2)
                return
            end
            v = math.floor(v + 0.5)
            if v < min then v = min end
            if v > max then v = max end
            cb(v)
        end)
end

return ConfigDialog
