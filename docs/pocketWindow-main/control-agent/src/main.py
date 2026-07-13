"""
PocketWindow Control Agent - Windows 被控端
窗口选择、捕获与控制指令处理
"""

import win32gui
import win32ui
import win32con
import numpy as np
from PIL import Image
import cv2
import socket
import threading
import json
import time
import sys
from dataclasses import dataclass
from typing import Optional, List, Tuple


@dataclass
class WindowInfo:
    """窗口信息"""
    hwnd: int
    title: str
    class_name: str
    rect: Tuple[int, int, int, int]

    def to_dict(self):
        return {
            'hwnd': self.hwnd,
            'title': self.title,
            'class_name': self.class_name,
            'rect': self.rect
        }


class WindowSelector:
    """窗口选择器 - 枚举和选择目标窗口"""

    @staticmethod
    def enum_windows_callback(hwnd, windows):
        """枚举窗口回调"""
        if win32gui.IsWindowVisible(hwnd):
            title = win32gui.GetWindowText(hwnd)
            class_name = win32gui.GetClassName(hwnd)
            rect = win32gui.GetWindowRect(hwnd)

            if title:  # 只保留有标题的窗口
                windows.append(WindowInfo(hwnd, title, class_name, rect))

    @classmethod
    def get_windows(cls) -> List[WindowInfo]:
        """获取所有可见窗口"""
        windows = []
        win32gui.EnumWindows(cls.enum_windows_callback, windows)
        return windows

    @classmethod
    def find_window(cls, title_pattern: str) -> Optional[WindowInfo]:
        """根据标题查找窗口"""
        windows = cls.get_windows()
        for window in windows:
            if title_pattern.lower() in window.title.lower():
                return window
        return None


class ScreenCapture:
    """屏幕捕获 - 支持窗口级捕获和区域捕获"""

    def __init__(self):
        self.last_frame = None
        self.capture_region = None  # (x, y, width, height)

    def capture_window(self, hwnd: int) -> Optional[np.ndarray]:
        """捕获指定窗口"""
        try:
            # 获取窗口大小
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            width = right - left
            height = bottom - top

            # 获取窗口设备上下文
            hwnd_dc = win32gui.GetWindowDC(hwnd)
            mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
            save_dc = mfc_dc.CreateCompatibleDC()

            # 创建位图
            bitmap = win32ui.CreateBitmap()
            bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
            save_dc.SelectObject(bitmap)

            # 复制图像
            save_dc.BitBlt((0, 0), (width, height), mfc_dc, (0, 0), win32con.SRCCOPY)

            # 转换为 PIL Image
            bmpinfo = bitmap.GetInfo()
            bmpstr = bitmap.GetBitmapBits(True)
            pil_image = Image.frombuffer(
                'RGB',
                (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                bmpstr, 'raw', 'BGRX', 0, 1
            )

            # 清理
            win32gui.DeleteObject(bitmap.GetHandle())
            save_dc.DeleteDC()
            mfc_dc.DeleteDC()
            win32gui.ReleaseDC(hwnd, hwnd_dc)

            return np.array(pil_image)

        except Exception as e:
            print(f"Capture error: {e}")
            return None

    def capture_region(self, hwnd: int, region: Tuple[int, int, int, int]) -> Optional[np.ndarray]:
        """捕获窗口指定区域"""
        full_image = self.capture_window(hwnd)
        if full_image is None:
            return None

        x, y, width, height = region
        return full_image[y:y+height, x:x+width]

    def compress_frame(self, frame: np.ndarray) -> Optional[bytes]:
        """压缩图像帧"""
        try:
            _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
            return buffer.tobytes()
        except Exception as e:
            print(f"Compress error: {e}")
            return None


class ControlHandler:
    """控制指令处理器"""

    def __init__(self):
        self.current_hwnd = None

    def set_target_window(self, hwnd: int):
        """设置目标窗口"""
        self.current_hwnd = hwnd

    def mouse_move(self, x: int, y: int):
        """鼠标移动"""
        if self.current_hwnd:
            # 转换坐标到窗口客户区
            win32gui.PostMessage(self.current_hwnd, win32con.WM_MOUSEMOVE, 0, (y << 16) | x)

    def mouse_click(self, x: int, y: int, button: str = 'left'):
        """鼠标点击"""
        if self.current_hwnd:
            # 设置鼠标位置
            self.mouse_move(x, y)
            time.sleep(0.05)

            # 发送点击消息
            if button == 'left':
                win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONDOWN, 0, (y << 16) | x)
                win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONUP, 0, (y << 16) | x)
            elif button == 'right':
                win32gui.PostMessage(self.current_hwnd, win32con.WM_RBUTTONDOWN, 0, (y << 16) | x)
                win32gui.PostMessage(self.current_hwnd, win32con.WM_RBUTTONUP, 0, (y << 16) | x)

    def key_press(self, key_code: int):
        """键盘按下"""
        if self.current_hwnd:
            win32gui.PostMessage(self.current_hwnd, win32con.WM_KEYDOWN, key_code, 0)
            win32gui.PostMessage(self.current_hwnd, win32con.WM_KEYUP, key_code, 0)

    def paste_text(self, text: str):
        """粘贴文本（需要更多权限）"""
        try:
            import pyperclip
            pyperclip.copy(text)
            # 模拟 Ctrl+V
            self.key_press(0x56)  # V key
        except ImportError:
            print("pyperclip not installed, install with: pip install pyperclip")


class WebRTCConnection:
    """WebRTC 连接管理器 - 使用 Socket.IO 作为信令通道"""

    def __init__(self, signaling_server: str = 'localhost', port: int = 58080):
        self.signaling_server = signaling_server
        self.port = port
        self.socket = None
        self.connected = False
        self.room_id = None

        # WebRTC 配置
        self.ice_servers = [
            {'urls': ['stun:stun.l.google.com:19302']},
            {'urls': ['stun:stun1.l.google.com:19302']}
        ]

    def connect(self, room_id: str = None):
        """连接到信令服务器"""
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.connect((self.signaling_server, self.port))
            self.connected = True
            self.room_id = room_id or self._generate_room_id()

            print(f"Connected to signaling server: {self.signaling_server}:{self.port}")
            print(f"Room ID: {self.room_id}")

            # 启动接收线程
            threading.Thread(target=self._receive_loop, daemon=True).start()

            # 发送连接消息
            self._send_message({
                'type': 'join_room',
                'room_id': self.room_id,
                'role': 'agent'
            })

        except Exception as e:
            print(f"Connection failed: {e}")
            self.connected = False

    def _generate_room_id(self) -> str:
        """生成随机 Room ID"""
        import uuid
        return 'pw-' + uuid.uuid4().hex[:8]

    def _receive_loop(self):
        """接收循环"""
        while self.connected:
            try:
                data = self.socket.recv(4096)
                if data:
                    self._handle_message(data.decode('utf-8'))
            except socket.error:
                self.connected = False
            except Exception as e:
                print(f"Receive error: {e}")
                self.connected = False

    def _handle_message(self, message: str):
        """处理消息"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')

            if msg_type == 'offer':
                # 处理 WebRTC offer
                self._handle_offer(data)
            elif msg_type == 'ice_candidate':
                # 处理 ICE 候选
                self._handle_ice_candidate(data)
            elif msg_type == 'control':
                # 处理控制指令
                self._execute_control(data.get('command'), data.get('params'))

        except json.JSONDecodeError:
            pass

    def _handle_offer(self, data: dict):
        """处理 Offer（简化版）"""
        print(f"Received offer from client")
        # 这里应该创建 WebRTC PeerConnection 并设置远程描述
        # 由于纯 Python 实现 WebRTC 较复杂，建议使用 aiortc

    def _handle_ice_candidate(self, data: dict):
        """处理 ICE 候选"""
        candidate = data.get('candidate', {})
        print(f"Received ICE candidate: {candidate.get('candidate')}")

    def _execute_control(self, command: str, params: dict):
        """执行控制命令"""
        handler = ControlHandler()

        if command == 'mouse_move':
            handler.mouse_move(params.get('x', 0), params.get('y', 0))
        elif command == 'mouse_click':
            handler.mouse_click(params.get('x', 0), params.get('y', 0), params.get('button', 'left'))
        elif command == 'key_press':
            handler.key_press(params.get('key_code', 0))
        elif command == 'set_window':
            handler.set_target_window(params.get('hwnd', 0))

    def _send_message(self, message: dict):
        """发送消息"""
        if self.connected:
            try:
                self.socket.send(json.dumps(message).encode('utf-8'))
            except Exception as e:
                print(f"Send error: {e}")

    def start_image_stream(self, capture: ScreenCapture, hwnd: int, region: Tuple[int, int, int, int] = None):
        """开始图像流传输"""
        def stream_loop():
            while self.connected:
                try:
                    if region:
                        frame = capture.capture_region(hwnd, region)
                    else:
                        frame = capture.capture_window(hwnd)

                    if frame is not None:
                        # 压缩图像
                        compressed = capture.compress_frame(frame)
                        if compressed:
                            # 发送图像数据
                            self._send_message({
                                'type': 'image_frame',
                                'room_id': self.room_id,
                                'data': compressed.hex()  # 转为 hex string 传输
                            })
                            time.sleep(0.1)  # 控制帧率
                    else:
                        time.sleep(0.5)

                except Exception as e:
                    print(f"Stream error: {e}")
                    time.sleep(1)

        threading.Thread(target=stream_loop, daemon=True).start()


def main():
    """主函数"""
    print("=" * 50)
    print("PocketWindow Control Agent")
    print("=" * 50)

    # 初始化组件
    selector = WindowSelector()
    capture = ScreenCapture()

    # 显示可用窗口
    print("\n可用窗口:")
    windows = selector.get_windows()
    for i, window in enumerate(windows[:15]):  # 显示更多窗口
        print(f"{i+1}. [{window.title}] {window.class_name}")

    if len(windows) > 15:
        print(f"... 还有 {len(windows) - 15} 个窗口")

    # 获取用户选择的窗口
    try:
        choice = input("\n选择窗口编号 (或输入窗口标题关键词): ").strip()
        selected_window = None

        # 尝试解析为数字
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(windows):
                selected_window = windows[idx]
        except ValueError:
            # 否则按关键词查找
            selected_window = selector.find_window(choice)

        if selected_window:
            print(f"\n已选择: [{selected_window.title}]")
        else:
            print("未找到窗口，使用默认窗口")
    except KeyboardInterrupt:
        print("\n退出")
        sys.exit(0)

    # 连接到信令服务器
    print("\n信令服务器配置:")
    signaling_server = input("服务器地址 (默认: localhost): ").strip() or 'localhost'
    try:
        port = int(input("服务器端口 (默认: 58080): ").strip() or '58080')
    except ValueError:
        port = 58080

    print("\n正在连接信令服务器...")
    connection = WebRTCConnection(signaling_server, port)
    connection.connect()

    # 获取房间 ID
    print(f"\n请在手机端输入房间 ID: {connection.room_id}")
    print("连接建立后将自动开始图像传输...")

    # 等待连接建立
    time.sleep(2)

    if connection.connected and selected_window:
        print(f"\n开始传输窗口 [{selected_window.title}] 的图像...")
        connection.start_image_stream(capture, selected_window.hwnd)

    # 保持运行
    try:
        while connection.connected:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n退出")
        connection.connected = False


if __name__ == '__main__':
    main()
