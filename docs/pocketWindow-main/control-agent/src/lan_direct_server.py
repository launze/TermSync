from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import queue
import socket
import socketserver
import struct
import threading
import time
import urllib.parse
from typing import Callable, Optional


logger = logging.getLogger('PocketWindowAgent')

_WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class _LanDirectHttpServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler_class, owner: 'LanDirectServer'):
        super().__init__(server_address, handler_class)
        self.owner = owner


class _LanDirectHandler(socketserver.BaseRequestHandler):
    def handle(self):
        owner: LanDirectServer = self.server.owner
        channel = ''
        try:
            # New-IP gate runs once per TCP connection. Returning False
            # before any HTTP parsing means we never even leak a 4xx
            # response shape to the scanner.
            if not owner._allow_peer(self.request):
                return
            request = self._read_http_request()
            if not request:
                return
            channel = self._accept_websocket(owner, request)
            if not channel:
                return
            owner.attach(channel, self.request)
            while not owner.stopped:
                payload = self._read_frame()
                if payload is None:
                    break
                if isinstance(payload, bytes):
                    continue
                try:
                    data = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                owner.handle_message(channel, data)
        except Exception as exc:
            logger.debug('LAN direct handler stopped: channel=%s error=%s', channel, exc)
        finally:
            if channel:
                owner.detach(channel, self.request)

    def _accept_websocket(self, owner: 'LanDirectServer', request: tuple[str, bytes]) -> str:
        header_text, body_prefix = request
        lines = header_text.split('\r\n')
        request_line = lines[0].split()
        if len(request_line) < 2:
            return ''
        method = request_line[0].upper()
        parsed_url = urllib.parse.urlparse(request_line[1])
        path = parsed_url.path
        headers = {}
        for line in lines[1:]:
            if ':' not in line:
                continue
            key, value = line.split(':', 1)
            headers[key.strip().lower()] = value.strip()
        if path.startswith('/file/'):
            self._handle_file_request(owner, method, parsed_url, headers, body_prefix)
            return ''
        if path != '/ws':
            self.request.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
            return ''
        key = headers.get('sec-websocket-key', '')
        if not key:
            self.request.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n')
            return ''
        accept = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode('ascii')).digest()).decode('ascii')
        response = (
            'HTTP/1.1 101 Switching Protocols\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            f'Sec-WebSocket-Accept: {accept}\r\n'
            '\r\n'
        )
        self.request.sendall(response.encode('ascii'))
        join = self._read_frame()
        if not isinstance(join, str):
            return ''
        data = json.loads(join)
        if data.get('type') != 'join_room' or data.get('role') != 'client':
            return ''
        if str(data.get('device_id') or '').strip() != owner.device_id:
            self._send_json({'type': 'error', 'message': 'device_id mismatch'})
            return ''
        # TOTP gate: when a TOTP secret is configured the join must carry
        # a fresh code+nonce pair. The slot is keyed on the public-direct
        # flag so the LAN flow can keep using its existing trust-based
        # check without forcing every LAN user through TOTP enrollment.
        if owner._totp_auth.is_configured():
            totp_code = str(data.get('totp_code') or '').strip()
            totp_nonce = str(data.get('totp_nonce') or '').strip()
            ok, reason = owner._totp_auth.verify(totp_code, totp_nonce)
            if not ok:
                logger.warning(
                    'LAN direct TOTP rejected: reason=%s channel=%s',
                    reason,
                    self._peer_label(),
                )
                self._send_json({'type': 'error', 'message': f'totp_{reason}'})
                return ''
        channel = str(data.get('channel') or 'control').strip()
        if channel not in {'control', 'media'} and not channel.startswith('stream-'):
            channel = 'control'
        owner.client_id = str(data.get('client_id') or '').strip()
        owner.client_name = str(data.get('client_name') or '').strip()
        if not owner._trusted_client_checker(owner.client_id):
            self._send_json({'type': 'error', 'message': 'client is not trusted'})
            return ''
        self._send_json({
            'type': 'room_joined',
            'room_id': owner.room_id,
            'role': 'client',
            'channel': channel,
            'lan_direct': True,
        })
        self.request.settimeout(None)
        if channel == 'control':
            owner.send_control({
                'type': 'remote_connected',
                'role': 'agent',
                'channel': 'control',
                'lan_direct': True,
            })
        return channel

    def _peer_label(self) -> str:
        try:
            peer = self.request.getpeername()
            if isinstance(peer, tuple) and peer:
                return f'{peer[0]}:{peer[1]}'
            return str(peer)
        except Exception:
            return 'unknown'

    def _authorize_http_request(self, owner: 'LanDirectServer', query: dict[str, list[str]]) -> bool:
        device_id = (query.get('device_id') or [''])[0].strip()
        client_id = (query.get('client_id') or [''])[0].strip()
        if device_id != owner.device_id or not client_id:
            self._send_http_json(403, {'message': 'device_id or client_id is invalid'})
            return False
        if not owner._trusted_client_checker(client_id):
            self._send_http_json(403, {'message': 'client is not trusted'})
            return False
        return True

    def _send_http_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        reason = {
            200: 'OK',
            400: 'Bad Request',
            403: 'Forbidden',
            404: 'Not Found',
            413: 'Payload Too Large',
            500: 'Internal Server Error',
        }.get(status, 'OK')
        header = (
            f'HTTP/1.1 {status} {reason}\r\n'
            'Content-Type: application/json; charset=utf-8\r\n'
            f'Content-Length: {len(body)}\r\n'
            'Connection: close\r\n'
            '\r\n'
        ).encode('ascii')
        self.request.sendall(header + body)

    def _handle_file_request(
        self,
        owner: 'LanDirectServer',
        method: str,
        parsed_url: urllib.parse.ParseResult,
        headers: dict[str, str],
        body_prefix: bytes,
    ) -> None:
        query = urllib.parse.parse_qs(parsed_url.query, keep_blank_values=True)
        if not self._authorize_http_request(owner, query):
            return
        if parsed_url.path == '/file/download' and method == 'GET':
            self._handle_file_download(owner, query)
            return
        if parsed_url.path == '/file/upload' and method == 'POST':
            self._handle_file_upload(query, headers, body_prefix)
            return
        self.request.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')

    def _is_path_under_whitelist(self, owner: 'LanDirectServer', file_path: str) -> bool:
        whitelist = owner._download_whitelist_getter() or []
        if not whitelist:
            return False
        try:
            normalized_target = os.path.normcase(os.path.normpath(os.path.abspath(file_path)))
        except Exception:
            return False
        for entry in whitelist:
            try:
                normalized_root = os.path.normcase(os.path.normpath(os.path.abspath(os.path.expandvars(str(entry)))))
            except Exception:
                continue
            if not normalized_root:
                continue
            # Ensure the trailing separator so "C:/share" does not match
            # "C:/shared".
            root_with_sep = normalized_root.rstrip(os.sep) + os.sep
            if normalized_target == normalized_root or normalized_target.startswith(root_with_sep):
                return True
        return False

    def _handle_file_download(self, owner: 'LanDirectServer', query: dict[str, list[str]]) -> None:
        raw_path = (query.get('path') or [''])[0]
        file_path = os.path.abspath(os.path.expandvars(raw_path))
        if not file_path or not os.path.exists(file_path):
            self._send_http_json(404, {'message': 'file not found'})
            return
        if not os.path.isfile(file_path):
            self._send_http_json(400, {'message': 'folders are not supported'})
            return
        if not self._is_path_under_whitelist(owner, file_path):
            logger.warning(
                'LAN direct file download denied by whitelist: path=%s peer=%s',
                file_path,
                self._peer_label(),
            )
            self._send_http_json(403, {'message': 'path not in download whitelist'})
            return
        file_size = os.path.getsize(file_path)
        file_name = os.path.basename(file_path) or 'download.bin'
        header = (
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/octet-stream\r\n'
            f'Content-Length: {file_size}\r\n'
            f'Content-Disposition: attachment; filename="{urllib.parse.quote(file_name)}"\r\n'
            'Connection: close\r\n'
            '\r\n'
        ).encode('ascii')
        try:
            self.request.sendall(header)
            with open(file_path, 'rb') as file:
                while True:
                    chunk = file.read(1024 * 1024)
                    if not chunk:
                        break
                    self.request.sendall(chunk)
        except Exception as exc:
            logger.warning('LAN direct file download failed: path=%s error=%s', file_path, exc)

    def _handle_file_upload(
        self,
        query: dict[str, list[str]],
        headers: dict[str, str],
        body_prefix: bytes,
    ) -> None:
        destination = os.path.abspath(os.path.expandvars((query.get('destination') or [''])[0]))
        file_name = os.path.basename((query.get('file_name') or ['upload.bin'])[0]) or 'upload.bin'
        declared_size = int((query.get('file_size') or ['0'])[0] or 0)
        content_length = int(headers.get('content-length') or 0)
        total_size = declared_size or content_length
        max_size = 1024 * 1024 * 1024
        if not destination or not os.path.isdir(destination):
            self._send_http_json(400, {'message': 'destination folder not found'})
            return
        if total_size <= 0:
            self._send_http_json(400, {'message': 'file is empty'})
            return
        if total_size > max_size:
            self._send_http_json(413, {'message': 'file too large'})
            return
        target_path = os.path.join(destination, file_name)
        if os.path.exists(target_path):
            name, ext = os.path.splitext(file_name)
            for index in range(1, 1000):
                candidate = os.path.join(destination, f'{name} ({index}){ext}')
                if not os.path.exists(candidate):
                    target_path = candidate
                    break
            else:
                self._send_http_json(500, {'message': 'cannot allocate file name'})
                return
        received = 0
        # The connection-setup read in _read_http_request set a short 5s socket
        # timeout that lingers on this socket. For a large upload (e.g. a 50MB
        # MP3 over a slow 5G uplink) the body read would hit that 5s deadline and
        # abort with a timeout, deleting the partial file and returning 500.
        # Reset to a generous per-recv idle timeout: it only fires if NO data
        # arrives for this long, not on total transfer duration.
        try:
            self.request.settimeout(120)
        except Exception:
            pass
        try:
            with open(target_path, 'wb') as file:
                if body_prefix:
                    initial = body_prefix[:total_size]
                    file.write(initial)
                    received += len(initial)
                while received < total_size:
                    chunk = self.request.recv(min(1024 * 1024, total_size - received))
                    if not chunk:
                        break
                    file.write(chunk)
                    received += len(chunk)
            if received != total_size:
                try:
                    os.remove(target_path)
                except Exception:
                    pass
                self._send_http_json(400, {'message': 'uploaded file is incomplete'})
                return
            self._send_http_json(200, {
                'message': f'已保存到电脑: {target_path}',
                'path': target_path,
                'file_name': os.path.basename(target_path),
                'size': received,
            })
        except Exception as exc:
            logger.warning('LAN direct file upload failed: destination=%s error=%s', destination, exc)
            try:
                if os.path.exists(target_path):
                    os.remove(target_path)
            except Exception:
                pass
            self._send_http_json(500, {'message': str(exc)})

    def _read_http_request(self) -> Optional[tuple[str, bytes]]:
        data = bytearray()
        self.request.settimeout(5)
        while b'\r\n\r\n' not in data and len(data) < 16384:
            chunk = self.request.recv(1024)
            if not chunk:
                break
            data.extend(chunk)
        marker = data.find(b'\r\n\r\n')
        if marker < 0:
            return None
        header = bytes(data[:marker]).decode('iso-8859-1', errors='ignore')
        body_prefix = bytes(data[marker + 4:])
        return header, body_prefix

    def _read_exact(self, length: int) -> Optional[bytes]:
        data = bytearray()
        while len(data) < length:
            chunk = self.request.recv(length - len(data))
            if not chunk:
                return None
            data.extend(chunk)
        return bytes(data)

    def _read_frame(self) -> Optional[str | bytes]:
        header = self._read_exact(2)
        if not header:
            return None
        first, second = header
        opcode = first & 0x0F
        masked = (second & 0x80) != 0
        length = second & 0x7F
        if length == 126:
            ext = self._read_exact(2)
            if not ext:
                return None
            length = struct.unpack('!H', ext)[0]
        elif length == 127:
            ext = self._read_exact(8)
            if not ext:
                return None
            length = struct.unpack('!Q', ext)[0]
        mask = self._read_exact(4) if masked else b''
        payload = self._read_exact(length)
        if payload is None:
            return None
        if masked and mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            self._send_frame(payload, opcode=0xA)
            return b''
        if opcode == 0x1:
            return payload.decode('utf-8', errors='replace')
        if opcode == 0x2:
            return payload
        return b''

    def _send_json(self, payload: dict) -> bool:
        return self._send_frame(json.dumps(payload, ensure_ascii=False).encode('utf-8'), opcode=0x1)

    def _send_frame(self, payload: bytes, opcode: int) -> bool:
        try:
            header = bytearray([0x80 | opcode])
            length = len(payload)
            if length < 126:
                header.append(length)
            elif length <= 0xFFFF:
                header.append(126)
                header.extend(struct.pack('!H', length))
            else:
                header.append(127)
                header.extend(struct.pack('!Q', length))
            self.request.sendall(bytes(header) + payload)
            return True
        except OSError:
            return False


class LanDirectServer:
    def __init__(
        self,
        host: str,
        port: int,
        *,
        device_id: str,
        room_id_getter: Callable[[], str],
        trusted_client_checker: Callable[[str], bool],
        on_message: Callable[[dict], None],
        totp_secret_getter: Optional[Callable[[], str]] = None,
        new_ip_approver: Optional[Callable[[str, dict], bool]] = None,
        download_whitelist_getter: Optional[Callable[[], list]] = None,
        known_ips_getter: Optional[Callable[[], list]] = None,
        known_ips_recorder: Optional[Callable[[str], None]] = None,
        is_new_ip_check_enabled: Optional[Callable[[], bool]] = None,
    ):
        self.host = host
        self.port = port
        self.device_id = device_id
        self._room_id_getter = room_id_getter
        self._trusted_client_checker = trusted_client_checker
        self._on_message = on_message
        # Lazy import keeps the LAN direct server importable in tests
        # without the TOTP slot being available.
        from totp_auth import TotpAuthenticator
        self._totp_auth = TotpAuthenticator(totp_secret_getter or (lambda: ''))
        self._new_ip_approver = new_ip_approver
        self._download_whitelist_getter = download_whitelist_getter or (lambda: [])
        self._known_ips_getter = known_ips_getter or (lambda: [])
        self._known_ips_recorder = known_ips_recorder or (lambda ip: None)
        self._is_new_ip_check_enabled = is_new_ip_check_enabled or (lambda: False)
        self._server: Optional[_LanDirectHttpServer] = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._sockets: dict[str, socket.socket] = {}
        self.client_id = ''
        self.client_name = ''
        self._active_control_client_id = ''
        self.stopped = False
        self._media_send_queue: "queue.Queue[Optional[bytes]]" = queue.Queue()
        self._media_send_thread: Optional[threading.Thread] = None
        self._media_send_stop = threading.Event()
        self._media_queue_max = 3
        self._media_inflight = 0
        self._media_dropped_stale = 0
        self._media_inflight_lock = threading.Lock()

    @property
    def room_id(self) -> str:
        return self._room_id_getter()

    @property
    def has_client(self) -> bool:
        with self._lock:
            return bool(self._sockets.get('control'))

    def _peer_ip(self, sock) -> str:
        try:
            peer = sock.getpeername()
            if isinstance(peer, tuple) and peer:
                return str(peer[0])
        except Exception:
            pass
        return ''

    def _allow_peer(self, sock) -> bool:
        """New-IP gate. When the public-direct mode is on, an unknown
        remote address must be approved by the user before any payload is
        parsed. Returning False causes the handler to drop the
        connection silently — no banner leak to scanners.
        """
        if not self._is_new_ip_check_enabled():
            return True
        ip = self._peer_ip(sock)
        if not ip:
            return True
        known = self._known_ips_getter() or []
        if ip in known:
            return True
        if self._new_ip_approver is None:
            return True
        try:
            approved = bool(self._new_ip_approver(ip, {'ip': ip}))
        except Exception as exc:
            logger.warning('new_ip_approver raised: %s', exc)
            return False
        if approved:
            try:
                self._known_ips_recorder(ip)
            except Exception as exc:
                logger.warning('known_ips_recorder raised: %s', exc)
        return approved

    def start(self) -> bool:
        if self._server is not None:
            return True
        try:
            self._server = _LanDirectHttpServer((self.host, self.port), _LanDirectHandler, self)
        except OSError as exc:
            logger.warning('Failed to start LAN direct server on %s:%s: %s', self.host, self.port, exc)
            return False
        self.stopped = False
        self._media_send_stop.clear()
        with self._media_inflight_lock:
            self._media_inflight = 0
        try:
            while True:
                self._media_send_queue.get_nowait()
        except queue.Empty:
            pass
        self._media_send_thread = threading.Thread(
            target=self._media_send_loop,
            daemon=True,
            name='lan-direct-media-send',
        )
        self._media_send_thread.start()
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            daemon=True,
            name='lan-direct-ws',
        )
        self._thread.start()
        logger.info('LAN direct WebSocket server listening on %s:%s', self.host, self.port)
        return True

    def stop(self) -> None:
        self.stopped = True
        self._media_send_stop.set()
        try:
            self._media_send_queue.put_nowait(None)
        except Exception:
            pass
        server = self._server
        self._server = None
        if server is not None:
            try:
                server.shutdown()
                server.server_close()
            except Exception:
                pass
        with self._lock:
            sockets = list(self._sockets.values())
            self._sockets.clear()
        for item in sockets:
            try:
                item.close()
            except Exception:
                pass

    def attach(self, channel: str, sock: socket.socket) -> None:
        should_notify_connected = False
        current_client_id = self.client_id
        current_client_name = self.client_name
        with self._lock:
            old = self._sockets.get(channel)
            self._sockets[channel] = sock
            if channel == 'control':
                should_notify_connected = self._active_control_client_id != current_client_id
                self._active_control_client_id = current_client_id
        if old is not None and old is not sock:
            try:
                old.close()
            except Exception:
                pass
        peer_ip = self._peer_ip(sock)
        logger.info('LAN direct client attached: channel=%s client_id=%s peer_ip=%s', channel, self.client_id, peer_ip)
        if channel == 'control' and should_notify_connected:
            self.handle_message('control', {
                'type': 'remote_connected',
                'role': 'client',
                'client_id': current_client_id,
                'client_name': current_client_name,
                'channel': 'control',
                'lan_direct': True,
            })
        elif channel == 'control':
            logger.info('LAN direct control attach: client_id=%s', current_client_id)

    def detach(self, channel: str, sock: socket.socket) -> None:
        removed = False
        client_id = self.client_id
        media_sock: Optional[socket.socket] = None
        with self._lock:
            if self._sockets.get(channel) is sock:
                self._sockets.pop(channel, None)
                removed = True
                if channel == 'control':
                    self._active_control_client_id = ''
                    media_sock = self._sockets.pop('media', None)
        if removed:
            peer_ip = self._peer_ip(sock)
            logger.info('LAN direct client detached: channel=%s peer_ip=%s', channel, peer_ip)
            if channel == 'control':
                if media_sock is not None:
                    try:
                        media_sock.close()
                    except Exception:
                        pass
                self.handle_message('control', {
                    'type': 'remote_disconnected',
                    'role': 'client',
                    'client_id': client_id,
                    'channel': 'control',
                    'reason': 'lan_direct_disconnected',
                    'lan_direct': True,
                })

    def handle_message(self, channel: str, data: dict) -> None:
        data['_lan_direct'] = True
        data['_client_ws_channel'] = channel
        self._on_message(data)

    def send_control(self, payload: dict) -> bool:
        return self._send('control', json.dumps(payload, ensure_ascii=False).encode('utf-8'), opcode=0x1)

    def send_media(self, payload: dict) -> bool:
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        if self._send('media', body, opcode=0x1):
            return True
        return self._send('control', body, opcode=0x1)

    def media_send_backpressured(self) -> bool:
        # No longer used to skip captures: send_binary_media now applies a
        # latest-frame-wins drop policy, so the capture loop should keep
        # producing fresh frames and let the queue discard stale ones. Always
        # report False so we never starve the pipe of new content.
        return False

    def send_binary_media(self, payload: bytes) -> bool:
        # Enqueue for the dedicated send thread so a slow/blocking socket
        # (e.g. weak 5G link via frpc) never stalls the capture loop.
        #
        # Latest-frame-wins: on a slow link the queue would otherwise fill with
        # STALE frames, so when the link briefly frees up we ship an old picture
        # while the newest frame waits at the tail. That is exactly the "screen
        # frozen / lagging behind" symptom. Instead, when the queue is full we
        # drop the oldest queued frame and enqueue the newest one, keeping the
        # pipe carrying only fresh content.
        with self._media_inflight_lock:
            while self._media_inflight >= self._media_queue_max:
                try:
                    self._media_send_queue.get_nowait()
                    self._media_dropped_stale += 1
                    if self._media_inflight > 0:
                        self._media_inflight -= 1
                except queue.Empty:
                    break
            self._media_inflight += 1
        self._media_send_queue.put(payload)
        return True

    def _media_send_loop(self) -> None:
        while not self._media_send_stop.is_set():
            try:
                payload = self._media_send_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            if payload is None:
                break
            try:
                self._send('media', payload, opcode=0x2)
            finally:
                with self._media_inflight_lock:
                    if self._media_inflight > 0:
                        self._media_inflight -= 1

    def _send(self, channel: str, payload: bytes, opcode: int) -> bool:
        with self._lock:
            sock = self._sockets.get(channel)
        if sock is None:
            return False
        try:
            header = bytearray([0x80 | opcode])
            length = len(payload)
            if length < 126:
                header.append(length)
            elif length <= 0xFFFF:
                header.append(126)
                header.extend(struct.pack('!H', length))
            else:
                header.append(127)
                header.extend(struct.pack('!Q', length))
            sock.sendall(bytes(header) + payload)
            return True
        except OSError as exc:
            logger.warning('LAN direct send failed: channel=%s bytes=%s error=%s', channel, len(payload), exc)
            with self._lock:
                if self._sockets.get(channel) is sock:
                    self._sockets.pop(channel, None)
            return False
