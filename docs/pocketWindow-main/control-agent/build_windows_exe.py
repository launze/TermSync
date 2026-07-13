from __future__ import annotations

import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DIST_DIR = ROOT / "dist"
BUILD_DIR = ROOT / "build"
RELEASE_DIR = ROOT / "release"
SPEC_FILE = ROOT / "pocketwindow_agent.spec"
VENV_PYTHON = ROOT / ".venv" / "Scripts" / "python.exe"
VERSION_FILE = ROOT / "version.json"


def run(cmd: list[str]) -> None:
    print(">", " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=str(ROOT))


def ensure_pyinstaller() -> None:
    try:
        subprocess.run(
            [str(VENV_PYTHON), "-c", "import PyInstaller"],
            check=True,
            cwd=str(ROOT),
        )
        return
    except subprocess.CalledProcessError:
        pass
    run([str(VENV_PYTHON), "-m", "pip", "install", "pyinstaller>=6.14,<7"])


def clean() -> None:
    shutil.rmtree(DIST_DIR, ignore_errors=True)
    shutil.rmtree(BUILD_DIR, ignore_errors=True)
    shutil.rmtree(ROOT / "dist-release", ignore_errors=True)
    shutil.rmtree(ROOT / "build-release", ignore_errors=True)


def load_version_info() -> tuple[str, int]:
    import json

    if not VERSION_FILE.exists():
        raise SystemExit(f"missing version file: {VERSION_FILE}")
    data = json.loads(VERSION_FILE.read_text(encoding="utf-8"))
    version = str(data.get("version") or "").strip() or "0.0.0"
    build = int(data.get("build") or 0) if str(data.get("build") or "").strip() else 0
    return version, build


def package_release(version: str, build: int) -> Path:
    source_dir = DIST_DIR / "PocketWindowAgent"
    if not source_dir.exists():
        raise SystemExit(f"missing built app directory: {source_dir}")

    RELEASE_DIR.mkdir(exist_ok=True)
    archive_name = f"PocketWindowAgent-win64-v{version}-build{build}.zip"
    archive_path = RELEASE_DIR / archive_name
    if archive_path.exists():
        archive_path.unlink()

    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in source_dir.rglob("*"):
            if path.is_file():
                zf.write(path, path.relative_to(source_dir.parent))
    return archive_path


def main() -> int:
    if not VENV_PYTHON.exists():
        raise SystemExit(f"missing venv python: {VENV_PYTHON}")

    version, build = load_version_info()
    clean()
    ensure_pyinstaller()
    run([str(VENV_PYTHON), "-m", "PyInstaller", "--clean", "-y", str(SPEC_FILE)])
    archive_path = package_release(version, build)
    print(f"built output: {DIST_DIR}")
    print(f"release archive: {archive_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
