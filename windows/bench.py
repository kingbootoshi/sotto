"""Benchmark: load Parakeet on GPU, transcribe a TTS-generated WAV, report speed."""
import logging
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sotto.engine import Engine

logging.basicConfig(level=logging.INFO)
wav = Path(__file__).with_name("bench.wav")
if not wav.exists():
    text = ("Hey, this is a quick test of local dictation on Windows. The quick brown fox jumps over "
            "the lazy dog, and the RTX fifty seventy should make this nearly instant.")
    ps = (f"Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer;"
          f"$f=New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,'Sixteen','Mono');"
          f"$s.SetOutputToWaveFile('{wav}',$f); $s.Speak('{text}'); $s.Dispose()")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], check=True)
with wave.open(str(wav)) as wf:
    sr = wf.getframerate()
    audio = np.frombuffer(wf.readframes(wf.getnframes()), "<i2").astype(np.float32) / 32768
dur = len(audio) / sr
e = Engine("nemo-parakeet-tdt-0.6b-v2", log=print)
e.load()
for i in range(5):
    text, secs = e.transcribe(audio)
    print(f"run {i}: {dur:.2f}s audio -> {secs*1000:.0f} ms ({dur/secs:.0f}x realtime)")
print("TEXT:", text)
