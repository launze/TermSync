import socket
import threading
import time
import urllib.parse
import uuid
from typing import Optional

import requests


DEFAULT_SIGNALING_PORT_PLAIN = 80
DEFAULT_SIGNALING_PORT_TLS = 443

_ENDPOINT_HEALTH_CACHE: dict[tuple[str, int], tuple[float, bool]] = {}
_ENDPOINT_HEALTH_TTL_SECONDS = 5.0
_ENDPOINT_HEALTH_LOCK = threading.Lock()


def can_reach_endpoint(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def verify_signaling_endpoint(
    host: str,
    port: int,
    tcp_timeout: float = 1.0,
    http_timeout: float = 1.5,
    use_cache: bool = True,
) -> bool:
    """Return True only when host:port is a real PocketWindow signaling server."""
    key = (str(host or '').strip(), int(port))
    if not key[0] or key[1] <= 0:
        return False
    now = time.time()
    if use_cache:
        with _ENDPOINT_HEALTH_LOCK:
            cached = _ENDPOINT_HEALTH_CACHE.get(key)
        if cached and (now - cached[0]) < _ENDPOINT_HEALTH_TTL_SECONDS:
            return cached[1]

    if not can_reach_endpoint(host, port, timeout=tcp_timeout):
        with _ENDPOINT_HEALTH_LOCK:
            _ENDPOINT_HEALTH_CACHE[key] = (now, False)
        return False

    ok = False
    bracketed = host
    if ':' in bracketed and not bracketed.startswith('['):
        bracketed = f'[{bracketed}]'
    url = f'http://{bracketed}:{port}/api/health'
    try:
        response = requests.get(url, timeout=http_timeout)
        if 200 <= response.status_code < 300:
            try:
                payload = response.json()
                if isinstance(payload, dict) and str(payload.get('status') or '').lower() == 'ok':
                    ok = True
            except ValueError:
                ok = False
    except requests.RequestException:
        ok = False

    with _ENDPOINT_HEALTH_LOCK:
        _ENDPOINT_HEALTH_CACHE[key] = (now, ok)
    return ok


def invalidate_endpoint_health_cache(host: Optional[str] = None, port: Optional[int] = None) -> None:
    with _ENDPOINT_HEALTH_LOCK:
        if host is None or port is None:
            _ENDPOINT_HEALTH_CACHE.clear()
            return
        _ENDPOINT_HEALTH_CACHE.pop((str(host).strip(), int(port)), None)


def resolve_host_ipv4_addresses(host: str, timeout: float = 1.5) -> list[str]:
    raw = str(host or '').strip()
    if not raw:
        return []
    result: list[str] = []
    error_box: list[BaseException] = []

    def _worker():
        try:
            for info in socket.getaddrinfo(raw, None, socket.AF_INET):
                sockaddr = info[4]
                if sockaddr and sockaddr[0]:
                    ip = str(sockaddr[0]).strip()
                    if ip and ip not in result:
                        result.append(ip)
        except OSError as exc:
            error_box.append(exc)

    thread = threading.Thread(target=_worker, daemon=True, name='dns-resolve')
    thread.start()
    thread.join(timeout)
    if thread.is_alive() or error_box:
        return []
    return result


def is_private_ipv4(value: str) -> bool:
    parts = value.split('.')
    if len(parts) != 4:
        return False
    try:
        nums = [int(part) for part in parts]
    except ValueError:
        return False
    if any(num < 0 or num > 255 for num in nums):
        return False
    return (
        nums[0] == 10
        or (nums[0] == 172 and 16 <= nums[1] <= 31)
        or (nums[0] == 192 and nums[1] == 168)
    )


def is_private_host(value: str) -> bool:
    host = str(value or '').strip().lower()
    return host in {'localhost', '127.0.0.1'} or is_private_ipv4(host)


def parse_signaling_url(url: str) -> Optional[tuple[str, str, int]]:
    raw = str(url or '').strip()
    if not raw:
        return None
    if '://' not in raw:
        raw = 'ws://' + raw
    try:
        parsed = urllib.parse.urlparse(raw)
    except Exception:
        return None
    scheme = (parsed.scheme or 'ws').lower()
    if scheme in ('http', 'wss'):
        scheme = 'wss' if scheme == 'wss' else 'ws'
    if scheme == 'https':
        scheme = 'wss'
    host = (parsed.hostname or '').strip()
    if not host:
        return None
    port = parsed.port
    if port is None:
        port = DEFAULT_SIGNALING_PORT_TLS if scheme == 'wss' else DEFAULT_SIGNALING_PORT_PLAIN
    return scheme, host, int(port)


def normalize_signaling_endpoint(item) -> Optional[dict]:
    if isinstance(item, dict):
        url = str(item.get('url') or '').strip()
        if not url and item.get('host'):
            host = str(item.get('host') or '').strip()
            try:
                port = int(item.get('port') or DEFAULT_SIGNALING_PORT_PLAIN)
            except Exception:
                port = DEFAULT_SIGNALING_PORT_PLAIN
            url = f'ws://{host}:{port}'
        if not url:
            return None
        parsed = parse_signaling_url(url)
        if parsed is None:
            return None
        scheme, host, port = parsed
        try:
            priority = int(item.get('priority') or 0)
        except Exception:
            priority = 0
        return {
            'id': str(item.get('id') or '').strip() or uuid.uuid4().hex,
            'name': str(item.get('name') or '').strip() or f'{host}:{port}',
            'url': f'{scheme}://{host}:{port}',
            'host': host,
            'port': port,
            'scheme': scheme,
            'priority': priority,
            'enabled': bool(item.get('enabled', True)),
            'created_at': int(item.get('created_at') or 0),
        }
    if isinstance(item, (tuple, list)) and len(item) >= 2:
        host = str(item[0] or '').strip()
        try:
            port = int(item[1])
        except Exception:
            return None
        if not host or port <= 0:
            return None
        return normalize_signaling_endpoint({'host': host, 'port': port})
    return None
