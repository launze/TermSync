import json
import logging
import os
import time
import uuid
from typing import Optional


class AgentStateStore:
    def __init__(self, state_path: str, logger: Optional[logging.Logger] = None):
        self._state_path = state_path
        self._logger = logger or logging.getLogger(__name__)

    def read(self) -> dict:
        try:
            if os.path.exists(self._state_path):
                with open(self._state_path, 'r', encoding='utf-8') as file:
                    data = json.load(file)
                if isinstance(data, dict):
                    return data
        except Exception as exc:
            self._logger.warning('Failed to read agent state: %s', exc)
        return {}

    def write(self, data: dict):
        with open(self._state_path, 'w', encoding='utf-8') as file:
            json.dump(data, file, ensure_ascii=False, indent=2)

    def load_or_create_device_id(self) -> str:
        state = self.read()
        try:
            device_id = str(state.get('device_id') or '').strip()
            if device_id:
                return device_id
        except Exception:
            pass

        device_id = f'pwdev-{uuid.uuid4().hex}'
        try:
            state['device_id'] = device_id
            if 'trusted_clients' not in state:
                state['trusted_clients'] = []
            if 'window_remarks' not in state:
                state['window_remarks'] = {}
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to persist agent state: %s', exc)
        return device_id

    def load_or_create_room_id(self) -> str:
        state = self.read()
        try:
            room_id = str(state.get('room_id') or '').strip()
            if room_id:
                return room_id
        except Exception:
            pass

        room_id = f'pw-{uuid.uuid4().hex[:8]}'
        try:
            state['room_id'] = room_id
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to persist room id: %s', exc)
        return room_id

    def load_trusted_clients(self) -> list[dict]:
        state = self.read()
        raw = state.get('trusted_clients')
        if not isinstance(raw, list):
            return []

        deduped: dict[str, dict] = {}
        for item in raw:
            if not isinstance(item, dict):
                continue
            client_id = str(item.get('client_id') or '').strip()
            if not client_id:
                continue
            current = {
                'client_id': client_id,
                'client_name': str(item.get('client_name') or '未命名手机').strip() or '未命名手机',
                'linked_at': int(item.get('linked_at') or 0),
                'last_connected_at': int(item.get('last_connected_at') or 0),
            }
            previous = deduped.get(client_id)
            if previous is None:
                deduped[client_id] = current
                continue
            previous_name = str(previous.get('client_name') or '').strip()
            current_name = str(current.get('client_name') or '').strip()
            if (not previous_name or set(previous_name) == {'?'}) and current_name:
                previous['client_name'] = current_name
            previous['linked_at'] = min(
                value for value in [int(previous.get('linked_at') or 0), int(current.get('linked_at') or 0)] if value > 0
            ) if any(value > 0 for value in [int(previous.get('linked_at') or 0), int(current.get('linked_at') or 0)]) else 0
            previous['last_connected_at'] = max(
                int(previous.get('last_connected_at') or 0),
                int(current.get('last_connected_at') or 0),
            )

        clients = list(deduped.values())
        clients.sort(key=lambda item: (int(item.get('linked_at') or 0), item['client_id']))
        return clients

    def save_trusted_clients(self, device_id: str, trusted_clients: list[dict]):
        try:
            state = self.read()
            state['device_id'] = device_id
            state['trusted_clients'] = trusted_clients
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to save trusted clients: %s', exc)

    def remember_trusted_client(
        self,
        trusted_clients: list[dict],
        client_id: str,
        client_name: str,
    ) -> bool:
        client_id = client_id.strip()
        if not client_id:
            return False
        name = client_name.strip() or '未命名手机'
        now_ts = int(time.time())
        for item in trusted_clients:
            if item['client_id'] == client_id:
                item['client_name'] = name
                item['linked_at'] = item.get('linked_at') or now_ts
                return True
        trusted_clients.append(
            {
                'client_id': client_id,
                'client_name': name,
                'linked_at': now_ts,
                'last_connected_at': 0,
            }
        )
        trusted_clients.sort(key=lambda item: item['linked_at'])
        return True

    def mark_trusted_client_connected(
        self,
        trusted_clients: list[dict],
        client_id: Optional[str],
    ) -> bool:
        if not client_id:
            return False
        now_ts = int(time.time())
        for item in trusted_clients:
            if item['client_id'] == client_id:
                item['last_connected_at'] = now_ts
                return True
        return False

    def load_window_remarks(self) -> dict[int, str]:
        state = self.read()
        raw = state.get('window_remarks')
        if not isinstance(raw, dict):
            return {}
        remarks: dict[int, str] = {}
        for key, value in raw.items():
            try:
                hwnd = int(key)
            except Exception:
                continue
            remark = str(value or '').strip()
            if remark:
                remarks[hwnd] = remark
        return remarks

    def save_window_remarks(self, window_remarks: dict[int, str]):
        try:
            state = self.read()
            serialized = {
                str(int(hwnd)): str(remark).strip()
                for hwnd, remark in window_remarks.items()
                if str(remark).strip()
            }
            state['window_remarks'] = serialized
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to save window remarks: %s', exc)

    def load_desktop_theme(self) -> str:
        state = self.read()
        theme = str(state.get('desktop_theme') or 'classic').strip().lower()
        return theme if theme in {'classic', 'mabinogi'} else 'classic'

    def save_desktop_theme(self, theme: str):
        normalized = str(theme).strip().lower()
        if normalized not in {'classic', 'mabinogi'}:
            normalized = 'classic'
        state = self.read()
        state['desktop_theme'] = normalized
        self.write(state)

    def load_ignored_windows_update_version(self) -> str:
        state = self.read()
        return str(state.get('ignored_windows_update_version') or '').strip()

    def save_ignored_windows_update_version(self, version: str):
        state = self.read()
        state['ignored_windows_update_version'] = str(version or '').strip()
        self.write(state)

    def load_signaling_endpoints(self) -> list[dict]:
        """Return the saved signaling endpoint list (may be empty).

        Each entry has: id, name, url, priority, enabled. Invalid entries are
        silently filtered so the caller never has to defend against malformed
        state.
        """
        state = self.read()
        raw = state.get('signaling_endpoints')
        if not isinstance(raw, list):
            return []
        results: list[dict] = []
        seen_ids: set[str] = set()
        for item in raw:
            if not isinstance(item, dict):
                continue
            url = str(item.get('url') or '').strip()
            if not url:
                continue
            entry_id = str(item.get('id') or '').strip()
            if not entry_id or entry_id in seen_ids:
                entry_id = uuid.uuid4().hex
            seen_ids.add(entry_id)
            try:
                priority = int(item.get('priority') or 0)
            except Exception:
                priority = 0
            results.append({
                'id': entry_id,
                'name': str(item.get('name') or '').strip() or url,
                'url': url,
                'priority': priority,
                'enabled': bool(item.get('enabled', True)),
                'created_at': int(item.get('created_at') or 0),
            })
        return results

    def save_signaling_endpoints(self, endpoints: list[dict]) -> list[dict]:
        """Persist the endpoint list and return the normalized list that was
        actually written so callers can refresh their in-memory copy.
        """
        normalized: list[dict] = []
        seen_ids: set[str] = set()
        now_ts = int(time.time() * 1000)
        for item in endpoints or []:
            if not isinstance(item, dict):
                continue
            url = str(item.get('url') or '').strip()
            if not url:
                continue
            entry_id = str(item.get('id') or '').strip()
            if not entry_id or entry_id in seen_ids:
                entry_id = uuid.uuid4().hex
            seen_ids.add(entry_id)
            try:
                priority = int(item.get('priority') or 0)
            except Exception:
                priority = 0
            normalized.append({
                'id': entry_id,
                'name': str(item.get('name') or '').strip() or url,
                'url': url,
                'priority': priority,
                'enabled': bool(item.get('enabled', True)),
                'created_at': int(item.get('created_at') or now_ts),
            })
        try:
            state = self.read()
            state['signaling_endpoints'] = normalized
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to save signaling endpoints: %s', exc)
        return normalized

    # --- Public direct transport settings -------------------------------
    # These power the optional public-direct mode that bypasses the
    # signaling server. Defaults are conservative: disabled, no whitelist,
    # 0.0.0.0 binding (so the user can choose). Switching on public direct
    # mode without filling any of the fields is a no-op.

    def _public_direct_defaults(self) -> dict:
        return {
            'enabled': False,
            'listen_host': '0.0.0.0',
            'listen_port': 0,
            'public_host': '',
            'public_port': 0,
            'totp_secret': '',
            'download_whitelist': [],
            'known_public_ips': [],
        }

    def _coerce_public_direct_settings(self, settings: dict) -> dict:
        defaults = self._public_direct_defaults()
        merged = dict(defaults)
        if isinstance(settings, dict):
            for key, value in settings.items():
                if key in defaults:
                    merged[key] = value
        merged['enabled'] = bool(merged['enabled'])
        merged['listen_host'] = str(merged['listen_host'] or '0.0.0.0').strip() or '0.0.0.0'
        try:
            merged['listen_port'] = max(0, min(65535, int(merged['listen_port'] or 0)))
        except Exception:
            merged['listen_port'] = 0
        try:
            merged['public_port'] = max(0, min(65535, int(merged['public_port'] or 0)))
        except Exception:
            merged['public_port'] = 0
        merged['public_host'] = str(merged['public_host'] or '').strip()
        merged['totp_secret'] = str(merged['totp_secret'] or '').strip()
        whitelist = merged['download_whitelist']
        if not isinstance(whitelist, list):
            whitelist = []
        merged['download_whitelist'] = [
            str(item).strip() for item in whitelist if str(item or '').strip()
        ]
        known_ips = merged['known_public_ips']
        if not isinstance(known_ips, list):
            known_ips = []
        merged['known_public_ips'] = [
            str(item).strip() for item in known_ips if str(item or '').strip()
        ]
        return merged

    def load_public_direct_settings(self) -> dict:
        state = self.read()
        raw = state.get('public_direct')
        if not isinstance(raw, dict):
            return self._public_direct_defaults()
        return self._coerce_public_direct_settings(raw)

    def save_public_direct_settings(self, settings: dict) -> dict:
        merged = self._coerce_public_direct_settings(settings if isinstance(settings, dict) else {})
        try:
            state = self.read()
            state['public_direct'] = merged
            self.write(state)
        except Exception as exc:
            self._logger.warning('Failed to save public direct settings: %s', exc)
        return merged

    def record_known_public_ip(self, ip: str) -> bool:
        """Append a public IP to the allow-list so subsequent connections
        from the same address are not re-prompted. Returns True if the IP
        was newly added, False if it was already present or invalid.
        """
        candidate = str(ip or '').strip()
        if not candidate:
            return False
        settings = self.load_public_direct_settings()
        if candidate in settings['known_public_ips']:
            return False
        settings['known_public_ips'].append(candidate)
        # Cap to most recent 64 entries to keep state.json small.
        settings['known_public_ips'] = settings['known_public_ips'][-64:]
        self.save_public_direct_settings(settings)
        return True

    def load_or_create_totp_secret(self) -> str:
        """Return the existing TOTP secret or create + persist a new one.

        Generation lives here (not in totp_auth) so the state store stays
        the single source of truth for persisted secrets.
        """
        settings = self.load_public_direct_settings()
        existing = settings.get('totp_secret') or ''
        if existing:
            return existing
        # Lazy import keeps the state store importable in pure-stdlib
        # contexts (e.g. offline unit tests).
        from totp_auth import generate_secret
        secret = generate_secret()
        settings['totp_secret'] = secret
        self.save_public_direct_settings(settings)
        return secret
