SOTTO for Windows
=================

Local dictation. Tap Right Alt, talk, tap Right Alt again: your words paste
wherever your cursor is. Runs 100% on your PC (NVIDIA Parakeet TDT 0.6B v2,
English). No cloud, no account, no audio leaves the machine.

INSTALL
  1. Unzip this folder somewhere permanent (e.g. C:\Apps\Sotto). Don't run it
     from inside the zip.
  2. Double-click Sotto.exe. If SmartScreen complains ("Windows protected your
     PC"), click "More info" -> "Run anyway" (the app isn't code-signed).
  3. Wait ~10-30 s the first time while the model loads onto your GPU. The
     orange waveform icon appears in the tray (click ^ near the clock).
  It adds itself to startup, so it's always on after that.

USE
  Tap Right Alt        start / stop (toggle)
  Hold Right Alt       push-to-talk: stops when you let go
  Esc while recording  cancel the paste (the transcript is still saved)
  Right Alt is taken over by Sotto. Left Alt still works normally.

TRAY MENU (right-click the icon)
  Copy last transcript | Microphone | Open History folder | Settings |
  Open log | Start with Windows | Restart | Quit

SETTINGS  %LOCALAPPDATA%\Sotto\config.json (Settings in the tray menu), then Restart.
  "hotkey": ["rmenu"]      any key or combo, e.g. ["rmenu","rcontrol"], ["f13"],
                           "vk:0x.." / "sc:0x.." codes
  "keep_mic_open": true    instant start + 0.25 s pre-roll (mic indicator stays on)
  "auto_paste": true       false = clipboard only
  "sounds": true

REQUIREMENTS
  Windows 10/11 64-bit. Any DirectX 12 GPU (NVIDIA / AMD / Intel); falls back
  to CPU (slower) if there isn't one. ~1.5 GB disk, ~2 GB RAM/VRAM.

TROUBLESHOOTING
  "Mic sent pure silence"  your mic is muted / asleep / the wrong one: check
                           the mute button, or pick it in tray -> Microphone.
  Nothing happens in admin windows  Windows blocks hotkeys from normal apps
                                    while an elevated window has focus.
  Logs: %LOCALAPPDATA%\Sotto\sotto.log   Recordings: %LOCALAPPDATA%\Sotto\History
  Uninstall: tray -> untick Start with Windows -> Quit, delete the folder
             and %LOCALAPPDATA%\Sotto.
