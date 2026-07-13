"""
PocketWindow Python WebRTC Agent - 使用 aiortc 实现 WebRTC 连接
使用 python-socketio 连接到 Socket.IO 信令服务器
"""

import asyncio
import json
import logging
import time
from typing import Optional, Callable
import cv2
import numpy as np
from PIL import Image

import socketio

logger = logging.getLogger(__name__)

# 创建 Socket.IO 客户端
sio = socketio.Client()
sio_connected = False


@sio.event
def connect():
    """连接建立"""
    global sio_connected
    sio_connected = True
    logger.info("Socket.IO 连接建立")


@sio.event
def disconnect():
    """连接断开"""
    global sio_connected
    sio_connected = False
    logger.info("Socket.IO 连接断开")


@sio.on('room_joined')
def on_room_joined(data):
    """加入房间成功"""
    logger.info(f"加入房间成功: {data.get('room_id')}")


@sio.on('remote_connected')
def on_remote_connected(data):
    """远程端已连接"""
    logger.info(f"远程端已连接: {data.get('role')}")


@sio.on('error')
def on_error(data):
    """错误消息"""
    logger.error(f"错误: {data}")


@sio.on('offer')
def on_offer(data):
    """收到 Offer"""
    logger.info("收到 Offer")
    # 这里应该调用 _handle_offer


class WebRTCAgent:
    """WebRTC Agent - 管理与手机端的 WebRTC 连接"""

    def __init__(self, signaling_host: str = 'localhost', signaling_port: int = 58080):
        self.signaling_host = signaling_host
        self.signaling_port = signaling_port

        self.pc: Optional[RTCPeerConnection] = None
        self.sio: Optional[socketio.Client] = None
        self.running = False
        self.room_id: Optional[str] = None

        # 回调
        self.on_connected: Callable = lambda: None
        self.on_disconnected: Callable = lambda: None
        self.on_control: Callable = lambda data: None

        # 图像捕获
        self.capture_callback = None

    async def connect(self, room_id: Optional[str] = None):
        """连接到信令服务器"""
        self.room_id = room_id or self._generate_room_id()

        # 构建 Socket.IO URL
        signaling_url = f"http://{self.signaling_host}:{self.signaling_port}"

        logger.info(f"正在连接信令服务器 {signaling_url}")

        # 注册回调
        @sio.event
        def connect():
            global sio_connected
            sio_connected = True
            logger.info("Socket.IO 连接建立")
            self._join_room()

        @sio.event
        def disconnect():
            global sio_connected
            sio_connected = False
            logger.info("Socket.IO 连接断开")

        @sio.on('remote_connected')
        def on_remote_connected(data):
            logger.info(f"远程端已连接: {data.get('role')}")
            self.on_connected()

        @sio.on('offer')
        def on_offer(data):
            logger.info("收到 Offer")
            asyncio.run(self._handle_offer(data))

        @sio.on('ice_candidate')
        def on_ice_candidate(data):
            logger.info("收到 ICE 候选")
            asyncio.run(self._handle_ice_candidate(data))

        @sio.on('control')
        def on_control(data):
            logger.info("收到控制指令")
            self.on_control(data)

        # 连接到服务器
        try:
            sio.connect(signaling_url)
            logger.info("Socket.IO 连接成功")

            # 等待连接
            for _ in range(10):
                if sio_connected:
                    break
                await asyncio.sleep(0.5)

            if not sio_connected:
                raise Exception("连接信令服务器超时")

        except Exception as e:
            logger.error(f"连接失败: {e}")
            raise

    def _generate_room_id(self) -> str:
        """生成随机 Room ID"""
        import uuid
        return 'pw-' + uuid.uuid4().hex[:8]

    def _join_room(self):
        """加入房间"""
        sio.emit('join_room', {
            'room_id': self.room_id,
            'role': 'agent'
        })

    async def _handle_offer(self, message: dict):
        """处理 Offer"""
        if self.pc is None:
            self._create_peer_connection()

        offer_sdp = message.get('offer')
        if offer_sdp:
            offer = RTCSessionDescription(offer_sdp, 'answer')
            await self.pc.setRemoteDescription(offer)

            # 创建 Answer
            answer = await self.pc.createAnswer()
            await self.pc.setLocalDescription(answer)

            # 发送 Answer
            sio.emit('send_answer', {
                'room_id': self.room_id,
                'answer': self.pc.localDescription.sdp,
                'target_role': 'client'
            })

    async def _handle_ice_candidate(self, message: dict):
        """处理 ICE 候选"""
        candidate = message.get('candidate')
        if candidate and self.pc:
            ice_candidate = RTCIceCandidate(
                candidate=candidate.get('candidate'),
                sdpMid=candidate.get('sdpMid'),
                sdpMLineIndex=candidate.get('sdpMLineIndex')
            )
            await self.pc.addIceCandidate(ice_candidate)

    async def disconnect(self):
        """断开连接"""
        self.running = False
        if self.pc:
            await self.pc.close()
        if sio.connected:
            sio.disconnect()
        if sio_connected:
            await asyncio.sleep(1)

    def _create_peer_connection(self):
        """创建 RTCPeerConnection"""
        from aiortc import RTCPeerConnection, RTCSessionDescription, RTCIceCandidate

        self.pc = RTCPeerConnection()

        # 配置 ICE servers
        self.pc.configuration = {
            'iceServers': [
                {'urls': ['stun:stun.l.google.com:19302']},
                {'urls': ['stun:stun1.l.google.com:19302']},
            ]
        }

        # 设置事件处理器
        @self.pc.on("connectionstatechange")
        async def on_connectionstatechange():
            logger.info(f"Connection state: {self.pc.connectionState}")
            if self.pc.connectionState == 'connected':
                self.running = True
                self.on_connected()
                asyncio.create_task(self._image_transmit_loop())
            elif self.pc.connectionState in ['failed', 'closed']:
                self.running = False
                self.on_disconnected()

        @self.pc.on("icecandidate")
        def on_icecandidate(candidate):
            """发送 ICE 候选"""
            if candidate and sio.connected:
                sio.emit('send_ice_candidate', {
                    'room_id': self.room_id,
                    'candidate': {
                        'candidate': candidate.candidate,
                        'sdpMid': candidate.sdpMid,
                        'sdpMLineIndex': candidate.sdpMLineIndex
                    },
                    'target_role': 'client'
                })

    async def _image_transmit_loop(self):
        """图像传输循环"""
        while self.running and self.pc and self.pc.connectionState == 'connected':
            try:
                if self.capture_callback:
                    frame = await asyncio.to_thread(self.capture_callback)
                    if frame is not None:
                        logger.debug(f"Frame ready")

                await asyncio.sleep(0.1)  # 10 FPS

            except Exception as e:
                logger.error(f"Image transmission error: {e}")
                await asyncio.sleep(1)

    def set_capture_callback(self, callback):
        """设置图像捕获回调"""
        self.capture_callback = callback
