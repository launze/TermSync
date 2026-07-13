# Spec: 桌面终端推送到手机（Terminal Streaming）

> 状态：Draft（待人工审阅）
> 关联预研：本机 Win11 build 22621；pywinpty 已装、pyte 0.8.2 可装、xterm 4.0.0 与现有 Flutter 依赖零冲突；ConPTY 实测可读到完整 ANSI 字节流（真彩色/清屏/光标定位）。

## 假设（请确认或纠正）

1. 终端运行在开发机本机（Windows，与 agent 同一台 103），不跨机。
2. shell 可选 `pwsh` / `powershell` / `cmd`，默认 `powershell`。
3. 数据走现有 control 通道，不新开物理通道；选路（信令/LAN 直连/公网直连/5G 中转）全部继承现状。
4. 第一版支持多会话（tab 切换），最大并发会话数限制为 5。
5. 断线重连用 pyte 服务端屏幕快照恢复，不做历史滚动回放。
6. 中转服务器（server.js）只做透明转发，本功能不改其核心逻辑。
7. 手机端用 `xterm: ^4.0.0` 渲染，等宽字体保证 TUI 网格对齐。
8. 本功能为纯叠加模块，绝不改动现有远控/视频/选路/文件传输逻辑。

→ 以上有误请现在指出，否则按此推进。

## Objective

让用户在手机 App 上拥有一个**与桌面 1:1 一致**的可交互终端：桌面端新建一个终端（ConPTY），把原始字节流（含全部 ANSI 样式）推送到手机，手机用 xterm.dart 还原渲染，并可反向输入命令。目标是替代“传画面”的方式来做远程命令行/编程（含 Codex、opencode、vim、htop 等 TUI 应用）。

**用户故事**
- 作为开发者，我在手机上打开终端页，新建一个 PowerShell 会话，看到的颜色/光标/对齐和桌面完全一致。
- 我能在手机上敲命令、运行 opencode/codex，界面渲染与桌面无差异。
- 我能同时开多个终端，用 tab 切换。
- 手机断网/切后台再回来，终端自动恢复到当前画面，不花屏、不丢失正在运行的进程。

**成功 = 一致性的三个条件同时满足**
1. 字节零篡改透传（不按行处理、不转码、不 strip ANSI）。
2. 尺寸先对齐再启动（手机算出 cols×rows → 桌面据此建 PTY），resize 实时同步。
3. 手机端等宽字体 + xterm.dart 完整 ANSI 解析。

## Tech Stack

| 端 | 选型 | 版本 | 状态 |
|----|------|------|------|
| 桌面 PTY | pywinpty (winpty) | 已装 | ✅ 实测可用 |
| 桌面屏幕快照 | pyte | 0.8.2 | ✅ 可装（依赖 wcwidth 已满足） |
| 手机渲染 | xterm | ^4.0.0 | ✅ 与现有依赖零冲突 |
| 运行环境 | Python 3.9.5 / Flutter 3.41.9 (Dart 3.11.5) | — | — |

## Commands

```
# 桌面 agent 编译验证
E:\Python\64\3.9.5\python.exe -m py_compile control-agent\src\terminal_manager.py
E:\Python\64\3.9.5\python.exe -m py_compile control-agent\src\agent_simple.py

# 桌面 agent 重启（应用改动）
Stop-Process -Id <pid> -Force
Start-Process pythonw.exe -ArgumentList "agent_simple.py" -WorkingDirectory F:\projects\pocketWindow\control-agent\src -WindowStyle Hidden

# 手机端依赖与静态分析
flutter pub add xterm        # 在 flutter-client 目录
flutter analyze lib\services\terminal_service.dart lib\ui\screens\terminal_screen.dart

# 打包（沿用现有手册）
# 1) 递增 pubspec.yaml 版本号
# 2) python build_release_apk.py
# 3) python server\tools\upload_release.py ...
# 4) pscp 上传到 /vol3/1000/soft/
```

## Project Structure

```
control-agent/src/
  terminal_manager.py        → 新增：多会话管理 + ConPTY + pyte 快照 + 读线程
  agent_simple.py            → 改动：挂载 TerminalManager 实例，路由 terminal.* 消息（最小侵入）

flutter-client/lib/
  services/terminal_service.dart   → 新增：终端会话状态、消息收发、与 control 通道对接
  ui/screens/terminal_screen.dart  → 新增：独立终端页（tab + TerminalView）
  pubspec.yaml                     → 改动：加 xterm 依赖

server/src/server.js         → 不改（仅确认 control 消息大小上限容得下一屏 snapshot）

docs/
  spec-terminal-streaming.md → 本文档
```

## 消息协议（control 通道内 JSON；字节流字段用 base64）

| type | 方向 | 字段 | 说明 |
|------|------|------|------|
| `terminal.open` | 手机→桌面 | `session_id, shell, cols, rows` | 先带尺寸再开，保证 TUI 第一帧正确 |
| `terminal.opened` | 桌面→手机 | `session_id, ok, error?` | 开启回执 |
| `terminal.data` | 桌面→手机 | `session_id, seq, b64` | PTY 输出字节；seq 单调递增 |
| `terminal.input` | 手机→桌面 | `session_id, b64` | 键盘输入字节 |
| `terminal.resize` | 手机→桌面 | `session_id, cols, rows` | PTY.setwinsize + pyte.resize |
| `terminal.close` | 双向 | `session_id, reason?` | 关闭/进程已退出 |
| `terminal.resync` | 手机→桌面 | `session_id, last_seq?` | 重连请求整屏快照 |
| `terminal.snapshot` | 桌面→手机 | `session_id, b64, cols, rows` | pyte dump 的整屏 ANSI，手机 write 后续流 |

## Code Style

Python（桌面）——与现有 agent 一致：snake_case、类型注解、模块级 logger、显式异常处理。

```python
class TerminalSession:
    def __init__(self, session_id: str, shell: str, cols: int, rows: int) -> None:
        self._session_id = session_id
        self._proc = PtyProcess.spawn(self._shell_cmd(shell), dimensions=(rows, cols))
        self._screen = pyte.Screen(cols, rows)
        self._stream = pyte.ByteStream(self._screen)
        self._seq = 0
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
```

Dart（手机）——与现有 service 一致：camelCase、明确类型、StreamController 解耦。

```dart
final terminal = Terminal(maxLines: 4000);
terminal.onOutput = (data) => _send('terminal.input', sessionId, base64Encode(utf8.encode(data)));
void onData(List<int> bytes) => terminal.write(latin1.decode(bytes));
```

## Testing Strategy

- **桌面单元/集成**：临时脚本验证 TerminalSession 起 PTY → 写命令 → 读到 ANSI → pyte 快照 dump 正确（参考预研脚本，跑完即删，不进库）。
- **手机静态**：`flutter analyze` 无 error。
- **手动验收**（分阶段，见下）：在真机上对照桌面验证渲染一致性，重点测 opencode/vim 的网格对齐与断线重连。
- 关键设计约束：PTY `read()` 阻塞 → 每会话独立守护线程读取，绝不在主循环同步 read（预研已踩坑验证）。

## Boundaries

- **Always**：终端模块与现有视频/控制/选路/文件逻辑零耦合；改动 agent_simple.py 仅限挂载与消息路由；每次改 Python 后 py_compile；每次改 Dart 后 flutter analyze；打包前递增 pubspec 版本号。
- **Ask first**：新增 Python/Flutter 依赖（pyte、xterm —— 本 spec 已批准）；改 server.js；改 control 通道消息上限；改任何 UI 之外影响远控的代码。
- **Never**：提交 .env/密钥；改动远控/视频/选路核心；为赶进度跳过 py_compile/analyze；在主循环阻塞 read PTY。

## Success Criteria（可测试）

1. 手机新建 powershell 会话，运行带颜色命令（如 `Write-Host -ForegroundColor Red`），手机显示的前景色/加粗与桌面一致。
2. 手机敲命令能在桌面 PTY 执行并回显（双向交互通）。
3. 手机运行 opencode/vim/htop，界面网格、框线、对齐与桌面 1:1（尺寸协商正确）。
4. 同时开 ≥2 个会话，tab 切换互不串流。
5. 手机断网/切后台 ≥30s 再回来，终端自动恢复当前画面、不花屏，桌面侧进程持续运行。
6. 终端功能开启/使用期间，现有远控视频/文件传输稳定性不受影响。
7. 会话进程退出（输入 exit）后，桌面回收 PTY/线程，手机 tab 显示已关闭。

## 分阶段落地

| 阶段 | 目标 | 验收 |
|------|------|------|
| P1 | 单会话、只读、固定尺寸：起 pwsh，跑 ls/echo，手机看到彩色输出 | 颜色/换行正确 |
| P2 | 加键盘输入 | 双向交互通 |
| P3 | 尺寸协商 + resize：跑 vim/htop/opencode 与桌面一致 | TUI 网格对齐 |
| P4 | 多会话 tab | 多终端并发不串流 |
| P5 | pyte 快照 + 断线重连续传 | 断网重连无花屏，进程不中断 |

## 已定决策（原 Open Questions，已拍板）

1. **尺寸**：手机端 `TerminalView` 自动测量可视 cols/rows（按屏幕尺寸 + 默认等宽字号算出），open 时带上；旋转/键盘弹出导致变化时发 `terminal.resize`。不做手动字号档位（第一版）。
2. **会话生命周期**：仅当次连接内有效。App 重启不持久化会话列表；但只要桌面进程仍在运行，重连后可对已知 session 发 `terminal.resync` 恢复画面。
3. **入口**：首页（home_screen）新增独立“终端”入口卡片，与远控并列。不嵌入 control_screen。

---

# V2 架构升级：会话归桌面 + list/attach + 桌面可见 UI

> 状态：进行中。V1（P1-P5）已实现“手机拥有会话”的基础流式终端；V2 把会话所有权迁移到桌面，支持手机 list/attach、桌面 GUI 可见、双向主动关闭。

## V2 核心变更（相对 V1）

V1 的根本局限：**会话 ID 由手机生成、桌面被动接收**，导致无法“连接到已开启的终端”、重连/换机丢失会话、桌面看不到终端界面。

V2 重新定义所有权：

1. **会话归桌面拥有并持久**。会话 ID 由桌面生成，活在 agent 进程内，手机离开只 detach 不杀。
2. **手机连上先 list**：看到桌面所有活动会话 + 桌面支持的 shell 类型清单；可 attach 已有，或 create 新建（桌面负责实际开启）。
3. **桌面被控端 GUI 可见**：tkinter Notebook 新增「远程终端」标签页，每个活动会话用 `tk.Text`（Consolas 等宽）渲染 pyte 屏幕镜像；桌面可在此手动新建/关闭终端。
4. **生命周期**：仅当桌面或手机**主动 close** 时才销毁 PTY；手机离页 = detach（保活），断线/换机重连可重新 list→attach。

## V2 消息协议（control 通道；新增/调整，base64 同 V1）

| type | 方向 | 字段 | 说明 |
|------|------|------|------|
| `terminal.list` | 手机→桌面 | — | 请求活动会话 + 可用 shell 类型 |
| `terminal.sessions` | 桌面→手机 | `shells:[...], sessions:[{id,shell,cols,rows,title}]` | list 回执 |
| `terminal.create` | 手机→桌面 | `shell, cols, rows` | 请求新建；**桌面生成 id** |
| `terminal.created` | 桌面→手机 | `session_id, shell, cols, rows` | 新建成功，回传桌面分配 id |
| `terminal.attach` | 手机→桌面 | `session_id, cols, rows` | 接入已有；桌面 resize 到该尺寸 + 回 snapshot |
| `terminal.detach` | 手机→桌面 | `session_id` | 手机不再看；**不杀 PTY** |
| `terminal.close` | 双向 | `session_id, reason?` | **真**销毁 PTY（桌面或手机主动） |
| `terminal.data` / `terminal.input` / `terminal.resize` / `terminal.snapshot` | 同 V1 | — | 沿用 |

注：V1 的 `terminal.open`/`terminal.opened`/`terminal.resync` 被 `create`/`created`/`attach` 取代；为简化不保留向后兼容（同一版本三端同步发布）。

## V2 桌面 GUI（desktop_agent_ui.py）

- `ttk.Notebook` 增加「远程终端」Tab。
- Tab 内：左侧会话列表（shell + title + 尺寸 + 是否被手机 attach），右侧 `tk.Text` 渲染选中会话的 pyte 屏幕镜像（只读展示，刷新由 manager `on_change`/定时拉取 `snapshot_bytes`）。
- 按钮：新建（选 shell 类型）、关闭选中会话。
- 与 manager 解耦：GUI 仅调用 `manager.create/close/list_sessions/get_screen_text`，并注册 `on_change` 回调刷新。

## V2 terminal_manager.py 改造点

- `create(shell, cols, rows) -> session_id`：桌面生成 `id`（如 `pty-{短uuid}`）和 `title`（shell + 序号）。
- `list_sessions() -> [dict]` 与 `available_shells() -> [str]`：供 GUI 与手机 list。
- `attach(session_id, cols, rows)`：resize + 返回 snapshot。
- `detach(session_id)`：标记无手机观察，**不关进程**。
- `get_screen_text(session_id) -> str`：供桌面 GUI 渲染（pyte `screen.display`）。
- `on_change` 回调：会话增删/状态变化时通知 GUI 刷新列表。
- 数据推送保持：有手机 attach 时 `_emit_data` 推 `terminal.data`；无 attach 时仍喂 pyte（桌面 GUI 要看），但可不推流省带宽。

## V2 手机端改造点

- `terminal_service.dart`：去掉“手机生成 id + 立即 open”；改为 `requestList()`、`attach(id)`、`create(shell)`、`detach(id)`；会话 id 以桌面回传为准。
- `terminal_screen.dart`：进页先 list → 显示会话列表（含可新建 shell 类型）；选已有→attach（写入 snapshot 后续流）；新建→create→自动 attach；离页→detach。

## V2 分阶段落地

| 阶段 | 目标 | 验收 |
|------|------|------|
| P-A | terminal_manager 重构（create/list/attach/detach + 桌面生成 id）+ agent 路由 | 桌面闭环脚本：create→list→写命令→attach 回 snapshot→detach 不杀→close 才杀 |
| P-B | 桌面 GUI「远程终端」Tab（列表 + Text 渲染 + 新建/关闭） | 桌面窗口能看到终端输出、可手动开关 |
| P-C | 手机端列表/attach/create UI | 手机进页看到列表、可选已有或新建 |
| P-D | 三端联调 + 打包发布 | list→attach→断线重连→换 shell→桌面/手机双向关闭全通 |

## V2 边界（叠加 V1 Boundaries）

- **Never**：detach 误杀 PTY；桌面 GUI 渲染阻塞 tkinter 主线程（用 after() 定时拉取，不在回调里做重活）；改动远控/视频/选路。
- **Always**：会话 id 唯一权威在桌面；close 是唯一销毁路径。
