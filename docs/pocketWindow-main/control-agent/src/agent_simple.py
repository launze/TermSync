"""
PocketWindow simple Windows agent.
Uses plain WebSocket(/ws) + JSON.
"""

import argparse
import base64
from collections import deque
import ctypes
import ctypes.wintypes
import faulthandler
import hashlib
import http.server
import io
import json
import logging
import os
import platform
import shlex
import shutil
import socket
import queue
import socketserver
import struct
import subprocess
import sys
import logging.handlers
import threading
import time
import tempfile
import urllib.parse
import uuid
from typing import Callable, Optional
import requests

from agent_state_store import AgentStateStore
from desktop_agent_presenter import DesktopAgentPresenter
from desktop_agent_ui import DesktopAgentUI, format_timestamp
from desktop_update_service import DesktopUpdateService, compare_versions, load_version_info
from direct_transport import DirectTransport
from lan_direct_server import LanDirectServer
from runtime_paths import (
    load_json_file,
    persistent_state_dir,
    resolve_runtime_file_path,
    runtime_base_dir,
)
from signaling_endpoints import (
    can_reach_endpoint,
    invalidate_endpoint_health_cache,
    is_private_host,
    is_private_ipv4,
    normalize_signaling_endpoint,
    parse_signaling_url,
    resolve_host_ipv4_addresses,
    verify_signaling_endpoint,
)
from signaling_channels import DualChannelSignaling
from terminal_manager import TerminalManager
from startup_service import (
    is_startup_enabled,
    set_startup_enabled,
    startup_command,
)
from video_peak_limiter import VideoPeakLimiter
import cv2
import numpy as np
import websocket
import win32con
import win32event
import win32gui
import win32process
import win32ui
import win32api
from PIL import Image, ImageGrab

try:
    from windows_capture import WindowsCapture as NativeWindowsCapture
except ImportError:
    NativeWindowsCapture = None


def _runtime_base_dir() -> str:
    return runtime_base_dir()


def _persistent_state_dir() -> str:
    return persistent_state_dir()


def _load_json_file(path: str) -> dict:
    return load_json_file(path)

_LOG_FORMAT = '%(asctime)s %(levelname)s %(threadName)s %(name)s: %(message)s'
_LOG_DIR = _runtime_base_dir()
_LOG_FILE = os.path.join(_LOG_DIR, 'agent.out.log')

VIDEO_FRAME_BINARY_MAGIC = b'PWVF'
VIDEO_FRAME_BINARY_VERSION = 1
VIDEO_FRAME_CODEC_IDS = {'h264': 1, 'h265': 2}
_PERSISTENT_LOG_FILE = os.path.join(_persistent_state_dir(), 'agent.out.log')
_SCROLL_DIAGNOSTIC_FILE = os.path.join(_persistent_state_dir(), 'scroll_diagnostics.jsonl')
_SCROLL_DIAGNOSTIC_LOCK = threading.Lock()
_SCROLL_DIAGNOSTIC_CHANGE_THRESHOLD = 0.03
_SCROLL_DIAGNOSTIC_OBSERVE_FRAMES = 6
_SCROLL_DIAGNOSTIC_OBSERVE_MS = 500
_SCROLL_DIAGNOSTIC_MAX_PENDING_WHEELS = 96

logging.basicConfig(level=logging.INFO, format=_LOG_FORMAT)
_root_logger = logging.getLogger()

def _add_log_handler(path: str) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if any(
            isinstance(handler, logging.handlers.RotatingFileHandler)
            and os.path.abspath(handler.baseFilename) == os.path.abspath(path)
            for handler in _root_logger.handlers
        ):
            return
        handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=5 * 1024 * 1024, backupCount=2, encoding='utf-8',
        )
        handler.setLevel(logging.INFO)
        handler.setFormatter(logging.Formatter(_LOG_FORMAT))
        _root_logger.addHandler(handler)
    except Exception:
        pass

_add_log_handler(_LOG_FILE)
if os.path.abspath(_PERSISTENT_LOG_FILE) != os.path.abspath(_LOG_FILE):
    _add_log_handler(_PERSISTENT_LOG_FILE)

logger = logging.getLogger(__name__)
try:
    faulthandler.enable()
except Exception:
    logger.debug('faulthandler is unavailable in this runtime', exc_info=True)

SINGLE_INSTANCE_MUTEX_NAME = 'Global\\PocketWindowDesktopAgent'
DESKTOP_UI_WINDOW_TITLE = 'PocketWindow 电脑端'
SINGLE_INSTANCE_LOCK_HOST = '127.0.0.1'
SINGLE_INSTANCE_LOCK_PORT = 47653
SINGLE_INSTANCE_FOCUS_MESSAGE = b'FOCUS'
# Protocol-level defaults. These describe how PocketWindow components agree to
# talk to one another, not which signaling server to use - the user supplies
# that through the UI / CLI / state file.
DEFAULT_SIGNALING_PORT_PLAIN = 80
DEFAULT_SIGNALING_PORT_TLS = 443
DEFAULT_LAN_PROBE_PORT = 58081
DEFAULT_LAN_DIRECT_PORT = 58082
# Built-in seed endpoints used only when both agent_state.json and CLI flags
# are empty (typical: a fresh install). These are pre-filled into the UI so
# the user can connect immediately without manual typing, but each entry can
# be edited or deleted from the desktop UI like any other endpoint.
BUILTIN_SEED_ENDPOINTS: list[dict] = [
    {'name': '局域网 NAS',  'url': 'ws://192.168.31.77:58080', 'priority': 0},
    {'name': '主公网',       'url': 'ws://signal.167183.xyz:80', 'priority': 1},
    {'name': '备用公网',     'url': 'ws://ha.wwszxc.tax:16900', 'priority': 2},
]
DESKTOP_VERSION_FILE = 'version.json'
WINDOWS_UPDATE_CHECK_INTERVAL_SECONDS = 60 * 60
WINDOWS_UPDATE_RETRY_INTERVAL_SECONDS = 5 * 60

def _resolve_runtime_file_path(file_name: str) -> str:
    return resolve_runtime_file_path(file_name)


_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_PROCESS_QUERY_INFORMATION = 0x0400
_GR_GDIOBJECTS = 0
_GR_USEROBJECTS = 1


def _log_uncaught_exception(exc_type, exc_value, exc_traceback):
    if issubclass(exc_type, KeyboardInterrupt):
        sys.__excepthook__(exc_type, exc_value, exc_traceback)
        return
    logger.critical(
        'Uncaught process exception',
        exc_info=(exc_type, exc_value, exc_traceback),
    )


def _log_thread_exception(args):
    logger.critical(
        'Uncaught thread exception in %s',
        getattr(args.thread, 'name', 'unknown'),
        exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
    )


sys.excepthook = _log_uncaught_exception
threading.excepthook = _log_thread_exception


def _current_process_handle_counts() -> Optional[dict]:
    try:
        kernel32 = ctypes.windll.kernel32
        user32 = ctypes.windll.user32
        pid = os.getpid()
        access = _PROCESS_QUERY_LIMITED_INFORMATION | _PROCESS_QUERY_INFORMATION
        process_handle = kernel32.OpenProcess(access, False, pid)
        if not process_handle:
            return None
        try:
            gdi_count = user32.GetGuiResources(process_handle, _GR_GDIOBJECTS)
            user_count = user32.GetGuiResources(process_handle, _GR_USEROBJECTS)
            return {
                'gdi': int(gdi_count),
                'user': int(user_count),
            }
        finally:
            kernel32.CloseHandle(process_handle)
    except Exception:
        return None


PUL = ctypes.POINTER(ctypes.c_ulong)


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ('wVk', ctypes.c_ushort),
        ('wScan', ctypes.c_ushort),
        ('dwFlags', ctypes.c_ulong),
        ('time', ctypes.c_ulong),
        ('dwExtraInfo', PUL),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ('dx', ctypes.c_long),
        ('dy', ctypes.c_long),
        ('mouseData', ctypes.c_ulong),
        ('dwFlags', ctypes.c_ulong),
        ('time', ctypes.c_ulong),
        ('dwExtraInfo', PUL),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ('uMsg', ctypes.c_ulong),
        ('wParamL', ctypes.c_short),
        ('wParamH', ctypes.c_ushort),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [
        ('ki', KEYBDINPUT),
        ('mi', MOUSEINPUT),
        ('hi', HARDWAREINPUT),
    ]


class INPUT(ctypes.Structure):
    _fields_ = [
        ('type', ctypes.c_ulong),
        ('union', INPUT_UNION),
    ]


class CURSORINFO(ctypes.Structure):
    _fields_ = [
        ('cbSize', ctypes.c_uint),
        ('flags', ctypes.c_uint),
        ('hCursor', ctypes.c_void_p),
        ('ptScreenPos', ctypes.wintypes.POINT),
    ]


class ICONINFO(ctypes.Structure):
    _fields_ = [
        ('fIcon', ctypes.c_int),
        ('xHotspot', ctypes.c_uint),
        ('yHotspot', ctypes.c_uint),
        ('hbmMask', ctypes.c_void_p),
        ('hbmColor', ctypes.c_void_p),
    ]


class BITMAP(ctypes.Structure):
    _fields_ = [
        ('bmType', ctypes.c_long),
        ('bmWidth', ctypes.c_long),
        ('bmHeight', ctypes.c_long),
        ('bmWidthBytes', ctypes.c_long),
        ('bmPlanes', ctypes.c_ushort),
        ('bmBitsPixel', ctypes.c_ushort),
        ('bmBits', ctypes.c_void_p),
    ]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ('biSize', ctypes.c_uint32),
        ('biWidth', ctypes.c_long),
        ('biHeight', ctypes.c_long),
        ('biPlanes', ctypes.c_ushort),
        ('biBitCount', ctypes.c_ushort),
        ('biCompression', ctypes.c_uint32),
        ('biSizeImage', ctypes.c_uint32),
        ('biXPelsPerMeter', ctypes.c_long),
        ('biYPelsPerMeter', ctypes.c_long),
        ('biClrUsed', ctypes.c_uint32),
        ('biClrImportant', ctypes.c_uint32),
    ]


class RGBQUAD(ctypes.Structure):
    _fields_ = [
        ('rgbBlue', ctypes.c_ubyte),
        ('rgbGreen', ctypes.c_ubyte),
        ('rgbRed', ctypes.c_ubyte),
        ('rgbReserved', ctypes.c_ubyte),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [
        ('bmiHeader', BITMAPINFOHEADER),
        ('bmiColors', RGBQUAD * 1),
    ]


class WebSocketSignaling:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.ws = None
        self.ws_thread = None
        self.connected = False
        self.running = False
        self.room_id: Optional[str] = None
        self.role = 'agent'
        self.on_message: Optional[Callable[[dict], None]] = None
        self.join_metadata: dict = {}

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
        self.join_metadata = metadata or {}

        try:
            ws_url = self._get_ws_url()
            logger.info('Connecting to WebSocket server: %s', ws_url)

            self.ws = websocket.WebSocketApp(
                ws_url,
                on_open=self._on_ws_open,
                on_message=self._on_ws_message,
                on_error=self._on_ws_error,
                on_close=self._on_ws_close,
            )

            self.ws_thread = threading.Thread(target=self.ws.run_forever, daemon=True)
            self.ws_thread.start()

            start_time = time.time()
            while not self.connected and (time.time() - start_time) < 5:
                time.sleep(0.1)

            if self.connected:
                logger.info('Room ID: %s', self.room_id)
                return True

            logger.error('Connection timed out')
            return False
        except Exception as exc:
            logger.error('Connection failed: %s', exc)
            return False

    def disconnect(self):
        self.running = False
        self.connected = False
        if self.ws:
            self.ws.close()

    def _generate_room_id(self) -> str:
        return 'pw-' + uuid.uuid4().hex[:8]

    def _on_ws_open(self, ws):
        logger.info('WebSocket connected: room=%s role=%s', self.room_id, self.role)
        self.connected = True
        self.running = True
        self._send(
            {
                'type': 'join_room',
                'room_id': self.room_id,
                'role': self.role,
                'metadata': self.join_metadata,
            }
        )

    def _on_ws_message(self, ws, message):
        try:
            data = json.loads(message)
            logger.debug('WS recv type=%s', data.get('type'))
            if self.on_message:
                self.on_message(data)
        except json.JSONDecodeError:
            logger.debug('Received non-JSON message: %s', str(message)[:100])

    def _on_ws_error(self, ws, error):
        logger.error('WebSocket error: room=%s error=%s', self.room_id, error)

    def _on_ws_close(self, ws, close_status_code, close_msg):
        logger.warning(
            'WebSocket closed: room=%s code=%s message=%s running=%s connected=%s',
            self.room_id,
            close_status_code,
            close_msg,
            self.running,
            self.connected,
        )
        self.connected = False
        self.running = False

    def _send(self, data: dict):
        if not self.connected or not self.ws:
            return
        try:
            self.ws.send(json.dumps(data))
        except Exception as exc:
            logger.error('Send error: type=%s error=%s', data.get('type'), exc)
            self.connected = False


def _can_reach_endpoint(host: str, port: int, timeout: float = 1.5) -> bool:
    return can_reach_endpoint(host, port, timeout=timeout)


_ENDPOINT_HEALTH_CACHE: dict[tuple[str, int], tuple[float, bool]] = {}
_ENDPOINT_HEALTH_TTL_SECONDS = 5.0
_ENDPOINT_HEALTH_LOCK = threading.Lock()


def _verify_signaling_endpoint(
    host: str,
    port: int,
    tcp_timeout: float = 1.0,
    http_timeout: float = 1.5,
    use_cache: bool = True,
) -> bool:
    return verify_signaling_endpoint(
        host,
        port,
        tcp_timeout=tcp_timeout,
        http_timeout=http_timeout,
        use_cache=use_cache,
    )


def _invalidate_endpoint_health_cache(host: Optional[str] = None, port: Optional[int] = None) -> None:
    invalidate_endpoint_health_cache(host, port)


def _resolve_host_ipv4_addresses(host: str, timeout: float = 1.5) -> list[str]:
    return resolve_host_ipv4_addresses(host, timeout=timeout)


def _is_private_ipv4(value: str) -> bool:
    return is_private_ipv4(value)


def _is_private_host(value: str) -> bool:
    return is_private_host(value)


def _parse_signaling_url(url: str) -> Optional[tuple[str, str, int]]:
    return parse_signaling_url(url)


def _normalize_signaling_endpoint(item) -> Optional[dict]:
    return normalize_signaling_endpoint(item)


def _dedupe_preserve_order(values: list[str]) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = str(value or '').strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        results.append(normalized)
    return results


class _LanProbeHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, request_handler_class, agent=None):
        super().__init__(server_address, request_handler_class)
        self.agent = agent


class _LanProbeRequestHandler(http.server.BaseHTTPRequestHandler):
    server_version = 'PocketWindowLanProbe/1.0'

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/probe':
            self._send_text('ok')
            return
        if parsed.path == '/probe/info':
            self._send_json(self._probe_info_payload())
            return
        if parsed.path != '/probe':
            self.send_response(404)
            self.end_headers()
            return

    def _probe_info_payload(self) -> dict:
        agent = getattr(self.server, 'agent', None)
        if agent is None:
            return {'ok': False, 'error': 'agent unavailable'}
        return {
            'ok': True,
            'protocol': 'pocketwindow-lan-probe',
            'version': 1,
            'device_id': agent.device_id,
            'device_name': platform.node() or socket.gethostname(),
            'room_id': getattr(agent, 'room_id', ''),
            'local_ips': list(getattr(agent, '_cached_local_ips', []) or []),
            'lan_probe_port': getattr(agent, '_lan_probe_port', 0),
            'lan_direct_port': getattr(agent, '_lan_direct_port', 0),
            'capabilities': {
                'lan_probe': True,
                'lan_direct_control': True,
                'lan_direct_video': True,
            },
        }

    def _send_text(self, value: str):
        body = value.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        logger.debug('lan-probe ' + format, *args)


class WindowsCaptureSession:
    def __init__(self):
        self._capture = None
        self._control = None
        self._hwnd: Optional[int] = None
        self._frame_lock = threading.Lock()
        self._latest_frame: Optional[np.ndarray] = None
        self._last_frame_at = 0.0
        self._closed = False
        self._last_error: Optional[str] = None

    @property
    def last_error(self) -> Optional[str]:
        return self._last_error

    def ensure_started(self, hwnd: int) -> bool:
        if NativeWindowsCapture is None:
            self._last_error = 'windows-capture package is not installed'
            return False

        if self._hwnd == hwnd and self._control and not self._control.is_finished():
            return True

        self.stop()
        self._hwnd = hwnd
        self._closed = False
        self._last_error = None
        self._latest_frame = None
        self._last_frame_at = 0.0

        capture = NativeWindowsCapture(
            cursor_capture=False,
            draw_border=False,
            window_hwnd=hwnd,
        )

        @capture.event
        def on_frame_arrived(frame, capture_control):
            try:
                rgb = np.ascontiguousarray(frame.frame_buffer[:, :, :3][:, :, ::-1])
                with self._frame_lock:
                    self._latest_frame = rgb.copy()
                    self._last_frame_at = time.time()
            except Exception as exc:
                self._last_error = f'windows-capture frame callback failed: {exc}'
                logger.error('windows-capture frame callback failed: %s', exc)
                capture_control.stop()

        @capture.event
        def on_closed():
            self._closed = True
            logger.warning('windows-capture session closed: hwnd=%s', hwnd)

        self._capture = capture
        self._control = capture.start_free_threaded()
        logger.info('windows-capture session started: hwnd=%s', hwnd)
        return True

    def get_latest_frame(self, hwnd: int) -> Optional[np.ndarray]:
        if not self.ensure_started(hwnd):
            return None

        with self._frame_lock:
            if self._latest_frame is None:
                return None
            return self._latest_frame.copy()

    def stop(self):
        control = self._control
        self._control = None
        self._capture = None
        self._hwnd = None
        self._closed = False
        with self._frame_lock:
            self._latest_frame = None

        if control:
            try:
                control.stop()
            except Exception:
                pass


class ScreenCapture:
    def __init__(self):
        self.last_capture_path = 'none'
        self.last_capture_error: Optional[str] = None
        self.last_frame_size: tuple[int, int] = (0, 0)
        self.last_frame_space = 'client'
        self.last_capture_bounds: Optional[tuple[int, int, int, int]] = None
        self._terminal_capture = WindowsCaptureSession()
        self._terminal_ready_hwnd: Optional[int] = None

    def _should_force_client_space(self, hwnd: int) -> bool:
        try:
            if not hwnd:
                return False
            title = win32gui.GetWindowText(hwnd) or ''
            return title == DESKTOP_UI_WINDOW_TITLE
        except Exception:
            return False

    def capture_desktop(self) -> Optional[np.ndarray]:
        screen_dc = None
        mfc_dc = None
        save_dc = None
        bitmap = None
        old_bitmap = None
        try:
            left = win32api.GetSystemMetrics(win32con.SM_XVIRTUALSCREEN)
            top = win32api.GetSystemMetrics(win32con.SM_YVIRTUALSCREEN)
            width = win32api.GetSystemMetrics(win32con.SM_CXVIRTUALSCREEN)
            height = win32api.GetSystemMetrics(win32con.SM_CYVIRTUALSCREEN)
            if width <= 0 or height <= 0:
                self.last_capture_error = 'invalid-desktop-rect'
                return None

            screen_dc = win32gui.GetDC(0)
            mfc_dc = win32ui.CreateDCFromHandle(screen_dc)
            save_dc = mfc_dc.CreateCompatibleDC()
            bitmap = win32ui.CreateBitmap()
            bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
            old_bitmap = save_dc.SelectObject(bitmap)
            save_dc.BitBlt((0, 0), (width, height), mfc_dc, (left, top), win32con.SRCCOPY)

            bmpinfo = bitmap.GetInfo()
            bmpstr = bitmap.GetBitmapBits(True)
            image = Image.frombuffer(
                'RGB',
                (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                bmpstr,
                'raw',
                'BGRX',
                0,
                1,
            )
            frame = np.array(image)
            self.last_capture_path = 'desktop-dc'
            self.last_frame_space = 'desktop'
            self.last_frame_size = (frame.shape[1], frame.shape[0])
            self.last_capture_bounds = (left, top, left + width, top + height)
            self.last_capture_error = None
            return frame
        except Exception as exc:
            self.last_capture_error = str(exc)
            logger.error('Desktop capture error: %s', exc)
            return None
        finally:
            if save_dc and old_bitmap:
                try:
                    save_dc.SelectObject(old_bitmap)
                except Exception:
                    pass
            if bitmap:
                win32gui.DeleteObject(bitmap.GetHandle())
            if save_dc:
                save_dc.DeleteDC()
            if mfc_dc:
                mfc_dc.DeleteDC()
            if screen_dc:
                win32gui.ReleaseDC(0, screen_dc)

    def capture_window(self, hwnd: int) -> Optional[np.ndarray]:
        try:
            class_name = ''
            try:
                class_name = win32gui.GetClassName(hwnd)
            except Exception:
                pass

            frame = None
            if class_name == 'CASCADIA_HOSTING_WINDOW_CLASS':
                if self._terminal_ready_hwnd != hwnd:
                    self._terminal_ready_hwnd = None
                self.last_capture_path = 'windows-capture-terminal'
                self.last_frame_space = 'window'
                frame = self._terminal_capture.get_latest_frame(hwnd)
                if frame is not None:
                    self._terminal_ready_hwnd = hwnd
                    rect = win32gui.GetWindowRect(hwnd)
                    self.last_capture_bounds = rect
                elif self._terminal_ready_hwnd == hwnd:
                    self.last_capture_error = self._terminal_capture.last_error or 'windows-capture temporarily returned no frame'
                    return None
                else:
                    self.last_capture_error = self._terminal_capture.last_error or 'windows-capture no frame yet'
                    return None
            else:
                if self._should_force_client_space(hwnd):
                    frame = self._capture_window_with_owned_popups(hwnd, space='client')
                else:
                    frame = self._capture_window_with_owned_popups(hwnd, space='window')

            if frame is None:
                left, top, right, bottom = self._client_screen_rect(hwnd)
                width = right - left
                height = bottom - top
                if width <= 0 or height <= 0:
                    self.last_capture_error = 'invalid-client-rect'
                    return None
                self.last_capture_path = 'window-dc-fallback'
                self.last_frame_space = 'client'
                self.last_capture_bounds = (left, top, right, bottom)
                frame = self._capture_window_dc(hwnd, width, height, left, top)

            if frame is None:
                self.last_capture_error = 'all-capture-paths-returned-none'
                return None

            self.last_capture_error = None
            self.last_frame_size = (frame.shape[1], frame.shape[0])
            return frame
        except Exception as exc:
            self.last_capture_error = str(exc)
            logger.error('Capture error: %s', exc)
            return None

    def release_window_resources(self, hwnd: Optional[int] = None):
        try:
            target_hwnd = int(hwnd) if hwnd is not None else None
        except Exception:
            target_hwnd = None
        if target_hwnd is None or self._terminal_capture._hwnd == target_hwnd:
            self._terminal_capture.stop()
            self._terminal_ready_hwnd = None

    def _popup_root_owner(self, hwnd: int) -> int:
        try:
            return int(ctypes.windll.user32.GetAncestor(hwnd, 3))
        except Exception:
            return 0

    def _enumerate_owned_popups(self, hwnd: int) -> list[int]:
        try:
            _, target_pid = win32process.GetWindowThreadProcessId(hwnd)
            target_rect = win32gui.GetWindowRect(hwnd)
        except Exception:
            return []

        results: list[int] = []

        def enum_callback(candidate_hwnd, _):
            try:
                if candidate_hwnd == hwnd or not win32gui.IsWindowVisible(candidate_hwnd):
                    return True
                _, candidate_pid = win32process.GetWindowThreadProcessId(candidate_hwnd)
                if candidate_pid != target_pid:
                    return True
                class_name = win32gui.GetClassName(candidate_hwnd)
                title = win32gui.GetWindowText(candidate_hwnd) or ''
                if class_name != 'TkTopLevel':
                    return True
                if title != 'popdown':
                    return True
                rect = win32gui.GetWindowRect(candidate_hwnd)
                if rect[2] <= rect[0] or rect[3] <= rect[1]:
                    return True
                horizontal_overlap = min(target_rect[2], rect[2]) - max(target_rect[0], rect[0])
                vertical_overlap = min(target_rect[3], rect[3]) - max(target_rect[1], rect[1])
                near_main_window = (
                    horizontal_overlap > 0
                    and rect[1] <= target_rect[3] + 64
                    and rect[3] >= target_rect[1] - 64
                ) or (
                    vertical_overlap > 0
                    and rect[0] <= target_rect[2] + 64
                    and rect[2] >= target_rect[0] - 64
                )
                if near_main_window:
                    results.append(candidate_hwnd)
            except Exception:
                return True
            return True

        try:
            win32gui.EnumWindows(enum_callback, None)
        except Exception:
            return []
        return results

    def _capture_window_with_owned_popups(self, hwnd: int, space: str) -> Optional[np.ndarray]:
        if space == 'client':
            base_rect = self._client_screen_rect(hwnd)
        else:
            base_rect = win32gui.GetWindowRect(hwnd)

        base_width = base_rect[2] - base_rect[0]
        base_height = base_rect[3] - base_rect[1]
        if base_width <= 0 or base_height <= 0:
            self.last_capture_error = f'invalid-{space}-rect'
            return None

        popup_hwnds = self._enumerate_owned_popups(hwnd)
        popup_rects: list[tuple[int, int, int, int]] = []
        union_left, union_top, union_right, union_bottom = base_rect
        for popup_hwnd in popup_hwnds:
            try:
                rect = win32gui.GetWindowRect(popup_hwnd)
            except Exception:
                continue
            if rect[2] <= rect[0] or rect[3] <= rect[1]:
                continue
            popup_rects.append(rect)
            union_left = min(union_left, rect[0])
            union_top = min(union_top, rect[1])
            union_right = max(union_right, rect[2])
            union_bottom = max(union_bottom, rect[3])

        width = union_right - union_left
        height = union_bottom - union_top
        if width <= 0 or height <= 0:
            self.last_capture_error = 'invalid-composite-rect'
            return None

        composite = np.zeros((height, width, 3), dtype=np.uint8)
        frame = None
        if space == 'client':
            frame = self._capture_window_dc(hwnd, base_width, base_height, base_rect[0], base_rect[1])
            self.last_capture_path = 'window-dc-client'
            self.last_frame_space = 'client'
        else:
            frame = self._capture_with_print_window(hwnd, include_non_client=False)
            self.last_capture_path = 'printwindow'
            self.last_frame_space = 'window'

        if frame is None:
            return None

        base_x = base_rect[0] - union_left
        base_y = base_rect[1] - union_top
        composite[base_y:base_y + frame.shape[0], base_x:base_x + frame.shape[1]] = frame[:, :, :3]

        popup_count = 0
        for popup_hwnd, popup_rect in zip(popup_hwnds, popup_rects):
            popup_width = popup_rect[2] - popup_rect[0]
            popup_height = popup_rect[3] - popup_rect[1]
            popup_frame = self._capture_with_print_window(popup_hwnd, include_non_client=True)
            if popup_frame is None:
                popup_frame = self._capture_window_dc(
                    popup_hwnd,
                    popup_width,
                    popup_height,
                    popup_rect[0],
                    popup_rect[1],
                )
            if popup_frame is None:
                continue
            offset_x = popup_rect[0] - union_left
            offset_y = popup_rect[1] - union_top
            composite[offset_y:offset_y + popup_frame.shape[0], offset_x:offset_x + popup_frame.shape[1]] = popup_frame[:, :, :3]
            popup_count += 1

        self.last_capture_bounds = (union_left, union_top, union_right, union_bottom)
        if popup_count:
            self.last_capture_path = f'{self.last_capture_path}+popup'
        return composite

    def _terminal_content_rect(self, hwnd: int) -> Optional[tuple[int, int, int, int]]:
        rects: list[tuple[int, int, int, int]] = []

        def enum_callback(child_hwnd, result):
            try:
                cls = win32gui.GetClassName(child_hwnd)
                if cls == 'Windows.UI.Composition.DesktopWindowContentBridge':
                    result.append(win32gui.GetWindowRect(child_hwnd))
            except Exception:
                pass

        try:
            win32gui.EnumChildWindows(hwnd, enum_callback, rects)
        except Exception:
            return None

        if not rects:
            return None

        left = min(item[0] for item in rects)
        top = min(item[1] for item in rects)
        right = max(item[2] for item in rects)
        bottom = max(item[3] for item in rects)
        return left, top, right, bottom

    def _capture_with_print_window(self, hwnd: int, include_non_client: bool) -> Optional[np.ndarray]:
        hwnd_dc = None
        mfc_dc = None
        save_dc = None
        bitmap = None
        old_bitmap = None
        try:
            window_rect = win32gui.GetWindowRect(hwnd)
            total_width = window_rect[2] - window_rect[0]
            total_height = window_rect[3] - window_rect[1]
            if total_width <= 0 or total_height <= 0:
                return None

            hwnd_dc = win32gui.GetWindowDC(hwnd)
            mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
            save_dc = mfc_dc.CreateCompatibleDC()

            bitmap = win32ui.CreateBitmap()
            bitmap.CreateCompatibleBitmap(mfc_dc, total_width, total_height)
            old_bitmap = save_dc.SelectObject(bitmap)

            flags = 0x00000002 if include_non_client else 0x00000003
            result = ctypes.windll.user32.PrintWindow(hwnd, save_dc.GetSafeHdc(), flags)
            if result != 1:
                return None

            bmpinfo = bitmap.GetInfo()
            bmpstr = bitmap.GetBitmapBits(True)
            image = Image.frombuffer(
                'RGB',
                (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                bmpstr,
                'raw',
                'BGRX',
                0,
                1,
            )
            full_frame = np.array(image)

            if include_non_client:
                client_rect = win32gui.GetClientRect(hwnd)
                client_origin = win32gui.ClientToScreen(hwnd, (0, 0))
                offset_x = client_origin[0] - window_rect[0]
                offset_y = client_origin[1] - window_rect[1]
                client_width = client_rect[2] - client_rect[0]
                client_height = client_rect[3] - client_rect[1]
                return full_frame[offset_y:offset_y + client_height, offset_x:offset_x + client_width]

            return full_frame
        except Exception:
            return None
        finally:
            if save_dc and old_bitmap:
                try:
                    save_dc.SelectObject(old_bitmap)
                except Exception:
                    pass
            if bitmap:
                win32gui.DeleteObject(bitmap.GetHandle())
            if save_dc:
                save_dc.DeleteDC()
            if mfc_dc:
                mfc_dc.DeleteDC()
            if hwnd_dc:
                win32gui.ReleaseDC(hwnd, hwnd_dc)

    def _client_screen_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        client_left, client_top, client_right, client_bottom = win32gui.GetClientRect(hwnd)
        origin_left, origin_top = win32gui.ClientToScreen(hwnd, (client_left, client_top))
        origin_right, origin_bottom = win32gui.ClientToScreen(hwnd, (client_right, client_bottom))
        return origin_left, origin_top, origin_right, origin_bottom

    def _capture_window_dc(
        self,
        hwnd: int,
        width: int,
        height: int,
        screen_left: int,
        screen_top: int,
    ) -> Optional[np.ndarray]:
        try:
            if width <= 0 or height <= 0:
                self.last_capture_error = 'invalid-screen-grab-size'
                return None
            image = ImageGrab.grab(
                bbox=(screen_left, screen_top, screen_left + width, screen_top + height),
                all_screens=True,
            ).convert('RGB')
            return np.array(image)
        except Exception as exc:
            self.last_capture_error = f'screen-grab failed: {exc}'
            return None

    def _draw_cursor(self, frame: np.ndarray, hwnd: int):
        try:
            cursor_screen_x, cursor_screen_y = win32api.GetCursorPos()
            capture_bounds = self.last_capture_bounds
            if capture_bounds is not None and self.last_frame_space != 'desktop':
                cursor_client_x = cursor_screen_x - capture_bounds[0]
                cursor_client_y = cursor_screen_y - capture_bounds[1]
            elif self.last_frame_space == 'window':
                window_left, window_top, _, _ = win32gui.GetWindowRect(hwnd)
                cursor_client_x = cursor_screen_x - window_left
                cursor_client_y = cursor_screen_y - window_top
            else:
                cursor_client_x, cursor_client_y = win32gui.ScreenToClient(
                    hwnd, (cursor_screen_x, cursor_screen_y)
                )
            frame_height, frame_width = frame.shape[:2]
            if (
                cursor_client_x < 0
                or cursor_client_y < 0
                or cursor_client_x >= frame_width
                or cursor_client_y >= frame_height
            ):
                return

            center = (int(cursor_client_x), int(cursor_client_y))
            arrow = np.array(
                [
                    [center[0], center[1]],
                    [center[0], center[1] + 24],
                    [center[0] + 6, center[1] + 18],
                    [center[0] + 11, center[1] + 30],
                    [center[0] + 16, center[1] + 28],
                    [center[0] + 11, center[1] + 16],
                    [center[0] + 22, center[1] + 16],
                ],
                dtype=np.int32,
            )

            cv2.fillPoly(frame, [arrow], (0, 0, 0))
            inner_arrow = arrow.copy()
            inner_arrow[:, 0] += 1
            inner_arrow[:, 1] += 1
            cv2.fillPoly(frame, [inner_arrow], (255, 255, 255))
            cv2.circle(frame, center, 5, (0, 0, 0), -1)
            cv2.circle(frame, center, 3, (255, 60, 60), -1)
        except Exception:
            return

    def compress_frame(
        self,
        frame: np.ndarray,
        fmt: str = 'jpg',
        quality: int = 70,
        png_compression: int = 2,
    ) -> Optional[bytes]:
        try:
            bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
            ext = '.jpg'
            params = [cv2.IMWRITE_JPEG_QUALITY, quality]
            if fmt == 'png':
                ext = '.png'
                params = [cv2.IMWRITE_PNG_COMPRESSION, png_compression]
            ok, buffer = cv2.imencode(ext, bgr, params)
            return buffer.tobytes() if ok else None
        except Exception:
            return None


class H264AnnexBEncoder:
    def __init__(self, codec_name: str = 'libx264', stream_codec: str = 'h264'):
        self.codec_name = codec_name
        self.stream_codec = stream_codec
        self._lock = threading.RLock()
        self._codec = None
        self._width = 0
        self._height = 0
        self._fps = 0
        self._bitrate_kbps = 0
        self._crf = ''
        self._bufsize_multiplier = 0
        self._pixel_format = ''
        self._preset = ''
        self._frames = 0
        self._failed = False
        self._content_width = 0
        self._content_height = 0
        self.last_encode_ms = 0.0
        self.last_packet_count = 0
        self.empty_outputs = 0

    @property
    def failed(self) -> bool:
        return self._failed

    @property
    def ready(self) -> bool:
        return self._codec is not None and not self._failed

    @property
    def encoded_size(self) -> tuple[int, int]:
        return self._width, self._height

    @property
    def content_size(self) -> tuple[int, int]:
        w = self._content_width or self._width
        h = self._content_height or self._height
        return w, h

    def _target_bitrate_kbps(self, width: int, height: int, fps: int) -> int:
        pixels = max(1, width * height)
        # Desktop text is much less tolerant of block artifacts than camera video.
        # Keep the low-latency encoder, but give it enough VBV headroom while scrolling.
        if self.stream_codec == 'h265':
            kbps = int(pixels * max(24, fps) * 0.105 / 1000)
            return max(5000, min(18000, kbps))
        kbps = int(pixels * max(24, fps) * 0.145 / 1000)
        return max(7000, min(24000, kbps))

    def reset(self):
        with self._lock:
            self._codec = None
            self._width = 0
            self._height = 0
            self._fps = 0
            self._bitrate_kbps = 0
            self._crf = ''
            self._bufsize_multiplier = 0
            self._pixel_format = ''
            self._preset = ''
            self._frames = 0
            self._failed = False
            self._content_width = 0
            self._content_height = 0
            self.last_encode_ms = 0.0
            self.last_packet_count = 0
            self.empty_outputs = 0

    def close(self):
        with self._lock:
            self._codec = None

    def encode(
        self,
        frame: np.ndarray,
        fps: float,
        *,
        bitrate_kbps: Optional[int] = None,
        crf: Optional[str] = None,
        bufsize_multiplier: Optional[int] = None,
        pixel_format: Optional[str] = None,
        preset: Optional[str] = None,
    ) -> Optional[bytes]:
        if self._failed or frame is None or not hasattr(frame, 'shape') or len(frame.shape) < 2:
            return None
        encode_started_at = time.perf_counter()
        try:
            import av
            from fractions import Fraction

            with self._lock:
                if self._failed:
                    return None
                height = int(frame.shape[0])
                width = int(frame.shape[1])
                self._content_width = width
                self._content_height = height
                pad_w = (width + 15) // 16 * 16
                pad_h = (height + 15) // 16 * 16
                if pad_w != width or pad_h != height:
                    frame = cv2.copyMakeBorder(
                        frame, 0, pad_h - height, 0, pad_w - width,
                        cv2.BORDER_REPLICATE,
                    )
                    width = pad_w
                    height = pad_h

                target_fps = max(10, min(60, int(round(fps or 24))))
                requested_bitrate_kbps = int(bitrate_kbps) if bitrate_kbps else 0
                requested_crf = str(crf or '35')
                requested_bufsize_multiplier = max(2, min(8, int(bufsize_multiplier or 2)))
                requested_pixel_format = 'yuv444p' if pixel_format == 'yuv444p' else 'yuv420p'
                requested_preset = str(preset or 'veryfast').strip().lower()
                if requested_preset not in {'ultrafast', 'superfast', 'veryfast', 'faster', 'fast'}:
                    requested_preset = 'veryfast'
                if (
                    self._codec is None
                    or self._width != width
                    or self._height != height
                    or self._bitrate_kbps != requested_bitrate_kbps
                    or self._crf != requested_crf
                    or self._bufsize_multiplier != requested_bufsize_multiplier
                    or self._pixel_format != requested_pixel_format
                    or self._preset != requested_preset
                ):
                    self._codec = av.CodecContext.create(self.codec_name, 'w')
                    self._codec.width = width
                    self._codec.height = height
                    self._codec.time_base = Fraction(1, target_fps)
                    self._codec.framerate = Fraction(target_fps, 1)
                    self._codec.pix_fmt = requested_pixel_format
                    target_kbps = requested_bitrate_kbps or self._target_bitrate_kbps(width, height, target_fps)
                    target_bufsize = target_kbps * requested_bufsize_multiplier
                    self._codec.bit_rate = target_kbps * 1000
                    if self.stream_codec == 'h265':
                        keyint = max(180, target_fps * 4)
                        self._codec.options = {
                            'preset': requested_preset,
                            'tune': 'zerolatency',
                            'x265-params': (
                                f'bframes=0:keyint={keyint}:min-keyint={keyint}:'
                                'scenecut=0:repeat-headers=1:frame-threads=1:'
                                f'rc-lookahead=0:ref=1:crf={requested_crf}:'
                                f'vbv-maxrate={target_kbps}:vbv-bufsize={target_bufsize}'
                            ),
                        }
                    else:
                        keyint = max(15, target_fps)
                        self._codec.options = {
                            'preset': requested_preset,
                            'tune': 'zerolatency',
                            'crf': requested_crf,
                            'maxrate': f'{target_kbps}k',
                            'bufsize': f'{target_bufsize}k',
                            'bf': '0',
                            'g': str(keyint),
                            'x264-params': (
                                f'keyint={keyint}:min-keyint={keyint}:'
                                'scenecut=0:repeat-headers=1'
                            ),
                        }
                    self._codec.open()
                    self._width = width
                    self._height = height
                    self._fps = target_fps
                    self._bitrate_kbps = requested_bitrate_kbps
                    self._crf = requested_crf
                    self._bufsize_multiplier = requested_bufsize_multiplier
                    self._pixel_format = requested_pixel_format
                    self._preset = requested_preset
                    self._frames = 0
                    logger.info(
                        'Video encoder opened: codec=%s size=%sx%s fps=%s pix_fmt=%s bitrate_kbps=%s crf=%s bufsize_kbps=%s bufsize_multiplier=%s preset=%s',
                        self.stream_codec,
                        width,
                        height,
                        target_fps,
                        self._codec.pix_fmt,
                        target_kbps,
                        requested_crf,
                        target_bufsize,
                        requested_bufsize_multiplier,
                        requested_preset,
                    )

                video_frame = av.VideoFrame.from_ndarray(frame, format='rgb24')
                video_frame.pts = self._frames
                self._frames += 1
                packets = self._codec.encode(video_frame)
                self.last_encode_ms = (time.perf_counter() - encode_started_at) * 1000.0
                self.last_packet_count = len(packets or [])
                if not packets:
                    self.empty_outputs += 1
                    return b''
                return b''.join(bytes(packet) for packet in packets)
        except AttributeError as exc:
            self.last_encode_ms = (time.perf_counter() - encode_started_at) * 1000.0
            logger.debug('%s encode skipped (encoder reset mid-frame): %s', self.stream_codec.upper(), exc)
            return b''
        except Exception as exc:
            self.last_encode_ms = (time.perf_counter() - encode_started_at) * 1000.0
            self._failed = True
            logger.warning('%s encoder disabled: %s', self.stream_codec.upper(), exc)
            return None


class PocketWindowAgent:
    STREAM_STATE_STATIC = 'static'
    STREAM_STATE_LOW_MOTION = 'low_motion'
    STREAM_STATE_HIGH_MOTION = 'high_motion'

    VIDEO_DELAY_THROTTLE_MS = 1600
    VIDEO_DELAY_RESUME_MS = 600
    VIDEO_DELAY_SAMPLE_STALE_S = 4.0
    # Minimum dwell time after engaging backpressure before it may clear, to stop
    # the engage/clear oscillation that happens when the link delay rides right
    # on the threshold.
    VIDEO_DELAY_MIN_DWELL_S = 1.5
    # While backpressured we do NOT fully stop sending. Instead we pace H264
    # frames at this reduced rate so the stream stays continuous (slow but never
    # stalling) and the client never sees a >1.5s gap that would flip the status
    # label to image mode. ~10fps.
    VIDEO_BACKPRESSURE_MIN_INTERVAL_S = 0.1

    STREAM_PROFILES = {
        'hybrid': {
            'label': 'hybrid',
            'low_motion_fps': 10.0,
            'high_motion_fps': 30.0,
            'static_hold_seconds': 60.0,
            'low_motion_hold_seconds': 2.0,
            'high_motion_hold_seconds': 0.45,
            'static_diff_threshold': 0.05,
            'high_motion_diff_threshold': 1.5,
            'low_motion_scale': 0.72,
            'low_motion_jpeg_quality': 44,
            'low_motion_png_compression': 5,
            'low_motion_encode_format': 'jpg',
            'high_motion_scale': 0.58,
            'high_motion_jpeg_quality': 34,
            'high_motion_png_compression': 6,
            'high_motion_encode_format': 'jpg',
            'static_scale': 1.0,
            'static_jpeg_quality': 86,
            'static_png_compression': 2,
            'static_encode_format': 'png',
        },
        'lan': {
            'label': 'lan',
            'loop_sleep': 1.0 / 60.0,
            'min_send_interval': 1.0 / 60.0,
            'max_stale_interval': 1.0 / 60.0,
            'scale': 1.0,
            'jpeg_quality': 88,
            'png_compression': 2,
            'diff_threshold': 0.0,
        },
        'smooth_hd': {
            'label': 'smooth_hd',
            'loop_sleep': 1.0 / 60.0,
            'min_send_interval': 1.0 / 60.0,
            'max_stale_interval': 1.0 / 60.0,
            'scale': 1.0,
            'jpeg_quality': 84,
            'png_compression': 2,
            'diff_threshold': 0.0,
        },
    }

    def __init__(self, server: str, port: int):
        self.server = server
        self.port = port
        self._preferred_endpoints: list[dict] = []
        self._endpoints_changed_event = threading.Event()
        self._lan_probe_port = DEFAULT_LAN_PROBE_PORT
        self._lan_direct_port = DEFAULT_LAN_DIRECT_PORT
        self._lan_probe_server: Optional[_LanProbeHttpServer] = None
        self._lan_probe_thread: Optional[threading.Thread] = None
        self._current_signaling_route = 'wan'
        self._last_signaling_route_switch_at = 0.0
        self._last_route_reevaluation_at = 0.0
        self._last_activated_hwnd = 0
        self._last_activated_at = 0.0
        self._state_store = AgentStateStore(self._state_file_path(), logger=logger)
        self.device_id = self._load_or_create_device_id()
        self._persistent_room_id = self._state_store.load_or_create_room_id()
        self.signaling = DualChannelSignaling(server, port, stream_count=2)
        self.signaling.room_id = self._persistent_room_id
        self.signaling.on_message = self._on_message
        self._direct_transport = DirectTransport(self.signaling.send_webrtc_signal, self)
        self._public_direct_settings = self._state_store.load_public_direct_settings()
        self._lan_direct_port = DEFAULT_LAN_DIRECT_PORT
        self._lan_direct_server = LanDirectServer(
            '0.0.0.0',
            self._lan_direct_port,
            device_id=self.device_id,
            room_id_getter=lambda: self.signaling.room_id or self._ui_room_id or '',
            trusted_client_checker=lambda client_id: self._is_trusted_client(client_id),
            on_message=self._on_message,
            download_whitelist_getter=lambda: list(self._public_direct_settings.get('download_whitelist') or []),
        )

        self.capture = ScreenCapture()
        logger.info('ScreenCapture config: terminal_capture=windows-capture')
        self.target_hwnd: Optional[int] = None
        self.target_window_title: Optional[str] = None
        self.target_mode = 'window'
        self._stop_requested = threading.Event()
        self.running = False
        self.client_connected = False
        self._original_window_rect: Optional[tuple[int, int, int, int]] = None
        self._original_client_size: Optional[tuple[int, int]] = None
        self._capture_thread: Optional[threading.Thread] = None
        self._cursor_thread: Optional[threading.Thread] = None
        self._capture_frames_sent = 0
        self._capture_frames_skipped = 0
        self._capture_empty_frames = 0
        self._cursor_updates_sent = 0
        self._last_capture_path = ''
        self._last_capture_log_at = 0.0
        self._last_empty_log_at = 0.0
        self._last_skip_log_at = 0.0
        self._last_cursor_log_at = 0.0
        self._last_handle_log_at = 0.0
        self._last_scroll_mode_log_at = 0.0
        self._stream_profile_id = 'hybrid'
        self._cached_local_ips: list[str] = []
        self._video_paused = False
        self._stream_quality_scale = 1.0
        self._stream_resolution_scale = 1.0
        self._dynamic_fps_limit = 20.0
        self._static_fps_limit = 2.0
        self._scroll_mode_active = False
        self._scroll_video_scale = 0.70
        self._scroll_video_bitrate_kbps = 4000
        self._scroll_video_fps = 24.0
        self._scroll_video_crf = '26'
        self._scroll_video_vbv_multiplier = 3
        self._scroll_video_pixel_format = 'yuv420p'
        self._scroll_video_preset = 'veryfast'
        self._motion_boost_until = 0.0
        self._stream_state = self.STREAM_STATE_STATIC
        self._stream_state_until = 0.0
        self._static_clear_frame_pending = False
        self._static_clear_frame_due_at = 0.0
        self._last_motion_score = 0.0
        self._last_change_percent = 0.0
        self._last_diff_intensity = 0.0
        self._window_title_cache: dict[int, str] = {}
        self._windows_list_cache: list[dict] = []
        self._windows_list_cache_at = 0.0
        self._windows_list_lock = threading.Lock()
        self._window_remarks = self._state_store.load_window_remarks()
        self._last_sent_at = 0.0
        self._image_frame_in_flight = False
        self._last_image_frame_ack_at = 0.0
        self._last_image_frame_seq = 0
        self._last_video_stream_seq = 0
        self._h264_encoder = H264AnnexBEncoder()
        self._h265_encoder = H264AnnexBEncoder('libx265', 'h265')
        self._terminal_manager = TerminalManager(self._send_peer_control)
        self._video_peak_limiter = VideoPeakLimiter()
        self._video_stream_codec = 'h264'
        self._video_stream_started_codec = ''
        self._h264_stream_started = False
        self._h264_client_active = False
        self._last_video_stream_start_sent_at = 0.0
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._video_startup_burst_until = 0.0
        self._video_startup_stable_until = 0.0
        self._video_start_wait_until = 0.0
        self._video_start_wait_reason = ''
        self._video_start_stable_size: tuple[int, int] = (0, 0)
        self._video_start_stable_since = 0.0
        self._video_start_content_signature: Optional[np.ndarray] = None
        self._video_start_content_stable_since = 0.0
        self._fit_target_aspect: float = 0.0
        self._fit_target_hwnd: Optional[int] = None
        self._last_fit_aspect_crop_log_at = 0.0
        self._pending_terminal_scroll_bottom_hwnd: Optional[int] = None
        self._last_media_keepalive_at = 0.0
        self._last_media_keepalive_log_at = 0.0
        self._last_video_frame_sent_at = 0.0
        self._video_frame_empty_outputs = 0
        self._h265_retry_after = 0.0
        self._force_h264_until = 0.0
        self._video_congested_until = 0.0
        self._video_congestion_level = 0
        self._video_fallback_until = 0.0
        self._last_video_ack_seq = 0
        self._last_video_ack_at = 0.0
        self._last_video_ack_delay_ms = 0
        self._video_delay_backpressured = False
        self._video_delay_last_sample_at = 0.0
        self._video_delay_engaged_at = 0.0
        self._video_backpressure_last_send_at = 0.0
        self._last_video_congestion_log_at = 0.0
        self._last_video_restart_request_at = 0.0
        self._h264_last_status_log_at = 0.0
        self._last_video_progress_stage = ''
        self._last_video_progress_at = 0.0
        self._last_mouse_wheel_method = ''
        self._pending_scroll_frame_diag: Optional[dict] = None
        self._pending_scroll_frame_diags = deque()
        self._last_frame_signature: Optional[np.ndarray] = None
        self._last_stream_frame_size: tuple[int, int] = (0, 0)
        self._last_cursor_visible: Optional[bool] = None
        self._last_cursor_handle: Optional[int] = None
        self._last_cursor_signature: Optional[str] = None
        self._last_cursor_payload: Optional[dict] = None
        self._last_cursor_image_built_at = 0.0
        self._virtual_cursor_client_pos: Optional[tuple[int, int]] = None
        self._force_next_frame = threading.Event()
        self._file_clipboard_paths: list[str] = []
        self._file_clipboard_mode: Optional[str] = None
        self._instance_mutex = None
        self._instance_socket: Optional[socket.socket] = None
        self._instance_listener_thread: Optional[threading.Thread] = None
        self._instance_listener_stop = threading.Event()
        self._instance_watchdog_thread: Optional[threading.Thread] = None
        self._instance_watchdog_stop = threading.Event()
        self._video_stream_count = 2
        self._video_send_inflight = 0
        self._video_send_inflight_lock = threading.Lock()
        self._video_send_threads: list[threading.Thread] = []
        self._video_send_stop = threading.Event()
        self._video_send_channel_queues: list["queue.Queue[tuple]"] = []
        self._duplicate_instance_alert_active = False
        self._trusted_clients = self._load_trusted_clients()
        self._current_client_hint_id: Optional[str] = None
        self._recent_pair_client_id: Optional[str] = None
        self._recent_pair_client_name: Optional[str] = None
        self._recent_pair_approved_at = 0.0
        self._ui_room_id = ''
        self._version_info = self._load_version_info()
        self._update_check_started = False
        self._update_install_started = False
        self._desktop_update_service = DesktopUpdateService(
            http_base_url_getter=self._http_base_url,
            version_info_getter=lambda: self._version_info,
            status_callback=self._set_ui_status,
            stop_event=self._stop_requested,
            check_interval_seconds=WINDOWS_UPDATE_CHECK_INTERVAL_SECONDS,
            retry_interval_seconds=WINDOWS_UPDATE_RETRY_INTERVAL_SECONDS,
        )
        self._desktop_theme = self._state_store.load_desktop_theme()
        self._desktop_ui = DesktopAgentUI(
            agent=self,
            device_id_getter=lambda: self.device_id,
            room_id_getter=lambda: self._ui_room_id or self.signaling.room_id or '',
            status_snapshot_getter=self._ui_snapshot_text,
            trusted_snapshot_getter=self._trusted_clients_snapshot_text,
            pair_request_approver=self._approve_pair_request,
            trusted_client_rememberer=self._on_pair_approved_remember_client,
            status_update_callback=self._set_ui_status,
            theme_getter=lambda: self._desktop_theme,
            theme_setter=self._set_desktop_theme,
            startup_getter=self._is_startup_enabled,
            startup_setter=self._set_startup_enabled,
            app_icon_path=_resolve_runtime_file_path('app.ico'),
            signaling_endpoints_getter=self.get_signaling_endpoints,
            signaling_endpoints_setter=self.update_signaling_endpoints,
            signaling_route_getter=lambda: (
                self._current_signaling_route,
                self.server,
                int(self.port or 0),
            ),
            update_check_callback=self.check_windows_update_now,
        )

    def _load_version_info(self) -> dict:
        version_path = _resolve_runtime_file_path(DESKTOP_VERSION_FILE)
        return load_version_info(version_path)

    def _http_base_url(self) -> str:
        host = self.server
        if ':' in host and not host.startswith('['):
            host = f'[{host}]'
        return f'http://{host}:{self.port}'

    def _compare_versions(self, left: str, right: str) -> int:
        return compare_versions(left, right)

    def _fetch_windows_release(self) -> Optional[dict]:
        return self._desktop_update_service.fetch_release()

    def _download_windows_release(self, release: dict) -> tuple[str, str]:
        return self._desktop_update_service.download_release(release)

    def _write_windows_updater_script(self, archive_path: str) -> str:
        return self._desktop_update_service.write_updater_script(archive_path)

    def _begin_windows_update(self, release: dict):
        self._desktop_update_service.begin_update(release)

    def _handle_windows_update_prompt_result(self, approved: bool, force_update: bool, remote_version: str, release: dict):
        if not approved:
            if not force_update:
                self._state_store.save_ignored_windows_update_version(remote_version)
            return
        self._state_store.save_ignored_windows_update_version('')
        threading.Thread(
            target=self._begin_windows_update,
            args=(release,),
            daemon=True,
            name='windows-update-install',
        ).start()

    def _prompt_windows_update(self, release: dict):
        self._desktop_update_service.maybe_install_release(release)

    def _check_and_install_windows_update_once(self, notify_no_update: bool = False) -> bool:
        return self._desktop_update_service.check_once(notify_no_update)

    def _windows_update_loop(self):
        self._desktop_update_service.run_loop()

    def check_windows_update_now(self):
        self._desktop_update_service.check_now()

    def _start_windows_update_check(self):
        self._desktop_update_service.start_background_check()

    def set_preferred_endpoints(self, endpoints) -> list[dict]:
        """Replace the preferred endpoint list. Accepts either:
          - list of (host, port) tuples (legacy), or
          - list of endpoint dicts {id, name, url, priority, enabled, ...}.

        Returns the normalized list actually stored, ordered by enabled-ness
        and priority.
        """
        normalized: list[dict] = []
        seen_keys: set[tuple[str, int]] = set()
        for item in endpoints or []:
            entry = _normalize_signaling_endpoint(item)
            if entry is None:
                continue
            key = (entry['host'], entry['port'])
            if key in seen_keys:
                continue
            seen_keys.add(key)
            normalized.append(entry)
        # Stable sort by priority (asc); enabled entries always come first.
        normalized.sort(key=lambda e: (0 if e.get('enabled', True) else 1, int(e.get('priority') or 0)))
        previous = self._preferred_endpoints
        self._preferred_endpoints = normalized
        if [(e['host'], e['port'], e.get('enabled', True)) for e in previous] != \
           [(e['host'], e['port'], e.get('enabled', True)) for e in normalized]:
            # Routing-relevant change: invalidate health cache so the next
            # resolution re-probes immediately.
            _invalidate_endpoint_health_cache()
            self._endpoints_changed_event.set()
        return list(normalized)

    def update_signaling_endpoints(self, endpoints) -> list[dict]:
        """Public API used by the desktop UI to commit a new endpoint list.

        Persists to agent state and triggers an immediate reconnect against
        the new selection.
        """
        normalized = self.set_preferred_endpoints(endpoints)
        try:
            self._state_store.save_signaling_endpoints(normalized)
        except Exception:
            logger.exception('Failed to persist signaling endpoints')
        return normalized

    def get_signaling_endpoints(self) -> list[dict]:
        """Return a defensive copy of the current endpoint list."""
        return [dict(entry) for entry in self._preferred_endpoints]

    def _enabled_endpoints(self) -> list[dict]:
        """Return only the enabled endpoints; falls back to all if none."""
        active = [entry for entry in self._preferred_endpoints if entry.get('enabled', True)]
        return active if active else list(self._preferred_endpoints)

    def _resolve_signaling_endpoint(self) -> tuple[str, int, str]:
        """Pick the best reachable signaling endpoint, LAN-first.

        Strategy:
          1. Expand the configured candidates by resolving DNS to IPv4. A host
             whose A record sits in a private range counts as a LAN candidate
             even if its literal hostname is a public domain.
          2. Group candidates into LAN (private) and WAN (public). LAN group is
             always tried first, in user-priority order.
          3. A candidate is considered reachable only when both TCP connect and
             GET /api/health succeed (status == "ok"). This avoids picking a
             stray service that happens to listen on the same port.
          4. If nothing passes the strict check, fall back to plain TCP reachability,
             then finally to the first configured entry as a last resort.
        """
        configured = self._enabled_endpoints()
        if not configured and self.server:
            seed = _normalize_signaling_endpoint({
                'host': self.server,
                'port': self.port,
                'name': 'seed',
            })
            if seed is not None:
                configured = [seed]

        lan_group: list[tuple[str, int]] = []
        wan_group: list[tuple[str, int]] = []
        seen: set[tuple[str, int]] = set()

        def _push(host_value: str, port_value: int) -> None:
            host_norm = str(host_value or '').strip()
            if not host_norm or port_value <= 0:
                return
            key = (host_norm, port_value)
            if key in seen:
                return
            seen.add(key)
            if _is_private_host(host_norm):
                lan_group.append(key)
            else:
                wan_group.append(key)

        for entry in configured:
            host_value = entry['host']
            port_value = int(entry['port'])
            _push(host_value, port_value)
            # Also probe DNS-resolved IPv4 addresses; some setups (split-horizon
            # DNS, hosts file overrides) point a public hostname at a LAN IP.
            for resolved in _resolve_host_ipv4_addresses(host_value):
                if resolved == host_value:
                    continue
                _push(resolved, port_value)

        ordered = lan_group + wan_group
        if not ordered:
            if not configured:
                # Truly nothing to try yet (UI hasn't been used). Caller will
                # see the empty server and surface a status to the user.
                return '', 0, 'unconfigured'
            host = configured[0]['host']
            port = int(configured[0]['port'])
            return host, port, 'lan' if _is_private_host(host) else 'wan'

        # Strict pass: TCP + /api/health
        for host, port in ordered:
            if _verify_signaling_endpoint(host, port):
                return host, port, 'lan' if _is_private_host(host) else 'wan'

        # Lenient pass: TCP only (in case /api/health is temporarily unhealthy
        # but the signaling WS still works).
        for host, port in ordered:
            if _can_reach_endpoint(host, port):
                return host, port, 'lan' if _is_private_host(host) else 'wan'

        host, port = ordered[0]
        return host, port, 'lan' if _is_private_host(host) else 'wan'

    _ROUTE_REEVAL_INTERVAL_SECONDS = 30.0
    _ROUTE_SWITCH_MIN_INTERVAL_SECONDS = 60.0
    # _show_and_activate_window throttle: skip the heavy activation sequence
    # when the same hwnd was activated this recently and is still foreground.
    _ACTIVATE_THROTTLE_SECONDS = 0.5

    def _maybe_switch_to_lan_endpoint(self) -> bool:
        """Re-evaluate routing while connected; force a switch when WAN was
        chosen but a LAN signaling server is now reachable.

        Returns True if a switch was triggered (caller should break the inner
        loop so the outer reconnect logic picks the new endpoint up).
        """
        if self._current_signaling_route == 'lan':
            return False
        if not self.signaling.connected:
            return False
        now = time.time()
        if (now - self._last_route_reevaluation_at) < self._ROUTE_REEVAL_INTERVAL_SECONDS:
            return False
        self._last_route_reevaluation_at = now
        if (now - self._last_signaling_route_switch_at) < self._ROUTE_SWITCH_MIN_INTERVAL_SECONDS:
            return False

        # Find the best LAN candidate (after DNS expansion) that passes
        # strict /api/health verification right now.
        lan_candidate: Optional[tuple[str, int]] = None
        seen: set[tuple[str, int]] = set()
        for entry in self._enabled_endpoints():
            host_value = entry['host']
            port_value = int(entry['port'])
            for candidate_host in [host_value] + _resolve_host_ipv4_addresses(host_value):
                key = (candidate_host, port_value)
                if key in seen:
                    continue
                seen.add(key)
                if not _is_private_host(candidate_host):
                    continue
                # Force fresh check; do not trust stale cache for a switch
                # decision.
                _invalidate_endpoint_health_cache(candidate_host, port_value)
                if _verify_signaling_endpoint(candidate_host, port_value):
                    lan_candidate = key
                    break
            if lan_candidate:
                break

        if not lan_candidate:
            return False
        if lan_candidate == (self.server, self.port):
            return False

        logger.info(
            'LAN signaling endpoint became reachable; switching: %s:%s -> %s:%s',
            self.server,
            self.port,
            lan_candidate[0],
            lan_candidate[1],
        )
        self._last_signaling_route_switch_at = now
        # Disconnect to let the outer loop reconnect against the new endpoint.
        try:
            self.signaling.disconnect()
        except Exception:
            logger.debug('Failed to cleanly disconnect signaling during route switch', exc_info=True)
        return True

    def _state_file_path(self) -> str:
        state_dir = _persistent_state_dir()
        os.makedirs(state_dir, exist_ok=True)
        state_path = os.path.join(state_dir, 'agent_state.json')

        legacy_candidates: list[str] = []
        runtime_state = os.path.join(_runtime_base_dir(), 'agent_state.json')
        legacy_candidates.append(runtime_state)

        source_state = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            'agent_state.json',
        )
        legacy_candidates.append(source_state)

        if os.path.exists(state_path):
            state_data = _load_json_file(state_path)
            state_clients = state_data.get('trusted_clients')
            current_has_clients = isinstance(state_clients, list) and bool(state_clients)
            if current_has_clients:
                return state_path

            best_candidate_path: Optional[str] = None
            best_candidate_data: dict = {}
            best_candidate_count = 0
            seen_existing: set[str] = {os.path.abspath(state_path)}
            for candidate in legacy_candidates:
                normalized = os.path.abspath(candidate)
                if normalized in seen_existing or not os.path.exists(normalized):
                    continue
                seen_existing.add(normalized)
                candidate_data = _load_json_file(normalized)
                candidate_clients = candidate_data.get('trusted_clients')
                candidate_count = len(candidate_clients) if isinstance(candidate_clients, list) else 0
                if candidate_count > best_candidate_count and str(candidate_data.get('device_id') or '').strip():
                    best_candidate_count = candidate_count
                    best_candidate_path = normalized
                    best_candidate_data = candidate_data

            if best_candidate_path and best_candidate_count > 0:
                try:
                    with open(state_path, 'w', encoding='utf-8') as file:
                        json.dump(best_candidate_data, file, ensure_ascii=False, indent=2)
                    logger.info(
                        'Recovered persistent agent state from %s -> %s (trusted_clients=%s)',
                        best_candidate_path,
                        state_path,
                        best_candidate_count,
                    )
                except Exception as exc:
                    logger.warning('Failed to recover persistent state from %s: %s', best_candidate_path, exc)
            return state_path

        seen: set[str] = set()
        for candidate in legacy_candidates:
            normalized = os.path.abspath(candidate)
            if normalized in seen:
                continue
            seen.add(normalized)
            if not os.path.exists(normalized):
                continue
            try:
                shutil.copy2(normalized, state_path)
                logger.info('Migrated agent state: %s -> %s', normalized, state_path)
                break
            except Exception as exc:
                logger.warning('Failed to migrate state file from %s: %s', normalized, exc)
        return state_path

    def _read_state_file(self) -> dict:
        return self._state_store.read()

    def _write_state_file(self, data: dict):
        self._state_store.write(data)

    def _load_or_create_device_id(self) -> str:
        return self._state_store.load_or_create_device_id()

    def _load_trusted_clients(self) -> list[dict]:
        return self._state_store.load_trusted_clients()

    def _save_trusted_clients(self):
        self._state_store.save_trusted_clients(self.device_id, self._trusted_clients)
        self._sync_trusted_clients_to_server()

    def _remember_trusted_client(self, client_id: str, client_name: str):
        changed = self._state_store.remember_trusted_client(
            self._trusted_clients,
            client_id,
            client_name,
        )
        if changed:
            self._save_trusted_clients()
            self._refresh_ui_snapshot()

    def _mark_trusted_client_connected(self, client_id: Optional[str]):
        changed = self._state_store.mark_trusted_client_connected(
            self._trusted_clients,
            client_id,
        )
        if changed:
            self._save_trusted_clients()
            self._refresh_ui_snapshot()

    def _is_trusted_client(self, client_id: str) -> bool:
        normalized = str(client_id or '').strip()
        if not normalized:
            return False
        return any(
            str(item.get('client_id') or '').strip() == normalized
            for item in self._trusted_clients
        )

    def _reset_stream_state(self):
        self._last_sent_at = 0.0
        self._image_frame_in_flight = False
        self._last_image_frame_ack_at = 0.0
        self._last_frame_signature = None
        self._last_stream_frame_size = (0, 0)
        self._last_cursor_visible = None
        self._last_cursor_signature = None
        self._last_cursor_payload = None
        self._last_cursor_handle = None
        self._last_cursor_image_built_at = 0.0
        self._virtual_cursor_client_pos = None
        self._stream_state = self.STREAM_STATE_STATIC
        self._stream_state_until = 0.0
        self._static_clear_frame_pending = False
        self._static_clear_frame_due_at = 0.0
        self._motion_boost_until = 0.0
        self._last_motion_score = 0.0
        self._last_change_percent = 0.0
        self._last_diff_intensity = 0.0
        self._force_next_frame.clear()
        self._h264_stream_started = False
        self._h264_client_active = False
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._h264_encoder.reset()

    def _defer_video_start_until_stable(self, reason: str, duration_seconds: float = 0.0) -> None:
        now = time.time()
        if duration_seconds > 0:
            self._video_start_wait_until = max(self._video_start_wait_until, now + max(0.1, duration_seconds))
            self._video_start_wait_reason = reason
        self._video_start_stable_size = (0, 0)
        self._video_start_stable_since = 0.0
        self._video_start_content_signature = None
        self._video_start_content_stable_since = 0.0
        self._h264_stream_started = False
        self._h264_client_active = False
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._h264_encoder.reset()
        self._h265_encoder.reset()
        self._send_video_stream_progress(
            stage='window_stabilizing',
            progress=25,
            codec='h264',
            stage_label='正在确认窗口尺寸',
            force=True,
        )
        if duration_seconds > 0:
            logger.info(
                'Video start deferred: reason=%s until_ms=%s',
                reason,
                int(self._video_start_wait_until * 1000),
            )

    def _video_start_wait_active(self, frame: np.ndarray, frame_size: tuple[int, int], now: float) -> bool:
        if self._video_start_wait_until <= 0.0 or self._h264_client_active:
            return False
        if now < self._video_start_wait_until:
            self._send_video_stream_progress(
                stage='window_stabilizing',
                progress=25,
                codec='h264',
                stage_label='正在确认窗口尺寸',
            )
            return True
        self._video_start_wait_until = 0.0
        self._video_start_wait_reason = ''
        self._h264_stream_started = False
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._h264_encoder.reset()
        self._force_next_frame.set()
        self._send_video_stream_progress(
            stage='window_stable',
            progress=35,
            codec='h264',
            stage_label='窗口就绪，正在启动编码器',
            force=True,
        )
        logger.info(
            'Video start ready: size=%sx%s',
            frame_size[0],
            frame_size[1],
        )
        pending_scroll_hwnd = self._pending_terminal_scroll_bottom_hwnd
        if pending_scroll_hwnd and pending_scroll_hwnd == self.target_hwnd:
            self._pending_terminal_scroll_bottom_hwnd = None
            self._scroll_terminal_to_bottom_after_resize(pending_scroll_hwnd)
        return False

    def _send_media_keepalive(self, now: Optional[float] = None, reason: str = 'idle') -> None:
        current = now or time.time()
        if current - self._last_media_keepalive_at < 1.0:
            return
        self._last_media_keepalive_at = current
        if current - self._last_media_keepalive_log_at >= 5.0:
            self._last_media_keepalive_log_at = current
            logger.info(
                'Media keepalive sent: reason=%s codec=%s active=%s profile=%s',
                reason,
                self._video_stream_started_codec or self._video_stream_codec,
                self._h264_client_active,
                self._stream_profile_id,
            )
        self._send_peer_media(
            {
                'type': 'video_stream_keepalive',
                'room_id': self.signaling.room_id,
                'codec': self._video_stream_started_codec or self._video_stream_codec,
                'reason': reason,
                'ts_ms': int(current * 1000),
                'active': self._h264_client_active,
                'profile': self._stream_profile_id,
            }
        )

    def _enqueue_pair_prompt(self, payload: dict):
        self._desktop_ui.enqueue_pair_prompt(payload)

    def _approve_new_public_ip(self, peer_ip: str, payload: dict) -> bool:
        """Block until the user approves a new public IP. Runs on the
        LAN-direct worker thread; the UI thread shows a yes/no dialog
        and we wait synchronously for the result.

        Returns False if the user does not answer within 120s, so the
        connection is dropped instead of hanging the LAN-direct server.
        """
        ui = getattr(self, '_desktop_ui', None)
        if ui is None:
            return False
        decision: dict = {'approved': False, 'answered': False}
        event = threading.Event()

        def _ask() -> None:
            try:
                ok = messagebox.askyesno(
                    '新的公网连接',
                    f'检测到来自新 IP {peer_ip} 的连接请求。\n\n是否允许此次连接？',
                    parent=ui._root if ui._root else None,
                )
            except Exception:
                ok = False
            decision['approved'] = bool(ok)
            decision['answered'] = True
            event.set()

        try:
            if ui._root is not None:
                ui._root.after(0, _ask)
            else:
                _ask()
        except Exception:
            _ask()
        event.wait(timeout=120)
        if not decision['answered']:
            logger.warning('public direct new-IP approval timed out: ip=%s', peer_ip)
            return False
        if decision['approved']:
            try:
                self._state_store.record_known_public_ip(peer_ip)
                self._public_direct_settings = self._state_store.load_public_direct_settings()
            except Exception as exc:
                logger.warning('record_known_public_ip failed: %s', exc)
        return bool(decision['approved'])

    def get_public_direct_settings(self) -> dict:
        settings = dict(self._public_direct_settings)
        settings['effective_listen_port'] = int(self._public_direct_settings.get('listen_port') or 0)
        settings['lan_direct_port'] = int(self._lan_direct_port or 0)
        return settings

    def update_public_direct_settings(self, settings: dict) -> dict:
        normalized = self._state_store.save_public_direct_settings(settings or {})
        self._public_direct_settings = normalized
        return normalized

    def _approve_pair_request(self, request_id: str, approved: bool):
        self.signaling._send(
            {
                'type': 'pair_response',
                'request_id': request_id,
                'approved': approved,
            }
        )

    def _sync_trusted_clients_to_server(self):
        if not self.signaling.connected:
            return
        self.signaling._send(
            {
                'type': 'agent_trusted_clients_sync',
                'device_id': self.device_id,
                'trusted_clients': list(self._trusted_clients),
            }
        )

    def _send_peer_control(self, payload: dict) -> bool:
        if self._lan_direct_server.has_client and self._lan_direct_server.send_control(payload):
            return True
        return self.signaling._send(payload)

    def _send_peer_media(self, payload: dict) -> bool:
        if self._lan_direct_server.has_client and self._lan_direct_server.send_media(payload):
            return True
        if not self.signaling.connected:
            return False
        return self.signaling._send(payload)

    def _send_peer_binary_media(self, payload: bytes) -> bool:
        if self._lan_direct_server.has_client:
            if self._lan_direct_server.send_binary_media(payload):
                return True
        if not self.signaling.connected:
            return False
        return self.signaling.send_binary_media(payload)

    def _peer_connected(self) -> bool:
        return self.signaling.connected or self._lan_direct_server.has_client

    def _on_pair_approved_remember_client(self, client_id: str, client_name: str):
        self._remember_trusted_client(client_id, client_name)
        self._recent_pair_client_id = client_id or None
        self._recent_pair_client_name = str(client_name)
        self._recent_pair_approved_at = time.time()

    def _create_ui(self):
        self._desktop_ui.create()

    def _set_ui_status(self, message: str):
        self._desktop_ui.set_status(message)

    def _ui_snapshot_text(self) -> str:
        return DesktopAgentPresenter.build_status_snapshot(
            server=self.server,
            port=self.port,
            signaling_room_id=self.signaling.room_id,
            device_id=self.device_id,
            version=str(self._version_info.get('version') or '0.0.0'),
            build=int(self._version_info.get('build') or 0),
            channel=str(self._version_info.get('channel') or 'stable'),
            signaling_connected=self.signaling.connected,
            client_connected=self.client_connected,
            target_mode=self.target_mode,
            target_window_title=self.target_window_title,
            target_hwnd=self.target_hwnd,
            stream_profile_id=self._stream_profile_id,
            capture_path=self.capture.last_capture_path or '-',
            capture_error=self.capture.last_capture_error or '-',
            capture_size=self.capture.last_frame_size,
            stream_size=self._last_stream_frame_size,
            capture_frames_sent=self._capture_frames_sent,
            capture_frames_skipped=self._capture_frames_skipped,
            capture_empty_frames=self._capture_empty_frames,
            cursor_updates_sent=self._cursor_updates_sent,
        )

    def _format_timestamp(self, ts: int) -> str:
        return format_timestamp(ts)

    def _trusted_clients_snapshot_text(self) -> str:
        return DesktopAgentPresenter.build_trusted_clients_snapshot(
            trusted_clients=self._trusted_clients,
            client_connected=self.client_connected,
            current_client_hint_id=self._current_client_hint_id,
        )

    def _refresh_ui_snapshot(self):
        self._desktop_ui.refresh_snapshot()

    def _write_scroll_diagnostic(self, event: str, payload: Optional[dict] = None):
        if not self._should_keep_recovery_diagnostic(event):
            return
        try:
            item = dict(payload or {})
            item['event'] = event
            item['ts_ms'] = int(time.time() * 1000)
            item['room_id'] = self.signaling.room_id
            item['target_mode'] = self.target_mode
            item['target_hwnd'] = self.target_hwnd
            item['target_title'] = self.target_window_title
            item['video_codec'] = self._video_stream_started_codec or self._video_stream_codec
            item['h264_client_active'] = self._h264_client_active
            item['stream_profile'] = self._stream_profile_id
            os.makedirs(os.path.dirname(_SCROLL_DIAGNOSTIC_FILE), exist_ok=True)
            line = json.dumps(item, ensure_ascii=False, separators=(',', ':'))
            with _SCROLL_DIAGNOSTIC_LOCK:
                with open(_SCROLL_DIAGNOSTIC_FILE, 'a', encoding='utf-8') as file:
                    file.write(line + '\n')
        except Exception as exc:
            logger.debug('scroll diagnostic write failed: %s', exc)

    def _should_keep_recovery_diagnostic(self, event: str) -> bool:
        name = str(event or '')
        if not name:
            return False
        if name.startswith('lifecycle_'):
            return True
        if name.startswith('full_reconnect'):
            return True
        if name.startswith('foreground_'):
            return True
        if name.startswith('connection_diag'):
            return True
        if name.startswith('media_reconnect'):
            return True
        if name == 'video_stream_status_received':
            return True
        if name == 'set_window_received':
            return True
        # First image_frame after a resume tells us whether the phone is
        # actually receiving frames on the new socket; rate-limited to the
        # first occurrence per second by upstream throttling.
        if name == 'image_frame_received':
            return True
        if name == 'image_frame_displayed':
            return True
        if name.startswith('signaling_channel_'):
            return True
        # Watchdog heartbeat from the phone's Dart isolate. Lets us tell when
        # the UI isolate stops servicing Timer events at all.
        if name == 'isolate_heartbeat':
            return True
        if 'reconnect' in name or 'recovery' in name:
            return True
        if 'failed' in name or 'error' in name:
            return True
        return False

    def _queue_scroll_frame_diagnostic(self, diagnostic: dict):
        diagnostic = dict(diagnostic or {})
        diagnostic['queued_ts_ms'] = int(time.time() * 1000)
        diagnostic['observed_frames'] = 0
        diagnostic['first_changed'] = False
        diagnostic['last_observed_seq'] = 0
        self._pending_scroll_frame_diags.append(diagnostic)
        while len(self._pending_scroll_frame_diags) > _SCROLL_DIAGNOSTIC_MAX_PENDING_WHEELS:
            dropped = self._pending_scroll_frame_diags.popleft()
            self._write_scroll_diagnostic(
                'scroll_diag_dropped',
                {
                    'source': 'desktop',
                    'reason': 'queue_full',
                    'gesture_id': dropped.get('gesture_id'),
                    'wheel_id': dropped.get('wheel_id'),
                    'wheel_desktop_ts_ms': dropped.get('desktop_ts_ms'),
                    'observed_frames': dropped.get('observed_frames'),
                },
            )

    def _observe_scroll_frame_diagnostics(
        self,
        now: float,
        diff_value: float,
        width: int,
        height: int,
        send_image_fallback: bool,
    ):
        if not self._pending_scroll_frame_diags:
            return
        now_ms = int(now * 1000)
        remaining = deque()
        while self._pending_scroll_frame_diags:
            item = self._pending_scroll_frame_diags.popleft()
            wheel_ts_ms = int(item.get('desktop_ts_ms') or item.get('queued_ts_ms') or now_ms)
            if now_ms < wheel_ts_ms:
                remaining.append(item)
                continue
            item['observed_frames'] = int(item.get('observed_frames') or 0) + 1
            item['last_observed_seq'] = self._capture_frames_sent
            age_ms = now_ms - wheel_ts_ms
            common = {
                'source': 'desktop',
                'gesture_id': item.get('gesture_id'),
                'wheel_id': item.get('wheel_id'),
                'wheel_desktop_ts_ms': item.get('desktop_ts_ms'),
                'wheel_delta': item.get('delta'),
                'wheel_method': item.get('method'),
                'frame_ts_ms': now_ms,
                'capture_frame': self._capture_frames_sent,
                'video_seq': self._last_video_stream_seq,
                'image_seq': self._last_image_frame_seq,
                'diff': diff_value,
                'width': width,
                'height': height,
                'fallback': send_image_fallback,
                'observed_frames': item.get('observed_frames'),
                'age_ms': age_ms,
            }
            if item.get('observed_frames') == 1:
                self._write_scroll_diagnostic('frame_after_scroll', common)
            self._write_scroll_diagnostic('scroll_frame_observed', common)
            if not item.get('first_changed') and diff_value >= _SCROLL_DIAGNOSTIC_CHANGE_THRESHOLD:
                item['first_changed'] = True
                self._write_scroll_diagnostic('scroll_first_changed', common)
                continue
            if (
                item.get('observed_frames', 0) >= _SCROLL_DIAGNOSTIC_OBSERVE_FRAMES
                or age_ms >= _SCROLL_DIAGNOSTIC_OBSERVE_MS
            ):
                if not item.get('first_changed'):
                    self._write_scroll_diagnostic('scroll_no_change_timeout', common)
                continue
            remaining.append(item)
        self._pending_scroll_frame_diags = remaining

    def _is_window_available(self, hwnd: Optional[int], require_visible: bool = False) -> bool:
        if not hwnd:
            return False
        try:
            hwnd_value = int(hwnd)
            if not win32gui.IsWindow(hwnd_value):
                return False
            if require_visible and not win32gui.IsWindowVisible(hwnd_value):
                return False
            return True
        except Exception:
            return False

    def _invalidate_target_window(self, reason: str):
        hwnd = self.target_hwnd
        if not hwnd:
            return
        title = self.target_window_title or ''
        self.target_hwnd = None
        self.target_window_title = None
        self._original_window_rect = None
        self._original_client_size = None
        self.capture.last_capture_bounds = None
        self.capture.last_capture_error = reason
        self._reset_stream_state()
        logger.warning(
            'Cleared invalid target window: hwnd=%s title=%s reason=%s',
            hwnd,
            title,
            reason,
        )
        self._set_ui_status(f'目标窗口已失效，请重新选择窗口：{title or hwnd}')
        self._send_agent_update()
        self._refresh_ui_snapshot()

    def _require_target_window(self, context: str, require_visible: bool = False) -> Optional[int]:
        if self.target_mode != 'window':
            return None
        hwnd = self.target_hwnd
        if self._is_window_available(hwnd, require_visible=require_visible):
            return int(hwnd)
        if hwnd:
            self._invalidate_target_window(f'{context}: invalid window handle')
        return None

    def _set_ui_pairing_info(self, room_id: str, pair_code: str):
        self._ui_room_id = room_id
        self._desktop_ui.set_pairing_info(room_id, pair_code)

    def _refresh_qr_image(self):
        self._desktop_ui.refresh_qr_image()

    def _ui_tick(self):
        self._desktop_ui._tick()

    def _set_desktop_theme(self, theme: str):
        self._desktop_theme = theme
        self._state_store.save_desktop_theme(theme)

    def _startup_command(self) -> str:
        return startup_command(__file__)

    def _is_startup_enabled(self) -> bool:
        return is_startup_enabled(self._startup_command())

    def _set_startup_enabled(self, enabled: bool) -> bool:
        return set_startup_enabled(enabled, self._startup_command())

    def _focus_existing_desktop_window(self):
        target_hwnd = None

        def enum_callback(hwnd, _):
            nonlocal target_hwnd
            if target_hwnd is not None:
                return
            try:
                if not win32gui.IsWindow(hwnd):
                    return
                title = win32gui.GetWindowText(hwnd)
                class_name = win32gui.GetClassName(hwnd)
                if title == DESKTOP_UI_WINDOW_TITLE and class_name == 'TkTopLevel':
                    target_hwnd = hwnd
            except Exception:
                return

        try:
            win32gui.EnumWindows(enum_callback, None)
        except Exception as exc:
            logger.debug('enumerate desktop ui window failed: %s', exc)
            return

        if target_hwnd:
            try:
                self._show_and_activate_window(target_hwnd)
            except Exception as exc:
                logger.debug('focus existing desktop ui failed: hwnd=%s error=%s', target_hwnd, exc)

    def _acquire_single_instance_lock(self) -> bool:
        if not self._acquire_single_instance_socket():
            return False
        try:
            mutex = win32event.CreateMutex(None, False, SINGLE_INSTANCE_MUTEX_NAME)
            if win32api.GetLastError() == 183:
                self._notify_existing_instance_focus()
                self._release_single_instance_lock()
                self._show_existing_instance_message()
                return False
            self._instance_mutex = mutex
            return True
        except Exception as exc:
            logger.error('single instance lock failed: %s', exc, exc_info=True)
            self._release_single_instance_lock()
            return False

    def _acquire_single_instance_socket(self) -> bool:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            sock.bind((SINGLE_INSTANCE_LOCK_HOST, SINGLE_INSTANCE_LOCK_PORT))
            sock.listen(1)
            self._instance_socket = sock
            self._start_single_instance_listener()
            return True
        except OSError as exc:
            logger.info('single instance socket is already held: %s', exc)
            self._notify_existing_instance_focus()
            self._show_existing_instance_message()
            return False

    def _show_existing_instance_message(self):
        self._focus_existing_desktop_window()
        try:
            message = 'PocketWindow 电脑端已经在运行。\n我已为你切换到正在运行的窗口。'
            try:
                ctypes.windll.user32.MessageBoxTimeoutW(
                    0,
                    message,
                    'PocketWindow',
                    0x00000040,
                    0,
                    1200,
                )
            except AttributeError:
                ctypes.windll.user32.MessageBoxW(
                    0,
                    message,
                    'PocketWindow',
                    0x00000040,
                )
        except Exception:
            pass

    def _show_duplicate_instance_warning(self, count: int):
        try:
            message = (
                '检测到多个 PocketWindow 电脑端实例同时运行。\n'
                f'当前检测到 {count} 个实例。\n'
                '请关闭多余实例，否则可能出现延迟、黑屏或控制异常。'
            )
            try:
                ctypes.windll.user32.MessageBoxTimeoutW(
                    0,
                    message,
                    'PocketWindow 重复实例警告',
                    0x00000030,
                    0,
                    1800,
                )
            except AttributeError:
                ctypes.windll.user32.MessageBoxW(
                    0,
                    message,
                    'PocketWindow 重复实例警告',
                    0x00000030,
                )
        except Exception:
            pass

    def _count_agent_processes(self) -> int:
        try:
            process_info: dict[int, dict] = {}
            for pid in win32process.EnumProcesses():
                if not pid:
                    continue
                try:
                    handle = win32api.OpenProcess(
                        win32con.PROCESS_QUERY_INFORMATION | win32con.PROCESS_VM_READ,
                        False,
                        pid,
                    )
                except Exception:
                    continue
                try:
                    exe_name = win32process.GetModuleFileNameEx(handle, 0)
                    lower_exe = str(exe_name or '').lower()
                    if not lower_exe.endswith('python.exe') and not lower_exe.endswith('pocketwindowagent.exe'):
                        continue
                    cmdline = ''
                    parent_pid = 0
                    try:
                        import win32com.client  # type: ignore
                        wmi = win32com.client.GetObject('winmgmts:')
                        processes = wmi.ExecQuery(
                            f'SELECT CommandLine, ParentProcessId FROM Win32_Process WHERE ProcessId = {pid}'
                        )
                        for proc in processes:
                            cmdline = str(getattr(proc, 'CommandLine', '') or '')
                            parent_pid = int(getattr(proc, 'ParentProcessId', 0) or 0)
                            break
                    except Exception:
                        cmdline = ''

                    normalized_cmd = cmdline.lower()
                    if lower_exe.endswith('pocketwindowagent.exe'):
                        process_info[pid] = {
                            'pid': pid,
                            'parent_pid': parent_pid,
                            'kind': 'exe',
                        }
                    elif 'control-agent\\src\\agent_simple.py' in normalized_cmd or 'control-agent/src/agent_simple.py' in normalized_cmd:
                        process_info[pid] = {
                            'pid': pid,
                            'parent_pid': parent_pid,
                            'kind': 'py',
                        }
                finally:
                    try:
                        win32api.CloseHandle(handle)
                    except Exception:
                        pass

            root_pids: set[int] = set()
            for pid, info in process_info.items():
                parent_pid = int(info.get('parent_pid') or 0)
                if parent_pid in process_info:
                    continue
                root_pids.add(pid)
            return max(1, len(root_pids)) if process_info else 1
        except Exception as exc:
            logger.debug('count agent processes failed: %s', exc)
            return 1

    def _start_duplicate_instance_watchdog(self):
        if self._instance_watchdog_thread and self._instance_watchdog_thread.is_alive():
            return

        self._instance_watchdog_stop.clear()

        def loop():
            while not self._instance_watchdog_stop.wait(30.0):
                count = self._count_agent_processes()
                if count > 1:
                    logger.warning('Duplicate desktop agent instances detected: count=%s', count)
                    if not self._duplicate_instance_alert_active:
                        self._duplicate_instance_alert_active = True
                        self._show_duplicate_instance_warning(count)
                else:
                    self._duplicate_instance_alert_active = False

        self._instance_watchdog_thread = threading.Thread(
            target=loop,
            daemon=True,
            name='agent-instance-watchdog',
        )
        self._instance_watchdog_thread.start()

    def _stop_duplicate_instance_watchdog(self):
        self._instance_watchdog_stop.set()
        self._instance_watchdog_thread = None
        self._duplicate_instance_alert_active = False

    def _notify_existing_instance_focus(self):
        try:
            with socket.create_connection(
                (SINGLE_INSTANCE_LOCK_HOST, SINGLE_INSTANCE_LOCK_PORT),
                timeout=0.6,
            ) as client:
                client.sendall(SINGLE_INSTANCE_FOCUS_MESSAGE)
        except OSError as exc:
            logger.debug('notify existing instance focus failed: %s', exc)

    def _start_single_instance_listener(self):
        if self._instance_socket is None:
            return
        if self._instance_listener_thread and self._instance_listener_thread.is_alive():
            return

        self._instance_listener_stop.clear()

        def listen():
            sock = self._instance_socket
            if sock is None:
                return
            try:
                sock.settimeout(0.5)
            except OSError:
                return
            while not self._instance_listener_stop.is_set():
                try:
                    conn, _addr = sock.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    payload = conn.recv(64)
                    if payload.startswith(SINGLE_INSTANCE_FOCUS_MESSAGE):
                        logger.info('single instance focus request received')
                        self._focus_existing_desktop_window()
                except OSError as exc:
                    logger.debug('single instance listener recv failed: %s', exc)
                finally:
                    try:
                        conn.close()
                    except OSError:
                        pass

        self._instance_listener_thread = threading.Thread(
            target=listen,
            daemon=True,
            name='agent-instance-lock',
        )
        self._instance_listener_thread.start()

    def _release_single_instance_socket(self):
        self._instance_listener_stop.set()
        sock = self._instance_socket
        self._instance_socket = None
        if sock:
            try:
                sock.close()
            except Exception:
                pass
        self._instance_listener_thread = None

    def _release_single_instance_mutex(self):
        mutex = self._instance_mutex
        self._instance_mutex = None
        if mutex:
            try:
                win32api.CloseHandle(int(mutex))
            except Exception as exc:
                logger.debug('release single instance mutex failed: %s', exc)

    def _release_single_instance_lock(self):
        self._stop_duplicate_instance_watchdog()
        self._release_single_instance_socket()
        self._release_single_instance_mutex()

    def _current_stream_profile(self) -> dict:
        profile = dict(
            self.STREAM_PROFILES.get(self._stream_profile_id, self.STREAM_PROFILES['hybrid'])
        )
        profile['quality_scale'] = self._stream_quality_scale
        profile['resolution_scale'] = self._stream_resolution_scale
        profile['dynamic_fps_limit'] = self._dynamic_fps_limit
        profile['static_fps_limit'] = self._static_fps_limit
        return profile

    def _scroll_video_tuning(self) -> dict:
        return {
            'scale': self._scroll_video_scale,
            'bitrate_kbps': self._scroll_video_bitrate_kbps,
            'fps': self._scroll_video_fps,
            'crf': self._scroll_video_crf,
            'vbv_multiplier': self._scroll_video_vbv_multiplier,
            'pixel_format': self._scroll_video_pixel_format,
            'preset': self._scroll_video_preset,
        }

    def _activate_motion_boost(self, duration_seconds: float = 0.9):
        now = time.time()
        self._motion_boost_until = max(
            self._motion_boost_until,
            now + max(0.1, duration_seconds),
        )
        self._force_next_frame.set()

    def _is_motion_boost_active(self, now: Optional[float] = None) -> bool:
        current = now if now is not None else time.time()
        return current < self._motion_boost_until

    def _capture_class_name(self) -> str:
        if self.target_mode != 'window' or not self.target_hwnd:
            return ''
        try:
            return win32gui.GetClassName(self.target_hwnd)
        except Exception:
            return ''

    def _prepare_frame_for_profile(
        self,
        frame: np.ndarray,
        scale: float,
        *,
        preserve_output_size: bool = False,
    ) -> np.ndarray:
        if scale >= 0.999:
            return frame
        height, width = frame.shape[:2]
        resized_width = max(2, int(round(width * scale)))
        resized_height = max(2, int(round(height * scale)))
        reduced = cv2.resize(frame, (resized_width, resized_height), interpolation=cv2.INTER_AREA)
        if not preserve_output_size:
            return reduced
        return cv2.resize(reduced, (width, height), interpolation=cv2.INTER_LINEAR)

    def _fit_frame_to_target_aspect(self, frame: np.ndarray) -> np.ndarray:
        if self.target_mode != 'window' or not self._fit_target_hwnd:
            return frame
        if self.target_hwnd != self._fit_target_hwnd:
            return frame
        if self.capture.last_frame_space == 'window':
            return frame
        target_aspect = float(self._fit_target_aspect or 0.0)
        if target_aspect <= 0.05:
            return frame
        height, width = frame.shape[:2]
        if width <= 4 or height <= 4:
            return frame
        current_aspect = width / height
        if abs(current_aspect - target_aspect) <= 0.01:
            return frame

        crop_x = 0
        crop_y = 0
        crop_width = width
        crop_height = height
        if current_aspect > target_aspect:
            crop_width = max(2, int(round(height * target_aspect)))
            crop_width -= crop_width % 2
            crop_x = max(0, (width - crop_width) // 2)
        else:
            crop_height = max(2, int(round(width / target_aspect)))
            crop_height -= crop_height % 2
            crop_y = max(0, (height - crop_height) // 2)

        if crop_width <= 0 or crop_height <= 0 or crop_width == width and crop_height == height:
            return frame

        now = time.time()
        if now - self._last_fit_aspect_crop_log_at >= 3.0:
            self._last_fit_aspect_crop_log_at = now
            logger.info(
                'Fit aspect crop applied: frame=%sx%s target_aspect=%.4f crop=%sx%s offset=%s,%s hwnd=%s',
                width,
                height,
                target_aspect,
                crop_width,
                crop_height,
                crop_x,
                crop_y,
                self.target_hwnd,
            )
        return frame[crop_y:crop_y + crop_height, crop_x:crop_x + crop_width]

    def _frame_signature(self, frame: np.ndarray) -> np.ndarray:
        gray = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY)
        thumbnail = cv2.resize(gray, (96, 54), interpolation=cv2.INTER_AREA)
        return thumbnail

    def _measure_frame_diff(self, frame: np.ndarray) -> float:
        signature = self._frame_signature(frame)
        if self._last_frame_signature is None:
            self._last_frame_signature = signature
            self._last_change_percent = 100.0
            self._last_diff_intensity = 255.0
            self._last_motion_score = 100.0
            return self._last_motion_score

        diff = cv2.absdiff(signature, self._last_frame_signature)
        diff_intensity = float(np.mean(diff))
        changed_pixels = int(np.count_nonzero(diff > 10))
        change_percent = changed_pixels * 100.0 / max(1, diff.size)
        motion_score = min(
            100.0,
            (change_percent * 0.75) + (min(diff_intensity / 12.0, 1.0) * 25.0),
        )
        self._last_frame_signature = signature
        self._last_change_percent = change_percent
        self._last_diff_intensity = diff_intensity
        self._last_motion_score = motion_score
        return motion_score

    def _lerp(self, start: float, end: float, amount: float) -> float:
        return start + ((end - start) * max(0.0, min(1.0, amount)))

    def _motion_amount(self, motion_score: float) -> float:
        if motion_score <= 0.50:
            return 0.0
        if motion_score >= 30.0:
            return 1.0
        amount = (motion_score - 0.50) / 29.50
        return amount * amount * (3.0 - (2.0 * amount))

    # Old hybrid logic intentionally retired.
    # It mixed independent frame-rate, resolution, and encode-format rules,
    # which caused drifting quality and unstable real FPS under scroll.
    # def _should_send_frame(self, diff: float, profile: dict, now: float) -> bool:
    #     ...
    #
    # def _resolved_profile_params(self, profile: dict, diff_value: Optional[float] = None) -> dict:
    #     ...

    def _resolve_stream_state(self, profile: dict, diff_value: float, now: float) -> str:
        # 'lan' (unlimited LAN) and 'smooth_hd' (5G/public, user wants a fixed
        # 25fps with bandwidth-be-damned) both run permanently in high motion so
        # the framerate never steps down.
        if self._stream_profile_id in {'lan', 'smooth_hd'}:
            return self.STREAM_STATE_HIGH_MOTION
        if self._is_motion_boost_active(now):
            return self.STREAM_STATE_HIGH_MOTION
        if diff_value >= 12.0 or self._last_change_percent >= 8.0:
            return self.STREAM_STATE_HIGH_MOTION
        if self._stream_state == self.STREAM_STATE_HIGH_MOTION and now < self._stream_state_until:
            return self.STREAM_STATE_HIGH_MOTION
        if diff_value >= 1.00 or self._last_change_percent >= 0.50:
            return self.STREAM_STATE_LOW_MOTION
        if self._stream_state == self.STREAM_STATE_LOW_MOTION and now < self._stream_state_until:
            return self.STREAM_STATE_LOW_MOTION
        return self.STREAM_STATE_STATIC

    def _resolved_stream_state_params(
        self,
        profile: dict,
        state: str,
    ) -> dict:
        quality_scale = min(1.0, max(0.15, float(profile.get('quality_scale', 1.0))))
        resolution_scale = min(1.0, max(0.20, float(profile.get('resolution_scale', 1.0))))
        dynamic_fps_limit = max(1.0, float(profile.get('dynamic_fps_limit', 30.0)))
        if self._stream_profile_id == 'lan':
            return {
                'state': self.STREAM_STATE_HIGH_MOTION,
                'target_fps': 60.0,
                'scale': 1.0,
                'jpeg_quality': 88,
                'png_compression': 2,
                'encode_format': 'jpg',
                'min_send_interval': 1.0 / 60.0,
                'loop_sleep': 1.0 / 60.0,
                'should_send_on_static': True,
            }
        if self._stream_profile_id == 'smooth_hd':
            # User preference: smooth_hd (the 5G/public high-quality profile) runs
            # at a FIXED 25fps regardless of motion. Bandwidth is not a concern;
            # the user wants rock-steady framerate with no dynamic stepping that
            # caused the previous stutter/oscillation. Always high-motion params.
            return {
                'state': self.STREAM_STATE_HIGH_MOTION,
                'target_fps': 25.0,
                'scale': 0.75,
                'jpeg_quality': 82,
                'png_compression': 2,
                'encode_format': 'jpg',
                'min_send_interval': 1.0 / 25.0,
                'loop_sleep': 1.0 / 25.0,
                'should_send_on_static': True,
            }

        now = time.time()
        boosted = self._is_motion_boost_active(now)
        motion = max(0.0, min(100.0, self._last_motion_score))
        amount = self._motion_amount(motion)
        if boosted:
            amount = max(amount, 0.75)

        if boosted:
            target_fps = max(24.0, self._lerp(24.0, 30.0, amount))
        elif motion < 0.50:
            target_fps = 1.0
        elif motion < 1.5:
            target_fps = self._lerp(1.0, 5.0, (motion - 0.5) / 1.0)
        elif motion < 8.0:
            target_fps = self._lerp(5.0, 12.0, (motion - 1.5) / 6.5)
        else:
            target_fps = self._lerp(20.0, 30.0, min(1.0, (motion - 8.0) / 22.0))

        target_fps = min(dynamic_fps_limit, target_fps)
        target_fps = max(0.0, target_fps)

        scale = self._lerp(1.0, 0.58, amount) * resolution_scale
        jpeg_quality = int(round(self._lerp(90.0, 38.0, amount) * quality_scale))
        png_compression = min(9, max(2, int(round(2 + amount * 5 + (1.0 - quality_scale) * 2))))
        encode_format = 'png' if motion < 0.50 and not boosted else 'jpg'

        if state == self.STREAM_STATE_STATIC:
            if self._static_clear_frame_pending and now >= self._static_clear_frame_due_at:
                return {
                    'state': state,
                    'target_fps': 0.0,
                    'scale': 1.0,
                    'jpeg_quality': 92,
                    'png_compression': 2,
                    'encode_format': 'png',
                    'min_send_interval': 0.0,
                    'loop_sleep': 0.20,
                    'should_send_on_static': False,
                    'static_clear_frame': True,
                }
            return {
                'state': state,
                'target_fps': target_fps,
                'scale': max(0.22, min(1.0, scale)),
                'jpeg_quality': max(16, min(95, jpeg_quality)),
                'png_compression': png_compression,
                'encode_format': encode_format,
                'min_send_interval': 30.0 if target_fps <= 0.0 else 1.0 / target_fps,
                'loop_sleep': 0.20,
                'should_send_on_static': False,
            }

        loop_sleep = max(0.033, min(0.20, 1.0 / max(1.0, target_fps)))
        return {
            'state': state,
            'target_fps': target_fps,
            'scale': max(0.22, min(1.0, scale)),
            'jpeg_quality': max(16, min(95, jpeg_quality)),
            'png_compression': png_compression,
            'encode_format': encode_format,
            'min_send_interval': 30.0 if target_fps <= 0.0 else 1.0 / max(1.0, target_fps),
            'loop_sleep': loop_sleep,
            'should_send_on_static': True,
        }

    def _apply_stream_state(self, state: str, profile: dict, now: float):
        if state != self._stream_state:
            if state == self.STREAM_STATE_STATIC:
                self._static_clear_frame_pending = True
                self._static_clear_frame_due_at = now + 1.0
            else:
                self._static_clear_frame_pending = False
                self._static_clear_frame_due_at = 0.0
            self._stream_state = state
        if state == self.STREAM_STATE_HIGH_MOTION:
            self._stream_state_until = max(
                self._stream_state_until,
                now + float(profile.get('high_motion_hold_seconds', 0.45)),
            )
        elif state == self.STREAM_STATE_LOW_MOTION:
            self._stream_state_until = max(
                self._stream_state_until,
                now + float(profile.get('low_motion_hold_seconds', 2.0)),
            )
        else:
            self._stream_state_until = now + float(profile.get('static_hold_seconds', 60.0))

    def _should_send_frame(self, diff: float, state_params: dict, now: float) -> bool:
        elapsed = now - self._last_sent_at
        target_fps = float(state_params.get('target_fps', 0.0))
        if self._force_next_frame.is_set():
            self._force_next_frame.clear()
            return True
        if not self._h264_client_active and now < self._video_startup_burst_until:
            startup_fps = max(8.0, target_fps)
            return elapsed >= 1.0 / min(20.0, startup_fps)
        if target_fps <= 0.0:
            return elapsed >= float(state_params.get('min_send_interval', 5.0))
        if state_params.get('state') == self.STREAM_STATE_STATIC and not state_params.get('should_send_on_static'):
            return elapsed >= float(state_params.get('min_send_interval', 5.0))
        return elapsed >= float(state_params.get('min_send_interval', 0.1))

    def _extend_video_startup_burst(self, reason: str, duration_seconds: float = 4.0) -> None:
        now = time.time()
        self._video_startup_burst_until = max(
            self._video_startup_burst_until,
            now + max(0.5, duration_seconds),
        )
        self._video_startup_stable_until = max(
            self._video_startup_stable_until,
            now + max(0.5, duration_seconds),
        )
        self._force_next_frame.set()
        logger.info(
            'Video startup burst extended: reason=%s until_ms=%s active=%s',
            reason,
            int(self._video_startup_burst_until * 1000),
            self._h264_client_active,
        )

    def _force_h264_video(self, reason: str, duration_seconds: float = 3.0) -> None:
        now = time.time()
        self._force_h264_until = max(self._force_h264_until, now + max(0.5, duration_seconds))
        self._h265_retry_after = 0.0
        if self._video_stream_codec != 'h264' or self._video_stream_started_codec == 'h265':
            logger.info('Force H264 video: reason=%s duration=%.1fs', reason, duration_seconds)
            self._video_stream_codec = 'h264'
            self._h264_stream_started = False
            self._video_stream_started_codec = ''
            self._video_stream_started_width = 0
            self._video_stream_started_height = 0
            self._last_video_stream_start_sent_at = 0.0
            self._h264_encoder.reset()
            self._force_next_frame.set()

    def _request_video_restart(self, reason: str, *, force_h264: bool = True) -> bool:
        now = time.time()
        if now - self._last_video_restart_request_at < 1.0:
            return False
        self._last_video_restart_request_at = now
        if force_h264:
            self._video_stream_codec = 'h264'
            self._force_h264_until = max(self._force_h264_until, now + 4.0)
        self._send_video_stream_progress(
            stage='restart_requested',
            progress=15,
            codec='h264' if force_h264 else self._video_stream_codec,
            stage_label='已请求重新建立视频通道',
            force=True,
        )
        self._h264_stream_started = False
        self._h264_client_active = False
        self._last_video_stream_seq = 0
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._extend_video_startup_burst(reason, 4.0)
        self._last_video_frame_sent_at = 0.0
        self._video_frame_empty_outputs = 0
        self._h264_encoder.reset()
        if force_h264:
            self._h265_retry_after = 0.0
        self._force_next_frame.set()
        logger.info('Video restart requested: reason=%s force_h264=%s', reason, force_h264)
        return True

    def _is_h264_forced(self, now: Optional[float] = None) -> bool:
        current = now if now is not None else time.time()
        return current < self._force_h264_until or current < self._video_congested_until

    def _apply_video_startup_params(self, encode_params: dict, now: float) -> dict:
        if self._h264_client_active or now >= self._video_startup_stable_until:
            return encode_params
        params = dict(encode_params)
        startup_fps = 15.0
        params['target_fps'] = startup_fps
        params['min_send_interval'] = 1.0 / startup_fps
        params['loop_sleep'] = 1.0 / startup_fps
        params['scale'] = 0.70
        params['target_bitrate_kbps'] = 3000
        params['crf'] = '28'
        params['bufsize_multiplier'] = 2
        params['pixel_format'] = 'yuv420p'
        params['preset'] = 'veryfast'
        params['state'] = 'startup_video'
        params['should_send_on_static'] = True
        return params

    def _apply_transport_congestion_params(self, encode_params: dict, now: float) -> dict:
        if now >= self._video_congested_until:
            if self._video_congestion_level != 0:
                self._video_congestion_level = 0
            return encode_params
        params = dict(encode_params)
        level = max(1, int(self._video_congestion_level or 1))
        max_fps = 18.0
        if level >= 2:
            max_fps = 12.0
        target_fps = min(float(params.get('target_fps', max_fps) or max_fps), max_fps)
        target_fps = max(8.0, target_fps)
        params['target_fps'] = target_fps
        params['min_send_interval'] = max(float(params.get('min_send_interval', 0.0)), 1.0 / target_fps)
        params['loop_sleep'] = max(float(params.get('loop_sleep', 0.0)), 1.0 / target_fps)
        return params

    def _enter_video_fallback(self, reason: str, duration_seconds: float = 20.0) -> None:
        now = time.time()
        self._video_fallback_until = max(
            self._video_fallback_until,
            now + max(1.0, float(duration_seconds or 1.0)),
        )
        self._h264_stream_started = False
        self._h264_client_active = False
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._video_startup_burst_until = 0.0
        self._h264_encoder.reset()
        self._h265_encoder.reset()
        self._image_frame_in_flight = False
        self._force_next_frame.set()
        logger.info(
            'Video fallback enabled: reason=%s until_ms=%s',
            reason,
            int(self._video_fallback_until * 1000),
        )

    def _handle_video_frame_ack(self, data: dict) -> None:
        try:
            seq = int(data.get('seq') or 0)
        except Exception:
            seq = 0
        if seq <= 0:
            return
        now = time.time()
        self._last_video_ack_seq = max(self._last_video_ack_seq, seq)
        self._last_video_ack_at = now
        delay_ms = int(data.get('server_to_client_receive_ms') or data.get('desktop_to_client_receive_ms') or 0)
        self._last_video_ack_delay_ms = delay_ms
        self._update_video_delay_backpressure(delay_ms)

    def _update_video_delay_backpressure(self, delay_ms: int) -> None:
        # Hysteresis gate driven by the client-reported media delay. Application
        # level inflight counters cannot see data already buffered in the TCP
        # kernel send buffer / network pipe, so a saturated 5G uplink lets delay
        # climb to many seconds before any fallback fires. Use the reported delay
        # to throttle the capture loop directly: enter backpressure above the high
        # watermark, leave below the low watermark. Only paces sends, never
        # touches bitrate/encoder so the rebuild-induced fps-to-zero is avoided.
        if delay_ms <= 0:
            return
        self._video_delay_last_sample_at = time.time()
        if self._video_delay_backpressured:
            # Enforce a minimum dwell so a single low sample cannot immediately
            # clear backpressure and restart the oscillation.
            dwell_ok = (
                time.time() - self._video_delay_engaged_at >= self.VIDEO_DELAY_MIN_DWELL_S
            )
            if dwell_ok and delay_ms < self.VIDEO_DELAY_RESUME_MS:
                self._video_delay_backpressured = False
                logger.info('Video delay backpressure cleared: delay_ms=%s', delay_ms)
        else:
            if delay_ms > self.VIDEO_DELAY_THROTTLE_MS:
                self._video_delay_backpressured = True
                self._video_delay_engaged_at = time.time()
                logger.info('Video delay backpressure engaged: delay_ms=%s', delay_ms)

    def _video_delay_backpressure_active(self) -> bool:
        if not self._video_delay_backpressured:
            return False
        # If we stop receiving delay samples (client gone / link recovered and
        # silent), do not stay throttled forever.
        if time.time() - self._video_delay_last_sample_at > self.VIDEO_DELAY_SAMPLE_STALE_S:
            self._video_delay_backpressured = False
            return False
        return True

    def _handle_video_congestion(self, data: dict) -> None:
        delay_ms = int(
            data.get('server_to_client_receive_ms')
            or data.get('desktop_to_client_receive_ms')
            or 0
        )
        self._update_video_delay_backpressure(delay_ms)
        now = time.time()
        if now - self._last_video_congestion_log_at >= 1.0:
            self._last_video_congestion_log_at = now
            logger.info(
                'Video congestion reported: delay_ms=%s reason=%s backpressure=%s',
                delay_ms,
                data.get('reason'),
                self._video_delay_backpressured,
            )

    def _maybe_log_scroll_mode_state(
        self,
        *,
        source: str,
        now: Optional[float] = None,
        loop_sleep: Optional[float] = None,
        encode_params: Optional[dict] = None,
        diff_value: Optional[float] = None,
        should_send: Optional[bool] = None,
    ) -> None:
        return

    def _log_stream_state(
        self,
        *,
        now: float,
        state_params: dict,
        diff_value: float,
        should_send: bool,
    ) -> None:
        if now - self._last_scroll_mode_log_at < 1.0:
            return
        self._last_scroll_mode_log_at = now
        logger.debug(
            'Stream state: state=%s profile=%s motion=%.3f change=%.3f intensity=%.3f should_send=%s fps=%.2f min_send_interval=%.4f scale=%.2f q=%s fmt=%s loop_sleep=%.4f scroll_mode=%s',
            state_params.get('state'),
            self._stream_profile_id,
            diff_value,
            self._last_change_percent,
            self._last_diff_intensity,
            should_send,
            float(state_params.get('target_fps', 0.0)),
            float(state_params.get('min_send_interval', 0.0)),
            float(state_params.get('scale', 1.0)),
            int(state_params.get('jpeg_quality', 72)),
            state_params.get('encode_format', 'jpg'),
            float(state_params.get('loop_sleep', 0.03)),
            self._scroll_mode_active,
        )

    def _encode_frame(self, frame: np.ndarray, encode_params: dict, diff_value: float) -> Optional[bytes]:
        encode_format = str(encode_params.get('encode_format', 'jpg')).lower()
        return self.capture.compress_frame(
            frame,
            fmt=encode_format,
            quality=int(encode_params.get('jpeg_quality', 72)),
            png_compression=int(encode_params.get('png_compression', 2)),
        )

    def _pack_video_frame_binary(
        self,
        *,
        codec: str,
        seq: int,
        sent_at_ms: int,
        width: int,
        height: int,
        profile: str,
        payload: bytes,
    ) -> bytes:
        profile_bytes = str(profile or '').encode('utf-8')
        codec_id = VIDEO_FRAME_CODEC_IDS.get(codec, 1)
        header = struct.pack(
            '!4sBBH I Q I I H',
            VIDEO_FRAME_BINARY_MAGIC,
            VIDEO_FRAME_BINARY_VERSION,
            codec_id,
            0,
            int(seq) & 0xFFFFFFFF,
            max(0, int(sent_at_ms)),
            max(0, int(width)),
            max(0, int(height)),
            len(profile_bytes),
        )
        return header + profile_bytes + payload

    def _send_video_stream_progress(
        self,
        *,
        stage: str,
        progress: int,
        codec: Optional[str] = None,
        stage_label: str = '',
        force: bool = False,
    ) -> None:
        now = time.time()
        active_codec = codec if codec in {'h264', 'h265'} else self._video_stream_codec
        key = f'{active_codec}:{stage}:{int(progress)}'
        if not force and key == self._last_video_progress_stage and now - self._last_video_progress_at < 1.0:
            return
        self._last_video_progress_stage = key
        self._last_video_progress_at = now
        try:
            self._send_peer_media(
                {
                    'type': 'video_stream_progress',
                    'room_id': self.signaling.room_id,
                    'codec': active_codec,
                    'stage': stage,
                    'stage_label': stage_label or stage,
                    'progress': max(0, min(100, int(progress))),
                    'sent_at': int(now * 1000),
                    'profile': self._stream_profile_id,
                    'selected_window_title': self.target_window_title or '',
                    'selected_hwnd': self.target_hwnd,
                }
            )
        except Exception as exc:
            logger.debug('video stream progress send failed: %s', exc)

    def _send_h264_frame(self, frame: np.ndarray, encode_params: dict, now: float) -> None:
        codec = self._video_stream_codec if self._video_stream_codec in {'h265', 'h264'} else 'h264'
        if self._is_h264_forced(now):
            if codec != 'h264':
                self._force_h264_video('forced_window', max(0.5, self._force_h264_until - now))
            codec = 'h264'
        encoder = self._h265_encoder if codec == 'h265' else self._h264_encoder
        if encoder.failed:
            if codec == 'h265':
                self._video_stream_codec = 'h264'
                self._h264_stream_started = False
                self._video_stream_started_codec = ''
                self._video_stream_started_width = 0
                self._video_stream_started_height = 0
                self._h264_encoder.reset()
            return
        if codec == 'h265' and self._h264_client_active and self._video_stream_started_codec == 'h264':
            return
        target_fps = float(encode_params.get('target_fps', 24.0) or 24.0)
        target_bitrate_kbps = int(encode_params.get('target_bitrate_kbps') or 0)
        crf = str(encode_params.get('crf') or '35')
        bufsize_multiplier = int(encode_params.get('bufsize_multiplier') or 2)
        pixel_format = str(encode_params.get('pixel_format') or 'yuv420p')
        preset = str(encode_params.get('preset') or 'veryfast')
        current_frame = frame
        if not self._h264_stream_started or self._video_stream_started_codec != codec:
            self._send_video_stream_progress(
                stage='encoding',
                progress=35,
                codec=codec,
                stage_label='正在编码第一帧画面',
            )
        encoded = encoder.encode(
            current_frame,
            target_fps,
            bitrate_kbps=target_bitrate_kbps,
            crf=crf,
            bufsize_multiplier=bufsize_multiplier,
            pixel_format=pixel_format,
            preset=preset,
        )
        if encoded is None:
            self._send_video_stream_progress(
                stage='encoder_failed',
                progress=35,
                codec=codec,
                stage_label='编码器启动失败，正在重试',
                force=True,
            )
            if codec == 'h265':
                self._video_stream_codec = 'h264'
                self._h264_stream_started = False
                self._video_stream_started_codec = ''
                self._video_stream_started_width = 0
                self._video_stream_started_height = 0
                self._h264_encoder.reset()
            return
        if not encoded:
            self._video_frame_empty_outputs += 1
            self._send_video_stream_progress(
                stage='waiting_encoder_output',
                progress=45,
                codec=codec,
                stage_label='等待编码器输出',
            )
            return
        if not self._h264_stream_started or self._video_stream_started_codec != codec:
            self._send_video_stream_progress(
                stage='encoded_first_frame',
                progress=50,
                codec=codec,
                stage_label='第一帧已编码，准备发送',
            )
        decision = self._video_peak_limiter.assess_encoded_frame(
            self._stream_profile_id,
            encoded_bytes=len(encoded),
            fps=target_fps,
            attempt=0,
            current_scale=float(encode_params.get('scale', 1.0) or 1.0),
        )
        if decision.reason and now - self._h264_last_status_log_at >= 5:
            logger.info(
                'Peak limiter send note: profile=%s codec=%s bytes=%s budget=%s reason=%s scroll_fixed=%s',
                self._stream_profile_id,
                codec,
                len(encoded),
                int(encode_params.get('peak_frame_budget_bytes') or 0),
                decision.reason,
                encode_params.get('scroll_fixed_tuning') is True,
            )
        encoded_width, encoded_height = encoder.encoded_size
        width = encoded_width or int(current_frame.shape[1])
        height = encoded_height or int(current_frame.shape[0])
        content_width, content_height = encoder.content_size
        should_send_start = (
            not self._h264_stream_started
            or self._video_stream_started_codec != codec
            or self._video_stream_started_width != width
            or self._video_stream_started_height != height
        )
        if should_send_start:
            self._h264_stream_started = True
            self._video_stream_started_codec = codec
            self._video_stream_started_width = width
            self._video_stream_started_height = height
            self._last_video_stream_start_sent_at = now
            self._send_peer_media(
                {
                    'type': 'video_stream_start',
                    'room_id': self.signaling.room_id,
                    'codec': codec,
                    'format': 'annexb',
                    'width': width,
                    'height': height,
                    'content_width': content_width,
                    'content_height': content_height,
                    'fps': max(1, int(round(target_fps))),
                    'profile': self._stream_profile_id,
                }
            )
            self._send_video_stream_progress(
                stage='stream_start_sent',
                progress=60,
                codec=codec,
                stage_label='视频通道信息已发送',
                force=True,
            )
            logger.info(
                'Video stream start sent: codec=%s size=%sx%s fps=%s profile=%s active=%s',
                codec,
                width,
                height,
                max(1, int(round(target_fps))),
                self._stream_profile_id,
                self._h264_client_active,
            )
        self._last_video_stream_seq += 1
        seq = self._last_video_stream_seq
        if seq == 1 or should_send_start:
            self._send_video_stream_progress(
                stage='sending_first_frame',
                progress=80,
                codec=codec,
                stage_label='正在发送视频数据',
            )
        sent_at_ms = int(now * 1000)
        sent_interval_ms = (
            (now - self._last_video_frame_sent_at) * 1000.0
            if self._last_video_frame_sent_at > 0.0
            else 0.0
        )
        self._last_video_frame_sent_at = now
        payload = self._pack_video_frame_binary(
            codec=codec,
            seq=seq,
            sent_at_ms=sent_at_ms,
            width=width,
            height=height,
            profile=self._stream_profile_id,
            payload=encoded,
        )
        if self._lan_direct_server.has_client:
            # LAN direct (incl. public-direct via frpc): async send thread so a
            # blocking socket on a weak link never stalls the capture loop.
            self._lan_direct_server.send_binary_media(payload)
        else:
            # Cloudflare relay: use async queue for multi-channel distribution
            self._queue_video_frame(seq, payload)
        if now - self._h264_last_status_log_at >= 5:
            self._h264_last_status_log_at = now
            logger.debug(
                '%s stream heartbeat: seq=%s size=%sx%s bytes=%s budget=%s fps=%.1f bitrate_kbps=%s crf=%s bufmul=%s pixfmt=%s preset=%s profile=%s binary=%s sent_interval_ms=%.1f encode_ms=%.1f packets=%s empty_outputs=%s encoder_empty_outputs=%s',
                codec.upper(),
                seq,
                width,
                height,
                len(encoded),
                int(encode_params.get('peak_frame_budget_bytes') or 0),
                target_fps,
                target_bitrate_kbps,
                crf,
                bufsize_multiplier,
                pixel_format,
                preset,
                self._stream_profile_id,
                True,
                sent_interval_ms,
                float(getattr(encoder, 'last_encode_ms', 0.0)),
                int(getattr(encoder, 'last_packet_count', 0)),
                self._video_frame_empty_outputs,
                int(getattr(encoder, 'empty_outputs', 0)),
            )

    def _reset_video_stream_session(self, *, prefer_h265: bool = True) -> None:
        self._last_video_stream_seq = 0
        self._h264_stream_started = False
        self._h264_client_active = False
        self._video_stream_started_codec = ''
        self._video_stream_started_width = 0
        self._video_stream_started_height = 0
        self._last_video_stream_start_sent_at = 0.0
        self._last_video_frame_sent_at = 0.0
        self._video_frame_empty_outputs = 0
        self._video_startup_stable_until = 0.0
        self._h265_retry_after = 0.0
        self._force_h264_until = 0.0
        self._video_congested_until = 0.0
        self._video_congestion_level = 0
        self._last_video_ack_seq = 0
        self._last_video_ack_at = 0.0
        self._last_video_ack_delay_ms = 0
        if prefer_h265:
            self._video_stream_codec = 'h265'
            self._h265_encoder.reset()
        self._h264_encoder.reset()

    def _should_suppress_image_fallback_for_video_transition(self, now: float) -> bool:
        if self._scroll_mode_active:
            return True
        if self._h264_stream_started and self._video_stream_started_codec in {'h264', 'h265'}:
            return now - self._last_video_stream_start_sent_at < 3.0
        return False

    def capture_webrtc_frame(self) -> Optional[np.ndarray]:
        if not self.running or not self.client_connected or self._video_paused:
            return None
        try:
            profile = self._current_stream_profile()
            if self.target_mode == 'desktop':
                frame = self.capture.capture_desktop()
            elif self.target_mode == 'window':
                hwnd = self._require_target_window('webrtc-video')
                if not hwnd:
                    return None
                frame = self.capture.capture_window(hwnd)
            else:
                return None
            if frame is None:
                return None
            frame = self._fit_frame_to_target_aspect(frame)

            state = self._resolve_stream_state(
                profile,
                self._measure_frame_diff(frame),
                time.time(),
            )
            params = self._resolved_stream_state_params(profile, state)
            scale = float(params.get('scale', 1.0))
            if self._stream_profile_id == 'smooth_hd':
                scale = min(scale, 1.0)
            elif self._stream_profile_id == 'hybrid':
                scale = min(scale, 0.80)
            prepared = self._prepare_frame_for_profile(frame, scale)
            self._last_stream_frame_size = (
                int(prepared.shape[1]),
                int(prepared.shape[0]),
            )
            return prepared
        except Exception as exc:
            logger.debug('capture_webrtc_frame failed: %s', exc)
            return None

    def _candidate_local_ipv4s(self) -> list[str]:
        candidates: list[str] = []

        try:
            host_name = socket.gethostname()
            for family, _, _, _, sockaddr in socket.getaddrinfo(host_name, None, socket.AF_INET):
                if family != socket.AF_INET or not sockaddr:
                    continue
                ip = str(sockaddr[0]).strip()
                if _is_private_ipv4(ip):
                    candidates.append(ip)
        except Exception:
            logger.debug('Failed to collect IPv4 addresses from getaddrinfo', exc_info=True)

        probe_targets: list[tuple[str, int]] = []
        for entry in self._preferred_endpoints:
            host = entry.get('host')
            try:
                port = int(entry.get('port') or 0)
            except Exception:
                continue
            if host and port > 0:
                probe_targets.append((str(host), port))
        if not probe_targets and self.server:
            try:
                probe_targets.append((str(self.server), int(self.port or 0)))
            except Exception:
                pass
        for host, port in probe_targets:
            if not host or port <= 0:
                continue
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.connect((host, int(port)))
                    local_ip = str(sock.getsockname()[0]).strip()
                if _is_private_ipv4(local_ip):
                    candidates.append(local_ip)
            except Exception:
                logger.debug('Failed to probe local IPv4 for %s:%s', host, port, exc_info=True)

        return _dedupe_preserve_order(candidates)

    def _ensure_lan_probe_server(self):
        if self._lan_probe_server is not None:
            return

        try:
            server = _LanProbeHttpServer(
                ('0.0.0.0', self._lan_probe_port),
                _LanProbeRequestHandler,
                agent=self,
            )
        except OSError as exc:
            logger.warning('Failed to start LAN probe server on port %s: %s', self._lan_probe_port, exc)
            return

        def serve():
            try:
                server.serve_forever(poll_interval=0.5)
            except Exception:
                logger.exception('LAN probe server stopped unexpectedly')

        thread = threading.Thread(target=serve, daemon=True, name='lan-probe-server')
        thread.start()
        self._lan_probe_server = server
        self._lan_probe_thread = thread
        logger.info('LAN probe server listening on 0.0.0.0:%s', self._lan_probe_port)

    def _stop_lan_probe_server(self):
        server = self._lan_probe_server
        self._lan_probe_server = None
        self._lan_probe_thread = None
        if server is None:
            return
        try:
            server.shutdown()
        except Exception:
            pass
        try:
            server.server_close()
        except Exception:
            pass

    def _build_metadata(self) -> dict:
        host_name = socket.gethostname()
        local_ips = self._candidate_local_ipv4s()
        self._cached_local_ips = local_ips
        local_ip = local_ips[0] if local_ips else ''

        meta = {
            'device_id': self.device_id,
            'device_name': platform.node() or host_name,
            'host_name': host_name,
            'local_ip': local_ip,
            'local_ips': local_ips,
            'lan_probe_port': self._lan_probe_port,
            'lan_direct_port': self._lan_direct_port,
            'platform': f'{platform.system()} {platform.release()}',
            'selected_window_title': self.target_window_title or '',
        }
        pd = self._public_direct_settings
        if pd.get('enabled') and pd.get('public_host') and pd.get('public_port'):
            meta['public_direct_host'] = pd['public_host']
            meta['public_direct_port'] = int(pd['public_port'])
        return meta

    def _cursor_image_payload(self) -> Optional[dict]:
        try:
            now = time.time()
            cursor_info = CURSORINFO()
            cursor_info.cbSize = ctypes.sizeof(CURSORINFO)
            if not ctypes.windll.user32.GetCursorInfo(ctypes.byref(cursor_info)):
                return self._last_cursor_payload
            if not cursor_info.hCursor:
                return self._last_cursor_payload
            cursor_handle = int(cursor_info.hCursor)
            if self._last_cursor_payload is not None and self._last_cursor_handle == cursor_handle:
                self._last_cursor_image_built_at = now
                return self._last_cursor_payload
            if self._last_cursor_payload is not None and now - self._last_cursor_image_built_at < 0.20:
                return self._last_cursor_payload

            icon_info = ICONINFO()
            if not ctypes.windll.user32.GetIconInfo(cursor_info.hCursor, ctypes.byref(icon_info)):
                return self._last_cursor_payload

            screen_dc = None
            mem_dc = None
            bitmap = None
            dib = None
            old_bitmap = None
            try:
                width = 32
                height = 32
                if icon_info.hbmColor:
                    color_bitmap = BITMAP()
                    ctypes.windll.gdi32.GetObjectW(
                        icon_info.hbmColor,
                        ctypes.sizeof(BITMAP),
                        ctypes.byref(color_bitmap),
                    )
                    if color_bitmap.bmWidth > 0:
                        width = int(color_bitmap.bmWidth)
                    if color_bitmap.bmHeight > 0:
                        height = int(color_bitmap.bmHeight)
                elif icon_info.hbmMask:
                    mask_bitmap = BITMAP()
                    ctypes.windll.gdi32.GetObjectW(
                        icon_info.hbmMask,
                        ctypes.sizeof(BITMAP),
                        ctypes.byref(mask_bitmap),
                    )
                    if mask_bitmap.bmWidth > 0:
                        width = int(mask_bitmap.bmWidth)
                    if mask_bitmap.bmHeight > 0:
                        height = max(1, int(mask_bitmap.bmHeight // 2))

                screen_dc = ctypes.windll.user32.GetDC(0)
                if not screen_dc:
                    return self._last_cursor_payload
                mem_dc = ctypes.windll.gdi32.CreateCompatibleDC(screen_dc)
                if not mem_dc:
                    return self._last_cursor_payload
                bitmap = ctypes.windll.gdi32.CreateCompatibleBitmap(screen_dc, width, height)
                if not bitmap:
                    return self._last_cursor_payload
                old_bitmap = ctypes.windll.gdi32.SelectObject(mem_dc, bitmap)

                brush = ctypes.windll.gdi32.GetStockObject(0)
                ctypes.windll.user32.FillRect(
                    mem_dc,
                    ctypes.byref(ctypes.wintypes.RECT(0, 0, width, height)),
                    brush,
                )
                ctypes.windll.user32.DrawIconEx(
                    mem_dc,
                    0,
                    0,
                    cursor_info.hCursor,
                    width,
                    height,
                    0,
                    None,
                    0x0003,
                )

                bmi = BITMAPINFO()
                bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
                bmi.bmiHeader.biWidth = width
                bmi.bmiHeader.biHeight = -height
                bmi.bmiHeader.biPlanes = 1
                bmi.bmiHeader.biBitCount = 32
                bmi.bmiHeader.biCompression = 0

                buffer_size = width * height * 4
                dib = (ctypes.c_ubyte * buffer_size)()
                result = ctypes.windll.gdi32.GetDIBits(
                    mem_dc,
                    bitmap,
                    0,
                    height,
                    ctypes.byref(dib),
                    ctypes.byref(bmi),
                    0,
                )
                if result == 0:
                    return self._last_cursor_payload

                image = Image.frombuffer(
                    'RGBA',
                    (width, height),
                    bytes(dib),
                    'raw',
                    'BGRA',
                    0,
                    1,
                )
                output = io.BytesIO()
                image.save(output, format='PNG')
                png_bytes = output.getvalue()
                signature = f'{cursor_info.hCursor}:{width}:{height}:{icon_info.xHotspot}:{icon_info.yHotspot}:{len(png_bytes)}'
                if signature == self._last_cursor_signature and self._last_cursor_payload is not None:
                    self._last_cursor_image_built_at = now
                    return self._last_cursor_payload

                payload = {
                    'png': base64.b64encode(png_bytes).decode('ascii'),
                    'width': width,
                    'height': height,
                    'hotspot_x': int(icon_info.xHotspot),
                    'hotspot_y': int(icon_info.yHotspot),
                }
                self._last_cursor_handle = cursor_handle
                self._last_cursor_signature = signature
                self._last_cursor_payload = payload
                self._last_cursor_image_built_at = now
                return payload
            finally:
                if mem_dc and old_bitmap:
                    try:
                        ctypes.windll.gdi32.SelectObject(mem_dc, old_bitmap)
                    except Exception:
                        pass
                if icon_info.hbmColor:
                    ctypes.windll.gdi32.DeleteObject(icon_info.hbmColor)
                if icon_info.hbmMask:
                    ctypes.windll.gdi32.DeleteObject(icon_info.hbmMask)
                if bitmap:
                    ctypes.windll.gdi32.DeleteObject(bitmap)
                if mem_dc:
                    ctypes.windll.gdi32.DeleteDC(mem_dc)
                if screen_dc:
                    ctypes.windll.user32.ReleaseDC(0, screen_dc)
        except Exception as exc:
            logger.debug('cursor image build failed: %s', exc)
            self._last_cursor_image_built_at = time.time()
            return self._last_cursor_payload

    def _cursor_position_payload(self) -> Optional[dict]:
        hwnd = self.target_hwnd
        if self.target_mode == 'window':
            hwnd = self._require_target_window('cursor-position')
            if not hwnd:
                return None
        elif not hwnd:
            return None

        try:
            if self.target_mode == 'window' and self._virtual_cursor_client_pos is not None:
                local_x, local_y = self._virtual_cursor_client_pos
                width, height = self._capture_dimensions(hwnd)
                visible = 0 <= local_x < width and 0 <= local_y < height
                normalized_x = min(1.0, max(0.0, local_x / max(1, width - 1)))
                normalized_y = min(1.0, max(0.0, local_y / max(1, height - 1)))
                return {
                    'type': 'cursor_position',
                    'room_id': self.signaling.room_id,
                    'visible': visible,
                    'x': normalized_x,
                    'y': normalized_y,
                    'width': width,
                    'height': height,
                    'space': self.capture.last_frame_space,
                    'cursor_image': self._cursor_image_payload(),
                }
            cursor_screen_x, cursor_screen_y = win32api.GetCursorPos()
            if self.target_mode == 'desktop' or self.capture.last_frame_space == 'desktop':
                left = win32api.GetSystemMetrics(win32con.SM_XVIRTUALSCREEN)
                top = win32api.GetSystemMetrics(win32con.SM_YVIRTUALSCREEN)
                width = max(1, win32api.GetSystemMetrics(win32con.SM_CXVIRTUALSCREEN))
                height = max(1, win32api.GetSystemMetrics(win32con.SM_CYVIRTUALSCREEN))
                local_x = cursor_screen_x - left
                local_y = cursor_screen_y - top
            elif self.capture.last_capture_bounds is not None:
                left, top, right, bottom = self.capture.last_capture_bounds
                local_x = cursor_screen_x - left
                local_y = cursor_screen_y - top
                width = max(1, right - left)
                height = max(1, bottom - top)
            elif self.capture.last_frame_space == 'window':
                left, top, right, bottom = win32gui.GetWindowRect(hwnd)
                local_x = cursor_screen_x - left
                local_y = cursor_screen_y - top
                width = max(1, right - left)
                height = max(1, bottom - top)
            else:
                local_x, local_y = win32gui.ScreenToClient(hwnd, (cursor_screen_x, cursor_screen_y))
                left, top, right, bottom = win32gui.GetClientRect(hwnd)
                width = max(1, right - left)
                height = max(1, bottom - top)

            visible = 0 <= local_x < width and 0 <= local_y < height
            normalized_x = min(1.0, max(0.0, local_x / max(1, width - 1)))
            normalized_y = min(1.0, max(0.0, local_y / max(1, height - 1)))
            return {
                'type': 'cursor_position',
                'room_id': self.signaling.room_id,
                'visible': visible,
                'x': normalized_x,
                'y': normalized_y,
                'width': width,
                'height': height,
                'space': self.capture.last_frame_space,
                'cursor_image': self._cursor_image_payload(),
            }
        except Exception as exc:
            logger.debug('cursor_position build failed: %s', exc)
            return None

    def _send_agent_update(self):
        self.signaling._send(
            {
                'type': 'agent_update',
                'room_id': self.signaling.room_id,
                'metadata': self._build_metadata(),
                'selected_window_title': self.target_window_title or '',
            }
        )

    def _log_process_handle_counts(self, force: bool = False):
        now = time.time()
        if not force and now - self._last_handle_log_at < 15:
            return
        self._last_handle_log_at = now
        counts = _current_process_handle_counts()
        if counts is None:
            return
        logger.info(
            'Process handle usage: gdi=%s user=%s hwnd=%s mode=%s profile=%s',
            counts['gdi'],
            counts['user'],
            self.target_hwnd,
            self.target_mode,
            self._stream_profile_id,
        )

    def _start_heartbeat(self):
        def loop():
            while self.signaling.connected:
                self.signaling._send(
                    {
                        'type': 'agent_heartbeat',
                        'room_id': self.signaling.room_id,
                        'metadata': self._build_metadata(),
                    }
                )
                time.sleep(10)

        threading.Thread(target=loop, daemon=True, name='agent-heartbeat').start()

    def _on_message(self, data: dict):
        msg_type = data.get('type')
        if msg_type in {'join_room', 'room_joined', 'remote_connected', 'remote_disconnected', 'request_video_restart'}:
            logger.info('Signal message: type=%s', msg_type)

        if msg_type == 'pairing_info':
            room_id = str(data.get('room_id') or self.signaling.room_id or '')
            pair_code = str(data.get('pair_code') or '------')
            logger.info(
                'Pairing info payload applied: room_id=%s pair_code=%s device_id=%s',
                room_id,
                pair_code,
                data.get('device_id'),
            )
            self._set_ui_pairing_info(room_id, pair_code)
            self._set_ui_status(f'等待手机扫码绑定，配对码：{pair_code}')
        elif msg_type == 'pair_request':
            self._enqueue_pair_prompt(data)
            client_name = data.get('client_name') or '未命名手机'
            self._set_ui_status(f'收到来自 {client_name} 的绑定申请')
        elif msg_type == 'room_joined':
            if data.get('channel') == 'media':
                return
            logger.info('Joined room: %s', data.get('room_id'))
            self._sync_trusted_clients_to_server()
            self._send_agent_update()
            self._start_heartbeat()
            self._set_ui_status('已连接服务器，等待配对或控制连接')
            self._refresh_ui_snapshot()
        elif msg_type == 'remote_connected':
            if data.get('channel') == 'media':
                return
            logger.info(
                'Remote connected: role=%s client_id=%s',
                data.get('role'),
                str(data.get('client_id') or '').strip() or '-',
            )
            if data.get('role') == 'client':
                incoming_client_id = str(data.get('client_id') or '').strip() or None
                self.client_connected = True
                if incoming_client_id:
                    self._current_client_hint_id = incoming_client_id
                    self._mark_trusted_client_connected(self._current_client_hint_id)
                elif self._recent_pair_client_id and time.time() - self._recent_pair_approved_at <= 300:
                    self._current_client_hint_id = self._recent_pair_client_id
                    self._mark_trusted_client_connected(self._current_client_hint_id)
                elif len(self._trusted_clients) == 1:
                    self._current_client_hint_id = self._trusted_clients[0]['client_id']
                    self._mark_trusted_client_connected(self._current_client_hint_id)
                else:
                    self._current_client_hint_id = None
                self.running = True
                self._send_video_stream_progress(
                    stage='remote_connected_received',
                    progress=20,
                    codec='h264',
                    stage_label='已收到客户端连接',
                    force=True,
                )
                self._select_default_window_if_needed('client-connected')
                self._reset_video_stream_session(prefer_h265=False)
                self._extend_video_startup_burst('client-connected', 5.0)
                self._start_capture()
                self._start_cursor_stream()
                self._set_ui_status('已连接到已授权手机，正在共享画面')
                self._refresh_ui_snapshot()
        elif msg_type == 'remote_disconnected':
            if data.get('channel') == 'media':
                return
            logger.info(
                'Remote disconnected: role=%s client_id=%s',
                data.get('role'),
                str(data.get('client_id') or '').strip() or '-',
            )
            if data.get('role') == 'client':
                incoming_client_id = str(data.get('client_id') or '').strip() or None
                if incoming_client_id and self._current_client_hint_id and incoming_client_id != self._current_client_hint_id:
                    logger.info(
                        'Remote disconnected client does not match current hint: disconnected=%s current=%s',
                        incoming_client_id,
                        self._current_client_hint_id,
                    )
                self.client_connected = False
                self._current_client_hint_id = None
                self.running = False
                self._reset_video_stream_session(prefer_h265=False)
                if self.target_mode == 'window':
                    self.capture.release_window_resources(self.target_hwnd)
                self._set_ui_status('手机已断开，等待下一次连接')
                self._refresh_ui_snapshot()
        elif msg_type == 'request_video_restart':
            reason = str(data.get('reason') or 'client-request')
            force_h264 = data.get('force_h264') is not False
            logger.info('Video restart requested (raw): reason=%s force_h264=%s', reason, force_h264)
            self._request_video_restart(reason, force_h264=force_h264)
        elif msg_type == 'get_windows':
            self._handle_get_windows(data)
        elif msg_type == 'set_window':
            self._write_scroll_diagnostic(
                'set_window_received',
                {
                    'requested_hwnd': data.get('hwnd'),
                    'client_connected': self.client_connected,
                    'h264_client_active': self._h264_client_active,
                    'video_codec': self._video_stream_started_codec or self._video_stream_codec,
                },
            )
            self._handle_set_window(data)
        elif msg_type == 'control':
            self._handle_control(data)
        elif msg_type == 'image_frame_ack':
            self._image_frame_in_flight = False
            self._last_image_frame_ack_at = time.time()
        elif msg_type == 'video_stream_status':
            codec = str(data.get('codec') or '').strip().lower()
            active = data.get('active') is True and codec in {'h264', 'h265'}
            reason = str(data.get('reason') or '')
            self._write_scroll_diagnostic(
                'video_stream_status_received',
                {
                    'codec': codec,
                    'active': active,
                    'reason': reason,
                    'started_codec': self._video_stream_started_codec,
                    'h264_client_active_before': self._h264_client_active,
                },
            )
            logger.debug(
                'Video stream status: codec=%s active=%s reason=%s',
                codec,
                active,
                reason,
            )
            if codec == 'h265' and not active:
                self._video_stream_codec = 'h264'
                self._h264_stream_started = False
                self._video_stream_started_codec = ''
                self._video_stream_started_width = 0
                self._video_stream_started_height = 0
                self._h265_retry_after = 0.0
                self._h264_encoder.reset()
            elif codec == 'h264' and not active and 'decoder produced no output' in reason:
                self._enter_video_fallback(reason, 30.0)
            elif codec == 'h264' and not active and reason != 'decoder-negotiating':
                self._h264_stream_started = False
                self._video_stream_started_codec = ''
                self._video_stream_started_width = 0
                self._video_stream_started_height = 0
                self._h264_encoder.reset()
                self._extend_video_startup_burst(f'h264-inactive:{reason}', 4.0)
            elif codec == 'h264' and not active:
                self._extend_video_startup_burst(f'h264-negotiating:{reason}', 3.0)
                active = self._h264_client_active
            elif codec in {'h264', 'h265'} and active:
                self._video_stream_codec = codec
                if codec == 'h265':
                    self._h265_retry_after = 0.0
            if self._h264_client_active != active:
                logger.info(
                    'Video stream client status changed: codec=%s active=%s reason=%s',
                    codec,
                    active,
                    reason,
                )
            self._h264_client_active = active
        elif msg_type == 'video_frame_ack':
            self._handle_video_frame_ack(data)
        elif msg_type == 'video_congestion':
            self._handle_video_congestion(data)
        elif msg_type in (
            'webrtc_offer',
            'webrtc_answer',
            'webrtc_ice_candidate',
            'webrtc_transport_state',
        ):
            logger.info('WebRTC signal received: type=%s', msg_type)
            self._direct_transport.handle_signal(data)

    def _available_drive_roots(self) -> list[dict]:
        roots = []
        for letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ':
            drive = f'{letter}:\\'
            if os.path.exists(drive):
                roots.append(
                    {
                        'name': drive,
                        'path': drive,
                        'is_dir': True,
                        'size': 0,
                        'modified_at': None,
                    }
                )
        return roots

    def _list_directory_payload(self, raw_path: Optional[str]) -> dict:
        path = (raw_path or '').strip()
        if path == '':
            return {
                'path': '',
                'parent': None,
                'entries': self._available_drive_roots(),
            }

        resolved_path = os.path.abspath(os.path.expandvars(path))
        if not os.path.isdir(resolved_path):
            raise FileNotFoundError(f'目录不存在: {resolved_path}')

        entries: list[dict] = []
        with os.scandir(resolved_path) as scan:
            for entry in scan:
                try:
                    stat = entry.stat(follow_symlinks=False)
                    modified_at = int(stat.st_mtime)
                    size = int(stat.st_size) if entry.is_file(follow_symlinks=False) else 0
                except OSError:
                    modified_at = None
                    size = 0
                entries.append(
                    {
                        'name': entry.name,
                        'path': entry.path,
                        'is_dir': entry.is_dir(follow_symlinks=False),
                        'size': size,
                        'modified_at': modified_at,
                    }
                )

        entries.sort(key=lambda item: (not item['is_dir'], item['name'].lower()))
        parent = os.path.dirname(resolved_path.rstrip('\\/'))
        if parent == resolved_path.rstrip('\\/'):
            parent = ''
        return {
            'path': resolved_path,
            'parent': parent,
            'entries': entries,
        }

    def _get_terminal_profiles(self) -> list[dict]:
        profiles: list[dict] = []

        def add_profile(profile_id: str, name: str, executable: str, description: str):
            if shutil.which(executable):
                profiles.append(
                    {
                        'id': profile_id,
                        'name': name,
                        'executable': executable,
                        'description': description,
                    }
                )

        add_profile('windows_terminal', 'Windows Terminal', 'wt.exe', '多标签终端')
        add_profile('pwsh', 'PowerShell 7', 'pwsh.exe', '现代 PowerShell')
        add_profile('powershell', 'Windows PowerShell', 'powershell.exe', '系统内置 PowerShell')
        add_profile('cmd', '命令提示符', 'cmd.exe', '经典 CMD')

        git_bash_candidates = [
            r'C:\Program Files\Git\git-bash.exe',
            r'C:\Program Files\Git\bin\bash.exe',
        ]
        for candidate in git_bash_candidates:
            if os.path.exists(candidate):
                profiles.append(
                    {
                        'id': 'git_bash',
                        'name': 'Git Bash',
                        'executable': candidate,
                        'description': 'Git for Windows Bash',
                    }
                )
                break

        return profiles

    def _set_file_clipboard(self, mode: str, paths: list[str]) -> tuple[bool, dict]:
        normalized_mode = mode.strip().lower()
        if normalized_mode not in {'copy', 'cut'}:
            return False, {'message': '不支持的剪贴模式'}

        normalized_paths: list[str] = []
        for item in paths:
            resolved = os.path.abspath(os.path.expandvars(str(item)))
            if not os.path.exists(resolved):
                return False, {'message': f'路径不存在: {resolved}'}
            normalized_paths.append(resolved)

        self._file_clipboard_mode = normalized_mode
        self._file_clipboard_paths = normalized_paths
        return True, {
            'clipboard_mode': self._file_clipboard_mode,
            'clipboard_count': len(self._file_clipboard_paths),
            'message': f'已{ "复制" if normalized_mode == "copy" else "剪切" } {len(self._file_clipboard_paths)} 项',
        }

    def _paste_file_clipboard(self, destination: str) -> tuple[bool, dict]:
        if not self._file_clipboard_paths or self._file_clipboard_mode is None:
            return False, {'message': '剪贴板为空'}

        resolved_destination = os.path.abspath(os.path.expandvars(destination))
        if not os.path.isdir(resolved_destination):
            return False, {'message': f'目标目录不存在: {resolved_destination}'}

        for source in self._file_clipboard_paths:
            target_path = os.path.join(resolved_destination, os.path.basename(source))
            if os.path.exists(target_path):
                return False, {'message': f'目标已存在: {target_path}'}

        moved_count = 0
        try:
            for source in self._file_clipboard_paths:
                target_path = os.path.join(resolved_destination, os.path.basename(source))
                if self._file_clipboard_mode == 'copy':
                    if os.path.isdir(source):
                        shutil.copytree(source, target_path)
                    else:
                        shutil.copy2(source, target_path)
                else:
                    shutil.move(source, target_path)
                    moved_count += 1
            if self._file_clipboard_mode == 'cut' and moved_count == len(self._file_clipboard_paths):
                self._file_clipboard_paths = []
                self._file_clipboard_mode = None
            return True, {
                'clipboard_mode': self._file_clipboard_mode,
                'clipboard_count': len(self._file_clipboard_paths),
                'message': '粘贴完成',
                'destination': resolved_destination,
            }
        except Exception as exc:
            logger.error('paste_file_clipboard failed: %s', exc)
            return False, {'message': str(exc)}

    def _create_folder(self, parent: str, name: str) -> tuple[bool, dict]:
        resolved_parent = os.path.abspath(os.path.expandvars(parent))
        if not os.path.isdir(resolved_parent):
            return False, {'message': f'目标目录不存在: {resolved_parent}'}

        folder_name = os.path.basename(str(name or '').strip().strip('\\/'))
        if not folder_name:
            return False, {'message': '文件夹名称不能为空'}
        if folder_name in {'.', '..'} or any(char in folder_name for char in '<>:"/\\|?*'):
            return False, {'message': '文件夹名称包含非法字符'}

        target_path = os.path.join(resolved_parent, folder_name)
        if os.path.exists(target_path):
            return False, {'message': f'文件夹已存在: {target_path}'}

        try:
            os.makedirs(target_path, exist_ok=False)
            return True, {
                'message': f'已新建文件夹: {folder_name}',
                'path': target_path,
            }
        except Exception as exc:
            logger.error('create_folder failed: %s', exc)
            return False, {'message': str(exc)}

    def _launch_terminal(self, working_dir: str, terminal_id: str) -> tuple[bool, dict]:
        resolved_dir = os.path.abspath(os.path.expandvars(working_dir))
        if not os.path.isdir(resolved_dir):
            return False, {'message': f'目录不存在: {resolved_dir}'}

        creation_flags = getattr(subprocess, 'CREATE_NEW_CONSOLE', 0)
        try:
            if terminal_id == 'windows_terminal':
                command = ['wt.exe', '-d', resolved_dir]
                subprocess.Popen(command, cwd=resolved_dir)
            elif terminal_id == 'pwsh':
                subprocess.Popen(['pwsh.exe', '-NoExit'], cwd=resolved_dir, creationflags=creation_flags)
            elif terminal_id == 'powershell':
                subprocess.Popen(
                    ['powershell.exe', '-NoExit'],
                    cwd=resolved_dir,
                    creationflags=creation_flags,
                )
            elif terminal_id == 'cmd':
                subprocess.Popen(['cmd.exe'], cwd=resolved_dir, creationflags=creation_flags)
            elif terminal_id == 'git_bash':
                git_bash = next(
                    (
                        candidate
                        for candidate in (
                            r'C:\Program Files\Git\git-bash.exe',
                            r'C:\Program Files\Git\bin\bash.exe',
                        )
                        if os.path.exists(candidate)
                    ),
                    None,
                )
                if not git_bash:
                    return False, {'message': '未找到 Git Bash'}
                subprocess.Popen([git_bash], cwd=resolved_dir)
            else:
                return False, {'message': f'未知终端: {terminal_id}'}
            return True, {'message': f'已在 {resolved_dir} 打开终端'}
        except Exception as exc:
            logger.error('launch_terminal failed: %s', exc)
            return False, {'message': str(exc)}

    def _execute_command(self, command_text: str, auto_enter: bool) -> tuple[bool, dict]:
        normalized = command_text.replace('\r\n', '\n').strip('\n')
        if normalized == '':
            return False, {'message': '命令不能为空'}

        foreground = self.target_hwnd if self.target_mode == 'window' and self.target_hwnd else win32gui.GetForegroundWindow()
        if not foreground:
            return False, {'message': '当前没有活动窗口'}

        try:
            class_name = win32gui.GetClassName(foreground)
        except Exception:
            class_name = ''

        if class_name not in {'CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass'}:
            return False, {'message': '当前前台不是终端窗口'}

        try:
            try:
                win32gui.SetForegroundWindow(foreground)
            except Exception:
                pass
            for ch in normalized:
                if ch == '\n':
                    self._send_virtual_key(win32con.VK_RETURN)
                else:
                    self._send_unicode_char(ch)
            if auto_enter:
                self._send_virtual_key(win32con.VK_RETURN)
            return True, {'message': '命令已发送到前台终端'}
        except Exception as exc:
            logger.error('execute_command failed: %s', exc)
            return False, {'message': str(exc)}

    def _launch_program(self, executable: str, arguments: str, working_dir: str) -> tuple[bool, dict]:
        resolved_working_dir = os.path.abspath(os.path.expandvars(working_dir)) if working_dir else ''
        if resolved_working_dir and not os.path.isdir(resolved_working_dir):
            return False, {'message': f'目录不存在: {resolved_working_dir}'}

        expanded_executable = os.path.expandvars(executable)
        if not shutil.which(expanded_executable) and not os.path.exists(expanded_executable):
            return False, {'message': f'程序不存在: {expanded_executable}'}

        try:
            argv = [expanded_executable]
            if arguments.strip():
                argv.extend(shlex.split(arguments, posix=False))
            subprocess.Popen(argv, cwd=resolved_working_dir or None)
            return True, {'message': f'已启动程序: {os.path.basename(expanded_executable)}'}
        except Exception as exc:
            logger.error('launch_program failed: %s', exc)
            return False, {'message': str(exc)}

    def _prepare_file_download(self, raw_path: str, client_id: str) -> tuple[bool, dict]:
        normalized_client_id = str(client_id or '').strip()
        if not normalized_client_id:
            return False, {'message': '缺少 client_id'}

        resolved_path = os.path.abspath(os.path.expandvars(str(raw_path or '').strip()))
        if not resolved_path:
            return False, {'message': '文件路径不能为空'}
        if not os.path.exists(resolved_path):
            return False, {'message': f'文件不存在: {resolved_path}'}
        if not os.path.isfile(resolved_path):
            return False, {'message': '暂不支持传输文件夹'}

        file_size = int(os.path.getsize(resolved_path))
        max_size = 1024 * 1024 * 1024
        if file_size <= 0:
            return False, {'message': '文件为空，无法传输'}
        if file_size > max_size:
            return False, {'message': '文件过大，当前仅支持 1GB 以内文件'}

        upload_url = f'{self.signaling.get_http_base_url()}/api/file-transfer/upload'
        file_name = os.path.basename(resolved_path)
        params = {
            'device_id': self.device_id,
            'client_id': normalized_client_id,
            'file_name': file_name,
            'file_size': str(file_size),
        }

        try:
            with open(resolved_path, 'rb') as file:
                response = requests.post(
                    upload_url,
                    params=params,
                    data=file,
                    headers={'Content-Type': 'application/octet-stream'},
                    timeout=(10, 600),
                )
            payload = response.json()
        except Exception as exc:
            logger.error('prepare_file_download upload failed: %s', exc)
            return False, {'message': str(exc)}

        if response.status_code < 200 or response.status_code >= 300:
            message = str(payload.get('message') or f'上传失败: {response.status_code}')
            return False, {'message': message}

        token = str(payload.get('token') or '').strip()
        download_url = str(payload.get('download_url') or '').strip()
        if not token or not download_url:
            return False, {'message': '服务端未返回下载令牌'}

        return True, {
            'message': f'已准备下载: {file_name}',
            'token': token,
            'file_name': str(payload.get('file_name') or file_name),
            'file_size': int(payload.get('size') or file_size),
            'expires_at': int(payload.get('expires_at') or 0),
            'download_url': download_url,
            'relative_download_url': str(payload.get('relative_download_url') or '').strip(),
            'server_base_url': self.signaling.get_http_base_url(),
        }

    def _save_uploaded_file(self, params: dict) -> tuple[bool, dict]:
        destination = os.path.abspath(os.path.expandvars(str(params.get('destination') or '').strip()))
        if not destination or not os.path.isdir(destination):
            return False, {'message': f'目标目录不存在: {destination}'}

        file_name = os.path.basename(str(params.get('file_name') or '').strip())
        if not file_name:
            return False, {'message': '文件名不能为空'}
        download_url = str(params.get('download_url') or '').strip()
        relative_download_url = str(params.get('relative_download_url') or '').strip()
        if not download_url and relative_download_url:
            download_url = self.signaling.get_http_base_url().rstrip('/') + relative_download_url
        if not download_url:
            return False, {'message': '下载地址不能为空'}

        target_path = os.path.join(destination, file_name)
        if os.path.exists(target_path):
            name, ext = os.path.splitext(file_name)
            for index in range(1, 1000):
                candidate = os.path.join(destination, f'{name} ({index}){ext}')
                if not os.path.exists(candidate):
                    target_path = candidate
                    break
            else:
                return False, {'message': '无法分配保存文件名'}

        try:
            with requests.get(download_url, stream=True, timeout=(10, 600)) as response:
                if response.status_code < 200 or response.status_code >= 300:
                    return False, {'message': f'下载失败: {response.status_code}'}
                with open(target_path, 'wb') as file:
                    for chunk in response.iter_content(chunk_size=1024 * 1024):
                        if chunk:
                            file.write(chunk)
            return True, {
                'message': f'已保存到电脑: {target_path}',
                'path': target_path,
                'file_name': os.path.basename(target_path),
            }
        except Exception as exc:
            logger.error('save_uploaded_file failed: %s', exc)
            try:
                if os.path.exists(target_path):
                    os.remove(target_path)
            except Exception:
                pass
            return False, {'message': str(exc)}

    def _capture_region_screenshot(self, params: dict) -> tuple[bool, dict]:
        normalized_client_id = str(params.get('client_id') or '').strip()
        if not normalized_client_id:
            return False, {'message': '缺少 client_id'}

        if self.target_mode == 'desktop':
            frame = self.capture.capture_desktop()
        else:
            hwnd = self._require_target_window('capture-region-screenshot', require_visible=False)
            if not hwnd:
                return False, {'message': '当前没有可截图的目标窗口'}
            frame = self.capture.capture_window(hwnd)

        if frame is None:
            return False, {'message': self.capture.last_capture_error or '截图失败'}

        source_width = int(frame.shape[1]) if frame.ndim >= 2 else 0
        source_height = int(frame.shape[0]) if frame.ndim >= 2 else 0
        if source_width <= 0 or source_height <= 0:
            return False, {'message': '截图尺寸无效'}

        remote_width = int(params.get('remote_width') or 0)
        remote_height = int(params.get('remote_height') or 0)
        if remote_width <= 0 or remote_height <= 0:
            remote_width, remote_height = self._last_stream_frame_size
        if remote_width <= 0 or remote_height <= 0:
            remote_width, remote_height = source_width, source_height

        try:
            left = int(params.get('left') or 0)
            top = int(params.get('top') or 0)
            width = int(params.get('width') or 0)
            height = int(params.get('height') or 0)
        except Exception:
            return False, {'message': '截图区域参数无效'}

        if width <= 0 or height <= 0:
            return False, {'message': '截图区域不能为空'}

        left = max(0, min(remote_width - 1, left))
        top = max(0, min(remote_height - 1, top))
        right = max(left + 1, min(remote_width, left + width))
        bottom = max(top + 1, min(remote_height, top + height))

        mapped_left = max(0, min(source_width - 1, round((left / max(1, remote_width - 1)) * max(1, source_width - 1))))
        mapped_top = max(0, min(source_height - 1, round((top / max(1, remote_height - 1)) * max(1, source_height - 1))))
        mapped_right = max(
            mapped_left + 1,
            min(source_width, round((right / max(1, remote_width)) * source_width)),
        )
        mapped_bottom = max(
            mapped_top + 1,
            min(source_height, round((bottom / max(1, remote_height)) * source_height)),
        )

        cropped = frame[mapped_top:mapped_bottom, mapped_left:mapped_right]
        if cropped.size == 0:
            return False, {'message': '截图区域超出有效范围'}

        temp_dir = os.path.join(_persistent_state_dir(), 'temp-captures')
        os.makedirs(temp_dir, exist_ok=True)
        suffix = f'-capture-{int(time.time())}-{uuid.uuid4().hex[:8]}.png'
        tmp_path = tempfile.mktemp(suffix=suffix, dir=temp_dir)

        try:
            image = Image.fromarray(cropped)
            image.save(tmp_path, format='PNG', compress_level=1)
            success, payload = self._prepare_file_download(tmp_path, normalized_client_id)
            if not success:
                return False, payload
            payload.update(
                {
                    'message': '截图已生成',
                    'image_width': int(cropped.shape[1]),
                    'image_height': int(cropped.shape[0]),
                    'source_width': source_width,
                    'source_height': source_height,
                    'capture_left': mapped_left,
                    'capture_top': mapped_top,
                }
            )
            return True, payload
        except Exception as exc:
            logger.error('capture_region_screenshot failed: %s', exc, exc_info=True)
            return False, {'message': str(exc)}
        finally:
            try:
                if os.path.exists(tmp_path):
                    os.remove(tmp_path)
            except Exception:
                pass

    def _list_windows(self):
        with self._windows_list_lock:
            now = time.time()
            if self._windows_list_cache and now - self._windows_list_cache_at <= 0.75:
                return list(self._windows_list_cache)

        windows = [
            {
                'hwnd': -1,
                'title': '整个桌面',
                'class_name': 'POCKETWINDOW_DESKTOP',
                'rect': [],
                'remark': '',
                'activity_state': 'idle',
            }
        ]

        now = time.time()
        live_hwnds: set[int] = set()

        def enum_callback(hwnd, result):
            if win32gui.IsWindowVisible(hwnd):
                title = win32gui.GetWindowText(hwnd)
                if title:
                    try:
                        class_name = win32gui.GetClassName(hwnd)
                        rect = win32gui.GetWindowRect(hwnd)
                    except Exception:
                        class_name = ''
                        rect = (0, 0, 0, 0)
                    int_hwnd = int(hwnd)
                    live_hwnds.add(int_hwnd)
                    previous_title = self._window_title_cache.get(int_hwnd)
                    activity_state = 'idle'
                    if previous_title is not None and previous_title != title:
                        activity_state = 'running'
                    elif self.target_mode == 'window' and self.target_hwnd == int_hwnd and self._is_motion_boost_active(now):
                        activity_state = 'running'
                    result.append(
                        {
                            'hwnd': int_hwnd,
                            'title': title,
                            'class_name': class_name,
                            'rect': list(rect),
                            'remark': self._window_remarks.get(int_hwnd, ''),
                            'activity_state': activity_state,
                        }
                    )
                    self._window_title_cache[int_hwnd] = title

        win32gui.EnumWindows(enum_callback, windows)
        self._window_title_cache = {
            hwnd: title for hwnd, title in self._window_title_cache.items() if hwnd in live_hwnds
        }
        with self._windows_list_lock:
            self._windows_list_cache = list(windows)
            self._windows_list_cache_at = time.time()
        return windows

    def _handle_get_windows(self, data: dict):
        room_id = data.get('room_id') or self.signaling.room_id
        self._send_peer_control(
            {
                'type': 'windows_list',
                'room_id': room_id,
            'windows': self._list_windows(),
            }
        )

    def _select_default_window_if_needed(self, reason: str) -> bool:
        if self.target_mode == 'desktop':
            return True
        if self.target_hwnd and self._is_window_available(self.target_hwnd):
            return True
        windows = self._list_windows()
        candidate = None
        for item in windows:
            try:
                hwnd = int(item.get('hwnd'))
            except Exception:
                continue
            if hwnd == -1:
                continue
            # Never default-select the agent's own desktop UI window. If we
            # did, the phone would scroll/click PocketWindow itself, which
            # confuses users into thinking control isn't working.
            title = str(item.get('title') or '').strip()
            if title == DESKTOP_UI_WINDOW_TITLE:
                continue
            if self._is_window_available(hwnd):
                candidate = item
                break
        if candidate is None:
            logger.info('Default window selection skipped: reason=%s no window available', reason)
            return False
        hwnd = int(candidate['hwnd'])
        self.target_mode = 'window'
        self.target_hwnd = hwnd
        self.target_window_title = str(candidate.get('title') or '')
        try:
            self._original_window_rect = win32gui.GetWindowRect(hwnd)
        except Exception:
            self._original_window_rect = None
        self._virtual_cursor_client_pos = None
        self._extend_video_startup_burst(f'default-window:{reason}', 4.0)
        self._defer_video_start_until_stable(f'default-window:{reason}')
        self._force_next_frame.set()
        logger.info(
            'Default selected target window: [%s] (%s) reason=%s',
            self.target_window_title.encode('unicode_escape').decode('ascii'),
            hwnd,
            reason,
        )
        return True

    def _handle_set_window(self, data: dict):
        room_id = data.get('room_id') or self.signaling.room_id
        hwnd = data.get('hwnd')
        success = False
        title = None

        if hwnd is not None:
            try:
                hwnd = int(hwnd)
                if hwnd == -1:
                    if self.target_mode == 'window' and self.target_hwnd:
                        self.capture.release_window_resources(self.target_hwnd)
                    self.target_mode = 'desktop'
                    self.target_hwnd = None
                    self.target_window_title = '整个桌面'
                    self._original_window_rect = None
                    self._original_client_size = None
                    self._reset_stream_state()
                    self._extend_video_startup_burst('select-desktop', 4.0)
                    self._defer_video_start_until_stable('select-desktop')
                    success = True
                    title = self.target_window_title
                    logger.info('Selected desktop mode')
                    if self.running and self.client_connected:
                        self._start_capture()
                    self._send_agent_update()
                    self._refresh_ui_snapshot()
                elif self._is_window_available(hwnd):
                    previous_hwnd = self.target_hwnd if self.target_mode == 'window' else None
                    if previous_hwnd and previous_hwnd != hwnd:
                        self.capture.release_window_resources(previous_hwnd)
                    self.target_mode = 'window'
                    self.target_hwnd = hwnd
                    title = win32gui.GetWindowText(hwnd)
                    self.target_window_title = title
                    self._original_window_rect = win32gui.GetWindowRect(hwnd)
                    client_rect = win32gui.GetClientRect(hwnd)
                    self._original_client_size = (
                        max(1, client_rect[2] - client_rect[0]),
                        max(1, client_rect[3] - client_rect[1]),
                    )
                    try:
                        self._show_and_activate_window(hwnd)
                    except Exception:
                        pass
                    self._reset_stream_state()
                    self._extend_video_startup_burst('select-window', 4.0)
                    self._defer_video_start_until_stable('select-window')
                    success = True
                    logger.info('Selected target window: [%s] (%s)', title, hwnd)
                    if self.running and self.client_connected:
                        self._start_capture()
                    self._send_agent_update()
                    self._refresh_ui_snapshot()
            except Exception as exc:
                logger.error('set_window failed: %s', exc)

        self._send_peer_control(
            {
                'type': 'set_window_response',
                'room_id': room_id,
                'success': success,
                'hwnd': hwnd,
                'title': title,
            }
        )

    def _handle_control(self, data: dict):
        command = data.get('command')
        params = data.get('params', {})

        if isinstance(command, str) and command.startswith('terminal.'):
            if command == 'terminal.clientlog':
                logger.info('PHONELOG %s', params.get('msg'))
                return
            self._terminal_manager.handle(command, params)
            return

        if command == 'mouse_move':
            x, y = params.get('x', 0), params.get('y', 0)
            if self.target_hwnd:
                success = self._move_cursor_to_client_point(int(x), int(y))
                self._send_control_response(command, success)
        elif command == 'mouse_move_relative':
            dx, dy = params.get('dx', 0), params.get('dy', 0)
            success = self._move_cursor_relative(int(dx), int(dy))
            self._send_control_response(command, success)
        elif command == 'mouse_click':
            x, y = params.get('x', 0), params.get('y', 0)
            button = params.get('button', 'left')
            if self.target_hwnd:
                success = self._click_client_point(int(x), int(y), button)
                if success:
                    self._request_interaction_frame_refresh()
                self._send_control_response(command, success)
        elif command == 'mouse_click_current':
            button = params.get('button', 'left')
            success = self._click_current_cursor(button)
            if success:
                self._request_interaction_frame_refresh()
            self._send_control_response(command, success)
        elif command == 'debug_client_click':
            logger.info(
                'debug_client_click: source=%s hwnd=%s selected_hwnd=%s local=(%.2f,%.2f) container=%sx%s remote=%sx%s mapped=(%s,%s) button=%s target_hwnd=%s target_title=%s frame_space=%s stream_frame=%sx%s capture_frame=%sx%s',
                params.get('source'),
                self.target_hwnd,
                params.get('selected_hwnd'),
                float(params.get('local_x', 0.0)),
                float(params.get('local_y', 0.0)),
                int(params.get('container_w', 0)),
                int(params.get('container_h', 0)),
                int(params.get('remote_w', 0)),
                int(params.get('remote_h', 0)),
                params.get('mapped_x'),
                params.get('mapped_y'),
                params.get('button'),
                self.target_hwnd,
                self.target_window_title,
                self.capture.last_frame_space,
                self._last_stream_frame_size[0],
                self._last_stream_frame_size[1],
                self.capture.last_frame_size[0],
                self.capture.last_frame_size[1],
            )
            self._send_control_response(command, True)
        elif command == 'center_cursor':
            success = self._move_cursor_to_window_center(self.target_hwnd) if self.target_hwnd else False
            if success:
                self._request_interaction_frame_refresh()
            self._send_control_response(command, success)
        elif command == 'mouse_wheel':
            delta = params.get('delta', 0)
            wheel_delta = params.get('wheel_delta', None)
            diagnostic = params.get('diagnostic') if isinstance(params.get('diagnostic'), dict) else {}
            self._write_scroll_diagnostic(
                'wheel_received',
                {
                    'source': 'desktop',
                    'client': diagnostic,
                    'delta': int(delta),
                    'wheel_delta': int(wheel_delta) if wheel_delta is not None else None,
                    'scroll_mode': self._scroll_mode_active,
                },
            )
            success = self._mouse_wheel(int(delta), int(wheel_delta) if wheel_delta is not None else None)
            self._write_scroll_diagnostic(
                'wheel_executed',
                {
                    'source': 'desktop',
                    'client': diagnostic,
                    'delta': int(delta),
                    'wheel_delta': int(wheel_delta) if wheel_delta is not None else None,
                    'success': success,
                    'method': self._last_mouse_wheel_method,
                    'scroll_mode': self._scroll_mode_active,
                },
            )
            if success:
                self._queue_scroll_frame_diagnostic(
                    {
                        'gesture_id': diagnostic.get('gesture_id'),
                        'wheel_id': diagnostic.get('wheel_id'),
                        'desktop_ts_ms': int(time.time() * 1000),
                        'delta': int(delta),
                        'wheel_delta': int(wheel_delta) if wheel_delta is not None else None,
                        'method': self._last_mouse_wheel_method,
                    }
                )
            self._send_control_response(command, success)
        elif command == 'scroll_diagnostic':
            self._write_scroll_diagnostic(
                str(params.get('event') or 'phone_event'),
                {
                    'source': 'phone',
                    'client': params,
                },
            )
            self._send_control_response(command, True)
        elif command == 'set_scroll_mode':
            self._scroll_mode_active = params.get('active') is True
            if not self._scroll_mode_active:
                self._h265_retry_after = 0.0
            self._force_next_frame.set()
            self._write_scroll_diagnostic(
                'scroll_mode_changed',
                {
                    'source': 'desktop',
                    'active': self._scroll_mode_active,
                    'profile': self._stream_profile_id,
                    'dynamic_fps': self._dynamic_fps_limit,
                    'static_fps': self._static_fps_limit,
                },
            )
            logger.info(
                'Scroll mode changed: active=%s profile=%s dynamic_fps=%.2f static_fps=%.2f quality_scale=%.2f resolution_scale=%.2f scroll_scale=%.2f scroll_bitrate=%s scroll_fps=%.1f scroll_crf=%s scroll_vbv=%s scroll_pixfmt=%s scroll_preset=%s',
                self._scroll_mode_active,
                self._stream_profile_id,
                self._dynamic_fps_limit,
                self._static_fps_limit,
                self._stream_quality_scale,
                self._stream_resolution_scale,
                self._scroll_video_scale,
                self._scroll_video_bitrate_kbps,
                self._scroll_video_fps,
                self._scroll_video_crf,
                self._scroll_video_vbv_multiplier,
                self._scroll_video_pixel_format,
                self._scroll_video_preset,
            )
            self._send_control_response(
                command,
                True,
                {'active': self._scroll_mode_active},
            )
        elif command == 'request_video_restart':
            reason = str(params.get('reason') or 'client-request')
            force_h264 = params.get('force_h264') is not False
            restarted = self._request_video_restart(reason, force_h264=force_h264)
            self._send_control_response(
                command,
                True,
                {'restarted': restarted, 'force_h264': force_h264},
            )
        elif command == 'set_scroll_video_tuning':
            try:
                scale = float(params.get('scale', self._scroll_video_scale))
                bitrate_kbps = int(float(params.get('bitrate_kbps', self._scroll_video_bitrate_kbps)))
                fps = float(params.get('fps', self._scroll_video_fps))
                crf = str(params.get('crf', self._scroll_video_crf)).strip()
                vbv_multiplier = int(float(params.get('vbv_multiplier', self._scroll_video_vbv_multiplier)))
                pixel_format = str(params.get('pixel_format', self._scroll_video_pixel_format)).strip().lower()
                preset = str(params.get('preset', self._scroll_video_preset)).strip().lower()
                if not crf:
                    crf = self._scroll_video_crf
                if pixel_format not in {'yuv420p', 'yuv444p'}:
                    pixel_format = 'yuv420p'
                if preset not in {'ultrafast', 'superfast', 'veryfast', 'faster', 'fast'}:
                    preset = 'veryfast'
                self._scroll_video_scale = min(1.0, max(0.30, scale))
                self._scroll_video_bitrate_kbps = min(60000, max(128, bitrate_kbps))
                self._scroll_video_fps = min(60.0, max(5.0, fps))
                self._scroll_video_crf = str(min(38, max(0, int(float(crf)))))
                self._scroll_video_vbv_multiplier = min(8, max(2, vbv_multiplier))
                self._scroll_video_pixel_format = pixel_format
                self._scroll_video_preset = preset
                self._force_next_frame.set()
                logger.info(
                    'Scroll video tuning changed: scale=%.2f bitrate_kbps=%s fps=%.1f crf=%s vbv_multiplier=%s pixel_format=%s preset=%s',
                    self._scroll_video_scale,
                    self._scroll_video_bitrate_kbps,
                    self._scroll_video_fps,
                    self._scroll_video_crf,
                    self._scroll_video_vbv_multiplier,
                    self._scroll_video_pixel_format,
                    self._scroll_video_preset,
                )
                self._send_control_response(
                    command,
                    True,
                    self._scroll_video_tuning(),
                )
            except Exception as exc:
                logger.warning('Scroll video tuning update failed: %s', exc)
                self._send_control_response(command, False, self._scroll_video_tuning())
        elif command == 'set_video_paused':
            self._video_paused = params.get('paused') is True
            if not self._video_paused:
                self._force_next_frame.set()
            logger.info('Video paused changed: paused=%s', self._video_paused)
            self._send_control_response(command, True, {'paused': self._video_paused})
        elif command == 'key_press':
            key_code = params.get('key_code')
            if (self.target_hwnd or self._video_paused or self.target_mode == 'desktop') and key_code is not None:
                try:
                    key_code = int(key_code)
                    if not self._video_paused:
                        self._focus_target_window()
                    self._send_virtual_key(key_code)
                    self._request_interaction_frame_refresh()
                    self._send_control_response(command, True)
                except Exception as exc:
                    logger.error('key_press failed: %s', exc)
                    self._send_control_response(command, False)
        elif command == 'key_combo':
            key_code = params.get('key_code')
            modifiers = params.get('modifiers', [])
            if (self.target_hwnd or self._video_paused or self.target_mode == 'desktop') and key_code is not None:
                try:
                    key_code = int(key_code)
                    normalized_modifiers: list[int] = []
                    if isinstance(modifiers, list):
                        for item in modifiers:
                            try:
                                normalized_modifiers.append(int(item))
                            except Exception:
                                continue
                    if not self._video_paused:
                        self._focus_target_window()
                    if normalized_modifiers:
                        self._send_key_combo_multi(normalized_modifiers, key_code)
                    else:
                        self._send_virtual_key(key_code)
                    self._request_interaction_frame_refresh()
                    self._send_control_response(command, True)
                except Exception as exc:
                    logger.error('key_combo failed: %s', exc)
                    self._send_control_response(command, False)
        elif command == 'clear_text':
            success = self._clear_text()
            if success:
                self._request_interaction_frame_refresh()
            self._send_control_response(command, success)
        elif command == 'paste_text':
            text = params.get('text', '')
            diag_id = str(params.get('diag_id') or '')
            if diag_id:
                self._write_scroll_diagnostic(
                    'paste_text_received',
                    {
                        'diag_id': diag_id,
                        'text_length': len(str(text)),
                        'target_mode': self.target_mode,
                        'target_hwnd': self.target_hwnd,
                        'video_paused': self._video_paused,
                        'h264_client_active': self._h264_client_active,
                    },
                )
            success = self._paste_text(str(text))
            if diag_id:
                self._write_scroll_diagnostic(
                    'paste_text_executed',
                    {
                        'diag_id': diag_id,
                        'success': success,
                        'target_mode': self.target_mode,
                        'target_hwnd': self.target_hwnd,
                        'video_paused': self._video_paused,
                        'h264_client_active': self._h264_client_active,
                    },
                )
            if success:
                self._request_interaction_frame_refresh('paste_text', diag_id)
            self._send_control_response(command, success)
        elif command == 'fit_window':
            success = self._fit_window(params)
            if success:
                self._request_interaction_frame_refresh()
            self._send_control_response(command, success)
        elif command == 'restore_window':
            success = self._restore_window()
            if success:
                self._request_interaction_frame_refresh()
            self._send_control_response(command, success)
        elif command == 'set_stream_profile':
            requested = str(params.get('profile', '')).strip().lower()
            if requested in self.STREAM_PROFILES:
                self._stream_profile_id = requested
                self._reset_stream_state()
                logger.info('Stream profile changed: %s', requested)
                self._send_control_response(command, True, {'profile': requested})
            else:
                logger.warning('Unknown stream profile requested: %s', requested)
                self._send_control_response(command, False, {'profile': self._stream_profile_id})
        elif command == 'set_stream_tuning':
            try:
                quality_scale = float(params.get('quality_scale', self._stream_quality_scale))
                resolution_scale = float(params.get('resolution_scale', self._stream_resolution_scale))
                dynamic_fps_limit = float(params.get('dynamic_fps_limit', self._dynamic_fps_limit))
                static_fps_limit = float(params.get('static_fps_limit', self._static_fps_limit))
                self._stream_quality_scale = min(1.0, max(0.15, quality_scale))
                self._stream_resolution_scale = min(1.0, max(0.20, resolution_scale))
                self._dynamic_fps_limit = min(60.0, max(1.0, dynamic_fps_limit))
                self._static_fps_limit = min(60.0, max(0.2, static_fps_limit))
                self._reset_stream_state()
                logger.info(
                    'Stream tuning changed: quality_scale=%.2f resolution_scale=%.2f dynamic_fps=%.2f static_fps=%.2f',
                    self._stream_quality_scale,
                    self._stream_resolution_scale,
                    self._dynamic_fps_limit,
                    self._static_fps_limit,
                )
                self._send_control_response(
                    command,
                    True,
                    {
                        'quality_scale': self._stream_quality_scale,
                        'resolution_scale': self._stream_resolution_scale,
                        'dynamic_fps_limit': self._dynamic_fps_limit,
                        'static_fps_limit': self._static_fps_limit,
                    },
                )
            except Exception as exc:
                logger.error('set_stream_tuning failed: %s', exc)
                self._send_control_response(command, False)
        elif command == 'set_window_remark':
            try:
                hwnd = int(params.get('hwnd', 0))
                remark = str(params.get('remark', '')).strip()
                if hwnd <= 0:
                    self._send_control_response(command, False, {'message': 'invalid hwnd'})
                else:
                    if remark:
                        self._window_remarks[hwnd] = remark
                    else:
                        self._window_remarks.pop(hwnd, None)
                    self._state_store.save_window_remarks(self._window_remarks)
                    self._send_control_response(
                        command,
                        True,
                        {'hwnd': hwnd, 'remark': self._window_remarks.get(hwnd, '')},
                    )
            except Exception as exc:
                logger.error('set_window_remark failed: %s', exc)
                self._send_control_response(command, False, {'message': str(exc)})
        elif command == 'list_directory':
            try:
                payload = self._list_directory_payload(params.get('path'))
                self._send_control_response(command, True, payload)
            except Exception as exc:
                logger.error('list_directory failed: %s', exc)
                self._send_control_response(command, False, {'message': str(exc)})
        elif command == 'get_terminal_profiles':
            self._send_control_response(
                command,
                True,
                {
                    'profiles': self._get_terminal_profiles(),
                },
            )
        elif command == 'set_file_clipboard':
            success, extra = self._set_file_clipboard(
                str(params.get('mode', '')),
                [str(item) for item in params.get('paths', [])],
            )
            self._send_control_response(command, success, extra)
        elif command == 'paste_file_clipboard':
            success, extra = self._paste_file_clipboard(str(params.get('destination', '')))
            self._send_control_response(command, success, extra)
        elif command == 'create_folder':
            success, extra = self._create_folder(
                str(params.get('parent', '')),
                str(params.get('name', '')),
            )
            self._send_control_response(command, success, extra)
        elif command == 'launch_terminal':
            success, extra = self._launch_terminal(
                str(params.get('working_dir', '')),
                str(params.get('terminal_id', '')),
            )
            self._send_control_response(command, success, extra)
        elif command == 'execute_command':
            success, extra = self._execute_command(
                str(params.get('command_text', '')),
                params.get('auto_enter', True) is not False,
            )
            self._send_control_response(command, success, extra)
        elif command == 'launch_program':
            success, extra = self._launch_program(
                str(params.get('executable', '')),
                str(params.get('arguments', '')),
                str(params.get('working_dir', '')),
            )
            self._send_control_response(command, success, extra)
        elif command == 'prepare_file_download':
            success, extra = self._prepare_file_download(
                str(params.get('path', '')),
                str(params.get('client_id', '')),
            )
            self._send_control_response(command, success, extra)
        elif command == 'save_uploaded_file':
            success, extra = self._save_uploaded_file(params)
            self._send_control_response(command, success, extra)
        elif command == 'capture_region_screenshot':
            success, extra = self._capture_region_screenshot(params)
            self._send_control_response(command, success, extra)

    def _send_control_response(self, command: str, success: bool, extra: Optional[dict] = None):
        payload = {
            'type': 'control_response',
            'room_id': self.signaling.room_id,
            'command': command,
            'success': success,
        }
        if extra:
            payload.update(extra)
        self._send_peer_control(payload)

    def _show_and_activate_window(self, hwnd: int):
        if not self._is_window_available(hwnd):
            logger.debug('show_and_activate_window skipped: invalid hwnd=%s', hwnd)
            return
        # Throttle: rapid input bursts (e.g. dozens of mouse_wheel events per
        # second) used to call this function for every event, which spammed
        # the target window with SetForegroundWindow / SetWindowPos / focus
        # changes. Some receivers (notably WindowsTerminal 1.24's
        # Microsoft.Terminal.Control.dll) crash under that contention. If the
        # same hwnd was just activated within ACTIVATE_THROTTLE_SECONDS and
        # is still the foreground window, skip the heavy re-activation.
        now = time.monotonic()
        last_hwnd = getattr(self, '_last_activated_hwnd', 0)
        last_at = getattr(self, '_last_activated_at', 0.0)
        if last_hwnd == hwnd and (now - last_at) < self._ACTIVATE_THROTTLE_SECONDS:
            try:
                if ctypes.windll.user32.GetForegroundWindow() == hwnd:
                    return
            except Exception:
                pass
        attached_threads: list[tuple[int, int]] = []
        try:
            before_iconic = False
            try:
                before_iconic = bool(win32gui.IsIconic(hwnd))
            except Exception:
                pass

            try:
                fg_hwnd = ctypes.windll.user32.GetForegroundWindow()
                current_thread = ctypes.windll.kernel32.GetCurrentThreadId()
                target_thread = ctypes.windll.user32.GetWindowThreadProcessId(hwnd, None)
                fg_thread = ctypes.windll.user32.GetWindowThreadProcessId(fg_hwnd, None) if fg_hwnd else 0
                for thread_id in (fg_thread, target_thread):
                    if thread_id and thread_id != current_thread:
                        ctypes.windll.user32.AttachThreadInput(current_thread, thread_id, True)
                        attached_threads.append((current_thread, thread_id))
            except Exception:
                pass

            if before_iconic:
                try:
                    win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
                except Exception:
                    pass
                try:
                    ctypes.windll.user32.ShowWindowAsync(hwnd, win32con.SW_RESTORE)
                except Exception:
                    pass
                try:
                    ctypes.windll.user32.OpenIcon(hwnd)
                except Exception:
                    pass
            else:
                try:
                    win32gui.ShowWindow(hwnd, win32con.SW_SHOW)
                except Exception:
                    pass
                try:
                    win32gui.ShowWindow(hwnd, win32con.SW_SHOWNORMAL)
                except Exception:
                    pass

            try:
                win32gui.BringWindowToTop(hwnd)
            except Exception:
                pass
            try:
                win32gui.SetForegroundWindow(hwnd)
            except Exception:
                pass
            try:
                ctypes.windll.user32.SetActiveWindow(hwnd)
            except Exception:
                pass
            try:
                ctypes.windll.user32.SetFocus(hwnd)
            except Exception:
                pass
            try:
                ctypes.windll.user32.SetWindowPos(
                    hwnd,
                    -1,
                    0,
                    0,
                    0,
                    0,
                    0x0001 | 0x0002 | 0x0040,
                )
                ctypes.windll.user32.SetWindowPos(
                    hwnd,
                    -2,
                    0,
                    0,
                    0,
                    0,
                    0x0001 | 0x0002 | 0x0040,
                )
                ctypes.windll.user32.SetWindowPos(
                    hwnd,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x0001 | 0x0002 | 0x0040,
                )
            except Exception:
                pass
            try:
                win32gui.ShowWindow(hwnd, win32con.SW_SHOW)
            except Exception:
                pass

            after_iconic = False
            try:
                after_iconic = bool(win32gui.IsIconic(hwnd))
            except Exception:
                pass
            logger.info(
                'show_and_activate_window: hwnd=%s iconic_before=%s iconic_after=%s',
                hwnd,
                before_iconic,
                after_iconic,
            )
        except Exception as exc:
            logger.debug('show_and_activate_window failed: hwnd=%s error=%s', hwnd, exc)
        finally:
            for source_thread, target_thread in reversed(attached_threads):
                try:
                    ctypes.windll.user32.AttachThreadInput(source_thread, target_thread, False)
                except Exception:
                    pass
            self._last_activated_hwnd = hwnd
            self._last_activated_at = time.monotonic()

    def _fit_window(self, params: dict) -> bool:
        hwnd = self._require_target_window('fit-window')
        if not hwnd:
            return False

        try:
            viewport_width = max(1, int(params.get('viewport_width', 0)))
            viewport_height = max(1, int(params.get('viewport_height', 0)))
            padding = max(0, int(params.get('padding', 24)))
            if viewport_width <= 0 or viewport_height <= 0:
                return False
            aspect_ratio = viewport_width / viewport_height
            logger.info(
                'fit_window request: hwnd=%s viewport=%sx%s aspect=%.4f padding=%s',
                hwnd,
                viewport_width,
                viewport_height,
                aspect_ratio,
                padding,
            )

            if self._original_window_rect is None:
                self._original_window_rect = win32gui.GetWindowRect(hwnd)
            if self._original_client_size is None:
                client_rect = win32gui.GetClientRect(hwnd)
                self._original_client_size = (
                    max(1, client_rect[2] - client_rect[0]),
                    max(1, client_rect[3] - client_rect[1]),
                )

            current_window_rect = win32gui.GetWindowRect(hwnd)
            current_client_rect = win32gui.GetClientRect(hwnd)
            current_width = max(1, current_window_rect[2] - current_window_rect[0])
            current_height = max(1, current_window_rect[3] - current_window_rect[1])
            client_width = max(1, current_client_rect[2] - current_client_rect[0])
            client_height = max(1, current_client_rect[3] - current_client_rect[1])
            border_width = max(0, current_width - client_width)
            border_height = max(0, current_height - client_height)
            frame_space = self.capture.last_frame_space or 'client'
            if self.capture._should_force_client_space(hwnd):
                frame_space = 'client'

            screen_w = win32api.GetSystemMetrics(0)
            screen_h = win32api.GetSystemMetrics(1)

            max_window_width = max(320, screen_w - padding * 2)
            max_window_height = max(240, screen_h - padding * 2)
            max_client_width = max(160, max_window_width - border_width)
            max_client_height = max(160, max_window_height - border_height)

            TARGET_STREAM_WIDTH = 340
            WINDOW_CLIENT_WIDTH = int(round(TARGET_STREAM_WIDTH / 0.70))
            target_client_height = max(240, int(round(WINDOW_CLIENT_WIDTH / aspect_ratio)))
            target_client_width = WINDOW_CLIENT_WIDTH

            if target_client_width > max_client_width:
                ratio = max_client_width / target_client_width
                target_client_width = max_client_width
                target_client_height = max(240, int(round(target_client_height * ratio)))
            if target_client_height > max_client_height:
                ratio = max_client_height / target_client_height
                target_client_height = max_client_height
                target_client_width = max(320, int(round(target_client_width * ratio)))

            if frame_space == 'window':
                target_width = target_client_width + border_width
                target_height = target_client_height + border_height
                self._fit_target_aspect = max(0.01, target_width / max(1, target_height))
            else:
                target_width = target_client_width + border_width
                target_height = target_client_height + border_height
                self._fit_target_aspect = max(0.01, target_client_width / max(1, target_client_height))

            self._fit_target_hwnd = hwnd

            new_left = max(0, (screen_w - target_width) // 2)
            new_top = max(0, (screen_h - target_height) // 2)

            size_matches = (
                abs(current_width - target_width) <= 3
                and abs(current_height - target_height) <= 3
                and abs(client_width - target_client_width) <= 3
                and abs(client_height - target_client_height) <= 3
            )
            if size_matches:
                logger.info(
                    'Fit window skipped; size already matches target: hwnd=%s outer=%sx%s client=%sx%s viewport=%sx%s frame_space=%s',
                    hwnd,
                    current_width,
                    current_height,
                    client_width,
                    client_height,
                    viewport_width,
                    viewport_height,
                    frame_space,
                )
                return True

            self._show_and_activate_window(hwnd)
            win32gui.MoveWindow(
                hwnd,
                new_left,
                new_top,
                target_width,
                target_height,
                True,
            )
            self._reset_stream_state()
            self._defer_video_start_until_stable('fit-window')
            self._pending_terminal_scroll_bottom_hwnd = hwnd
            self._move_cursor_to_window_center(hwnd)

            logger.info(
                'Fit window outer %sx%s -> %sx%s, client %sx%s -> %sx%s, viewport=%sx%s, border=%sx%s, frame_space=%s',
                current_width,
                current_height,
                target_width,
                target_height,
                client_width,
                client_height,
                target_client_width,
                target_client_height,
                viewport_width,
                viewport_height,
                border_width,
                border_height,
                frame_space,
            )
            return True
        except Exception as exc:
            logger.error('fit_window failed: %s', exc)
            return False

    def _scroll_terminal_to_bottom_after_resize(self, hwnd: int):
        try:
            class_name = win32gui.GetClassName(hwnd)
        except Exception:
            class_name = ''
        if class_name not in {'CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass'}:
            return

        def send_end():
            try:
                self._show_and_activate_window(hwnd)
                time.sleep(0.12)
                self._send_key_combo(win32con.VK_CONTROL, win32con.VK_END)
                time.sleep(0.45)
                self._send_key_combo(win32con.VK_CONTROL, win32con.VK_END)
                self._force_next_frame.set()
                logger.info('Terminal scrolled to bottom after resize: hwnd=%s class=%s', hwnd, class_name)
            except Exception as exc:
                logger.debug('scroll terminal to bottom after resize failed: hwnd=%s error=%s', hwnd, exc)

        threading.Thread(target=send_end, daemon=True, name='terminal-scroll-bottom').start()

    def _restore_window(self) -> bool:
        hwnd = self._require_target_window('restore-window')
        if not hwnd or not self._original_window_rect:
            return False

        try:
            left, top, right, bottom = self._original_window_rect
            width = max(1, right - left)
            height = max(1, bottom - top)
            self._show_and_activate_window(hwnd)
            win32gui.MoveWindow(hwnd, left, top, width, height, True)
            self._reset_stream_state()
            self._fit_target_hwnd = None
            self._fit_target_aspect = 0.0
            self._pending_terminal_scroll_bottom_hwnd = None
            logger.info('Restored window to original rect: %s', self._original_window_rect)
            return True
        except Exception as exc:
            logger.error('restore_window failed: %s', exc)
            return False

    def _move_cursor_to_window_center(self, hwnd: int) -> bool:
        if not self._is_window_available(hwnd):
            if hwnd == self.target_hwnd:
                self._invalidate_target_window('move-cursor-center: invalid window handle')
            return False
        try:
            if self.target_mode != 'desktop':
                width, height = self._capture_dimensions(hwnd)
                self._virtual_cursor_client_pos = (max(0, width // 2), max(0, height // 2))
                return self._send_window_mouse_move(hwnd, *self._virtual_cursor_client_pos, activate_target=False)
            frame_space = self.capture.last_frame_space or 'client'
            if self.capture._should_force_client_space(hwnd):
                frame_space = 'client'
            if frame_space == 'window':
                left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            else:
                left, top, right, bottom = self.capture._client_screen_rect(hwnd)
            center_x = left + max(1, (right - left)) // 2
            center_y = top + max(1, (bottom - top)) // 2
            win32api.SetCursorPos((center_x, center_y))
            logger.info(
                'Moved cursor to window center: hwnd=%s center=(%s,%s) frame_space=%s',
                hwnd,
                center_x,
                center_y,
                frame_space,
            )
            return True
        except Exception as exc:
            logger.debug('move cursor to center failed: hwnd=%s error=%s', hwnd, exc)
            return False

    def _request_interaction_frame_refresh(self, reason: str = 'interaction', diag_id: str = ''):
        self._activate_motion_boost(0.9)
        self._force_next_frame.set()
        if diag_id:
            self._write_scroll_diagnostic(
                'interaction_frame_refresh_requested',
                {
                    'diag_id': diag_id,
                    'reason': reason,
                    'h264_client_active': self._h264_client_active,
                    'video_codec': self._video_stream_started_codec or self._video_stream_codec,
                },
            )

    def _clamp_virtual_cursor_point(self, hwnd: int, x: int, y: int) -> tuple[int, int]:
        width, height = self._capture_dimensions(hwnd)
        return (
            max(0, min(width - 1, int(x))),
            max(0, min(height - 1, int(y))),
        )

    def _window_mouse_lparam(self, x: int, y: int) -> int:
        return ((int(y) & 0xFFFF) << 16) | (int(x) & 0xFFFF)

    def _window_wheel_wparam(self, wheel_delta: int, key_flags: int = 0) -> int:
        return ((int(wheel_delta) & 0xFFFF) << 16) | (int(key_flags) & 0xFFFF)

    def _resolve_window_message_target(
        self,
        hwnd: int,
        client_x: int,
        client_y: int,
    ) -> tuple[int, int, int, int, int]:
        screen_x, screen_y = self._capture_point_to_screen(hwnd, client_x, client_y)
        target_hwnd = self._popup_target_hwnd_at_point(screen_x, screen_y) or hwnd
        local_x, local_y = win32gui.ScreenToClient(target_hwnd, (screen_x, screen_y))
        return target_hwnd, screen_x, screen_y, int(local_x), int(local_y)

    def _post_window_mouse_message(
        self,
        target_hwnd: int,
        message: int,
        wparam: int,
        local_x: int,
        local_y: int,
    ) -> bool:
        try:
            win32gui.PostMessage(
                target_hwnd,
                message,
                int(wparam),
                self._window_mouse_lparam(local_x, local_y),
            )
            return True
        except Exception as exc:
            logger.debug(
                'post window mouse message failed: hwnd=%s msg=%s error=%s',
                target_hwnd,
                message,
                exc,
            )
            return False

    def _send_window_mouse_move(self, hwnd: int, x: int, y: int, activate_target: bool = False) -> bool:
        try:
            client_x, client_y = self._clamp_virtual_cursor_point(hwnd, x, y)
            target_hwnd, screen_x, screen_y, local_x, local_y = self._resolve_window_message_target(
                hwnd,
                client_x,
                client_y,
            )
            if activate_target:
                try:
                    self._show_and_activate_window(target_hwnd)
                except Exception:
                    pass
            success = self._post_window_mouse_message(target_hwnd, win32con.WM_MOUSEMOVE, 0, local_x, local_y)
            if success:
                self._virtual_cursor_client_pos = (client_x, client_y)
            logger.info(
                'window_mouse_move: hwnd=%s target=%s client=(%s,%s) local=(%s,%s) screen=(%s,%s)',
                hwnd,
                target_hwnd,
                client_x,
                client_y,
                local_x,
                local_y,
                screen_x,
                screen_y,
            )
            return success
        except Exception as exc:
            logger.error('window mouse_move failed: hwnd=%s error=%s', hwnd, exc)
            return False

    def _move_cursor_to_client_point(self, x: int, y: int, activate_target: bool = False) -> bool:
        if self.target_mode == 'desktop':
            try:
                screen_x, screen_y = self._desktop_point_to_screen(x, y)
                win32api.SetCursorPos((screen_x, screen_y))
                return True
            except Exception as exc:
                logger.error('desktop mouse_move failed: %s', exc)
                return False
        hwnd = self._require_target_window('mouse-move')
        if not hwnd:
            return False
        return self._send_window_mouse_move(hwnd, int(x), int(y), activate_target=activate_target)

    def _move_cursor_relative(self, dx: int, dy: int) -> bool:
        if self.target_mode != 'desktop':
            hwnd = self._require_target_window('mouse-move-relative')
            if not hwnd:
                return False
            width, height = self._capture_dimensions(hwnd)
            current_x, current_y = self._virtual_cursor_client_pos or (width // 2, height // 2)
            next_x = current_x + int(dx)
            next_y = current_y + int(dy)
            return self._send_window_mouse_move(hwnd, next_x, next_y, activate_target=False)
        try:
            current_x, current_y = win32api.GetCursorPos()
            win32api.SetCursorPos((current_x + dx, current_y + dy))
            return True
        except Exception as exc:
            logger.error('mouse_move_relative failed: %s', exc)
            return False

    def _click_client_point(self, x: int, y: int, button: str) -> bool:
        try:
            if not self._move_cursor_to_client_point(x, y, activate_target=True):
                return False
            return self._click_current_cursor(button)
        except Exception as exc:
            logger.error('mouse_click failed: %s', exc)
            return False

    def _click_current_cursor(self, button: str) -> bool:
        if self.target_mode != 'desktop':
            hwnd = self._require_target_window('mouse-click-current')
            if not hwnd:
                return False
            width, height = self._capture_dimensions(hwnd)
            client_x, client_y = self._virtual_cursor_client_pos or (width // 2, height // 2)
            try:
                target_hwnd, _, _, local_x, local_y = self._resolve_window_message_target(hwnd, client_x, client_y)
                if button == 'right':
                    down_msg = win32con.WM_RBUTTONDOWN
                    up_msg = win32con.WM_RBUTTONUP
                    key_flag = win32con.MK_RBUTTON
                else:
                    down_msg = win32con.WM_LBUTTONDOWN
                    up_msg = win32con.WM_LBUTTONUP
                    key_flag = win32con.MK_LBUTTON
                down_ok = self._post_window_mouse_message(target_hwnd, down_msg, key_flag, local_x, local_y)
                up_ok = self._post_window_mouse_message(target_hwnd, up_msg, 0, local_x, local_y)
                return down_ok and up_ok
            except Exception as exc:
                logger.error('window mouse_click_current failed: %s', exc)
                return False
        try:
            down_flag = win32con.MOUSEEVENTF_LEFTDOWN
            up_flag = win32con.MOUSEEVENTF_LEFTUP
            if button == 'right':
                down_flag = win32con.MOUSEEVENTF_RIGHTDOWN
                up_flag = win32con.MOUSEEVENTF_RIGHTUP
            win32api.mouse_event(down_flag, 0, 0, 0, 0)
            win32api.mouse_event(up_flag, 0, 0, 0, 0)
            return True
        except Exception as exc:
            logger.error('mouse_click_current failed: %s', exc)
            return False

    def _mouse_wheel(self, delta: int, wheel_delta: Optional[int] = None) -> bool:
        if delta == 0 and not wheel_delta:
            return False
        normalized_wheel_delta = int(wheel_delta) if wheel_delta is not None else max(-3, min(3, delta)) * 120
        normalized_wheel_delta = max(-360, min(360, normalized_wheel_delta))
        if normalized_wheel_delta == 0:
            normalized_wheel_delta = 120 if delta > 0 else -120
        self._last_mouse_wheel_method = ''
        if not self._scroll_mode_active:
            self._scroll_mode_active = True
            self._force_next_frame.set()
        logger.info(
            'mouse_wheel requested: delta=%s scroll_mode=%s mode=%s hwnd=%s',
            delta,
            self._scroll_mode_active,
            self.target_mode,
            self.target_hwnd,
        )
        if self.target_mode == 'desktop':
            try:
                win32api.mouse_event(win32con.MOUSEEVENTF_WHEEL, 0, 0, normalized_wheel_delta, 0)
                self._force_next_frame.set()
                self._last_mouse_wheel_method = 'desktop_mouse_event'
                return True
            except Exception as exc:
                logger.error('desktop mouse_wheel failed: %s', exc)
                return False
        hwnd = self._require_target_window('mouse-wheel')
        if not hwnd:
            return False
        try:
            width, height = self._capture_dimensions(hwnd)
            client_x, client_y = self._virtual_cursor_client_pos or (width // 2, height // 2)
            target_hwnd, screen_x, screen_y, _, _ = self._resolve_window_message_target(hwnd, client_x, client_y)

            try:
                try:
                    self._show_and_activate_window(target_hwnd)
                except Exception:
                    self._show_and_activate_window(hwnd)
                win32api.SetCursorPos((screen_x, screen_y))
                win32api.mouse_event(win32con.MOUSEEVENTF_WHEEL, 0, 0, normalized_wheel_delta, 0)
                self._force_next_frame.set()
                self._last_mouse_wheel_method = 'window_mouse_event'
                return True
            except Exception as exc:
                logger.debug('window mouse_wheel native event fallback failed: hwnd=%s error=%s', hwnd, exc)

            success = bool(
                win32gui.PostMessage(
                    target_hwnd,
                    win32con.WM_MOUSEWHEEL,
                    self._window_wheel_wparam(normalized_wheel_delta),
                    self._window_mouse_lparam(screen_x, screen_y),
                )
            )
            if success:
                self._force_next_frame.set()
                self._last_mouse_wheel_method = 'post_message'
            return success
        except Exception as exc:
            logger.error('mouse_wheel failed: hwnd=%s error=%s', hwnd, exc)
            return False

    def _paste_text(self, text: str) -> bool:
        if text == '':
            return False
        try:
            normalized = text.replace('\r\n', '\n')
            for ch in normalized:
                if ch == '\n':
                    self._send_virtual_key(win32con.VK_RETURN)
                else:
                    self._send_unicode_char(ch)
            return True
        except Exception as exc:
            logger.error('paste_text failed: %s', exc)
            return False

    def _clear_text(self) -> bool:
        try:
            foreground = win32gui.GetForegroundWindow()
            class_name = win32gui.GetClassName(foreground) if foreground else ''
            if class_name == 'CASCADIA_HOSTING_WINDOW_CLASS':
                self._send_key_combo(win32con.VK_CONTROL, win32con.VK_HOME)
                time.sleep(0.03)
                self._send_key_combo(win32con.VK_CONTROL, win32con.VK_END)
            else:
                self._send_key_combo(win32con.VK_CONTROL, ord('A'))
                self._send_virtual_key(win32con.VK_DELETE)
            return True
        except Exception as exc:
            logger.error('clear_text failed: %s', exc)
            return False

    def _focus_target_window(self) -> bool:
        if self.target_mode == 'desktop':
            return True
        hwnd = self._require_target_window('focus-target')
        if not hwnd:
            return False
        try:
            foreground = 0
            try:
                foreground = win32gui.GetForegroundWindow()
            except Exception:
                foreground = 0
            if foreground == hwnd:
                return True
            self._show_and_activate_window(hwnd)
            return True
        except Exception:
            return False

    def _popup_target_hwnd_at_point(self, screen_x: int, screen_y: int) -> Optional[int]:
        hwnd = self.target_hwnd
        if not hwnd:
            return None
        try:
            popup_hwnds = self.capture._enumerate_owned_popups(hwnd)
        except Exception:
            return None
        for popup_hwnd in reversed(popup_hwnds):
            try:
                left, top, right, bottom = win32gui.GetWindowRect(popup_hwnd)
            except Exception:
                continue
            if left <= screen_x < right and top <= screen_y < bottom:
                return popup_hwnd
        return None

    def _capture_point_to_screen(self, hwnd: int, x: int, y: int) -> tuple[int, int]:
        rect = self.capture.last_capture_bounds
        if rect is None:
            frame_space = self.capture.last_frame_space
            if self.capture._should_force_client_space(hwnd):
                frame_space = 'client'
            if frame_space == 'window':
                rect = win32gui.GetWindowRect(hwnd)
            else:
                rect = self.capture._client_screen_rect(hwnd)

        frame_width, frame_height = self._last_stream_frame_size
        if frame_width <= 0 or frame_height <= 0:
            frame_width, frame_height = self.capture.last_frame_size
        target_width = max(1, rect[2] - rect[0])
        target_height = max(1, rect[3] - rect[1])
        base_width = frame_width if frame_width > 0 else target_width
        base_height = frame_height if frame_height > 0 else target_height

        mapped_x = rect[0] + round((x / max(1, base_width - 1)) * max(1, target_width - 1))
        mapped_y = rect[1] + round((y / max(1, base_height - 1)) * max(1, target_height - 1))
        return mapped_x, mapped_y

    def _capture_dimensions(self, hwnd: int) -> tuple[int, int]:
        frame_width, frame_height = self.capture.last_frame_size
        if frame_width > 0 and frame_height > 0:
            return frame_width, frame_height

        if self.capture.last_capture_bounds is not None:
            rect = self.capture.last_capture_bounds
            return max(1, rect[2] - rect[0]), max(1, rect[3] - rect[1])

        if self.capture._should_force_client_space(hwnd):
            rect = self.capture._client_screen_rect(hwnd)
        else:
            rect = win32gui.GetWindowRect(hwnd)
        return max(1, rect[2] - rect[0]), max(1, rect[3] - rect[1])

    def _desktop_point_to_screen(self, x: int, y: int) -> tuple[int, int]:
        left = win32api.GetSystemMetrics(win32con.SM_XVIRTUALSCREEN)
        top = win32api.GetSystemMetrics(win32con.SM_YVIRTUALSCREEN)
        width = max(1, win32api.GetSystemMetrics(win32con.SM_CXVIRTUALSCREEN))
        height = max(1, win32api.GetSystemMetrics(win32con.SM_CYVIRTUALSCREEN))

        frame_width, frame_height = self.capture.last_frame_size
        base_width = frame_width if frame_width > 0 else width
        base_height = frame_height if frame_height > 0 else height

        mapped_x = left + round((x / max(1, base_width - 1)) * max(1, width - 1))
        mapped_y = top + round((y / max(1, base_height - 1)) * max(1, height - 1))
        return mapped_x, mapped_y

    def _send_virtual_key(self, vk_code: int):
        extra = ctypes.c_ulong(0)
        key_down = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(wVk=vk_code, wScan=0, dwFlags=0, time=0, dwExtraInfo=ctypes.pointer(extra))
            ),
        )
        key_up = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=vk_code,
                    wScan=0,
                    dwFlags=win32con.KEYEVENTF_KEYUP,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_down), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_up), ctypes.sizeof(INPUT))

    def _send_key_combo(self, modifier_vk: int, key_vk: int):
        extra = ctypes.c_ulong(0)
        modifier_down = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=modifier_vk,
                    wScan=0,
                    dwFlags=0,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        key_down = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=key_vk,
                    wScan=0,
                    dwFlags=0,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        key_up = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=key_vk,
                    wScan=0,
                    dwFlags=win32con.KEYEVENTF_KEYUP,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        modifier_up = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=modifier_vk,
                    wScan=0,
                    dwFlags=win32con.KEYEVENTF_KEYUP,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        ctypes.windll.user32.SendInput(1, ctypes.byref(modifier_down), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_down), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_up), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(modifier_up), ctypes.sizeof(INPUT))

    def _send_key_combo_multi(self, modifier_vks: list[int], key_vk: int):
        normalized = [int(vk) for vk in modifier_vks if int(vk) > 0]
        if not normalized:
            self._send_virtual_key(key_vk)
            return
        if len(normalized) == 1:
            self._send_key_combo(normalized[0], key_vk)
            return

        extra = ctypes.c_ulong(0)
        for modifier_vk in normalized:
            modifier_down = INPUT(
                type=1,
                union=INPUT_UNION(
                    ki=KEYBDINPUT(
                        wVk=modifier_vk,
                        wScan=0,
                        dwFlags=0,
                        time=0,
                        dwExtraInfo=ctypes.pointer(extra),
                    )
                ),
            )
            ctypes.windll.user32.SendInput(1, ctypes.byref(modifier_down), ctypes.sizeof(INPUT))

        key_down = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=key_vk,
                    wScan=0,
                    dwFlags=0,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        key_up = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=key_vk,
                    wScan=0,
                    dwFlags=win32con.KEYEVENTF_KEYUP,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_down), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_up), ctypes.sizeof(INPUT))

        for modifier_vk in reversed(normalized):
            modifier_up = INPUT(
                type=1,
                union=INPUT_UNION(
                    ki=KEYBDINPUT(
                        wVk=modifier_vk,
                        wScan=0,
                        dwFlags=win32con.KEYEVENTF_KEYUP,
                        time=0,
                        dwExtraInfo=ctypes.pointer(extra),
                    )
                ),
            )
            ctypes.windll.user32.SendInput(1, ctypes.byref(modifier_up), ctypes.sizeof(INPUT))

    def _send_unicode_char(self, ch: str):
        extra = ctypes.c_ulong(0)
        key_down = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=0,
                    wScan=ord(ch),
                    dwFlags=win32con.KEYEVENTF_UNICODE,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        key_up = INPUT(
            type=1,
            union=INPUT_UNION(
                ki=KEYBDINPUT(
                    wVk=0,
                    wScan=ord(ch),
                    dwFlags=win32con.KEYEVENTF_UNICODE | win32con.KEYEVENTF_KEYUP,
                    time=0,
                    dwExtraInfo=ctypes.pointer(extra),
                )
            ),
        )
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_down), ctypes.sizeof(INPUT))
        ctypes.windll.user32.SendInput(1, ctypes.byref(key_up), ctypes.sizeof(INPUT))

    def _start_video_send_thread(self) -> None:
        alive = [t for t in self._video_send_threads if t.is_alive()]
        if alive and len(alive) == max(1, self._video_stream_count):
            return
        self._video_send_stop.set()
        for t in self._video_send_threads:
            t.join(timeout=0.5)
        self._video_send_stop.clear()
        self._video_send_threads = []
        with self._video_send_inflight_lock:
            self._video_send_inflight = 0
        count = max(1, int(self._video_stream_count))
        self._video_send_channel_queues = [queue.Queue() for _ in range(count)]

        def worker(channel_idx: int, ch_queue: "queue.Queue[tuple]") -> None:
            while not self._video_send_stop.is_set():
                try:
                    frame = ch_queue.get(timeout=0.5)
                except queue.Empty:
                    continue
                if frame is None:
                    break
                seq, payload = frame
                try:
                    if self._lan_direct_server.has_client:
                        self._lan_direct_server.send_binary_media(payload)
                    else:
                        self.signaling.send_binary_stream(channel_idx, payload)
                except Exception as exc:
                    logger.warning('Video send worker %s error: %s', channel_idx, exc)
                finally:
                    with self._video_send_inflight_lock:
                        if self._video_send_inflight > 0:
                            self._video_send_inflight -= 1

        self._send_video_stream_progress(
            stage='send_thread_started',
            progress=30,
            codec='h264',
            stage_label='视频发送线程已启动',
            force=True,
        )
        for idx in range(count):
            t = threading.Thread(
                target=worker,
                args=(idx, self._video_send_channel_queues[idx]),
                daemon=True,
                name=f'video-send-{idx}',
            )
            t.start()
            self._video_send_threads.append(t)
        # Also ensure stream channels are connected
        self.signaling.ensure_media_connected()
        self._send_video_stream_progress(
            stage='channels_ready',
            progress=35,
            codec='h264',
            stage_label='信令通道就绪',
        )

    def _video_hard_backpressured(self) -> bool:
        # Hard backpressure: the send queue / inflight buffer is actually full,
        # so a new frame would overwrite an un-sent one. This must fully skip.
        if self._lan_direct_server.has_client:
            return self._lan_direct_server.media_send_backpressured()
        with self._video_send_inflight_lock:
            return self._video_send_inflight >= max(1, int(self._video_stream_count))

    def _video_send_backpressured(self) -> bool:
        # Delay-driven gate: the client-reported media delay reflects buffering
        # in the TCP kernel send buffer / network pipe that application-level
        # inflight counters cannot observe. This is the real signal on a
        # saturated 5G uplink, so honor it first.
        if self._video_delay_backpressure_active():
            return True
        return self._video_hard_backpressured()

    def _queue_video_frame(self, seq: int, payload: bytes):
        count = max(1, int(self._video_stream_count))
        queues = getattr(self, '_video_send_channel_queues', None)
        if not queues:
            return
        channel_idx = seq % count
        with self._video_send_inflight_lock:
            self._video_send_inflight += 1
        queues[channel_idx].put((seq, payload))

    def _start_capture(self):
        self._start_video_send_thread()
        if self._capture_thread and self._capture_thread.is_alive():
            logger.info('Capture thread already running')
            return

        def loop():
            def sleep_remaining(loop_started_at: float, target_interval: float) -> None:
                elapsed = time.time() - loop_started_at
                sleep_for = max(0.001, min(0.2, target_interval - elapsed))
                time.sleep(sleep_for)

            logger.info(
                'Capture thread started: room=%s hwnd=%s title=%s profile=%s',
                self.signaling.room_id,
                self.target_hwnd,
                self.target_window_title,
                self._stream_profile_id,
            )
            try:
                while self._peer_connected():
                    loop_started_at = time.time()
                    if not self.running or not self.client_connected:
                        time.sleep(0.2)
                        continue
                    self._send_media_keepalive(loop_started_at, 'capture-loop')
                    if self._video_paused:
                        self._send_media_keepalive(loop_started_at, 'video-paused')
                        time.sleep(0.2)
                        continue
                    if self._direct_transport.video_active:
                        self._send_media_keepalive(loop_started_at, 'direct-transport-active')
                        time.sleep(0.2)
                        continue

                    profile = self._current_stream_profile()
                    loop_sleep = 0.1
                    capture_started_at = time.time()
                    hwnd = self.target_hwnd
                    if self.target_mode == 'desktop':
                        frame = self.capture.capture_desktop()
                        hwnd_for_log = None
                    elif self.target_mode == 'window':
                        hwnd = self._require_target_window('capture-loop')
                        if not hwnd:
                            sleep_remaining(loop_started_at, loop_sleep)
                            continue
                        frame = self.capture.capture_window(hwnd)
                        hwnd_for_log = hwnd
                    else:
                        sleep_remaining(loop_started_at, loop_sleep)
                        continue
                    capture_ms = (time.time() - capture_started_at) * 1000.0

                    capture_path = self.capture.last_capture_path
                    if capture_path and capture_path != self._last_capture_path:
                        self._last_capture_path = capture_path
                        logger.info(
                            'Capture path switched: hwnd=%s title=%s path=%s',
                            hwnd_for_log,
                            self.target_window_title,
                            capture_path,
                        )

                    if frame is None:
                        self._capture_empty_frames += 1
                        now = time.time()
                        self._send_media_keepalive(now, 'capture-empty')
                        if now - self._last_empty_log_at >= 2:
                            self._last_empty_log_at = now
                            logger.warning(
                                'Capture returned no frame: hwnd=%s title=%s path=%s empty_count=%s error=%s',
                                hwnd_for_log,
                                self.target_window_title,
                                self.capture.last_capture_path,
                                self._capture_empty_frames,
                                self.capture.last_capture_error,
                            )
                        sleep_remaining(loop_started_at, loop_sleep)
                        continue

                    frame = self._fit_frame_to_target_aspect(frame)
                    now = time.time()
                    captured_size = (int(frame.shape[1]), int(frame.shape[0]))
                    if self._video_start_wait_active(frame, captured_size, now):
                        self._send_media_keepalive(now, 'window-stabilizing')
                        sleep_remaining(loop_started_at, loop_sleep)
                        continue
                    diff_value = self._measure_frame_diff(frame)
                    state = self._resolve_stream_state(profile, diff_value, now)
                    self._apply_stream_state(state, profile, now)
                    encode_params = self._resolved_stream_state_params(profile, state)
                    encode_params = self._apply_video_startup_params(encode_params, now)
                    encode_params = self._apply_transport_congestion_params(encode_params, now)
                    encode_params = self._video_peak_limiter.tune_params(
                        self._stream_profile_id,
                        encode_params,
                        scroll_mode_active=False,
                        diff_value=diff_value,
                        scroll_tuning=None,
                    )
                    loop_sleep = float(encode_params.get('loop_sleep', 0.03))
                    should_send = self._should_send_frame(diff_value, encode_params, now)
                    if self._image_frame_in_flight:
                        if now - self._last_sent_at > 0.75:
                            self._image_frame_in_flight = False
                            logger.info('Image frame ACK timeout; dropping stale in-flight frame')
                        else:
                            should_send = False
                    h264_path_active = (
                        should_send
                        and now >= self._video_fallback_until
                        and self._h264_client_active
                    )
                    if h264_path_active and self._video_hard_backpressured():
                        # Transport queue is actually full; skip this capture
                        # instead of overwriting an un-sent frame. Keeps encoder
                        # running (no restart) and produces frames at the pipe's
                        # real rate.
                        should_send = False
                        self._capture_frames_skipped += 1
                        self._send_media_keepalive(now, 'video-backpressure')
                        if now - self._last_skip_log_at >= 5:
                            self._last_skip_log_at = now
                            logger.debug(
                                'Video send backpressure: inflight=%s channels=%s profile=%s',
                                self._video_send_inflight,
                                self._video_stream_count,
                                self._stream_profile_id,
                            )
                        sleep_remaining(loop_started_at, loop_sleep)
                        continue
                    self._log_stream_state(
                        now=now,
                        state_params=encode_params,
                        diff_value=diff_value,
                        should_send=should_send,
                    )
                    if not should_send:
                        self._send_media_keepalive(now, 'idle-no-frame')
                        self._capture_frames_skipped += 1
                        if now - self._last_skip_log_at >= 5:
                            self._last_skip_log_at = now
                            logger.debug(
                                'Capture skip heartbeat: skipped=%s diff=%.3f profile=%s state=%s path=%s hwnd=%s min_send_interval=%.4f loop_sleep=%.4f',
                                self._capture_frames_skipped,
                                diff_value,
                                self._stream_profile_id,
                                encode_params.get('state'),
                                capture_path,
                                hwnd_for_log,
                                float(encode_params.get('min_send_interval', 0.0)),
                                loop_sleep,
                            )
                        sleep_remaining(loop_started_at, loop_sleep)
                        continue

                    prepare_started_at = time.time()
                    prepared_frame = self._prepare_frame_for_profile(
                        frame,
                        float(encode_params.get('scale', 1.0)),
                    )
                    prepare_ms = (time.time() - prepare_started_at) * 1000.0
                    self._last_stream_frame_size = (
                        int(prepared_frame.shape[1]),
                        int(prepared_frame.shape[0]),
                    )
                    video_started_at = time.time()
                    video_fallback_active = now < self._video_fallback_until
                    if not video_fallback_active:
                        self._send_h264_frame(prepared_frame, encode_params, now)
                    video_ms = (time.time() - video_started_at) * 1000.0
                    self._capture_frames_sent += 1
                    self._last_sent_at = now
                    suppress_image_fallback = (
                        False if video_fallback_active
                        else self._should_suppress_image_fallback_for_video_transition(now)
                    )
                    send_image_fallback = (
                        video_fallback_active
                        or ((not self._h264_client_active) and not suppress_image_fallback)
                    )
                    compressed = None
                    if send_image_fallback:
                        image_started_at = time.time()
                        compressed = self._encode_frame(prepared_frame, encode_params, diff_value)
                        image_ms = (time.time() - image_started_at) * 1000.0
                        if compressed:
                            self._image_frame_in_flight = True
                            self._last_image_frame_seq += 1
                    else:
                        image_ms = 0.0
                    if send_image_fallback and not compressed:
                        logger.warning(
                            'Frame compression failed: hwnd=%s title=%s path=%s',
                            hwnd_for_log,
                            self.target_window_title,
                            capture_path,
                        )
                    if encode_params.get('static_clear_frame'):
                        self._static_clear_frame_pending = False
                    self._observe_scroll_frame_diagnostics(
                        now,
                        diff_value,
                        prepared_frame.shape[1],
                        prepared_frame.shape[0],
                        send_image_fallback,
                    )
                    if now - self._last_capture_log_at >= 5:
                        self._last_capture_log_at = now
                        logger.info(
                            'Capture heartbeat: frames=%s skipped=%s size=%sx%s bytes=%s path=%s hwnd=%s profile=%s state=%s diff=%.3f scale=%.2f q=%s png=%s fps=%.1f bitrate_kbps=%s crf=%s bufmul=%s pixfmt=%s preset=%s min_send_interval=%.4f loop_sleep=%.4f fallback=%s timing_ms=capture:%.1f prepare:%.1f video:%.1f image:%.1f loop:%.1f',
                            self._capture_frames_sent,
                            self._capture_frames_skipped,
                            prepared_frame.shape[1],
                            prepared_frame.shape[0],
                            len(compressed or b''),
                            capture_path,
                            hwnd_for_log,
                            self._stream_profile_id,
                            encode_params.get('state'),
                            diff_value,
                            float(encode_params.get('scale', 1.0)),
                            int(encode_params.get('jpeg_quality', 72)),
                            int(encode_params.get('png_compression', 2)),
                            float(encode_params.get('target_fps', 0.0)),
                            int(encode_params.get('target_bitrate_kbps') or 0),
                            str(encode_params.get('crf') or ''),
                            int(encode_params.get('bufsize_multiplier') or 0),
                            str(encode_params.get('pixel_format') or ''),
                            str(encode_params.get('preset') or ''),
                            float(encode_params.get('min_send_interval', 0.0)),
                            loop_sleep,
                            send_image_fallback,
                            capture_ms,
                            prepare_ms,
                            video_ms,
                            image_ms,
                            (time.time() - loop_started_at) * 1000.0,
                        )
                    if send_image_fallback and compressed:
                        self._send_peer_media(
                            {
                                'type': 'image_frame',
                                'room_id': self.signaling.room_id,
                                'seq': self._last_image_frame_seq,
                                'sent_at': int(now * 1000),
                                'width': prepared_frame.shape[1],
                                'height': prepared_frame.shape[0],
                                'profile': self._stream_profile_id,
                                'data': base64.b64encode(compressed).decode('ascii'),
                            }
                        )
                    self._log_process_handle_counts()
                    sleep_remaining(loop_started_at, loop_sleep)
            finally:
                logger.warning(
                    'Capture thread exiting: room=%s ws_connected=%s running=%s client_connected=%s frames=%s skipped=%s empty=%s last_path=%s last_error=%s',
                    self.signaling.room_id,
                    self.signaling.connected,
                    self.running,
                    self.client_connected,
                    self._capture_frames_sent,
                    self._capture_frames_skipped,
                    self._capture_empty_frames,
                    self.capture.last_capture_path,
                    self.capture.last_capture_error,
                )

        self._capture_thread = threading.Thread(target=loop, daemon=True, name='capture-loop')
        self._capture_thread.start()

    def _start_cursor_stream(self):
        if self._cursor_thread and self._cursor_thread.is_alive():
            logger.info('Cursor thread already running')
            return

        def loop():
            logger.info(
                'Cursor thread started: room=%s hwnd=%s title=%s',
                self.signaling.room_id,
                self.target_hwnd,
                self.target_window_title,
            )
            try:
                while self._peer_connected():
                    if not self.running or not self.client_connected:
                        time.sleep(0.1)
                        continue

                    payload = self._cursor_position_payload()
                    if payload is None:
                        time.sleep(1 / 30)
                        continue

                    visible = payload.get('visible') is True
                    should_send = False
                    if self._scroll_mode_active:
                        should_send = visible != self._last_cursor_visible
                    else:
                        should_send = visible or self._last_cursor_visible is not True
                    if should_send:
                        self._send_peer_control(payload)
                        self._cursor_updates_sent += 1
                        now = time.time()
                        if now - self._last_cursor_log_at >= 5:
                            self._last_cursor_log_at = now
                            logger.debug(
                                'Cursor heartbeat: updates=%s visible=%s x=%.4f y=%.4f hwnd=%s',
                                self._cursor_updates_sent,
                                visible,
                                float(payload.get('x', 0.0)),
                                float(payload.get('y', 0.0)),
                                self.target_hwnd,
                            )
                        self._log_process_handle_counts()
                    self._last_cursor_visible = visible
                    time.sleep(1 / 30)
            finally:
                logger.warning(
                    'Cursor thread exiting: room=%s ws_connected=%s running=%s client_connected=%s updates=%s',
                    self.signaling.room_id,
                    self.signaling.connected,
                    self.running,
                    self.client_connected,
                    self._cursor_updates_sent,
                )

        self._cursor_thread = threading.Thread(target=loop, daemon=True, name='cursor-loop')
        self._cursor_thread.start()

    def _run_connection_loop(self, window_title: Optional[str] = None):
        windows = self._list_windows()
        logger.info('Found %s windows', len(windows))
        for index, item in enumerate(windows[:10], 1):
            logger.info('%s. [%s]', index, item['title'].encode('unicode_escape').decode('ascii'))

        if window_title:
            for item in windows:
                if window_title.lower() in item['title'].lower():
                    self.target_hwnd = item['hwnd']
                    self.target_window_title = item['title']
                    logger.info(
                        'Preselected window: [%s]',
                        item['title'].encode('unicode_escape').decode('ascii'),
                    )
                    break

        reconnect_delay_seconds = 2
        while not self._stop_requested.is_set():
            resolved_host, resolved_port, resolved_route = self._resolve_signaling_endpoint()
            if resolved_route == 'unconfigured' or not resolved_host or resolved_port <= 0:
                # No signaling server configured yet. The desktop UI lets the
                # user add one; until they do, idle politely and keep checking
                # so the connection starts as soon as configuration arrives.
                self._current_signaling_route = 'unconfigured'
                self._set_ui_status('未配置信令服务器，请进入设置添加')
                self._refresh_ui_snapshot()
                self._stop_requested.wait(2)
                continue
            route_label = '局域网' if resolved_route == 'lan' else '外网'
            if (resolved_host, resolved_port) != (self.server, self.port):
                logger.info(
                    'Switch signaling endpoint: %s:%s -> %s:%s (%s)',
                    self.server,
                    self.port,
                    resolved_host,
                    resolved_port,
                    resolved_route,
                )
            self.server = resolved_host
            self.port = resolved_port
            self.signaling.host = resolved_host
            self.signaling.port = resolved_port
            self._current_signaling_route = resolved_route
            self._set_ui_status(f'正在连接{route_label}服务器：{resolved_host}:{resolved_port}')
            self._refresh_ui_snapshot()
            if self.signaling.connect(metadata=self._build_metadata()):
                if self.signaling.room_id != self._persistent_room_id:
                    self._persistent_room_id = self.signaling.room_id
                    try:
                        state = self._state_store.read()
                        state['room_id'] = self._persistent_room_id
                        self._state_store.write(state)
                    except Exception:
                        pass
                logger.info('Waiting for remote connection...')
                self._set_ui_status('已连接服务器，等待配对或控制连接')
                self._refresh_ui_snapshot()
                self._start_windows_update_check()
                try:
                    while self.signaling.connected and not self._stop_requested.is_set():
                        self.signaling.ensure_media_connected()
                        if self._maybe_switch_to_lan_endpoint():
                            break
                        if self._endpoints_changed_event.is_set():
                            self._endpoints_changed_event.clear()
                            logger.info('Signaling endpoints changed; reconnecting to apply')
                            break
                        time.sleep(1)
                except KeyboardInterrupt:
                    self._stop_requested.set()
                    break

            if self._stop_requested.is_set():
                break

            self.signaling.disconnect()
            self.client_connected = False
            self.running = False
            self.capture.release_window_resources(self.target_hwnd)
            self._set_ui_status(f'与服务器断开，{reconnect_delay_seconds} 秒后自动重连')
            self._refresh_ui_snapshot()
            logger.warning(
                'Signaling disconnected, retrying in %s seconds',
                reconnect_delay_seconds,
            )
            self._stop_requested.wait(reconnect_delay_seconds)

        self.signaling.disconnect()
        logger.info('Exited')

    def run(self, window_title: Optional[str] = None):
        logger.info('PocketWindow agent starting')
        if not self._acquire_single_instance_lock():
            logger.warning('another desktop agent instance is already running')
            return
        try:
            self._stop_requested.clear()
            self._ensure_lan_probe_server()
            self._lan_direct_server.start()
            self._start_duplicate_instance_watchdog()
            connection_thread = threading.Thread(
                target=self._run_connection_loop,
                args=(window_title,),
                daemon=True,
                name='agent-connection',
            )
            connection_thread.start()
            self._create_ui()
        finally:
            self._stop_requested.set()
            self.running = False
            self.client_connected = False
            self.signaling.disconnect()
            self._lan_direct_server.stop()
            self._stop_lan_probe_server()
            self.capture.release_window_resources(self.target_hwnd)
            self._release_single_instance_lock()


def main():
    parser = argparse.ArgumentParser()
    # All endpoint arguments are optional now. The desktop UI is the source
    # of truth via agent_state.json; CLI flags only seed an empty configuration
    # so existing automation (daemon scripts, packaged shortcuts) keeps working
    # the first time it runs against this build.
    parser.add_argument('--server', '-s', default=None,
                        help='Optional seed host for a primary signaling endpoint '
                             '(used only if no endpoints are saved yet)')
    parser.add_argument('--port', '-p', type=int, default=None)
    parser.add_argument('--fallback-server', default=None,
                        help='Optional seed host for a secondary signaling endpoint')
    parser.add_argument('--fallback-port', type=int, default=None)
    parser.add_argument('--window', '-w', default=None)
    args = parser.parse_args()

    agent = PocketWindowAgent('', 0)

    saved = agent._state_store.load_signaling_endpoints()
    if saved:
        agent.set_preferred_endpoints(saved)
    else:
        seeds: list[dict] = []
        if args.server:
            port = int(args.port or DEFAULT_SIGNALING_PORT_PLAIN)
            seeds.append({
                'name': '主服务器',
                'url': f'ws://{args.server}:{port}',
                'priority': 0,
            })
        if args.fallback_server:
            port = int(args.fallback_port or DEFAULT_SIGNALING_PORT_PLAIN)
            seeds.append({
                'name': '备用服务器',
                'url': f'ws://{args.fallback_server}:{port}',
                'priority': 10,
            })
        # If neither agent state nor CLI provided any seed, fall back to the
        # built-in defaults so a fresh install can connect out of the box.
        if not seeds:
            seeds = [dict(entry) for entry in BUILTIN_SEED_ENDPOINTS]
        agent.update_signaling_endpoints(seeds)

    agent.run(args.window)


if __name__ == '__main__':
    main()
