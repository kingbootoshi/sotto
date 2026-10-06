"""Keeps Sotto alive forever: relaunches on crash. Exit code 0 (tray Quit) stops it.
Launched at logon by the HKCU Run key that install.py writes."""
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PYW = Path(sys.executable).with_name("pythonw.exe")

fails = []
while True:
    t = time.time()
    rc = subprocess.call([str(PYW), "-m", "sotto.app"], cwd=str(HERE),
                         creationflags=0x08000000)  # CREATE_NO_WINDOW
    if rc == 0:
        break
    fails = [f for f in fails if t - f < 60] + [t]
    time.sleep(2 if len(fails) < 5 else 30)  # back off if it's crash-looping
