# TermSync (TTY1) Code Wiki

> 跨平台终端共享系统 — 在桌面端创建终端，手机端实时查看与操控

---

## 目录

1. [项目概述](#1-项目概述)
2. [整体架构](#2-整体架构)
3. [通信协议 (Protocol v2)](#3-通信协议-protocol-v2)
4. [Server 模块 (Go)](#4-server-模块-go)
5. [Desktop 模块 (Rust/Tauri)](#5-desktop-模块-rusttauri)
6. [Mobile Android 模块 (Kotlin)](#6-mobile-android-模块-kotlin)
7. [终端渲染层](#7-终端渲染层)
8. [依赖关系总览](#8-依赖关系总览)
9. [项目运行方式](#9-项目运行方式)
10. [部署方案](#10-部署方案)

---

## 1. 项目概述

TermSync 是一个跨平台终端共享系统，核心场景：

- **桌面端**（Windows/macOS/Linux）创建本地 PTY 终端会话
- **手机端**（Android）通过 WebSocket 实时查看终端输出、发送输入和特殊按键
- **服务端**作为中继服务器，负责设备认证、配对、会话管理和消息路由

### 核心特性

| 特性 | 说明 |
|------|------|
| 实时终端共享 | 桌面 PTY 输出实时推送到手机端 |
| Owner/Viewer 模型 | 桌面为 Owner（创建/关闭），手机为 Viewer（订阅/输入） |
| 设备配对 | 6 位数字配对码，桌面生成 → 手机输入完成绑定 |
| 终端回放 (Replay) | 手机订阅会话时，桌面推送历史输出 |
| 自签名 TLS | 全链路 WSS 加密，证书内嵌到客户端 |
| 自动重连 | 手机端指数退避重连（3s → 60s） |
| 命令库 | 手机端内置常用命令快捷方式，支持收藏与最近使用 |
| AI 代理 | 桌面端可代理 AI API 请求（绕过浏览器 CORS） |

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                     TermSync Architecture                       │
│                                                                 │
│  ┌──────────────┐    WSS/TLS     ┌──────────────┐              │
│  │   Desktop     │◄─────────────►│    Server     │              │
│  │  (Tauri/Rust) │               │    (Go)       │              │
│  │               │               │               │              │
│  │  ┌─────────┐  │               │ ┌───────────┐ │              │
│  │  │PTY Mgr  │  │  terminal.    │ │  Session   │ │              │
│  │  │(portable │  │  output ───► │ │  Manager   │ │              │
│  │  │  -pty)   │  │               │ │  (relay)   │ │              │
│  │  └─────────┘  │  terminal.    │ └─────┬─────┘ │              │
│  │  ┌─────────┐  │  input  ◄─── │       │       │              │
│  │  │WSS Cln  │  │               │ ┌─────▼─────┐ │              │
│  │  └─────────┘  │               │ │  SQLite    │ │              │
│  │  ┌─────────┐  │               │ │  Store     │ │              │
│  │  │API Cln  │  │  HTTPS/TLS    │ └───────────┘ │              │
│  │  └─────────┘  │◄─────────────►│               │              │
│  └──────────────┘               └───────┬───────┘              │
│                                          │                      │
│                                          │ WSS/TLS              │
│                                          │                      │
│  ┌──────────────┐                        │                      │
│  │   Mobile      │◄──────────────────────┘                      │
│  │  (Android/    │                                               │
│  │   Kotlin)     │                                               │
│  │               │                                               │
│  │  ┌─────────┐  │                                               │
│  │  │WSS Cln  │  │  OkHttp WebSocket                             │
│  │  └─────────┘  │                                               │
│  │  ┌─────────┐  │                                               │
│  │  │API Cln  │  │  OkHttp HTTP (注册/配对)                       │
│  │  └─────────┘  │                                               │
│  │  ┌─────────┐  │                                               │
│  │  │WebView  │  │  xterm.js 终端渲染                             │
│  │  │(xterm)  │  │                                               │
│  │  └─────────┘  │                                               │
│  └──────────────┘                                               │
└─────────────────────────────────────────────────────────────────┘
```

### 数据流

```
桌面 PTY 输出 → PtyManager(读线程) → Tauri Event → 前端 xterm.js
                                    → WssClient → Server → Mobile WssClient → ViewModel → WebView xterm.js

手机输入 → WssClient → Server → Desktop WssClient → PtyManager → PTY stdin
```

---

## 3. 通信协议 (Protocol v2)

所有 WebSocket 通信使用统一的 JSON 信封格式：

```json
{
  "type": "<message_type>",
  "session_id": "<optional_session_id>",
  "timestamp": 1700000000,
  "payload": { ... }
}
```

### 消息类型一览

| 类型 | 方向 | 说明 |
|------|------|------|
| `auth` | Client → Server | 认证请求，携带 device token |
| `auth_response` | Server → Client | 认证结果，返回 device_id 和 device_type |
| `session.create` | Desktop → Server | 创建终端会话（Owner 操作） |
| `session.create_request` | Mobile → Server | 请求桌面创建新终端 |
| `session.close` | Desktop → Server | 关闭终端会话（Owner 操作） |
| `session.close_request` | Mobile → Server | 请求桌面关闭终端 |
| `session.update` | Desktop → Server | 更新会话元数据（title/activity/task_state/preview） |
| `session.list` | Client → Server | 请求会话列表 |
| `session.list_res` | Server → Client | 返回会话快照列表 |
| `session.state` | Server → Client | 会话完整快照推送（订阅时/更新时） |
| `session.subscribe` | Mobile → Server | 订阅会话以接收输出 |
| `session.unsubscribe` | Mobile → Server | 取消订阅 |
| `terminal.output` | Desktop → Server → Mobile | 终端输出数据 |
| `terminal.input` | Mobile → Server → Desktop | 终端输入数据 |
| `terminal.resize` | 双向 | 终端尺寸变更（手机端 resize 被服务端忽略） |
| `terminal.replay_request` | Mobile → Server → Desktop | 请求历史输出回放 |
| `terminal.replay` | Desktop → Server → Mobile | 回放数据（定向发送给请求者） |
| `heartbeat` | 双向 | 心跳保活 |
| `error` | Server → Client | 错误消息 |

### 权限模型

| 操作 | Owner (Desktop) | Viewer (Mobile) |
|------|-----------------|-----------------|
| 创建会话 | ✅ | ❌（可发 create_request） |
| 关闭会话 | ✅ | ❌（可发 close_request） |
| 发送终端输出 | ✅ | ❌ |
| 发送终端输入 | ✅ | ✅（需先订阅） |
| 调整终端尺寸 | ✅ | ❌（服务端忽略手机 resize） |
| 请求回放 | ✅ | ✅（需先订阅） |
| 订阅/取消订阅 | ✅ | ✅（需配对验证） |

---

## 4. Server 模块 (Go)

### 目录结构

```
server/
├── main.go              # 入口：HTTP/HTTPS 服务器启动
├── go.mod               # Go 模块定义
├── Makefile             # 构建/证书/测试/Docker 命令
├── Dockerfile           # 最小化 scratch 镜像
├── .env.example         # 环境变量模板
├── certs/               # TLS 证书目录
│   ├── server.crt
│   └── server.key
├── cmd/gencert/         # 证书生成工具
├── models/
│   └── models.go        # 数据模型与协议类型定义
├── handler/
│   └── handlers.go      # HTTP/WS 处理器
├── relay/
│   └── manager.go       # 会话管理与消息路由
└── store/
    └── sqlite.go        # SQLite 持久化层
```

### 关键类与函数

#### `main.go` — 服务入口

| 函数 | 说明 |
|------|------|
| `main()` | 初始化数据库、SessionManager、路由，启动 HTTPS + HTTP 重定向服务器 |
| `newTLSServer()` | 使用内嵌证书创建 TLS HTTP Server |
| `getEnv()` | 读取环境变量，支持默认值 |
| `executableDir()` | 获取可执行文件所在目录 |
| `resolveRuntimePath()` | 解析运行时路径（相对路径基于可执行文件目录） |

**环境变量配置：**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TERMSYNC_PORT` | `7373` | WSS 端口 |
| `TERMSYNC_HTTP_PORT` | `8080` | HTTP 重定向端口 |
| `TERMSYNC_DB_PATH` | `./data/termsync.db` | SQLite 数据库路径 |
| `TERMSYNC_JWT_SECRET` | `termsync-secret-change-in-production` | JWT 签名密钥 |

**路由表：**

| 路径 | 方法 | 处理器 | 说明 |
|------|------|--------|------|
| `/api/register` | POST | `AuthHandler.HandleRegister` | 设备注册 |
| `/api/login` | POST | `AuthHandler.HandleLogin` | 设备登录 |
| `/api/pairing/start` | POST | `APIHandler.HandleStartPairing` | 生成配对码 |
| `/api/pairing/complete` | POST | `APIHandler.HandleCompletePairing` | 完成配对 |
| `/api/sessions` | GET | `APIHandler.HandleGetSessions` | 获取活跃会话 |
| `/api/health` | GET | `APIHandler.HandleHealthCheck` | 健康检查 |
| `/api/cert` | GET | `APIHandler.ServeCertContent` | 下载服务端证书 |
| `/ws` | GET | `WSHandler.HandleWebSocket` | WebSocket 连接 |

#### `models/models.go` — 数据模型

| 结构体 | 说明 |
|--------|------|
| `Device` | 注册设备（id/name/token/type/created_at） |
| `PairingCode` | 短时效配对码（code/desktop_id/expires_at） |
| `DevicePairing` | 设备配对关系（desktop_id/mobile_id） |
| `Session` | 终端会话（id/device_id/title/cols/rows/status） |
| `OnlineStatus` | 设备在线状态 |
| `Message` | WebSocket 统一信封（type/session_id/timestamp/payload） |
| `SessionSnapshot` | 会话完整快照（用于同步推送） |
| `MsgType` | 消息类型枚举常量 |
| `Role` | 角色枚举：`owner` / `viewer` |

#### `handler/handlers.go` — 请求处理器

| 处理器 | 说明 |
|--------|------|
| `AuthHandler` | 设备注册与登录，JWT 生成与验证 |
| `WSHandler` | WebSocket 升级、认证等待、消息循环、Keepalive Ping |
| `APIHandler` | REST API：配对码生成/消费、会话列表、健康检查、证书下载 |

**关键方法：**

- `AuthHandler.HandleRegister` — 注册设备，生成 UUID token + JWT（1年有效期）
- `AuthHandler.HandleLogin` — Token 登录，返回 JWT
- `AuthHandler.ValidateJWT` — 从 Authorization Header 解析 JWT
- `WSHandler.HandleWebSocket` — 升级 WS → 等待 auth → 注册连接 → 30s Ping 保活 → 消息循环
- `WSHandler.waitForAuth` — 10s 超时等待首条 auth 消息
- `APIHandler.HandleStartPairing` — 桌面端生成 6 位数字配对码（5 分钟有效）
- `APIHandler.HandleCompletePairing` — 手机端消费配对码，建立配对关系
- `generatePairingCode` — 使用 `crypto/rand` 生成 6 位数字码

#### `relay/manager.go` — 会话管理与消息路由

`SessionManager` 是服务端核心，管理所有 WebSocket 连接和会话路由。

| 数据结构 | 说明 |
|----------|------|
| `deviceConnections` | `map[deviceID]*websocket.Conn` — 设备连接映射 |
| `deviceTypes` | `map[deviceID]string` — 设备类型（desktop/mobile） |
| `sessions` | `map[sessionID]*SessionInfo` — 活跃会话 |
| `deviceSessions` | `map[deviceID]map[sessionID]bool` — 设备拥有的会话集 |

**关键方法：**

| 方法 | 说明 |
|------|------|
| `RegisterConnection` | 注册设备连接，替换旧连接，更新在线状态 |
| `UnregisterConnection` | 注销连接，关闭所有 Owner 会话，通知 Viewer |
| `HandleMessage` | 消息分发入口，按 type 路由到对应处理函数 |
| `handleSessionCreate` | 创建会话，持久化到 DB，通知已配对手机 |
| `handleSessionUpdate` | 更新会话元数据，广播给所有 Viewer |
| `handleSessionCreateRequest` | 手机→桌面转发创建请求（验证配对关系） |
| `handleSessionClose` | Owner 关闭会话，通知 Viewer |
| `handleSessionCloseRequest` | 手机→桌面转发关闭请求 |
| `relayTerminalOutput` | Owner 输出 → 广播给所有 Viewer |
| `relayTerminalInput` | Viewer 输入 → 转发给 Owner |
| `relayTerminalResize` | Viewer resize → 转发给 Owner（手机端被忽略） |
| `relayTerminalReplayRequest` | Viewer 请求回放 → 转发给 Owner |
| `relayTerminalReplay` | Owner 回放数据 → 定向发送给请求者 |
| `handleSubscribe` | 添加 Viewer，验证配对，推送完整快照 |
| `handleUnsubscribe` | 移除 Viewer |
| `handleHeartbeat` | 心跳响应，更新在线状态 |
| `sendToDevice` | 发送消息（最多 2 次重试，5s 超时） |
| `broadcastToViewers` | 广播给会话所有 Viewer（排除指定设备） |
| `notifyPairedMobiles` | 通知所有已配对手机 |
| `PushSessionList` | 推送可见会话列表（手机只看配对桌面的会话） |

**并发安全：** 使用 `sync.RWMutex` 保护所有共享状态。DB 查询在锁外执行以避免全局阻塞。

#### `store/sqlite.go` — SQLite 持久化

| 表 | 说明 |
|----|------|
| `devices` | 设备注册信息（id/name/token/type） |
| `sessions` | 终端会话（id/device_id/title/cols/rows/status） |
| `online_status` | 设备在线状态（connected_at/last_seen） |
| `pairing_codes` | 短时效配对码（code/desktop_device_id/expires_at） |
| `pairings` | 配对关系（desktop_device_id/mobile_device_id） |

**SQLite 优化：** WAL 模式、NORMAL 同步、2MB 缓存、64MB mmap、外键约束。

**关键方法：**

| 方法 | 说明 |
|------|------|
| `New(dbPath)` | 创建 Store，执行 PRAGMA 优化，初始化 Schema |
| `CreateDevice` | 注册设备 |
| `GetDeviceByToken` | Token 查找设备 |
| `CreatePairingCode` | 创建配对码（事务：先清理旧码/过期码） |
| `ConsumePairingCode` | 消费配对码（事务：验证→删除码→创建配对） |
| `IsPaired` | 检查配对关系 |
| `ListPairedDesktopIDs` | 列出手机配对的所有桌面 |
| `ListPairedMobileIDs` | 列出桌面配对的所有手机 |
| `SetOnline` / `SetOffline` | 更新在线状态（UPSERT / DELETE） |

---

## 5. Desktop 模块 (Rust/Tauri)

### 目录结构

```
desktop/
├── src-tauri/
│   ├── Cargo.toml           # Rust 依赖
│   ├── tauri.conf.json      # Tauri 配置
│   ├── src/
│   │   ├── main.rs          # Tauri 入口，注册命令与状态
│   │   ├── commands.rs      # Tauri 命令（前端调用接口）
│   │   ├── pty_manager.rs   # PTY 进程管理
│   │   ├── wss_client.rs    # WebSocket 客户端
│   │   └── api_client.rs    # HTTP API 客户端
│   └── assets/
│       └── server.crt       # 内嵌服务端证书
├── src/
│   ├── index.html           # 前端单页应用（xterm.js 终端 UI）
│   └── vendor/xterm/        # xterm.js 及插件
└── scripts/
    └── dev-server.ps1       # 开发服务器脚本
```

### 关键类与函数

#### `main.rs` — 应用入口

| 功能 | 说明 |
|------|------|
| 注册 Tauri 命令 | 28 个 `invoke_handler` 命令 |
| 管理全局状态 | `WssClientState`、`PtyManager` |
| 窗口配置 | 无边框（Windows）、默认最大化 |
| 单实例 | Release 模式启用 `tauri-plugin-single-instance` |
| 调试日志 | 写入 `%TEMP%/termsync-desktop-debug.log` |

#### `pty_manager.rs` — PTY 进程管理

| 结构体 | 说明 |
|--------|------|
| `PtyManager` | PTY 会话管理器（`Arc<Mutex<HashMap>>` 线程安全） |
| `PtySession` | 单个 PTY 会话（child/master/writer/title/pid/cwd） |
| `PtyOutputEvent` | PTY 输出事件（session_id/data/cwd） |
| `PtyExitEvent` | PTY 退出事件 |
| `SessionDescriptor` | 会话描述（session_id/title/cols/rows/cwd） |

**关键方法：**

| 方法 | 说明 |
|------|------|
| `create_session` | 创建 PTY 会话：打开 PTY → 检测 Shell → 启动子进程 → 启动读线程 |
| `write_input` | 向 PTY stdin 写入数据 |
| `resize` | 调整 PTY 尺寸 |
| `close_session` | 终止 PTY 子进程 |
| `describe_sessions` | 列出所有会话（含 CWD 检测） |
| `detect_shell` | Shell 检测：Windows（pwsh→powershell→cmd），其他（bash） |

**PTY 读线程：** 独立线程循环读取 PTY 输出，通过 `app_handle.emit("pty-output", ...)` 发送给前端，同时检测进程 CWD。

#### `wss_client.rs` — WebSocket 客户端

| 结构体 | 说明 |
|--------|------|
| `WssClientState` | WS 连接状态管理（`Arc<Mutex<InnerState>>`） |
| `InnerState` | 内部状态（connected/server_url/device_id/sender/task） |
| `ServerStatusPayload` | 连接状态事件 |
| `ServerMessagePayload` | 服务端消息事件 |

**关键方法：**

| 方法 | 说明 |
|------|------|
| `connect` | 建立 WSS 连接 → 发送 auth → 进入收发循环 |
| `disconnect` | 关闭连接，中止任务 |
| `send_session_create/close` | 发送会话生命周期消息 |
| `send_terminal_output/input/resize` | 发送终端 I/O 消息 |
| `send_terminal_replay_request/replay` | 发送回放请求/数据 |
| `send_session_update` | 发送会话元数据更新 |
| `subscribe_session/unsubscribe_session` | 订阅/取消订阅 |
| `handle_incoming_text` | 处理服务端消息：auth_response→更新状态，terminal.input→写入PTY，terminal.resize→调整PTY，session.close→关闭PTY |
| `build_connector` | 构建 TLS Connector：加载系统证书 + 内嵌服务端证书 |

**Tauri 事件：**

| 事件 | 说明 |
|------|------|
| `server-status` | 连接状态变更（connecting/connected/disconnected） |
| `server-message` | 服务端消息转发给前端 |
| `pty-output` | PTY 输出数据 |
| `pty-exit` | PTY 进程退出 |

#### `commands.rs` — Tauri 命令

28 个前端可调用命令，主要分类：

| 分类 | 命令 |
|------|------|
| 连接管理 | `connect_server`, `disconnect_server`, `get_server_status` |
| 会话管理 | `create_session`, `close_session`, `list_local_sessions`, `sync_active_sessions` |
| 终端 I/O | `send_input`, `resize_terminal_cmd`, `relay_terminal_output` |
| 回放 | `request_terminal_replay`, `relay_terminal_replay` |
| 订阅 | `subscribe_session`, `unsubscribe_session` |
| 元数据 | `update_session_meta` |
| 设备注册 | `register_device`, `generate_pairing_code` |
| 剪贴板 | `write_clipboard_text`, `read_clipboard_text` |
| 窗口控制 | `window_minimize`, `window_start_dragging`, `window_toggle_maximize`, `window_is_maximized`, `window_close`, `window_destroy` |
| AI 代理 | `proxy_ai_request` |
| 调试 | `debug_log` |

#### `api_client.rs` — HTTP API 客户端

| 函数 | 说明 |
|------|------|
| `register_device` | POST `/api/register` 注册设备 |
| `generate_pairing_code` | POST `/api/pairing/start` 生成配对码 |
| `server_base_url` | 将 `wss://` URL 转换为 `https://` 基地址 |

TLS 配置：使用 `reqwest` + `rustls`，内嵌 `server.crt` 作为受信根证书。

---

## 6. Mobile Android 模块 (Kotlin)

### 目录结构

```
mobile-android/
├── app/
│   ├── build.gradle.kts          # 构建配置
│   └── src/main/
│       ├── java/com/termsync/mobile/
│       │   ├── TermSyncApplication.kt  # Application：TLS 证书初始化
│       │   ├── network/
│       │   │   ├── WssClient.kt        # WebSocket 客户端
│       │   │   └── ApiClient.kt        # HTTP API 客户端
│       │   ├── viewmodel/
│       │   │   ├── MainViewModel.kt    # 核心 ViewModel
│       │   │   └── CommandLibrary.kt   # 命令库数据模型
│       │   └── ui/
│       │       └── MainActivity.kt     # 主 Activity + Compose UI
│       ├── assets/
│       │   ├── terminal/
│       │   │   ├── terminal.html       # xterm.js 终端页面
│       │   │   ├── xterm.js            # xterm.js 库
│       │   │   ├── xterm.css           # xterm.js 样式
│       │   │   └── addon-fit.js        # xterm.js fit 插件
│       │   └── raw/
│       │       └── server_cert        # 服务端证书（DER 格式）
│       └── res/                        # Android 资源
└── build.gradle.kts                    # 根构建配置
```

### 关键类与函数

#### `TermSyncApplication.kt` — 应用初始化

| 功能 | 说明 |
|------|------|
| `initializeTLS` | 从 `raw/server_cert` 加载自签名证书，创建自定义 `SSLContext` 和 `TrustManager` |
| `sslContext` | 全局共享的 SSL 上下文 |
| `trustManager` | 全局共享的 TrustManager |
| `getCertificateFingerprint` | 计算证书 SHA256 指纹 |

#### `WssClient.kt` — WebSocket 客户端

| 类/方法 | 说明 |
|---------|------|
| `WssClient` | OkHttp WebSocket 客户端，协议 v2 实现 |
| `connectionGeneration` | 单调递增的连接代 ID，防止旧连接回调污染新连接状态 |
| `connect(url, token)` | 建立 WSS 连接，发送 auth，启动心跳 |
| `disconnect()` | 断开连接，递增代 ID 使旧回调失效 |
| `sendMessage(type, sessionId, payload)` | 发送协议消息 |
| `requestSessionList()` | 请求会话列表 |
| `subscribeToSession(sessionId)` | 订阅会话 |
| `requestTerminalReplay(sessionId)` | 请求回放 |
| `sendTerminalInput(sessionId, input)` | 发送终端输入 |
| `requestResize(sessionId, cols, rows)` | 请求尺寸变更 |
| `requestRemoteSessionCreate(desktopId, title)` | 请求桌面创建终端 |
| `requestRemoteSessionClose(sessionId)` | 请求桌面关闭终端 |
| `startHeartbeat(gen)` | 30s 间隔心跳（绑定到特定连接代） |

**线程安全：** 使用 `AtomicLong`（connectionGeneration）、`AtomicReference`（activeSocket）、`AtomicBoolean`（isConnected）保证并发安全。

#### `ApiClient.kt` — HTTP API 客户端

| 方法 | 说明 |
|------|------|
| `registerDevice(serverUrl, name, deviceType)` | POST `/api/register` |
| `completePairing(serverUrl, token, code)` | POST `/api/pairing/complete` |

TLS：使用 `TermSyncApplication.sslContext` 配置 OkHttp 的 `sslSocketFactory`。

#### `MainViewModel.kt` — 核心 ViewModel

| 状态流 | 类型 | 说明 |
|--------|------|------|
| `connectionState` | `StateFlow<ConnectionState>` | 连接状态（Disconnected/Connecting/Connected/Error） |
| `sessions` | `StateFlow<List<TerminalSession>>` | 可见终端会话列表 |
| `selectedSessionId` | `StateFlow<String?>` | 当前选中的会话 |
| `terminalOutput` | `StateFlow<String>` | 当前终端完整输出 |
| `terminalOutputVersion` | `StateFlow<Long>` | 输出版本号 |
| `terminalDelta` | `SharedFlow<TerminalDeltaBatch>` | 增量输出流（~20fps 批处理） |
| `serverUrl/deviceToken/deviceName` | `StateFlow<String>` | 连接设置 |
| `isPaired/pairedDesktopName` | `StateFlow` | 配对状态 |
| `commandLibrary` | `StateFlow<CommandLibraryUiState>` | 命令库 UI 状态 |
| `replayLoading` | `StateFlow<Boolean>` | 回放加载状态 |
| `terminalStreamStatus` | `StateFlow<String>` | 终端流状态文本 |

**关键方法：**

| 方法 | 说明 |
|------|------|
| `connect(url, token)` | 保存设置 → 连接 WSS |
| `disconnect()` | 手动断开，取消重连 |
| `selectSession(sessionId)` | 选中会话 → 加载缓存 → 请求回放 → 订阅 |
| `sendInput(input)` | 发送终端输入 |
| `submitCommand(command)` | 规范化命令 → 记录使用 → 发送 |
| `sendSpecialKey(key)` | 发送特殊键（ESC/TAB/方向键/Ctrl+C 等） |
| `requestSelectedSessionResize` | 请求尺寸变更（防抖 350ms） |
| `requestRemoteSessionCreate` | 请求桌面创建终端 |
| `requestRemoteSessionClose` | 请求桌面关闭终端 |
| `registerMobileDevice` | 注册手机设备 |
| `completePairing(code)` | 完成配对 |
| `handleMessage(msg)` | 处理所有 WSS 消息 |
| `scheduleReconnect` | 指数退避重连（3s→6s→12s→24s→48s→60s） |
| `autoConnectIfPossible` | 启动时自动恢复连接 |

**Delta 批处理机制：** 原始终端输出进入 `_rawDeltaChannel`（Channel），独立协程每 50ms 批量合并后发射到 `_terminalDelta`（SharedFlow），WebView 端直接消费，绕过 Compose 重组。

**会话输出缓存：** 使用 SharedPreferences 持久化最近 8 个会话的输出（最大 1000 行 / 400KB），支持离线查看。

#### `MainActivity.kt` — UI 层

Compose UI 主要组件：

| 组件 | 说明 |
|------|------|
| `TTY1App` | 根组件：连接状态栏 + 主页/终端视图切换 |
| `HomeScreen` | 主页：配对状态卡片 + 会话列表 |
| `TerminalViewScreen` | 终端视图：WebView + 命令输入 + 特殊键 + 命令库 |
| `TerminalWebView` | Android WebView 封装，加载 xterm.js，JS Bridge 通信 |
| `ConnectionDialog` | 连接设置对话框（服务器地址/设备名/Token/配对码） |
| `CommandLibraryPanel` | 命令库面板（推荐/收藏/最近/分类） |
| `SessionCard` | 会话卡片（标题/状态/活动/尺寸） |
| `ConnectionStatusBar` | 连接状态指示条 |

**TerminalWebView 关键机制：**

- 加载 `file:///android_asset/terminal/terminal.html`
- `TerminalAndroidBridge` JS 接口：`reportSize(cols, rows, reason)` 回调尺寸变更
- `termsyncRenderBase64(base64)` — 全量渲染（回放/切换会话）
- `termsyncAppendBase64(base64)` — 增量追加（实时输出）
- `termsyncSetRenderMode(mode, fontScale, cols, rows)` — 渲染模式切换
- `termsyncSetSelectionMode(enabled)` — 复制模式切换
- `termsyncEnsureLayout(reason)` — 强制布局刷新
- 两种渲染模式：`MobileFit`（手机适配）和 `DesktopMirror`（桌面镜像）

#### `CommandLibrary.kt` — 命令库

| 数据类 | 说明 |
|--------|------|
| `CommandShortcut` | 命令快捷方式（id/title/command/category/dangerous/isFavorite/useCount） |
| `CommandCategory` | 命令分类（System/Files/Network/Docker/Process/Custom） |
| `CommandLibraryUiState` | 命令库 UI 状态（recommended/favorites/recent/sections） |

内置常用 Linux 命令快捷方式，支持自定义命令、收藏、使用频率统计。

---

## 7. 终端渲染层

两端均使用 **xterm.js** 进行终端渲染：

### Desktop 前端

- `desktop/src/index.html` — 单页应用，内嵌 xterm.js + xterm-addon-fit + xterm-addon-web-links
- 通过 Tauri `invoke` 调用 Rust 后端命令
- 监听 `pty-output` / `server-message` / `server-status` 事件

### Mobile WebView

- `mobile-android/app/src/main/assets/terminal/terminal.html` — xterm.js 终端页面
- 通过 `JavascriptInterface`（`TerminalAndroidBridge`）与原生层通信
- 支持两种渲染模式：
  - **MobileFit**：根据手机屏幕自适应列数/行数
  - **DesktopMirror**：保持桌面端原始列数/行数，可缩放字体

### 数据传输格式

终端输出数据使用 **Base64 编码** 传输，避免 JSON 中转义特殊字符的问题：

- 全量渲染：`termsyncRenderBase64(base64EncodedOutput)`
- 增量追加：`termsyncAppendBase64(base64EncodedDelta)`

---

## 8. 依赖关系总览

### Server (Go)

| 依赖 | 版本 | 用途 |
|------|------|------|
| `chi/v5` | 5.0.11 | HTTP 路由框架 |
| `golang-jwt/jwt/v5` | 5.2.0 | JWT 令牌生成与验证 |
| `google/uuid` | 1.5.0 | UUID 生成 |
| `modernc.org/sqlite` | 1.28.0 | 纯 Go SQLite 驱动（无 CGO） |
| `nhooyr.io/websocket` | 1.8.7 | WebSocket 服务器 |

### Desktop (Rust)

| 依赖 | 版本 | 用途 |
|------|------|------|
| `tauri` | 2.0 | 桌面应用框架 |
| `tauri-plugin-shell` | 2.0 | Shell 插件 |
| `tauri-plugin-single-instance` | 2.0 | 单实例限制 |
| `tokio` | 1.35 | 异步运行时 |
| `tokio-tungstenite` | 0.20 | WebSocket 客户端（rustls TLS） |
| `rustls` / `rustls-pemfile` / `rustls-native-certs` | 0.21/1.0/0.6 | TLS 实现 |
| `portable-pty` | 0.8 | 跨平台 PTY |
| `serde` / `serde_json` | 1.0 | 序列化 |
| `reqwest` | 0.12 | HTTP 客户端（rustls TLS） |
| `sysinfo` | 0.30 | 系统信息（进程 CWD 检测） |
| `arboard` | 3.6 | 剪贴板访问 |
| `uuid` | 1.6 | UUID 生成 |
| `parking_lot` | 0.12 | 高性能互斥锁 |
| `futures` | 0.3 | 异步工具 |
| `base64` | 0.21 | Base64 编解码 |

### Mobile Android (Kotlin)

| 依赖 | 版本 | 用途 |
|------|------|------|
| `Compose BOM` | 2023.10.01 | Compose 组件版本管理 |
| `material3` | — | Material Design 3 |
| `navigation-compose` | 2.7.5 | 导航框架 |
| `lifecycle-viewmodel-compose` | 2.6.2 | ViewModel 集成 |
| `OkHttp` | 4.12.0 | HTTP/WebSocket 客户端 |
| `Moshi` | 1.15.0 | JSON 解析 |
| `kotlinx-coroutines-android` | 1.7.3 | 协程支持 |
| `xterm.js` | — | 终端渲染（WebView 内） |

---

## 9. 项目运行方式

### Server

```bash
cd server

# 生成自签名证书
make certs

# 开发模式运行
make dev

# 或构建后运行
make run

# 运行测试
make test

# 跨平台构建
make build-all    # Linux + macOS + Windows
```

**Docker 运行：**

```bash
make docker
docker run -d -p 7373:7373 -p 8080:8080 -v termsync-data:/data termsync-server:latest
```

### Desktop

```bash
cd desktop

# 开发模式（需要 Rust 工具链 + Node.js）
cd src-tauri
cargo tauri dev

# 构建发布版
cargo tauri build
```

**前置条件：**
- Rust (stable)
- Tauri CLI v2
- Windows: Visual Studio Build Tools
- macOS: Xcode Command Line Tools

### Mobile Android

```bash
cd mobile-android

# 使用 Android Studio 打开项目
# 或命令行构建
./gradlew assembleDebug
```

**前置条件：**
- Android Studio (Flamingo+)
- Android SDK 34
- JDK 17
- Kotlin 1.9+

---

## 10. 部署方案

### 典型部署拓扑

```
┌─────────────────────────────────────────────┐
│              云服务器 / NAS                   │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  TermSync Server (Docker)           │    │
│  │  - WSS Port: 7373 (TLS)            │    │
│  │  - HTTP Port: 8080 (→ HTTPS 重定向) │    │
│  │  - SQLite: /data/termsync.db       │    │
│  │  - 自签名证书内嵌于二进制            │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
         ▲                    ▲
         │ WSS                │ WSS
         │                    │
    ┌────┴────┐          ┌────┴────┐
    │ Desktop  │          │ Mobile   │
    │ (Home/   │          │ (Any     │
    │  Office) │          │  where)  │
    └─────────┘          └─────────┘
```

### 安全考量

| 项目 | 实现 |
|------|------|
| 传输加密 | 全链路 WSS (TLS 1.2+)，自签名证书 |
| 设备认证 | UUID Token + JWT（1 年有效期） |
| 配对验证 | 6 位数字码（5 分钟有效，一次性消费） |
| 权限隔离 | Owner/Viewer 角色模型，Viewer 不能创建/关闭/resize |
| 会话可见性 | 手机只能看到已配对桌面的会话 |
| 证书分发 | 服务端 `/api/cert` 端点 + 客户端内嵌 |

### 环境变量

| 变量 | 默认值 | 生产建议 |
|------|--------|----------|
| `TERMSYNC_JWT_SECRET` | `termsync-secret-change-in-production` | **必须修改为强随机字符串** |
| `TERMSYNC_PORT` | `7373` | 按需调整 |
| `TERMSYNC_HTTP_PORT` | `8080` | 按需调整 |
| `TERMSYNC_DB_PATH` | `./data/termsync.db` | 使用持久化卷挂载 |

---

> 文档生成时间：2026-05-09 | 基于 TermSync v0.1.0 代码库分析
