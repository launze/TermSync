"""
WebRTC 连接管理器 - 通过 Socket.IO 进行信令交换
"""

import socket
import json
import threading
import time
from typing import Optional, Tuple, Callable


class WebRTCConnection:
    """WebRTC 连接管理器 - 使用 Socket.IO 作为信令通道"""

    def __init__(self, signaling_server: str = 'localhost', port: int = 58080):
        self.signaling_server = signaling_server
        self.port = port
        self.socket = None
        self.connected = False
        self.room_id = None
        self.target_hwnd = None
        self.capture_region = None

        # 回调函数
        self.on_ice_candidate = None
        self.on_offer = None
        self.on_control = None

    def connect(self, room_id: str = None) -> bool:
        """连接到信令服务器"""
        try:
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.connect((self.signaling_server, self.port))
            self.connected = True
            self.room_id = room_id or self._generate_room_id()

            print(f"已连接到信令服务器: {self.signaling_server}:{self.port}")
            print(f"房间 ID: {self.room_id}")

            # 启动接收线程
            threading.Thread(target=self._receive_loop, daemon=True).start()

            # 发送加入房间消息
            self._send_message({
                'type': 'join_room',
                'room_id': self.room_id,
                'role': 'agent'
            })

            return True

        except Exception as e:
            print(f"连接失败: {e}")
            self.connected = False
            return False

    def _generate_room_id(self) -> str:
        """生成随机 Room ID"""
        import uuid
        return 'pw-' + uuid.uuid4().hex[:8]

    def _receive_loop(self):
        """接收循环"""
        while self.connected:
            try:
                data = self.socket.recv(8192)
                if data:
                    self._handle_message(data.decode('utf-8'))
                else:
                    self.connected = False
            except socket.error:
                self.connected = False
            except Exception as e:
                print(f"接收错误: {e}")
                self.connected = False

    def _handle_message(self, message: str):
        """处理消息"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')

            if msg_type == 'offer':
                self._trigger_callback(self.on_offer, data)
            elif msg_type == 'ice_candidate':
                self._trigger_callback(self.on_ice_candidate, data)
            elif msg_type == 'control':
                self._trigger_callback(self.on_control, data)

        except json.JSONDecodeError:
            pass

    def _trigger_callback(self, callback, data):
        """触发回调函数"""
        if callback:
            try:
                callback(data)
            except Exception as e:
                print(f"回调执行错误: {e}")

    def set_callbacks(self, on_ice=None, on_offer=None, on_control=None):
        """设置回调函数"""
        if on_ice:
            self.on_ice_candidate = on_ice
        if on_offer:
            self.on_offer = on_offer
        if on_control:
            self.on_control = on_control

    def send_ice_candidate(self, candidate: dict):
        """发送 ICE 候选"""
        self._send_message({
            'type': 'ice_candidate',
            'room_id': self.room_id,
            'candidate': candidate
        })

    def send_offer(self, offer_sdp: str):
        """发送 Offer"""
        self._send_message({
            'type': 'offer',
            'room_id': self.room_id,
            'offer': offer_sdp
        })

    def send_answer(self, answer_sdp: str):
        """发送 Answer"""
        self._send_message({
            'type': 'answer',
            'room_id': self.room_id,
            'answer': answer_sdp
        })

    def send_image_frame(self, frame_bytes: bytes):
        """发送图像帧（转为 hex string）"""
        self._send_message({
            'type': 'image_frame',
            'room_id': self.room_id,
            'data': frame_bytes.hex()
        })

    def send_control_response(self, command: str, success: bool, message: str = ''):
        """发送控制响应"""
        self._send_message({
            'type': 'control_response',
            'room_id': self.room_id,
            'command': command,
            'success': success,
            'message': message
        })

    def _send_message(self, message: dict):
        """发送消息"""
        if self.connected:
            try:
                self.socket.send(json.dumps(message).encode('utf-8'))
            except Exception as e:
                print(f"发送错误: {e}")
                self.connected = False

    def disconnect(self):
        """断开连接"""
        self.connected = False
        if self.socket:
            try:
                self.socket.close()
            except:
                pass
            self.socket = None


def load_config(config_path: str = 'config.json') -> dict:
    """加载配置文件"""
    default_config = {
        'signaling_server': 'localhost',
        'port': 58080,
        'jpeg_quality': 70,
        'frame_interval': 0.1,
        'auto_connect': False,
        'room_id': None
    }

    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
            default_config.update(config)
    except FileNotFoundError:
        print(f"配置文件 {config_path} 不存在，使用默认配置")
    except json.JSONDecodeError:
        print(f"配置文件 {config_path} 格式错误")

    return default_config


def save_config(config: dict, config_path: str = 'config.json'):
    """保存配置文件"""
    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=2)
