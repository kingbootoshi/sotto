"""On-screen cinematic: glass pill + live waveform while you speak, contracts to
a charging orb while the GPU works, then a comet slingshots to where your mouse
was the instant you stopped. One click-through, no-activate, topmost Tk window
spanning the virtual desktop; it never takes focus."""
import ctypes
import math
import time
import tkinter as tk
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

KEY = "#010203"  # transparent color key
ORANGE, GOLD, DARK, RIM = "#ff9e1c", "#ffcc59", "#121212", "#3a2a12"
GWL_EXSTYLE = -20
WS_EX_LAYERED, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE, WS_EX_TOPMOST = (
    0x80000, 0x20, 0x80, 0x8000000, 0x8)
SW_HIDE, SW_SHOWNOACTIVATE = 0, 4
HWND_TOPMOST = -1
SWP_NOMOVE, SWP_NOSIZE, SWP_NOACTIVATE, SWP_SHOWWINDOW = 0x2, 0x1, 0x10, 0x40
user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.MonitorFromPoint.argtypes = [wintypes.POINT, wintypes.DWORD]
user32.MonitorFromPoint.restype = wintypes.HMONITOR


class MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]


def cursor_pos():
    p = wintypes.POINT()
    user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def work_area_at(x, y):
    mon = user32.MonitorFromPoint(wintypes.POINT(x, y), 2)
    mi = MONITORINFO(cbSize=ctypes.sizeof(MONITORINFO))
    user32.GetMonitorInfoW(mon, ctypes.byref(mi))
    r = mi.rcWork
    return r.left, r.top, r.right, r.bottom


def ease_in(t):
    return t * t * t


def ease_out(t):
    return 1 - (1 - t) ** 3


class Overlay:
    NBARS = 26

    def __init__(self, root: tk.Tk, level_fn, scale=1.0):
        self.root = root
        self.level_fn = level_fn
        self.s = scale
        self.vx = user32.GetSystemMetrics(76); self.vy = user32.GetSystemMetrics(77)
        self.vw = user32.GetSystemMetrics(78); self.vh = user32.GetSystemMetrics(79)
        self.win = tk.Toplevel(root)
        self.win.overrideredirect(True)
        self.win.geometry(f"{self.vw}x{self.vh}+{self.vx}+{self.vy}")
        self.win.configure(bg=KEY)
        self.win.attributes("-transparentcolor", KEY, "-topmost", True)
        self.cv = tk.Canvas(self.win, bg=KEY, highlightthickness=0, width=self.vw, height=self.vh)
        self.cv.pack(fill="both", expand=True)
        self.win.update_idletasks()
        self.hwnd = user32.GetParent(self.win.winfo_id()) or self.win.winfo_id()
        ex = user32.GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE)
        user32.SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED | WS_EX_TRANSPARENT
                                 | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST)
        user32.ShowWindow(self.hwnd, SW_HIDE)
        self.visible = False
        self.phase = "hidden"
        self.levels = [0.0] * self.NBARS
        self.center = (0, 0)
        self.phase_t = 0.0
        self.msg = ""
        self.hide_at = None
        self.comets = []  # list of dicts
        self._tick()

    # --- public API (call from Tk thread) -------------------------------
    def listening(self):
        x, y = cursor_pos()
        l, t, r, b = work_area_at(x, y)
        self.center = ((l + r) // 2 - self.vx, b - int(70 * self.s) - self.vy)
        self.levels = [0.0] * self.NBARS
        self._set("listening")

    def charging(self):
        self._set("charging")

    def error(self, msg, secs=2.5):
        if self.phase == "hidden":
            x, y = cursor_pos()
            l, t, r, b = work_area_at(x, y)
            self.center = ((l + r) // 2 - self.vx, b - int(70 * self.s) - self.vy)
        self.msg = msg
        self._set("error")
        self.hide_at = time.perf_counter() + secs

    def hide(self):
        self._set("hidden")

    def launch(self, aim):
        """Orb -> comet to aim (screen coords). Pill vanishes."""
        cx, cy = self.center
        self.comets.append(dict(t0=time.perf_counter(), sx=cx, sy=cy,
                                ax=aim[0] - self.vx, ay=aim[1] - self.vy, trail=[]))
        self._set("hidden")

    # --- internals --------------------------------------------------------
    def _set(self, phase):
        self.phase = phase
        self.phase_t = time.perf_counter()
        if phase != "error":
            self.hide_at = None
        self._ensure_visible()

    def _ensure_visible(self):
        want = self.phase != "hidden" or bool(self.comets)
        if want and not self.visible:
            user32.SetWindowPos(self.hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW)
            user32.ShowWindow(self.hwnd, SW_SHOWNOACTIVATE)
            self.visible = True
        elif not want and self.visible:
            self.cv.delete("all")
            user32.ShowWindow(self.hwnd, SW_HIDE)
            self.visible = False

    def _pill(self, cx, cy, w, h, fill, outline, width=2):
        r = h / 2
        x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
        c = self.cv
        if w <= h + 1:
            c.create_oval(cx - r, y0, cx + r, y1, fill=fill, outline=outline, width=width)
            return
        c.create_oval(x0, y0, x0 + h, y1, fill=fill, outline=outline, width=width)
        c.create_oval(x1 - h, y0, x1, y1, fill=fill, outline=outline, width=width)
        c.create_rectangle(x0 + r, y0, x1 - r, y1, fill=fill, outline="")
        c.create_line(x0 + r, y0 + width / 2, x1 - r, y0 + width / 2, fill=outline, width=width)
        c.create_line(x0 + r, y1 - width / 2, x1 - r, y1 - width / 2, fill=outline, width=width)

    def _tick(self):
        try:
            self._draw()
        finally:
            self.root.after(15, self._tick)

    def _draw(self):
        now = time.perf_counter()
        if self.hide_at and now >= self.hide_at:
            self.hide_at = None
            self._set("hidden")
        if not self.visible:
            return
        s, c = self.s, self.cv
        c.delete("all")
        cx, cy = self.center
        dt = now - self.phase_t
        if self.phase == "listening":
            self.levels = self.levels[1:] + [self.level_fn()]
            w, h = 260 * s * min(1, ease_out(min(1, dt / 0.14))), 52 * s
            self._pill(cx, cy, max(w, h), h, DARK, ORANGE)
            if dt > 0.1:
                bw = 4 * s; gap = 4.4 * s
                x = cx - (self.NBARS * (bw + gap)) / 2 + gap / 2 + 14 * s
                c.create_oval(cx - w / 2 + 14 * s, cy - 5 * s, cx - w / 2 + 24 * s, cy + 5 * s,
                              fill="#ff3b30" if int(now * 2) % 2 == 0 else "#7a1d18", outline="")
                for i, lv in enumerate(self.levels):
                    bh = max(3 * s, min(h - 18 * s, (lv ** 0.7) * (h - 16 * s)))
                    xi = x + i * (bw + gap)
                    c.create_rectangle(xi, cy - bh / 2, xi + bw, cy + bh / 2,
                                       fill=GOLD if lv > 0.55 else ORANGE, outline="")
        elif self.phase == "charging":
            k = ease_in(min(1, dt / 0.16))
            w = 260 * s * (1 - k) + 40 * s * k
            h = 52 * s * (1 - k) + 40 * s * k
            if k < 1:
                self._pill(cx, cy, max(w, h), h, DARK, ORANGE)
            else:
                pulse = 1 + 0.12 * math.sin(now * 18)
                for i, col in enumerate((RIM, "#6b4410", ORANGE, GOLD)):
                    rr = (26 - i * 5) * s * pulse
                    c.create_oval(cx - rr, cy - rr, cx + rr, cy + rr, fill=col, outline="")
        elif self.phase == "error":
            c.create_text(cx, cy, text=self.msg, fill="#f3e9d8", font=("Segoe UI", int(11 * s)),
                          width=520 * s, tags="t")
            bb = c.bbox("t")
            w = (bb[2] - bb[0]) + 44 * s if bb else 300 * s
            h = max(46 * s, (bb[3] - bb[1]) + 22 * s) if bb else 46 * s
            c.delete("t")
            self._pill(cx, cy, w, h, DARK, "#c0392b")
            c.create_text(cx, cy, text=self.msg, fill="#f3e9d8", font=("Segoe UI", int(11 * s)),
                          width=520 * s)
        # comets
        alive = []
        for cm in self.comets:
            t = now - cm["t0"]
            sx, sy, ax, ay = cm["sx"], cm["sy"], cm["ax"], cm["ay"]
            dx, dy = ax - sx, ay - sy
            dist = math.hypot(dx, dy) or 1
            ux, uy = dx / dist, dy / dist
            if t < 0.11:  # pull-back
                k = ease_out(t / 0.11)
                x, y = sx - ux * 22 * s * k, sy - uy * 22 * s * k
            elif t < 0.37:  # streak
                k = ease_in((t - 0.11) / 0.26)
                bx, by = sx - ux * 22 * s, sy - uy * 22 * s
                x, y = bx + (ax - bx) * k, by + (ay - by) * k
            elif t < 0.62:  # splash
                k = (t - 0.37) / 0.25
                rr = (8 + 40 * ease_out(k)) * s
                col = GOLD if k < 0.5 else ORANGE
                c.create_oval(ax - rr, ay - rr, ax + rr, ay + rr, outline=col, width=max(1, 3 * s * (1 - k)))
                alive.append(cm)
                continue
            else:
                continue
            cm["trail"].append((x, y))
            cm["trail"] = cm["trail"][-9:]
            n = len(cm["trail"])
            for i, (tx, ty) in enumerate(cm["trail"]):
                rr = (3 + 9 * (i + 1) / n) * s
                col = ORANGE if i < n - 2 else GOLD
                c.create_oval(tx - rr, ty - rr, tx + rr, ty + rr, fill=col, outline="")
            c.create_oval(x - 7 * s, y - 7 * s, x + 7 * s, y + 7 * s, fill="#fff4dc", outline="")
            alive.append(cm)
        self.comets = alive
        if self.phase == "hidden" and not self.comets:
            self._ensure_visible()
