# PyInstaller spec — freezes the bridge into a single self-contained binary
# (gbf-bridge / gbf-bridge.exe). Built per-OS in CI and bundled with the
# game so end users don't need Python or uv installed.
#
#   uv run --group build pyinstaller gbf-bridge.spec
#
# collect_all("bleak") pulls in the platform BLE backend (CoreBluetooth via
# pyobjc on macOS, WinRT on Windows, BlueZ/dbus-fast on Linux) plus any data
# files PyInstaller's static analysis would otherwise miss.

import importlib.util

from PyInstaller.utils.hooks import collect_all


def _collect(pkg):
    # collect_all raises if the package isn't installed, so only pull in
    # packages present on this platform: bleak everywhere, winrt only on
    # Windows (its BLE backend), dbus_fast only on Linux.
    if importlib.util.find_spec(pkg) is None:
        return [], [], []
    return collect_all(pkg)


datas, binaries, hiddenimports = [], [], []
for _pkg in ("bleak", "winrt", "dbus_fast", "bleak_winrt"):
    _d, _b, _h = _collect(_pkg)
    datas += _d
    binaries += _b
    hiddenimports += _h

# websockets + our own package are pure-Python; name them explicitly so the
# analysis never drops them.
hiddenimports += [
    "websockets",
    "gbf_bridge",
    "gbf_bridge.server",
    "gbf_bridge.sensors",
    "gbf_bridge.protocol",
]

a = Analysis(
    ["run_bridge.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="gbf-bridge",
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
