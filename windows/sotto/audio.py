"""Mic capture: always-open 16 kHz mono stream with pre-roll ring buffer.
Audio streams to a WAV on disk while you speak (crash-safe) and is also kept
in RAM so transcription never re-reads the file."""
import collections
import os
import queue
import threading
import time
import wave

import numpy as np
import sounddevice as sd

SR = 16000
BLOCK = 320  # 20 ms


class VoiceActivity:
    """Is someone talking? Judged per 20 ms block from loudness alone.

    Tuned on 101 real dictation takes: speech ~-14 dB, room tone -47..-85 dB
    (the mic's noise gate sometimes outputs near-digital silence), longest natural
    pause 4.4 s. A block is "voiced" if it is within 22 dB of this voice's learned
    loudness (and 12 dB over the noise floor); speech = 10 voiced blocks in the last
    0.5 s, so single clicks/keyboard taps don't count as talking."""

    def __init__(self, window=25, need=10, floor_s=10.0):
        self.need = need
        self.recent = collections.deque(maxlen=window)
        self.levels = collections.deque(maxlen=int(floor_s * SR / BLOCK))
        self.floor = -60.0
        self.ref = -20.0  # learned speaking loudness (dB)
        self._n = 0

    def feed(self, x):
        """-> True while speech is present."""
        db = 10 * np.log10(float(np.mean(x * x)) + 1e-12)
        self.levels.append(db)
        self._n += 1
        if self._n < 25 or self._n % 25 == 0:
            self.floor = float(np.percentile(self.levels, 10))
        if db > max(self.floor + 20, -40.0):  # clearly speech: learn how loud this voice is
            self.ref = max(-35.0, 0.995 * self.ref + 0.005 * db)
        self.recent.append(db > max(self.floor + 12, self.ref - 22, -60.0))
        return sum(self.recent) >= self.need


class Recorder:
    def __init__(self, device=None, preroll_s=0.25, keep_open=True, log=print):
        self.device = device
        self.keep_open = keep_open
        self.log = log
        self.level = 0.0
        self._pre = collections.deque(maxlen=max(1, int(preroll_s * SR / BLOCK)))
        self._lock = threading.Lock()
        self._rec = False
        self._chunks = []
        self._wq: queue.Queue | None = None
        self._writer = None
        self._stream = None
        self._started = 0.0
        self.interrupted = False
        self.zero_blocks = 0
        self.opened_name = None
        self.vad = VoiceActivity()
        self._take_n = 0        # samples in the current take (incl. pre-roll)
        self._last_voice_n = 0  # take sample index where speech was last heard
        if keep_open:
            self._open()

    # --- stream -----------------------------------------------------------
    @staticmethod
    def input_devices():
        """WASAPI input devices (full names). -> [(idx, name)]"""
        out = []
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] > 0 and sd.query_hostapis(d["hostapi"])["name"] == "Windows WASAPI":
                out.append((i, d["name"]))
        return out

    @staticmethod
    def windows_default_name():
        """Live Windows default recording device (not PortAudio's stale cache)."""
        try:
            import soundcard
            return soundcard.default_microphone().name
        except Exception:
            return None

    def wanted_name(self):
        if self.device in (None, "", "default"):
            return self.windows_default_name()
        return str(self.device)

    def _find(self, name):
        if not name:
            return None
        for i, n in self.input_devices():
            if n.lower() == name.lower():
                return i
        for i, n in self.input_devices():
            if name.lower() in n.lower() or n.lower() in name.lower():
                return i
        return None

    def _open(self, reinit=False):
        self._close()
        name = self.wanted_name()
        idx = None if reinit else self._find(name)
        if idx is None:  # device list is stale (plugged in / woke up later): re-enumerate
            try:
                sd._terminate(); sd._initialize()
            except Exception as e:
                self.log(f"portaudio reinit: {e}")
            idx = self._find(name)
        self.zero_blocks = 0
        kw = {}
        if idx is not None:
            kw["extra_settings"] = sd.WasapiSettings(auto_convert=True)  # Windows resamples to 16k
        else:
            self.log(f"mic {name!r} not found in PortAudio; using PortAudio default")
        self._stream = sd.InputStream(samplerate=SR, channels=1, dtype="float32",
                                      blocksize=BLOCK, device=idx,
                                      callback=self._cb, latency="low", **kw)
        self._stream.start()
        self.opened_name = name
        self.log(f"mic open: {sd.query_devices(idx if idx is not None else sd.default.device[0])['name']}")

    def _close(self):
        if self._stream is not None:
            try:
                self._stream.stop(); self._stream.close()
            except Exception:
                pass
            self._stream = None

    def healthy(self):
        return self._stream is not None and self._stream.active

    def dead(self):
        """Pure digital zeros for >0.5 s: device asleep/disconnected/muted.
        Real mics always have a noise floor."""
        return self.zero_blocks > 25

    def _cb(self, indata, frames, t, status):
        x = indata[:, 0].copy()
        self.zero_blocks = self.zero_blocks + 1 if not x.any() else 0
        rms = float(np.sqrt(np.mean(x * x)) + 1e-9)
        self.level = 0.6 * self.level + 0.4 * min(1.0, rms * 12)
        voice = self.vad.feed(x)  # runs while idle too, so it's calibrated before you talk
        with self._lock:
            if self._rec:
                self._chunks.append(x)
                self._wq.put(x)
                self._take_n += len(x)
                if voice:
                    self._last_voice_n = self._take_n
            else:
                self._pre.append(x)

    # --- take -------------------------------------------------------------
    def start(self, wav_path):
        if not self.healthy() or self.dead():
            self._open(reinit=self.dead())  # dead stream / first use / keep_open=False
        f = open(wav_path, "wb", buffering=0)  # unbuffered: each 20 ms block hits the OS immediately
        wf = wave.open(f, "wb")
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SR)
        self._wq = queue.Queue()
        self._writer = threading.Thread(target=self._write, args=(wf, f, self._wq), daemon=True)
        self._writer.start()
        with self._lock:
            self._chunks = list(self._pre)
            for c in self._chunks:
                self._wq.put(c)
            self._pre.clear()
            self._take_n = self._last_voice_n = sum(len(c) for c in self._chunks)
            self._rec = True
        self._started = time.perf_counter()

    @staticmethod
    def _write(wf, f, q):
        """Crash-proof take file. Unbuffered writes mean a process crash loses nothing
        already captured; wave re-patches the header sizes on every write so the file
        is always a valid WAV; fsync every 0.2 s pushes it to the physical disk so even
        a power cut / BSOD loses at most ~0.2 s."""
        last_sync = time.monotonic()
        try:
            while True:
                c = q.get()
                if c is None:
                    break
                wf.writeframes((np.clip(c, -1, 1) * 32767).astype("<i2").tobytes())
                now = time.monotonic()
                if now - last_sync >= 0.2:
                    os.fsync(f.fileno())
                    last_sync = now
        finally:
            try:
                wf.close()  # final header patch (does not close f: we passed a file object)
            finally:
                try:
                    os.fsync(f.fileno())
                except OSError:
                    pass
                f.close()

    def silence_s(self):
        """Seconds since speech was last heard in the current take."""
        return (self._take_n - self._last_voice_n) / SR

    def stop(self, trim_silence=False):
        """-> (float32 audio, seconds). trim_silence: drop the dead tail after the
        last speech (+1 s) from the in-RAM copy; the WAV on disk keeps everything."""
        with self._lock:
            self._rec = False
            chunks, self._chunks = self._chunks, []
            keep = self._last_voice_n + SR
        if self._wq is not None:
            self._wq.put(None)
            self._writer.join(timeout=2)
            self._wq = None
        if not self.keep_open:
            self._close()
        audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
        if trim_silence:
            audio = audio[:keep]
        return audio, len(audio) / SR


def repair_wav_header(path):
    """Fix RIFF/data sizes from real file length (crash mid-take)."""
    import struct
    with open(path, "r+b") as f:
        data = f.read()
        if len(data) < 44 or data[:4] != b"RIFF":
            return
        i = data.find(b"data")
        if i < 0:
            return
        size = len(data) - (i + 8)
        f.seek(4); f.write(struct.pack("<I", len(data) - 8))
        f.seek(i + 4); f.write(struct.pack("<I", size))


def read_wav(path):
    repair_wav_header(path)
    with wave.open(str(path), "rb") as wf:
        raw = wf.readframes(wf.getnframes())
    return np.frombuffer(raw, "<i2").astype(np.float32) / 32768.0
