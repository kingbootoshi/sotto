"""Mic capture: always-open 16 kHz mono stream with pre-roll ring buffer.
Audio streams to a WAV on disk while you speak (crash-safe) and is also kept
in RAM so transcription never re-reads the file."""
import collections
import queue
import threading
import time
import wave

import numpy as np
import sounddevice as sd

SR = 16000
BLOCK = 320  # 20 ms


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
        with self._lock:
            if self._rec:
                self._chunks.append(x)
                self._wq.put(x)
            else:
                self._pre.append(x)

    # --- take -------------------------------------------------------------
    def start(self, wav_path):
        if not self.healthy() or self.dead():
            self._open(reinit=self.dead())  # dead stream / first use / keep_open=False
        wf = wave.open(str(wav_path), "wb")
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(SR)
        self._wq = queue.Queue()
        self._writer = threading.Thread(target=self._write, args=(wf, self._wq), daemon=True)
        self._writer.start()
        with self._lock:
            self._chunks = list(self._pre)
            for c in self._chunks:
                self._wq.put(c)
            self._pre.clear()
            self._rec = True
        self._started = time.perf_counter()

    @staticmethod
    def _write(wf, q):
        while True:
            c = q.get()
            if c is None:
                break
            wf.writeframes((np.clip(c, -1, 1) * 32767).astype("<i2").tobytes())
        wf.close()

    def stop(self):
        """-> (float32 audio, seconds)."""
        with self._lock:
            self._rec = False
            chunks, self._chunks = self._chunks, []
        if self._wq is not None:
            self._wq.put(None)
            self._writer.join(timeout=2)
            self._wq = None
        if not self.keep_open:
            self._close()
        audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
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
