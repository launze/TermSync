# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_submodules


ROOT = Path(SPEC).resolve().parent
SRC_DIR = ROOT / 'src'

def collect_runtime_submodules(package):
    skipped_parts = {'.tests', '.test_', '._configtool'}
    return [
        name
        for name in collect_submodules(package)
        if not any(part in name for part in skipped_parts)
    ]


hiddenimports = []
hiddenimports += collect_runtime_submodules('websocket')
hiddenimports += collect_runtime_submodules('qrcode')
hiddenimports += collect_runtime_submodules('PIL')
hiddenimports += collect_runtime_submodules('cv2')
hiddenimports += collect_runtime_submodules('numpy')
hiddenimports += collect_runtime_submodules('windows_capture')
hiddenimports += [
    'win32api',
    'win32con',
    'win32event',
    'win32gui',
    'win32process',
    'win32ui',
    'pywintypes',
    'pythoncom',
]

binaries = []
binaries += collect_dynamic_libs('cv2')
binaries += collect_dynamic_libs('numpy')
binaries += collect_dynamic_libs('PIL')
binaries += collect_dynamic_libs('windows_capture')

datas = [
    (str(ROOT / 'config.json.example'), '.'),
    (str(ROOT / 'version.json'), '.'),
    (str(ROOT / 'assets' / 'app.ico'), '.'),
]

a = Analysis(
    [str(SRC_DIR / 'agent_simple.py')],
    pathex=[str(SRC_DIR)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'matplotlib',
        'PySide6',
        'PySide6_Addons',
        'PySide6_Essentials',
        'shiboken6',
    ],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='PocketWindowAgent',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=str(ROOT / 'assets' / 'app.ico'),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='PocketWindowAgent',
)
