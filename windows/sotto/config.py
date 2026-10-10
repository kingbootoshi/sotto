"""Paths + user settings (config.json in %LOCALAPPDATA%\\Sotto)."""
import json
import os
from pathlib import Path

APP_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Sotto"
HISTORY_DIR = APP_DIR / "History"
CONFIG_PATH = APP_DIR / "config.json"
LOG_PATH = APP_DIR / "sotto.log"

DEFAULTS = {
    # Keys that make up the hotkey. All must be held. Names: rmenu (Right Alt),
    # lmenu, rcontrol, lcontrol, rshift, lshift, rwin, apps, capital, scroll,
    # pause, f13..f24, or raw "vk:0xA5" / "sc:0x63" (use `--probe` to find codes).
    "hotkey": ["rmenu"],
    # Swallow the hotkey keys so Right Alt never pops app menus.
    "suppress_hotkey": True,
    # Down→up longer than this = push-to-talk (release stops). Shorter = toggle.
    "hold_threshold_s": 0.5,
    "min_duration_s": 0.3,
    "model": "nemo-parakeet-tdt-0.6b-v2",
    # Keep the mic stream open 24/7: zero start latency + pre-roll so the first
    # syllable is never clipped. Windows will show the mic-in-use indicator.
    "keep_mic_open": True,
    "preroll_s": 0.25,
    "input_device": None,
    "append_space": True,
    "auto_paste": True,
    "sounds": True,
    "comet": False,
    # Esc while recording discards the paste. Off: Esc is how you back out of a
    # snip/screenshot, and that must never kill a take. Only the hotkey ends one.
    "esc_cancels": False,
    # Auto-stop (and paste) after this many seconds with no speech. 0 = never.
    "auto_stop_silence_s": 30,
}


def load() -> dict:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
        except Exception:
            pass
    else:
        CONFIG_PATH.write_text(json.dumps(DEFAULTS, indent=2), encoding="utf-8")
    return cfg


def save_key(key, value):
    cfg = load()
    cfg[key] = value
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
