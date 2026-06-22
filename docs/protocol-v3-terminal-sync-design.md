# TermSync Protocol v3 终端同步协议设计

更新时间: 2026-06-21

状态: v3-only 改造进行中。服务端已切换为 v3-only，不再兼容旧 `session.*` / `terminal.*` WebSocket 协议；桌面端和 Android 已接入 v3 auth、workspace/layout、snapshot-backed layout.patch、screen snapshot/delta、resync、screen.ack 和 input.send 的基础链路。桌面 owner 已对 screen delta 做短窗口合并，在写入 PTY 前按 `input_id` 二次去重，并接入 xterm serialize addon 生成 VT screen snapshot。PC receiver 已改为按 v3 layout snapshot 直接同步 tab/pane/root，支持协议字符串 `pane_id` 到本地 numeric pane 的稳定映射，并且只为当前可见 tab 的 pane 订阅 screen，切换/移除 pane 时发送 `screen.unsubscribe`。Android 已改为详情页只订阅当前 pane screen，提供同标签 pane 切换入口，首页按 v3 `tab.root` 显示可点击 split tree 预览，并在后台退订 screen、回前台重新订阅恢复 snapshot。精细 layout diff、Android 详情页多 pane 同屏渲染、cell-level 快照仍属于后续完善项。

本文用于替代当前 v2 中“输出追加 + 回放 + viewer resize owner PTY”的协议思路。目标是让 PC 接收端和 Android 手机端统一为 viewer，并稳定支持 Codex、vim、top、fzf、tmux、less 等 TUI 程序。

## 0. 当前落地状态

更新时间: 2026-06-21

| 模块 | 状态 |
|------|------|
| Server auth | 已要求 v3，旧客户端不再通过协议协商 |
| Server connection | 已加入 `connection_id`、`client_instance_id`、旧连接 retired 检查 |
| Server layout | 已支持 `workspace.list`、`workspace.subscribe`、`layout.snapshot/patch`、`layout.action_request` |
| Server screen | 已支持 `screen.subscribe`、`screen.snapshot`、`screen.delta`、`screen.ack`、`screen.resync_request` 的基础路由、缓存、ack lag 降级和 outbound backlog 降级 |
| Server input | 已支持 `input.send`、`input_id` 去重和 owner 转发 |
| Desktop owner | 连接时发布 `layout.snapshot`，日常变更发布 snapshot-backed `layout.patch`，合并发布 `screen.delta`，用 xterm serialize 生成 `screen.snapshot`，并处理 `input.send` / `layout.action_request` / `screen.resync_request` |
| PC receiver | 已使用 v3 workspace/screen/input 基础链路，已按 seq 断档请求 resync 并发送 screen ack；`layout.snapshot/patch` 已按 v3 tab/pane/root 直接应用，协议 `pane_id` 与本地 pane id 解耦，只订阅当前可见 tab 的 pane，切换/移除时会 `screen.unsubscribe` |
| Android | 已使用 v3 auth、workspace/layout、screen snapshot/delta、resync、screen ack、input.send；列表按 tab/pane 分组并按 `tab.root` 渲染 split tree 预览，详情页只订阅当前 pane 并可在同标签 pane 间切换，后台会 `screen.unsubscribe`，前台重新订阅 |
| 未完成 | 精细 layout diff patch、Android 详情页多 pane 同屏渲染、cell-level 快照、队列内旧 delta 精细丢弃 |

## 1. 背景问题

当前 v2 协议把终端输出作为 `terminal.output.payload.data` 直接广播，viewer 侧再写入 xterm.js。这个模型对普通 shell 日志可用，但对 TUI 不稳:

- TUI 程序通过 ANSI/VT 控制序列频繁重绘屏幕，不是追加日志。
- viewer resize 转发到 owner PTY 后，会触发 TUI 整屏重绘，形成“接收端尺寸变化 -> 发送端重绘 -> 输出广播 -> 接收端重排”的循环。
- `session.state` 和 layout 同步如果驱动 xterm DOM 重建，会导致屏幕闪烁和资源占用。
- replay 依赖 owner 当前缓冲，重新订阅时容易把历史内容重复写入。
- PC 接收端和 Android 端现在协议行为不完全一致，后续维护成本高。

## 2. 开源方案调研结论

调研对象:

- xterm.js: Web 终端渲染基础设施，被 VS Code、ttyd、GoTTY 等使用。
- ttyd / GoTTY / WeTTY: WebSocket + browser terminal 的典型实现。
- tmate / tmux / Upterm: 多客户端共享终端会话的典型实现。
- VS Code integrated terminal: 持久会话、shell integration、键盘路由和本地回显策略。

结论不是“把当前输出去重一下”，而是协议层必须承认 terminal 是状态机。TUI 程序输出的 VT/ANSI 序列会移动光标、清屏、改属性、切换 alternate screen、响应 resize，不能当成普通文本日志追加。

### 2.1 xterm.js / ttyd / WeTTY 类 Web Terminal

xterm.js 的官方定位是浏览器中的完整终端模拟器，明确支持 bash、vim、tmux 等 curses/TUI 程序和鼠标事件。xterm.js 官方也提供 `@xterm/addon-attach`，用于把终端连接到 WebSocket 进程通道。

ttyd 和 WeTTY 这类项目的共同实践是:

- server/agent 侧拥有真实 PTY。
- browser/client 侧使用 xterm.js 作为渲染器。
- 输入按字符/按键实时发送，不等待整行命令。
- 输出保持 VT/ANSI 字节流语义，不把 TUI 输出解析成普通文本。
- resize 是 owner PTY 的敏感操作，必须受控，不能由任意 viewer 持续驱动。

### 2.2 tmate / tmux 类 Terminal Sharing

tmate 基于 tmux，核心价值不是“把文本广播给客户端”，而是用一个权威 terminal session/multiplexer 管理真实会话，客户端只是 attach 到同一个会话。它天然支持:

- read-only / read-write 连接区分。
- 多客户端加入/离开。
- TUI 稳定显示。
- session 生命周期独立于某个 viewer。

TermSync 不一定要引入 tmux，但应借鉴它的原则: `session owner/multiplexer` 是唯一权威，viewer 不能反向改变会话基础状态。

### 2.3 xterm serialize / persistent terminal

xterm serialize addon 能把 terminal framebuffer 序列化成可重新 `write()` 的 VT 字符串，用于恢复屏幕状态。VS Code 的 terminal 设计也把“终端进程持久性”和“shell integration 元数据”分开处理: 屏幕由终端流维护，cwd/命令检测等是辅助元数据，不驱动 terminal 重新渲染。

对 TermSync 的启发:

- 新 viewer 加入时，不应要求 owner 重放完整历史输出。
- 应有可缓存的 screen snapshot。
- TUI 屏幕恢复应以 terminal framebuffer / VT snapshot 为准，而不是普通文本行。
- activity/task_state 这类摘要不能反向影响 terminal 渲染。

### 2.4 对 TermSync 的取舍

| 方案 | 可借鉴点 | 不直接采用的原因 |
|------|----------|------------------|
| ttyd / GoTTY | WebSocket 转发 PTY I/O，浏览器用 xterm.js 渲染 | 主要是单命令/单窗口共享，不覆盖 TermSync 的标签、分屏、PC 接收端和手机端统一布局 |
| tmux / tmate | 一个权威 multiplexer 管理真实会话，多客户端 attach | 引入 tmux 会改变 Windows 原生体验；TermSync 需要跨平台内建 layout |
| Upterm | Host 拥有真实 session，客户端连接可走 SSH/WebSocket，并支持访问控制 | TermSync 已有配对和 WSS 中继，适合借鉴 host/client 权限模型而不是替换传输栈 |
| VS Code terminal | 持久会话、screen 恢复、shell metadata 分离、键盘路由 | VS Code 是单机/远程开发架构，TermSync 需要跨设备同步协议 |

因此 v3 的最佳方向是: 保留 TermSync 自己的配对/中继/桌面 PTY 架构，但把协议改成“权威 owner + 独立 layout stream + 独立 screen stream + raw input stream + snapshot/resync”。

## 3. v3 设计目标

1. 发送端真实 PTY 权威

真实 PTY 只运行在 desktop owner。PC 接收端和 Android 都是 viewer。viewer 只能发送输入和 workspace action request，不能直接 resize owner PTY。

2. 终端流和布局流分离

终端屏幕同步不触发布局重建。布局变更不触发终端 replay。二者都有独立版本号。

3. 支持 TUI

输出层保留 VT/ANSI 语义，viewer 端用 xterm.js 消费。对 Codex、vim、top 等 TUI 不做文本追加假设。

4. 支持迟到 viewer

新 viewer 订阅 pane 后先收到 screen snapshot，再收到按序增量。无需 owner 每次重新生成大 replay。

5. PC 和 Android 统一协议

`pc_receiver` 和 `mobile` 都使用相同 viewer 消息、权限和订阅语义。UI 能力不同，但协议一致。

6. 高速输出可控

每个 pane 的 screen stream 有 seq、ack、背压和丢帧策略。TUI 高频刷新时，宁可合并帧，也不能无限堆积。

## 3.1 协议不变量

这些规则必须作为 v3 实现的硬约束，用于防止当前“重复执行、循环显示、分屏狂闪”的问题重新出现。

1. viewer 永远不发布 terminal output。
2. viewer 永远不自动 resize owner PTY。
3. layout 更新不能清空 terminal screen。
4. screen delta 不能创建、关闭、重命名 tab/pane。
5. metadata 更新不能触发 replay。
6. input 不做本地 echo，必须等待 owner PTY 输出回显。
7. 每条 input 必须有 `input_id`，server 和 owner 都要去重。
8. 每个 pane 的 screen stream 必须单调递增 seq。
9. viewer 发现 seq 缺口只能 resync，不能猜测补写。
10. 同一设备新连接成功后，server 必须踢掉旧连接或将旧连接标记 retired，旧连接消息一律丢弃。

## 3.2 为什么不能只做“重复不发”

当前问题的关键不是某一层多发了一条字符串，而是 TUI 链路中有多个反馈环:

- viewer fit/resize -> owner PTY resize -> TUI 整屏重绘 -> output 广播 -> viewer layout 重排。
- `session.state` -> viewer 重新挂载 xterm -> replay -> output 看起来重复。
- PC receiver 新建/关闭布局 -> server 转发 -> owner 应用 -> receiver 同时本地乐观创建和远端 patch 创建。
- 旧客户端仍在线 -> 同一 viewer 的输入被多个连接重复发送。

v3 要从协议上切断反馈环，而不是只在某个字段上做内容去重。内容去重还会误伤合法 TUI 输出，例如进度条、spinner、alternate screen 重绘、Codex 状态区刷新。

## 4. 角色模型

### 4.1 设备类型

- `desktop`
  - 可以成为 workspace owner。
  - 拥有真实 PTY。
  - 负责产生 screen stream、layout state、session metadata。

- `pc_receiver`
  - viewer。
  - 可查看完整 tab/pane 布局。
  - 可发送输入。
  - 可请求新建、关闭、分屏、重命名。
  - 不可 resize owner PTY。

- `mobile`
  - viewer。
  - 可查看完整布局，也可只展示单 pane/单 tab。
  - 可发送输入和特殊键。
  - 可请求新建/关闭。
  - 不可 resize owner PTY。

### 4.2 权限

| 能力 | desktop owner | pc_receiver | mobile |
|------|---------------|-------------|--------|
| 创建真实 PTY | 是 | 否 | 否 |
| 关闭真实 PTY | 是 | 请求 owner | 请求 owner |
| resize 真实 PTY | 是 | 否 | 否 |
| 发送输入 | 是 | 是，需订阅/授权 | 是，需订阅/授权 |
| 发送终端输出 | 是 | 否 | 否 |
| 发布 layout snapshot | 是 | 否 | 否 |
| 请求 layout action | 本地执行 | 是 | 是 |
| 接收 screen snapshot/patch | 可选 | 是 | 是 |

## 5. 核心状态对象

### 5.1 Workspace

workspace 表示一个 desktop owner 当前共享的终端工作区。

```json
{
  "workspace_id": "desktop-device-id:default",
  "owner_device_id": "desktop-device-id",
  "layout_version": 42,
  "active_tab_id": "tab-1",
  "tabs": [],
  "updated_at": 1782036000
}
```

### 5.2 Tab

```json
{
  "tab_id": "tab-1",
  "title": "ppAI",
  "order": 0,
  "active_pane_id": "pane-1"
}
```

### 5.3 Pane

```json
{
  "pane_id": "pane-1",
  "session_id": "local-44",
  "title": "codex",
  "order": 0,
  "status": "active",
  "cols": 120,
  "rows": 36,
  "cwd": "E:\\Work\\Code\\ppAI",
  "program": "codex",
  "task_state": "running",
  "activity": "gpt-5.5 high · E:\\Work\\Code\\ppAI",
  "preview": ""
}
```

### 5.4 Split Tree

split tree 只描述布局，不描述终端内容。

```json
{
  "type": "horizontal",
  "children": [
    { "type": "leaf", "pane_id": "pane-1", "size": 0.5 },
    { "type": "leaf", "pane_id": "pane-2", "size": 0.5 }
  ]
}
```

### 5.5 Screen Stream

每个 pane 有独立 screen stream。

```json
{
  "pane_id": "pane-1",
  "session_id": "local-44",
  "stream_id": "local-44:1",
  "seq": 1024,
  "snapshot_seq": 1000,
  "cols": 120,
  "rows": 36
}
```

## 6. 消息 Envelope

v3 继续使用 JSON envelope，但必须加入协议版本、消息 id 和版本/序列语义。

```json
{
  "type": "screen.delta",
  "v": 3,
  "id": "01J...",
  "workspace_id": "desktop-device-id:default",
  "pane_id": "pane-1",
  "session_id": "local-44",
  "timestamp": 1782036000,
  "payload": {}
}
```

字段规则:

- `v`: 协议版本，v3 必填。
- `id`: 发送方生成的消息 id，用于去重和日志。
- `workspace_id`: workspace 相关消息必填。
- `pane_id`: pane/screen/input 相关消息必填。
- `session_id`: 兼容现有 PTY session，v3 内不再作为布局主键。
- `timestamp`: Unix 秒或毫秒，服务端用于审计和过期保护。

### 6.1 连接实例与旧客户端处理

`auth` 必须增加 `client_instance_id` 和 `connection_generation`:

```json
{
  "type": "auth",
  "v": 3,
  "payload": {
    "token": "...",
    "device_type": "pc_receiver",
    "client_instance_id": "pc-receiver-boot-uuid",
    "connection_generation": 17,
    "supported_protocols": [3]
  }
}
```

server 规则:

- 同一个 `device_id` 只能有一个 active connection。
- 新连接认证成功后，旧连接收到 `peer.replaced` 后关闭。
- 如果旧连接仍然发消息，server 按 `connection_id` 丢弃，并记录日志。
- 所有 viewer action/input 都带 `client_instance_id`，便于定位重复来源。
- server 不做旧协议协商；`supported_protocols` 不包含 3 或消息 `v != 3` 时直接拒绝。

这能直接回答“是不是旧客户端还在线”: v3 下即使旧客户端没退出，也不能继续影响 owner。

### 6.2 编码与传输

第一阶段使用 JSON envelope + base64 payload，兼容当前 Rust/Go/Kotlin 栈:

- `screen.delta.payload.data`: `base64+vt`
- `screen.snapshot.payload.data`: `base64+vt`
- `input.send.payload.data`: `base64`

第二阶段可引入 binary WebSocket frame:

- JSON control frame 只传 envelope 和 metadata。
- 大的 VT payload 用 binary frame，按 `message_id` 关联。
- Android WebView 仍可在 native 层转成 base64 调 JS，避免 JS bridge 直接处理任意二进制。

无论是否使用 binary frame，协议语义不变。

## 7. 消息类型

### 7.1 Auth / Peer

| 类型 | 方向 | 说明 |
|------|------|------|
| `auth` | client -> server | 带 token、device_type、supported_protocols |
| `auth.ok` | server -> client | 返回 device_id、device_type、selected_protocol |
| `auth.error` | server -> client | 认证失败 |
| `peer.state` | server -> client | 已配对设备在线状态 |

`auth` 示例:

```json
{
  "type": "auth",
  "v": 3,
  "payload": {
    "token": "...",
    "device_type": "pc_receiver",
    "supported_protocols": [3],
    "client": {
      "platform": "windows",
      "app_version": "0.1.9"
    }
  }
}
```

### 7.2 Workspace / Layout

| 类型 | 方向 | 说明 |
|------|------|------|
| `workspace.list` | viewer -> server | 请求可见 workspace |
| `workspace.list_res` | server -> viewer | 返回已配对 desktop 的 workspace 摘要 |
| `workspace.subscribe` | viewer -> server | 订阅 workspace layout |
| `workspace.unsubscribe` | viewer -> server | 退订 workspace |
| `layout.snapshot` | owner/server -> viewer | 完整布局快照 |
| `layout.patch` | owner/server -> viewer | 增量布局变化 |
| `layout.action_request` | viewer -> server -> owner | viewer 请求 owner 执行动作 |
| `layout.action_result` | owner/server -> viewer | 请求结果 |

布局动作枚举:

- `new_tab`
- `close_tab`
- `rename_tab`
- `split_pane`
- `close_pane`
- `rename_pane`
- `move_pane`
- `resize_split`
- `set_active_tab`
- `set_active_pane`

原则:

- owner 是布局权威。
- viewer 发 `layout.action_request`，不得直接发布 `layout.patch`。
- owner 执行动作后发布新的 `layout.patch` 或 `layout.snapshot`。
- viewer 收到 layout 更新时只更新布局 DOM；不清空 screen，不 replay。

### 7.3 Screen

| 类型 | 方向 | 说明 |
|------|------|------|
| `screen.subscribe` | viewer -> server | 订阅某个 pane 的屏幕流 |
| `screen.unsubscribe` | viewer -> server | 退订屏幕流 |
| `screen.snapshot` | server/owner -> viewer | 当前 framebuffer 快照 |
| `screen.delta` | owner/server -> viewer | VT/ANSI 增量输出 |
| `screen.ack` | viewer -> server | viewer 已处理到某个 seq |
| `screen.resync_request` | viewer -> server | seq 缺口或渲染异常，请求快照 |
| `screen.clear` | owner/server -> viewer | 会话重启/PTY 重建，清空并等待 snapshot |

#### screen.snapshot

推荐短期格式: `encoding = "vt"`，payload 是可写入 xterm 的 VT 字符串。来源可以是 owner 维护的 xterm/terminal buffer serialize。

```json
{
  "type": "screen.snapshot",
  "v": 3,
  "workspace_id": "desktop:default",
  "pane_id": "pane-1",
  "session_id": "local-44",
  "payload": {
    "stream_id": "local-44:1",
    "snapshot_seq": 1200,
    "cols": 120,
    "rows": 36,
    "encoding": "base64+vt",
    "data": "G1s..."
  }
}
```

长期可选格式: `encoding = "cells"`，直接传行/单元格模型，用于更精确的 patch。但第一阶段不建议直接做 cells patch，复杂度高。

#### screen.delta

```json
{
  "type": "screen.delta",
  "v": 3,
  "workspace_id": "desktop:default",
  "pane_id": "pane-1",
  "session_id": "local-44",
  "payload": {
    "stream_id": "local-44:1",
    "seq": 1201,
    "prev_seq": 1200,
    "encoding": "base64+vt",
    "data": "..."
  }
}
```

规则:

- delta 是 PTY 输出的 VT/ANSI 字节流，不做文本摘要解析。
- viewer 必须按 seq 顺序写入 xterm。
- seq 缺失时 viewer 发送 `screen.resync_request`。
- 服务端可缓存最近 N 秒或 N MB delta ring。
- 服务端不能解析 terminal 内容，只做缓存和路由。

### 7.4 Input

| 类型 | 方向 | 说明 |
|------|------|------|
| `input.send` | viewer/server -> owner | 写入 PTY stdin |
| `input.ack` | owner/server -> viewer | 可选，确认输入已转交 owner |
| `input.reject` | server -> viewer | 权限/会话状态拒绝 |

```json
{
  "type": "input.send",
  "v": 3,
  "workspace_id": "desktop:default",
  "pane_id": "pane-1",
  "session_id": "local-44",
  "payload": {
    "input_id": "viewer-device:000123",
    "encoding": "base64",
    "data": "Y29kZXgNCg==",
    "mode": "raw"
  }
}
```

规则:

- 输入永远是 raw terminal input，支持单字符、控制键、组合键。
- 不按命令行聚合，避免破坏 TUI。
- server 和 owner 都用 `input_id` 去重。
- owner 写入 PTY 后本地 PTY 输出自然经 `screen.delta` 回显；viewer 不本地 echo。

### 7.5 PTY Lifecycle

| 类型 | 方向 | 说明 |
|------|------|------|
| `pty.create` | owner -> server | owner 发布真实 PTY 创建 |
| `pty.ready` | owner -> server/viewer | PTY 可用 |
| `pty.exit` | owner -> server/viewer | PTY 退出 |
| `pty.close` | owner -> server/viewer | PTY 已关闭 |
| `pty.error` | owner/server -> viewer | PTY 错误 |

viewer 请求创建/关闭仍走 layout action:

- `layout.action_request { action: "new_tab" }`
- `layout.action_request { action: "close_pane" }`

owner 应用后再发布 `pty.create` / `pty.close` 和 layout patch。

### 7.6 Metadata

| 类型 | 方向 | 说明 |
|------|------|------|
| `pane.meta` | owner -> server/viewer | cwd/program/title/task_state/activity/preview |
| `pane.meta.patch` | owner/server -> viewer | 元数据变化 |

原则:

- metadata 不驱动 xterm screen 重绘。
- metadata 不触发 layout DOM 重建，除非标题显示实际变化。
- TUI 装饰行、状态栏、spinner 不应频繁改变 task_state。
- shell integration 可用于 cwd/command detection，但不是 screen truth。

## 8. Resize 策略

v3 明确禁止 viewer resize owner PTY。

原因:

- 手机/PC 接收端尺寸和发送端 pane 尺寸不同。
- TUI 会对 resize 触发整屏重绘，容易形成循环。
- 多 viewer 尺寸冲突无法一致解决。

owner PTY 尺寸来源:

1. desktop owner 本地 pane 尺寸。
2. owner 用户显式设置的共享固定尺寸，例如 120x36。
3. 可选: owner 接受某个 viewer 的 `viewport.suggest`，但必须是手动或策略明确的 opt-in。

viewer 本地行为:

- `pc_receiver`: xterm 本地 fit 显示 owner 尺寸；可滚动或缩放，不回传 resize。
- `mobile`: 默认 `DesktopMirror`，按 owner cols/rows 渲染，可缩放字体；`MobileFit` 仅改变本地显示，不改变 owner PTY。

可选消息:

| 类型 | 方向 | 说明 |
|------|------|------|
| `viewport.report` | viewer -> server/owner | 仅用于诊断和 UI 提示，不影响 PTY |
| `viewport.suggest` | viewer -> owner | 请求 owner 改为某尺寸，默认不自动执行 |

### 8.1 手机端显示策略

Android 默认使用 `DesktopMirror`:

- 以 owner pane 的 `cols/rows` 创建 xterm。
- 用字体缩放、横向滚动、双指缩放或全屏横屏适配手机。
- 不把 WebView fit 后的 `cols/rows` 发回 owner。

`MobileFit` 只能作为本地视图模式:

- 改变本地字体、缩放或 viewport。
- 不改变 owner PTY。
- 不触发 `terminal.resize`。

手机后台/锁屏:

- 自动 `screen.unsubscribe` 或降低订阅到 metadata-only。
- 回到前台后 `screen.subscribe`，拿 snapshot + delta ring。
- 不依赖本地缓存作为权威屏幕。

## 9. Server 职责

服务端在 v3 中仍不执行命令，不解析 terminal 内容，但需要承担更明确的状态缓存。

### 9.1 必须维护

- 在线设备连接。
- 配对关系。
- workspace latest layout snapshot。
- pane/session metadata。
- 每个 pane 的 screen latest snapshot。
- 每个 pane 最近 delta ring。
- viewer subscriptions。
- input_id / message_id 去重窗口。

### 9.2 不应做

- 不解析 ANSI。
- 不把 terminal output 转成普通文本摘要。
- 不允许 viewer 直接修改 owner PTY 尺寸。
- 不在 session.state 到达时触发 screen replay。

### 9.3 服务端是否必须更新

必须更新。

原因是 v3 不只是客户端行为调整，而是协议权威关系变化:

- server 必须拒绝旧协议，只接受 `v:3` 消息。
- server 要维护 workspace/layout 最新快照。
- server 要维护 screen snapshot 和 delta ring。
- server 要按 subscription 路由 screen，而不是按 session 全量广播。
- server 要按 `input_id`、`message_id`、`connection_id` 做去重和旧连接隔离。
- server 要实现 per-viewer backpressure，否则 TUI 高频输出会拖垮慢设备。

如果 server 仍只是 v2 relay，客户端即使改好也无法可靠解决重复输入、旧连接、多 viewer 尺寸冲突和重连恢复。

## 10. Owner Desktop 职责

desktop owner 是真实终端权威。

必须维护:

- PTY lifecycle。
- workspace layout state。
- 每个 pane 的 screen stream seq。
- 每个 pane 的 headless/hidden terminal buffer，用于生成 snapshot。
- replay/snapshot 生成。
- input 去重和写入。

推荐实现:

- 当前前端 xterm 继续用于本地显示。
- 增加 per-pane screen model:
  - 短期: 已使用 xterm.js serialize addon 在前端生成 snapshot。
  - 中期: 使用 Rust/JS headless terminal emulator 维护 owner-side framebuffer。
- `pty-output` 进入两条链:
  - owner 本地 xterm display。
  - screen stream publisher。
- `applySessionOutput()` 只更新 metadata，不再作为 screen 恢复依据。

## 11. Viewer 职责

PC 接收端和 Android 手机端统一实现:

1. 连接后 `workspace.list`。
2. 选择 workspace 后 `workspace.subscribe`。
3. 按 layout snapshot 创建本地 tabs/panes。
4. 对可见 pane 执行 `screen.subscribe`。
5. 收到 `screen.snapshot`:
   - clear local xterm。
   - write snapshot data。
   - 记录 snapshot_seq。
6. 收到 `screen.delta`:
   - 校验 seq。
   - 顺序 write 到 xterm。
   - 定期 `screen.ack`。
7. 输入时发送 `input.send`。
8. 新建/关闭/改名/分屏时发送 `layout.action_request`。

移动端优化:

- 列表页可以只订阅 metadata，不订阅 screen。
- 进入终端详情才订阅该 pane screen。
- 后台时退订 screen，回到前台重新订阅当前 pane 并以 snapshot 恢复。
- 保留本地近期 snapshot/delta cache，但以 server snapshot 为权威。

## 12. Backpressure 与丢帧策略

TUI 高频输出时不能无限排队。

推荐策略:

- owner 为每个 pane 合并 16ms-50ms 内的小 delta。
- server 每个 viewer 每个 pane 维护 outbound queue 限额。
- queue 超限时:
  1. 丢弃未发送 delta。
  2. 标记 viewer 需要 resync。
  3. 下一次发送 `screen.snapshot`。
- viewer 如果发现 `prev_seq != last_seq`，立即 `screen.resync_request`。
- snapshot 频率限流，例如同一 pane 同一 viewer 2 秒内最多 1 次，除非 stream_id 改变。

当前基础实现:

- viewer 收到并应用 snapshot/delta 后发送 `screen.ack`。
- desktop owner 已用约 32ms 窗口合并同 pane 的 PTY output chunk，再生成单调递增 `screen.delta`。
- server 记录每个 pane/viewer 的 `last_ack_seq`、`last_sent_seq` 和 `needs_resync`。
- 当 viewer ack 落后当前 delta 超过窗口时，server 标记该 viewer `needs_resync`，跳过后续 delta，并向 viewer 发送缓存 snapshot；如果没有 snapshot，则向 owner 发 `screen.resync_request`。
- 当 viewer 的实际 WebSocket outbound queue backlog 超过 screen delta 水位时，server 按该 pane/viewer 标记 `needs_resync`，跳过后续 delta，并优先触发 snapshot resync。
- 后续可继续优化为队列内旧 delta 精细丢弃，目前基础策略是在新 delta 入队前降级，避免继续堆积过期帧。

## 13. Replay 替代方案

v3 不再使用 `terminal.replay_request` / `terminal.replay` 作为核心恢复机制。

替代:

- `screen.snapshot`: 当前屏幕和可选 scrollback。
- `screen.delta ring`: snapshot 后的增量补齐。
- `screen.resync_request`: 异常恢复。

当前实现不设兼容期:

- v3 client 不再请求 replay。
- server 不再接受 v2 replay/input/output/session 消息。
- 旧客户端必须升级，否则连接或消息会被拒绝。

## 14. v3-only 改造计划

### Phase 0: 冻结旧问题面

- viewer resize owner PTY 在服务端禁用。
- PC/Android viewer 本地 resize 不再发送 `terminal.resize`。
- session.state 不触发 screen replay 和 terminal DOM 重建。

### Phase 1: v3 Envelope 与连接隔离

- `auth` 使用 `supported_protocols=[3]`。
- server 返回 selected protocol 3。
- server 拒绝 `v != 3` 的消息。
- 同一设备新连接会 retire 旧 connection。

### Phase 2: Workspace/Layout v3

- 增加 `workspace.*` 和 `layout.*`。
- owner 发布 `layout.snapshot`。
- owner 对日常新建/关闭/改名/分屏发布 snapshot-backed `layout.patch`。
- PC receiver 用 layout snapshot 直接重建 tabs/panes/root，并按 pane 生命周期订阅/退订 screen。
- Android 列表按 tab/pane 分组显示，并用 `tab.root` 展示 split tree 预览；终端详情仍单 pane 渲染，但可切换同标签 pane，且只订阅当前 pane screen。

### Phase 3: Screen Snapshot/Delta

- owner 为每个 pane 维护 screen seq。
- server 缓存 snapshot + delta ring。
- viewer 使用 `screen.subscribe`。
- v3 viewer 停用 replay。

### Phase 4: Backpressure / Ack

- 已增加基础 `screen.ack`。
- 已增加 ack 落后窗口和 `needs_resync` 标记。
- 已增加 server per-connection outbound queue 限额，所有下发消息由单 writer 串行写入 WebSocket。
- 已增加 screen delta 入队前的 viewer backlog 降级，优先跳过 delta 并触发 snapshot resync。

### Phase 5: Metadata 清理

- shell integration 专注 cwd/command metadata。
- Codex/TUI 状态栏不再导致 task_state 高频抖动。
- task_state 更新限流和稳定化。

## 14.1 模块实施清单

### Server: `server/`

1. 在 `models` 增加 v3 envelope、workspace/layout/screen/input 类型。
2. 在 WS auth 中加入 `supported_protocols`、`client_instance_id`、`connection_generation`。
3. 在 `relay` 中只保留 v3 router，旧 `session.*` / `terminal.*` 不再作为服务端协议入口。
4. 增加 workspace cache:
   - latest layout snapshot
   - layout version
   - tab/pane index
5. 增加 screen cache:
   - latest snapshot per pane
   - delta ring per pane
   - per-viewer ack
   - per-viewer outbound queue limit
6. 增加去重窗口:
   - `message_id`
   - `input_id`
   - retired `connection_id`
7. 增加 subscription registry:
   - workspace subscriptions
   - screen subscriptions
   - metadata-only subscriptions
8. 删除服务端旧 v2 session/terminal handler 和模型常量。

### Desktop Owner: `desktop/`

1. owner 前端维护 workspace layout state，并发布 `layout.snapshot/patch`。
2. 本地新建/关闭/改名/分屏先改 owner state，再发布 patch。
3. 接收 viewer 的 `layout.action_request`，由 owner 应用，不能让 viewer 本地直接定稿。
4. PTY 输出进入 screen publisher:
   - 生成 per-pane seq
   - 合并 16ms-50ms delta
   - 发布 `screen.delta`
5. 为每个 pane 维护可序列化 terminal buffer:
   - 已接入 xterm serialize addon
   - pane 不可见时也要保持 buffer
6. 接收 `input.send`:
   - 按 `input_id` 去重
   - 写入对应 PTY
   - 不额外 echo
7. 禁止处理 viewer 自动 resize。

### PC Receiver

1. 连接后走 `workspace.list` / `workspace.subscribe`。
2. 根据 `layout.snapshot/patch` 渲染 tabs/splits。
3. 对可见 pane 发送 `screen.subscribe`。
4. screen snapshot/delta 只写入本地 xterm，不反向触发布局。
5. 新建/关闭/改名/分屏只发送 `layout.action_request`。
6. 输入、方向键、Tab、Ctrl 组合键全部走 raw `input.send`。
7. 右方向键/Tab 补全时必须保持 active pane focus:
   - 键盘事件优先交给当前 xterm
   - UI 快捷键只处理非 terminal focus 状态
   - 发送特殊键后主动 refocus 当前 xterm

### Android

1. 与 PC receiver 使用同一 v3 viewer 协议。
2. 首页只订阅 workspace/layout/meta，不订阅所有 screen。
3. 终端详情页只订阅当前 pane screen。
4. 后台退订 screen 或切 metadata-only。
5. 特殊键、方向键、Tab、Ctrl+C 均发 raw input。
6. WebView 尺寸变化只发 `viewport.report`，不 resize owner。
7. 本地缓存只作为进入页面前的占位，收到 snapshot 后必须以 server/owner 为准。

### Compatibility

1. 不兼容 v2 client。
2. v3 client 不发送 `terminal.replay_request` 和 viewer `terminal.resize`。
3. server 日志要打印 selected protocol 和 rejected old connection，方便排查。
4. 发布时必须先升级 server，再升级 desktop owner、PC receiver 和 Android。

## 14.2 关键验收场景

| 场景 | 预期 |
|------|------|
| PC receiver 输入一次 `codex` | owner PTY 只收到一个 `input_id`，只启动一次 |
| Codex TUI 高频刷新 | viewer 不 resize owner，screen seq 连续，无 replay 循环 |
| receiver 右方向键补全 | 输入发到当前 pane，焦点不离开 xterm |
| receiver 按 Tab 补全 | raw `\t` 或等价控制序列到 owner，UI 不抢焦点 |
| owner 新建标签 | receiver/Android 收到 layout patch 自动出现 |
| owner 关闭标签 | receiver/Android 自动删除对应 tab/pane，不只显示“已关闭” |
| receiver 新建标签 | owner 创建真实 PTY 后发布 patch，receiver 按 patch 创建 |
| receiver 关闭标签 | owner 关闭真实 PTY 后发布 patch，receiver 自动移除 |
| 改名 | tab/pane title 通过 layout/meta patch 同步两端 |
| 分屏/关闭分屏 | split tree patch 同步两端 |
| 旧 receiver 仍在线 | server 将旧 connection retired，旧消息被拒绝 |
| Android 后台再前台 | 重新 screen.subscribe，snapshot 恢复当前屏幕 |
| 慢手机网络 | server queue 超限后 snapshot resync，不无限堆积 |

## 15. v2 到 v3 消息映射

| v2 | v3 |
|----|----|
| `session.list` | `workspace.list` |
| `session.list_res` | `workspace.list_res` + `layout.snapshot` |
| `session.state` | `pane.meta` / `layout.patch` |
| `session.subscribe` | `workspace.subscribe` + `screen.subscribe` |
| `terminal.output` | `screen.delta` |
| `terminal.input` | `input.send` |
| `terminal.resize` | owner-only resize；viewer 改为 `viewport.report` |
| `terminal.replay_request` | `screen.resync_request` |
| `terminal.replay` | `screen.snapshot` |
| `session.create_request` | `layout.action_request(new_tab)` |
| `session.close_request` | `layout.action_request(close_pane)` |
| `session.close` | `pty.close` + `layout.patch` |

## 16. 需要保留的现有功能覆盖

| 功能 | v3 覆盖方式 |
|------|-------------|
| PC 发送端本地终端 | desktop owner + PTY lifecycle |
| PC 接收端实时查看 | workspace/layout subscribe + screen subscribe |
| Android 实时查看 | 同 PC viewer 协议，UI 可单 pane |
| 输入命令 | `input.send(mode=raw)` |
| 方向键/Tab/Ctrl+C | `input.send` raw 控制序列 |
| 新建标签 | `layout.action_request(new_tab)` |
| 关闭标签 | `layout.action_request(close_tab)` |
| 分屏 | `layout.action_request(split_pane)` |
| 关闭分屏 | `layout.action_request(close_pane)` |
| 改名 | `layout.action_request(rename_tab/rename_pane)` |
| 发送端动作同步到接收端 | owner 发布 `layout.patch` |
| 接收端动作同步到发送端 | viewer request -> owner apply -> patch |
| TUI 稳定显示 | screen snapshot/delta，viewer 不 resize owner |
| 断线重连 | snapshot + delta ring + resync |
| 多 viewer | server per-viewer subscription/queue/ack |
| 手机端低资源 | only-visible-pane screen subscribe |

## 17. 实现风险

1. Snapshot 生成位置

如果 snapshot 在 owner 前端 xterm 生成，必须确保后台/不可见 pane 也有可靠 terminal buffer。否则需要 headless emulator。

2. xterm serialize 版本

已引入 `@xterm/addon-serialize` 的 UMD vendor 文件；仍需要真实 Codex/vim/tmux 场景验证 alt buffer、scrollback 和当前 vendored xterm 版本的运行兼容性。

3. 大 snapshot 传输

snapshot 需要分片或 size limit。建议默认只保留 viewport + 有限 scrollback。

4. 多端输入冲突

多个 viewer 同时输入会自然写入同一 PTY。需要 UI 显示“谁在输入”或权限开关，但协议只保证顺序和去重。

5. Android WebView 性能

移动端应减少全量 render，优先 delta append；snapshot 只在进入 pane 或 resync 时使用。

## 18. 参考资料

- xterm.js: https://github.com/xtermjs/xterm.js
- xterm.js Terminal API `onWriteParsed`: https://xtermjs.org/docs/api/terminal/classes/terminal/
- xterm serialize addon: https://www.npmjs.com/package/@xterm/addon-serialize
- xterm serialize typings: https://github.com/xtermjs/xterm.js/blob/master/addons/addon-serialize/typings/addon-serialize.d.ts
- ttyd: https://tsl0922.github.io/ttyd/
- WeTTY: https://github.com/butlerx/wetty
- tmate: https://github.com/tmate-io/tmate
- Upterm: https://github.com/owenthereal/upterm
- VS Code terminal advanced / persistent sessions: https://code.visualstudio.com/docs/terminal/advanced
- VS Code shell integration: https://code.visualstudio.com/docs/terminal/shell-integration
