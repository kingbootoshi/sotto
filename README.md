# Sotto

Menu-bar-only **local dictation** for macOS. Tap a hotkey, speak, tap again —
your words streak across the screen and paste wherever your cursor is.
Everything runs on your Mac: no cloud, no account, no audio leaves the device.

```
tap hotkey → WAV on disk → Parakeet TDT (Neural Engine) → orb charges → streak → ⌘V paste
```

## Why

Local ASR on Apple Silicon is now faster and more accurate than most cloud
dictation (~114× realtime measured on an M3 Max), so dictation can be private,
instant, and *fun*. Sotto treats the whole loop as one cinematic: a glass pill
with a live waveform while you speak, a felt-not-heard sound set, and a comet
that slingshots your transcript to the cursor.

## Features

- **Fully local**: [FluidAudio](https://github.com/FluidInference/FluidAudio)
  Parakeet TDT 0.6B v2 (English) or v3 (25 languages), CoreML on the Neural
  Engine. First run downloads the model (~1.2 GB), then it's offline forever.
- **Tap to toggle, hold to push-to-talk**: hold Fn (default), or right ⌘ / ⌥ / ⌃.
  Esc cancels. The transcript pastes into whatever app has focus.
- **Never lose a word**: audio streams to disk *while* you speak
  (`~/Library/Application Support/Sotto/History/yyyy-MM-dd/UUID.wav`); the
  JSON transcript record is written atomically after. Crash mid-sentence?
  The WAV survives, its header is repaired from real file length, and
  **Recover Unfinished Recordings** transcribes it. Mic vanished, disk full,
  engine died — every failure path saves first and says so; empty results are
  never pasted, and the transcript hits the clipboard before any animation
  runs.
- **The comet**: on stop, the pill contracts into a glowing orb, charges while
  the Neural Engine works, then slingshots — 110 ms pull-back, 260 ms
  streak — to where your mouse was **the instant you tapped stop** (ballistic;
  it never chases your cursor).
- **Felt, not heard**: a synthesized sound set tuned to F/C anchor tones
  through a 2 kHz low-pass ceiling — wood-bar ack, felt-piano merge, sub-swell
  charge, noise-splash arrive. Five packs, switchable in Settings. All
  synthesized offline at launch; no audio assets.
- **Menu-bar only**: no Dock icon, no windows. A waveform status item, a
  History folder, Settings, and nothing else.

## Build and install

```bash
./scripts/bundle.sh    # swift build -c release → /Applications/Sotto.app
```

Requires macOS 15+ and Apple Silicon (the ASR models are CoreML/ANE).
Permissions: **Microphone** (recording) and **Accessibility** (global hotkey +
synthesized ⌘V). The bundle script signs with a `Sotto Dev Signing` identity
if one exists in your keychain (stable signature = permission grants survive
rebuilds) and falls back to ad-hoc signing otherwise.

## Self-check

The app binary doubles as a headless transcriber — runnable proof of the exact
engine path the app uses:

```bash
swift build
./.build/debug/Sotto transcribe path/to/audio.wav
# prints transcript to stdout, confidence/timing to stderr
```

## Design workbenches

Every piece of motion and sound was chosen by feel from HTML workbenches in
`scripts/` — open them in a browser, click around, tweak sliders:

| Workbench | Picks |
|---|---|
| `launch-variants.html` | 5 slingshot launches (Streak shipped) |
| `thud-library.html` | 43 note-aware synth recipes, cue assignment, copy-as-Swift export |
| `sfx-packs.html` | the 5 shipped sound packs |
| `ux-variants.html` | the full dictation cinematic (Comet shipped) |
| `rim-variants*.html` | overlay ring animations (twin Tron snakes shipped) |

The loop: prototype in HTML, feel it, certify it, port 1:1 to Swift.

## Layout

| File | Owns |
|---|---|
| `main.swift` | app entry + `transcribe` CLI self-check |
| `DictationController.swift` | state machine: idle → arming → recording → transcribing |
| `TranscriptionEngine.swift` | FluidAudio AsrManager wrapper |
| `Recorder.swift` | AVAudioEngine → WAV + RMS levels, write-failure watchdog |
| `HistoryStore.swift` | dated WAV+JSON history, WAV header repair, unfinished scan |
| `HotkeyMonitor.swift` | global flagsChanged hold detection, Esc; `Paster` (⌘V) |
| `CometFlight.swift` | the streak flight + splash ring |
| `SoundPlayer.swift` | offline synth: packs, cues, 2 kHz ceiling |
| `Overlay.swift` | glass overlay panel + SwiftUI views |
| `AppDelegate.swift` | status item, menu, engine prewarm |
| `SettingsView.swift` | hotkey/model/sound pickers, launch at login |

## Roadmap

- Custom vocabulary (names, jargon) via FluidAudio CTC vocabulary boosting
- Fine-tuned personal Parakeet via NeMo → CoreML conversion
- Intro/exit animations for the pill

## License

[MIT](LICENSE)
