from __future__ import annotations

import json
import logging
import socket
import threading
import time
import urllib.parse
import uuid
from typing import Callable, Optional

import websocket


logger = logging.getLogger('PocketWindowAgent')


class _WebSocketChannel:
    def __init__(
        self,
        owner: 'DualChannelSignaling',
        channel: str,
        on_message: Callable[[dict], None],
    ):
        self.owner = owner
        self.channel = channel
        self.on_message = on_message
        self.ws = None
        self.ws_thread = None
        self.connected = False
        self._socket_open = False
        self._send_lock = threading.Lock()

    def connect(self) -> bool:
        try:
            ws_url = self.owner._get_ws_url()
            logger.info('Connecting %s WebSocket: %s', self.channel, ws_url)
            self.ws = websocket.WebSocketApp(
                ws_url,
                on_open=self._on_open,
                on_message=self._on_message,
                on_error=self._on_error,
                on_close=self._on_close,
            )
            self.ws_thread = threading.Thread(
                target=self.ws.run_forever,
                daemon=True,
                name=f'ws-{self.channel}',
            )
            self.ws_thread.start()

            start_time = time.time()
            while not self._socket_open and (time.time() - start_time) < 5:
                time.sleep(0.05)
            if not self._socket_open:
                return False
            while not self.connected and (time.time() - start_time) < 10:
                time.sleep(0.05)
            return self.connected
        except Exception as exc:
            logger.error('%s WebSocket connection failed: %s', self.channel, exc)
            return False

    def disconnect(self):
        self.connected = False
        self._socket_open = False
        if self.ws:
            self.ws.close()

    def send(self, data: dict):
        if not self._socket_open or not self.ws:
            return False
        try:
            with self._send_lock:
                self.ws.send(json.dumps(data))
            return True
        except Exception as exc:
            logger.error(
                '%s WebSocket send error: type=%s error=%s',
                self.channel,
                data.get('type'),
                exc,
            )
            self._socket_open = False
            self.connected = False
            return False

    def send_binary(self, payload: bytes):
        if not self._socket_open or not self.ws:
            return False
        try:
            with self._send_lock:
                self.ws.send(payload, opcode=websocket.ABNF.OPCODE_BINARY)
            return True
        except Exception as exc:
            logger.error(
                '%s WebSocket binary send error: bytes=%s error=%s',
                self.channel,
                len(payload) if payload is not None else 0,
                exc,
            )
            self._socket_open = False
            self.connected = False
            return False

    def _on_open(self, ws):
        logger.info(
            '%s WebSocket connected: room=%s role=%s',
            self.channel,
            self.owner.room_id,
            self.owner.role,
        )
        self._socket_open = True
        join_payload = {
            'type': 'join_room',
            'room_id': self.owner.room_id,
            'role': self.owner.role,
            'channel': self.channel,
        }
        if self.channel == 'control':
            join_payload['metadata'] = self.owner.join_metadata
        self.send(join_payload)

    def _on_message(self, ws, message):
        try:
            data = json.loads(message)
            logger.debug('WS %s recv type=%s', self.channel, data.get('type'))
            if data.get('type') == 'room_joined' and data.get('channel') == self.channel:
                logger.info('%s WebSocket room_joined received; protocol handshake complete', self.channel)
                self.connected = True
            self.on_message(data)
        except json.JSONDecodeError:
            logger.debug('Received non-JSON message on %s: %s', self.channel, str(message)[:100])

    def _on_error(self, ws, error):
        logger.error('WebSocket %s error: room=%s error=%s', self.channel, self.owner.room_id, error)

    def _on_close(self, ws, close_status_code, close_msg):
        logger.warning(
            'WebSocket %s closed: room=%s code=%s message=%s connected=%s',
            self.channel,
            self.owner.room_id,
            close_status_code,
            close_msg,
            self.connected,
        )
        self._socket_open = False
        self.connected = False


class DualChannelSignaling:
    MEDIA_TYPES = {
        'image_frame',
        'video_stream_start',
        'video_stream_frame',
        'video_stream_keepalive',
        'video_stream_stop',
    }
    WEBRTC_SIGNAL_TYPES = {
        'webrtc_offer',
        'webrtc_answer',
        'webrtc_ice_candidate',
        'webrtc_transport_state',
    }

    def __init__(self, host: str, port: int, stream_count: int = 1):
        self.host = host
        self.port = port
        self.room_id: Optional[str] = None
        self.role = 'agent'
        self.on_message: Optional[Callable[[dict], None]] = None
        self.join_metadata: dict = {}
        self.running = False
        self._server_supports_channels = False
        self._control = _WebSocketChannel(self, 'control', self._handle_message)
        self._media = _WebSocketChannel(self, 'media', self._handle_message)
        self._stream_count = max(0, int(stream_count or 0))
        self._stream_channels: list[_WebSocketChannel] = []
        for idx in range(self._stream_count):
            ch = _WebSocketChannel(self, f'stream-{idx + 1}', self._handle_message)
            self._stream_channels.append(ch)

    @property
    def connected(self) -> bool:
        return self._control.connected

    @property
    def media_connected(self) -> bool:
        return self._media.connected

    def _get_ws_url(self) -> str:
        return f'{self._normalized_http_base("ws")}/ws'

    def get_http_base_url(self) -> str:
        return self._normalized_http_base('http')

    def _normalized_http_base(self, default_scheme: str) -> str:
        raw = str(self.host or '').strip()
        if not raw:
            raise ValueError('signaling host is empty')
        if '://' not in raw:
            raw = f'{default_scheme}://{raw}'
        parsed = urllib.parse.urlparse(raw)
        scheme = parsed.scheme or default_scheme
        host = parsed.hostname or parsed.path.split('/')[0].strip()
        if not host:
            raise ValueError(f'invalid signaling host: {self.host}')
        if ':' in host and not host.startswith('['):
            host = f'[{host}]'
        port = parsed.port or int(self.port)
        return f'{scheme}://{host}:{port}'

    def connect(self, room_id: Optional[str] = None, metadata: Optional[dict] = None) -> bool:
        self.room_id = room_id or self.room_id or self._generate_room_id()
        logger.info('DualChannelSignaling.connect: room_id=%s', self.room_id)
        self.join_metadata = metadata or {}
        self.running = True

        control_ok = self._control.connect()
        if not control_ok:
            self.running = False
            logger.error('Control WebSocket connection timed out')
            return False

        # Wait briefly for server to advertise channel support via room_joined
        wait_start = time.time()
        while not self._server_supports_channels and (time.time() - wait_start) < 2:
            time.sleep(0.05)

        if not self._server_supports_channels:
            logger.info('Server does not advertise channel support; using single control WebSocket')
            logger.info('Room ID: %s', self.room_id)
            return True

        self._connect_media_and_streams()
        logger.info('Room ID: %s', self.room_id)
        return True

    def disconnect(self):
        self.running = False
        for ch in self._stream_channels:
            ch.disconnect()
        self._media.disconnect()
        self._control.disconnect()

    def _connect_media_and_streams(self) -> None:
        if not self._media.connected:
            logger.info('Connecting media WebSocket channel')
            media_ok = self._media.connect()
            if not media_ok:
                logger.warning('Media WebSocket connection failed; media frames will be dropped until media reconnects')
        for idx, ch in enumerate(self._stream_channels):
            if not ch.connected:
                logger.info('Connecting stream-%s WebSocket channel', idx + 1)
                ok = ch.connect()
                if not ok:
                    logger.warning('stream-%s WebSocket connection failed', idx + 1)

    def ensure_media_connected(self) -> bool:
        if not self.running or not self._control.connected:
            return False
        if not self._server_supports_channels:
            return True
        if not self._media.connected:
            logger.warning('Media WebSocket is disconnected; reconnecting media channel')
            self._media.disconnect()
            self._media.connect()
        for idx, ch in enumerate(self._stream_channels):
            if not ch.connected:
                logger.warning('stream-%s WebSocket is disconnected; reconnecting', idx + 1)
                ch.disconnect()
                ch.connect()
        return True

    def _send(self, data: dict):
        if data.get('type') in self.MEDIA_TYPES:
            if self._media.connected:
                return self._media.send(data)
            if self._server_supports_channels:
                logger.debug(
                    'Media channel is disconnected; sending media payload on control: type=%s',
                    data.get('type'),
                )
        return self._control.send(data)

    def send_binary_media(self, payload: bytes):
        if self._media.connected:
            return self._media.send_binary(payload)
        if self._server_supports_channels:
            logger.debug('Media channel is disconnected; sending binary media on control')
        return self._control.send_binary(payload)

    def send_binary_stream(self, stream_idx: int, payload: bytes) -> bool:
        if stream_idx == 0:
            return self.send_binary_media(payload)
        ch_idx = stream_idx - 1
        if ch_idx < len(self._stream_channels) and self._stream_channels[ch_idx].connected:
            return self._stream_channels[ch_idx].send_binary(payload)
        logger.debug('stream-%s channel not connected; falling back to media', stream_idx)
        return self.send_binary_media(payload)

    def send_webrtc_signal(self, signal_type: str, payload: Optional[dict] = None):
        if signal_type not in self.WEBRTC_SIGNAL_TYPES:
            raise ValueError(f'unsupported WebRTC signaling type: {signal_type}')
        data = dict(payload or {})
        data['type'] = signal_type
        data['room_id'] = self.room_id
        return self._control.send(data)

    def _generate_room_id(self) -> str:
        return 'pw-' + uuid.uuid4().hex[:8]

    def _handle_message(self, data: dict):
        if data.get('type') == 'error':
            logger.warning(
                'WS %s server error: message=%s',
                data.get('channel') or 'dual',
                data.get('message'),
            )
        if data.get('type') == 'room_joined' and data.get('channel') == 'control':
            self._server_supports_channels = True
        if self.on_message:
            self.on_message(data)
