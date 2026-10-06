"""Real paste test: focused Tk Entry receives our clipboard + SendInput Ctrl+V."""
import sys
import tkinter as tk
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sotto.paste import copy, paste_text_now, send_ctrl_v

root = tk.Tk()
e = tk.Entry(root, width=60)
e.pack()
root.attributes("-topmost", True)
root.focus_force(); e.focus_set()
result = {}


def force_fg(w):
    import ctypes
    u = ctypes.windll.user32
    hwnd = u.GetParent(w.winfo_id()) or w.winfo_id()
    u.keybd_event(0x12, 0, 0, 0); u.keybd_event(0x12, 0, 2, 0)  # ALT trick unlocks SetForegroundWindow
    u.SetForegroundWindow(hwnd)
    return u.GetForegroundWindow() == hwnd


def go():
    root.update()
    result["fg"] = force_fg(root); e.focus_set(); root.update()
    assert result["fg"], "could not take foreground; refusing to send Ctrl+V elsewhere"
    assert copy("pasted from sotto ✓ ")
    result["clip"] = paste_text_now()
    send_ctrl_v()
    root.after(400, done)


def done():
    result["entry"] = e.get()
    root.destroy()


root.after(600, go)
root.mainloop()
print(result)
assert result["entry"] == "pasted from sotto ✓ ", result
print("PASTE OK")
