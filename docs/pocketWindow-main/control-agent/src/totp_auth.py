"""TOTP-based shared-secret authenticator for LAN/public direct transport.

Design:
- Single-file slot module so it can be replaced with HMAC/JWT/mTLS later
  without touching the HTTP/WS server code.
- 30-second TOTP window, ±1 step tolerance (effective accept window 90s).
- Optional nonce list to defeat replay inside the same time step.

Wire format (request side):
- Client appends two query parameters or two WebSocket join_room fields:
    code   = 6-digit current TOTP value (string)
    nonce  = random 16+ char string, unique within the same minute

This module is intentionally dependency-free (stdlib only) so PyInstaller
packaging does not need an extra requirement.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import struct
import threading
import time
from collections import deque
from typing import Deque, Optional, Tuple


_TOTP_STEP_SECONDS = 30
_TOTP_DIGITS = 6
_REPLAY_WINDOW_SECONDS = 120
_MAX_REPLAY_ENTRIES = 4096


def generate_secret() -> str:
    """Return a fresh base32-encoded TOTP secret (160-bit)."""
    raw = secrets.token_bytes(20)
    return base64.b32encode(raw).rstrip(b'=').decode('ascii')


def _decode_secret(secret: str) -> bytes:
    cleaned = (secret or '').strip().replace(' ', '').upper()
    if not cleaned:
        raise ValueError('totp secret is empty')
    padding = '=' * (-len(cleaned) % 8)
    return base64.b32decode(cleaned + padding, casefold=True)


def _hotp(secret_bytes: bytes, counter: int, digits: int = _TOTP_DIGITS) -> str:
    msg = struct.pack('>Q', counter)
    digest = hmac.new(secret_bytes, msg, hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    truncated = (
        ((digest[offset] & 0x7F) << 24)
        | ((digest[offset + 1] & 0xFF) << 16)
        | ((digest[offset + 2] & 0xFF) << 8)
        | (digest[offset + 3] & 0xFF)
    )
    code = truncated % (10 ** digits)
    return str(code).zfill(digits)


def current_code(secret: str, at_time: Optional[float] = None) -> str:
    secret_bytes = _decode_secret(secret)
    now = time.time() if at_time is None else float(at_time)
    counter = int(now // _TOTP_STEP_SECONDS)
    return _hotp(secret_bytes, counter)


def verify_code(
    secret: str,
    code: str,
    *,
    at_time: Optional[float] = None,
    tolerance_steps: int = 1,
) -> bool:
    """Verify ``code`` against ``secret`` allowing ±tolerance_steps drift."""
    if not code:
        return False
    cleaned_code = str(code).strip()
    if len(cleaned_code) != _TOTP_DIGITS or not cleaned_code.isdigit():
        return False
    try:
        secret_bytes = _decode_secret(secret)
    except Exception:
        return False
    now = time.time() if at_time is None else float(at_time)
    counter = int(now // _TOTP_STEP_SECONDS)
    for offset in range(-int(tolerance_steps), int(tolerance_steps) + 1):
        expected = _hotp(secret_bytes, counter + offset)
        if hmac.compare_digest(expected, cleaned_code):
            return True
    return False


class TotpAuthenticator:
    """Verify TOTP code + nonce uniqueness for direct transport endpoints.

    Thread-safe; intended to be instantiated once per LanDirectServer.
    """

    def __init__(self, secret_getter):
        self._secret_getter = secret_getter
        self._lock = threading.Lock()
        self._seen: Deque[Tuple[float, str]] = deque()

    def secret(self) -> str:
        try:
            value = self._secret_getter() or ''
        except Exception:
            value = ''
        return str(value).strip()

    def is_configured(self) -> bool:
        return bool(self.secret())

    def verify(self, code: str, nonce: str) -> Tuple[bool, str]:
        secret = self.secret()
        if not secret:
            return False, 'totp_not_configured'
        if not verify_code(secret, code):
            return False, 'invalid_code'
        nonce_value = (nonce or '').strip()
        if len(nonce_value) < 8:
            return False, 'invalid_nonce'
        now = time.time()
        with self._lock:
            cutoff = now - _REPLAY_WINDOW_SECONDS
            while self._seen and self._seen[0][0] < cutoff:
                self._seen.popleft()
            for _, used in self._seen:
                if hmac.compare_digest(used, nonce_value):
                    return False, 'replay'
            if len(self._seen) >= _MAX_REPLAY_ENTRIES:
                self._seen.popleft()
            self._seen.append((now, nonce_value))
        return True, ''


__all__ = [
    'generate_secret',
    'current_code',
    'verify_code',
    'TotpAuthenticator',
]
