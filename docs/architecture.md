# TermSync 技术架构文档

更新时间: 2026-04-07

说明:
- 当前产品名称为 `TermSync`。
- 仓库目录、部分资源文件和历史日志中仍保留 `tty1` / `TTY1` 命名，这是历史遗留，不影响当前运行架构。

## 1. 文档范围

本文描述仓库当前已经落地的技术架构，而不是早期方案稿。内容基于以下目录的现状整理:

- `server/`
- `desktop/src-tauri/`
- `desktop/src/`
- `mobile-android/app/src/main/`

文档重点覆盖:

- 运行时组件与职责边界
- 终端会话的创建、同步、订阅、回放和关闭流程
- 当前 WebSocket 协议与 SQLite 数据模型
- TLS / 自签名证书的落地方式

## 2. 系统概览

TermSync 是一个“桌面端拥有真实 PTY、服务器做安全中继、移动端远程查看与输入”的跨端终端同步系统。

运行拓扑如下:

```text
┌────────────────────┐        WSS + HTTPS         ┌────────────────────┐
│ Desktop Client     │ <───────────────────────> │ TermSync Server    │
│ Tauri + Rust       │                           │ Go + SQLite        │
│ HTML/JS + xterm.js │                           │ Session relay      │
│ Local PTY owner    │                           │ Pairing + auth     │
└────────────────────┘                           └────────────────────┘
           ^                                                ^
           │                                                │
           └────────────── WSS + HTTPS ─────────────────────┘
                            ┌────────────────────┐
                            │ Android Client     │
                            │ Compose + WebView  │
                            │ OkHttp WebSocket   │
                            │ Session viewer     │
                            └────────────────────┘
```

核心原则:

- 真实终端进程只在桌面端运行。
- 服务器不执行命令，不保存完整滚屏，只保存设备、配对关系和会话元数据。
- 移动端通过订阅已配对桌面的会话获得 `session.state`、`terminal.output` 和 `terminal.replay`。
- 输入、尺寸调整和回放请求由移动端经服务器转发给桌面端会话 owner。
- 移动端也可以请求已配对桌面新建终端或关闭现有终端，但真正的 PTY 创建/销毁仍由桌面端执行。

默认端口:

- `7373`: HTTPS / WSS
- `8080`: HTTP 重定向到 `7373`

## 3. 仓库模块映射

### 3.1 服务端

实际目录:

```text
server/
├── main.go
├── handler/
│   └── handlers.go
├── relay/
│   └── manager.go
├── store/
│   └── sqlite.go
├── models/
│   └── models.go
└── certs/
    ├── server.crt
    └── server.key
```

职责划分:

- `main.go`
  - 读取环境变量
  - 初始化 SQLite、SessionManager、HTTP 路由
  - 将 `certs/server.crt` 和 `certs/server.key` 以 `go:embed` 方式打进二进制
  - 启动 HTTPS/WSS 服务和 HTTP 重定向服务

- `handler/handlers.go`
  - REST API:
    - `/api/register`
    - `/api/login`
    - `/api/pairing/start`
    - `/api/pairing/complete`
    - `/api/sessions`
    - `/api/health`
    - `/api/cert`
  - WebSocket 升级和首包认证
  - 连接存活与服务端 heartbeat

- `relay/manager.go`
  - 维护在线连接、会话元数据、owner/viewer 关系
  - 做严格的消息类型校验与权限校验
  - 负责以下消息的路由:
    - `session.create`
    - `session.update`
    - `session.close`
    - `session.list`
    - `session.subscribe`
    - `session.unsubscribe`
    - `terminal.output`
    - `terminal.input`
    - `terminal.resize`
    - `terminal.replay_request`
    - `terminal.replay`

- `store/sqlite.go`
  - 设备注册
  - 配对码生成与消费
  - 桌面/手机绑定关系
  - 会话记录和在线状态持久化

- `models/models.go`
  - WebSocket 协议枚举
  - 消息 envelope
  - `SessionSnapshot` 与错误载荷定义

### 3.2 桌面端

实际目录:

```text
desktop/
├── src/
│   ├── index.html
│   └── vendor/xterm/
└── src-tauri/
    └── src/
        ├── main.rs
        ├── commands.rs
        ├── pty_manager.rs
        ├── wss_client.rs
        └── api_client.rs
```

职责划分:

- `desktop/src/index.html`
  - 当前唯一前端入口
  - 负责标签页、分屏树、pane 生命周期和 UI 事件
  - 用 `xterm.js` 渲染本地终端
  - 监听 Tauri 事件:
    - `server-status`
    - `server-message`
    - PTY 输出事件
  - 在连接成功后调用 `sync_active_sessions`，把当前活跃本地 PTY 重新注册到服务器

- `desktop/src-tauri/src/main.rs`
  - 注册 Tauri 命令
  - 注入全局状态:
    - `WssClientState`
    - `PtyManager`

- `desktop/src-tauri/src/commands.rs`
  - 前端与 Rust 后端的桥接层
  - 暴露命令:
    - 连接/断开服务端
    - 创建/关闭本地 PTY 会话
    - 发送输入、调整大小
    - 订阅/退订会话
    - 转发终端输出
    - 请求/回传终端回放
    - 更新会话元数据
    - 同步活跃会话

- `desktop/src-tauri/src/pty_manager.rs`
  - 本地 PTY 生命周期管理
  - 读取真实 shell 输出并转发给前端
  - 支持 write / resize / close

- `desktop/src-tauri/src/wss_client.rs`
  - 使用 `tokio-tungstenite` 建立 WSS 连接
  - 使用单独 writer task + `mpsc` 队列串行发送消息
  - 将服务端消息转成 Tauri 事件派发给前端
  - 与 `PtyManager` 协同处理:
    - viewer 输入
    - resize
    - session close

### 3.3 Android 端

实际目录:

```text
mobile-android/app/src/main/
├── java/com/termsync/mobile/
│   ├── TermSyncApplication.kt
│   ├── ui/MainActivity.kt
│   ├── viewmodel/MainViewModel.kt
│   └── network/
│       ├── ApiClient.kt
│       └── WssClient.kt
├── assets/terminal/
│   ├── terminal.html
│   ├── xterm.js
│   └── addon-fit.js
└── res/raw/server_cert.crt
```

职责划分:

- `TermSyncApplication.kt`
  - 启动时加载内置证书
  - 构建全局 `SSLContext` 和 `X509TrustManager`
  - 给 REST / WSS 共享

- `ui/MainActivity.kt`
  - Compose 界面入口
  - 首页显示连接摘要、已配对状态和终端列表
  - 终端详情页通过 `WebView` 加载 `assets/terminal/terminal.html`
  - 底部支持输入框和可折叠特殊键区

- `viewmodel/MainViewModel.kt`
  - 当前移动端状态机核心
  - 处理 `auth_response`、`session.list_res`、`session.state`、`terminal.output`、`terminal.replay`、`session.close`
  - 管理订阅集合、自动重连、回放超时、终端输出本地缓存

- `network/WssClient.kt`
  - 基于 OkHttp WebSocket
  - 首包发送 `auth`
  - 提供 `session.list`、`session.subscribe`、`terminal.input`、`terminal.replay_request` 等 helper
  - 提供远程新建/关闭终端请求 helper

- `assets/terminal/terminal.html`
  - 使用 `xterm.js` 在 Android `WebView` 内渲染终端输出
  - 支持整段渲染、增量追加和滚动到底部

说明:

- 当前 Android 端并不是“原生 PTY/终端控件”方案，而是 Compose 外壳 + WebView 内的 `xterm.js`。
- 当前移动端主流程是“列表 + 单终端详情页”，不是早期方案里的底部多 Tab 导航。

## 4. 关键运行时状态

### 4.1 设备角色

- `desktop`
  - 本地 PTY owner
  - 创建会话
  - 发送 `terminal.output`
  - 处理 viewer 的 `terminal.input` / `terminal.resize` / `terminal.replay_request`

- `mobile`
  - viewer
  - 通过配对关系看到桌面端会话
  - 订阅后接收 `session.state`、`terminal.output`
  - 可发送输入、特殊键、resize、回放请求

### 4.2 owner / viewer 语义

服务端 `SessionManager` 对每个 session 强制区分 owner 和 viewer:

- owner:
  - 可以 `session.create`
  - 可以 `session.update`
  - 可以 `session.close`
  - 可以发送 `terminal.output`
  - 可以发送 `terminal.replay`

- viewer:
  - 先 `session.subscribe`
  - 之后可以发送 `terminal.input`
  - 之后可以发送 `terminal.resize`
  - 之后可以发送 `terminal.replay_request`

权限由服务端集中校验，移动端和桌面端都不直接信任对方。

## 5. 核心数据流

### 5.1 设备注册与配对

```text
Desktop/Mobile -> POST /api/register -> 获得 device token
Desktop        -> POST /api/pairing/start -> 获得 6 位配对码
Mobile         -> POST /api/pairing/complete -> 建立 desktop/mobile 绑定
```

当前特点:

- 注册后会持久化设备记录到 `devices`
- 配对码存放在 `pairing_codes`
- 成功绑定后写入 `pairings`
- `session.list` 和 `session.subscribe` 都依赖 `pairings` 做授权过滤

### 5.2 桌面端本地终端创建

```text
前端 pane 创建
  -> invoke(create_session)
  -> PtyManager 创建本地 PTY
  -> 如果 WSS 已连接则发送 session.create
  -> 如果尚未连接，则等待后续 sync_active_sessions 补同步
```

当前桌面端 pane 使用 `local-${paneId}` 形式作为 session ID。

手机端远程新建流程:

```text
Mobile 点击“新建终端”
  -> session.create_request(desktop_id)
  -> Server 校验 mobile 与 desktop 已配对，且 desktop 在线
  -> Desktop 前端收到请求后 createNewTab()
  -> 走桌面端原有 create_session / session.create 主链路
```

### 5.3 移动端会话发现与预览订阅

```text
Mobile WSS connected
  -> auth
  -> auth_response
  -> session.list
  -> session.list_res
  -> 对返回的 sessionId 执行 session.subscribe
  -> 收到 session.state + 后续 terminal.output
```

说明:

- 移动端当前只会订阅服务端真实返回的会话 ID
- `session.list_res` 对 mobile 只返回已配对桌面的活跃会话
- `session.state` 是完整快照，用于同步标题、尺寸、状态、预览、活动描述

### 5.4 终端输出与活动状态同步

```text
本地 PTY 输出
  -> Desktop Rust 侧读取
  -> 前端本地 xterm.js 立即显示
  -> relay_terminal_output -> terminal.output -> Server
  -> Server broadcastToViewers
  -> Mobile 收到 terminal.output
  -> Mobile 更新:
       - 终端 WebView 输出
       - 预览摘要
       - activity/taskState
       - 本地输出缓存
```

另外，桌面端也会主动发送 `session.update`，同步:

- `title`
- `activity`
- `preview`
- `task_state`

### 5.5 输入、特殊键和尺寸调整回传

```text
Mobile 输入 / 特殊键 / resize
  -> terminal.input / terminal.resize
  -> Server 权限校验
  -> 转发给 session owner
  -> Desktop Rust 接收后写入 PTY 或 resize PTY
```

### 5.6 手机端远程关闭终端

```text
Mobile 在终端详情页点击“关闭终端”
  -> session.close_request(session_id)
  -> Server 校验会话存在、请求方已配对且 owner 在线
  -> Desktop 前端定位对应 pane 并执行 closePane()
  -> 走桌面端原有 session.close / 本地 PTY 销毁链路
```

### 5.7 回放机制

当前回放不是“服务器持久化滚屏”，而是“owner 定向补发当前缓冲”。

流程:

```text
Mobile 进入终端详情页
  -> terminal.replay_request(session_id)
  -> Server 在 payload 中补 target_device_id，转发给 owner
  -> Desktop owner 收到后整理本地缓冲
  -> terminal.replay(session_id, target_device_id, data)
  -> Server 定向转发给该 mobile viewer
  -> Mobile 合并 replay 与本地 live cache
```

因此:

- 服务器不存完整终端历史
- 桌面端必须在线，回放才能命中最新缓冲
- 移动端会额外保留少量本地缓存，避免重新进入详情页时全空白

### 5.8 断线重连与恢复

#### 服务端视角

- 连接断开时，`UnregisterConnection` 会:
  - 将设备标记离线
  - 将其拥有的 session 标记为关闭
  - 广播 `session.close`
  - 清理内存态 session

#### 桌面端视角

- `wss_client.rs` 内部有独立 writer task，避免并发直接写 socket
- 前端在 `server-status == connected` 时会调用 `sync_active_sessions`
- 这一步会把 `PtyManager` 当前仍存活的本地会话重新向服务端发布

#### 移动端视角

- `MainViewModel` 在 `connection.error` / `connection.closed` 后按固定延迟自动重连
- 重连成功后重新 `session.list`
- 订阅集合会按新的服务端返回结果重新建立

## 6. WebSocket 协议

### 6.1 消息 envelope

当前统一 envelope:

```json
{
  "type": "session.update",
  "session_id": "local-1",
  "timestamp": 1710000000,
  "payload": {
    "activity": "正在执行命令",
    "preview": "pnpm install",
    "task_state": "running"
  }
}
```

说明:

- `session_id` 对会话相关消息必填
- `timestamp` 为 Unix 秒级时间戳
- 服务端会拒绝明显过旧或未来过远的消息
- `terminal.output.payload.data` 当前直接传文本，不做 base64 包装

### 6.2 当前已实现消息类型

| 类型 | 方向 | 说明 |
|------|------|------|
| `auth` | Client -> Server | WebSocket 首包认证，载荷中带 device token |
| `auth_response` | Server -> Client | 认证结果，返回 `device_id` / `device_type` |
| `session.create` | Owner -> Server | 创建新终端会话 |
| `session.create_request` | Mobile -> Server -> Desktop | 请求已配对桌面新建终端 |
| `session.update` | Owner -> Server | 更新标题、活动、预览、任务状态 |
| `session.close` | Owner -> Server -> Viewers | 关闭会话 |
| `session.close_request` | Mobile -> Server -> Desktop | 请求已配对桌面关闭指定终端 |
| `session.list` | Client -> Server | 请求当前可见活跃会话列表 |
| `session.list_res` | Server -> Client | 返回 `SessionSnapshot[]` |
| `session.state` | Server -> Client | 推送单个 session 的完整快照 |
| `session.subscribe` | Viewer -> Server | 订阅会话并立即收到 `session.state` |
| `session.unsubscribe` | Viewer -> Server | 取消订阅 |
| `terminal.output` | Owner -> Server -> Viewers | 广播终端输出 |
| `terminal.input` | Viewer/Owner -> Server -> Owner | 向 owner 写入输入 |
| `terminal.resize` | Viewer/Owner -> Server -> Owner | 调整终端尺寸 |
| `terminal.replay_request` | Viewer -> Server -> Owner | 请求 owner 回放最近输出 |
| `terminal.replay` | Owner -> Server -> target viewer | 定向补发回放数据 |
| `heartbeat` | Client <-> Server | 保活与在线状态刷新 |
| `error` | Server -> Client | 结构化错误消息 |

### 6.3 SessionSnapshot 字段

`session.list_res` 和 `session.state` 当前使用的快照字段:

```json
{
  "session_id": "local-1",
  "owner_id": "desktop-device-id",
  "title": "标签 1",
  "cols": 120,
  "rows": 32,
  "status": "active",
  "task_state": "running",
  "preview": "pnpm dev",
  "activity": "正在处理终端任务"
}
```

## 7. 数据存储

### 7.1 SQLite 表

当前数据库 schema 由 `server/store/sqlite.go` 初始化，核心表如下:

```sql
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  token TEXT UNIQUE NOT NULL,
  type TEXT NOT NULL DEFAULT 'desktop',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  title TEXT,
  layout TEXT,
  status TEXT DEFAULT 'active',
  cols INTEGER DEFAULT 80,
  rows INTEGER DEFAULT 24,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE online_status (
  device_id TEXT PRIMARY KEY,
  connected_at DATETIME,
  last_seen DATETIME
);

CREATE TABLE pairing_codes (
  code TEXT PRIMARY KEY,
  desktop_device_id TEXT NOT NULL,
  expires_at DATETIME NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pairings (
  desktop_device_id TEXT NOT NULL,
  mobile_device_id TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (desktop_device_id, mobile_device_id)
);
```

### 7.2 内存态与持久化边界

当前边界非常明确:

- 持久化到 SQLite:
  - 设备
  - 配对关系
  - 会话基础元数据
  - 在线时间戳

- 只存在内存中:
  - 当前在线连接
  - viewer 订阅集合
  - 活跃 session 的实时 owner/viewer 映射
  - 服务器运行期内的 `SessionInfo`

- 不在服务端持久化:
  - 完整终端滚屏
  - 输入历史
  - 移动端本地缓存

含义:

- 服务端重启后，需要等待桌面端重新连接并执行 `sync_active_sessions` 才能恢复活跃会话视图。

## 8. TLS 与安全

### 8.1 服务端

- 证书位于 `server/certs/server.crt` 和 `server/certs/server.key`
- `main.go` 通过 `go:embed` 将证书打进二进制
- `/api/cert` 可把当前服务端证书内容返回给客户端
- HTTPS/WSS 最低版本为 TLS 1.2

### 8.2 桌面端

- `desktop/assets/server.crt` 随客户端打包
- `wss_client.rs` 将:
  - 系统根证书
  - 内置 `server.crt`
  一起放入 `rustls::RootCertStore`
- 连接时使用 `Sec-WebSocket-Protocol: termsync-protocol`

### 8.3 Android 端

- `res/raw/server_cert.crt` 内置服务端证书
- `TermSyncApplication` 构建共享 `SSLContext`
- `ApiClient` 和 `WssClient` 都复用该信任链

### 8.4 当前认证模型

- REST 注册返回 device token 和 JWT
- 当前客户端主链路实际主要使用 device token:
  - REST 配对接口传 token
  - WSS 首包 `auth` 传 token
- JWT 已具备生成与校验能力，但目前不是桌面/移动主链路的核心依赖

## 9. 当前实现特征与限制

### 9.1 已实现特征

- 桌面端真实 PTY + xterm.js 本地渲染
- 移动端远程查看、输入、特殊键和回放请求
- 移动端可请求桌面新建终端与关闭终端
- 设备注册、桌面/手机配对
- owner/viewer 权限模型
- 连接断开后 owner session 自动关闭
- 桌面端连接成功后的活跃会话补同步
- Android 与桌面端均支持自签名证书

### 9.2 当前限制

- 服务端不保存完整终端滚屏，回放依赖桌面端在线返回
- 活跃 session 注册表保存在内存中，服务端重启后要等桌面端重连补同步
- 仓库里仍存在 `TTY1` 历史命名，后续可继续清理

## 10. 推荐阅读顺序

如果要继续维护当前系统，建议按这个顺序读代码:

1. `server/models/models.go`
2. `server/relay/manager.go`
3. `desktop/src-tauri/src/wss_client.rs`
4. `desktop/src-tauri/src/commands.rs`
5. `desktop/src/index.html`
6. `mobile-android/app/src/main/java/com/termsync/mobile/viewmodel/MainViewModel.kt`
7. `mobile-android/app/src/main/java/com/termsync/mobile/network/WssClient.kt`

这样可以最快把“协议 -> 中继 -> 桌面 owner -> 移动 viewer”这条主链路串起来。
