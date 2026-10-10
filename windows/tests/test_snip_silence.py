"""Snip-proofing + silence auto-stop tests (pure logic, no keystrokes, no mic)."""
import numpy as np

from sotto.audio import BLOCK, SR, Recorder, VoiceActivity
from sotto.hotkey import ComboTracker
from sotto.statemachine import TapHold

RALT = 0xA5


def test_lost_release_does_not_eat_next_tap():
    c, sm = ComboTracker(["rmenu"]), TapHold(0.5)
    _, e = c.feed(RALT, 0, True, 10.0)
    assert sm.down(10.0) == "start" and e == "down"
    # the key-up gets swallowed by a snip overlay; user taps again 8 s later
    _, e = c.feed(RALT, 0, True, 18.0)
    assert e == "down"  # old behavior: None (tap ignored, Sotto "stopped working")
    assert sm.down(18.0) == "stop"
    assert c.stale_resets == 1


def test_autorepeat_while_held_is_not_a_new_press():
    c = ComboTracker(["rmenu"])
    assert c.feed(RALT, 0, True, 0.0)[1] == "down"
    t = 0.5
    while t < 3.0:  # autorepeat every 33 ms after the 500 ms delay
        assert c.feed(RALT, 0, True, t)[1] is None
        t += 0.033
    assert c.feed(RALT, 0, False, t)[1] == "up"
    assert c.stale_resets == 0


def _tone(sec, db):
    t = np.arange(int(sec * SR)) / SR
    amp = 10 ** (db / 20) * np.sqrt(2)
    return (amp * np.sin(2 * np.pi * 200 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)


def _noise(sec, db, seed=0):
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(int(sec * SR)) * 10 ** (db / 20)).astype(np.float32)


def _drive(rec, audio):
    for i in range(len(audio) // BLOCK):
        rec._cb(audio[i * BLOCK:(i + 1) * BLOCK, None], BLOCK, None, None)


class _FakeStream:
    active = True


def test_recorder_tracks_silence_and_trims(tmp_path):
    rec = Recorder(keep_open=False)
    rec._stream = _FakeStream()
    _drive(rec, _noise(3, -50))           # idle room tone: calibrates
    rec.start(tmp_path / "t.wav")
    _drive(rec, _tone(5, -15) + _noise(5, -50, 1))   # talking
    assert rec.silence_s() < 0.6
    _drive(rec, _noise(31, -50, 2))       # 31 s of room tone
    assert 30 <= rec.silence_s() <= 31.6
    audio, dur = rec.stop(trim_silence=True)
    assert 5.5 <= dur <= 7.0              # dead tail trimmed from the RAM copy
    import wave
    with wave.open(str(tmp_path / "t.wav")) as w:   # full take still on disk
        assert w.getnframes() / SR >= 36


def test_clicks_are_not_speech():
    v = VoiceActivity()
    room = _noise(12, -50, 3)
    hits = 0
    for i in range(len(room) // BLOCK):
        x = room[i * BLOCK:(i + 1) * BLOCK].copy()
        if i % 10 == 0:                   # a sharp click every 200 ms (typing/mouse)
            x[:40] += 0.3
        hits += v.feed(x)
    assert hits == 0
