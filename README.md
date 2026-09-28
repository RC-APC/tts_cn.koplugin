# kindle-tts-cn

为 **Kindle（含老款 Kindle 3）+ KOReader** 做的中文朗读插件，配合一个**手机 / 云端语音中继**，把微软 edge-tts 的真人中文音色转成 WAV 喂给设备播放。

> 设备端零依赖（只需 KOReader 的 Lua）；语音合成放在手机或云端完成，Kindle 只负责取文、朗读、翻页。

---

## 特性

- 高质量中文断句（自写 `segmenter`），按句朗读、自动翻页、句内高亮。
- 暂停 / 继续 / 停止，支持菜单与快捷键（Kindle 3 实体键可用）。
- 在线后端走 edge-tts（免费真人音色：晓晓 / 云希 / 云扬等），离线后端可选 espeak。
- 文本清洗：自动剔除取文混入的乱码（如孤立断字节 `0x9C` 编码出的 `%9C`）、HTML 实体。
- 设置全菜单化：音量 / 语速 / 音调 / 长句阈值 / 音色 / 中继地址均可用 5-way 按键加减，无需软键盘。

---

## 架构

```
┌─────────────┐    HTTP GET /tts?voice=&text=    ┌──────────────────┐
│ Kindle 3    │ ───────────────────────────────▶ │ 手机 / 云端 中继   │
│ KOReader    │ ◀─────────────────────────────── │ (Flask+edge-tts) │
│ tts_cn 插件 │    WAV (16bit PCM @16000)        └──────────────────┘
└─────────────┘
```

- **Kindle 端**：`tts_cn.koplugin/`（本仓库的 KOReader 插件）。
- **中继端**：`relay/`（手机 Termux 或任意能跑 Python 的机器），或 `relay/cloud/`（Railway / Render / PythonAnywhere 等公网部署）。

---

## 快速开始

### 1. Kindle 安装插件

```bash
# 把 tts_cn.koplugin 整个目录拷到 KOReader 的插件目录，例如
cp -r tts_cn.koplugin /mnt/us/extensions/   # 具体路径视 KOReader 版本而定
```

重启 KOReader → 阅读界面菜单 → 「中文朗读」→ 开始朗读。
首次使用在「设置」里填好中继地址（见下）。

### 2. 手机中继（Termux，最简单，私网）

```bash
# 手机装 Termux（F-Droid 版）+ Termux:API，把 relay/ 拷到 ~/tts_relay
cp -r relay ~/tts_relay
cd ~/tts_relay
bash relay.sh setup     # 装 python/ffmpeg/edge-tts/flask + 唤醒锁
bash relay.sh start     # 后台常驻，打印要填进 Kindle 的地址
```

把打印出的地址（形如 `http://手机IP:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`）填进
Kindle：`中文朗读 → 设置 → 在线接口地址`，后端选「在线」。

> ⚠️ **背景保活**：Android 会把后台 Termux 挂起/断网，导致 Kindle 收不到请求。
> 务必在系统设置里把 **Termux 的电池优化关掉**（加白名单）；详见 [`relay/README.md`](relay/README.md)。
> 想彻底无感后台，可做成 APK 前台服务（见仓库 Issues / 后续计划）。

### 3. 云端部署（手机彻底不用）

按 `deploy/` 下的平台文档把 `relay/cloud/` 部署到免费云平台，Kindle 填公网 `https` 地址即可。
详见 [`deploy/DEPLOY.md`](deploy/DEPLOY.md)。

---

## 目录结构

```
kindle-tts-cn/
├── tts_cn.koplugin/      # Kindle 端 KOReader 插件（Lua）
├── relay/                # 手机 / 本机中继
│   ├── tts_relay_android.py   # 中继本体（Flask + edge-tts）
│   ├── relay.sh               # 单窗口控制：setup/start/stop/status/log/test
│   ├── requirements.txt
│   └── README.md              # Termux 流程 + 背景保活
├── relay/cloud/          # 云端部署版中继 + 平台配置
├── deploy/               # 各云平台部署文档
├── tests/                # 断句等单元测试
└── README.md
```

---

## 许可证

[MIT](LICENSE)。插件可自由修改、分发；中继代码同理。
