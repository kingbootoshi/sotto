"""End-to-end self test (no physical key needed): real App, real GPU engine, real
overlay + comet + clipboard + Ctrl+V into a focused Tk Entry, using bench.wav.
Grabs screenshots of the pill and the orb."""
import sys
import time
import tkinter as tk
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from PIL import ImageGrab

from sotto import app as sapp
from sotto.audio import read_wav

sapp.setup_logging()
A = sapp.App()
A.hook.stop = lambda: None
target = tk.Toplevel(A.root)
target.geometry("700x60+200+200")
ent = tk.Entry(target, width=80, font=("Segoe UI", 12)); ent.pack(fill="x")
audio = read_wav(ROOT / "bench.wav")
shots = ROOT / "tests" / "shots"; shots.mkdir(exist_ok=True)


def step1():
    if not A.engine.ready.is_set():
        return A.root.after(200, step1)
    target.focus_force(); ent.focus_set()
    A.overlay.listening()
    A.root.after(900, lambda: ImageGrab.grab(all_screens=True).save(shots / "pill.png"))
    A.root.after(1200, step2)


def step2():
    A.overlay.charging()
    A.root.after(250, lambda: ImageGrab.grab(all_screens=True).save(shots / "orb.png"))
    A.root.after(300, lambda: A.jobs.put(dict(wav=ROOT / "tests" / "shots" / "st.wav", audio=audio,
                                              deliver=True, aim=(500, 230), dur=len(audio) / 16000)))
    A.root.after(2000, done)


def done():
    print("ENTRY:", ent.get())
    print("comets alive:", len(A.overlay.comets), "phase:", A.overlay.phase)
    A.root.destroy()


A.root.after(100, step1)
threading = __import__("threading")
threading.Thread(target=A._load_model, daemon=True).start()
threading.Thread(target=A._worker, daemon=True).start()
A.root.after(5, A._pump)
A.root.mainloop()
