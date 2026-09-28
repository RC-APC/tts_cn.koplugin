# 手机 / 本机中继（relay）

把 `tts_relay_android.py` 跑起来，Kindle 就能通过局域网 HTTP 拉到中文语音 WAV。

## 依赖

- Python 3.8+
- `ffmpeg`（转码 mp3 → WAV，Kindle 端用 ALSA 直写）
- `flask`、`edge-tts`

```bash
pip install -r requirements.txt
```

## Termux 一键流程（推荐手机端）

```bash
# 把本目录拷到手机 ~/tts_relay，然后：
bash relay.sh setup     # pkg 装 python/ffmpeg/termux-tools；pip 装 edge-tts/flask；开唤醒锁
bash relay.sh start     # 后台常驻（setsid nohup），打印 Kindle 要填的地址
```

`relay.sh` 子命令：`setup` / `start` / `stop` / `restart` / `status` / `log` / `test`。

## 本机 / 服务器（非 Termux）

```bash
pip install -r requirements.txt
python tts_relay_android.py
# 或自定义端口 / 采样率：
PORT=8080 TTS_WAV_RATE=22050 python tts_relay_android.py
```

## Kindle 要填的地址

控制台（`http://手机IP:5000/`）和启动日志都会打印：

```
http://<手机IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}
```

填进 Kindle：`中文朗读 → 设置 → 在线接口地址`，保留 `{text}`（和 `{voice}`）占位符。

## 环境变量

| 变量 | 含义 | 默认 |
|------|------|------|
| `PORT` | 监听端口 | `5000` |
| `TTS_WAV_RATE` | 输出 WAV 采样率（Kindle 3 用 `16000` 干净；**勿用 8000**） | `16000` |
| `TTS_RATE` | 默认语速，edge-tts 格式 | `+0%` |
| `PUBLIC_URL` | 强制覆盖控制台显示的基础地址 | 自动取本机 IP |

## ⚠️ 背景保活（最小化后 Kindle 收不到请求）

**现象**：Termux 浮窗时能正常朗读，一最小化/切到别的 App，Kindle 端就卡住收不到音频。
**原因**：Android 后台执行限制（Doze + 电池优化），不是代码 bug。App 进后台后系统挂起它的 CPU/网络。

按优先级处理（前两步通常就够）：

1. **关闭 Termux 的电池优化（最关键）**
   系统设置 → 应用 → Termux → 电池/省电优化 → 设为「不限制 / 不受优化」。
   小米/三星/OPPO 等还有厂商自带的「神隐模式 / 内存加速 / 自启动管理」，把 Termux 加进白名单。
2. **装 Termux:API（F-Droid）** → `relay.sh` 已自动调用 `termux-wake-lock` 持 partial wakelock，降低被挂起概率。
3. **Termux:Boot** → 开机自启，作为系统拉起的后台进程更抗杀。
4. **Termux:Float** → 常驻浮窗，始终前台，最稳但占屏幕。
5. **仍不稳定 / 想"最小化就忘掉"** → 做成 **APK 前台服务（带常驻通知）** 才是根治方案：前台服务系统不敢随意杀，最小化、锁屏都持续收请求。

> 判断标准：能接受"手机留个浮窗/关电池优化" → 用本中继；想彻底无感后台 → 走 APK 前台服务。
