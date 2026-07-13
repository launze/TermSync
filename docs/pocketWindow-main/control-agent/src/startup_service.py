import logging
import os
import sys
import winreg


logger = logging.getLogger(__name__)

WINDOWS_RUN_KEY_PATH = r'Software\Microsoft\Windows\CurrentVersion\Run'
WINDOWS_RUN_VALUE_NAME = 'PocketWindowAgent'


def startup_command(script_path: str) -> str:
    if getattr(sys, 'frozen', False):
        return f'"{os.path.abspath(sys.executable)}"'
    return f'"{os.path.abspath(sys.executable)}" "{os.path.abspath(script_path)}"'


def is_startup_enabled(command: str) -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, WINDOWS_RUN_KEY_PATH, 0, winreg.KEY_READ) as key:
            value, _ = winreg.QueryValueEx(key, WINDOWS_RUN_VALUE_NAME)
        return str(value or '').strip() == command
    except FileNotFoundError:
        return False
    except OSError:
        return False


def set_startup_enabled(enabled: bool, command: str) -> bool:
    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            WINDOWS_RUN_KEY_PATH,
            0,
            winreg.KEY_SET_VALUE,
        ) as key:
            if enabled:
                winreg.SetValueEx(
                    key,
                    WINDOWS_RUN_VALUE_NAME,
                    0,
                    winreg.REG_SZ,
                    command,
                )
            else:
                try:
                    winreg.DeleteValue(key, WINDOWS_RUN_VALUE_NAME)
                except FileNotFoundError:
                    pass
        return True
    except OSError as exc:
        logger.warning('set startup enabled failed: %s', exc)
        return False
