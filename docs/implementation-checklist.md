# TTY1 功能落地清单

更新时间: 2026-04-06

## 审计结论

本次审计重点核对了 `server`、`desktop/src-tauri`、`desktop/src`、`mobile-android/app/src/main/java`。
服务端主链路已具备可用实现，主要未落地点集中在桌面端客户端闭环和 Android 客户端协议/构建链路。

## 清单

| 模块 | 问题 | 影响 | 状态 |
|------|------|------|------|
| Desktop / Tauri | `connect_server`、`disconnect_server`、`subscribe_session`、`unsubscribe_session`、`get_server_status` 为占位实现 | 桌面端无法真实连接服务端 | 已完成 |
| Desktop / PTY | PTY 输出未回传前端，窗口 resize 未实际作用于 PTY | 本地终端无真实输出，分屏/窗口调整不生效 | 已完成 |
| Desktop / Frontend | 每个 pane 没有真实创建后端会话，输入参数与 Tauri 命令不匹配 | 输入落不到 PTY，连接服务端后也不能同步输出 | 已完成 |
| Desktop / Build | `tauri.conf.json` 仍指向不存在的 dev server，Rust 侧缺少可编译状态 | 桌面端无法稳定启动或构建 | 已完成 |
| Mobile / TLS | Android WebSocket 客户端绕过证书校验，没有使用内置证书信任链 | 自签名证书方案未真正落地 | 已完成 |
| Mobile / Protocol | `session.create` 未带 `session_id`，`session.state` / `session.close` 解析与服务端协议不一致 | 移动端无法稳定收发会话状态和关闭事件 | 已完成 |
| Mobile / UX | 会话切换未取消旧订阅，关闭终端页时传空字符串代替空值，默认 URL 未带 `/ws` | 订阅串线，返回列表行为异常，默认连接失败 | 已完成 |
| Mobile / Build | 仓库缺少 Gradle Wrapper 脚本和 `gradle-wrapper.jar`，当前环境默认 JDK 为 11，且无 SDK 路径 | Android 项目无法直接构建 | 已完成 |

## 本次落地内容

### 1. 桌面端

- 补齐了 Tauri 命令层的真实实现，包括连接/断开服务端、同步活动会话、转发终端输出、订阅/退订会话、查询连接状态。
- 将 PTY 读写、resize、退出事件接入前端事件流，前端可以收到真实终端输出。
- 修正了前端 pane 与后端 session 的生命周期绑定，新建标签页和分屏时会自动创建本地 PTY，会话关闭时同步释放。
- Tauri 前端采用单入口 `desktop/src/index.html`，开发态由内置静态服务器直接提供，不再依赖缺失的 `http://localhost:1420` 开发服务器。

### 2. Android 端

- 将 `WssClient` 改为使用 `TTY1Application` 初始化出的证书信任链。
- 修正协议字段和事件名，按服务端当前实现处理 `session.list_res`、`session.state`、`terminal.output`、`session.close`。
- 修正订阅切换和关闭行为，避免旧会话残留订阅。
- 补齐 Gradle Wrapper、JDK 17 指向和本机 SDK 路径，使当前仓库可直接执行 `assembleDebug`。

## 验证

- `go test ./...` 通过
- `cargo check` 通过
- `node --check` 校验 `desktop/src/index.html` 内嵌脚本通过
- `mobile-android\\gradlew.bat assembleDebug` 通过

## 仍需注意

- `mobile-android/local.properties` 和 `mobile-android/gradle.properties` 里的 JDK/SDK 路径是当前机器的本地配置，换机器后需要同步调整。
- 当前 Tauri 实际加载的是 `desktop/src/index.html`；`desktop/src/ui/index.html` 已移除，避免双入口漂移。
- 服务端默认 WSS 端口已切到 `7373`，客户端默认地址也要跟随该端口。
