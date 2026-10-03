# QNotch

A performance-first "notch" overlay for Windows 11. A near-black pill sits at the top edge of your monitor and shows live CPU, GPU, RAM, battery, clock and what is playing. Hover it (or press the hotkey) and it opens into a panel: system stats, now playing with seek and transport controls, clipboard history, search, AI app shortcuts and usage, a quick note, a GitHub contribution graph, a file tray, volume, a timer, a color picker, your scheduled tasks, and notifications that any app or script can post. When a game or fullscreen video owns the screen, the notch turns into a passive one-line status bar.

It is a small shell plus self-contained extensions, one per folder in `src/QNotch/Modules/`. `SPEC.md` is the full specification and `ARCHITECTURE.md` explains the code and how to add an extension.

Stack: C# on .NET 10, WPF, x64. The only NuGet package is CommunityToolkit.Mvvm. Native calls use `LibraryImport`; no WinForms.

## Install

Windows 10 2004 or newer (Windows 11 recommended), x64. Each release has two downloads:

- `QNotch.exe`: small, needs the [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) installed.
- `QNotch-self-contained.zip`: about 80 MB, includes the runtime, nothing else to install.

Only one instance runs at a time. Quit from the tray icon menu. The tray icon turns amber while Game mode is forced or the game bar is showing.

## Build

Requires the .NET 10 SDK.

```powershell
dotnet build -c Release                                                                # development build
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64                      # framework-dependent, into dist\
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64-self-contained       # with the runtime, into dist\self-contained\
dist\QNotch.exe
```

Both profiles are ReadyToRun and single file. `QNotch.exe --snapshot <dir>` renders every tab and settings page to PNG without touching your settings: CI runs it on every push.

## Features

Settings, Features has one switch per feature: System stats, Now playing, Clipboard history, AI apps and usage, Note, GitHub, File tray, Notifications, Scheduled tasks, Volume, Timer, Color picker, Search. A feature that is off is never loaded and costs nothing (no timers, hooks, hotkeys, cards or tabs). Changes apply after a restart: the page shows "Restart QNotch to apply your changes." with a "Restart now" button. Game mode and Edit mode are part of the shell and always available.

The Claude Code usage reading sends your local Claude Code sign-in token to Anthropic's usage endpoint, which is undocumented and can change without notice. Turn it off in Settings, AI if you prefer. Codex usage is read from Codex's local logs and sends nothing.

## Scheduled tasks

The Scheduled tab and Home card list the tasks you added to the Windows Task Scheduler (root folder; tasks installed by a vendor such as OneDrive are left out): schedule, next run and last run. Each row has pause or resume and delete (delete asks once more). The list is read when the panel opens, so it costs nothing while collapsed.

## Notifications

Any app, script or agent can post a notification. It shows as a toast under the pill, counts as unread in the pill, and stays in the Notifications tab and Home card. Settings, Notifications has the toast time, the history retention, per-app mute and the HTTP token.

```powershell
QNotch.exe notify "Build finished" "142 tests passed" --app Build --level success --url https://example.com/report
QNotch.exe notify "Claude needs you" --app "Claude Code" --icon chat --focus          # button that brings the calling terminal forward
QNotch.exe notify "Run the tests?" --action approve=Approve --action deny=Deny        # waits, prints the clicked id
QNotch.exe notify --help
```

Exit codes: 0 sent or answered, 1 dismissed, 2 timed out, 3 QNotch not running, 4 error. `QNotch.exe` is a GUI program, so an interactive shell does not wait for it: capture the output (`$answer = QNotch.exe notify ...`) when you need the answer. Hooks and scripts that capture output wait as usual.

The payload behind every option (only `title` is required):

```json
{
  "id": "build-42",
  "app": "Build",
  "title": "Build finished",
  "body": "142 tests passed",
  "icon": "C:\\tools\\build.png",
  "level": "success",
  "ttl": 8,
  "wait": false,
  "timeout": 0,
  "actions": [
    { "label": "Open report", "url": "https://example.com/report" },
    { "label": "Show", "focusPid": 1234 },
    { "id": "approve", "label": "Approve" }
  ]
}
```

- `id`: posting the same id again replaces the notification (progress updates). `{"op":"dismiss","id":"build-42"}` removes it.
- `icon`: an image path, an exe or shortcut path (its icon is used), or a glyph name: bell, info, check, warning, error, chat, code, link, clock, download, bolt, person, folder, globe, mail, play, build. Local drive paths only.
- `level`: info, success, warning or error. An error opens the panel by itself (not in Game mode; can be turned off).
- `ttl`: toast seconds, 0 for no toast.
- `actions`: three at most. `url` opens a link (http, https, vscode, vscode-insiders, cursor, claude). `focusPid` brings that process's window forward, or the window of its nearest parent that has one (a script's terminal). An action with neither only answers a waiting request. Nothing can run a program.
- `wait`: the request stays open until the user clicks an action or dismisses the notification, then answers `{"ok":true,"id":"...","result":"clicked","action":"approve"}` (`result` is `clicked`, `dismissed` or `timeout`). `timeout` is in seconds, 0 means no limit. In Game mode a waiting request is held until the game ends.

Three ways in, same payload:

| Way | How | Who can use it |
| --- | --- | --- |
| Command line | `QNotch.exe notify`, or `--json` / `--stdin` for a raw payload | anything that can start a program |
| Named pipe | connect to `\\.\pipe\QNotch.Notify`, write one line of JSON, read one line back | programs under your Windows account only |
| HTTP | `POST http://127.0.0.1:47821/notify` (add `?wait=1` to wait), `DELETE /notify/{id}` | this computer only, with the header `Authorization: Bearer <token>` |

```bash
curl -X POST http://127.0.0.1:47821/notify -H "Authorization: Bearer <token>" -d '{"title":"Deploy done","app":"CI","level":"success"}'
```

Copy the token from Settings, Notifications. Requests that carry an `Origin` header (web pages) are refused. Titles are cut at 80 characters, descriptions at 300, messages at 64 KB, and an app gets one toast per second (the rest goes straight to the history).

Claude Code example (`~/.claude/settings.json`), a toast with a button back to the session whenever Claude waits for you:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "C:\\path\\to\\QNotch.exe notify \"Claude needs you\" --app \"Claude Code\" --icon chat --focus" }] }
    ]
  }
}
```

## Hotkeys

| Keys | Action |
| --- | --- |
| Ctrl+Alt+N | Toggle the panel |
| Ctrl+Alt+G | Cycle Game mode: Auto, Force on, Force off |
| Ctrl+Alt+F | Open search |
| Alt+1 to Alt+6 | Launch the AI app bound to that slot (Settings, AI) |
| Esc | Close the panel |

To change a hotkey, open Settings, Hotkeys, click the box and press the new shortcut. A shortcut that another app already owns is flagged inline.

## Data folder

`%APPDATA%\QNotch\` holds one JSON file per module (`general.json`, `ai.json`, `clipboard.json`, and so on), the note, and `logs\` (`qnotch.log`, `crash.log`). Clipboard history lives in memory only unless you turn on "Keep history between sessions" (text only). Notifications keep their history in `notifications.history.json` for the retention period (7 days by default). The GitHub token and the notification HTTP token are stored in Windows Credential Manager, never in a file. Set `QNOTCH_DATA_DIR` to a full path to use another folder, and `QNOTCH_INSTANCE` to a suffix to allow a second instance next to the first (both are for parallel test runs).

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

## Contributing

Bug reports, fixes and new extensions are welcome. See `CONTRIBUTING.md`.

## License

MIT, see `LICENSE`.
