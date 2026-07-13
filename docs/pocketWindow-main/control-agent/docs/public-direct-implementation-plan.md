# 公网直连（P2P over NAS 端口转发）实施清单

> 这份清单是本次会话验证后留下的接力文档。下次开工时按顺序执行即可。
>
> 状态约定：[ ] 未做 · [/] 进行中 · [x] 已做
> 风险约定：⚠ 改动大 · ★ 必须按顺序 · ◆ 单文件 slot 模块（可独立替换）

---

## 0. 目标

- 让 PocketWindow 桌面端支持**公网直连模式**：监听 `0.0.0.0:<5 位冷门端口>`，通过用户已经在 NAS 上配好的 frpc 端口转发，被外网手机直连。
- 直连流量不经过 `signal.167183.xyz` 这台公网信令服务器，速度上限从服务器带宽提升到家庭上行带宽。
- 兜底保留：直连失败自动回落到信令服务器路径。
- 安全：TOTP 动态码防嗅探、文件下载白名单、新 IP 弹窗确认。

## 1. 当前基线

- Git HEAD: `3443efd fix mobile foreground video recovery`（git 干净，未暂存改动）
- 桌面端版本: `1.1.118 build 118`（control-agent/version.json）
- 手机端版本: `1.2.14 build 214`（flutter-client/pubspec.yaml 实际最新）
- 本会话已完成：
  - ◆ `control-agent/src/totp_auth.py`（TOTP 槽模块，已通过 .codex_tmp/check_totp.py 10 项验证）
  - NAS 登录通道：plink + PowerShell + 密码文件，存长期记忆 `nas.main.ssh_howto`
  - 更新服务器 API：`POST http://192.168.31.77:58080/admin/releases/upload`
  - 备份目录：`/vol3/1000/soft`（pscp 上传）

## 2. 改动清单（按顺序执行）

### 2.1 桌面端：状态存储
- [ ] 文件：`control-agent/src/agent_state_store.py`
- [ ] 在 `AgentStateStore.__init__` 后新增以下 `load/save` 方法（保持原 JSON 文件向后兼容）：
  - `load_public_direct_settings() -> dict`：返回 `{"enabled": bool, "listen_host": str, "listen_port": int, "public_host": str, "public_port": int, "totp_secret": str, "download_whitelist": list[str], "known_public_ips": list[str], "auth_token_hint": str}`
  - `save_public_direct_settings(settings: dict) -> None`
- [ ] 默认值：
  - `enabled = false`（关闭，不影响现有用户）
  - `listen_host = "0.0.0.0"`
  - `listen_port = 0`（0 = 让 OS 分配，用户可在 UI 改成 5 位数）
  - `public_host = ""` / `public_port = 0`
  - `totp_secret = ""`（首次启用时由 `totp_auth.generate_secret()` 生成）
  - `download_whitelist = []`
  - `known_public_ips = []`
- [ ] ⚠ 字段命名不要和已有 `signaling_endpoints` 冲突。

### 2.2 桌面端：LAN 直连服务器改造 ★ 顺序敏感
- [ ] 文件：`control-agent/src/lan_direct_server.py`
- [ ] 在文件顶部 `from totp_auth import TotpAuthenticator`
- [ ] 改 `LanDirectServer.__init__`：增加参数 `totp_secret_getter=None, new_ip_approver=None, download_whitelist_getter=None`
- [ ] 改 `_LanDirectHttpServer.__init__`：把上面三个值透传给 handler
- [ ] 改 `_LanDirectHandler.handle()`：在 `self._read_http_request()` 之后，根据 `path` 分发：
  - `path == '/api/direct/handshake'` → 走 TOTP 握手（POST，body 含 `device_id/client_id/client_name/totp_code/nonce`），校验通过后升级到 WebSocket
  - `path == '/probe'` 或 `/probe/info` → 维持现有 LAN 探测逻辑（不要破坏局域网流程）
  - `path.startswith('/file/')` → 维持现有流程，但 `_handle_file_download` 前加白名单校验
  - 其他 → 404
- [ ] 新增方法 `_check_totp_request(self, request_data) -> tuple[bool, str]`：用 `self.server.owner._totp_auth.verify(code, nonce)`，失败返回 `('error reason',)` 状态码 401
- [ ] 新增方法 `_authorize_download_path(self, raw_path: str) -> bool`：
  - 调 `owner._download_whitelist_getter()` 拿到白名单
  - 若白名单为空 → 拒绝（这是你定的默认拒绝）
  - 否则把 `raw_path` 做 `os.path.abspath`，检查是否在任一白名单目录内
  - Windows 大小写不敏感，但路径用 `os.path.normcase` 比较
- [ ] 新增方法 `_is_new_public_ip(self, peer_ip: str) -> bool`：
  - 调 `owner._known_ips_getter()` 拿到已记录 IP
  - 不在表里就返回 True
- [ ] 新增回调 `owner.new_ip_approver(peer_ip, request_payload) -> bool`：
  - 如果返回 False 直接关连接
  - 如果 True 写回 known_public_ips
- [ ] 文件上传/下载走 `Accept` 头解析 client_id + totp 签名，**和原 LAN 共用 join_room 逻辑**。这意味着直连 client_id 必须先在 trusted_clients 里，否则弹原配对流程。

### 2.3 桌面端：agent_simple 集成 ⚠ 最大改动
- [ ] 文件：`control-agent/src/agent_simple.py`
- [ ] 顶部 import 加 `from totp_auth import TotpAuthenticator`
- [ ] 在 `__init__` 末尾（line ~6403 之后），增加：
  - `self._public_direct_settings = self._state_store.load_public_direct_settings()`
  - `self._totp_auth = TotpAuthenticator(lambda: self._public_direct_settings.get('totp_secret', ''))`
  - `self._lan_direct_server = LanDirectServer(..., totp_secret_getter=lambda: self._public_direct_settings.get('totp_secret', ''), new_ip_approver=self._approve_new_public_ip, download_whitelist_getter=lambda: self._public_direct_settings.get('download_whitelist', []))`
- [ ] 改 `self._lan_direct_port = ...`（原 line ~1374）：如果开启公网模式且 `listen_port > 0`，用用户配置的；否则用 `DEFAULT_LAN_DIRECT_PORT`（58082）
- [ ] 新增方法 `_approve_new_public_ip(peer_ip, payload) -> bool`：
  - 必须在主线程跑（弹 messagebox）
  - 用 `self._desktop_ui.enqueue_pair_prompt` 复用现有弹窗（payload 里加 `kind='new_public_ip'`）
  - 改 `desktop_agent_ui.py` 的 `_tick` 处理 `new_public_ip` kind
- [ ] 启动逻辑改：原 line ~6388 `self._lan_direct_server.start()` 后，若公网模式开，改 host = `0.0.0.0`，否则用 `127.0.0.1`
- [ ] 状态快照 getter 加一行：`'public_direct_enabled': ...`, `'public_direct_port': ...`, `'public_direct_address': f"{public_host}:{public_port}"`

### 2.4 桌面端：UI 新增"公网直连"标签页
- [ ] 文件：`control-agent/src/desktop_agent_ui.py`
- [ ] 在 `notebook.add(settings_tab, text='配置')` 之后增加：
  ```python
  direct_tab = tk.Frame(notebook, padx=2, pady=2)
  notebook.add(direct_tab, text='公网直连')
  ```
- [ ] 控件清单（按垂直顺序）：
  - 标题："公网直连（高级）" + 副标题："配合 NAS 上 frpc 端口转发使用，不开启时本界面无效。"
  - `Checkbutton` "启用公网直连模式"
  - `Label` + `Entry` + `Button` "重新生成"：监听端口（5 位冷门，0 = 随机）
  - `Label` + `Entry`：公网地址（域名或 IP）
  - `Label` + `Entry`：公网端口
  - `Label` + `Listbox` + `Button` "添加目录" / "删除"：下载白名单
  - `Button` "生成直连配置二维码"：payload = `{type:'pw-direct', v:1, direct_url, direct_port, device_id, totp_secret}`（★ TOTP 密钥用 base32 明文写进二维码，因为它只在初次扫码时传一次，之后手机端本地存）
  - `Button` "显示 TOTP 密钥"（仅调试用）
- [ ] 保存按钮触发 `state_store.save_public_direct_settings()`，**并重启 LanDirectServer**
- [ ] 所有 get/set 通过新增的 4 个回调：`public_direct_getter / public_direct_setter / public_direct_apply_callback / public_direct_token_hint_getter`
- [ ] 在 `_tick` 里处理 `kind='new_public_ip'`：弹窗"检测到来自新 IP `<ip>` 的连接请求，是否允许？" -> 调 `_approve_new_public_ip_callback`

### 2.5 桌面端：版本号升级
- [ ] 文件：`control-agent/version.json`
- [ ] 改为 `{"version": "1.2.0", "build": 200, "channel": "stable"}`（首次加公网直连 = minor 升一级）
- [ ] 顺带：`control-agent/config.json.example` 不动（没用到这个 key）

### 2.6 手机端：直连客户端（独立 slot 模块）◆
- [ ] 新建文件：`flutter-client/lib/services/public_direct_client.dart`
- [ ] 类结构：
  ```dart
  class PublicDirectClient with ChangeNotifier {
    String? directUrl;        // 如 https://yourdomain.com
    int? directPort;
    String? deviceId;
    String? totpSecret;
    
    String currentCode() => _totpCode(secret: totpSecret);  // HMAC-SHA1, 6 digits
    String newNonce() => random16bytesHex;
    Map<String,String> signedHeaders() => {'X-PW-Code': currentCode(), 'X-PW-Nonce': newNonce()};
  }
  ```
- [ ] 用 `package:crypto`（已存在依赖）算 TOTP，**不引入新第三方包**
- [ ] 类方法 `testConnection()`：`GET {directUrl}/api/direct/handshake?device_id=...&code=...&nonce=...` 验证可达
- [ ] 持久化：`SharedPreferences` 存 `pw.direct.url / pw.direct.port / pw.direct.device_id / pw.direct.totp_secret / pw.direct.last_verified_at`

### 2.7 手机端：扫码分支
- [ ] 文件：`flutter-client/lib/services/qr_scan_service.dart`（如不存在就新建）
- [ ] 扫到 `type == 'pw-direct'` 的 payload → 解析后调 `PublicDirectClient` 保存 + 提示用户"已保存直连配置"
- [ ] 已有 `type == 'pw-pair'` 流程**不动**

### 2.8 手机端：连接策略
- [ ] 文件：`flutter-client/lib/services/control_service.dart`
- [ ] `connect()` 入口：先 `PublicDirectClient.testConnection()` 成功 → 走直连；否则 fallback 到现有信令服务器
- [ ] 直连模式下：HTTP POST `directUrl/api/direct/handshake` → upgrade → WebSocket 自定义二进制协议
- [ ] **MVP 简化**：直连模式只做"标记已配置 + 提示用户扫码绑定到这台桌面端的 trusted_clients"，**真正的直连视频流先不实现**，等下一版。先让 UI 跑起来 + 让公网握手能通
- [ ] pubspec.yaml：`version: 1.3.0+300`（一次跨大版本，匹配桌面端 v1.2.0 build 200 的关系）

### 2.9 验证
- [ ] `cd control-agent && python -m py_compile src/totp_auth.py src/agent_state_store.py src/lan_direct_server.py src/agent_simple.py src/desktop_agent_ui.py`
- [ ] `python .codex_tmp/check_totp.py`（应输出 `ALL_TOTP_CHECKS_PASSED`）
- [ ] `cd flutter-client && flutter analyze`（新增文件 0 警告）

### 2.10 打包
- [ ] 桌面端：
  - `cd control-agent`
  - `Stop-Process -Name PocketWindowAgent -Force`
  - `python build_windows_exe.py`
  - 输出：`control-agent/release/PocketWindowAgent-win64-v1.2.0-build200.zip`
- [ ] 手机端：
  - `cd flutter-client`
  - `python build_release_apk.py`（使用 `--target-platform android-arm64`，注意打包文档第三节"versionCode 的坑"）
  - 输出：`flutter-client/release/PocketWindow-android-arm64-v8a-v1.3.0-build300.apk`

### 2.11 上传更新服务器
- [ ] 回到项目根 `F:\projects\pocketWindow`
- [ ] 桌面端：
  ```powershell
  python server\tools\upload_release.py --server http://192.168.31.77:58080 `
    --platform windows --version 1.2.0 --build 200 `
    --file control-agent\release\PocketWindowAgent-win64-v1.2.0-build200.zip `
    --file-name PocketWindowAgent-win64.zip
  ```
- [ ] 手机端：
  ```powershell
  python server\tools\upload_release.py --server http://192.168.31.77:58080 `
    --platform android --version 1.3.0 --build 300 `
    --file flutter-client\release\PocketWindow-android-arm64-v8a-v1.3.0-build300.apk `
    --file-name PocketWindow.apk
  ```
- [ ] 两个文件都 pscp 到 `/vol3/1000/soft`（保留带版本号的文件名）

### 2.12 重启桌面端
- [ ] `Stop-Process -Name PocketWindowAgent -Force`
- [ ] `Start-Process -FilePath "F:\projects\pocketWindow\control-agent\dist\PocketWindowAgent\PocketWindowAgent.exe" -WorkingDirectory "F:\projects\pocketWindow\control-agent\dist\PocketWindowAgent" -WindowStyle Hidden`
- [ ] 看 `$env:LOCALAPPDATA\PocketWindow\agent.out.log` 确认：信令连上 + LanDirectServer 监听 0.0.0.0:xxxxx

## 3. 你那边收尾

1. 手机点更新 → 装 v1.3.0 build 300
2. 桌面端自动更新 → 装 v1.2.0 build 200（agent 内置 updater）
3. 桌面 UI 重新启用公网直连 → 输入端口（点"重新生成"或自己填）→ 填公网地址 → 保存
4. 桌面端点"生成直连配置二维码" → 手机扫 → 手机直连配置页生效
5. NAS frpc 加一行：`公网 47823 → 192.168.31.x:47823`（你的电脑内网 IP）
6. 手机在设置页填"公网地址" → 测试连接 → 成功

## 4. 已知的、文档化但本会话不处理的

- **frpc 配置文件位置没确认**：你的 frpc 跑在 NAS 192.168.31.77 上，具体配置文件路径不在这台工作区。手动加转发规则时你自己知道在哪。
- **TURN 服务器**：公网直连是 TCP/WS，不需要 TURN。这一项跳过。
- **WebRTC P2P**：本次不做，保留现状（你 README 里 webrtc_agent.py 那条线以后再说）。
- **HTTPS / TLS**：你决定用 TOTP 替代。TOTP 在 LAN 探测路径也加，给 LAN 模式顺手升一下安全等级。

## 5. 回滚方案

万一新版本出锅：
```bash
cd F:\projects\pocketWindow
git reset --hard 3443efd
```
桌面端：
```powershell
Stop-Process -Name PocketWindowAgent -Force
Start-Process -FilePath "F:\projects\pocketWindow\control-agent\dist\PocketWindowAgent\PocketWindowAgent.exe" -WorkingDirectory "F:\projects\pocketWindow\control-agent\dist\PocketWindowAgent" -WindowStyle Hidden
```
手机端：在 APP 内"检查更新"，让 NAS 上的 v1.2.14 旧版本再次被识别（因为新 release 表会保留多个版本，APP 拉版本号最高的）。

## 6. 下一会话开场白（建议）

> "接着干 public-direct-implementation-plan.md，第 2.1 节 agent_state_store 开始。"

然后照着清单往下做即可。`control-agent/src/totp_auth.py` 已经写完且验证过，**不要重写**。
