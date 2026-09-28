# TTS 中继云端部署指南（抛弃手机 Termux）

目标：把 `tts_relay_android.py` 部署到免费云平台，**手机彻底不用参与**，
Kindle 直接填一个公网 `https://...` 地址即可朗读。

> 前提：有个 GitHub 账号，且已把本目录（含 `tts_relay_android.py` / `requirements.txt` /
> `Dockerfile` / `render.yaml`）推送到一个 GitHub 仓库。

---

## 一键部署按钮（推荐放在你的 GitHub README，让别人零门槛用自己的实例）

把下面两行放进仓库 README，**别人点一下就自动 fork + 部署自己的实例**，
无需手动建仓库（仍是「各自自建」模式，隐私/免费都保留，只是门槛降到一次点击）：

```markdown
[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/YOUR_USERNAME/tts-relay)

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template?template=https://github.com/YOUR_USERNAME/tts-relay)
```

> 把 `YOUR_USERNAME` 换成你的 GitHub 用户名、仓库名换成实际名（默认 `tts-relay`）。
> Render 按钮最稳；Railway 按钮依赖仓库里的 `Dockerfile` 自动识别构建。

## 方式 A：Render（最省心，推荐）

1. 打开 https://render.com ，用 GitHub 登录。
2. 右上角 **New** → **Web Service** → 选择你刚推的仓库。
3. 配置：
   - **Name**：随便（如 `tts-relay`）
   - **Runtime**：保持 Python（Render 会自动读 `render.yaml`，Build 命令里已含装 ffmpeg）
   - **Plan**：选 **Free**
   - 其余默认，点 **Create Web Service**。
4. 等 1–2 分钟构建完成，页面会显示一个地址，形如：
   `https://tts-relay-xxxx.onrender.com`
5. 打开这个地址（后面加 `/`）就是**控制台**：能看到 Kindle 请求数、能试听。

> 注意：Render 免费层 **15 分钟无请求会休眠**，下次请求要等约 10–30 秒「唤醒」。
> 这是正常的，Kindle 端超时已调到 60 秒，唤醒期间第一句可能稍慢，之后就正常。

---

## 方式 B：Railway（也免费，用 Dockerfile）

1. 打开 https://railway.app ，用 GitHub 登录。
2. **New Project** → **Deploy from GitHub repo** → 选本仓库。
3. Railway 检测到 `Dockerfile`，自动构建（镜像里已含 ffmpeg）。
4. 部署完成后点 **Settings** → **Networking** 生成公开域名，形如：
   `https://tts-relay-xxxx.up.railway.app`
5. 打开该域名 `/` 即控制台。Railway 免费层闲置也会休眠，行为同 Render。

---

## Kindle 端填地址

阅读器菜单 → **中文朗读 → 设置 → 在线接口**，填：

```
https://你的域名/tts?voice=zh-CN-XiaoxiaoNeural&text={text}
```

- 把 `https://你的域名` 换成实际拿到的地址（Render/Railway 给的）。
- 保留结尾的 `{text}` 占位符，插件会逐句替换。
- 后端选 **在线**。

控制台地址 = 上面的域名（末尾不加 `/tts`，直接打开就是控制台网页）。

---

## 想要「原速」而不是「慢一倍」

本地 Kindle 硬件时钟锁死约 8000Hz，中继发 16000Hz 数据会被系统下采样成慢一倍。
最稳的提速方式是在**中继端**（云端）让 edge-tts 直接说快一倍，正好抵消：

- Render：在 Web Service → **Environment** 里加变量 `TTS_RATE = +100%`，Save 后自动重启。
- Railway：项目 **Variables** 里加 `TTS_RATE = +100%`。
- 或不改环境变量，Kindle 接口地址加 `&rate=+100%` 也行。

> `TTS_RATE` 合法范围 `+0%` ~ `+100%`，填 `+100%` 即内容快一倍、弥补设备半速 → 整体原速且干净。
> 这是中继端调速，不碰 Kindle 播放逻辑，比之前在 Kindle 端做降采样稳得多（那次会卡死）。

---

## 本地兜底（不想上云 / 临时用）

```bash
pip install -r requirements.txt
# 系统还需装 ffmpeg：
#   macOS:  brew install ffmpeg
#   Debian/Ubuntu:  sudo apt-get install ffmpeg
#   Termux:  pkg install ffmpeg
python tts_relay_android.py
```

脚本会打印本机地址（如 `http://192.168.x.x:5000`），Kindle 填这个即可。
`relay.sh` 是 Termux 下的启动脚本（start/stop/restart/status/log），本地想用也可。

---

## 控制台能做什么

打开 `<域名>/`：

- **服务地址**：直接复制整行填进 Kindle。
- **Kindle 累计请求数**：每次读一句 +1，刷新即可确认连接是否活着。
- **测试朗读**：输入中文点「试听」，不用 Kindle 就能确认音色/语速。

部署后若 Kindle 没声音：先看控制台的请求数是否在涨（确认连接到云端），
再看平台日志里有没有 `edge-tts failed` / `ffmpeg` 相关报错。
