import hashlib
import logging
import os
import subprocess
import sys
import threading
import time
from typing import Callable, Optional

import requests

from runtime_paths import persistent_state_dir, runtime_base_dir


logger = logging.getLogger(__name__)


class DesktopUpdateService:
    def __init__(
        self,
        *,
        http_base_url_getter: Callable[[], str],
        version_info_getter: Callable[[], dict],
        status_callback: Callable[[str], None],
        stop_event: threading.Event,
        check_interval_seconds: int = 60 * 60,
        retry_interval_seconds: int = 5 * 60,
    ):
        self._http_base_url_getter = http_base_url_getter
        self._version_info_getter = version_info_getter
        self._status_callback = status_callback
        self._stop_event = stop_event
        self._check_interval_seconds = check_interval_seconds
        self._retry_interval_seconds = retry_interval_seconds
        self._check_started = False
        self._install_started = False

    @property
    def install_started(self) -> bool:
        return self._install_started

    def fetch_release(self) -> Optional[dict]:
        try:
            response = requests.get(
                f'{self._http_base_url_getter()}/api/releases/latest',
                params={'platform': 'windows'},
                timeout=(5, 15),
            )
            if response.status_code == 404:
                return None
            response.raise_for_status()
            payload = response.json()
            release = payload.get('release')
            if isinstance(release, dict):
                return release
        except Exception as exc:
            logger.info('windows update check skipped: %s', exc)
        return None

    def download_release(self, release: dict) -> tuple[str, str]:
        source_url = str(release.get('source_url') or '').strip()
        if not source_url:
            raise RuntimeError('更新包地址为空')
        updates_dir = os.path.join(persistent_state_dir(), 'updates')
        os.makedirs(updates_dir, exist_ok=True)
        file_name = os.path.basename(str(release.get('file_name') or 'PocketWindowAgent-update.zip').strip()) or 'PocketWindowAgent-update.zip'
        file_name = ''.join(ch if ch not in '<>:"/\\|?*' else '_' for ch in file_name)
        file_path = os.path.join(updates_dir, file_name)
        self._status_callback(f'正在下载电脑端更新 {release.get("version") or ""}...')
        with requests.get(source_url, stream=True, timeout=(10, 600)) as response:
            response.raise_for_status()
            digest = hashlib.sha256()
            with open(file_path, 'wb') as file:
                for chunk in response.iter_content(chunk_size=1024 * 256):
                    if not chunk:
                        continue
                    file.write(chunk)
                    digest.update(chunk)
        expected_sha = str(release.get('sha256') or '').strip().lower()
        actual_sha = digest.hexdigest().lower()
        if expected_sha and expected_sha != actual_sha:
            raise RuntimeError('更新包校验失败')
        return file_path, actual_sha

    def write_updater_script(self, archive_path: str) -> str:
        runtime_dir = runtime_base_dir()
        script_path = os.path.join(persistent_state_dir(), 'update-and-restart.bat')
        current_pid = os.getpid()
        exe_path = os.path.abspath(sys.executable)
        extract_dir = os.path.join(persistent_state_dir(), 'update-extract')
        extracted_root = os.path.join(extract_dir, 'package')
        log_path = os.path.join(persistent_state_dir(), 'update-and-restart.log')
        script = f'''@echo off
setlocal enableextensions
set "ZIP_PATH={archive_path}"
set "TARGET_DIR={runtime_dir}"
set "EXE_PATH={exe_path}"
set "PID={current_pid}"
set "EXTRACT_DIR={extract_dir}"
set "PACKAGE_DIR={extracted_root}"
set "SOURCE_DIR=%PACKAGE_DIR%"
set "LOG_PATH={log_path}"
echo [%DATE% %TIME%] update-and-restart begin > "%LOG_PATH%"
echo ZIP_PATH=%ZIP_PATH% >> "%LOG_PATH%"
echo TARGET_DIR=%TARGET_DIR% >> "%LOG_PATH%"
echo EXE_PATH=%EXE_PATH% >> "%LOG_PATH%"
timeout /t 2 /nobreak >nul
taskkill /PID %PID% /F >nul 2>nul
timeout /t 2 /nobreak >nul
if exist "%EXTRACT_DIR%" rmdir /s /q "%EXTRACT_DIR%"
mkdir "%PACKAGE_DIR%" >nul 2>nul
echo [%DATE% %TIME%] expanding zip >> "%LOG_PATH%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ZIP_PATH%' -DestinationPath '%PACKAGE_DIR%' -Force" >> "%LOG_PATH%" 2>&1
if errorlevel 1 (
  echo [%DATE% %TIME%] expand-archive failed >> "%LOG_PATH%"
  goto :failed
)
if exist "%PACKAGE_DIR%\\PocketWindowAgent\\PocketWindowAgent.exe" set "SOURCE_DIR=%PACKAGE_DIR%\\PocketWindowAgent"
if not exist "%SOURCE_DIR%\\PocketWindowAgent.exe" (
  echo [%DATE% %TIME%] missing exe in %SOURCE_DIR% >> "%LOG_PATH%"
  goto :failed
)
echo [%DATE% %TIME%] copying %SOURCE_DIR% -> %TARGET_DIR% >> "%LOG_PATH%"
robocopy "%SOURCE_DIR%" "%TARGET_DIR%" /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS >> "%LOG_PATH%" 2>&1
set "RC=%ERRORLEVEL%"
echo [%DATE% %TIME%] robocopy exit=%RC% >> "%LOG_PATH%"
if %RC% GEQ 8 goto :failed
echo [%DATE% %TIME%] starting %EXE_PATH% >> "%LOG_PATH%"
start "" "%EXE_PATH%"
exit /b 0
:failed
echo [%DATE% %TIME%] PocketWindow update failed. >> "%LOG_PATH%"
echo PocketWindow update failed. > "%TARGET_DIR%\\update-error.log"
exit /b 1
'''
        with open(script_path, 'w', encoding='utf-8', newline='\r\n') as file:
            file.write(script)
        return script_path

    def begin_update(self, release: dict):
        if self._install_started:
            return
        if not getattr(sys, 'frozen', False):
            self._status_callback('当前是源码运行模式，已跳过自动更新。')
            return
        self._install_started = True
        try:
            archive_path, _ = self.download_release(release)
            self._status_callback('更新下载完成，正在安装并重启电脑端...')
            script_path = self.write_updater_script(archive_path)
            subprocess.Popen(
                ['cmd.exe', '/c', script_path],
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0,
            )
            os._exit(0)
        except Exception as exc:
            self._install_started = False
            logger.error('desktop self-update failed: %s', exc, exc_info=True)
            self._status_callback(f'更新失败: {exc}')

    def maybe_install_release(self, release: dict) -> bool:
        version_info = self._version_info_getter()
        local_version = str(version_info.get('version') or '0.0.0')
        local_build = int(version_info.get('build') or 0)
        remote_version = str(release.get('version') or '').strip()
        remote_build = int(release.get('build') or 0)
        version_compare = compare_versions(remote_version, local_version)
        if version_compare < 0 or (version_compare == 0 and remote_build <= local_build):
            return False
        logger.info(
            'windows update available: local=%s build=%s remote=%s build=%s',
            local_version,
            local_build,
            remote_version,
            remote_build,
        )
        self._status_callback(f'检测到电脑端新版本 {remote_version}，开始自动更新...')
        threading.Thread(
            target=self.begin_update,
            args=(dict(release),),
            daemon=True,
            name='windows-auto-update-install',
        ).start()
        return True

    def check_once(self, notify_no_update: bool = False) -> bool:
        release = self.fetch_release()
        if not release:
            if notify_no_update:
                self._status_callback('未检测到可用的电脑端更新。')
            return False
        before = self._install_started
        self.maybe_install_release(release)
        if notify_no_update and self._install_started == before:
            self._status_callback('电脑端已是最新版本。')
        return self._install_started and not before

    def run_loop(self):
        time.sleep(3)
        while not self._stop_event.is_set():
            try:
                installing = self.check_once()
                if installing:
                    return
                wait_seconds = self._check_interval_seconds
            except Exception as exc:
                logger.info('windows update check failed: %s', exc)
                wait_seconds = self._retry_interval_seconds
            self._stop_event.wait(wait_seconds)

    def check_now(self):
        if not getattr(sys, 'frozen', False):
            self._status_callback('当前是源码运行模式，打包版才支持自动安装更新。')
            return
        if self._install_started:
            self._status_callback('更新正在进行中...')
            return
        self._status_callback('正在检查电脑端更新...')
        threading.Thread(
            target=self.check_once,
            args=(True,),
            daemon=True,
            name='windows-update-manual-check',
        ).start()

    def start_background_check(self):
        if self._check_started:
            return
        if not getattr(sys, 'frozen', False):
            logger.info('windows update check skipped in source mode')
            return
        self._check_started = True
        threading.Thread(target=self.run_loop, daemon=True, name='windows-update-check').start()


def load_version_info(version_file_path: str) -> dict:
    from runtime_paths import load_json_file

    data = load_json_file(version_file_path)
    version = str(data.get('version') or '').strip() or '0.0.0'
    build = int(data.get('build') or 0) if str(data.get('build') or '').strip() else 0
    channel = str(data.get('channel') or 'stable').strip() or 'stable'
    return {
        'version': version,
        'build': build,
        'channel': channel,
    }


def compare_versions(left: str, right: str) -> int:
    def normalize(value: str) -> list[int]:
        parts = []
        for item in str(value or '').strip().replace('-', '.').replace('+', '.').split('.'):
            try:
                parts.append(int(item))
            except Exception:
                parts.append(0)
        return parts

    left_parts = normalize(left)
    right_parts = normalize(right)
    max_length = max(len(left_parts), len(right_parts))
    for index in range(max_length):
        left_value = left_parts[index] if index < len(left_parts) else 0
        right_value = right_parts[index] if index < len(right_parts) else 0
        if left_value > right_value:
            return 1
        if left_value < right_value:
            return -1
    return 0
