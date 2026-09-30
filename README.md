# QNotch

A personal, performance-first "notch" overlay for Windows 11. A near-black pill sits at the top edge of your monitor and shows live CPU, RAM, network, battery, clock and what is playing. Hover it (or press the hotkey) and it opens into a panel: system stats, now playing with seek and transport controls, clipboard history, AI tool usage and app shortcuts, a quick note, a GitHub contribution graph, and a file tray. When a game or fullscreen video owns the screen, the notch turns into a passive one-line status bar. See `SPEC.md` for the full specification and `ARCHITECTURE.md` for the architecture: a small shell plus six self-contained extensions (Media, Clipboard, Ai, NoteGithub, FileTray, Stats), each in `src/QNotch/Modules/<Name>/`.

Stack: C# on .NET 10, WPF, x64. The only NuGet package is CommunityToolkit.Mvvm. Native calls use `LibraryImport`; no WinForms.

## Build, publish, run

Requires the .NET 10 SDK and Windows 10 2004 or newer (Windows 11 recommended). The published exe is framework-dependent, so the .NET 10 Desktop Runtime must be installed.

```powershell
dotnet build -c Release                                                # development build
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64      # ReadyToRun, single file, into dist\
dist\QNotch.exe
```

Only one instance runs at a time. Quit from the tray icon menu. The tray icon turns amber while Game mode is forced or the game bar is showing.

## Features

Settings, Features has one switch per feature: System stats, Now playing, Clipboard history, AI apps and usage, Note and GitHub, File tray. A feature that is off is never loaded and costs nothing (no timers, hooks, hotkeys, cards or tabs). Changes apply after a restart: the page shows "Restart QNotch to apply your changes." with a "Restart now" button. Game mode and Edit mode are part of the shell and always available. `ARCHITECTURE.md` explains how to add an extension.

## Hotkeys

| Keys | Action |
| --- | --- |
| Ctrl+Alt+N | Toggle the panel (changeable in Settings, General) |
| Ctrl+Alt+G | Cycle Game mode: Auto, Force on, Force off (changeable) |
| Alt+1 to Alt+6 | Launch the AI tool bound to that slot (Settings, AI) |
| Esc | Close the panel |

To change a hotkey, open Settings, General, click the box and press the new shortcut. A shortcut that another app already owns is flagged inline.

## Data folder

`%APPDATA%\QNotch\` holds one JSON file per module (`general.json`, `ai.json`, `clipboard.json`, and so on), the note, and `logs\` (`qnotch.log`, `crash.log`). Clipboard history lives in memory only unless you turn on "Keep history between sessions" (text only). The GitHub token is stored in Windows Credential Manager, never in a file. Set `QNOTCH_DATA_DIR` to a full path to use another folder, and `QNOTCH_INSTANCE` to a suffix to allow a second instance next to the first (both are for parallel test runs).

## Measured performance

Published build (`dist\QNotch.exe`, ReadyToRun, single file), Windows 11 Pro 10.0.26200, 24 logical cores, collapsed and idle:

| Metric | Result | Spec target |
| --- | --- | --- |
| Cold start to visible pill | about 495 to 540 ms (window handle polled from Process.Start) | under 300 ms |
| Working set (8 s after start) | about 42 MB | under 80 MB |
| Private bytes | about 52 to 54 MB | n/a |
| Idle CPU, 60 s window | 46.9 ms CPU time, 0.08% of one core (0.003% of the whole machine) | 0.1% |
| Idle CPU, 20 s windows (4 runs) | 0 to 94 ms | 0.1% |
| Working set after copying a 4K screenshot (settled) | about 85 MB | under 80 MB |

The idle numbers come from `Get-Process` CPU time over the window, taken 8 s after launch.

## Known gaps

- Cold start misses the 300 ms target. About 150 ms is runtime and WPF startup, and about 200 ms is first-use cost inside the first WPF window. Warming fonts and control types on a pool thread already saved about 80 ms.
- Copying a 4K screenshot transiently peaks near 185 MB before the heap is compacted about 3 s later, and settles slightly above 80 MB. Smaller images stay well below.
- Game mode frame-time readout is reserved but not implemented (needs a presentation hook).
- After Game mode turns on, the GPU segment reads `n/a` for about one sampling interval (5 s) while the GPU counter primes.
- The media session fix (one entry per session, even for two tabs of one app) and the clipboard worker were verified by build, self-test and a scripted clipboard run, not with several live media sources.
