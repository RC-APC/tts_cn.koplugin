# alwaysdata 部署指南（纯 HTTP 云端中继，绕开 Kindle 3 的 TLS 死穴）

## 为什么选 alwaysdata

- **免费、不绑卡**（PythonAnywhere 免费版有出站白名单，拦微软语音服务，已判死）
- **无出站访问限制**：edge-tts 能连微软服务
- **`http://用户名.alwaysdata.net` 支持纯 HTTP**：Kindle 3 只需 HTTP，不需要 TLS
- 支持 Python WSGI + virtualenv

## 部署步骤

### 1. 注册

https://www.alwaysdata.com → 注册 **Free** 套餐（不绑卡）。
记住用户名，你的站点地址就是 `http://用户名.alwaysdata.net`。

### 2. 装依赖（SSH 或 Web 的 Bash console）

alwaysdata 的 Bash console：管理后台 → Remote → SSH / console。
（把 `你的用户名` 换成实际值）

```bash
python3 -m venv ~/venv
~/venv/bin/pip install flask edge-tts av
```

> 免费版磁盘有限，装完可执行 `~/venv/bin/pip cache purge` 清缓存。

### 3. 上传两个文件到 `~/www/`

- `tts_relay_cloud.py`（主程序）
- `wsgi.py`（WSGI 入口，已配好路径）

没有文件管理器的话用 SFTP（FileZilla，主机 `sftp-ssh.alwaysdata.net`，端口 22），
或在 console 里 `cd ~/www && nano tts_relay_cloud.py` 粘贴保存。

### 4. 建 Web 站点

管理后台 → **Web → Sites → Add a site**：

| 字段 | 填写 |
|---|---|
| Address | 留默认（你的用户名.alwaysdata.net） |
| Type | **Python** |
| Python version | 选最新的 3.x |
| Application file / WSGI file | `www/wsgi.py` |
| Virtualenv | `venv` |

保存后点 **重启（Restart）**。

### 5. 判死测试（浏览器）

先开自检（顺便验证出站白名单没拦微软）：

```
http://你的用户名.alwaysdata.net/selftest
```

- `{"ok":true,...}` → **成了**，继续第 6 步
- 超时/500 → 看返回的错误信息发我

再测真实朗读（浏览器会下载一段 wav）：

```
http://你的用户名.alwaysdata.net/tts?voice=zh-CN-XiaoxiaoNeural&text=你好世界
```

### 6. Kindle 3 侧

**不用手打域名**——把你的 alwaysdata 用户名告诉我，我把
`http://用户名.alwaysdata.net/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`
直接写进插件默认地址（v1.68），装上即用。

## 常见问题

- **冷启动慢**：WSGI 进程空闲会被回收，第一句可能等 5~10 秒，之后正常
- **内存 256MB**：短句合成没问题；别一次合成超长文本（插件本身就是逐句发的，天然满足）
- **免费版限制**：仅限个人非营利使用，只跑这一个朗读中继完全合规
