"""Global low-level keyboard hook (WH_KEYBOARD_LL) on its own thread.

The callback must stay tiny: Windows silently unhooks slow LL hooks, so it
only flips bits and pushes events onto a queue for the UI thread.
"""
import ctypes
import queue
import threading
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WH_KEYBOARD_LL = 13
WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP = 0x100, 0x101, 0x104, 0x105
WM_QUIT = 0x12
WM_TIMER = 0x113
REHOOK_MS = 2000  # Windows silently drops an LL hook that is ever slow to answer
                  # (e.g. the screen freeze of a snip/screenshot). Re-arm it often.
STALE_S = 1.0     # a held key autorepeats every ~33 ms; a "down" for a key we think
                  # is held, with nothing heard for >1 s, means its release was lost
LLKHF_EXTENDED, LLKHF_INJECTED = 0x01, 0x10
VK_ESCAPE = 0x1B

NAMED_VK = {
    "rmenu": 0xA5, "ralt": 0xA5, "lmenu": 0xA4, "lalt": 0xA4,
    "rcontrol": 0xA3, "rctrl": 0xA3, "lcontrol": 0xA2, "lctrl": 0xA2,
    "rshift": 0xA1, "lshift": 0xA0, "rwin": 0x5C, "lwin": 0x5B, "apps": 0x5D,
    "capital": 0x14, "capslock": 0x14, "scroll": 0x91, "pause": 0x13,
    "insert": 0x2D,
    **{f"f{i}": 0x70 + i - 1 for i in range(1, 25)},
}


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD),
                ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.c_size_t)]


LRESULT = ctypes.c_ssize_t
HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HHOOK
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.UnhookWindowsHookEx.argtypes = [wintypes.HHOOK]
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SetTimer.argtypes = [wintypes.HWND, ctypes.c_size_t, wintypes.UINT, ctypes.c_void_p]
user32.SetTimer.restype = ctypes.c_size_t
kernel32.GetModuleHandleW.restype = wintypes.HMODULE


def parse_key(spec: str):
    """-> ('vk', int) | ('sc', int)  (sc includes 0xE000 when extended)."""
    s = spec.strip().lower()
    if s.startswith("vk:"):
        return ("vk", int(s[3:], 0))
    if s.startswith("sc:"):
        return ("sc", int(s[3:], 0))
    if s in NAMED_VK:
        return ("vk", NAMED_VK[s])
    raise ValueError(f"unknown hotkey key {spec!r}")


class ComboTracker:
    """Pure logic: which hotkey keys are held -> combo down/up edges."""

    def __init__(self, keys):
        self.keys = [parse_key(k) for k in keys]
        self.held = set()
        self.active = False
        self.last = {}  # key -> time of its last event
        self.stale_resets = 0

    def match(self, vk, sc):
        for k in self.keys:
            if (k[0] == "vk" and k[1] == vk) or (k[0] == "sc" and k[1] == sc):
                return k
        return None

    def feed(self, vk, sc, down, t=None):
        """Returns (is_hotkey_key, edge) where edge is 'down'/'up'/None."""
        k = self.match(vk, sc)
        if k is None:
            return False, None
        if t is not None:
            prev = self.last.get(k)
            self.last[k] = t
            if down and k in self.held and prev is not None and t - prev > STALE_S:
                # The release got eaten (snip overlay, focus change, secure desktop).
                # Treat this as a fresh press instead of ignoring the tap.
                self.held.clear()
                self.active = False
                self.stale_resets += 1
        if down:
            self.held.add(k)
        else:
            self.held.discard(k)
        now = len(self.held) == len(self.keys)
        edge = None
        if now and not self.active:
            edge = "down"
        elif not now and self.active:
            edge = "up"
        self.active = now
        return True, edge


class HotkeyHook:
    """Emits ('down'|'up'|'esc', t_seconds) onto `events`."""

    def __init__(self, keys, suppress=True, esc=True, probe=False):
        self.events: queue.Queue = queue.Queue()
        self.combo = ComboTracker(keys)
        self.suppress = suppress
        self.esc = esc
        self.probe = probe
        self.recording = False  # set by app; Esc only matters while recording
        self._tid = None
        self._proc = HOOKPROC(self._cb)  # keep ref alive
        self._hook = None
        self.rehooks = 0
        self.rehook_errors = 0

    def _cb(self, ncode, wparam, lparam):
        if ncode == 0:
            kb = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
            if not (kb.flags & LLKHF_INJECTED):
                down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)
                sc = kb.scanCode | (0xE000 if kb.flags & LLKHF_EXTENDED else 0)
                t = kb.time / 1000.0
                if self.probe:
                    print(f"{'DOWN' if down else 'up  '} vk=0x{kb.vkCode:02X} sc=0x{sc:04X}", flush=True)
                is_key, edge = self.combo.feed(kb.vkCode, sc, down, t)
                if edge:
                    self.events.put((edge, t))
                if is_key and self.suppress and len(self.combo.keys) == 1:
                    return 1
                if self.esc and down and kb.vkCode == VK_ESCAPE and self.recording:
                    self.events.put(("esc", t))
        return user32.CallNextHookEx(self._hook, ncode, wparam, lparam)

    def _install(self):
        """(Re)arm the hook: install the new one first, then drop the old, so there is
        never a moment with no hook."""
        new = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._proc, kernel32.GetModuleHandleW(None), 0)
        if not new:
            self.rehook_errors += 1
            return False
        old, self._hook = self._hook, new
        if old:
            user32.UnhookWindowsHookEx(old)
        self.rehooks += 1
        return True

    def _run(self):
        self._tid = kernel32.GetCurrentThreadId()
        if not self._install():
            raise ctypes.WinError(ctypes.get_last_error())
        user32.SetTimer(None, 0, REHOOK_MS, None)  # thread timer -> WM_TIMER below
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_TIMER:
                self._install()
        user32.UnhookWindowsHookEx(self._hook)

    def start(self):
        threading.Thread(target=self._run, name="kbhook", daemon=True).start()

    def stop(self):
        if self._tid:
            user32.PostThreadMessageW(self._tid, WM_QUIT, 0, 0)
