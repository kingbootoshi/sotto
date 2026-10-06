"""Start-with-Windows via HKCU Run key. Frozen .exe: the exe itself (it runs
its own supervisor). Source checkout: pythonw + supervisor.pyw."""
import sys
import winreg
from pathlib import Path

RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"
NAME = "Sotto"


def command() -> str:
    if getattr(sys, "frozen", False):
        return f'"{Path(sys.executable).resolve()}"'
    root = Path(__file__).resolve().parents[1]
    pyw = Path(sys.executable).with_name("pythonw.exe")
    return f'"{pyw}" "{root / "supervisor.pyw"}"'


def is_enabled() -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN) as k:
            return bool(winreg.QueryValueEx(k, NAME)[0])
    except OSError:
        return False


def enable():
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN, 0, winreg.KEY_SET_VALUE) as k:
        winreg.SetValueEx(k, NAME, 0, winreg.REG_SZ, command())


def disable():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, NAME)
    except OSError:
        pass
