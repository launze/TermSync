# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_submodules


ROOT = Path(SPEC).resolve().parent
SRC_DIR = ROOT / 'src'

hiddenimports = [
    'win32api',
    'win32con',
    'win32event',
    'win32gui',
    'win32process',
    'win32ui',
    'pywintypes',
    'pythoncom',
]
for package in ('websocket', 'qrcode', 'PIL', 'cv2', 'numpy', 'windows_capture'):
    hiddenimports += collect_submodules(package)

binaries = []
for package in ('cv2', 'numpy', 'PIL', 'windows_capture'):
    binaries += collect_dynamic_libs(package)

datas = [
    (str(ROOT / 'config.json.example'), '.'),
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
    name='PocketWindowAgentDebug',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='PocketWindowAgentDebug',
)
