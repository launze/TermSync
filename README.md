# TermSync

> 手机上的终端入口，桌面上的真实终端。

`TermSync` 是一个跨平台终端同步项目：真实终端进程运行在桌面端，服务端负责认证、配对与消息中继，Android 客户端负责远程查看、输入和控制已经配对的桌面会话。

当前公开版本：**`0.1.0`**

## 核心特性

- **桌面端持有真实 PTY**
- **Android 远程查看与输入终端**
- **服务端负责认证、配对和消息中继**
- **自签名证书分发，适合局域网/自部署场景**
- **桌面端集成 AI 助手面板**
- **跨平台桌面目标**：Windows / macOS / Linux

## 仓库结构

```text
tty1/
├── desktop/         # 桌面客户端 (Rust + Tauri + xterm.js)
├── mobile-android/  # Android 客户端 (Kotlin + Compose + WebView)
├── server/          # 服务端 (Go + SQLite)
├── docs/            # 架构与实现文档
├── start.ps1        # Windows 开发启动脚本
└── README.md
```

## 组件说明

### Desktop Client
桌面应用负责：
- 创建和持有本地真实终端会话
- 渲染终端 UI 与多标签页/分屏布局
- 接收移动端输入并写入 PTY
- 将终端输出同步给远端客户端
- 提供 AI 辅助命令面板

### Android Client
Android 应用负责：
- 查看已配对桌面的活动终端
- 发送输入、快捷键和控制命令
- 远程订阅终端输出
- 在移动端提供轻量终端操控体验

### Relay Server
服务端负责：
- 注册设备与登录认证
- 生成和完成配对码流程
- 中继桌面端与移动端消息
- 提供证书下载与健康检查接口

## 技术栈

### Desktop
- Rust
- Tauri 2
- Tokio
- xterm.js

### Android
- Kotlin
- Jetpack Compose
- OkHttp
- WebView

### Server
- Go
- Chi
- SQLite
- WebSocket

## 快速开始

## 1. 启动服务端

```bash
cd server
make all
./termsync-server
```

默认端口：
- `7373`: HTTPS / WSS
- `8080`: HTTP 重定向

常用环境变量：
- `TERMSYNC_PORT`
- `TERMSYNC_HTTP_PORT`
- `TERMSYNC_DB_PATH`
- `TERMSYNC_JWT_SECRET`

## 2. 启动桌面端

```bash
cd desktop/src-tauri
cargo tauri dev
```

构建发布版：

```bash
cd desktop/src-tauri
cargo tauri build
```

## 3. 构建 Android 客户端

在 Android Studio 中直接打开 `mobile-android` 运行，或者使用命令行：

```bash
cd mobile-android
./gradlew assembleRelease
```

Windows 下：

```powershell
cd mobile-android
.\gradlew.bat assembleRelease
```

## 使用流程

### 局域网 / 自部署模式
1. 启动服务端
2. 启动桌面端并完成登录
3. 在桌面端生成 6 位配对码
4. 在 Android 客户端输入配对码完成绑定
5. 在移动端查看终端列表并开始远程操作

## 证书说明

项目默认使用自签名证书。

如果重新生成服务端证书，需要同步更新：
- `server/certs/server.crt`
- `desktop/assets/server.crt`
- `mobile-android/app/src/main/res/raw/server_cert.crt`

根目录 `start.ps1` 已包含生成证书并分发到各端的便捷流程。

## GitHub Actions 与 Release

项目已提供两套工作流：

- `.github/workflows/quick-build.yml`
  - 针对 `dev` / `develop` 分支进行快速构建校验
  - 包含 server / android / desktop 三端基础构建
- `.github/workflows/build-all.yml`
  - 针对 `main` / `master` 分支和 `v*` 标签执行完整构建
  - 自动打包服务端、Android APK、桌面端安装包
  - 推送 `v0.1.0` 这类标签时自动创建 GitHub Release

典型 Release 产物命名：

- `termsync-server-linux-x64-v0.1.0`
- `termsync-android-v0.1.0.apk`
- `termsync-desktop-windows-x64-v0.1.0.msi`
- `termsync-desktop-windows-x64-v0.1.0-setup.exe`
- `termsync-desktop-macos-x64-v0.1.0.dmg`
- `termsync-desktop-macos-arm64-v0.1.0.dmg`
- `termsync-desktop-linux-x64-v0.1.0.deb`
- `termsync-desktop-linux-x64-v0.1.0.AppImage`

## 当前状态

`0.1.0` 可视为当前对外发布起点版本。

当前仓库仍保留少量 `tty1` 历史命名，但项目产品名、服务名和 UI 主文案以 `TermSync` 为主。

## 参考文档

- `docs/architecture.md`
- `docs/implementation-checklist.md`
- `server/README.md`
- `desktop/README.md`
- `mobile-android/README.md`
