# PocketWindow Control Agent

PocketWindow 的 Windows 被控端程序，使用 Python 实现窗口捕获和控制。

## 功能

- 窗口枚举与选择
- 区域捕获（只捕获指定区域，节省流量）
- JPEG 压缩传输
- WebRTC 连接
- 控制指令接收（鼠标、键盘）

## 依赖

```bash
pip install -r requirements.txt
```

## 使用方法

### 交互式运行

```bash
python src/agent_full.py
```

### 指定窗口

```bash
python src/agent_full.py -w "VSCode"
```

### 指定信令服务器

```bash
python src/agent_full.py -s your-nas-ip -p 58080
```

### 区域捕获

```bash
python src/agent_full.py -w "Chrome" -R 0,0,800,600
```

### 后台运行

```bash
python src/agent_full.py --headless -w "IDE" --server your-nas-ip
```

### 配置文件

复制 `config.json.example` 为 `config.json`，然后修改：

```json
{
  "signaling_host": "localhost",
  "signaling_port": 58080,
  "window_title": "VSCode",
  "jpeg_quality": 70,
  "frame_interval": 0.1
}
```

## 编译为可执行文件

```bash
pip install pyinstaller
pyinstaller --onefile --windowed src/agent_full.py
```
