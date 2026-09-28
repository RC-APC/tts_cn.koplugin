--[[
  audioplayer.lua —— Kindle / MiuRead 音频播放封装（v1.52）
  设计要点：
    * MiuRead 把 KOReader 的标准音频 Lua 层（ui/sound、ffi/audio…）整个删掉了，
      package.loaded 里不存在任何音频模块；SDL2 FFI 在真机上也 ffi.load 失败。
    * 但原生 Kindle 系统能发声（系统 TTS 走耳机孔出声），说明底层 ALSA（libasound）
      是活的。因此主音频后端改为直接用 LuaJIT FFI 调 libasound 写 PCM，
      这是与「原生系统能响」同一套音频子系统。
    * 中继端发来 16-bit PCM 单声道 WAV，本层解析 WAV 头、按真实参数配置 hw_params、
      写 PCM、drain、close。使用 "default" 设备（plug 层自动重采样/格式转换）。
    * 关键改动（v1.23）：整段朗读只 open 一次 ALSA 设备，反复复用（标准 TTS 做法），
      彻底避免 v1.22「每句重开 default 导致 dmix/plug 层阻塞、第 2 句起 writei 卡死」。
    * SDL FFI / 内部 Lua 引擎 / CLI 播放器作为依次兜底。
    * 播放状态：ALSA 同步播放期间用 _busy 标记；stop() 置 alsa_stop 让写循环提前退出。
]]

local AudioPlayer = {}

-- ---------- 日志辅助 ----------
local function log_info(s)
    pcall(function()
        local Logger = require("logger")
        if Logger and Logger.info then Logger.info("[tts_cn] " .. s) end
    end)
end
local function log_warn(s)
    pcall(function()
        local Logger = require("logger")
        if not Logger then return end
        -- MiuRead/KOReader 的 logger 方法名不统一，逐个尝试以免告警被静默吞掉
        if Logger.warn then Logger.warn("[tts_cn] " .. s)
        elseif Logger.warning then Logger.warning("[tts_cn] " .. s)
        elseif Logger.error then Logger.error("[tts_cn] " .. s)
        elseif Logger.err then Logger.err("[tts_cn] " .. s)
        end
    end)
end

-- ---------- 后端探测（仅加载一次） ----------
local play_method = nil
local stop_method = nil
local probe_log = {}
local sdl_engine = nil
local alsa_engine = nil      -- ALSA FFI 播放器（MiuRead 主后端）
local internal_engine = nil
local internal_kind = nil
local cli_cmd = nil

local alsa_stop = false      -- 全局停止标志，写循环每帧检查
-- v1.41「语速校正」开关（main.lua 菜单实时切换，下一句立即生效，无需重启）：
-- 原理见 alsa_play 内 speed_fix 分支注释。默认关 = v1.31 原生行为（干净但慢一倍）。
local speed_fix_on = false
-- v1.53 软件音量增益百分比（0-100，100=原样不处理）。MiuRead 把物理音量键吃掉了、
-- 不转发给 ALSA，系统音量只能回原生阅读器改；故只能靠软件增益降音量（对 16bit PCM 样本乘系数）。
local cur_volume = 100

-- 扫描 /proc/self/maps，找出进程里实际加载的共享库绝对路径（按关键字）
local function find_loaded_lib_paths(keyword)
    local paths = {}
    local f = io.open("/proc/self/maps", "r")
    if not f then return paths end
    for line in f:lines() do
        local p = line:match("(%S*" .. keyword .. "%S*.so%S*)")
        if p then
            local dup = false
            for _, v in ipairs(paths) do if v == p then dup = true break end end
            if not dup then paths[#paths + 1] = p end
        end
    end
    f:close()
    return paths
end

local ffi_ok, ffi = pcall(require, "ffi")

-- 异步分片播放需要 UIManager 调度：把写循环切成小段，每段之间把控制权交还事件循环，
-- 这样播放期间 UI 线程仍能被唤醒处理按键 / 暂停 / 翻页（否则 snd_pcm_writei 阻塞会把 UI 焊死）。
-- 缺失时退化为「递归立即调用」（仍可用，仅播放期间 UI 短暂不响应）。
local UIManager
pcall(function() UIManager = require("ui/uimanager") end)
if not UIManager then
    UIManager = { scheduleIn = function(_, f) if type(f) == "function" then f() end end }
end

-- ============================================================
-- 0) ALSA FFI 后端（主后端，v1.23 改为「整段复用单一设备」）
-- ============================================================
if ffi_ok and ffi then
    local asound_lib, asound_err
    do
        local names = { "asound", "libasound", "libasound.so.2", "libasound.so" }
        for _, p in ipairs(find_loaded_lib_paths("libasound")) do
            names[#names + 1] = p
        end
        for _, name in ipairs(names) do
            local ok, lib = pcall(ffi.load, name)
            if ok and lib then
                asound_lib = lib
                break
            end
        end
        if not asound_lib then
            asound_err = "ffi.load(libasound*) 失败"
        end
    end

    if asound_lib then
        ffi.cdef[[
            typedef struct snd_pcm snd_pcm_t;
            typedef struct snd_pcm_hw_params snd_pcm_hw_params_t;
            typedef long snd_pcm_sframes_t;
            typedef unsigned long snd_pcm_uframes_t;
            int  snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
            int  snd_pcm_close(snd_pcm_t *pcm);
            int  snd_pcm_hw_params_malloc(snd_pcm_hw_params_t **ptr);
            void snd_pcm_hw_params_free(snd_pcm_hw_params_t *obj);
            int  snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
            int  snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int access);
            int  snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int format);
            int  snd_pcm_hw_params_test_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int format);
            int  snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val);
            int  snd_pcm_hw_params_set_rate(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val, int dir);
            int  snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int dir);
            int  snd_pcm_hw_params_get_rate(snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
            int  snd_pcm_start(snd_pcm_t *pcm);
            int  snd_pcm_hw_params_set_buffer_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val);
            int  snd_pcm_hw_params_set_buffer_time_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
            int  snd_pcm_hw_params_set_period_time_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
            int  snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
            int  snd_pcm_prepare(snd_pcm_t *pcm);
            snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size);
            int  snd_pcm_recover(snd_pcm_t *pcm, int err, int silent);
            int  snd_pcm_drain(snd_pcm_t *pcm);
            int  snd_pcm_drop(snd_pcm_t *pcm);
        ]]
        -- v1.37 教训：ffi.cdef 若与宿主（MiuRead 内核）已声明符号冲突，会直接抛错并
        -- 中止整个模块加载 → require("audioplayer") 失败 → 「音频引擎未加载」。
        -- 因此新增声明必须单独一条 cdef 且用 pcall 包裹：即使冲突也只损失这几个
        -- 新符号（走降级路径），绝不拖垮模块加载。
        pcall(ffi.cdef, [[
            int  snd_pcm_nonblock(snd_pcm_t *pcm, int nonblock);
            int  snd_pcm_wait(snd_pcm_t *pcm, int timeout);
            int  snd_pcm_state(snd_pcm_t *pcm);
            struct timeval { long tv_sec; long tv_usec; };
            int  gettimeofday(struct timeval *tv, void *tz);
        ]])
        local SND_PCM_STREAM_PLAYBACK = 0
        local SND_PCM_ACCESS_RW_INTERLEAVED = 3
        -- ALSA snd_pcm_format_t 真值（取自 alsa/pcm.h）：
        --   S8=0  U8=1  S16_LE=2  S16_BE=3  U16_LE=4  U16_BE=5
        --   S24_LE=6  S24_BE=7  S32_LE=10  S32_BE=11
        -- WAV 样本恒为【小端】（RIFF 小端），故 16bit 必须用 S16_LE=2。
        -- 旧代码误把 FMT[16] 写成 3（S16_BE）→ 告诉 ALSA「数据是大端」，但喂的是小端字节 →
        -- 每个 16bit 样本高低字节被错位解读；真实语音相邻样本主要差低字节，错位后相邻输出值剧烈跳变
        -- → 宽频咝咝/收音机调台噪声。这恰是「与采样率无关、三种速率组合全噪声、drain 也正常」的根因。
        -- v1.43 修正：16bit 一律按 S16_LE=2，并在 setup 里实测设备是否只支持大端（不支持小端时退 S16_BE
        -- 并对数据做字节交换），彻底消除字节序错位。
        local FMT = { [8] = 1, [16] = 2, [24] = 6, [32] = 10 }  -- U8=1, S16_LE=2, S24_LE=6, S32_LE=10

        -- 小端整数解析（Lua 5.1 无 string.unpack）
        local function le16(s, off) return string.byte(s, off) + string.byte(s, off + 1) * 256 end
        local function le32(s, off)
            return string.byte(s, off) + string.byte(s, off + 1) * 256
                 + string.byte(s, off + 2) * 65536 + string.byte(s, off + 3) * 16777216
        end

        -- 解析 WAV，返回 {fmt, channels, rate, bits, buf, data_off, data_len, raw_len} 或 nil
        -- 关键：必须保留原始缓冲区引用 buf（cdata），不能只存派生指针 cdata+off，
        -- 否则 parse_wav 返回后局部 cdata 出作用域被 LuaJIT GC 回收，派生指针变悬空，
        -- snd_pcm_writei 读已释放内存 → Segmentation fault（GC 时机不定，故偶发崩溃）。
        local function parse_wav(path)
            local f = io.open(path, "rb")
            if not f then return nil, "open" end
            local raw = f:read("*a")
            f:close()
            if #raw < 44 then return nil, "too small" end
            if raw:sub(1, 4) ~= "RIFF" or raw:sub(9, 12) ~= "WAVE" then
                return nil, "not RIFF/WAVE"
            end
            -- 扫子块找 fmt 和 data
            local off = 13
            local fmt, channels, rate, bits, data_off, data_len
            while off + 8 <= #raw do
                local id = raw:sub(off, off + 3)
                local sz = le32(raw, off + 4)
                local base = off + 8
                if id == "fmt " then
                    fmt = le16(raw, base)
                    channels = le16(raw, base + 2)
                    rate = le32(raw, base + 4)
                    bits = le16(raw, base + 14)
                elseif id == "data" then
                    data_off = base
                    data_len = sz
                    break
                end
                off = base + sz + (sz % 2)  -- 对齐到偶边界
            end
            if not (fmt and data_off) then return nil, "missing fmt/data" end
            if fmt ~= 1 then return nil, "not PCM(fmt=" .. tostring(fmt) .. ")" end
            local cdata = ffi.new("uint8_t[?]", #raw)
            ffi.copy(cdata, raw, #raw)
            return {
                fmt = fmt, channels = channels, rate = rate, bits = bits,
                buf = cdata,            -- 持有原始缓冲区，防止 GC 回收
                data_off = data_off,    -- Lua 字符串下标（1 基），仅用于长度换算/日志
                -- 关键修正：cdata 是 0 基数组（cdata[0] 对应 Lua 字符串第 1 字节），
                -- 而 data_off 是 1 基下标。以前直接把 data_off 当 cdata 偏移用，整段 PCM
                -- 读偏 1 个字节 —— 16bit 采样的高低字节被错位拼合，声音变成刺耳失真
                -- （用户反馈的"声音粗"）。所有指针运算必须用 cdata_off。
                cdata_off = data_off - 1,
                data_len = data_len,
                raw_len = #raw,         -- 原始文件总长度，用于写循环越界兜底
            }
        end

        -- 高精度计时（用于「写循环实际耗时 vs 音频时长」对比，是诊断语速异常的关键证据）。
        -- 全链路 pcall 兜底：gettimeofday（微秒）→ socket.gettime（毫秒）→ os.time()（整秒）。
        -- struct timeval / gettimeofday 可能因 cdef 冲突没声明成功，绝不能让它们在加载期炸掉。
        local tv_ok, tv = pcall(ffi.new, "struct timeval[1]")
        local gettimeofday = (tv_ok and tv and ffi.C and type(ffi.C.gettimeofday) == "function")
                             and ffi.C.gettimeofday or nil
        local gettime_sock = nil
        do
            local oks, sk = pcall(require, "socket")
            if oks and sk and type(sk.gettime) == "function" then gettime_sock = sk.gettime end
        end
        local function now()
            if gettimeofday and tv then
                local ok, v = pcall(function()
                    if gettimeofday(tv, nil) == 0 then
                        return tonumber(tv[0].tv_sec) + tonumber(tv[0].tv_usec) / 1000000
                    end
                    return nil
                end)
                if ok and type(v) == "number" then return v end
            end
            if gettime_sock then
                local ok, v = pcall(gettime_sock)
                if ok and type(v) == "number" then return v end
            end
            return os.time()
        end

        -- 从 uint8 缓冲里读一个 16bit 有符号小端样本
        local function s16(buf, off)
            local lo = buf[off]
            local hi = buf[off + 1]
            local v = lo + hi * 256
            if v >= 32768 then v = v - 65536 end
            return v
        end

        -- 16bit PCM 软件重采样（带抗混叠低通）。
        -- 为什么必须有这一步：Kindle 的 ALSA 设备若只支持 8000Hz，snd_pcm_hw_params_set_rate_near
        -- 会把 16000Hz 的请求「协商」成 8000Hz 并照 8000Hz 的时钟吐数据 —— 于是 16000Hz 的音频
        -- 被当成 8000Hz 播：语速慢一倍、音调低一个八度（用户反馈的"语速慢、声音粗"就是这个）。
        -- 按设备真实速率把 PCM 重采样后，时长和音调都回到正确值。
        -- 关键：降采样必须用【区间均值】做抗混叠低通，否则 4000–8000Hz 的语音成分会折叠混叠
        -- 回 0–4000Hz，听感就是刺耳的"吱吱吱"（v1.35 之前用"丢奇数样本"正是这个坑）。
        local function resample_s16(buf, data_off, frames, ch, src_rate, dst_rate)
            if src_rate == dst_rate or frames < 2 then return nil, 0 end
            local ratio = src_rate / dst_rate
            local dst_frames = math.floor(frames / ratio + 0.5)
            if dst_frames < 1 then return nil, 0 end
            local out = ffi.new("int16_t[?]", dst_frames * ch)
            local last = frames - 1
            for i = 0, dst_frames - 1 do
                -- 本输出帧对应源区间 [i*ratio, (i+1)*ratio)，取区间内的均值 = 抗混叠低通
                local p0 = math.floor(i * ratio)
                local p1 = math.floor((i + 1) * ratio)
                if p1 > last then p1 = last end
                if p0 > last then p0 = last end
                if p1 < p0 then p1 = p0 end
                local span = p1 - p0 + 1
                for c = 0, ch - 1 do
                    local acc = 0
                    for j = p0, p1 do
                        acc = acc + s16(buf, data_off + j * ch * 2 + c * 2)
                    end
                    out[i * ch + c] = math.floor(acc / span)
                end
            end
            return out, dst_frames
        end

        -- 持久化设备句柄：整段朗读只开一次，逐句复用，避免每句重开 default 卡死。
        local alsa_dev = nil   -- { pcm, rate, channels, bits }
        -- v1.40 关键回退：缓冲回到 v1.31 工作态的 32768（~2s@16000）。
        -- 之前 v1.39 调到 65536，但日志实测本机 snd_pcm_hw_params_set_buffer_size_near
        -- 协商后只给 16384（硬件上限 2s@8000），调大无效；且"吱吱"根因不在缓冲大小，
        -- 而在「设备被强制开在 8000Hz 直出 8000Hz 数据」这条坏路（见 alsa_open_dev 注释）。
        -- 故缓冲恢复常态即可，重点改在采样率策略。
        local ALSABUF = 32768

        -- ===== 采样率模型（v1.41 整理，全部来自真机日志实测）=====
        -- 1) 设备按 16000Hz 开：ALSA 协商"成功"，但实际按 8000 帧/秒消耗
        --    （v1.31/33 日志 比值=2.00 铁证）→ 16000Hz 内容被半速播放（音调低八度，但【干净】，
        --    v1.31 凭此路径连放好几句）。
        -- 2) 设备按 8000Hz 开：按 8000 帧/秒消耗（比值=1.00），但 DAC 输出全程"吱吱吱"
        --    （v1.35/37/39 三次实验均如此）→ 这条 8000 直出配置是坏的，绝不再走。
        -- 3) 推论：无论开多少率，帧消耗速率恒为 8000/秒。故把内容预先降到 8000Hz 再喂给
        --    「开在 16000 的设备」，播放耗时 = 帧数/8000 = 自然时长 → 【原速 + 干净】，
        --    且走的仍是 16000 的干净 DAC 配置。这就是「语速校正」开关的原理。
        local DRAIN_RATE = 8000        -- 实测帧消耗速率（帧/秒），与设备开多少率无关
        local DEVICE_OPEN_RATE = 16000 -- 慢速(半速)模式开门率：16000 内容原样直出，硬件按 8000 时钟消耗 → 半速但干净（v1.31 工作态）
        local DEVICE_OPEN_RATE_FAST = 8000 -- 原速(语速校正开)模式开门率：内容降到 8000 后直出，plug 8000→硬件8000 直通 → 原速干净。
        -- v1.44 修正：旧「语速校正」把内容降 8000 却仍喂 16000 设备，plug 被迫做 8000→16000 实时上采样
        -- → 本机 writei 永久阻塞(卡死)，且算出来实为 2 倍速。现改为开门率随开关切换（16000↔8000），
        -- 8000 路走 plug 直通，既原速又避开上采样死锁。旧"8000 直出吱吱"是格式字节序 bug，v1.43 已修。

        local function alsa_close_dev()
            if alsa_dev then
                pcall(function() asound_lib.snd_pcm_drop(alsa_dev.pcm) end)
                pcall(function() asound_lib.snd_pcm_close(alsa_dev.pcm) end)
                alsa_dev = nil
            end
        end

        local function alsa_open_dev(rate, channels, bits)
            alsa_close_dev()
            if not FMT[bits] and bits ~= 16 then
                log_warn("ALSA 不支持的位深 " .. tostring(bits))
                return nil, "bits"
            end
            local handle = ffi.new("snd_pcm_t*[1]")
            -- 设备名候选：default 优先（v1.31 已实测此路能连着放好几句、人声干净；
            -- 它走系统 plug 层做 16000→设备内时钟 的硬件下采样，正是可用的干净路径）；
            -- 其次 plughw:0,0、hw:0,0 兜底。v1.40 设备按文件原生率开、不做 Lua 重采样。
            local devnames = { "default", "plughw:0,0", "hw:0,0" }
            local opened, opened_name = false, nil
            for _, dn in ipairs(devnames) do
                local rc = asound_lib.snd_pcm_open(handle, dn, SND_PCM_STREAM_PLAYBACK, 0)
                log_info("ALSA snd_pcm_open(" .. dn .. ") rc=" .. tonumber(rc))
                if tonumber(rc) >= 0 then
                    opened = true
                    opened_name = dn
                    break
                else
                    log_warn("ALSA snd_pcm_open(" .. dn .. ") 失败 rc=" .. tonumber(rc))
                end
            end
            if not opened then
                return nil, "open"
            end
            local pcm = handle[0]
            -- 整段参数配置包进 pcall：任何一步（含 FFI 类型错误）失败都释放已开的 pcm 句柄，
            -- 否则句柄泄漏会导致后续每句 snd_pcm_open 全部 EBUSY(-16)（v1.34 初版踩过的坑：
            -- set_rate_near 第4参数误传 int[1] 指针而非标量，抛错中断函数、pcm 没关，
            -- 声卡被占、从此一句都打不开）。
            local hw = ffi.new("snd_pcm_hw_params_t*[1]")
            asound_lib.snd_pcm_hw_params_malloc(hw)
            local function setup()
                asound_lib.snd_pcm_hw_params_any(pcm, hw[0])
                asound_lib.snd_pcm_hw_params_set_access(pcm, hw[0], SND_PCM_ACCESS_RW_INTERLEAVED)
                -- v1.43 格式自适应（根因修复）：WAV 是小端，优先 S16_LE(2)。
                -- 若设备不支持小端才退 S16_BE(3) 并对数据交换字节（need_swap），
                -- 这样无论硬件字节序如何都能出正确声音，绝不再把小端字节当大端解读成噪声。
                local fmt_le, fmt_be = 2, 3
                local chosen_fmt, need_swap = fmt_le, false
                if bits == 16 then
                    local le_ok = (tonumber(asound_lib.snd_pcm_hw_params_test_format(pcm, hw[0], fmt_le)) >= 0)
                    if le_ok then
                        chosen_fmt, need_swap = fmt_le, false
                    else
                        local be_ok = (tonumber(asound_lib.snd_pcm_hw_params_test_format(pcm, hw[0], fmt_be)) >= 0)
                        if be_ok then
                            chosen_fmt, need_swap = fmt_be, true
                            log_warn("ALSA 设备不支持 S16_LE，改用 S16_BE 并对数据交换字节")
                        else
                            log_warn("ALSA 设备既不支持 S16_LE 也不支持 S16_BE，按 S16_LE 赌一把，交 plug 协商")
                        end
                    end
                else
                    chosen_fmt = FMT[bits] or fmt_le
                end
                asound_lib.snd_pcm_hw_params_set_format(pcm, hw[0], chosen_fmt)
                asound_lib.snd_pcm_hw_params_set_channels(pcm, hw[0], channels)
                -- v1.40 回退到 v1.31 工作态：【按文件原生采样率】开设备，不做 Lua 重采样。
                -- set_rate_near 协商到设备支持的最近率并写回 r[0]（plug 层负责真正转换）。
                -- 实测 v1.31 用此路径连着放好几句、人声干净；而强制 8000 直出会全程吱吱。
                -- 关键：第 4 参数 dir 是标量 int（FFI 声明 int dir），传 0（即 NULL）即可。
                local r = ffi.new("unsigned int[1]", rate)
                asound_lib.snd_pcm_hw_params_set_rate_near(pcm, hw[0], r, 0)
                local actual_rate = tonumber(r[0]) or rate
                -- v1.22 回归教训：绝不用 buffer_time_near（本机 snd_pcm_open 卡死）。
                -- 用 buffer_size_near（v1.20 验证可用路径）。
                local bs = ffi.new("unsigned long[1]", ALSABUF)
                pcall(function() asound_lib.snd_pcm_hw_params_set_buffer_size_near(pcm, hw[0], bs) end)
                local rc = asound_lib.snd_pcm_hw_params(pcm, hw[0])
                if tonumber(rc) < 0 then
                    log_warn("ALSA snd_pcm_hw_params 失败 rc=" .. tonumber(rc))
                    return nil, "hw_params:" .. tonumber(rc)
                end
                asound_lib.snd_pcm_prepare(pcm)
                -- req_rate 记录「当初是用哪个文件速率开的设备」。重开判断必须拿它来比，
                -- 不能拿协商后的 actual_rate 比——否则同一文件每句都判定「参数变了」而重开设备，
                -- 直接复现 v1.22「第 2 句起卡死」的故障。
                alsa_dev = { pcm = pcm, rate = actual_rate, req_rate = rate,
                             channels = channels, bits = bits, need_swap = need_swap }
                log_info(string.format(
                    "ALSA 已开声路 dev=%s 请求率=%d 协商率=%d ch=%d bits=%d buf=%d（v1.40 原生率直出,交给系统plug重采样）",
                    opened_name, rate, actual_rate, channels, bits, tonumber(bs[0])))
                return alsa_dev
            end
            local ok, dev_or_err = pcall(setup)
            asound_lib.snd_pcm_hw_params_free(hw[0])
            if not ok or not dev_or_err then
                log_warn("ALSA 设备参数配置失败(已释放句柄防占用): " .. tostring(dev_or_err or "unknown"))
                pcall(function() asound_lib.snd_pcm_close(pcm) end)
                return nil, "setup"
            end
            return dev_or_err
        end

        -- 单句播放：复用已开设备；若设备未开或参数变化（极少）则重开。
        -- v1.68：改为异步分片播放（self/on_done 参数 + UIManager 调度），播放期间不阻塞 UI，
        -- 按键 / 暂停 / 翻页都能在句子间隙被事件循环处理。
        local function alsa_play(self, path, on_done)
            log_info("ALSA 播放开始: " .. path)
            alsa_stop = false
            self._busy = true
            local finished = false
            local function finish(ok)
                if finished then return end
                finished = true
                self._busy = false
                if on_done then pcall(on_done, ok) end
            end
            -- 播放前先确认文件可读、大小合理（中继异常时常返回空文件/错误页而非 WAV）
            local fsize = -1
            pcall(function()
                local f = io.open(path, "rb")
                if f then
                    local data = f:read("*a")
                    f:close()
                    fsize = #data
                end
            end)
            log_info("ALSA 文件大小: " .. fsize .. " path=" .. path)
            local info, perr = parse_wav(path)
            if not info then
                log_warn("ALSA WAV 解析失败: " .. tostring(perr) .. " filesize=" .. fsize .. " path=" .. path)
                return finish(false)
            end
            -- 诊断：文件真实大小 vs WAV 头声明 data_len，便于发现中继截断
            local declared = info.data_len
            local real_data = (info.raw_len and info.data_off) and (info.raw_len - info.data_off) or declared
            log_info(string.format("ALSA WAV 解析 ok filesize=%d data_off=%d(cdata%d) 头data_len=%d 实data=%d rate=%d ch=%d bits=%d",
                info.raw_len, info.data_off, info.cdata_off, declared, real_data,
                info.rate, info.channels, info.bits))
            -- 抽样打印前几帧，便于一眼确认 PCM 没读偏（正常应是小振幅、相邻样本接近）
            pcall(function()
                local fb = info.channels * (info.bits / 8)
                if info.cdata_off + 4 * fb > info.raw_len then return end
                local s = {}
                for k = 0, 3 do
                    s[#s + 1] = tostring(s16(info.buf, info.cdata_off + k * fb))
                end
                log_info("ALSA 前4样本(自 cdata_off): " .. table.concat(s, ","))
            end)

            -- 必要时开/重开设备。
            -- v1.44：开门率随「语速校正」开关切换：
            --   关 → 开在 16000，16000 内容原样直出（半速、干净，v1.31 工作态）；
            --   开 → 开在 8000，内容先降到 8000 再直出（plug 8000→硬件8000 直通，原速、干净）。
            -- 这样速率差由「开门率 + 内容降采样」共同吸收，绝不触发 plug 8000→16000 上采样死锁。
            -- 仅当开门率/声道/位深变化时才重开（同一开关状态下连续句子不重开，避免 v1.22 卡死）。
            -- v1.48：每句强制重开设备（close 旧 + open 新），不跨句复用。
            -- 根因：阻塞 writei 复用同一设备播到较大那句时，驱动内 XRUN 累积/状态异常会导致
            -- writei 永久阻塞在 ALSA 内核（看门狗写在返回后永远走不到）→ 卡死重启。v1.43/46 复现。
            -- 每句用全新设备从干净态(PREPARED)起跑，XRUN 不跨句继承，根治该卡死。
            -- 开门率仍随「语速校正」开关切（开→8000 直通原速；关→16000 半速干净）。
            local open_rate = speed_fix_on and DEVICE_OPEN_RATE_FAST or DEVICE_OPEN_RATE
            pcall(alsa_close_dev)
            local ok_open, oerr = pcall(alsa_open_dev, open_rate, info.channels, info.bits)
            if not (ok_open and alsa_dev) then
                log_warn("ALSA 打开设备失败: " .. tostring(oerr))
                return finish(false)
            end
            log_info("ALSA 本句已重开设备 开门率=" .. open_rate)
            local pcm = alsa_dev.pcm

            -- 写循环：带欠载(XRUN)恢复 + 连续 0 写看门狗（防 writei 卡死无限循环）
            local frame_bytes = info.channels * (info.bits / 8)
            local total_frames = math.floor(info.data_len / frame_bytes)
            -- 硬护栏：WAV 头若损坏，data_len 可能超过实际缓冲，写循环按派生指针越界读取
            -- → snd_pcm_writei 读越界内存 → 偶发段错误。用原始文件总长度兜底封顶，绝不越界。
            if info.raw_len and info.data_off then
                local safe_frames = math.floor((info.raw_len - info.data_off + 1) / frame_bytes)
                if safe_frames < total_frames then
                    log_warn("ALSA WAV data_len 越界，帧数从 " .. total_frames
                        .. " 截断到 " .. safe_frames .. "（防段错误）")
                    total_frames = safe_frames
                end
            end
            if total_frames <= 0 then
                log_warn("ALSA 有效帧数为 0，跳过播放避免崩溃")
                return finish(false)
            end

            -- ===== 内容准备（v1.41）=====
            -- 基准 = v1.31 干净路：16000Hz 内容原样写给「开在 16000 的设备」→ 半速、低八度、干净。
            -- 「语速校正」开（speed_fix_on，菜单实时切换，下一句生效）：
            --   设备帧消耗恒为 DRAIN_RATE=8000/秒，故把内容降到 8000Hz 后，播放耗时=自然时长
            --   → 原速 + 音调正常（带宽 4kHz，电话音质），仍走 16000 的干净 DAC 配置。
            --   中继发 16000 时降 2 倍（区间均值抗混叠）；发 8000 则无需处理（本就原速）。
            local src_buf = info.buf
            local src_off = info.cdata_off
            local natural_frames = total_frames
            if speed_fix_on and info.bits == 16 and info.rate > DRAIN_RATE * 1.5 then
                local t0 = now()
                local out, n = resample_s16(info.buf, info.cdata_off, total_frames,
                                            info.channels, info.rate, DRAIN_RATE)
                if out and n and n > 0 then
                    src_buf, src_off, total_frames = out, 0, n
                    log_info(string.format(
                        "ALSA 语速校正: %dHz→%dHz 帧数 %d→%d 耗时 %.2fs（设备仍开%d，按%d帧/秒消耗→原速）",
                        info.rate, DRAIN_RATE, natural_frames, n, now() - t0,
                        DEVICE_OPEN_RATE, DRAIN_RATE))
                else
                    log_warn("ALSA 语速校正重采样失败，本句按半速播放")
                end
            else
                log_info(string.format("ALSA 原生直出（文件%dHz→设备%d，按%d帧/秒消耗→%s）",
                    info.rate, DEVICE_OPEN_RATE, DRAIN_RATE,
                    info.rate > DRAIN_RATE * 1.5 and "慢放" or "原速"))
            end

            local written = 0
            local chunk = 4096
            local recover_cnt = 0
            local max_recover = 50
            local zero_cnt = 0
            local max_zero = 300       -- writei 连续返回 0 超过此数，判定卡死并退出
            -- 整体耗时看门狗：写循环若远超音频时长，说明声卡没按预期速率消耗数据（卡死/降速），
            -- 直接退出，避免一句卡住整条朗读链（用户反馈"讲几句后彻底没动静"）。
            -- expect_sec 按【自然时长】（原始帧数/文件速率）计：比值直接反映设备消耗系数——
            -- 语速校正开 → 应≈1.00（原速）；关 + 中继16000 → ≈2.00（半速，v1.31 行为）。
            local expect_sec = natural_frames / (info.rate > 0 and info.rate or DRAIN_RATE)
            local hard_sec = expect_sec * 3 + 15
            local t_start = now()
            -- v1.43：若设备只支持大端格式（need_swap），把小端 WAV 数据交换字节，否则 ALSA 按
            -- 大端解读会高低字节错位 → 宽频噪声。一次性整缓冲交换，写循环不变。
            if alsa_dev.need_swap then
                local nbytes = total_frames * frame_bytes
                local swapped = ffi.new("uint8_t[?]", nbytes)
                local sb = ffi.cast("uint8_t*", src_buf) + src_off
                for i = 0, nbytes - 2, 2 do
                    swapped[i] = sb[i + 1]
                    swapped[i + 1] = sb[i]
                end
                src_buf, src_off = swapped, 0
                log_info("ALSA 已对小端数据做字节交换(适配大端设备) 字节数=" .. nbytes)
            end
        -- v1.68 软件音量增益：写循环前对 16bit 样本乘 cur_volume/100（仅 16bit 路径；
        -- 本机只走 16bit，8/24/32bit 罕见故跳过）。100% 时整段跳过，零开销。
        -- MiuRead 不转发物理音量键，故这是调音量的唯一可靠手段：
        -- 范围已放宽到 0~300%（默认 180%），edge-tts 输出偏弱时靠放大增益提声（乘完按 int16 范围钳制防削波）。
            if cur_volume ~= 100 and info.bits == 16 then
                local ch = info.channels
                local nsamp = total_frames * ch
                local in16 = ffi.cast("int16_t*", ffi.cast("uint8_t*", src_buf) + src_off)
                local out16 = ffi.new("int16_t[?]", nsamp)
                local g = cur_volume / 100
                for i = 0, nsamp - 1 do
                    local vv = in16[i] * g
                    if vv > 32767 then vv = 32767
                    elseif vv < -32768 then vv = -32768 end
                    out16[i] = math.floor(vv + 0.5)
                end
                src_buf, src_off = out16, 0
                log_info(string.format("ALSA 软件音量增益生效: %d%% (samples=%d)", cur_volume, nsamp))
            end
            local src_base = ffi.cast("uint8_t*", src_buf)
            -- v1.68 异步分片播放：用 UIManager 把写循环切成小段，每段之间把控制权交还事件循环，
            -- 播放期间 UI 线程仍能被唤醒（按键 / 暂停 / 翻页）。写满后不再阻塞 drain——
            -- 改为轮询设备「仍在播放」状态（snd_pcm_state==RUNNING=3）来等缓冲放空，
            -- 期间每 50ms 让出一次 UI，保证句尾也不卡界面。单句设备已重开，不跨句复用（规避 XRUN 卡死）。
            pcall(function() asound_lib.snd_pcm_prepare(pcm) end)
            -- v1.74：显式 start 设备，让第一片 writei 立即出声。
            -- 根因：之前只 prepare 不 start，分片写入时首片写到环形缓冲、但 start_threshold
            -- 未达 → 设备不立即出声 → 状态机误判「已放空」提前 finish，把句尾/大半句吞掉
            -- （日志里 比值=实际/预期 普遍只有 0.22~0.88 即此）。预取命中后句间 0s，每句都丢句首，最明显。
            pcall(function() asound_lib.snd_pcm_start(pcm) end)
            local wrote_all = false
            local function step()
                if alsa_stop then
                    log_info("ALSA 收到停止，提前结束")
                    pcall(asound_lib.snd_pcm_drop, pcm)
                    pcall(alsa_close_dev)
                    return finish(false)
                end
                if not alsa_dev or alsa_dev.pcm ~= pcm then
                    log_warn("ALSA 设备已变更/被释放，结束播放")
                    return finish(false)
                end
                if now() - t_start > hard_sec then
                    log_warn(string.format("ALSA 写循环超时（已 %.1fs > 上限 %.1fs），drop 兜底退出避免卡死",
                        now() - t_start, hard_sec))
                    pcall(asound_lib.snd_pcm_drop, pcm)
                    pcall(alsa_close_dev)
                    return finish(false)
                end
                if not wrote_all then
                    local n = (total_frames - written < chunk) and (total_frames - written) or chunk
                    -- 从缓冲区计算指针（保持 info.buf 引用，避免 v1.19 的悬空指针段错误）
                    local ptr = ffi.cast("void*", src_base + src_off + written * frame_bytes)
                    local w = tonumber(asound_lib.snd_pcm_writei(pcm, ptr, n))
                    if w < 0 then
                        -- 阻塞模式负 rc（多为 -EPIPE/-EIO 欠载）：用 snd_pcm_recover 恢复后继续；
                        -- 超过恢复上限则 drop+关闭兜底退出，避免永久阻塞卡死 KOReader。
                        if recover_cnt > max_recover then
                            log_warn("ALSA 欠载恢复超上限，drop 兜底退出 rc=" .. w)
                            pcall(asound_lib.snd_pcm_drop, pcm)
                            pcall(alsa_close_dev)
                            return finish(false)
                        end
                        recover_cnt = recover_cnt + 1
                        pcall(function() asound_lib.snd_pcm_recover(pcm, w, 0) end)
                    elseif w == 0 then
                        zero_cnt = zero_cnt + 1
                        if zero_cnt > max_zero then
                            log_warn("ALSA writei 连续返回 0 超上限，drop 兜底退出（已写 " .. written .. "/" .. total_frames .. "）")
                            pcall(asound_lib.snd_pcm_drop, pcm)
                            pcall(alsa_close_dev)
                            return finish(false)
                        end
                    else
                        written = written + w
                        zero_cnt = 0
                        if written >= total_frames then wrote_all = true end
                    end
                else
                    -- 已写满：等声卡把缓冲真正放空（状态离开 RUNNING=3）即视为播完；
                    -- 持续让出 UI，期间暂停/翻页照常生效。
                    local st = -1
                    pcall(function()
                        if asound_lib.snd_pcm_state then
                            st = tonumber(asound_lib.snd_pcm_state(pcm))
                        end
                    end)
                    if st == 4 then  -- 4=XRUN(欠载)：恢复后继续，不要切断
                        pcall(function() asound_lib.snd_pcm_recover(pcm, 0, 0) end)
                    end
                    -- v1.74：完成判定修正。3=RUNNING(仍在播)、5=DRAINING(正在放空缓冲) 都继续等，
                    -- 4=XRUN 已 recover 继续；这几种若提前 finish 会切断尚未播出的尾段（吞字）。
                    -- 仅 SETUP/PREPARED/CLOSED(1/2/7) 等才视为真正放空。
                    if st == 3 or st == 4 or st == 5 then
                        UIManager:scheduleIn(0, step)
                        return
                    end
                    local used = now() - t_start
                    log_info(string.format("ALSA 播放结束 written=%d/%d recover=%d 实际耗时=%.2fs 预期时长=%.2fs 比值=%.2f",
                        written, total_frames, recover_cnt, used, expect_sec,
                        expect_sec > 0 and (used / expect_sec) or -1))
                    return finish(true)
                end
                UIManager:scheduleIn(0, step)
            end
            UIManager:scheduleIn(0, step)
            -- 立即返回，不阻塞：真正的播放由 step 异步驱动，UI 在此期间可响应按键/暂停/翻页。
        end

        -- 整段朗读结束/停止时调用：释放 ALSA 设备，让系统/其它应用可再用声卡
        local function alsa_close()
            pcall(alsa_close_dev)
        end

        alsa_engine = { play = alsa_play, close = alsa_close }
        probe_log[#probe_log + 1] = "ALSA FFI 可用(libasound 已加载)，已作为原生音频主后端（整段复用单一设备）"
    else
        probe_log[#probe_log + 1] = "ALSA FFI 不可用: " .. asound_err
    end
else
    probe_log[#probe_log + 1] = "require(ffi) 失败，ALSA/SDL 均不可用"
end

-- ============================================================
-- 1) SDL2 FFI 后端（兜底，真机实测 ffi.load 失败，保留以防变种）
-- ============================================================
local sdl_lib_name = nil
if ffi_ok and ffi and not alsa_engine then
    local SDL, sdl_load_err
    local sdl_maps = find_loaded_lib_paths("libSDL")
    if #sdl_maps > 0 then
        probe_log[#probe_log + 1] = "进程内 SDL 库路径=" .. table.concat(sdl_maps, ";")
    end
    local names = { "SDL2", "libSDL2", "SDL", "libSDL" }
    for _, p in ipairs(sdl_maps) do names[#names + 1] = p end
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then SDL = lib; sdl_lib_name = name; break end
    end
    if not SDL then
        sdl_load_err = "ffi.load(SDL*) 失败"
        probe_log[#probe_log + 1] = "SDL FFI 不可用: " .. sdl_load_err
    else
        ffi.cdef[[
            typedef uint32_t SDL_AudioDeviceID;
            typedef struct SDL_AudioSpec {
                int freq; uint16_t format; uint8_t channels; uint8_t silence;
                uint16_t samples; uint16_t padding; uint32_t size;
                void (*callback)(void*, uint8_t*, int); void* userdata;
            } SDL_AudioSpec;
            int  SDL_InitSubSystem(uint32_t flags);
            void SDL_QuitSubSystem(uint32_t flags);
            char* SDL_GetError(void);
            SDL_AudioSpec* SDL_LoadWAV(const char* file, SDL_AudioSpec* spec, uint8_t** audio_buf, uint32_t* audio_len);
            void SDL_FreeWAV(uint8_t* audio_buf);
            SDL_AudioDeviceID SDL_OpenAudioDevice(const char* device, int iscapture, const SDL_AudioSpec* desired, SDL_AudioSpec* obtained, int allowed_changes);
            int  SDL_QueueAudio(SDL_AudioDeviceID dev, const void* data, uint32_t len);
            void SDL_PauseAudioDevice(SDL_AudioDeviceID dev, int pause_on);
            void SDL_CloseAudioDevice(SDL_AudioDeviceID dev);
            uint32_t SDL_GetQueuedAudioSize(SDL_AudioDeviceID dev);
            void SDL_Delay(uint32_t ms);
        ]]
        local function sdl_play(self, path, on_done)
            pcall(function() SDL.InitSubSystem(0x00000010) end)
            local spec = ffi.new("SDL_AudioSpec")
            local buf = ffi.new("uint8_t*[1]")
            local len = ffi.new("uint32_t[1]")
            local loaded = SDL.LoadWAV(path, spec, buf, len)
            if tonumber(ffi.cast("uintptr_t", loaded)) == 0 then
                log_warn("SDL_LoadWAV 失败: " .. ffi.string(SDL.GetError()))
                return false, "LoadWAV"
            end
            local dev = SDL.OpenAudioDevice(nil, 0, spec, nil, 0)
            if dev == 0 then
                local obtained = ffi.new("SDL_AudioSpec")
                dev = SDL.OpenAudioDevice(nil, 0, spec, obtained, 7)
            end
            if dev == 0 then
                SDL.FreeWAV(buf[0])
                return false, "OpenAudioDevice"
            end
            SDL.QueueAudio(dev, buf[0], len[0])
            SDL.PauseAudioDevice(dev, 0)
            local guard = 0
            while tonumber(SDL.GetQueuedAudioSize(dev)) > 0 and guard < 3000 do
                SDL.Delay(20); guard = guard + 1
            end
            SDL.Delay(150)
            SDL.CloseAudioDevice(dev)
            SDL.FreeWAV(buf[0])
            return true
        end
        sdl_engine = { play = sdl_play }
        probe_log[#probe_log + 1] = "SDL FFI 可用(" .. sdl_lib_name .. ")，作为兜底后端"
    end
end

-- ============================================================
-- 2) 标准 KOReader Lua 音频模块（其它变种用，MiuRead 上应全失败）
-- ============================================================
local function list_fn_keys(M)
    local ks = {}
    for k, v in pairs(M) do
        if type(v) == "function" then ks[#ks + 1] = k end
    end
    table.sort(ks)
    return table.concat(ks, ",")
end

local CANDIDATE_MODULES = {
    "ui/sound", "ffi/audio", "audio", "sound", "ui/audio", "ui/tts",
    "tts", "reader/tts", "reader/sound", "reader/audiobook",
    "ffi/SDL2_0", "ffi/SDL", "SDL", "ui/soundmgr", "device/audio",
    "AudioEngine", "audioengine",
}
local PLAY_METHODS = { "play", "playFile", "play_file", "playSound", "playAudio" }
local STOP_METHODS = { "stop", "stopAll", "stop_all", "stopAudio" }

local function detect_internal()
    for _, modname in ipairs(CANDIDATE_MODULES) do
        local ok, M = pcall(require, modname)
        if ok and type(M) == "table" then
            local fns = list_fn_keys(M)
            probe_log[#probe_log + 1] = modname .. " 加载成功，方法=[" .. fns .. "]"
            for _, mn in ipairs(PLAY_METHODS) do
                if type(M[mn]) == "function" then
                    pcall(function() if M.init then M:init() end end)
                    play_method = mn
                    for _, sn in ipairs(STOP_METHODS) do
                        if type(M[sn]) == "function" then stop_method = sn break end
                    end
                    return M, modname .. "." .. mn
                end
            end
        end
    end
    return nil, nil
end

local function detect_cli()
    local candidates = {
        "aplay -q", "madplay -q", "ffplay -nodisp -autoexit -loglevel quiet",
        "mplayer -really-quiet", "gst-play-1.0 --quiet", "play -q",
        "mpg123 -q", "mpv --no-video", "cvlc --play-and-exit -q", "vlc -q",
        "alsaplayer -q", "omxplayer -o local", "paplay", "sox",
    }
    for _, cmd in ipairs(candidates) do
        local bin = cmd:match("^(%S+)")
        local ok = os.execute(string.format('command -v %s >/dev/null 2>&1', bin))
        if ok == true or ok == 0 then return cmd end
    end
    return nil
end

-- 生成本地纯正弦测试音（WAV），用于诊断音频链路本身是否正常（不依赖中继/网络）。
-- 用途（v1.42 音频诊断）：若此音经播放后端出来是「干净 440Hz 蜂鸣」→ 音频链路 OK，
--   之前的噪声来自中继 WAV；若出来是「噪声/静电」→ 自定义 FFI 直写在本机损坏，应改用系统 aplay。
local function gen_tone_wav(path, freq, secs, rate)
    rate = rate or 8000
    secs = secs or 1.5
    freq = freq or 440
    local n = math.floor(rate * secs)
    local function i16le(v)
        if v < 0 then v = v + 65536 end
        v = math.floor(v) % 65536
        return string.char(v % 256, math.floor(v / 256) % 256)
    end
    local function u16le(x) x = math.floor(x) % 65536; return string.char(x % 256, math.floor(x / 256) % 256) end
    local function u32le(x)
        x = math.floor(x) % 4294967296
        return string.char(x % 256, math.floor(x / 256) % 256, math.floor(x / 65536) % 256, math.floor(x / 16777216) % 256)
    end
    local amp = 9000
    local data = {}
    for i = 0, n - 1 do
        local v = math.floor(amp * math.sin(2 * math.pi * freq * i / rate))
        data[#data + 1] = i16le(v)
    end
    local databytes = table.concat(data)
    local dsize = #databytes
    local header = "RIFF" .. u32le(36 + dsize) .. "WAVE"
        .. "fmt " .. u32le(16) .. u16le(1) .. u16le(1) .. u32le(rate)
        .. u32le(rate * 2) .. u16le(2) .. u16le(16)
        .. "data" .. u32le(dsize)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(header .. databytes)
    f:close()
    return true
end

internal_engine, internal_kind = detect_internal()
cli_cmd = detect_cli()

function AudioPlayer:has_espeak()
    local ok = os.execute("command -v espeak >/dev/null 2>&1")
    if ok == true or ok == 0 then return true end
    return false
end

function AudioPlayer:probe_info()
    return table.concat(probe_log, " | ")
        .. " | CLI=" .. (cli_cmd or "无")
        .. " | 内部引擎=" .. (internal_kind or "无")
        .. " | ALSA=" .. (alsa_engine and "可用" or "不可用")
        .. " | SDL2=" .. (sdl_engine and "可用" or "不可用")
end

function AudioPlayer:new(opts)
    opts = opts or {}
    local kind = alsa_engine and "ALSA/ffi"
                or (sdl_engine and ("SDL2/ffi(" .. sdl_lib_name .. ")"))
                or (internal_kind or nil)
    local has_internal = (alsa_engine ~= nil) or (sdl_engine ~= nil) or (internal_engine ~= nil)
    local o = {
        tmpdir = opts.tmpdir or "/tmp",
        pidfile = (opts.tmpdir or "/tmp") .. "/tts_cn.pid",
        player_cmd = cli_cmd or "aplay -q",
        last_path = nil,
        _busy = false,
        has_internal_player = has_internal,
        internal_kind = kind,
    }
    setmetatable(o, { __index = self })
    return o
end

local function shell_escape(s)
    return (s:gsub('"', '\\"'))
end

-- 通过 ALSA / SDL2 / 内部音频引擎播放。
-- v1.68：ALSA 后端改为异步分片播放（play 内部用 UIManager 调度，立即返回，由 on_done 回报完成）；
-- 故此处只负责「发起播放 + 设置 busy 标志」，busy 的复位由播放回调(finish)完成，调用方不得提前清零。
-- on_done(ok) 在播放真正结束/停止时回调，供上层（如 _wait_and_cb 轮询）感知结束。
function AudioPlayer:play_internal(path, on_done)
    if alsa_engine then
        self._busy = true
        local ok, err = pcall(alsa_engine.play, self, path, on_done)
        if not ok then
            self._busy = false
            log_warn("ALSA 播放异常: " .. tostring(err))
            if on_done then pcall(on_done, false) end
            return false, tostring(err)
        end
        return true
    end
    if sdl_engine then
        self._busy = true
        local ok, err = pcall(sdl_engine.play, self, path, on_done)
        self._busy = false
        if not ok then
            log_warn("SDL 播放异常: " .. tostring(err))
            if on_done then pcall(on_done, false) end
            return false, tostring(err)
        end
        if on_done then pcall(on_done, true) end
        return true
    end
    if not internal_engine or not play_method then
        if on_done then pcall(on_done, false) end
        return false, "no internal engine"
    end
    self._busy = true
    local ok, err = pcall(function() internal_engine[play_method](internal_engine, path) end)
    self._busy = false
    if not ok then
        if on_done then pcall(on_done, false) end
        return false, tostring(err)
    end
    if on_done then pcall(on_done, true) end
    return true
end

function AudioPlayer:play_cli(path)
    -- v1.42：同步播放（阻塞到句尾），保证逐句顺序；aplay/ffplay 等走 alsa-utils 官方路径，
    -- 对同一 libasound 驱动比手搓 FFI snd_pcm_writei 正确得多。stderr 丢弃避免刷屏。
    -- 之所以不再后台化：正常朗读是逐句调度，同步返回即可保持句序；后台化反而会让句子重叠。
    local cmd = string.format('%s "%s" >/dev/null 2>&1',
        self.player_cmd, path)
    os.execute(cmd)
    return true
end

function AudioPlayer:play_espeak(text, voice, rate, pitch, volume)
    voice = voice or "zh"
    rate = rate or 160
    pitch = pitch or 50
    volume = volume or 100
    local safe = shell_escape(text)
    local cmd = string.format(
        'espeak -v %s -s %d -p %d -a %d "%s" >/dev/null 2>&1 & echo $! > %s',
        voice, rate, pitch, volume, safe, self.pidfile)
    os.execute(cmd)
end

-- 播放临时音频：v1.43 起 ALSA FFI 仍是本机唯一可用后端（实测本机 CLI=无、SDL2=不可用、无内部引擎），
-- 故 FFI 直写必须可用。v1.42 误判 FFI 直写「损坏」——其实 FFI 没坏，坏的是【采样格式字节序】：
-- 旧代码把 16bit 格式写成 S16_BE(3)，却喂小端 WAV 字节，导致高低字节错位成宽频噪声。
-- v1.43 已把格式修正为 S16_LE(2) 并做字节序自适应，FFI 直写恢复正常干净出声；CLI 播放器若存在则优先。
function AudioPlayer:play_file(path)
    self.last_path = path
    if cli_cmd then
        log_info("音频后端：CLI(" .. self.player_cmd .. ") 播放 " .. path)
        self:play_cli(path)
        return
    end
    if alsa_engine or sdl_engine or internal_engine then
        local ok, err = self:play_internal(path)
        if ok then return end
        log_warn("内部/FFI 音频引擎播放失败(" .. tostring(self.internal_kind)
            .. ")，且无 CLI 播放器可回退: " .. tostring(err))
    else
        log_warn("无可用音频后端（CLI/ALSA/SDL/内部引擎均缺失），无法出声")
    end
end

function AudioPlayer:_clean_last()
    if self.last_path and self.last_path ~= "" then
        pcall(function() os.remove(self.last_path) end)
        self.last_path = nil
    end
end

-- 整段朗读结束/停止：释放 ALSA 设备（v1.23 新增，设备改为整段复用）
function AudioPlayer:close_alsa()
    if alsa_engine and alsa_engine.close then
        pcall(alsa_engine.close)
    end
end

-- v1.41「语速校正」实时开关：朗读中即可切换，下一句立即生效（无需重启/重开设备）。
-- 详见 audioplayer 内 DRAIN_RATE/DEVICE_OPEN_RATE 模型注释。
function AudioPlayer:set_speed_fix(v)
    speed_fix_on = v and true or false
end

-- v1.53 软件音量：把增益百分比写入播放器，下一句起生效（写循环前对 16bit 样本乘系数，不重开设备）。
-- MiuRead 不转发物理音量键，故这是降音量的唯一可靠手段。
function AudioPlayer:set_volume(v)
    local n = tonumber(v)
    if not n then n = 100 end
    if n < 0 then n = 0 elseif n > 300 then n = 300 end
    cur_volume = n
end

-- v1.43 音频诊断：播放一段本地生成的 440Hz 纯正弦音，用于确认音频链路本身是否正常（不依赖中继/网络）。
-- 调用路径与正常朗读完全一致（走 play_file 的同一后端选择），故结果可直接代表真实出声能力。
-- 干净蜂鸣 → 音频链路 OK（若朗读仍噪声，则问题在中继 WAV/edge-tts）；噪声 → 仍有字节序/格式问题待查。
function AudioPlayer:diagnostic_tone()
    local path = (self.tmpdir or "/tmp") .. "/tts_cn_tone.wav"
    local ok = gen_tone_wav(path, 440, 1.5, 16000)
    if not ok then
        log_warn("音频诊断：测试音 WAV 生成失败")
        return false, "gen"
    end
    local backend = cli_cmd and ("CLI(" .. self.player_cmd .. ")") or "FFI"
    log_info("音频诊断：开始播放 440Hz 测试音 → " .. path .. " 后端=" .. backend)
    self:play_file(path)
    log_info("音频诊断：测试音播放结束。请确认听到的是【干净 440Hz 蜂鸣】还是【噪声】；"
        .. "并把本段日志贴回。后端=" .. backend)
    return true
end

function AudioPlayer:stop()
    alsa_stop = true
    if sdl_engine then
        -- SDL 同步播放无法中断，alsa_stop 机制不适用，停止在句间生效
    end
    if internal_engine and stop_method then
        pcall(function() internal_engine[stop_method](internal_engine) end)
    end
    os.execute(string.format('kill "$(cat %s)" 2>/dev/null', self.pidfile))
    self:_clean_last()
end

function AudioPlayer:is_playing()
    if alsa_engine or sdl_engine then
        return self._busy
    end
    if internal_engine and play_method then
        for _, mn in ipairs({ "isPlaying", "is_playing", "isPlayingFile" }) do
            if type(internal_engine[mn]) == "function" then
                local ok, v = pcall(function() return internal_engine[mn](internal_engine) end)
                if ok and type(v) == "boolean" then
                    if not v then self:_clean_last() end
                    return v
                end
            end
        end
        return true
    end
    local f = io.open(self.pidfile, "r")
    if not f then return false end
    local pid = f:read("*a")
    f:close()
    pid = pid and pid:match("%d+")
    if not pid then return false end
    -- v1.72：用 /proc 存在性检查替代 os.execute('kill -0')。
    -- 旧写法在每 0.2s 的播放轮询里 fork 一个 /bin/sh，弱 CPU 上单次 100-300ms，
    -- 主线程一半时间被吞掉——这是「朗读时翻页卡顿、按 P 无响应」的主要元凶之一。
    local pf = io.open("/proc/" .. pid .. "/stat", "r")
    if pf then pf:close() return true end
    return false
end

-- 加载成功横幅：crash.log 里若有这行，说明 audioplayer.lua 顺利通过加载期
-- （cdef/ffi.load 等全没炸）；若只有 main 的 init 横幅而没有这行，说明加载期失败，
-- 结合 safe_require 的失败日志即可定位原因。
log_info("audioplayer.lua 加载成功")

return AudioPlayer
