# PocketWindow - 项目实现细节

## 项目概述

PocketWindow 是一个手机端远程控制 Windows 电脑指定窗口的跨平台解决方案。

## 核心架构

### 1. 连接流程

```
1. 手机端启动 → 输入房间ID
2. 被控端启动 → 注册到房间
3. 信令服务器协调 → WebRTC P2P 连接
4. 连接建立 → 开始图像传输和控制
```

### 2. 图像捕获与传输

#### 窗口捕获
- 使用 Windows DWM (Desktop Window Manager) API
- 支持窗口级捕获（非全屏）
- 硬件加速支持

#### 区域选择
- 用户可圈定监控区域
- 只捕获指定矩形区域
- 支持多区域监听

#### 变更检测
- 图像差分算法（Perceptual Diff）
- 只传输变化的区域
- 可调节的压缩质量

### 3. 控制协议

#### 指令类型
```json
{
  "type": "control",
  "command": "mouse_move|mouse_click|key_press|paste_text",
  "params": {
    "x": 100,
    "y": 200,
    "button": "left"
  }
}
```

#### 反向控制
- 剪贴板同步
- 滚动控制
- 特殊键支持（Ctrl/Cmd/Alt）

### 4. 语音输入

#### 集成方案
```
手机端语音 → Flutter ASR plugin → 语音识别 →
发送文本 → 被控端模拟键盘输入 → IDE
```

#### 支持的识别
- 在线识别（Google/百度/阿里）
- 离线识别（Edge TTS）

## 技术细节

### 被控端 (Python)

```python
# 核心依赖
- pywin32: Windows API 访问
- Pillow: 图像处理
- OpenCV: 图像压缩与差分
- numpy: 数组操作
```

### 手机端 (Flutter)

```yaml
# 核心依赖
- flutter_webrtc: WebRTC 支持
- flutter_secure_storage: 本地存储
- speech_to_text: 语音识别
- http: 网络请求
```

## 部署指南

### NAS 部署

1. **克隆项目**
```bash
git clone https://github.com/your/pocketwindow.git
cd pocketwindow/server
```

2. **构建镜像**
```bash
docker build -t pocketwindow-server .
```

3. **启动服务**
```bash
docker-compose up -d
```

4. **获取 Room ID**
```bash
 curl http://your-nas-ip:58080/api/create_room
```

### 被控端运行

```bash
cd ../control-agent
python src/main.py
# 输入房间ID连接
```

### 手机端运行

```bash
cd ../flutter-client
flutter run
# 输入房间ID连接
```

## 优化建议

### 带宽优化
1. 调整 JPEG 压缩质量 (50-80)
2. 使用 H.264 视频编码（后续）
3. 启用 ICE 快速连接（UDP 优先）

### 延迟优化
1. 使用 TURN 服务器（如果 P2P 失败）
2. 启用 NACK/ACK 重传机制
3. 调整 WebRTC QoS 参数

## 安全考虑

1. **连接认证** - Room ID 本质上是临时 token
2. **数据加密** - WebRTC DataChannel 默认 SRTP 加密
3. **访问控制** - 可添加密码保护
4. **日志审计** - 记录控制操作

## 扩展功能

- [ ] 多窗口管理
- [ ] 用户权限系统
- [ ] 网页远程调试
- [ ] 文件传输
- [ ] 音频流传输
