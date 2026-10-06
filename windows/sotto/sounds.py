"""Felt-not-heard sound set, synthesized at launch (no assets).
F/C anchor tones, soft envelopes, gentle low-pass. Played async via winsound."""
import threading
import wave
import winsound

import numpy as np

from .config import APP_DIR

SR = 44100
F4, C5, F5, C4, F3 = 349.23, 523.25, 698.46, 261.63, 174.61


def _env(n, a=0.004, d=0.12):
    t = np.arange(n) / SR
    return np.minimum(1, t / a) * np.exp(-t / d)


def _lp(x, cutoff=2000):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x); acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def _tone(freqs, dur, d=0.1, vol=0.25, partials=(1, 2.01, 3.99), pw=(1, .35, .12)):
    n = int(SR * dur); t = np.arange(n) / SR
    x = sum(w * np.sin(2 * np.pi * f * p * t) for f in freqs for p, w in zip(partials, pw))
    return _lp(x * _env(n, d=d)) * vol


def _make():
    n = int(SR * 0.35)
    rng = np.random.default_rng(7)
    noise = rng.standard_normal(n) * _env(n, a=0.002, d=0.05)
    return {
        "ack": _tone([F5], 0.18, d=0.05, vol=0.22, partials=(1, 3.9), pw=(1, .25)),   # wood bar
        "stop": _tone([C5, F4], 0.30, d=0.11, vol=0.18),                               # felt piano merge
        "arrive": _lp(noise, 1800) * 0.10 + _tone([F3], 0.35, d=0.12, vol=0.22),        # splash + sub
        "error": _tone([C4], 0.28, d=0.12, vol=0.2),
    }


class Sounds:
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.paths = {}
        if enabled:
            threading.Thread(target=self._build, daemon=True).start()

    def _build(self):
        d = APP_DIR / "sfx"; d.mkdir(parents=True, exist_ok=True)
        for name, x in _make().items():
            p = d / f"{name}.wav"
            with wave.open(str(p), "wb") as wf:
                wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SR)
                wf.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
            self.paths[name] = str(p)

    def play(self, name):
        p = self.paths.get(name)
        if self.enabled and p:
            winsound.PlaySound(p, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
