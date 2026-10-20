# Windows development

Run all commands below from the repository root on Windows x64 with the .NET 10 SDK. The solution still contains the Windows app only; Mac and website work do not require .NET.

## Build and regression checks

```powershell
dotnet build src/QNotch/QNotch.csproj -c Release -warnaserror
dotnet run --project tests/QNotch.UpdateTests -c Release
dotnet run --project tests/QNotch.PhoneShareTests -c Release
dotnet run --project tests/QNotch.OnboardingTests -c Release
```

The updater suite covers release selection, variant selection, checksums, executable validation, cancellation, replacement/recovery, and update settings. It consumes the shared release-tag fixtures to confirm Mac tags are ignored. The phone-sharing suite covers the existing transfer protocol. The onboarding suite covers when the welcome tour shows, what its choices write to `general.json`, and the GitHub device flow against canned responses, with no network.

## Snapshots

`--snapshot` follows [the shared diagnostics contract](../../spec/diagnostics.md). It does not open the interactive app or take the single-instance lock, so it runs next to a normal instance:

```powershell
src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe --snapshot snapshots
node scripts/check-snapshots.mjs snapshots
```

Without `--data-dir` (or `QNOTCH_DATA_DIR`) it uses a fresh temporary data folder and deletes it on exit. It loads every module with demo data: no network requests, no Credential Manager reads or writes, no autostart or update changes, a demo profile name.

- `--data-dir <path>`: the data folder to read (settings, logs); nothing is saved to it.
- `--only <patterns>`: only the views whose file name without `.png` matches, `*` for any run of characters, commas between patterns (`--only "tab-*,settings-general"`).
- `--appearance light|dark`: forces the theme (the positional `light` still works). Default: the system's.

Every PNG is rendered at 2x and has a text outline with the same name (`.txt`):

| File | View |
| --- | --- |
| `pill.png` | The collapsed pill, idle, with the glance strip |
| `pill-peek.png`, `pill-running.png`, `pill-capture.png`, `pill-waiting.png`, `pill-agent.png` | The pill with a peek, a running timer, the mic and camera in use, an agent that needs you, agents working |
| `pill-game.png`, `gamebar-corner.png` | The game bar, and the bar clamped into the corner |
| `tab-<id>.png`, `tab-home-edit.png` | The panel on every tab, and Home in edit mode |
| `card-<id>.png` | Every registered Home card on its own |
| `settings-<id>.png`, `settings-<id>-end.png` | Every settings section, and the bottom of a page taller than the window |
| `onboarding-<step>.png`, `onboarding-features-ondemand.png` | Every welcome tour step, and the read-only Features step opened from Settings |

`snapshot.txt` starts with `version:`, `self-contained:` and, with `--only`, `only:` lines, then lists `<view>: ok` or `FAILED: <view>: <reason>` for each view; a failed view does not stop the others. The last line is `done` only when every view passed; the exit code is then 0, otherwise 1. Other output, such as the hotkey parse checks, goes to `snapshot.log`. `node scripts/check-snapshots.mjs <dir>` checks the report, that every PNG has an outline and every outline a PNG, the file names, the required views and the outline format. Inspect changed PNGs and attach them to UI pull requests. CI disables native runtime error dialogs, checks the exit code, applies a 120-second timeout, runs the checker and uploads `snapshots` even on failure.

If an old local build directory contains self-contained runtime files, a later framework-dependent build can pick up a stale local `hostfxr.dll`. Verify with a fresh output directory before diagnosing an app regression; CI starts from a clean checkout. Do not copy self-contained runtime files into the framework-dependent output.

For other parallel test runs, also set a unique `QNOTCH_INSTANCE` value. Only stop test processes you started, by PID.

## Smoke test

`--smoke-test <dir>` writes everything `--snapshot` writes (`--only`, `--appearance` and `--data-dir` work the same), then brings the real shell on screen at the top of its monitor for about 15 seconds and runs the contract's [smoke checks](../../spec/diagnostics.md#smoke-checks). It takes no single-instance lock, uses demo data and a temporary data folder like `--snapshot`, and without `QNOTCH_INSTANCE` names its own instance (`smoke-<pid>`), so its pipes and child processes never reach your normal QNotch:

```powershell
$env:QNOTCH_INSTANCE = 'smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$p = Start-Process src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe -ArgumentList '--smoke-test', "$PWD\smoke" -PassThru
$p.WaitForExit(); $p.ExitCode
node scripts/check-snapshots.mjs smoke
```

The report is `smoke.txt`: the snapshot lines, then `check <name>: ok`, `check <name>: skip: <reason>` or `FAILED: check <name>: <reason>`, and `done` last only when every view and check passed (exit 0, otherwise 1). Details per check go to `smoke.log`, the app log is copied as `qnotch.log`. The checks drive the shell through its own methods and key handling (the hover dwell, the `toggle` and `search` shortcut actions, Escape and Return routed to QNotch's own windows, `CardLayout.Move`, the `panel-pin` toggle) and never move the pointer or send keystrokes to the desktop; they assert on what Windows reports: the window rectangle against the monitor, the foreground window, keyboard focus.

| Check | On Windows |
| --- | --- |
| `placement` | Window and pill top center of the chosen monitor (DIPs), 760 x 430 window, 38 DIP pill |
| `hover-keeps-focus` | The hover path opens the panel; the foreground window stays the other app's |
| `hotkey-toggle`, `hotkey-search` | The shortcut actions open the panel with the keyboard (Search with focus in `search-field`) and toggle closes it again, handing the foreground back. Windows lets a process take the foreground only in some cases (the real hotkey qualifies); when it refuses, the check reports a skip saying so |
| `escape-collapses` | Escape through the window's key handling closes the panel and releases the keyboard |
| `module-disabled` | A child process (`--smoke-test <dir> --smoke-probe notifications`) boots with Notifications off and lists the modules it created, every registry id and every AutomationId it built: nothing of the module may appear |
| `module-toggle` | Skip: modules apply on restart on Windows |
| `edit-mode`, `pin` | The pointer leaving does not close the panel; a card move is saved (`general.json` as the read-only store would write it) |
| `notify-cli`, `notify-transport` | The real `QNotch.exe notify --action ... --wait` answered through the module; a raw pipe request and dismiss. Only the pipe starts, never the HTTP endpoint or its token |
| `agents-hook` | The real `QNotch.exe agent` hook sends a prompt event; the board shows the session working |
| `game-mode` | Forced on: the bar shows, `TryOpenPanel`, `OpenPanelWithKeyboard`, the toggle and hover do nothing; back to Auto |
| `accessible-names` | Every interactive control line in every outline written has a name |
| `onboarding` | No tour opened by itself; one opened on demand (off screen, settings copied) steps through every step with Return and finishes; another skips with Esc |
| `debug-channel` | No debug pipe in the run; a private one opened in process answers `ping`, `state`, `select-tab`, `outline`, an unknown command and `close` as documented |

When game mode detection sees a fullscreen app in front at the start, the checks that take the foreground (`hotkey-toggle`, `hotkey-search`, `escape-collapses`, `debug-channel`) skip rather than interrupt it. CI runs the smoke test after the snapshot (240-second timeout, the checker, `smoke` uploaded even on failure).

## Measure

`--measure <dir>` writes `performance.json` ([contract keys](../../spec/diagnostics.md#measure) plus `cpu_model`, `logical_processors`, `cpu_seconds`, `cpu_percent_one_core_ticks`, `private_bytes_start`/`_end`, `gc_heap_bytes_end`, `busiest_threads`, `warmup_seconds` and `modules`) and exits 1 when a limit fails. It boots like a normal start (early modules before the first frame, the rest and Game mode at startup idle, the post-startup `MemoryTrim`) with every module on, demo data, read-only settings, no tray icon, hotkeys or network, the window off screen and the panel collapsed. It waits 15 s after startup idle, then measures 30 s:

```powershell
$p = Start-Process src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe -ArgumentList '--measure', "$PWD\perf" -PassThru
$p.WaitForExit(); Get-Content perf\performance.json
```

CPU comes from `QueryProcessCycleTime` (exact cycles) over a calibrated cycle rate; `Process.TotalProcessorTime` is kept as `cpu_percent_one_core_ticks` (sampled on the 15.6 ms clock tick, so noisy at idle). `limits` holds the [hard rules](../../ARCHITECTURE.md#performance-rules-hard) it can measure: `idle_cpu_percent_one_core` at or under 0.1 while collapsed and `resident_bytes` (working set at both ends) under 80 MiB. Demo data means modules that honor read-only settings start no providers, so the number covers the shell, the stats sampler and the clock rather than live media or clipboard work. Close other busy apps first; foreground changes and display events wake the shell. Measure is local only: a shared runner's numbers say nothing about the app.

## Debug channel

`--debug-control` starts the normal interactive app (single-instance mutex and all) plus the [debug channel](../../spec/diagnostics.md#debug-channel): the named pipe `\\.\pipe\QNotch.Debug.<QNOTCH_INSTANCE>` (`QNotch.Debug` without the variable), created for the current user only. It opens once the shell and every module are up. Without the flag there is no pipe and no thread; `--snapshot`, `--measure` and settings never open it, and `--smoke-test` opens only a private one in process for its `debug-channel` check.

Start a test instance with its own data folder and instance name. This is the one interactive instance an agent may launch directly (see [Windows agent instructions](../../src/QNotch/AGENTS.md)). A `--debug-control` run never opens the welcome tour by itself (the `onboarding` command does); otherwise it is the normal app, network and updates included. Pre-seed `general.json` so it boots straight to the pill with no Updates prompt and no update check:

```powershell
$env:QNOTCH_INSTANCE = 'test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$data = Join-Path $env:TEMP "qnotch-$env:QNOTCH_INSTANCE"
New-Item -ItemType Directory -Force $data | Out-Null
'{ "UpdateChecksChoiceMade": true, "CheckForUpdates": false }' | Set-Content (Join-Path $data general.json)
$exe = 'src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe'
$app = Start-Process $exe -ArgumentList '--debug-control', '--data-dir', "`"$data`"" -PassThru
```

Then drive it with the `debug` verb from a shell with the same `QNOTCH_INSTANCE`. It sends one request and prints the result as one line of JSON on stdout, or `{"error": "…"}` on stderr (also for exit codes 3 and 4). Capture the output in PowerShell (`| Out-String`) so it waits for the GUI executable:

```powershell
& $exe debug ping | Out-String
& $exe debug state | Out-String
& $exe debug select-tab --id search | Out-String
& $exe debug type --id search-field --text wea | Out-String
& $exe debug outline | Out-String
& $exe debug key --name Escape | Out-String
& $exe debug snapshot --path "$env:TEMP\qnotch-shot\search.png" | Out-String
& $exe debug quit | Out-String
```

Every command of the contract table is there: `ping`, `state`, `open [--tab]`, `close`, `select-tab --id`, `settings [--section] [--close]`, `onboarding [--close]`, `outline [--window panel|pill|settings|onboarding]`, `snapshot --path <absolute .png> [--window]`, `press --id`, `type --text [--id]`, `key --name Escape|Return|Tab|Space|Up|Down|Left|Right|Backspace|Delete|<char> [--modifiers ctrl,alt,shift,cmd]` (`Backspace` erases backwards, `Delete` forwards), `hotkey --action toggle|search|game-mode` and `game-mode --mode auto|on|off`. Windows has no `timer` tab (the timer is a Home card); `select-tab` lists the valid ids when it gets an unknown one.

- Arguments are `--name value`; the verb sends every value as a JSON string and the channel reads `true`, `false` and numbers from strings, so `--close true` and a bare `--close` both work.
- Exit codes: 0 ok, 1 the command failed (the error is printed), 3 no instance has the channel open, 4 bad usage.
- Each answer waits until the UI has settled: the dispatcher is idle, the panel's open or close animation has ended and, with motion on, 300 ms have passed since the last tab or mode change (700 ms while the welcome tour shows), at most 2 s. A following `outline` or `snapshot` sees the result.
- `press` uses the WPF automation peer's Invoke, Toggle or SelectionItem pattern of the first visible, enabled control with that AutomationId in the tour, the notch window, then Settings. It refuses pop-ups (combo boxes), whose menus would block; set them with `key`. `type` focuses the field (a panel field also takes the keyboard, as a click would) and inserts at the caret. `key` raises the key events on QNotch's own focused element (modifiers are held for the UI thread only with `SetKeyboardState`); nothing is sent to other apps, and the real cursor never moves.
- `state` frames are DIPs from the primary display's top left: the window's device-pixel position divided by the DPI scale of the monitor the window is on, plus the element's offset in the window. They are exact on the primary display and whenever every display uses the same scale; on a display with another scale the position is that display's pixels over its own scale (sizes stay exact).

The raw protocol is one JSON object per line each way; several requests can share a connection and each gets one answer, in order (`{"id":1,"cmd":"select-tab","args":{"id":"search"}}`). Requests over 64 KB get an error and the connection closes.

Security: the channel can read whatever QNotch shows (clipboard history, notifications) and press any control. It listens only to the same Windows user, never on the network, and only in a process started with `--debug-control`. Never start the user's own instance with it.

## Publish and launch

```powershell
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64-self-contained
```

The outputs remain `dist/QNotch.exe` and `dist/self-contained/QNotch.exe`. The profiles deliberately use separate intermediate and build directories. For full release-package verification, create the single-file ZIP and inspect both embedded runtime configurations:

```powershell
Compress-Archive -Path dist/self-contained/QNotch.exe -DestinationPath dist/QNotch-self-contained.zip -Force
dotnet run --project tests/QNotch.UpdateTests -c Release -- --verify-publish
```

After a Windows feature, leave a fresh `dist/QNotch.exe` for the user. Stop a normal running instance if it locks the executable, then restart through Explorer:

```powershell
explorer.exe dist\QNotch.exe
```

Do not directly launch an interactive instance from a packaged agent host: its private `%APPDATA%` can differ from the user's real profile. Tests should always specify their own data directory. See [Windows agent instructions](../../src/QNotch/AGENTS.md).

## Performance and modules

Follow the [Windows architecture contract](../../ARCHITECTURE.md), including [hard performance limits](../../ARCHITECTURE.md#performance-rules-hard), and measure idle CPU and memory for background changes. Include app version, Windows version, hardware, enabled modules, measurement interval, and panel state with new numbers. Distinguish a measured result from a target.

Windows extensions live in `src/QNotch/Modules/<Name>/`. Read [the module checklist](../../ARCHITECTURE.md#add-a-new-extension). Secrets belong in Windows Credential Manager; network access must be explained and switchable. Discuss new runtime dependencies before adding them.
