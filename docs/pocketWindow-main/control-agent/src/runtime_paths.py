import json
import os
import sys


def runtime_base_dir() -> str:
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def persistent_state_dir() -> str:
    local_appdata = str(os.environ.get('LOCALAPPDATA') or '').strip()
    if local_appdata:
        return os.path.join(local_appdata, 'PocketWindow')
    return runtime_base_dir()


def load_json_file(path: str) -> dict:
    try:
        with open(path, 'r', encoding='utf-8') as file:
            data = json.load(file)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def resolve_runtime_file_path(file_name: str) -> str:
    base_dir = runtime_base_dir()
    candidates = [
        os.path.join(base_dir, file_name),
        os.path.join(base_dir, '_internal', file_name),
    ]
    meipass = str(getattr(sys, '_MEIPASS', '') or '').strip()
    if meipass:
        candidates.append(os.path.join(meipass, file_name))
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    return candidates[0]
