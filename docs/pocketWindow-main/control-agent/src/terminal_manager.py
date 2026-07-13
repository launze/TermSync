"""Terminal streaming module for PocketWindow agent.

Creates and manages local ConPTY sessions (PowerShell / cmd) on the desktop and
streams their raw byte output (including all ANSI escape sequences) to the mobile
client over the existing control channel. The mobile side renders the bytes with
xterm.dart, producing a pixel-identical terminal.

This module is fully decoupled from the video / remote-control logic: it only
needs a callback to push control-channel payloads to the peer.

Ownership model (V2):
- Sessions are owned by the desktop agent and live for the lifetime of the
  process. The session id and title are generated on the desktop, never by the
  phone.
- The phone can `list` active sessions, `attach` to one (gets a snapshot and the
  live stream), `detach` (stops watching, PTY keeps running) or `create` a new
  session (the desktop actually spawns it).
- A session is only destroyed on an explicit `close` (from phone or desktop).
- The desktop GUI can also render / create / close sessions via the same
  manager (see desktop_agent_ui.py), so terminals are visible on the desktop.

Design notes (validated by research):
- winpty PtyProcess.read() blocks; therefore every session reads in its own
  daemon thread and never blocks the agent main loop.
- Bytes are forwarded verbatim (base64) - never line-processed, transcoded or
  stripped - so styling renders identically on the phone.
- A pyte screen always mirrors the PTY at the same size, so a full-screen
  snapshot can be produced for attach/reconnect and for desktop GUI rendering.
"""

from __future__ import annotations

import base64
import logging
import threading
import time
import uuid
from typing import Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

try:
    from winpty import PtyProcess  # type: ignore
    _WINPTY_AVAILABLE = True
except Exception as exc:  # pragma: no cover - environment dependent
    PtyProcess = None  # type: ignore
    _WINPTY_AVAILABLE = False
    logger.warning('winpty unavailable, terminal feature disabled: %s', exc)

try:
    import pyte  # type: ignore
    _PYTE_AVAILABLE = True
except Exception as exc:  # pragma: no cover - environment dependent
    pyte = None  # type: ignore
    _PYTE_AVAILABLE = False
    logger.info('pyte unavailable, terminal snapshot/desktop-render disabled: %s', exc)


MAX_SESSIONS = 5
DEFAULT_COLS = 80
DEFAULT_ROWS = 24
READ_CHUNK = 8192
SCROLLBACK_LINES = 3000

_SHELL_COMMANDS = {
    'powershell': 'powershell.exe -NoLogo',
    'pwsh': 'pwsh.exe -NoLogo',
    'cmd': 'cmd.exe',
}

_SHELL_LABELS = {
    'powershell': 'PowerShell',
    'pwsh': 'PowerShell Core',
    'cmd': 'cmd',
}


def available_shells() -> List[str]:
    """Shell keys the desktop is willing to spawn (order = display order)."""
    return ['powershell', 'pwsh', 'cmd']


def _resolve_shell(shell: Optional[str]) -> str:
    key = (shell or 'powershell').strip().lower()
    return _SHELL_COMMANDS.get(key, _SHELL_COMMANDS['powershell'])


def _normalize_shell(shell: Optional[str]) -> str:
    key = (shell or 'powershell').strip().lower()
    return key if key in _SHELL_COMMANDS else 'powershell'


def _clamp_dim(value, fallback: int) -> int:
    try:
        v = int(value)
    except (TypeError, ValueError):
        return fallback
    return max(1, min(1000, v))


class TerminalSession:
    """A single ConPTY session with its own reader thread and pyte mirror."""

    def __init__(
        self,
        session_id: str,
        shell: str,
        title: str,
        cols: int,
        rows: int,
        on_data: Callable[[str, int, bytes], None],
        on_exit: Callable[[str], None],
    ) -> None:
        self.session_id = session_id
        self.shell = shell
        self.title = title
        self.cols = cols
        self.rows = rows
        self.attached = False
        self._on_data = on_data
        self._on_exit = on_exit
        self._seq = 0
        self._closed = False
        self._lock = threading.RLock()

        cmd = _resolve_shell(shell)
        self._proc = PtyProcess.spawn(cmd, dimensions=(rows, cols))

        if _PYTE_AVAILABLE:
            # HistoryScreen keeps a scrollback buffer so the phone can scroll
            # up to earlier output after attaching.
            self._screen = pyte.HistoryScreen(cols, rows, history=SCROLLBACK_LINES, ratio=0.5)
            self._stream = pyte.ByteStream(self._screen)
        else:
            self._screen = None
            self._stream = None

        self._reader = threading.Thread(
            target=self._read_loop,
            name=f'terminal-{session_id}',
            daemon=True,
        )
        self._reader.start()
        logger.info('Terminal session created: id=%s shell=%s size=%sx%s', session_id, shell, cols, rows)

    def _read_loop(self) -> None:
        while not self._closed:
            try:
                data = self._proc.read(READ_CHUNK)
            except EOFError:
                break
            except Exception as exc:
                logger.debug('Terminal read error: id=%s error=%s', self.session_id, exc)
                break
            if not data:
                if not self._proc.isalive():
                    break
                time.sleep(0.02)
                continue
            raw = data.encode('utf-8', 'surrogatepass') if isinstance(data, str) else bytes(data)
            if b'\x1b[?1049h' in raw or b'\x1b[?1049l' in raw or b'\x1b[?47h' in raw or b'\x1b[?47l' in raw:
                logger.info('SEQDIAG id=%s ALTSCREEN h1049=%s l1049=%s h47=%s l47=%s',
                            self.session_id,
                            raw.count(b'\x1b[?1049h'), raw.count(b'\x1b[?1049l'),
                            raw.count(b'\x1b[?47h'), raw.count(b'\x1b[?47l'))
            if self._stream is not None:
                try:
                    self._stream.feed(raw)
                except Exception:
                    pass
            with self._lock:
                self._seq += 1
                seq = self._seq
            try:
                self._on_data(self.session_id, seq, raw)
            except Exception as exc:
                logger.debug('Terminal on_data callback error: id=%s error=%s', self.session_id, exc)
        self._handle_exit()

    def _handle_exit(self) -> None:
        if self._closed:
            return
        self._closed = True
        logger.info('Terminal session exited: id=%s', self.session_id)
        try:
            self._on_exit(self.session_id)
        except Exception:
            pass

    @property
    def closed(self) -> bool:
        return self._closed

    def write(self, data: bytes) -> None:
        if self._closed:
            return
        try:
            self._proc.write(data.decode('utf-8', 'surrogatepass') if isinstance(data, (bytes, bytearray)) else data)
        except Exception as exc:
            logger.debug('Terminal write error: id=%s error=%s', self.session_id, exc)

    def resize(self, cols: int, rows: int) -> None:
        if self._closed:
            return
        self.cols = cols
        self.rows = rows
        try:
            self._proc.setwinsize(rows, cols)
        except Exception as exc:
            logger.debug('Terminal resize error: id=%s error=%s', self.session_id, exc)
        if self._screen is not None:
            try:
                self._screen.resize(rows, cols)
            except Exception:
                pass

    def snapshot_bytes(self) -> Optional[bytes]:
        """Return scrollback history + current screen for attach/reconnect.

        History lines are emitted as plain text (no color) so the phone's
        xterm scrollback is populated; the current visible screen follows.
        """
        if self._screen is None:
            return None
        try:
            cols = self._screen.columns
            display = self._screen.display
        except Exception:
            return None
        parts = [b'\x1b[2J\x1b[H']

        # Scrollback history (rows that scrolled off the top).
        history = getattr(self._screen, 'history', None)
        if history is not None:
            try:
                for row in list(history.top):
                    line = ''.join(row[x].data for x in range(cols)).rstrip()
                    parts.append(line.encode('utf-8', 'replace'))
                    parts.append(b'\r\n')
            except Exception:
                pass

        # Current visible screen.
        for idx, line in enumerate(display):
            parts.append(line.encode('utf-8', 'replace'))
            if idx < len(display) - 1:
                parts.append(b'\r\n')
        return b''.join(parts)

    def screen_text(self) -> str:
        """Plain-text screen mirror for the desktop GUI (no ANSI)."""
        if self._screen is None:
            return ''
        try:
            return '\n'.join(self._screen.display)
        except Exception:
            return ''

    def screen_cells(self) -> Optional[list]:
        """Structured colored screen for the desktop GUI.

        Returns a list of rows; each row is a list of runs, where a run is
        (text, fg, bg, bold, reverse). Colors are pyte color names / 'default'
        / hex. None when pyte is unavailable.
        """
        if self._screen is None:
            return None
        try:
            buffer = self._screen.buffer
            cols = self._screen.columns
            rows = self._screen.lines
        except Exception:
            return None
        result = []
        for y in range(rows):
            line = buffer[y]
            runs = []
            cur_text = []
            cur_key = None
            for x in range(cols):
                cell = line[x]
                data = cell.data or ' '
                reverse = bool(cell.reverse)
                key = (cell.fg, cell.bg, bool(cell.bold), reverse)
                if key != cur_key:
                    if cur_text:
                        runs.append((''.join(cur_text),) + cur_key)
                    cur_text = [data]
                    cur_key = key
                else:
                    cur_text.append(data)
            if cur_text:
                runs.append((''.join(cur_text),) + cur_key)
            result.append(runs)
        return result

    def info(self) -> dict:
        return {
            'id': self.session_id,
            'shell': self.shell,
            'title': self.title,
            'cols': self.cols,
            'rows': self.rows,
            'attached': self.attached,
        }

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._proc.terminate(force=True)
        except Exception:
            pass
        logger.info('Terminal session closed: id=%s', self.session_id)


class TerminalManager:
    """Owns all terminal sessions and routes terminal.* control messages.

    Sessions are owned by the desktop and persist until an explicit close. The
    optional `on_change` callback fires whenever the session set or its state
    changes, so the desktop GUI can refresh its view.
    """

    def __init__(
        self,
        send_control: Callable[[dict], bool],
        on_change: Optional[Callable[[], None]] = None,
    ) -> None:
        self._send_control = send_control
        self._on_change = on_change
        self._sessions: Dict[str, TerminalSession] = {}
        self._lock = threading.RLock()
        self._counter = 0

    @property
    def available(self) -> bool:
        return _WINPTY_AVAILABLE

    def set_on_change(self, callback: Optional[Callable[[], None]]) -> None:
        self._on_change = callback

    def _notify_change(self) -> None:
        cb = self._on_change
        if cb is None:
            return
        try:
            cb()
        except Exception as exc:
            logger.debug('Terminal on_change error: %s', exc)

    # ---- message routing -------------------------------------------------

    def handle(self, command: str, params: dict) -> None:
        if command == 'terminal.list':
            self._list(params)
        elif command == 'terminal.create':
            self._create_remote(params)
        elif command == 'terminal.attach':
            self._attach(params)
        elif command == 'terminal.detach':
            self._detach(params)
        elif command == 'terminal.input':
            self._input(params)
        elif command == 'terminal.scroll':
            self._scroll(params)
        elif command == 'terminal.resize':
            self._resize(params)
        elif command == 'terminal.close':
            self._close(params)

    def _list(self, params: dict) -> None:
        self._send_control({
            'type': 'control',
            'command': 'terminal.sessions',
            'params': {
                'shells': available_shells(),
                'sessions': self.list_sessions(),
            },
        })

    def _create_remote(self, params: dict) -> None:
        shell = _normalize_shell(params.get('shell'))
        cols = _clamp_dim(params.get('cols'), DEFAULT_COLS)
        rows = _clamp_dim(params.get('rows'), DEFAULT_ROWS)
        session_id, error = self.create(shell, cols, rows)
        if session_id is None:
            self._send_control({
                'type': 'control',
                'command': 'terminal.created',
                'params': {'session_id': '', 'ok': False, 'error': error},
            })
            return
        session = self._sessions.get(session_id)
        self._send_control({
            'type': 'control',
            'command': 'terminal.created',
            'params': {
                'session_id': session_id,
                'ok': True,
                'shell': shell,
                'cols': cols,
                'rows': rows,
                'title': session.title if session else shell,
            },
        })

    def _attach(self, params: dict) -> None:
        session_id = str(params.get('session_id') or '')
        session = self._sessions.get(session_id)
        if session is None:
            self._send_control({
                'type': 'control',
                'command': 'terminal.close',
                'params': {'session_id': session_id, 'reason': 'not_found'},
            })
            return
        cols = _clamp_dim(params.get('cols'), session.cols)
        rows = _clamp_dim(params.get('rows'), session.rows)
        prev_rows = session.rows
        hist_before = 0
        try:
            h = getattr(session._screen, 'history', None)
            hist_before = len(list(h.top)) if h is not None else -1
        except Exception:
            hist_before = -2
        session.resize(cols, rows)
        session.attached = True
        self._notify_change()
        hist_after = 0
        try:
            h = getattr(session._screen, 'history', None)
            hist_after = len(list(h.top)) if h is not None else -1
        except Exception:
            hist_after = -2
        snap = session.snapshot_bytes()
        snap_len = len(snap) if snap is not None else -1
        logger.info(
            'ATTACH id=%s req=%sx%s prev_rows=%s hist_before=%s hist_after=%s snap_bytes=%s',
            session_id, cols, rows, prev_rows, hist_before, hist_after, snap_len,
        )
        if snap is not None:
            try:
                text = snap.decode('utf-8', 'replace')
                lines = text.split('\n')
                logger.info('ATTACH-SNAP id=%s line_count=%s', session_id, len(lines))
                for i, ln in enumerate(lines):
                    logger.info('ATTACH-SNAP id=%s L%03d |%s', session_id, i, ln.rstrip('\r')[:200])
            except Exception as exc:
                logger.info('ATTACH-SNAP dump failed: %s', exc)
            # The snapshot (scrollback history + current screen) can be large
            # (tens of KB). Some control channels (e.g. WebRTC data channels)
            # cap a single message around 16 KB, which would silently truncate
            # or drop a big snapshot and lose the history. Send it in ordered
            # chunks the phone reassembles via its streaming UTF-8 decoder.
            chunk_size = 4096
            total = len(snap)
            sent_chunks = 0
            if total <= chunk_size:
                self._send_control({
                    'type': 'control',
                    'command': 'terminal.snapshot',
                    'params': {
                        'session_id': session_id,
                        'cols': session.cols,
                        'rows': session.rows,
                        'b64': base64.b64encode(snap).decode('ascii'),
                    },
                })
                sent_chunks = 1
            else:
                for offset in range(0, total, chunk_size):
                    part = snap[offset:offset + chunk_size]
                    self._send_control({
                        'type': 'control',
                        'command': 'terminal.snapshot',
                        'params': {
                            'session_id': session_id,
                            'cols': session.cols,
                            'rows': session.rows,
                            'b64': base64.b64encode(part).decode('ascii'),
                            'chunk': offset // chunk_size,
                            'final': offset + chunk_size >= total,
                        },
                    })
                    sent_chunks += 1
            logger.info('ATTACH id=%s sent snapshot chunks=%s total_bytes=%s', session_id, sent_chunks, total)

    def _detach(self, params: dict) -> None:
        session_id = str(params.get('session_id') or '')
        session = self._sessions.get(session_id)
        if session is None:
            return
        session.attached = False
        self._notify_change()

    def _input(self, params: dict) -> None:
        session_id = str(params.get('session_id') or '')
        b64 = params.get('b64')
        if not session_id or not b64:
            return
        session = self._sessions.get(session_id)
        if session is None:
            return
        try:
            data = base64.b64decode(b64)
        except Exception:
            return
        session.write(data)

    def _scroll(self, params: dict) -> None:
        """Drive the program's own scrollback by injecting mouse-wheel events.

        Full-screen TUIs (opencode / claude / etc.) keep their conversation
        history in their *own* internal viewport, not in terminal scrollback --
        the user scrolls it on the desktop with the mouse wheel and the program
        repaints. We reproduce that exactly: the phone's swipe becomes SGR
        mouse-wheel sequences written to the PTY, the program scrolls and
        repaints, and the new frame goes back via terminal.screen. This is a
        1:1 match with the desktop, with no self-built history to get wrong.

        params: {session_id, direction: 'up'|'down', lines: int}
        SGR wheel: ESC[<64;col;rowM = wheel up, ESC[<65;col;rowM = wheel down.
        """
        session_id = str(params.get('session_id') or '')
        session = self._sessions.get(session_id)
        if session is None:
            return
        direction = str(params.get('direction') or 'up').lower()
        try:
            lines = int(params.get('lines') or 3)
        except Exception:
            lines = 3
        lines = max(1, min(lines, 100))
        # Aim the wheel near the middle of the screen so it lands on the
        # scrollable content region rather than the fixed status bar.
        col = max(1, session.cols // 2)
        row = max(1, session.rows // 2)
        button = 64 if direction == 'up' else 65
        seq = ('\x1b[<%d;%d;%dM' % (button, col, row)).encode('ascii')
        for _ in range(lines):
            session.write(seq)

    def _resize(self, params: dict) -> None:
        session_id = str(params.get('session_id') or '')
        session = self._sessions.get(session_id)
        if session is None:
            return
        cols = _clamp_dim(params.get('cols'), session.cols)
        rows = _clamp_dim(params.get('rows'), session.rows)
        session.resize(cols, rows)
        self._notify_change()

    def _close(self, params: dict) -> None:
        session_id = str(params.get('session_id') or '')
        self.close(session_id)

    # ---- public API (used by message routing AND desktop GUI) -----------

    def create(self, shell: str, cols: int, rows: int) -> tuple:
        """Spawn a new session owned by the desktop. Returns (session_id, error)."""
        if not _WINPTY_AVAILABLE:
            return None, 'winpty unavailable'
        with self._lock:
            if len(self._sessions) >= MAX_SESSIONS:
                return None, 'too many sessions'
            shell = _normalize_shell(shell)
            cols = _clamp_dim(cols, DEFAULT_COLS)
            rows = _clamp_dim(rows, DEFAULT_ROWS)
            self._counter += 1
            session_id = 'pty-' + uuid.uuid4().hex[:8]
            title = '{} #{}'.format(_SHELL_LABELS.get(shell, shell), self._counter)
            try:
                session = TerminalSession(
                    session_id, shell, title, cols, rows,
                    on_data=self._emit_data,
                    on_exit=self._emit_exit,
                )
            except Exception as exc:
                logger.warning('Terminal create failed: shell=%s error=%s', shell, exc)
                return None, str(exc)
            self._sessions[session_id] = session
        self._notify_change()
        return session_id, None

    def close(self, session_id: str) -> None:
        with self._lock:
            session = self._sessions.pop(session_id, None)
        if session is not None:
            session.close()
            self._send_control({
                'type': 'control',
                'command': 'terminal.close',
                'params': {'session_id': session_id, 'reason': 'closed'},
            })
            self._notify_change()

    def list_sessions(self) -> List[dict]:
        with self._lock:
            return [s.info() for s in self._sessions.values()]

    def available_shells(self) -> List[str]:
        return available_shells()

    def shell_labels(self) -> Dict[str, str]:
        return dict(_SHELL_LABELS)

    def get_screen_text(self, session_id: str) -> str:
        session = self._sessions.get(session_id)
        return session.screen_text() if session is not None else ''

    def get_screen_cells(self, session_id: str):
        session = self._sessions.get(session_id)
        return session.screen_cells() if session is not None else None

    # ---- internal callbacks ---------------------------------------------

    def _emit_data(self, session_id: str, seq: int, raw: bytes) -> None:
        session = self._sessions.get(session_id)
        # pyte is always fed in the reader thread; only stream to the phone
        # when a client is attached (saves bandwidth when only desktop watches).
        if session is not None and not session.attached:
            return
        self._send_control({
            'type': 'control',
            'command': 'terminal.data',
            'params': {
                'session_id': session_id,
                'seq': seq,
                'b64': base64.b64encode(raw).decode('ascii'),
            },
        })

    def _emit_exit(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)
        self._send_control({
            'type': 'control',
            'command': 'terminal.close',
            'params': {'session_id': session_id, 'reason': 'exited'},
        })
        self._notify_change()

    def close_all(self) -> None:
        with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            session.close()
        self._notify_change()
