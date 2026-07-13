# PocketWindow 使用指南

## 当前运行状态

| 服务 | 状态 | 地址 |
|------|------|------|
| WebSocket 信令服务器 | ✅ 运行中 | ws://localhost:58080/ws |
| Python 被控端 | ✅ 运行中 | 房间 ID: 请运行 `python agent_simple.py` 查看 |

## 快速使用

### 1. 启动被控端（Windows）

```bash
cd D:/project/pocketWindow/control-agent
python src/agent_simple.py
```

程序会输出可用窗口列表和 Room ID。

### 2. 启动手机端

使用 Flutter 连接：
- 信令服务器: `ws://localhost:58080/ws`
- 房间 ID: 从被控端输出中获取

## 技术实现

- **信令服务器**: Node.js + WebSocket
- **被控端**: Python + Win32 API + TCP Socket
- **手机端**: Flutter + WebSocket

## 文件说明

```
D:/project/pocketWindow/
├── server/
│   └── src/server.js          # WebSocket 信令服务器
├── control-agent/
│   ├── src/agent_simple.py    # 简易版被控端（推荐）
│   ├── src/agent_full.py      # 完整版被控端
│   └── src/screen_capture.py  # 图像捕获
└── flutter-client/
    └── lib/ui/screens/home_screen.dart  # 手机端入口
```

## 下一步

完善 Flutter 手机端的 WebSocket 连接和画面显示。
