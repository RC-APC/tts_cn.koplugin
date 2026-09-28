# tts_cn —— KOReader 中文朗读插件（高质量断句 + 可插拔 TTS）

在 Kindle 3 这类弱硬件（532MHz ARM11、无 FPU）上，本地神经 TTS（Piper / sane-tts）
无法实时运行。本插件走另一条路：**把"断句"和"发声"解耦**，断句在设备本地做（纯 Lua、
零依赖、中文优先），发声则可插拔：

- **espeak（本地离线）**：设备装好 espeak 即可直接朗读，免费、零网络，但音色偏机械；
  靠高质量断句 + 语速/音调/音量调节改善听感。
- **http 在线流式（好音色）**：把每一句发到可配置的 TTS 接口（自建 Piper 服务器 /
  Edge-TTS 中继 / Azure 等），服务器返回音频，设备只负责播放。音质接近真人，
  只需 WiFi + 一个 TTS 服务，本地 CPU 几乎零负担。

在线不可达时**自动回退 espeak**，所以离线也能用。

---

## 一、安装

把整个 `tts_cn.koplugin/` 目录拷到 KOReader 的插件目录，重启 KOReader：

```
koreader/plugins/tts_cn.koplugin/
```

目录结构：

```
tts_cn.koplugin/
├── _meta.lua          # 元信息
├── main.lua           # 插件入口（注册菜单、朗读循环、翻页、高亮）
├── segmenter.lua      # 断句核心（纯 Lua，可独立测试）
├── ttsengine.lua      # TTS 后端管理（espeak / http 流式）
├── audioplayer.lua    # Kindle 音频播放封装（espeak / 临时文件）
├── configdialog.lua   # 设置界面
└── README.md
```

## 二、去哪找到它（重要）

本插件是**阅读器插件**，入口**只在「打开一本书之后」的阅读器菜单里**，不在书架、也不在插件管理界面。所以在插件管理里能看到它、但在书架里找不到是正常的。

**操作路径：**
1. 用 KOReader 打开任意一本书（ePub / PDF / TXT 等）。
2. 调出阅读器菜单：
   - 触屏设备：点屏幕**顶部**或**中央**区域。
   - Kindle 3 等按键设备：按机身 **Menu** 键（或五向键中央）。
3. 在菜单里找到 **「更多工具」** 分组，里面有一项 **「开始朗读 / 停止朗读」**（直接可点），以及一项 **「中文朗读」**（子菜单，含「暂停/继续」「设置」「当前后端」）。
   - 未打开书（书架界面）时，这两项是灰的（没有文档可朗读），属正常；打开书后变亮。
4. 点「开始朗读」即逐句朗读；再点一次停止。Kindle 3 上也可直接按键盘 **G** 键开始/停止。
5. 想先配置后端或在线接口：阅读器菜单里点「中文朗读 → 设置」，或书架界面的「更多工具 → 中文朗读 → 设置」。

> 如果打开书并调出菜单、进入「更多工具」后仍看不到「中文朗读 / 开始朗读」，说明插件没被 KOReader 正确加载——请把 KOReader 的 `crash.log` / 启动日志里与本插件相关的报错发我（或开启 KOReader 的 debug 模式看日志），我再针对性修。常见原因：插件目录名不是 `tts_cn.koplugin`、或 `main.lua` 有加载错误。

---

## 三、Kindle 3 音频注意事项

1. **需要音频输出**：Kindle 3 有 3.5mm 耳机孔；蓝牙版另说。KOReader 通过 KUAL 启动。
2. **espeak**：设备需有 `espeak`（及中文语音数据）。Kindle 上通常随 KOReader 的
   TTS 支持附带，或用 `espeak-ng`。若缺失，菜单朗读会无声——先确认 SSH 进设备能跑
   `espeak -v zh "测试"` 出声。
3. **在线后端的解码器（v1.8 起无需 aplay）**：插件优先使用 **KOReader 内置音频引擎**
   （`ui/sound`，即翻页声/听书所用的 SDL 通道）直接播放服务器返回的 **WAV**，
   因此即使设备没有 `aplay`/`ffmpeg`/`madplay` 也能正常出声。
   - 推荐中继服务直接输出 **WAV**（本项目附带的 `tts_relay_android.py` 已转码为 WAV）。
   - 仅当内置引擎不可用（极老版本/特殊构建）时，才回退到设置里的「在线音频播放命令」
     （如 `aplay -q` / `ffmpeg -i %s -f alsa default` / `madplay %s`）。
   - 想确认用的是哪种后端：开始朗读前看 KOReader 日志里
     `[tts_cn] 音频后端：KOReader 内置引擎（无需 aplay）` 即成功。
4. **音量**：espeak 的 `-a` 参数（0-200）和播放器音量是两个概念；如设备侧音量过小，
   调设置里的「音量」或系统音量。

---

## 四、配置在线流式 TTS（拿到"好音色"）

设置 → **在线接口地址** 填一个模板，用 `{text}` 和 `{voice}` 占位：

```
http://192.168.1.100:5000/tts?voice={voice}&text={text}
```

- GET：直接拼 URL（中文会自动百分比编码）。
- POST：把 `{ "text": "...", "voice": "..." }` 以 JSON 发出，`http_url` 里可不写 `{text}`。

返回 `audio/*` 二进制即可（WAV 最省事）。HTTP 非 200 或网络失败 → 自动回退 espeak。

### 自建一个中继服务的示例（任选）

**方案 A：Edge-TTS（Windows / 有网的机器，真人中文音色，免费）**

```python
# pip install edge-tts flask
import asyncio, edge_tts, flask
app = flask.Flask(__name__)

@app.route("/tts")
def tts():
    text = flask.request.args.get("text", "")
    voice = flask.request.args.get("voice", "zh-CN-XiaoxiaoNeural")
    async def gen():
        comm = edge_tts.Communicate(text, voice)
        # 直接流式返回，无需落盘
        return await comm.stream()
    # 简单起见这里落盘再回传（生产可流式）
    import tempfile, os
    path = tempfile.mktemp(suffix=".mp3")
    asyncio.run(edge_tts.Communicate(text, voice).save(path))
    return flask.send_file(path, mimetype="audio/mpeg")
app.run(host="0.0.0.0", port=5000)
```

插件里把 `voice` 设成 `zh-CN-XiaoxiaoNeural`，「在线音频播放命令」设成 `ffmpeg -i %s -f alsa default`。

**方案 B：自托管 Piper（Linux 服务器，本地神经 TTS，断网也好用）**

用 `piper` 起一个 HTTP 服务（社区已有 `piper-http` 之类封装），让它输出 WAV，
插件「在线音频播放命令」保持默认 `aplay -q` 即可。

---

## 五、断句规则（segmenter.lua）

中文为主、英文作为纯英文书支持：

1. 保护 URL / 邮箱，里面的 `.` `?` 不触发断句。
2. 强句末 `。！？!?` 断句（保留标点）。
3. 软句末 `；;` 断句。
4. `……` `——` `，` `、` `：` 及空格为句内停顿；仅当单句超过 `max_len`（默认 80）
   时才在上一个停顿处软断，避免一口气读过长。
5. CJK 引号/括号配对：句末标点若落在未闭合引号/括号内不切，闭合后再补断。
6. 英文缩写 `Mr. Dr. e.g. i.e. etc. fig.` 与首字母缩写 `U.S. J.K.` 不误断。
7. 小数 `3.14` 不误断。
8. ASCII 引号不视为引号（避免 `don't` 误判）。

参考实现与单元测试见仓库 `tests/test_segmenter.py`（Python，已全绿），
Lua 版为逐行移植，逻辑一致。

---

## 六、已知限制 / 待设备验证

- `getPageText` 在 PDF（无文本层）/ DjVu 上可能取不到文字 → 该页跳过。
- `onGotoNextPage` 翻页接口与 `setHighlight` 高亮偏移依赖具体 KOReader 版本；
  均已 `pcall` 保护，缺失时降级（高亮失败会自动关闭，不影响朗读）。
- 高亮为 best-effort：句中文字在文档内部文本索引与 `getPageText` 返回串不完全一致时，
  高亮位置可能偏移。
- 朗读以"句"为粒度响应暂停/停止（句间检查标志），非逐字中断。

---

## 七、测试

```bash
cd tests && python3 test_segmenter.py   # 验证断句算法（Python 参考实现）
```

Lua 版断句逻辑与该参考实现一致；真机/KOReader 内联调请在设备上验证音频链路。
