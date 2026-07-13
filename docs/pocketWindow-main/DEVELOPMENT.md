# PocketWindow - 完整开发文档

## 项目概述

PocketWindow 是一个手机端远程控制 Windows 电脑指定窗口的跨平台解决方案。

## 连接架构

### WebRTC P2P 连接流程

```
┌──────────────┐      ┌──────────────┐
│   手机控制端   │<---->│  Windows被控端 │
│  (Flutter)   │ WebRTC│   (Python)   │
└──────▲───────┘      └───────▲──────┘
       │                      │
       │   WebRTC DataChannel │
       │                      │
┌──────┴───────┐              │
│   NAS (Docker)│              │
│  - Signaling │--------------┘
│  - STUN Server
└──────────────┘
```

## 部署指南

### NAS 部署 (Docker)

```bash
cd server
docker build -t pocketwindow-server .
 docker run -d -p 58080:58080 --name pocketwindow-server pocketwindow-server
```

### Windows 被控端

```bash
# 安装依赖
pip install -r requirements.txt

# 运行
 python src/agent.py --window "VSCode" --server your-nas-ip --port 58080
```

### Flutter 手机端

```bash
flutter pub get
flutter run
```

## 技术栈

| 模块 | 技术 |
|------|------|
| 信令服务器 | Node.js + Socket.IO |
| 被控端 | Python 3.10+ + Win32 API |
| 手机端 | Flutter + flutter_webrtc |

## 实施计划

- [x] 项目初始化
- [x] 信令服务器
- [x] Windows 被控端
- [x] Flutter 控制端
- [ ] RTCPeerConnection 集成
- [ ] 图像流传输优化
- [ ] 控制指令完整实现
- [ ] 语音输入集成
- [ ] 窗口选择功能完整实现

## 开发进度

当前进度: **基础架构完成**

- 信令服务器: 基本功能已完成
- Windows 被控端: 核心模块已完成
- Flutter 客户端: UI 基础已完成

## 下一步计划

### 阶段一: 连接与图像传输
- [ ] 完善 WebRTC 连接流程
- [ ] 实现图像帧压缩与传输
- [ ] 区域变更检测

### 阶段二: 控制功能
- [ ] 鼠标控制完整实现
- [ ] 键盘控制完整实现
- [ ] 剪贴板同步

### 阶段三: 增强功能
- [ ] 语音输入集成
- [ ] 窗口列表获取
- [ ] 多窗口管理

## 注意事项

1. Python 被控端需要 Windows 环境
2. Flutter 端需要 Android/iOS 设备测试
3. 信令服务器需要公网可访问(或内网)
