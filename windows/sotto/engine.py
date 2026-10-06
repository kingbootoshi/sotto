"""Parakeet TDT via onnx-asr. Loaded once, kept hot.

Provider order: CUDA (onnxruntime-gpu + CUDA libs) > DirectML (any DX12 GPU -
what the shareable .exe ships) > CPU. Model: bundled folder
models/parakeet-tdt-0.6b-v2-fp16 next to the app if present, else HF hub."""
import sys
import threading
import time
from pathlib import Path

import numpy as np

PREFERRED = ("CUDAExecutionProvider", "DmlExecutionProvider", "CPUExecutionProvider")
BUNDLED_NAME = "parakeet-tdt-0.6b-v2-fp16"


def app_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parents[1]


def bundled_model_dir():
    for base in (app_root(), Path(getattr(sys, "_MEIPASS", app_root()))):
        d = base / "models" / BUNDLED_NAME
        if (d / "encoder-model.onnx").exists():
            return d
    return None


def load_asr(model_name, providers):
    import onnx_asr
    local = bundled_model_dir()
    if local:
        return onnx_asr.load_model(model_name, local, providers=providers), "bundled"
    return onnx_asr.load_model(model_name, providers=providers), "hub"


class Engine:
    def __init__(self, model_name, log=print):
        self.model_name = model_name
        self.log = log
        self.model = None
        self.provider = "?"
        self.ready = threading.Event()
        self.error = None
        self._lock = threading.Lock()

    def load(self):
        try:
            import onnxruntime as ort
            ort.set_default_logger_severity(3)
            if hasattr(ort, "preload_dlls"):
                try:
                    ort.preload_dlls()  # CUDA/cuDNN DLLs from nvidia-* wheels (gpu build only)
                except Exception as e:
                    self.log(f"preload_dlls: {e}")
            avail = ort.get_available_providers()
            provs = [p for p in PREFERRED if p in avail]
            t = time.perf_counter()
            self.model, src = load_asr(self.model_name, provs)
            self.provider = provs[0]
            # Warm-up so the first real take doesn't pay kernel init / shape compile.
            for n in (1, 2, 3, 5, 8, 1):
                self.model.recognize(np.zeros(16000 * n, np.float32), sample_rate=16000)
            self.log(f"model ready on {self.provider} ({src}) in {time.perf_counter() - t:.1f}s")
            self.ready.set()
        except Exception as e:
            self.error = e
            self.log(f"MODEL LOAD FAILED: {e!r}")
            raise

    def transcribe(self, audio: np.ndarray) -> tuple[str, float]:
        with self._lock:
            t = time.perf_counter()
            # Pad very short takes - the encoder hates < ~0.5 s inputs.
            if len(audio) < 8000:
                audio = np.pad(audio, (0, 8000 - len(audio)))
            text = self.model.recognize(audio.astype(np.float32), sample_rate=16000)
            return (text or "").strip(), time.perf_counter() - t
