"""Install/uninstall autostart (HKCU Run key -> pythonw supervisor.pyw).
   python install.py            install + start now
   python install.py --remove   remove autostart"""
import subprocess
import sys
import winreg
from pathlib import Path

HERE = Path(__file__).resolve().parent
PYW = HERE / ".venv" / "Scripts" / "pythonw.exe"
RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"
cmd = f'"{PYW}" "{HERE / "supervisor.pyw"}"'

with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN, 0, winreg.KEY_SET_VALUE) as k:
    if "--remove" in sys.argv:
        try:
            winreg.DeleteValue(k, "Sotto")
        except FileNotFoundError:
            pass
        print("autostart removed")
    else:
        winreg.SetValueEx(k, "Sotto", 0, winreg.REG_SZ, cmd)
        print("autostart set:", cmd)
        subprocess.Popen(cmd, creationflags=0x00000008 | 0x00000200)  # DETACHED | NEW_GROUP
        print("started")
