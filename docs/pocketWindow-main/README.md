# PocketWindow

口袋里的窗口控制 - Pocket Window Control

手机端远程控制 Windows 电脑指定窗口的跨平台解决方案

## 项目结构

```
pocketwindow/
├── server/              # 信令服务器 (Docker 部署)
│   ├── src/
│   └── Dockerfile
├── control-agent/       # Windows 被控端 (Python)
│   ├── src/
│   └── requirements.txt
└── flutter-client/      # Flutter 手机控制端
    ├── lib/
    └── pubspec.yaml
```

## 功能特性

- 🎯 **窗口级控制** - 选择并控制指定窗口
- 📐 **区域捕获** - 自定义监控区域，节省流量
- 📸 **变更同步** - 只传输变化部分
- 🖱️ **鼠标键盘** - 完整控制支持
- 🎤 **语音输入** - 语音转文本，vibe coding
- 📋 **剪贴板同步** - 文本复制粘贴

## 快速开始

### 1. 部署信令服务器

```bash
cd server
docker build -t pocketwindow-server .
 docker run -p 58080:58080 pocketwindow-server
```

### 2. 运行被控端

```bash
cd control-agent
pip install -r requirements.txt
python main.py
```

### 3. 运行手机端

```bash
cd flutter-client
flutter pub get
flutter run
```

## 技术栈

| 模块 | 技术 |
|------|------|
| 信令服务器 | Node.js + WebSocket(ws) |
| 被控端 | Python + Win32 API |
| 手机端 | Flutter + WebSocket |

## 开发进度

- [ ] 项目初始化
- [ ] 信令服务器
- [ ] Windows 被控端
- [ ] Flutter 控制端
- [ ] 窗口选择功能
- [ ] 区域捕获功能
- [ ] 图像压缩与传输
- [ ] 控制指令系统

## 许可证

MIT
