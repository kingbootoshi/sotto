"""Sotto for Windows - tap Right Alt, speak, tap again; words paste at the cursor.
Parakeet TDT 0.6B on the GPU via onnx-asr/ONNX Runtime CUDA. Fully local."""
import ctypes
import logging
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk

from . import autostart, config, history
from .audio import Recorder, read_wav
from .engine import Engine
from .hotkey import HotkeyHook
from .overlay import Overlay, cursor_pos
from .paste import copy, send_ctrl_v
from .sounds import Sounds
from .statemachine import TapHold

log = logging.getLogger("sotto")


def setup_logging():
    config.APP_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=config.LOG_PATH, level=logging.INFO, encoding="utf-8",
                        format="%(asctime)s %(levelname)s %(message)s")
    if sys.stdout and sys.stdout.isatty():
        logging.getLogger().addHandler(logging.StreamHandler(sys.stdout))


def single_instance():
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    h = k32.CreateMutexW(None, False, "Local\\SottoWinDictation")
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        return None
    return h


class App:
    def __init__(self):
        self.cfg = config.load()
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            pass
        self.root = tk.Tk()
        self.root.withdraw()
        scale = ctypes.windll.user32.GetDpiForSystem() / 96.0
        self.ui = queue.Queue()  # callables to run on Tk thread
        self.engine = Engine(self.cfg["model"], log=log.info)
        self.rec = Recorder(self.cfg["input_device"], self.cfg["preroll_s"],
                            self.cfg["keep_mic_open"], log=log.info)
        self.sounds = Sounds(self.cfg["sounds"])
        self.overlay = Overlay(self.root, lambda: self.rec.level, scale)
        self.sm = TapHold(self.cfg["hold_threshold_s"])
        self.hook = HotkeyHook(self.cfg["hotkey"], self.cfg["suppress_hotkey"], self.cfg["esc_cancels"])
        self.jobs = queue.Queue()  # transcription jobs, one GPU worker, FIFO
        self.current = None  # (tid, wav_path)
        self.tray = None

    # --- lifecycle ---------------------------------------------------------
    def run(self):
        threading.Thread(target=self._load_model, daemon=True).start()
        threading.Thread(target=self._worker, daemon=True).start()
        self.hook.start()
        self._start_tray()
        self.root.after(1500, self._first_run)
        self.root.after(5, self._pump)
        self.root.after(3000, self._watchdog)
        log.info("sotto up; hotkey=%s", self.cfg["hotkey"])
        self.root.mainloop()

    def _load_model(self):
        try:
            self.engine.load()
            self._title(f"Sotto - ready ({self.engine.provider.replace('ExecutionProvider', '')})")
            pend = history.unfinished()
            if pend:
                log.info("recovering %d unfinished takes", len(pend))
                for p in pend:
                    self.jobs.put(dict(wav=p, audio=None, deliver=False, aim=None, dur=0))
        except Exception as e:
            err = str(e)
            self._title("Sotto - MODEL FAILED (see log)")
            self.ui.put(lambda: self.overlay.error(f"Sotto: model failed to load: {err}", 6))

    def _pump(self):
        try:
            while True:
                kind, t = self.hook.events.get_nowait()
                self._on_key(kind, t)
        except queue.Empty:
            pass
        try:
            while True:
                self.ui.get_nowait()()
        except queue.Empty:
            pass
        self.root.after(5, self._pump)

    def _watchdog(self):
        # Mic unplugged / wireless headset asleep / default swapped: the always-on
        # stream goes dead (pure zeros). Reopen it, at most every 10 s.
        now = time.monotonic()
        if self.cfg["keep_mic_open"] and self.current is None:
            want = self.rec.wanted_name()
            if want and want != self.rec.opened_name:
                log.info("default mic changed -> %s", want)
                try:
                    self.rec._open()
                except Exception as e:
                    log.warning("mic switch failed: %s", e)
            elif ((not self.rec.healthy() or self.rec.dead())
                  and now - getattr(self, "_last_reopen", 0) > 10):
                self._last_reopen = now
                try:
                    self.rec._open(reinit=True); log.info("mic stream reopened (was dead)")
                except Exception as e:
                    log.warning("mic reopen failed: %s", e)
        self.root.after(2000, self._watchdog)

    def set_mic(self, name):
        self.cfg["input_device"] = name
        config.save_key("input_device", name)
        self.rec.device = name
        try:
            self.rec._open(reinit=True)
        except Exception as e:
            log.warning("mic switch failed: %s", e)
            self.overlay.error(f"Mic error: {e}", 3)

    # --- hotkey -> actions ---------------------------------------------------
    def _on_key(self, kind, t):
        if kind == "down":
            act = self.sm.down(t)
        elif kind == "up":
            act = self.sm.up(t)
        else:
            act = self.sm.esc()
        if act == "start":
            self._start()
        elif act in ("stop", "cancel"):
            self._stop(deliver=act == "stop")

    def _start(self):
        if not self.engine.ready.is_set():
            self.sm.force_idle()
            self.sounds.play("error")
            msg = "Model failed - check log" if self.engine.error else "Model still loading on the GPU..."
            self.overlay.error(msg, 1.8)
            return
        tid, wav = history.new_take()
        try:
            self.rec.start(wav)
        except Exception as e:
            log.exception("record start failed")
            self.sm.force_idle()
            self.overlay.error(f"Mic error: {e}", 3.5)
            self.sounds.play("error")
            return
        self.current = (tid, wav)
        self.hook.recording = True
        self.overlay.listening()
        self.sounds.play("ack")

    def _stop(self, deliver):
        aim = cursor_pos()  # the stop tap IS the aim moment
        self.hook.recording = False
        if not self.current:
            return
        tid, wav = self.current
        self.current = None
        audio, dur = self.rec.stop()
        if dur < self.cfg["min_duration_s"]:
            self.overlay.hide()
            try:
                if wav.stat().st_size < 8192:
                    wav.unlink()
            except OSError:
                pass
            return
        self.overlay.hide()  # instant: no orb / comet, text just appears
        if deliver:
            self.sounds.play("stop")
        silent = not audio.any()
        self.jobs.put(dict(wav=wav, audio=audio, deliver=deliver, aim=aim, dur=dur, silent=silent))

    # --- GPU worker ------------------------------------------------------------
    def _worker(self):
        while True:
            if getattr(self, "_restart_after", False) and self.jobs.empty():
                log.info("restarting for fresh CUDA context")
                time.sleep(0.3)
                os._exit(3)  # supervisor relaunches in ~2 s
            try:
                job = self.jobs.get(timeout=20)
            except queue.Empty:
                self._gpu_healthcheck()
                continue
            wav, deliver = job["wav"], job["deliver"]
            try:
                audio = job["audio"] if job["audio"] is not None else read_wav(wav)
                dur = job["dur"] or len(audio) / 16000
                try:
                    text, secs = self.engine.transcribe(audio)
                except Exception as ge:
                    if not self._is_gpu_dead(ge):
                        raise
                    # CUDA context is poisoned (sleep/resume, driver reset). Deliver this
                    # take on CPU right now, then restart the process to get the GPU back.
                    log.error("GPU dead (%s); CPU fallback + restart", str(ge)[:120])
                    text, secs = self._cpu_transcribe(audio)
                    self._restart_after = True
                history.finalize(wav, duration=round(dur, 2), model=self.cfg["model"], text=text,
                                 processingTime=round(secs, 3), provider=self.engine.provider)
                log.info("take %.2fs -> %d chars in %.0f ms (%.0fx RT)", dur, len(text), secs * 1000,
                         dur / max(secs, 1e-6))
                if not deliver:
                    continue
                if not text:
                    msg = ("Mic sent pure silence - muted/asleep or wrong mic. Right-click tray > Microphone."
                           if job.get("silent") else "Heard no words. Kept in History.")
                    self.ui.put(lambda m=msg: (self.sounds.play("error"), self.overlay.error(m, 3.0)))
                    continue
                out = text + (" " if self.cfg["append_space"] else "")
                copy(out)  # words are safe before any animation
                if self.cfg["auto_paste"]:
                    send_ctrl_v()
            except Exception as e:
                log.exception("transcription failed")
                try:
                    history.finalize(wav, text=None, error=repr(e), model=self.cfg["model"])
                except Exception:
                    pass
                if deliver:
                    self.ui.put(lambda: self.overlay.error("Transcription failed. Kept in History.", 3))

    @staticmethod
    def _is_gpu_dead(e):
        s = str(e)
        markers = ("cuda", "cublas", "cudnn", "887a0005", "887a0006", "device_removed", "device removed",
                   "dxgi_error", "e_outofmemory")
        return any(m in s.lower() for m in markers)

    def _gpu_healthcheck(self):
        # Runs while idle (every 20 s): catches a dead GPU after sleep BEFORE you dictate.
        if not self.engine.ready.is_set() or self.current is not None:
            return
        try:
            import numpy as np
            self.engine.transcribe(np.zeros(8000, np.float32))
        except Exception as e:
            if self._is_gpu_dead(e):
                log.error("healthcheck: GPU dead (%s) -> restart", str(e)[:120])
                os._exit(3)

    def _cpu_transcribe(self, audio):
        if getattr(self, "_cpu", None) is None:
            from .engine import load_asr
            self._cpu, _ = load_asr(self.cfg["model"], ["CPUExecutionProvider"])
        t0 = time.perf_counter()
        txt = self._cpu.recognize(audio.astype("float32"), sample_rate=16000)
        return (txt or "").strip(), time.perf_counter() - t0

    # --- tray -----------------------------------------------------------------
    def _title(self, s):
        if self.tray:
            self.tray.title = s

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw
        except Exception:
            log.warning("pystray unavailable; no tray icon")
            return
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((2, 14, 62, 50), 18, fill=(18, 18, 18, 255), outline=(255, 158, 28, 255), width=3)
        for i, hgt in enumerate((8, 16, 24, 14, 20, 10)):
            x = 13 + i * 7
            d.rectangle((x, 32 - hgt // 2, x + 3, 32 + hgt // 2), fill=(255, 158, 28, 255))

        def open_hist(*_):
            config.HISTORY_DIR.mkdir(parents=True, exist_ok=True)
            os.startfile(config.HISTORY_DIR)

        def copy_last(*_):
            t = history.last_text()
            if t:
                copy(t)

        def settings(*_):
            subprocess.Popen(["notepad.exe", str(config.CONFIG_PATH)])

        def restart(*_):
            self.tray.stop(); os._exit(3)  # supervisor relaunches

        def quit_(*_):
            self.tray.stop(); os._exit(0)

        def toggle_autostart(*_):
            autostart.disable() if autostart.is_enabled() else autostart.enable()

        def mic_items():

            items = [pystray.MenuItem("System default", lambda *_: self.ui.put(lambda: self.set_mic(None)),
                                      checked=lambda _: not self.cfg.get("input_device"), radio=True)]
            for _, name in self.rec.input_devices():
                items.append(pystray.MenuItem(
                    name, (lambda n: lambda *_: self.ui.put(lambda: self.set_mic(n)))(name),
                    checked=(lambda n: lambda _: self.cfg.get("input_device") == n)(name), radio=True))
            return items

        menu = pystray.Menu(
            pystray.MenuItem("Copy last transcript", copy_last, default=True),
            pystray.MenuItem("Microphone", pystray.Menu(lambda: mic_items())),
            pystray.MenuItem("Open History folder", open_hist),
            pystray.MenuItem("Settings (config.json)", settings),
            pystray.MenuItem("Open log", lambda *_: os.startfile(config.LOG_PATH)),
            pystray.MenuItem("Start with Windows", toggle_autostart,
                             checked=lambda _: autostart.is_enabled()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Restart", restart),
            pystray.MenuItem("Quit", quit_),
        )
        self.tray = pystray.Icon("sotto", img, "Sotto - loading model...", menu)
        threading.Thread(target=self.tray.run, daemon=True).start()

    def _first_run(self):
        flag = config.APP_DIR / ".first_run_done"
        if flag.exists():
            return
        flag.touch()
        try:
            autostart.enable()
        except Exception as e:
            log.warning("autostart enable failed: %s", e)
        if self.tray:
            try:
                self.tray.notify("Tap Right Alt, talk, tap again. Words paste at your cursor. "
                                 "Hold Right Alt for push-to-talk. Lives in the tray.", "Sotto is running")
            except Exception:
                pass


def main():
    setup_logging()
    if "--probe" in sys.argv:
        hk = HotkeyHook(["vk:0x00"], suppress=False, esc=False, probe=True)
        hk.start()
        print("Press keys (Ctrl+C to quit). Try Fn, Fn+Alt etc.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            return
    m = single_instance()
    if m is None:
        log.info("already running; exiting")
        return
    try:
        App().run()
    except Exception:
        log.exception("fatal")
        raise


if __name__ == "__main__":
    main()
