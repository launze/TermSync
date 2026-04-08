# TermSync

TermSync 是一个跨端终端同步系统。

它的核心思路很直接: 真实终端进程只运行在桌面端，服务端负责认证、配对和消息中继，移动端负责远程查看、输入和控制已经配对的桌面会话。

## 核心能力

- 桌面端基于 Tauri + Rust + xterm.js，持有真实本地 PTY。
- 服务端基于 Go + SQLite，提供 HTTPS / WSS、设备注册、登录、配对和会话中继。
- Android 客户端可查看已配对桌面的活跃终端，并支持输入、缩放、回放和关闭会话。
- 桌面端内置 AI 助手面板，可接入 OpenAI-compatible 网关生成命令或结合当前终端上下文提问。
- 支持自签名证书分发，方便局域网或自部署环境下直接联通。

## 系统结构

```text
Desktop Client  <---- HTTPS / WSS ---->  TermSync Server  <---- HTTPS / WSS ---->  Android Client
Tauri + Rust                              Go + SQLite                               Compose + WebView
真实 PTY owner                            认证 / 配对 / 消息中继                    远程查看与输入
```

## 仓库结构

- `server/`: Go 服务端，负责 REST API、WebSocket 中继、SQLite 持久化和配对流程。
- `desktop/`: Tauri 桌面端，包含 Rust 后端命令和 `desktop/src/index.html` 前端界面。
- `mobile-android/`: Android 客户端，基于 Kotlin + Compose + WebView。
- `docs/architecture.md`: 当前落地架构说明，适合快速了解协议和模块边界。
- `start.ps1`: Windows 下的便捷启动脚本。

## 快速启动

### 1. 启动服务端

```bash
cd server
make all
./termsync-server
```

默认端口:

- `7373`: HTTPS / WSS
- `8080`: HTTP 重定向

常用环境变量:

- `TERMSYNC_PORT`
- `TERMSYNC_HTTP_PORT`
- `TERMSYNC_DB_PATH`
- `TERMSYNC_JWT_SECRET`

### 2. 启动桌面端

前提:

- Rust 1.70+
- Node.js 18+
- Tauri CLI

```bash
cd desktop/src-tauri
cargo tauri dev
```

### 3. 构建 Android 客户端

前提:

- Android Studio Hedgehog+
- Android SDK 34
- Kotlin 1.9.20
- JDK 17

```bash
cd mobile-android
./gradlew assembleDebug
```

Windows 下可直接使用:

```powershell
cd mobile-android
.\gradlew.bat assembleDebug
```

## 使用流程

1. 启动服务端。
2. 启动桌面端并完成登录。
3. 在桌面端生成 6 位配对码。
4. 在 Android 客户端输入配对码完成绑定。
5. 在移动端查看已配对桌面的会话列表，订阅终端输出并执行远程输入或控制。

## 证书说明

项目默认使用自签名证书。

如果你重新生成服务端证书，需要同步更新以下文件:

- `server/certs/server.crt`
- `desktop/assets/server.crt`
- `mobile-android/app/src/main/res/raw/server_cert.crt`

根目录 `start.ps1` 已内置证书生成与复制流程，适合在 Windows 开发环境下快速操作。

## 当前实现说明

- 产品当前名称为 `TermSync`。
- 仓库目录、部分类名、日志和 UI 文案中仍保留 `tty1` / `TTY1` 的历史命名，这是迁移遗留，不影响当前架构和运行。
- 桌面端当前已经包含终端回放中继与 AI 助手面板。

## 参考文档

- `docs/architecture.md`
- `server/README.md`
- `desktop/README.md`
- `mobile-android/README.md`
