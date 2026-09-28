# PythonAnywhere 部署：纯 HTTP 云端 TTS 中继

**目标**：让 Kindle 3 不依赖手机中继也能朗读。
**原理**：Kindle 3 的 TLS 栈坏，`https://` 一律连不上；PythonAnywhere 提供**纯 HTTP** 域名（`http://用户名.pythonanywhere.com`），Kindle 3 可以直接访问，且**不用绑信用卡**。

---

## 0. 先知道风险（第 6 步会验证）

PythonAnywhere **免费版有外网白名单**：只能访问白名单内的网站，付费版才无限制。
edge-tts 需要连微软语音服务，可能不在白名单里。

所以第 6 步的 `/selftest` 是**必须做**的判死测试：
- ✅ 通过 → 直接用
- ❌ 报 Connection/Timeout/Forbidden → 被白名单拦了 → 换 **alwaysdata.com**（免费版，同样支持纯 HTTP、不用卡），或升级 PythonAnywhere 付费版

---

## 1. 注册

https://www.pythonanywhere.com → 注册 **Beginner (free)** 账号，**记住你的用户名**（下面统称 `USERNAME`）。

## 2. 装依赖

打开 **Consoles → Bash**，执行：

```bash
pip3 install --user -r requirements-cloud.txt
```

（等价：`pip3 install --user edge-tts flask av numpy`）

## 3. 建 Web 应用

**Web** 页 → **Add a new web app** → 选 **Manual configuration** → 选 **Python 3.10**（或更高）。

## 4. 上传代码

**Files** 页 → 把 `tts_relay_cloud.py` 上传到 `/home/USERNAME/`

## 5. 改 WSGI 配置

**Web** 页往下滚，点 WSGI configuration file
（路径 `/var/www/USERNAME_pythonanywhere_com_wsgi.py`），**删掉全部内容**，改成下面三行：

```python
import sys
sys.path.insert(0, '/home/USERNAME')
from tts_relay_cloud import app as application
```

> 把 `USERNAME` 换成你自己的用户名。

点 **Save**，再点绿色的 **Reload**。

## 6. 判死自检（关键）

浏览器打开：

```
http://USERNAME.pythonanywhere.com/selftest
```

- 显示 **✅ 自检通过（x.x s，xxxxx 字节，16000Hz）** → 成功，继续第 7 步
- 显示 ❌ 且含 `Connection` / `Timeout` / `Forbidden` / `403` → **免费版白名单拦住了微软语音服务**
  → 换 alwaysdata.com（免费、纯 HTTP、不用卡），或升级 PythonAnywhere 付费版
- 显示 ❌ 且含 `av失败` → 回 Bash 重跑 `pip3 install --user av numpy`

## 7. Kindle 填地址

```
http://USERNAME.pythonanywhere.com/tts?voice=zh-CN-XiaoxiaoNeural&text={text}
```

由于 Kindle 上调不出软键盘，**把你的 USERNAME 发给我，我直接把地址写进插件默认值**（v1.68），你装完就能用，无需输入。

---

## 注意事项

| 事项 | 说明 |
|---|---|
| 必须是 `http` | 不要填 `https`——Kindle 3 的 TLS 栈坏，https 必失败 |
| 免费版会休眠 | 一段时间无访问会休眠，先用手机浏览器打开首页唤醒，Kindle 再朗读 |
| 插件别乱改地址 | v1.67 起自动纠偏只拦 `https://`，纯 HTTP 域名不会再被改回局域网 IP |
| 输出 16000Hz | 本地版实测的"干净路"；8000Hz 直出会全程吱吱，别改 |
| 控制台首页 | 打开 `http://USERNAME.pythonanywhere.com/` 可在线试听、看 Kindle 请求计数 |
