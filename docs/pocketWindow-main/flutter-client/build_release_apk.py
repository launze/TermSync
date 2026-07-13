from __future__ import annotations

import os
import shutil
import subprocess
from shutil import which
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PUBSPEC_FILE = ROOT / "pubspec.yaml"
# Single-ABI builds (`--target-platform android-arm64`) put the APK at
# build/app/outputs/flutter-apk/app-release.apk, not the per-ABI path.
BUILD_APK = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
RELEASE_DIR = ROOT / "release"


def run(cmd: list[str]) -> None:
    print(">", " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=str(ROOT))


def resolve_flutter_command() -> str:
    for candidate in ["flutter.bat", "flutter"]:
        resolved = which(candidate)
        if resolved:
            return resolved
    flutter_home = str(os.environ.get("FLUTTER_HOME") or "").strip()
    if flutter_home:
        bat = Path(flutter_home) / "bin" / "flutter.bat"
        if bat.exists():
            return str(bat)
    raise SystemExit("flutter executable not found in PATH")


def load_version_info() -> tuple[str, int]:
    for line in PUBSPEC_FILE.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("version:"):
            raw = line.split(":", 1)[1].strip()
            version_text, _, build_text = raw.partition("+")
            version = version_text.strip() or "0.0.0"
            build = int(build_text.strip() or "0")
            return version, build
    raise SystemExit(f"version not found in {PUBSPEC_FILE}")


def main() -> int:
    version, build = load_version_info()
    flutter = resolve_flutter_command()
    # Single-ABI build keeps the APK small (~25-30 MB instead of 100+ MB) and
    # sidesteps the split-per-abi versionCode offset surprise documented in
    # 打包发布注意事项.md.
    run([
        flutter,
        "build",
        "apk",
        "--release",
        "--target-platform",
        "android-arm64",
    ])
    if not BUILD_APK.exists():
        raise SystemExit(f"missing built apk: {BUILD_APK}")

    RELEASE_DIR.mkdir(exist_ok=True)
    target = RELEASE_DIR / f"PocketWindow-android-arm64-v8a-v{version}-build{build}.apk"
    shutil.copy2(BUILD_APK, target)
    print(f"release apk: {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
