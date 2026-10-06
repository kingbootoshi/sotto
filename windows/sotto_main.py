"""Sotto.exe entry point.

Sotto.exe            -> supervisor: keeps `Sotto.exe --child` alive forever
                        (relaunch on crash / GPU reset). Exit code 0 = user quit.
Sotto.exe --child    -> the actual app.
Sotto.exe --probe    -> print key codes (console build only).
"""
import ctypes
import subprocess
import sys
import time


def supervise():
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateMutexW(None, False, "Local\\SottoWinSupervisor")
    if ctypes.get_last_error() == 183:  # another supervisor already running
        return
    fails = []
    while True:
        t = time.time()
        rc = subprocess.call([sys.executable, "--child"], creationflags=0x08000000)
        if rc == 0:
            break
        fails = [f for f in fails if t - f < 60] + [t]
        time.sleep(2 if len(fails) < 5 else 30)


def selftest(wav):
    """Frozen-build smoke test: bundled model + GPU provider + audio libs + tray lib."""
    import os
    from pathlib import Path
    out = Path(os.environ.get("LOCALAPPDATA", ".")) / "Sotto" / "selftest.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    try:
        import pystray  # noqa: F401
        from sotto.audio import Recorder, read_wav
        from sotto.engine import Engine, bundled_model_dir
        lines.append(f"bundled model: {bundled_model_dir()}")
        lines.append(f"mics: {[n for _, n in Recorder.input_devices()]}")
        lines.append(f"default mic: {Recorder.windows_default_name()}")
        e = Engine("nemo-parakeet-tdt-0.6b-v2", log=lines.append)
        t = time.perf_counter(); e.load(); lines.append(f"load+warmup {time.perf_counter() - t:.1f}s")
        audio = read_wav(wav)
        for _ in range(3):
            text, secs = e.transcribe(audio)
            lines.append(f"{len(audio) / 16000:.2f}s audio -> {secs * 1000:.0f} ms")
        lines.append(f"TEXT: {text}")
        lines.append("SELFTEST OK")
    except Exception:
        import traceback
        lines.append(traceback.format_exc())
    out.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest(sys.argv[sys.argv.index("--selftest") + 1])
    elif getattr(sys, "frozen", False) and "--child" not in sys.argv and "--probe" not in sys.argv:
        supervise()
    else:
        from sotto.app import main
        main()
