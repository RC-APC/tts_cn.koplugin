--[[
  ttsengine.lua —— 可插拔 TTS 后端管理器
  两个后端：
    * espeak：本地离线，直接朗读（调节语速/音调/音量/音色）。
    * http  ：在线流式。按句请求可配置的 TTS 接口，返回音频写入临时文件播放。
              GET 用 {text}{voice} 占位符拼 URL；POST 把 {text,voice} 以 JSON 发出。
              返回非 200 或网络不可达时自动回退到本地 espeak。

  播放采用后台子进程 + 轮询完成（见 audioplayer），因此朗读循环可以保持事件驱动，
  不阻塞 KOReader 界面（暂停/停止可被响应）。
]]

local UIManager = require("ui/uimanager")

local function log_err(s)
    pcall(function()
        local Logger = require("logger")
        if Logger and (Logger.err or Logger.error) then
            (Logger.err or Logger.error)("[tts_cn] " .. s)
        end
    end)
end

-- ttsengine 自身版本：写进探测日志与报错串，用于确认「设备实际加载的是哪一版」
-- （用户多次反馈同一报错，需排除「旧代码仍在运行」这一可能）
local ENGINE_VERSION = "1.82"

local TTSengine = {}
TTSengine.version = ENGINE_VERSION  -- 暴露给 main.lua 打印，用于确认加载的是哪一版引擎

function TTSengine:new(audio, settings)
    local o = { audio = audio, settings = settings }
    setmetatable(o, { __index = self })
    return o
end

-- RFC3986 百分比编码（按字节处理 UTF-8）
local function urlencode(s)
    return (s:gsub("([^%w%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function ext_from_ct(ct)
    ct = ct or ""
    if ct:find("wav") then return ".wav" end
    if ct:find("mpeg") or ct:find("mp3") then return ".mp3" end
    if ct:find("ogg") or ct:find("opus") then return ".ogg" end
    if ct:find("flac") then return ".flac" end
    if ct:find("webm") then return ".weba" end
    return ".wav"
end

function TTSengine:build_url(text)
    local url = self.settings.http_url or ""
    -- 替换串必须用函数返回，否则 urlencode 结果里的 %XX 会被 gsub 当成捕获组引用而崩溃
    url = url:gsub("{voice}", function() return urlencode(self.settings.voice or "zh") end)
    url = url:gsub("{text}", function() return urlencode(text) end)
    -- v1.82：强制让 voice 参数等于当前 settings.voice，无论 URL 是写死 Xiaoxiao 还是用 {voice} 占位符，
    -- 保证「音色」菜单的选择一定生效（老版本写死 Xiaoxiao 的 URL 不再覆盖用户选择，无需重存地址）。
    url = url:gsub("([?&]voice=)[^&]*", "%1" .. urlencode(self.settings.voice or "zh"))
    return url
end

-- 底层 HTTP GET：用核心 socket 自己收发，receive("*a") 一直读到服务端关闭连接为止。
-- 动机：socket.http 高层 API 在「WAV 较大 + 服务端提前断」时只读到部分数据就返回成功且不报错，
-- v1.30 实测首包恰好停在 40960(=40KiB) 边界、宣言 data_len=204270 而实收 40881，明显是被截断。
-- 自己循环读到 close 最可靠，且不依赖 Content-Length 是否诚实。
function TTSengine:raw_get(url, timeout_s)
    local oks, core = pcall(require, "socket")
    if not oks or not core or not core.tcp then return nil, "no core socket" end
    local scheme, hostport, path = url:match("^(https?)://([^/]+)(/?.*)$")
    if not scheme then return nil, "bad url" end
    local host, port = hostport:match("^([^:]+):?(%d*)$")
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    if not path or path == "" then path = "/" end
    local c, err = core.tcp()
    if not c then return nil, "tcp fail:" .. tostring(err) end
    c:settimeout(timeout_s or 10)  -- v1.65：裸 TCP 连接 10s 上限，避免连接失败时 UI 卡死
    local okc, erre = c:connect(host, port)
    if not okc then c:close(); return nil, "connect fail:" .. tostring(erre) end
    local req = "GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\n"
        .. "User-Agent: koreader-tts-cn/" .. ENGINE_VERSION .. "\r\n"
        .. "Accept: */*\r\nConnection: close\r\n\r\n"
    local sok, serr = c:send(req)
    if not sok then c:close(); return nil, "send fail:" .. tostring(serr) end
    local all, cerr, partial = c:receive("*a")
    c:close()
    local raw = (type(all) == "string" and all) or partial or ""
    local hb = raw:find("\r\n\r\n", 1, true)
    local hdr = hb and raw:sub(1, hb - 1) or ""
    local body = hb and raw:sub(hb + 4) or ""
    local code = tonumber(hdr:match("^HTTP/[%d%.]+%s+(%d+)"))
    return body, code, { _status = code, _raw = true }
end

-- v1.66：裸 TCP 探测。返回 (true) 或 (false, 原因)。
-- 用途：把「Kindle 到手机的网络层不通」和「HTTP 层坏了」一分为二。
-- 原因对照：connection refused=对端没服务；timeout=被隔离/IP不对；no route/network unreachable=不同网段或 WiFi 没连。
function TTSengine:tcp_probe(host, port, timeout_s)
    local oks, core = pcall(require, "socket")
    if not oks or not core or not core.tcp then return false, "no core socket" end
    local c, err = core.tcp()
    if not c then return false, "tcp fail:" .. tostring(err) end
    c:settimeout(timeout_s or 4)
    local okc, erre = c:connect(host, port)
    pcall(function() c:close() end)
    if okc then return true end
    return false, tostring(erre)
end

-- 校验 WAV 完整性，并顺带读出采样率/声道/时长。
-- 返回 (declared, actual, rate, ch, bits, seconds)；declared vs actual 用于判截断，
-- seconds 用于给「播放等待」提供超时依据（防止 is_playing() 卡住导致整条链路静默停摆）。
local function wav_info(body)
    if type(body) ~= "string" or #body < 44 then return nil end
    local doff = body:find("data", 1, true)
    local declared, actual = nil, nil
    if doff and doff + 8 <= #body then
        local b1, b2, b3, b4 = body:byte(doff + 4, doff + 7)
        if b1 and b2 and b3 and b4 then
            declared = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            actual = #body - (doff + 7)
        end
    end
    local f = body:find("fmt ", 1, true)
    local rate, ch, bits = nil, 1, 16
    if f and f + 16 <= #body then
        local c1, c2 = body:byte(f + 10, f + 11)
        local r1, r2, r3, r4 = body:byte(f + 12, f + 15)
        if c1 and c2 then ch = c1 + c2 * 256 end
        if r1 and r2 and r3 and r4 then
            rate = r1 + r2 * 256 + r3 * 65536 + r4 * 16777216
        end
        local bb1, bb2 = body:byte(f + 22, f + 23)
        if bb1 and bb2 then bits = bb1 + bb2 * 256 end
    end
    local seconds = nil
    if actual and rate and rate > 0 and ch and ch > 0 and bits and bits > 0 then
        seconds = actual / (rate * ch * (bits / 8))
    end
    return declared, actual, rate, ch, bits, seconds
end

-- GET 请求，返回 (body, code, headers)
-- 关键：默认 socket.request 会复用 keep-alive 连接且无超时，大 WAV 易半截断开/后续请求整段为空。
-- 这里改为：每次新建连接(Connection: close) + 30s 超时 + 分段收齐(sink.table)，
-- 避免 v1.24 观察到的「首次收到部分、之后全 0 字节」截断问题。
function TTSengine:http_get(url)
    -- HTTPS 分流：云端中继（Render/Hugging Face 等）对外强制 HTTPS，裸 TCP 无法完成 TLS 握手，
    -- 会被 Cloudflare 回 400（"plain HTTP request sent to HTTPS port"），必须走带 ssl 的高层通道。
    if url:match("^https://") then
        return self:https_get(url)
    end
    -- 优先走自写的底层通道（读到服务端关闭为止，最不容易丢数据）
    local rb, rcode, rhdr = self:raw_get(url)
    if type(rb) == "string" and #rb >= 100 then
        return rb, (type(rcode) == "number" and rcode) or 200, rhdr
    end
    -- 底层通道失败时回退到 socket.http 高层 API
    if type(rb) ~= "string" then
        -- v1.66：把 raw_get 的具体原因（connect fail:timeout / connection refused 等）打进日志，
        -- 之前只打 (nil)，无法区分「网络层不通」和「HTTP 层坏了」。
        log_err("http_get: 底层通道失败(" .. tostring(rb) .. " 原因=" .. tostring(rcode) .. ")，回退 socket.http")
    end
    local ok, socket = pcall(require, "socket.http")
    if not ok or not socket then return nil, "no socket.http" end
    local okl, ltn12 = pcall(require, "ltn12")
    if not okl or not ltn12 then return nil, "no ltn12" end
    -- 核心 socket 模块（提供 tcp()）可能以不同名字暴露：先试 "socket"，再试 "socket.core"，
    -- 最后退回 socket.http 自身（极少情况 http 子模块自带 tcp）。
    -- 注意：上面 require 的是 socket.http 子模块，它【没有】tcp()，直接调会报
    -- "attempt to call field 'tcp' (a nil value)"（v1.26 实测崩溃点）。
    local coresocket
    for _, mn in ipairs({ "socket", "socket.core" }) do
        local okm, m = pcall(require, mn)
        if okm and m and m.tcp then coresocket = m; break end
    end
    if not coresocket then coresocket = socket end
    -- 首次调用时打一次 socket 能力探测 + 本模块版本，便于从日志判断「设备跑的是哪个版本」
    if not self._socket_probe then
        self._socket_probe = true
        log_err(string.format("http_get 探测 v%s: socket.http=%s 核心socket=%s tcp可用=%surl=%s",
            ENGINE_VERSION,
            socket and "有" or "无",
            coresocket and "有" or "无",
            (coresocket and coresocket.tcp) and "是" or "否(已回退默认连接)",
            tostring(url):sub(1, 60)))
    end
    -- v1.65：单次超时从 60s 砍到 10s。局域网中继本就应在 1-2s 内响应；云端冷启动也罕超 10s。
    -- 关键是避免连接失败时 luasocket 把 UI 线程焊死 60s×重试次数（此前表现为「卡死/死机」）。
    pcall(function()
        if socket.TIMEOUT then socket.TIMEOUT = 10 end
        if coresocket.TIMEOUT then coresocket.TIMEOUT = 10 end
    end)
    -- 关键：通用表单 + sink 时，socket.request{} 返回的是 (1, code, headers, status)——
    -- 首返回值是「成功标记 1」，正文已被写入 sink，并非 (body, code, headers)。
    -- 早期写成 `local ok_req, code, headers = pcall(...)` 导致整体错位一位：
    -- code 拿到 1、headers 拿到数字型 HTTP 码(如 200)，随后 headers["content-type"] 触发
    -- "attempt to index local 'headers' (a number value)"，未捕获并冲出 UIManager 令 KOReader 崩溃。
    -- 这里显式按 (flag, code, headers) 取值修正。（同文件 http_post 无此问题，它多写了一个 _ 占位）
    local chunks = {}   -- 接收 sink 写入的分段正文（改写时曾误删此行，导致 sink.table(nil) 崩溃）
    local r = { pcall(function()
        return socket.request{
            url = url,
            method = "GET",
            headers = { ["Connection"] = "close" },
            sink = ltn12.sink.table(chunks),
            create = function()
                if not coresocket.tcp then return nil end  -- 拿不到 tcp 就交回 luasocket 自建连接
                local c = coresocket.tcp()
                c:settimeout(10)   -- v1.65：单次 socket 操作 10s 超时，避免连接失败时 UI 卡死（见上文）
                return c
            end,
        }
    end) }
    local ok_req = table.remove(r, 1)
    if not ok_req then
        return nil, "req_err(v" .. ENGINE_VERSION .. "):" .. tostring(r[1])
    end
    local flag, code, headers = r[1], r[2], r[3]
    -- v1.64：flag~=1 时 code 里其实是 luasocket 的底层原因（connection refused / timeout / no route），
    -- 之前只回 "http_fail:nil" 把真因吞了，用户无法判断是「中继没跑」还是「被路由器隔离」。
    if flag ~= 1 then return nil, "http_fail:" .. tostring(flag) .. ":" .. tostring(code), headers end
    local body = table.concat(chunks)
    if type(code) == "number" and code >= 400 then return nil, code, headers end
    if type(body) ~= "string" or #body < 100 then return nil, "empty/short", headers end
    return body, code, headers
end

-- HTTPS 专用通道：云端中继（Render / Hugging Face 等）对外强制 HTTPS，
-- 而裸 core.tcp() 无法完成 TLS 握手，会被 Cloudflare/Render 回 400
-- （"plain HTTP request sent to HTTPS port"）。必须改用带 luasec 的手动 TLS 握手。
--
-- v1.59 曾用 socket.http 高层 API 走 HTTPS，但它内部默认 verify=peer（校验证书），
-- 而 Kindle/MiuRead 多半【没有 CA 证书库】→ 握手校验失败 → 连接直接 nil（日志见
-- `code=http_fail(https):nil`）。现代 CDN（Render 走 Cloudflare 类边缘）还要求 SNI。
-- 故 v1.60 改为手写 ssl.wrap 完成握手，强制 verify="none"（跳过 CA 校验）+ server_name（SNI）
-- + tlsv1_2，彻底绕开 Kindle 缺 CA 库与 SNI 的坑。
function TTSengine:_tls_connect(host, port, timeout_s)
    local ok_s, socket = pcall(require, "socket")
    if not ok_s or not socket then return nil, "no socket" end
    local c, cerr = socket.tcp()
    if not c then return nil, "tcp fail:" .. tostring(cerr) end
    c:settimeout(timeout_s or 12)  -- v1.65：TLS 握手 12s 上限，避免云端路径卡死
    local okc, erre = c:connect(host, port)
    if not okc then c:close(); return nil, "connect fail:" .. tostring(erre) end

    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl or not ssl then c:close(); return nil, "no ssl module" end

    -- 三种握手参数逐步降级：先 SNI+tlsv1_2，再无 SNI，再 any 协议。
    -- verify="none" 跳过证书校验（Kindle 无 CA 库）；options="all" 启用全部安全选项。
    local variants = {
        { mode = "client", protocol = "tlsv1_2", server_name = host, verify = "none", options = "all" },
        { mode = "client", protocol = "tlsv1_2", verify = "none", options = "all" },
        { mode = "client", protocol = "any", verify = "none", options = "all" },
    }
    local last_err = ""
    for _, opts in ipairs(variants) do
        local okw, conn = pcall(ssl.wrap, c, opts)
        if okw and conn then
            local okh, errh = pcall(function() return conn:dohandshake() end)
            if okh and errh then
                return conn, nil
            end
            last_err = tostring(errh)
            pcall(function() if conn.close then conn:close() end end)
        else
            last_err = tostring(conn)
        end
    end
    c:close()
    return nil, "tls handshake fail:" .. last_err
end

function TTSengine:https_get(url)
    local ok_ssl = pcall(require, "ssl")
    if not ok_ssl then
        log_err("https_get: 本设备未加载 ssl/luasec 模块，无法访问 https 云端中继；"
            .. "请改用 http 局域网中继（手机开热点 + 本地 tts_relay_android.py）")
        return nil, "no_ssl_module"
    end
    local scheme, hostport, path = url:match("^(https)://([^/]+)(/?.*)$")
    if not hostport then return nil, "bad url" end
    local host, port = hostport:match("^([^:]+):?(%d*)$")
    port = tonumber(port) or 443
    if not path or path == "" then path = "/" end
    if not self._https_probe then
        self._https_probe = true
        log_err("https_get 探测: ssl=有 host=" .. host .. " 走手动 TLS(verify=none+SNI+tlsv1_2)")
    end
    local conn, terr = self:_tls_connect(host, port, 60)
    if not conn then
        log_err("https_get: TLS 连接失败 " .. tostring(terr))
        return nil, "tls_fail:" .. tostring(terr)
    end
    local req = "GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\n"
        .. "User-Agent: koreader-tts-cn/" .. ENGINE_VERSION .. "\r\n"
        .. "Accept: */*\r\nConnection: close\r\n\r\n"
    local sok, serr = pcall(function() return conn:send(req) end)
    if not sok or not serr then
        pcall(function() conn:close() end)
        return nil, "send fail:" .. tostring(serr)
    end
    local all, rerr, partial = conn:receive("*a")
    pcall(function() conn:close() end)
    local raw = (type(all) == "string" and all) or partial or ""
    local hb = raw:find("\r\n\r\n", 1, true)
    local hdr = hb and raw:sub(1, hb - 1) or ""
    local body = hb and raw:sub(hb + 4) or ""
    local code = tonumber(hdr:match("^HTTP/[%d%.]+%s+(%d+)"))
    if type(code) ~= "number" then
        log_err("https_get: 非法响应 raw=" .. tostring(raw:sub(1, 120)))
        return nil, "bad resp"
    end
    if code >= 400 then
        log_err("https_get: HTTP " .. code .. " 响应前80=" .. tostring(body:sub(1, 80)))
        return nil, code
    end
    if type(body) ~= "string" or #body < 100 then return nil, "empty/short", { _status = code } end
    return body, code, { _status = code }
end

-- POST 请求（JSON），返回 (body, code, headers)
function TTSengine:http_post(url, text)
    local ok, socket = pcall(require, "socket.http")
    if not ok or not socket then return nil, "no socket.http" end
    local okj, json = pcall(require, "json")
    if not okj or not json then return nil, "no json" end
    local ltn12 = require("ltn12")
    local payload = json.encode({ text = text, voice = self.settings.voice or "zh" })
    local resp = {}
    local _, code, headers = socket.request({
        url = url,
        method = "POST",
        headers = { ["content-type"] = "application/json", ["content-length"] = tostring(#payload) },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(resp),
    })
    if type(code) == "number" and code >= 400 then return nil, code, headers end
    return table.concat(resp), code, headers
end

-- 按 method 取值，返回 (body, code, headers)
function TTSengine:fetch(text)
    if self.settings.http_method == "POST" then
        local url = (self.settings.http_url or ""):gsub("{voice}", function() return urlencode(self.settings.voice or "zh") end)
        return self:http_post(url, text)
    end
    return self:http_get(self:build_url(text))
end

-- 轮询播放是否结束，结束后回调 on_end。
-- 重要：带【超时守护】。MiuRead 上 is_playing() 偶发一直返回真（ALSA 状态没复位），
-- 原本的纯轮询会永远等下去 —— 表现为"讲了几句后彻底停住、手机端不再收到任何请求、
-- 屏幕也没动静"，却完全没有报错。现在按 WAV 时长估算上限，到点就强制推进。
function TTSengine:_wait_and_cb(on_end, expected_sec)
    local self_ref = self
    local elapsed = 0
    local limit = 120                -- 硬上限（秒），任何情况下不会超过 10 分钟
    if type(expected_sec) == "number" and expected_sec > 0 then
        limit = expected_sec + 6     -- 正常时长 + 6 秒冗余
    end
    local function poll()
        local playing = false
        pcall(function() playing = self_ref.audio:is_playing() end)
        if playing then
            elapsed = elapsed + 0.2
            if elapsed < limit then
                UIManager:scheduleIn(0.2, poll)
                return
            end
            log_err(string.format("_wait_and_cb: 超时守护触发，强制推进（已等%.1fs，预期时长%.1fs）",
                elapsed, type(expected_sec) == "number" and expected_sec or -1))
            pcall(function() self_ref.audio:stop() end)
        end
        if on_end then on_end() end
    end
    UIManager:scheduleIn(0.2, poll)
end

function TTSengine:speak_espeak(sentence, on_end)
    self.audio:play_espeak(sentence,
        self.settings.voice, self.settings.rate, self.settings.pitch, self.settings.volume)
    self:_wait_and_cb(function() if on_end then on_end(true) end end)
end

function TTSengine:speak_http(sentence, on_end)
    local body, code, headers
    local last_err = ""
    local t_fetch = os.time()
    -- v1.72：预取缓存命中 → 直接用，跳过同步网络等待。
    -- 同步 fetch 在每句开播前冻结主线程 1-3 秒（弱网更久），是「翻页卡顿/按 P 无响应」的主因；
    -- 预取把取文摊到上一句的播放时间里，稳态下本路径零等待。
    local pfc = self._pf_cache
    if pfc and pfc.sentence == sentence and type(pfc.body) == "string"
        and #pfc.body > 100 and pfc.body:find("RIFF", 1, true) then
        self._pf_cache = nil
        body = pfc.body
        headers = pfc.ct and { ["content-type"] = pfc.ct } or {}
        log_err(string.format("speak_http: 预取命中 %d 字节，零等待播放", #body))
    else
    log_err(string.format("待朗读(%d字): %s", #(sentence or ""),
        (sentence or ""):sub(1, 20)))
    for i = 1, 3 do
        body, code, headers = self:fetch(sentence)
        local reason = nil
        if not (type(body) == "string" and #body > 100 and body:find("RIFF", 1, true)) then
            reason = string.format("code=%s len=%s", tostring(code),
                type(body) == "string" and #body or tostring(body))
        else
            -- 完整性校验：半截 WAV 必须重试。v1.30 里截断的音频照样通过了 RIFF 检查，
            -- 结果每句只播出开头一点点（用户听到"响了一声就不响了"）。
            local declared, actual = wav_info(body)
            if declared and actual and declared > 0 and actual < declared * 0.95 then
                reason = string.format("截断 declared=%d actual=%d", declared, actual)
            end
        end
        if not reason then break end
        last_err = reason
        -- v1.65：连接类硬失败（拒接 / 无路由 / DNS / TLS）绝不再重试——重试只会把卡死时间×3。
        -- 只对「有声但截断」这类瞬时问题重试。
        if type(code) == "string" and code:match("http_fail") or type(code) == "string" and code:match("req_err")
            or type(code) == "string" and code:match("tls_fail") or type(code) == "string" and code:match("connect fail") then
            log_err("TTS 取文硬失败(连接层)，不再重试: " .. reason)
            break
        end
        log_err("TTS 取文失败/不完整，重试 retry" .. i .. ": " .. reason)
        body = nil
    end
    end  -- v1.72 else 收口：未命中预取时走同步取文
    if not body then
        -- 3 次均失败：回报失败，交由 main 的连续失败看门狗决定是否停止（不再闷头往下翻页）
        log_err("TTS 取文 3 次均失败，跳过本句: " .. tostring(last_err))
        self.last_err = last_err  -- v1.63：把最近一次错误留在引擎上，供弹窗/测试显示具体原因
        UIManager:scheduleIn(0.1, function() if on_end then on_end(false) end end)
        return
    end
    -- 守卫：headers 必须是表才能取 content-type（历史 bug：错位后拿到数字，直接把 KOReader 打崩）
    local ct = (type(headers) == "table")
        and (headers["content-type"] or headers["Content-Type"]) or nil
    local name = string.format("tts_cn_%d_%d%s",
        os.time(), math.random(100000), ext_from_ct(ct))

    -- 依次尝试多个目录，并【校验写入是否真的成功】。
    -- v1.30 的致命坑：/tmp 是 tmpfs 且历史 wav 从不清理，写满后 io.open("wb") 仍返回句柄、
    -- 但 f:write 静默失败 → 文件 0 字节 → 完全没声音，而代码毫无察觉。
    local path, f = nil, nil
    for _, d in ipairs({ self.audio.tmpdir, "/tmp", "/var/tmp" }) do
        if d and d ~= "" then
            local p = d .. "/" .. name
            local fo, oerr = io.open(p, "wb")
            if not fo then
                log_err("无法创建临时文件 " .. p .. " err=" .. tostring(oerr))
            else
                local wok, werr = fo:write(body)
                fo:close()
                if wok then
                    path, f = p, true
                    break
                end
                log_err("写入失败(磁盘可能已满) " .. p .. " err=" .. tostring(werr))
                os.remove(p)
            end
        end
    end
    if not f then
        log_err("所有临时目录均无法写入（/tmp 可能已满），跳过本句")
        UIManager:scheduleIn(0.1, function() if on_end then on_end(false) end end)
        return
    end
    -- 落盘复校：确认真的拿到了字节，避免再次出现 0 字节文件被送去播放
    do
        local chk = io.open(path, "rb")
        local size = 0
        if chk then size = chk:seek("end") or 0; chk:close() end
        if size == 0 then
            log_err("落盘后文件为空 size=0 path=" .. tostring(path))
            os.remove(path)
            UIManager:scheduleIn(0.1, function() if on_end then on_end(false) end end)
            return
        end
    end
    -- 仅当用户在设置里显式改过播放命令（≠默认占位 aplay -q）才覆盖自动探测结果
    if self.settings.player_cmd and self.settings.player_cmd ~= ""
       and self.settings.player_cmd ~= "aplay -q" then
        self.audio.player_cmd = self.settings.player_cmd
    end
    self.audio:play_file(path)
    local _, _, rate, ch, bits, seconds = wav_info(body)
    log_err(string.format("播放: %.2f秒 rate=%s ch=%s bits=%s 文件大小=%d 取文耗时=%ds",
        seconds or -1, tostring(rate), tostring(ch), tostring(bits), #body,
        os.time() - t_fetch))
    -- 播完立刻删除：不让历史 wav 堆积把 /tmp 塞满（这正是本次故障的根源）
    self:_wait_and_cb(function()
        pcall(function() os.remove(path) end)
        if on_end then on_end(true) end
    end, seconds)
end

function TTSengine:speak(sentence, on_end)
    if self.settings.backend == "http" then
        self:speak_http(sentence, on_end)
    else
        self:speak_espeak(sentence, on_end)
    end
end

-- 立即停止
function TTSengine:stop()
    -- v1.72：停朗读时收掉进行中的预取连接与缓存
    pcall(function()
        if self._pf and self._pf.sock then self._pf.sock:close() end
        self._pf = nil
        self._pf_cache = nil
    end)
    self.audio:stop()
end

-- v1.72：协作式分片预取。
-- 动机：speak_http 的同步 fetch 在每句开播前冻结主线程 1-3 秒（弱网更久），
-- 期间按键/翻页全部排队——这就是「朗读时翻页卡顿、按 P 无响应」的主因。
-- 做法：播放第 N 句期间，用非阻塞 socket 分片拉取第 N+1 句的音频，
-- 每片只占主线程几毫秒（读到一点就让出），下一句开播时音频已在内存。
-- 失败/超时静默丢弃，speak_http 自动回退同步取文，绝不影响出声。
function TTSengine:start_prefetch(sentence)
    pcall(function()
        if not sentence then return end
        if self._pf then return end                          -- 已有一个预取在跑
        local pfc = self._pf_cache
        if pfc and pfc.sentence == sentence then return end  -- 已缓存
        -- v1.73：必须用 build_url 把 {voice}/{text} 替换成真实请求串。
        -- 否则中继收到字面占位符 text={text} 会返回空响应（日志里「数据不完整(0字节)」的元凶），
        -- 预取彻底失效 → 每句仍走同步 fetch 冻结 UI。这是 v1.72「还是卡」的真正原因。
        local real_url = self:build_url(sentence)
        if not real_url or real_url == "" then return end
        if self.settings.http_method == "POST" then return end
        -- 仅对 http GET 做分片预取；HTTPS(TLS) 握手复杂，维持同步路径
        local scheme, hostport, path = real_url:match("^(https?)://([^/]+)(/?.*)$")
        if not scheme or scheme ~= "http" then return end
        local host, port = hostport:match("^([^:]+):?(%d*)$")
        port = tonumber(port) or 80
        if not path or path == "" then path = "/" end
        local oks, core = pcall(require, "socket")
        if not oks or not core or not core.tcp then return end
        local c = core.tcp()
        if not c then return end
        c:settimeout(0.05)
        self._pf = {
            sentence = sentence, sock = c, stage = "connect", tries = 0,
            host = host, port = port, buf = "",
            req = "GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\n"
                .. "User-Agent: koreader-tts-cn/" .. ENGINE_VERSION .. "\r\n"
                .. "Accept: */*\r\nConnection: close\r\n\r\n",
        }
        self:_pf_step()
    end)
end

function TTSengine:_pf_step()
    local pf = self._pf
    if not pf then return end
    local ok, err = pcall(function()
        local c = pf.sock
        if pf.stage == "connect" then
            pf.tries = pf.tries + 1
            if pf.tries > 40 then error("connect 超时") end
            local cok, cerr = c:connect(pf.host, pf.port)
            local es = tostring(cerr)
            if cok or es:find("already connected") then
                c:settimeout(0)
                pf.stage = "send"
            elseif es:find("timeout") or es:find("progress") then
                return  -- 连接进行中，等下一片
            else
                error("connect: " .. es)
            end
        end
        if pf.stage == "send" then
            c:settimeout(1)
            local sok = c:send(pf.req)
            if not sok then error("send fail") end
            c:settimeout(0)
            pf.stage = "recv"
            return
        end
        if pf.stage == "recv" then
            for _ = 1, 4 do
                local data, emsg, partial = c:receive(65536)
                if data then
                    pf.buf = pf.buf .. data
                elseif emsg == "timeout" then
                    pf.buf = pf.buf .. (partial or "")
                    return  -- 本片读尽，让出主线程
                else
                    -- v1.79：服务端关连接时，最后一块数据常经 partial 返回
                    -- （receive 返回 nil,"closed",partial）。旧逻辑直接丢弃 → 句尾数据丢失
                    -- （表现为「句尾吞字」，长句/首章尤明显）。此处先收下 partial 再结束。
                    pf.buf = pf.buf .. (partial or "")
                    error("_PF_DONE_")
                end
            end
            return
        end
    end)
    if ok then
        UIManager:scheduleIn(0.15, function() self:_pf_step() end)
        return
    end
    -- 完成（_PF_DONE_）或失败，统一收尾
    pcall(function() pf.sock:close() end)
    self._pf = nil
    local msg = tostring(err or "")
    if msg:find("_PF_DONE_") then
        local b = pf.buf or ""
        -- 切掉 HTTP 响应头（与 raw_get 同款逻辑），只留正文
        local hb = b:find("\r\n\r\n", 1, true)
        local ct = nil
        if hb then
            local hdr = b:sub(1, hb - 1)
            ct = hdr:lower():match("content%-type:%s*([%w/%-]+)")
            b = b:sub(hb + 4)
        end
        if #b > 100 and b:find("RIFF", 1, true) then
            self._pf_cache = { sentence = pf.sentence, body = b, ct = ct }
            log_err("prefetch: 下一句音频已缓存 " .. #b .. " 字节")
        else
            log_err("prefetch: 数据不完整(" .. #b .. "字节)，丢弃，下一句回退同步取文")
        end
    else
        log_err("prefetch 失败: " .. msg .. "（下一句回退同步取文）")
    end
end

return TTSengine
