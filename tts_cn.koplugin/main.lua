--[[
  main.lua —— tts_cn 插件入口（KOReader 标准插件契约）

  关键：本插件是 WidgetContainer 子类，name 与目录名一致。
  init() 必须调用 self.ui.menu:registerToMainMenu(self)，
  否则 KOReader 永远不会调用 addToMainMenu，菜单里就不会出现本插件。

  本文件做了「防爆」处理：所有顶层依赖（含 KOReader 内部模块）均用
  pcall 安全加载，缺失则用占位/降级对象。这样即使某个模块在设备上
  加载失败，TTS_CN 仍能被定义、init 仍能被调用、主菜单项仍能挂上，
  而不会整盘崩溃成 "attempt to call a nil value"（这正是早期版本在
  crash.log 里报的错）。

  功能：开始/停止朗读、暂停/继续、设置、按句高亮（尽力）、自动翻页。
  朗读循环走 UIManager 事件调度（scheduleIn + 引擎播放完成回调），不阻塞界面。
]]

-- 防爆 require：失败返回 nil 而非抛出，避免连累整个 main.lua 加载。
-- v1.37 起失败必须留痕：之前静默吞错，「音频引擎未加载」却查不到是哪个模块、
-- 因为什么错（v1.36 的 cdef 冲突就是这么被藏了两天）。
local function safe_require(mod)
    local ok, m = pcall(require, mod)
    if ok and m then return m end
    pcall(function()
        local Logger = require("logger")
        local msg = "safe_require 失败: " .. tostring(mod) .. " 原因: " .. tostring(m)
        if Logger then
            if Logger.err then Logger.err("[tts_cn] " .. msg)
            elseif Logger.warn then Logger.warn("[tts_cn] " .. msg)
            elseif Logger.info then Logger.info("[tts_cn] " .. msg) end
        end
    end)
    return nil
end

-- 把本插件目录加入 package.path，确保 require("segmenter") 等能找到同目录模块。
pcall(function()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:match("@(.*/)") or src:match("(.*/)")
    if dir and package and package.path then
        package.path = dir .. "?.lua;" .. package.path
    end
end)

-- ---------- 顶层依赖：全部安全加载 ----------
local WidgetContainer = safe_require("ui/widget/container/widgetcontainer")
if not WidgetContainer then
    -- 最小替身：保证插件对象可被 extend 且 init 可被安全调用。
    --（正常 KOReader / MiuRead 环境都有 widgetcontainer，这里只是兜底。）
    WidgetContainer = {
        extend = function(_, t)
            t = t or {}
            t.init = t.init or function() end
            return t
        end,
    }
end

local UIManager = safe_require("ui/uimanager")
if not UIManager then
    UIManager = { show = function() end, scheduleIn = function() end,
                  schedule = function() end, run = function() end }
end
local InfoMessage = safe_require("ui/widget/infomessage")
if not InfoMessage then
    InfoMessage = { new = function() return {} end }
end

-- 自包含朗读屏显用的依赖：优先 ScrollTextWidget，其次 TextBoxWidget / TextWidget
-- （核心 widget，MiuRead 通常仍保留），最后用 Screen.fb 直接画到墨水屏。
-- 注意：MiuRead 冻结运行时 require("ui/screen") 常返回 nil，但 Screen 全局对象通常仍在，
-- 因此 Screen 优先取全局，再回退 Device.screen / require。
local Device = safe_require("ui/device")
local Screen = _G.Screen or (UIManager and UIManager.Screen) or (Device and Device.screen)
            or safe_require("ui/screen") or safe_require("device/screen")
local ScrollTextWidget = safe_require("ui/widget/scrolltextwidget")
local TextBoxWidget  = safe_require("ui/widget/textboxwidget")
local TextWidget      = safe_require("ui/widget/textwidget")

local Segmenter   = safe_require("segmenter")
local AudioPlayer = safe_require("audioplayer")
local TTSengine   = safe_require("ttsengine")
local ConfigDialog = safe_require("configdialog")
local logger = safe_require("logger")

-- 诊断日志：把取文/播放相关的失败写入 crash.log（标记 [tts_cn]），便于真机排查。
local function log_err(msg)
    pcall(function()
        if logger and logger.err then logger.err("[tts_cn] " .. tostring(msg)) end
    end)
end

-- 列出 table（含元表链）上的方法名，辅助排查设备上的 document 接口差异。
local function list_methods(t)
    local names, seen = {}, {}
    local function collect(obj)
        if type(obj) ~= "table" then return end
        for k, v in pairs(obj) do
            if type(v) == "function" and not seen[k] then
                seen[k] = true
                names[#names + 1] = tostring(k)
            end
        end
        local m = getmetatable(obj)
        if m and m.__index and type(m.__index) == "table" then collect(m.__index) end
    end
    collect(t)
    return table.concat(names, ",")
end

local DEFAULTS = {
    backend = "http",     -- "espeak" | "http"（本设备未装 espeak，默认走在线）
    voice = "zh",        -- espeak 音色，如 zh / zh+f2 / en
    rate = 160,          -- 语速（词/分）
    pitch = 50,          -- 音调 0-99
    volume = 180,        -- 音量（v1.53 软件增益百分比，100=原样；edge-tts 输出偏弱，默认 180% 更清晰；MiuRead 物理音量键无效）
    max_len = 80,        -- 长句软断阈值（字符）
    -- 默认在线接口：手机局域网中继（Kindle 3/MiuRead 对云端 HTTPS 域名有 DNS/TLS 限制，
    -- 局域网字面量 IP 直连、不走 DNS，是本设备唯一稳定通路）。
    -- 请把 192.168.0.1 改成你手机在 WiFi 下的真实 IP，并在设置里确认/修改。
    http_url = "http://192.168.0.101:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}",
    http_method = "GET", -- GET | POST
    player_cmd = "aplay -q", -- 在线后端「兜底」播放命令（仅当 KOReader 内置音频引擎不可用时才用）
    speed_fix = false,  -- v1.41 语速校正：内容预降 8000Hz 喂「开在16000的设备」→ 原速+干净（朗读中可切换）
    autostart = false,
}

local TTS_CN = WidgetContainer:extend{
    name = "tts_cn",
    is_doc_only = false,
}

local PLUGIN_VERSION = "1.82"  -- 版本标记：init / start_tts 都打进日志，便于确认运行的是哪一版

-- ---------- 生命周期 ----------
function TTS_CN:init()
    log_err("init v" .. PLUGIN_VERSION .. " 加载成功")
    -- 资源探测：下一次日志直接告诉我们屏显可用哪条渲染路径（避免反复试错）
    log_err(string.format("init 资源探测: Screen=%s(_G=%s Device=%s UIManager.screen=%s _G.fb=%s UIManager.fb=%s) Screen.fb=%s ScrollTextWidget=%s TextBoxWidget=%s TextWidget=%s UIManager=%s",
        Screen and "有" or "无",
        _G.Screen and "Y" or "N",
        (Device and Device.screen) and "Y" or "N",
        (UIManager and UIManager.screen) and "Y" or "无",
        _G.fb and "Y" or "N",
        (UIManager and UIManager.fb) and "Y" or "无",
        (Screen and Screen.fb) and "有" or "无",
        (Screen and Screen.getWidth) and "有" or "无",
        ScrollTextWidget and "有" or "无",
        TextBoxWidget and "有" or "无",
        TextWidget and "有" or "无",
        UIManager and "有" or "无"))

    -- socket 能力自检：确认核心 socket 是否提供 tcp()（http 子模块一定没有）
    -- 这决定了下载层能否建带超时的新连接，直接影响是否出现 v1.24 的截断问题
    pcall(function()
        local sok, sk = pcall(require, "socket")
        local hok, sh = pcall(require, "socket.http")
        local lok, lt = pcall(require, "ltn12")
        log_err(string.format("init socket 自检: core socket=%s socket.tcp=%s socket.http=%s ltn12=%s",
            (sok and sk) and "有" or "无",
            (sok and sk and sk.tcp) and "有" or "无",
            (hok and sh) and "有" or "无",
            (lok and lt) and "有" or "无"))
    end)

    -- WidgetContainer 基类 init（若存在），用 pcall 保护。
    pcall(function()
        if WidgetContainer and WidgetContainer.init then
            WidgetContainer.init(self)
        end
    end)

    -- 关键步骤：把自己注册进主菜单系统，KOReader 才会调用 addToMainMenu。
    -- 用 pcall 包裹：即使此 API 在当前版本略有差异，也不至于崩。
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        pcall(function()
            self.ui.menu:registerToMainMenu(self)
        end)
    end

    -- 文件管理器（书架）界面同样注册，便于先配置在线接口。
    pcall(function()
        if self.ui and self.ui.file_chooser_menu and self.ui.file_chooser_menu.registerToMainMenu then
            self.ui.file_chooser_menu:registerToMainMenu(self)
        end
    end)

    self.settings = self:load_settings()
    self.running = false
    self.stop = false
    self.paused = false
    self.sentences = nil
    self.sent_idx = 0
    self.cur_page = nil
    self.highlight_disabled = false
    self.audio = nil
    self.engine = nil  -- 懒加载，避免在无文档界面（如书架）提前创建
    self._read_widget = nil  -- 自包含朗读屏显层（绕开 MiuRead 冻结翻页的屏幕渲染）

    -- v1.61：彻底删除「加载即纠偏/自动改地址」逻辑。
    -- 历史教训：本设备（Kindle 3 / MiuRead）对云端 HTTPS 域名存在 DNS/TLS 握手限制，
    -- 自动把地址切到云端或网关都会把配置永久污染成「连不上」的地址，且用户设好的局域网 IP
    -- 也会被覆盖。从此地址 100% 由用户在「设置→在线接口地址」掌控，插件只读、绝不改写。
    -- 只读诊断：仅打印当前地址类型，便于排查，不影响配置。
    pcall(function()
        local u = self.settings.http_url or ""
        local h = u:match("^https?://([^:/]+)")
        if h and not h:match("^%d+%.%d+%.%d+%.%d+$") then
            log_err("init: 当前接口为云端域名(" .. h
                .. ")。本设备对 HTTPS 域名有 DNS/TLS 限制，建议改用手机局域网 IP："
                .. "http://<手机在同一 WiFi 下的 IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}")
        end
    end)

    -- 键盘快捷键：声明在 self.key_events 上（KOReader 标准做法，会被快捷键面板收录并分发）
    --   G = 开始/停止朗读（切换）   S = 停止   P = 暂停/继续
    self.key_events = {
        ToggleTTS_CN = { { "G" } },
        StopTTS_CN   = { { "S" } },
        PauseTTS_CN  = { { "P" } },
    }
    -- v1.76：KOReader 里插件自身的 key_events 不进入输入焦点链（焦点在 readerui，插件只是挂其上的
    -- 对象，不在 widget 栈里），P 字母键无法直接派发到插件。故改用官方 Dispatcher 注册动作：
    -- 用户去「设置 → 手势/快捷键」把任意物理键/手势（如 P 键、长按屏幕）绑到「TTS 暂停/继续」
    -- 等动作，即可按键暂停。现在也立即可用：阅读器菜单键 → 中文朗读 → 暂停/继续。
    local okd, Dispatcher = pcall(require, "dispatcher")
    if okd and Dispatcher and Dispatcher.registerAction then
        -- 同时带 event 与 callback 两种字段：新 KOReader 走 callback 直接调；老版本走 event 派发。
        -- 注意：那台机器（Kindle3 系）不把插件事件派发到插件焦点链，event 路径多半无效，
        -- callback 路径依赖版本；无论如何，菜单项（addToMainMenu 的「暂停/继续」）是直接回调、确定可用。
        pcall(function() Dispatcher:registerAction("tts_cn_toggle", { category="none", event="ToggleTTS_CN", title="TTS 开始/停止", general=true, callback=function() self:toggle() end }) end)
        pcall(function() Dispatcher:registerAction("tts_cn_pause", { category="none", event="PauseTTS_CN", title="TTS 暂停/继续", general=true, callback=function() self:pause_tts() end }) end)
        pcall(function() Dispatcher:registerAction("tts_cn_stop", { category="none", event="StopTTS_CN", title="TTS 停止", general=true, callback=function() self:stop_tts() end }) end)
    end
end

-- 键盘快捷键回调
function TTS_CN:onToggleTTS_CN()
    self:toggle()
    return true
end

function TTS_CN:onStopTTS_CN()
    self:stop_tts()
    return true
end

function TTS_CN:onPauseTTS_CN()
    self:pause_tts()
    return true
end

function TTS_CN:onCloseDocument()
    if self.running then
        self.stop = true
        self.running = false
        if self.engine then pcall(function() self.engine:stop() end) end
    end
end

-- 懒加载音频引擎（仅在真正开始朗读时创建，依赖 settings 已就绪）
function TTS_CN:ensure_engine()
    if self.engine then return true end
    if not (AudioPlayer and TTSengine) then
        self:show_msg("音频引擎未加载，无法朗读", 2)
        return false
    end
    local ok = pcall(function()
        self.audio = AudioPlayer:new({ tmpdir = "/tmp" })
        self.engine = TTSengine:new(self.audio, self.settings or self:load_settings())
        -- v1.41：把持久化的「语速校正」开关应用到播放器（之后菜单切换实时生效）
        if self.audio and self.audio.set_speed_fix then
            self.audio:set_speed_fix(self.settings.speed_fix)
        end
        if self.audio and self.audio.set_volume then
            self.audio:set_volume(self.settings.volume)
        end
    end)
    if not ok or not self.engine then
        self:show_msg("音频引擎初始化失败", 2)
        return false
    end
    -- 记录使用了哪种音频后端，便于从日志确认
    local Logger = require("logger")
    if Logger and Logger.info then
        if self.audio.has_internal_player then
            Logger.info("[tts_cn] 音频后端：" .. tostring(self.audio.internal_kind) .. "（原生/内置，无需 aplay）")
        elseif self.audio.player_cmd and self.audio.player_cmd ~= "aplay -q" then
            Logger.info("[tts_cn] 音频后端：外部命令 " .. tostring(self.audio.player_cmd))
        else
            Logger.info("[tts_cn] 音频后端：未找到可用后端（ALSA/SDL2/ffi/audio 均不可用，且无 CLI 播放器）")
        end
        if self.audio.probe_info then
            Logger.info("[tts_cn] 音频探测详情：" .. tostring(self.audio:probe_info()))
        end
    end
    return true
end

-- v1.53 把设置里的音量百分比应用到音频播放器（软件增益）。朗读中改也立即生效（下一句）。
function TTS_CN:apply_volume(v)
    if self.audio and self.audio.set_volume then
        pcall(function() self.audio:set_volume(v) end)
    end
end

-- ---------- 设置持久化 ----------
function TTS_CN:settings_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        local dir = DataStorage:getDataDir() .. "/settings"
        self:mkdir(dir)
        return dir .. "/tts_cn.lua"
    end
    return "/tmp/tts_cn.lua"
end

function TTS_CN:mkdir(dir)
    pcall(function() os.execute('mkdir -p "' .. dir .. '" >/dev/null 2>&1') end)
    return true
end

function TTS_CN:load_settings()
    local path = self:settings_path()
    local ok, f = pcall(loadfile, path)
    local s
    if ok and f then
        ok, s = pcall(f)
    end
    if not ok or type(s) ~= "table" then s = {} end
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    -- 一次性迁移：若旧设置仍是占位地址，替换为本设备实测热点地址
    if s.http_url and s.http_url:find("192.168.1.100") then
        s.http_url = DEFAULTS.http_url
    end
    -- v1.68：edge-tts 输出偏弱，旧默认 100% 偏小。若用户从未主动调过音量（仍是旧默认 100），
    -- 一次性提到 180%，避免 Kindle 上因软键盘调不动而长期被困在小声（如需微调可在设置→音量改）。
    if type(s.volume) == "number" and s.volume == 100 then
        s.volume = 180
    end
    return s
end

function TTS_CN:save_settings()
    local path = self:settings_path()
    local f, err = io.open(path, "w")
    if not f then return end
    f:write("return {\n")
    for k, v in pairs(self.settings) do
        local vs
        if type(v) == "string" then vs = string.format("%q", v)
        elseif type(v) == "number" then vs = tostring(v)
        elseif type(v) == "boolean" then vs = v and "true" or "false"
        else vs = "nil" end
        f:write(string.format("  [%q] = %s,\n", k, vs))
    end
    f:write("}\n")
    f:close()
end

function TTS_CN:show_msg(msg, timeout)
    pcall(function()
        UIManager:show(InfoMessage:new{ text = msg, timeout = timeout })
    end)
end

-- v1.55：中继连不上时，给出明确、可见的提示（弹窗 + 整页文本层），
-- 不再静默啃书、也不再让用户「不知道发生了什么」。
function TTS_CN:show_relay_error()
    local err = ""
    pcall(function()
        if self.engine and self.engine.last_err then
            err = "\n\n最近一次错误：\n" .. tostring(self.engine.last_err)
        end
    end)
    self:show_msg("⚠ 中继连不上，已停止朗读" .. err, 5)
    local tip = "⚠ 中继未连接，已停止\n\n推荐通路（本设备最稳）：手机局域网 HTTP 中继\n"
        .. "1. 手机和 Kindle 连同一个 WiFi（都在 192.168.x.x 这种局域网）\n"
        .. "2. 手机上运行：python tts_relay_android.py（或 bash relay.sh start）\n"
        .. "3. 设置 → 在线接口地址 填（用手机在该 WiFi 下的真实 IP）：\n"
        .. "   http://<手机IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}\n\n"
        .. "注意：本设备对云端 HTTPS 域名（onrender 等）有 DNS/TLS 限制，\n"
        .. "      走云端会「飞快结束 / 取不到音频」，请用上面的局域网 IP 方式。\n\n"
        .. "（按 Back 退出朗读，修好中继后重新「开始朗读」）"
    self:show_page_widget(self.cur_page or 1, tip)
end

-- v1.63：单次连通性自测，立即在屏上显示「通/不通 + 具体原因」，
-- 不必等连挂 3 句触发看门狗，也不必翻日志。
-- v1.66：先做裸 TCP 探测——网络层不通时直接给出原因，不再浪费时间走 HTTP 层。
function TTS_CN:test_relay()
    local url = self.settings.http_url or ""
    if url == "" then
        self:show_msg("请先在设置里填写「在线接口地址/中继地址」，再测试连通性", 4)
        return
    end
    -- 引擎是懒加载的（仅在「开始朗读」时才创建），但测试连通性是纯网络操作，
    -- 不依赖音频后端；故若引擎尚未创建，自行构造一个轻量 TTSengine 实例（audio=nil）
    -- 来探测，避免误报「引擎未加载」。注意：只用于网络探测，不写入 self.engine，
    -- 以免让后续「开始朗读」误以为音频后端已就绪。
    local eng = self.engine
    if not eng then
        if not TTSengine then
            self:show_msg("网络模块未加载，无法测试连通性", 3); return
        end
        eng = TTSengine:new(nil, self.settings or self:load_settings())
    end
    local host = url:match("^https?://([^:/]+)")
    local port = tonumber((url:match(":(%d+)"))) or (url:match("^https") and 443 or 5000)
    -- 第 1 步：网络层（裸 TCP）
    if host and not url:match("^https") then
        local tok, terr = eng:tcp_probe(host, port, 4)
        if not tok then
            self:show_msg("❌ 网络不通：" .. host .. ":" .. port .. "\n原因=" .. tostring(terr)
                .. "\n\n含义：\n· timeout → Kindle与手机不在同一WiFi，或路由器开了AP隔离（开手机热点绕开）\n"
                .. "· connection refused → 中继没在跑（回Termux重跑 python tts_relay_android.py &）\n"
                .. "· no route → 不同网段/WiFi没连上", 12)
            return
        end
    end
    -- 第 2 步：网络通，测 HTTP 层（完整取文）
    local body, code = eng:fetch("连接测试")
    local err = eng.last_err or ""
    if body and type(body) == "string" and #body > 100 and body:find("RIFF", 1, true) then
        self:show_msg("✅ 中继连通，收到 " .. #body .. " 字节音频", 4)
    else
        self:show_msg("❌ TCP可达但取文失败\n地址=" .. url
            .. "\n原因=" .. tostring(code) .. "\n" .. tostring(err), 10)
    end
end

-- ---------- 主菜单注册 ----------
-- 阅读器菜单与书架（文件管理器）菜单都会调用本方法。
-- sorting_hint = "more_tools" 把项挂到「更多工具」分组，确保可见。
function TTS_CN:addToMainMenu(menu_items)
    local has_doc = function() return self.ui and self.ui.document ~= nil end

    local function open_settings()
        if ConfigDialog and ConfigDialog.show then
            ConfigDialog:show(self)
        else
            self:show_msg("设置模块未加载", 2)
        end
    end

    -- 顶级直接按钮：打开书调出菜单就能看到，点一下即开始/停止
    menu_items.tts_cn_toggle = {
        text_func = function()
            return self.running and "停止朗读" or "开始朗读"
        end,
        sorting_hint = "more_tools",
        enabled_func = has_doc,
        callback = function() self:toggle() end,
    }
    menu_items.tts_cn = {
        text = "中文朗读",
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    return self.running and "停止朗读" or "开始朗读"
                end,
                enabled_func = has_doc,
                callback = function() self:toggle() end,
            },
            {
                text = "暂停 / 继续",
                enabled_func = function() return self.running end,
                callback = function() self:pause_tts() end,
            },
            {
                -- v1.41 语速校正：实时切换，下一句生效。默认关 = 干净但慢一倍（v1.31 行为）；
                -- 开 = 内容预降 8000Hz → 原速 + 音调正常（电话音质）。若开启后出现异常，切回即可。
                text_func = function()
                    return "语速校正(原速): " .. ((self.settings.speed_fix) and "开" or "关(慢一倍)")
                end,
                callback = function()
                    self.settings.speed_fix = not self.settings.speed_fix
                    self:save_settings()
                    if not self.audio then self:ensure_engine() end
                    if self.audio and self.audio.set_speed_fix then
                        pcall(function() self.audio:set_speed_fix(self.settings.speed_fix) end)
                    end
                    pcall(function()
                        local Logger = require("logger")
                        if Logger and Logger.info then
                            Logger.info("[tts_cn] 语速校正切换为 " .. tostring(self.settings.speed_fix)
                                .. "（下一句起生效：开=原速/关=慢一倍）")
                        end
                    end)
                    self:show_msg("语速校正已" .. (self.settings.speed_fix
                        and "开启（下一句起原速）" or "关闭（下一句起慢一倍）"), 2.5)
                end,
            },
            {
                text = "设置",
                callback = open_settings,
            },
            {
                text = "音频诊断(440Hz测试音)",
                callback = function()
                    -- v1.44：self.audio 是懒加载的（仅开始朗读时创建），点诊断前若没读过书会是 nil，
                    -- 故先 ensure_engine 确保后端就绪，避免误报"音频后端未加载"。
                    if not self.audio then self:ensure_engine() end
                    if self.audio and self.audio.diagnostic_tone then
                        self.audio:diagnostic_tone()
                        self:show_msg("已播放 440Hz 测试音，请听是【干净蜂鸣】还是【噪声】", 2.5)
                    else
                        self:show_msg("音频后端未加载", 2)
                    end
                end,
            },
            {
                text_func = function()
                    return "当前后端：" .. ((self.settings.backend == "http") and "在线流式" or "本地 espeak")
                end,
                callback = open_settings,
            },
        },
    }
end

-- ---------- 控制 ----------

-- 自动修正中继地址：v1.61 起彻底改为「只读诊断」，一律不再改写 http_url。
-- 原因：本设备（Kindle 3 / MiuRead）对云端 HTTPS 域名存在 DNS/TLS 握手限制，
-- 且历史「自动切网关 / 自动恢复云端」会把配置永久污染成连不上的地址。
-- 唯一稳定通路是「手机局域网 IP（http://手机IP:5000）」——字面量 IP 直连，
-- 不经过 DNS 解析，正好绕开本设备的 DNS/TLS 死穴。地址完全由用户掌控。
function TTS_CN:auto_fix_relay_host()
    if self.settings.backend ~= "http" then return end
    local url = self.settings.http_url or ""
    local host = url:match("^https?://([^:/]+)")
    if not host or host == "" then
        -- 完全没地址：直接套用局域网默认
        if url ~= DEFAULTS.http_url then
            self.settings.http_url = DEFAULTS.http_url
            self:save_settings()
            log_err("auto_fix_relay_host: 未填地址，已套用局域网默认 " .. DEFAULTS.http_url)
        end
        return
    end
    -- v1.67 关键修正：只有 https:// 才自动切回局域网默认。
    -- 原因：K3 的 TLS 栈坏，任何 https 都连不上，必须切；但 http:// 的域名
    -- （例如 PythonAnywhere 纯 HTTP 云端）是 K3【能用的合法配置】，绝不能被改掉——
    -- v1.63 曾把一切域名都当云端处理，会把云端版地址冲回局域网 IP。
    if url:match("^https://") then
        if url ~= DEFAULTS.http_url then
            self.settings.http_url = DEFAULTS.http_url
            self:save_settings()
            log_err("auto_fix_relay_host: https 在本设备不可用(TLS栈坏)，"
                .. "已切回默认 " .. DEFAULTS.http_url)
        end
        return
    end
    -- http:// ：无论是局域网 IP 还是云端域名，都尊重用户配置，只探测可达性
    local port = tonumber((url:match(":(%d+)")) or "") or 5000
    local ok = false
    pcall(function()
        local sok, socket = pcall(require, "socket")
        if not sok or not socket then return end
        local c = socket.tcp()
        if not c then return end
        c:settimeout(0.8)
        local r = c:connect(host, port)
        c:close()
        if r == 1 then ok = true end
    end)
    log_err("auto_fix_relay_host: 当前中继 " .. host .. ":" .. port
        .. (ok and " 可达" or " 不通 —— 请确认手机已运行 tts_relay_android.py 且与 Kindle 同一 WiFi"))
end

function TTS_CN:toggle()
    if self.running then self:stop_tts() else self:start_tts() end
end

function TTS_CN:start_tts()
    self:safe_step("start_tts", function() return self:_start_tts() end)
end

function TTS_CN:_start_tts()
    if self.running then return end
    if not self.ui or not self.ui.document then
        self:show_msg("请先打开一本书", 2)
        return
    end
    -- 每次开始朗读都打版本横幅 + 中继地址 + 引擎版本：
    -- 日志常被截断，init 行会丢；这里打的路标一定出现在朗读会话开头，
    -- 从此无需再靠现象猜测「设备到底跑的是哪一版」。
    pcall(function()
        local sok, sk = pcall(require, "socket")
        log_err(string.format("start_tts ===>[main v%s][engine v%s] relay=%s core_socket.tcp=%s 语速校正=%s",
            PLUGIN_VERSION,
            tostring(TTSengine and TTSengine.version or "未加载"),
            tostring((self.settings and self.settings.http_url) or "?"):match("^(https?://[^/]+)") or "?",
            (sok and sk and sk.tcp) and "有" or "无",
            tostring(self.settings and self.settings.speed_fix or false)))
    end)

    -- 清理历史临时 wav：旧版本从不在播后删除，导致 /tmp(tmpfs) 被塞满，
    -- 表现为一切看似正常但文件写成 0 字节、完全没声音。这里开局先扫干净。
    pcall(function()
        os.execute('rm -f /tmp/tts_cn_*.wav /var/tmp/tts_cn_*.wav >/dev/null 2>&1')
        local p = io.popen("df -k /tmp 2>/dev/null | tail -1")
        if p then
            local line = p:read("*a")
            p:close()
            log_err("磁盘诊断(/tmp): " .. tostring(line):gsub("%s+", " "))
        end
    end)

    self:auto_fix_relay_host()  -- 手机热点 IP 常变：配置地址不通时自动切到网关（即手机）
    if not self:ensure_engine() then return end
    -- 本地后端需要 espeak；在线流式后端不需要
    if self.settings.backend ~= "http" and self.audio and not self.audio:has_espeak() then
        self:show_msg("未检测到 espeak 语音引擎，无法朗读。请安装 espeak，或在设置里切换为「在线流式」后端。", 4)
        log_err("start_tts: espeak 未安装，已停止")
        return
    end
    self.running = true
    self.stop = false
    self.paused = false
    self.sentences = nil
    self.sent_idx = 0
    self.cur_page = nil
    self.fail_streak = 0
    self:read_next()
    self:show_msg("开始朗读", 1.5)
end

function TTS_CN:stop_tts()
    self.stop = true
    self.running = false
    self.paused = false
    if self.engine then pcall(function() self.engine:stop() end) end
    if self.audio then pcall(function() self.audio:close_alsa() end) end  -- 释放复用的 ALSA 设备
    self:clear_highlight()
    self:close_page_widget()
    self:show_msg("已停止", 1.5)
end

function TTS_CN:pause_tts()
    if not self.running then return end
    -- v1.74：防抖，避免事件同时被屏显层与插件两层派发导致「连翻两次=不生效」
    local c = os.clock()
    if self._last_pause and (c - self._last_pause) < 0.25 then return end
    self._last_pause = c
    -- v1.72：先探一下「暂停时是否正播到半句」——若是，恢复时重读这句，不再丢半句
    local was_playing = false
    if self.audio then pcall(function() was_playing = self.audio:is_playing() end) end
    self.paused = not self.paused
    if self.paused then
        self._redo_current = was_playing
        if self.engine then pcall(function() self.engine:stop() end) end
    else
        if self._redo_current and self.sent_idx > 0 then
            self.sent_idx = self.sent_idx - 1
        end
        self._redo_current = false
    end
    self:show_msg(self.paused and "已暂停" or "继续朗读", 1.5)
end

function TTS_CN:finish()
    self.running = false
    self:clear_highlight()
    self:close_page_widget()
    if self.audio then pcall(function() self.audio:close_alsa() end) end  -- 释放复用的 ALSA 设备
    self:show_msg("朗读结束", 2)
end

-- 注意：必须写成 TTS_CN 的【方法】而非模块级 local 函数。
-- 早期写成 `local function safe_step(...)` 且定义在 start_tts 之后，Lua 会把
-- start_tts 里的引用编译成全局查找（local 在引用点之后声明，不在作用域内），
-- 运行时 safe_step 为 nil → "attempt to call a nil value" 反而立刻崩。改成方法调用无此问题。
function TTS_CN:safe_step(name, fn)
    local ok, err = pcall(fn)
    if ok then
        -- 成功一次就把该步骤的连续失败计数清零，避免偶发一次错误就判死
        if self._err_cnt then self._err_cnt[name] = 0 end
        return
    end
    self._err_cnt = self._err_cnt or {}
    local n = (self._err_cnt[name] or 0) + 1
    self._err_cnt[name] = n
    log_err(name .. " 异常已拦截（KOReader 不会崩）第 " .. n .. " 次: " .. tostring(err))
    -- v1.33：不再一遇异常就把整条朗读链杀掉（老行为表现为"讲几句后彻底没动静、也不报错了"）。
    -- 先自动重试几步，实在不行才收尾，并把原因明确提示出来。
    if n <= 3 and self.running and not self.stop then
        UIManager:scheduleIn(0.6, function()
            if not self.running or self.stop then return end
            if name == "read_next" then self:read_next()
            elseif name == "read_sentences" then self:read_sentences()
            elseif name == "start_tts" then self:start_tts() end
        end)
        return
    end
    self.running = false
    self.stop = true
    self:show_msg("朗读中断：" .. name .. " 连续出错，详见 crash.log", 3)
    pcall(function() self:finish() end)
end

-- ---------- 朗读循环（事件驱动） ----------
function TTS_CN:read_next()
    self:safe_step("read_next", function() return self:_read_next() end)
end

function TTS_CN:_read_next()
    if not self.running or self.stop then
        self.running = false
        return
    end
    if self.paused then
        UIManager:scheduleIn(0.3, function() self:read_next() end)
        return
    end
    -- 当前页的句子还没读完：继续逐句朗读
    if self.sentences and self.sent_idx < #self.sentences then
        self:read_sentences()
        return
    end
    -- 需要新的一页：翻页是异步的（MiuRead 重绘需要时间），翻完再取文
    self:ensure_page(function(page)
        if not page then
            log_err("read_next: 无更多页，结束（页 " .. tostring(self.cur_page) .. "）")
            self:show_msg("朗读结束", 2)
            self:finish()
            return
        end
        local raw = self:page_text(page)
        if not raw then
            self:show_msg("取不到文本，无法朗读", 2)
            self:finish()
            return
        end
        local body = self:strip_leading_title(raw)
        if #body == 0 then body = raw end
        -- v1.80：文本级清除文档编码残留（如 %97、%9C）。
        -- v1.79 用 %d+（十进制）只能清「%数字」，但 %9C 的「C」是十六进制字母，被漏掉，
        -- 仍被 edge-tts 读成「百分之九 c」之类的噪声。这里改用十六进制模式
        -- %[0-9A-Fa-f][0-9A-Fa-f]?[...]（1~4 位 hex），与 normalize_text 的清洗规则一致，
        -- 覆盖 %9C / %97 / %E2 等所有「百分号 + 十六进制」残留。真实文本里偶见的「50%」
        -- 去掉 % 仅损百分号，远小于乱码干扰。
        local cleaned = body:gsub("%%[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?", "")
        if #cleaned > 0 then body = cleaned end
        -- v1.75：字幕优先用「高亮当前句」（标准 KOReader 翻页活、高亮可见且不抢焦点，
        -- P 键也不会被全屏层吃掉）。自包含全屏屏显层仅在「高亮不可用」时兜底。
        if self.highlight_disabled then
            self:show_page_widget(page, body)
        end
        if not (Segmenter and Segmenter.split) then
            self:show_msg("断句模块未加载，无法朗读", 2)
            self:finish()
            return
        end
        self.sentences = Segmenter.split(body, self.settings.max_len or 80)
        self.sent_idx = 0
        if #self.sentences == 0 then
            log_err("read_next: 断句为空（页 " .. tostring(page)
                .. "），文本前80字=[" .. string.sub(body, 1, 80) .. "]")
            self:show_msg("本页无可读文本", 2)
            self:finish()
            return
        end
        self:read_sentences()
    end)
end

-- 逐句朗读：每句播放完再读下一句（无声音时也会按节奏推进，翻页由 read_next 异步驱动）
function TTS_CN:read_sentences()
    self:safe_step("read_sentences", function() return self:_read_sentences() end)
end

function TTS_CN:_read_sentences()
    if not self.running or self.stop then
        self.running = false
        return
    end
    if self.paused then
        UIManager:scheduleIn(0.3, function() self:read_sentences() end)
        return
    end
    self.sent_idx = self.sent_idx + 1
    local s = self.sentences[self.sent_idx]
    if not s then
        -- 本页句子读完，进入下一页（翻页 + 取文在 read_next 里异步处理）
        self:read_next()
        return
    end
    -- v1.77：跳过噪声碎句。
    --   原 v1.52 只跳「纯标点」；但文档里混进的「%97」这类编码残留含数字，没被跳过，
    --   被 edge-tts 读成「百分之九十七」噪声（句间尤为明显）。这里额外跳「整句就是 %+数字」的孤立串：
    --   去掉 %、数字、空白、点、连字符后若为空且原句含 %，则跳过。
    --   真实文本里的「50%」处在完整句中不会被单独切出，不受影响。
    local s_clean = s:gsub("[%%%d%s%.%-]", "")
    if not s:match("[%w一-鿿]") or (s:find("%%") and #s_clean == 0) then
        log_err("read_sentences: 跳过噪声碎句（" .. #s .. "字）: " .. s:sub(1, 40))
        UIManager:scheduleIn(0.05, function() self:read_sentences() end)
        return
    end
    self:highlight(s)
    if self.engine then
        -- v1.72：播放当前句的同时，分片预取下一句音频；下一句开播时零等待，
        -- 彻底消除「每句开播前同步取文冻结 UI 1-3 秒」的翻页卡顿。
        local nxt = self.sentences[self.sent_idx + 1]
        if nxt and nxt:match("[%w一-鿿]") then
            self.engine:start_prefetch(nxt)
        end
        self.engine:speak(s, function(ok)
            -- v1.55：连续失败看门狗。中继断了不该闷头啃完整本书，
            -- 连挂 3 句（约 9 次取文）即判定中继不可用，停止并弹明确提示。
            -- v1.68：用户暂停/停止导致的「未播完」不算失败，绝不计入看门狗，
            -- 否则暂停 3 次会被误判成「中继不可用」而强制终止朗读。
            if ok == false and not (self.paused or self.stop) then
                self.fail_streak = (self.fail_streak or 0) + 1
                if self.fail_streak >= 3 then
                    log_err("连续 " .. self.fail_streak
                        .. " 句取文失败，判定中继不可用，停止朗读")
                    self:show_relay_error()
                    self:finish()
                    return
                end
            else
                self.fail_streak = 0
            end
            -- v1.78：句间补 2s 间隔。v1.73 引入预取后句间变 0s，ALSA 设备连续重开触发状态竞态
            -- 导致「句首被吞」；v1.72（同步取文、句间 2-4s）不吞就是因为间隔大。
            -- 0.4s 实测仍吞（不够设备 settle），拉到 2s 与 v1.72 持平，先保「不吞字」；
            -- 取文仍走预取（0s 不卡），这 2s 是纯静音间隔，不是 UI 冻结。
            UIManager:scheduleIn(2, function() self:read_sentences() end)
        end)
    else
        UIManager:scheduleIn(0.1, function() self:read_sentences() end)
    end
end

-- 异步取下一页：若当前页句子已用完，先翻到下一页，等 MiuRead 完成重绘后再回调页码
function TTS_CN:ensure_page(cb)
    local total = self:get_page_count()
    if self.cur_page == nil then
        -- 起始页以「屏幕可见页」为准，避免 getCurrentPage 返回打开书时的旧页导致后端与屏幕错位
        self.cur_page = self:view_page() or self:get_current_page() or 1
        if cb then cb(self.cur_page) end
        return
    end
    local cur = self.cur_page
    if total and cur >= total then
        log_err("ensure_page: 已到末页（页 " .. cur .. "/" .. total .. "）")
        if cb then cb(nil) end
        return
    end
    self:goto_next_page(cur + 1, function(ok)
        if not ok then
            if cb then cb(nil) end
            return
        end
        -- 诊断：文档页码计数器已推进到 self.cur_page，屏显层(show_page_widget)会渲染该页文本
        log_err("ensure_page: 已推进到文档页 " .. tostring(self.cur_page)
            .. "（屏显层渲染中，阅读器可见页 view=" .. tostring(self:view_page()) .. "）")
        if cb then cb(self.cur_page) end
    end)
end

-- ---------- 取文 / 翻页 ----------
function TTS_CN:get_current_page()
    local ok, p = pcall(function()
        if self.ui and self.ui.getCurrentPage then return self.ui:getCurrentPage() end
        if self.ui and self.ui.document and self.ui.document.getCurrentPage then
            return self.ui.document:getCurrentPage()
        end
        return nil
    end)
    if ok and type(p) == "number" and p > 0 then return p end
    return 1
end

-- 读取 view 真实渲染页：view.state.page 是屏幕当前显示的真相，
-- 比 getCurrentPage() 可靠（MiuRead 里 getCurrentPage 常返回打开书时的旧页，不随翻页更新）
function TTS_CN:view_page()
    if self.ui and self.ui.view and self.ui.view.state and self.ui.view.state.page then
        return self.ui.view.state.page
    end
    return nil
end

-- v1.82：清洗无效 UTF-8 字节（如取文混入的孤立 0x9C 等断字节），只保留合法 UTF-8 序列。
-- 背景：KOReader 取文（尤其 getTextBoxes 多框拼接）偶把多字节字符（如 " = E2 80 9C）截断，
-- 只留下尾字节 0x9C；urlencode 会把 0x9C 编码成 %9C，relay 端就听到「百分之九 c」。
-- 逐字节走 UTF-8：ASCII(<0x80) 保留；合法 lead(0xC2-0xDF / 0xE0-0xEF / 0xF0-0xF4) 带上对应数量
-- 的 continuation(0x80-0xBF) 保留；其余字节（孤立 continuation、非法 lead）一律丢弃。
-- 注意：合法中文（如 注=E6 B3 A8）是完整 3 字节序列，会被原样保留，不会误删。
local function sanitize_utf8(s)
    if type(s) ~= "string" or s == "" then return s end
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = string.byte(s, i)
        if b < 0x80 then
            out[#out + 1] = string.char(b); i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local c1 = string.byte(s, i + 1)
            if c1 and c1 >= 0x80 and c1 <= 0xBF then
                out[#out + 1] = string.sub(s, i, i + 1); i = i + 2
            else
                i = i + 1
            end
        elseif b >= 0xE0 and b <= 0xEF then
            local c1 = string.byte(s, i + 1); local c2 = string.byte(s, i + 2)
            if c1 and c2 and c1 >= 0x80 and c1 <= 0xBF and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = string.sub(s, i, i + 2); i = i + 3
            else
                i = i + 1
            end
        elseif b >= 0xF0 and b <= 0xF4 then
            local c1 = string.byte(s, i + 1); local c2 = string.byte(s, i + 2); local c3 = string.byte(s, i + 3)
            if c1 and c2 and c3 and c1 >= 0x80 and c1 <= 0xBF and c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF then
                out[#out + 1] = string.sub(s, i, i + 3); i = i + 4
            else
                i = i + 1
            end
        else
            i = i + 1  -- 孤立 continuation(0x80-0xBF) 或非法 lead(0xC0/0xC1/0xF5-0xFF)：丢弃
        end
    end
    return table.concat(out)
end

function TTS_CN:normalize_text(v)
    if v == nil or v == "" then return nil end
    if type(v) == "table" then
        local parts = {}
        for _, item in ipairs(v) do
            if type(item) == "string" then parts[#parts + 1] = item end
        end
        v = table.concat(parts, "\n")
    end
    if type(v) ~= "string" then return nil end
    if v == "" then return nil end
    v = v:gsub("[\n\r]+", " ")
    v = v:gsub("%s+", " ")
    -- v1.82：先丢弃孤立断字节（如 0x9C），再处理 %XX 字面残留与 HTML 实体，避免 urlencode 把坏字节编成 %9C
    v = sanitize_utf8(v)
    -- v1.49 文本清洗：去掉取文混入的噪声字符，避免 TTS 把乱码逐字读成「百分号九 c」之类，
    -- 且这类字符常出现在翻页取文的新页首，表现为「翻页时多一句 %9c 噪声」。
    --   %XX          百分号编码残留（如 %9c），2~4 位 hex 一并清掉
    --   %uXXXX       unicode 转义残留
    --   ％            全角百分号（中文排版常见，作噪声时清掉）
    --   &amp; &lt;    HTML 命名实体          &#156; &#x9c; 数字/十六进制实体
    --   控制字符       \0 与 \1-\x1f（\t\n\r 已在上面压缩，此处只去其余不可见字符）
    v = v:gsub("%%[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?", "")
    v = v:gsub("%%[uU][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]", "")
    v = v:gsub("％", "")   -- 全角百分号
    v = v:gsub("&[a-zA-Z][a-zA-Z0-9]*;", "")
    v = v:gsub("&#[xX]?[0-9A-Fa-f]+;", "")
    v = v:gsub("[%z\1-\8\11\12\14-\31]", "")
    v = v:gsub("^%s+", "")
    v = v:gsub("%s+$", "")
    v = v:gsub("%s+", " ")
    -- v1.52 诊断：清洗后仍残留 %（说明源文本有未覆盖的百分号形态），把上下文打出来便于定位
    local bad = v:find("%%")
    if bad then
        local a = math.max(1, bad - 12)
        local b = math.min(#v, bad + 12)
        log_err("normalize_text 警告：清洗后仍有 % 残留，上下文=["
            .. v:sub(a, b):gsub("%%", "%%%%") .. "] 全串长度=" .. #v)
    end
    if v == "" then return nil end   -- 整页都是噪声时被清洗为空，跳过避免空读
    return v
end

-- 从 cre 文档的 getTextBoxes 返回里提取文字：兼容多种 box 结构
function TTS_CN:extract_box_text(boxes)
    if type(boxes) ~= "table" then return nil end
    local parts = {}
    for _, b in ipairs(boxes) do
        if type(b) == "string" then
            parts[#parts + 1] = b
        elseif type(b) == "table" then
            local t = b.text or b.txt or b.word or b.s or b[1]
            if type(t) == "string" and t ~= "" then
                parts[#parts + 1] = t
            elseif type(b) == "table" and #b > 0 then
                -- 嵌套：递归取第一个字符串
                local sub = self:extract_box_text(b)
                if sub then parts[#parts + 1] = sub end
            end
        end
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

-- 尝试多种取文方案，适配不同文档后端（epub/cre 与微信读书/MiuRead 自定义后端）
function TTS_CN:page_text(page)
    local doc = self.ui and self.ui.document
    if not doc then
        log_err("page_text: self.ui.document 不存在")
        return nil
    end
    local candidates = {
        { name = "getPageText(page)",            fn = function() return doc:getPageText(page) end },
        { name = "getPageText(page, true)",      fn = function() return doc:getPageText(page, true) end },
        { name = "getPageText(page, page)",      fn = function() return doc:getPageText(page, page) end },
        { name = "_document:getPageText(page)",  fn = function() return doc._document and doc._document:getPageText(page) end },
    }
    local errs = {}
    for _, c in ipairs(candidates) do
        if doc[c.name:match("^%w+")] then  -- 仅当该方法存在时才试（避免 "attempt to call a nil value" 噪声）
            local ok, text = pcall(c.fn)
            if ok then
                local norm = self:normalize_text(text)
                if norm then
                    log_err("page_text: 取文成功，方法=" .. c.name)
                    return norm
                end
            else
                errs[#errs + 1] = c.name .. " -> " .. tostring(text)
            end
        end
    end
    -- cre 后端专用：getTextBoxes 返回页面文字框，逐框提取拼接
    if doc.getTextBoxes then
        local ok, boxes = pcall(function() return doc:getTextBoxes(page) end)
        if ok and boxes ~= nil then
            -- 记录返回结构，便于字段名不符时精确定位
            local n = type(boxes) == "table" and #boxes or 0
            local sample = ""
            if type(boxes) == "table" and boxes[1] ~= nil then
                local function brief(v, d)
                    d = d or 0
                    if d > 2 then return "..." end
                    if type(v) == "string" then return string.format("%q", v:sub(1, 20)) end
                    if type(v) == "table" then
                        local ks = {}
                        for k, _ in pairs(v) do ks[#ks + 1] = tostring(k) end
                        return "{" .. table.concat(ks, ",") .. "}"
                    end
                    return type(v)
                end
                sample = " 首框=" .. brief(boxes[1])
            end
            log_err("page_text: getTextBoxes 返回 type=" .. type(boxes) .. " n=" .. n .. sample)
            local txt = self:extract_box_text(boxes)
            if txt then
                -- v1.82 修复：getTextBoxes 路径此前「直接 return txt」没做 normalize_text，
                -- 导致取文混入的孤立断字节（如 " 的尾字节 0x9C）未被清洗，
                -- 经 urlencode 变成 %9C 被 relay 读成「百分之九 c」。这里与其它路径一致先 normalize。
                local norm = self:normalize_text(txt)
                if norm then
                    log_err("page_text: 取文成功，方法=getTextBoxes")
                    return norm
                end
            end
        else
            errs[#errs + 1] = "getTextBoxes(page) -> " .. tostring(boxes)
        end
    end
    -- cre 后端最强方案：范围取文。getPageXPointer(page) 只指向页首元素（常是章节标题），
    -- 单点取文只能拿到标题；用 getTextFromXPointers(页首, 下一页页首) 才能取整页正文。
    if doc.getPageXPointer and doc.getTextFromXPointers then
        local ok_a, xp_a = pcall(function() return doc:getPageXPointer(page) end)
        local ok_b, xp_b = pcall(function() return doc:getPageXPointer(page + 1) end)
        if ok_a and xp_a and ok_b and xp_b then
            local ok_t, raw = pcall(function() return doc:getTextFromXPointers(xp_a, xp_b) end)
            if ok_t and type(raw) == "string" then
                raw = raw:gsub("<[^>]+>", "")
                local norm = self:normalize_text(raw)
                log_err("page_text: 范围取文 len=" .. (norm and #norm or 0)
                        .. " 预览=[" .. (norm and norm:sub(1, 24) or "") .. "]")
                if norm and #norm > 0 then
                    log_err("page_text: 取文成功，方法=getTextFromXPointers(范围)")
                    return norm
                end
            else
                log_err("page_text: 范围取文失败 type=" .. type(raw))
            end
        else
            log_err("page_text: getPageXPointer(page/page+1) 抛错 " .. tostring(xp_a) .. " / " .. tostring(xp_b))
        end
    end
    -- cre 后端专用：优先试"整页文本 xpointer"与"当前屏幕 xpointer"（语义比页首更完整）
    if doc.getTextFromXPointer then
        local xp_candidates = {}
        if doc.getPageTextXPointer then
            xp_candidates[#xp_candidates + 1] = { name = "getPageTextXPointer", fn = function() return doc:getPageTextXPointer(page) end }
        end
        if doc.getScreenXPointer then
            xp_candidates[#xp_candidates + 1] = { name = "getScreenXPointer", fn = function() return doc:getScreenXPointer() end }
        end
        for _, c in ipairs(xp_candidates) do
            local ok_xp, xp = pcall(c.fn)
            if ok_xp and xp then
                local ok_t, raw = pcall(function() return doc:getTextFromXPointer(xp) end)
                if ok_t and type(raw) == "string" then
                    raw = raw:gsub("<[^>]+>", "")
                    local norm = self:normalize_text(raw)
                    log_err("page_text: " .. c.name .. " 取文 len=" .. (norm and #norm or 0)
                            .. " 预览=[" .. (norm and norm:sub(1, 24) or "") .. "]")
                    if norm then
                        log_err("page_text: 取文成功，方法=" .. c.name)
                        return norm
                    end
                else
                    log_err("page_text: " .. c.name .. " -> getTextFromXPointer 失败 type=" .. type(raw))
                end
            else
                log_err("page_text: " .. c.name .. " 抛错 " .. tostring(xp))
            end
        end
    end
    -- cre 后端：用页面 xpointer 取该页纯文本（不依赖 openPage）
    if doc.getPageXPointer and doc.getTextFromXPointer then
        local ok_xp, xp = pcall(function() return doc:getPageXPointer(page) end)
        if ok_xp and xp then
            local ok_t, raw = pcall(function() return doc:getTextFromXPointer(xp) end)
            if ok_t and type(raw) == "string" then
                raw = raw:gsub("<[^>]+>", "")  -- 去掉可能的 HTML 标签
                local norm = self:normalize_text(raw)
                log_err("page_text: getPageXPointer 取文 len=" .. (norm and #norm or 0)
                        .. " 预览=[" .. (norm and norm:sub(1, 24) or "") .. "]")
                if norm then
                    log_err("page_text: 取文成功，方法=getTextFromXPointer")
                    return norm
                end
            end
        else
            errs[#errs + 1] = "getPageXPointer(page) -> " .. tostring(xp)
        end
    end
    -- 诊断探针：记录其它文本接口的返回类型，便于精确定位（下一轮若上述均失败则用）
    for _, nm in ipairs({ "getXPointer", "getDocumentFileContent" }) do
        if doc[nm] then
            local ok, r = pcall(function() return doc[nm](doc) end)
            local info = ok and (type(r) .. (type(r) == "string" and (" len=" .. #r) or ""))
                           or ("ERR " .. tostring(r))
            log_err("probe: " .. nm .. "() -> " .. info)
        end
    end
    -- 全部失败：列出 document 真实支持的方法名，便于定位正确取文 API
    log_err("page_text: 页 " .. tostring(page) .. " 所有取文方法均失败；document 方法=[" .. list_methods(doc) .. "]")
    if doc._document ~= nil then
        log_err("page_text: doc._document 存在；_document 方法=[" .. list_methods(doc._document) .. "]")
    else
        log_err("page_text: doc._document 不存在")
    end
    if #errs > 0 then
        log_err("page_text: 失败明细=[" .. table.concat(errs, " | ") .. "]")
    end
    return nil
end

function TTS_CN:get_page_count()
    local doc = self.ui and self.ui.document
    if not doc or not doc.getPageCount then return nil end
    local ok, n = pcall(function() return doc:getPageCount() end)
    if ok and type(n) == "number" and n > 0 then return n end
    return nil
end

-- 识别"章节标题"：目录/章首屏取文常只拿到章节名，读出来没有意义
function TTS_CN:looks_like_title(t)
    if type(t) ~= "string" then return false end
    if #t > 120 then return false end  -- 超过 120 字节(约40汉字)基本不可能是标题
    if t:match("^%s*第[0-9一二三四五六七八九十百千零两]+[章节回卷部篇]") then return true end
    if t:match("^%s*[（(]?%d+[)）]?%.?%s*%S{0,20}$") and #t < 60 then return true end
    if t:match("^%s*[目录序跋附录后记]") and #t < 24 then return true end
    return false
end

-- 剥离页首的章节标题行（"第二十四章 …"），保留正文，避免把标题当正文读、也避免整页误跳
function TTS_CN:strip_leading_title(raw)
    if type(raw) ~= "string" then return raw end
    local body = raw:gsub("^%s*第[0-9一二三四五六七八九十百千零两]+[章节回卷部篇][^\n]*\n?", "", 1)
    body = body:gsub("^%s*序[章]?[^\n]*\n?", "", 1)
    return body
end

--[[ 旧同步版 get_next_page_text 已被异步 ensure_page 取代（见 read_next / ensure_page / goto_next_page）。
     保留空壳以避免遗留调用报错。]]
function TTS_CN:get_next_page_text()
    return nil
end

-- 整屏强制重绘：翻页后主动触发，让 e-ink 屏幕刷新正文
function TTS_CN:repaint_all()
    pcall(function()
        if UIManager and UIManager.setDirty and self.ui then
            UIManager:setDirty(self.ui, "full")
        end
    end)
    pcall(function()
        if UIManager and UIManager.setDirty and self.ui and self.ui.view then
            UIManager:setDirty(self.ui.view, "full")
        end
    end)
    pcall(function()
        if UIManager and UIManager.forceRepaint then UIManager:forceRepaint() end
    end)
end

-- 翻页：MiuRead 冻结了所有 Lua 翻页通道（runtime frozen plugin），调用 onGotoNextPage /
-- handleEvent(GotoNextPage) / doc:gotoPage 都不会改变 view.state.page（日志实测 view 永远卡 257）。
-- 因此彻底放弃「驱动阅读器翻页」，改用「文档页码计数器」独立推进：
--   getTextFromXPointers(文档页码) 按文档绝对页码取文，与阅读器可见页无关，
--   屏幕则由我们的自包含文本层（show_page_widget）渲染，必然跟着走。
-- 这样绕开 MiuRead 的冻结墙，朗读进度与屏幕显示都由我们自己的计数器掌控。
function TTS_CN:goto_next_page(target, cb)
    local total = self:get_page_count()
    if total and target > total then
        log_err("goto_next_page: 目标超出末页 " .. target .. "/" .. total)
        if cb then cb(false) end
        return
    end
    -- v1.75：标准 KOReader 下直接驱动阅读器翻页，让「高亮当前句」作为字幕跟随进度。
    -- 不再只推进页码计数器——那样需要全屏屏显层接管屏幕，既抢焦点吃掉 P 键、又可能不渲染。
    -- 若 onGotoNextPage 不可用（冻结版），pcall 失败则返回 true 走旧页码计数器 + 屏显层兜底。
    local ok = pcall(function() self.ui:onGotoNextPage() end)
    if ok then
        -- 翻页是异步重绘，等一帧让 view 更新后再回读真实页码
        UIManager:scheduleIn(0.2, function()
            self.cur_page = self:view_page() or target
            if cb then cb(true) end
        end)
    else
        self.cur_page = target
        log_err("goto_next_page: onGotoNextPage 不可用，降级为页码计数器（屏显层兜底）")
        if cb then cb(true) end
    end
end

-- v1.74：把朗读控制按键（暂停/停止/开始切换）挂到屏显 widget 实例上并转发给插件自身。
-- 朗读时全屏 TextBoxWidget/ScrollTextWidget 在栈顶抢焦点，KOReader 不会把 P/S/G 键
-- 向插件冒泡；直接在屏显 widget 上声明 key_events + onXxx，焦点在此层时按键也能控朗读。
function TTS_CN:attach_read_keys(widget)
    if not widget then return end
    widget.key_events = {
        PauseTTS_CN  = { { "P" } },
        StopTTS_CN   = { { "S" } },
        ToggleTTS_CN = { { "G" } },
    }
    widget.onPauseTTS_CN  = function() self:pause_tts() end
    widget.onStopTTS_CN   = function() self:stop_tts() end
    widget.onToggleTTS_CN = function() self:toggle() end
end

-- 自包含朗读屏显：全屏文本层，显示当前正在朗读的页文本。
-- 这是绕开 MiuRead 冻结翻页的关键——屏幕内容由本层渲染，必然随朗读进度推进。
-- 渲染路径（按可用性依次回退）：
--   1) ScrollTextWidget（最理想，原生滚动文本层）
--   2) TextBoxWidget  （核心 widget，MiuRead 通常保留，自动换行/可滚）
--   3) TextWidget     （单行，取前若干字，保底可见）
--   4) Screen.fb:paintText 直接画到墨水屏（最后兜底，不依赖任何 widget 模块）
-- 全部缺失才跳过屏显（不影响出声）。
function TTS_CN:show_page_widget(page, body)
    pcall(function()
        -- 入口诊断：每次渲染都打一行，便于确认屏显到底走了哪条路径（MiuRead 环境差异极大）
        log_err(string.format("show_page_widget 入口: 页=%s 文本=%d ScrollText=%s TextBox=%s Text=%s fbobj=%s",
            tostring(page), #(body or ""),
            ScrollTextWidget and "有" or "无",
            TextBoxWidget and "有" or "无",
            TextWidget and "有" or "无",
            ((UIManager and UIManager.screen) or (Device and Device.screen) or _G.fb
                or (UIManager and UIManager.fb) or Screen) and "有" or "无"))
        if not UIManager then
            log_err("show_page_widget: UIManager 缺失，跳过屏显")
            return
        end
        -- 屏幕尺寸：优先 UIManager.screen / Device.screen / 全局 fb，MiuRead 不暴露全局 Screen，
        -- 故兜底用 Kindle 3 原生分辨率 600x800（已知设备，绝不会错）。
        local sw, sh = 600, 800
        local scrobj = (UIManager and UIManager.screen) or (Device and Device.screen)
            or _G.fb or (UIManager and UIManager.fb) or Screen
        if scrobj and scrobj.getWidth then
            sw, sh = scrobj:getWidth(), scrobj:getHeight()
        end
        if self._read_widget then
            pcall(function() UIManager:close(self._read_widget) end)
            self._read_widget = nil
        end
        local w, h = sw - 16, sh - 16
        -- v1.52：优先用 KOReader 原生 widget（TextBoxWidget/TextWidget/ScrollTextWidget）走 UIManager:show。
        -- 理由：v1.50 实测 FBInk 虽然「渲染成功」但 MiuRead 每隔 10~30s 自行刷新屏幕（日志里
        -- 的 `refreshed page=` 行）会把 framebuffer 上的 FBInk 字覆盖掉，导致用户完全看不到覆盖层。
        -- 而原生 widget 活在 MiuRead 自己的 UI 栈里，随其刷新周期自动重绘，不会被覆盖——这才是
        -- 「全屏文本层跟随翻页」真正可靠的路径。FBInk 降级为兜底。
        local widget, path_name
        if TextBoxWidget then
            widget = TextBoxWidget:new{
                text = body or "", width = w, height = h,
                scroll = true, title = "中文朗读 · 第 " .. tostring(page) .. " 页（按 Back 停止）",
            }
            path_name = "TextBoxWidget"
        elseif TextWidget then
            widget = TextWidget:new{ text = (body or ""):sub(1, 240),
                title = "中文朗读 · 第 " .. tostring(page) .. " 页" }
            path_name = "TextWidget"
        elseif ScrollTextWidget then
            widget = ScrollTextWidget:new{
                title = "中文朗读 · 第 " .. tostring(page) .. " 页（按 Back 停止）",
                text = body or "", width = w, height = h,
            }
            path_name = "ScrollTextWidget"
        end
        if widget then
            -- v1.74：朗读屏显层（TextBoxWidget 等）在栈顶抢焦点，若不处理 P/S/G 键，
            -- KOReader 可能不向插件冒泡 → 暂停/停止按键失效。直接在屏显 widget 实例上
            -- 挂 key_events + handler 转发给插件，确保焦点在屏显层时按键也能控制朗读。
            self:attach_read_keys(widget)
            local ok_show, err_show = pcall(function()
                self._read_widget = widget
                UIManager:show(widget)
            end)
            if ok_show then
                log_err("show_page_widget: 已用 " .. path_name .. " 渲染第 " .. tostring(page)
                    .. " 页（自动跟随翻页）len=" .. (#(body or "")))
                return
            end
            log_err("show_page_widget: " .. path_name .. " UIManager:show 抛错: "
                .. tostring(err_show) .. "，转 FBInk 兜底")
            self._read_widget = nil
        end
        log_err("show_page_widget: 无可用原生 widget（TextBox/Text/ScrollText 均缺失），转 FBInk")
        if self:show_page_fbink(page, body, sw, sh) then
            log_err("show_page_widget: FBInk 全屏层已渲染第 " .. tostring(page) .. " 页（自动跟随翻页）")
            return
        end
        -- 兜底：用 framebuffer 的 paintText 直接画到墨水屏（不依赖 widget 显示）
        self:show_page_fb(page, body, sw, sh)
    end)
end

-- 最后兜底：用 framebuffer 的 paintText 把当前页文本直接画到墨水屏。
-- 当原生 widget 与 FBInk 均不可用时走这里；全程 pcall 包裹，画失败也不影响出声。
-- fb 取自 UIManager.screen / Device.screen / 全局 fb / UIManager.fb（MiuRead 不暴露全局 Screen）。
function TTS_CN:show_page_fb(page, body, w, h)
    pcall(function()
        local scrobj = (UIManager and UIManager.screen) or (Device and Device.screen)
            or _G.fb or (UIManager and UIManager.fb) or Screen
        local fb = scrobj and scrobj.fb
        if not fb or not fb.paintText then
            log_err("show_page_widget: fb/paintText 不可用（scrobj=" .. (scrobj and "有" or "无")
                .. "），跳过屏显；将尝试 FBInk")
            self:show_page_fbink(page, body, w, h)
            return
        end
        -- 取一个字号合适的字体面（CJK 由系统字体覆盖）
        local face = nil
        local okf, Font = pcall(require, "ui/font")
        if okf and Font and Font.getFace then
            pcall(function() face = Font:getFace(22) end)
        end
        -- 清屏（墨水屏：0 黑 / 0xFF 白，按 Blitbuffer 约定填白底）
        pcall(function() if fb.clear then fb:clear(0xFF) else fb:fill(0xFF) end end)
        local fs = 22          -- 字号
        local lh = math.floor(fs * 1.25)  -- 行高
        local cpl = math.max(8, math.floor((w - 16) / fs))  -- 每行字符数（CJK 近似等宽）
        local x, y = 8, 10
        local txt = body or ""
        local i = 1
        while i <= #txt and y < h - lh do
            local seg = txt:sub(i, i + cpl - 1)
            pcall(function() fb:paintText(x, y, seg, face, fs) end)
            i = i + cpl
            y = y + lh
        end
        pcall(function()
            if Screen.refreshFull then Screen:refreshFull()
            elseif Screen.refresh then Screen:refresh("full", 1, 1, w, h) end
        end)
        log_err("show_page_widget: 已用 fb:paintText 渲染第 " .. tostring(page) .. " 页（cpl=" .. cpl .. "）")
    end)
end

-- FBInk 兜底：MiuRead 自带 FBInk（libfbink），是插件被冻结时最可靠的墨水屏直绘通路。
-- FBInk API 跨版本签名不一，这里逐个尝试并把结果打进日志；全程 pcall，失败不崩溃。
-- FBInk 兜底（MiuRead 自带 libfbink）：全屏直绘当前朗读页，是「全屏文本层跟随」最可靠的路径，
-- 因为它不依赖被冻结的 UIManager:show。v1.49 起提升到最优先。
-- 返回 true/false：调用方据此决定是否回退 widget 路径。
function TTS_CN:show_page_fbink(page, body, w, h)
    local ok, drawn = pcall(function()
        local ffi_ok, ffi = pcall(require, "ffi")
        if not ffi_ok then log_err("show_page_fbink: 无 ffi，放弃"); return false end
        -- 扫描已加载的 libfbink（MiuRead 已 ffi.load 过，必在 maps 里）
        local libpath
        local mf = io.open("/proc/self/maps")
        if mf then
            for line in mf:lines() do
                local p = line:match("(%S*fbink%S*.so%S*)")
                if p then libpath = p; break end
            end
            mf:close()
        end
        if not libpath then log_err("show_page_fbink: 找不到 libfbink"); return false end
        local okl, fbink = pcall(ffi.load, libpath)
        if not okl or not fbink then
            log_err("show_page_fbink: ffi.load 失败 " .. tostring(libpath)); return false
        end
        ffi.cdef[[
            int fbink_init(int fbfd);
            int fbink_init_v(void);
            int fbink_print(int fbfd, const char * string, int row, int col, unsigned int color);
            int fbink_print_v(const char * string, int row, int col, unsigned int color);
            int fbink_clear(unsigned int color);
            int fbink_cls(void);
        ]]
        local fd = -999
        pcall(function() fd = fbink.fbink_init(0) end)
        local inited = (fd >= 0)
        if not inited then
            pcall(function() fd = fbink.fbink_init(-1) end)
            inited = (fd >= 0)
        end
        if not inited then
            pcall(function() fd = fbink.fbink_init_v() end)
            inited = true; fd = -1
        end
        -- 清屏（白底）让朗读文本层盖住原书页；API 签名随版本不同，失败忽略不影响文字绘制
        pcall(function() if fbink.fbink_clear then fbink.fbink_clear(0xFF) end end)
        pcall(function() if fbink.fbink_cls then fbink.fbink_cls() end end)
        log_err("show_page_fbink: init fd=" .. tostring(fd))
        -- 逐行打印当前页纯文本（黑字 color=0；若设备约定相反则反显白字黑底，仍可辨）
        local cpl = 22
        local txt = body or ""
        local i, row = 1, 1
        while i <= #txt and row < 34 do
            local seg = txt:sub(i, i + cpl - 1)
            if fd >= 0 then
                pcall(function() fbink.fbink_print(fd, seg, row, 2, 0) end)
            else
                pcall(function() fbink.fbink_print_v(seg, row, 2, 0) end)
            end
            i = i + cpl
            row = row + 1
        end
        log_err("show_page_fbink: 已用 FBInk 全屏渲染第 " .. tostring(page) .. " 页（盖住原书页，lib=" .. libpath .. "）")
        return true
    end)
    if not ok then
        log_err("show_page_fbink: 异常 " .. tostring(drawn))
        return false
    end
    return drawn == true
end

function TTS_CN:close_page_widget()
    pcall(function()
        if self._read_widget then
            UIManager:close(self._read_widget)
            self._read_widget = nil
        end
    end)
    -- 停止朗读后清掉 FBInk 全屏文本层，让屏幕回到可操作状态（原书页在下次重绘时恢复）
    pcall(function()
        local ffi_ok, ffi = pcall(require, "ffi")
        if not ffi_ok then return end
        local libpath
        local mf = io.open("/proc/self/maps")
        if mf then
            for line in mf:lines() do
                local p = line:match("(%S*fbink%S*.so%S*)")
                if p then libpath = p; break end
            end
            mf:close()
        end
        if not libpath then return end
        local okl, fbink = pcall(ffi.load, libpath)
        if not okl or not fbink then return end
        ffi.cdef[[ int fbink_init(int fbfd); int fbink_init_v(void); int fbink_clear(unsigned int color); int fbink_cls(void); ]]
        local fd = -999
        pcall(function() fd = fbink.fbink_init(0) end)
        if fd < 0 then pcall(function() fd = fbink.fbink_init(-1) end) end
        if fd < 0 then pcall(function() fd = fbink.fbink_init_v() end); fd = -1 end
        pcall(function() if fbink.fbink_clear then fbink.fbink_clear(0xFF) end end)
        pcall(function() if fbink.fbink_cls then fbink.fbink_cls() end end)
    end)
end

-- ---------- 当前句高亮（best-effort） ----------
function TTS_CN:highlight(s)
    if self.highlight_disabled then return end
    local ok = pcall(function()
        local hl = self.ui.highlight
        if not hl or not hl.setHighlight then return end
        local page_text = self:page_text(self.cur_page) or ""
        local start = page_text:find(s, 1, true)  -- 明文查找
        if not start then return end
        local s_end = start + #s - 1
        hl:setHighlight(self.cur_page, start - 1, s_end - 1)
    end)
    if not ok then
        self.highlight_disabled = true  -- 该设备/版本不支持则永久关闭，避免反复报错
    end
end

function TTS_CN:clear_highlight()
    if self.highlight_disabled then return end
    pcall(function()
        local hl = self.ui.highlight
        if hl and hl.clearHighlight then hl:clearHighlight() end
    end)
end

return TTS_CN
