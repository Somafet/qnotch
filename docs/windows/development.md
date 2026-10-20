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

```powershell
$env:QNOTCH_DATA_DIR = Join-Path $env:TEMP ('qnotch-snapshot-' + [guid]::NewGuid().ToString('N'))
src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe --snapshot snapshots
Remove-Item Env:QNOTCH_DATA_DIR
```

The snapshot command does not open the interactive app. It renders every tab, settings page and welcome tour step (`onboarding-<step>.png`) to PNG and a text outline, then exits. The last line of `snapshots/snapshot.txt` must be `done`. Inspect changed PNGs and attach them to UI pull requests. CI disables native runtime error dialogs, checks the exit code, applies a 120-second timeout, and uploads `snapshots` even on failure.

If an old local build directory contains self-contained runtime files, a later framework-dependent build can pick up a stale local `hostfxr.dll`. Verify with a fresh output directory before diagnosing an app regression; CI starts from a clean checkout. Do not copy self-contained runtime files into the framework-dependent output.

For other parallel test runs, also set a unique `QNOTCH_INSTANCE` value. Only stop test processes you started, by PID.

## Debug channel

`--debug-control` starts the normal interactive app (single-instance mutex and all) plus the [debug channel](../../spec/diagnostics.md#debug-channel): the named pipe `\\.\pipe\QNotch.Debug.<QNOTCH_INSTANCE>` (`QNotch.Debug` without the variable), created for the current user only. It opens once the shell and every module are up. Without the flag there is no pipe and no thread; `--snapshot`, `--smoke-test`, `--measure` and settings never open it.

Start a test instance with its own data folder and instance name. This is the one interactive instance an agent may launch directly (see [Windows agent instructions](../../src/QNotch/AGENTS.md)). Pre-seed `general.json` so it boots straight to the pill, with no welcome tour and no Updates prompt:

```powershell
$env:QNOTCH_INSTANCE = 'test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$data = Join-Path $env:TEMP "qnotch-$env:QNOTCH_INSTANCE"
New-Item -ItemType Directory -Force $data | Out-Null
'{ "OnboardingDone": true, "UpdateChecksChoiceMade": true, "CheckForUpdates": false }' | Set-Content (Join-Path $data general.json)
$exe = 'src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe'
$app = Start-Process $exe -ArgumentList '--debug-control', '--data-dir', "`"$data`"" -PassThru
```

Then drive it with the `debug` verb from a shell with the same `QNOTCH_INSTANCE`. It sends one request and prints the result (stdout) or the error (stderr) as one line of JSON. Capture the output in PowerShell (`| Out-String`) so it waits for the GUI executable:

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

Every command of the contract table is there: `ping`, `state`, `open [--tab]`, `close`, `select-tab --id`, `settings [--section] [--close]`, `onboarding [--close]`, `outline [--window panel|pill|settings|onboarding]`, `snapshot --path <absolute .png> [--window]`, `press --id`, `type --text [--id]`, `key --name [--modifiers ctrl,alt,shift,cmd]`, `hotkey --action toggle|search|game-mode` and `game-mode --mode auto|on|off`. Windows has no `timer` tab (the timer is a Home card); `select-tab` lists the valid ids when it gets an unknown one.

- Arguments are `--name value`; the verb sends every value as a JSON string and the channel reads `true`, `false` and numbers from strings, so `--close true` and a bare `--close` both work.
- Exit codes: 0 ok, 1 the command failed (the error is printed), 3 no instance has the channel open, 4 bad usage.
- Each answer waits until the UI has settled: the dispatcher is idle, the panel's open or close animation has ended and, with motion on, 300 ms have passed since the last tab or mode change (700 ms while the welcome tour shows), at most 2 s. A following `outline` or `snapshot` sees the result.
- `press` uses the WPF automation peer's Invoke, Toggle or SelectionItem pattern of the first visible, enabled control with that AutomationId in the tour, the notch window, then Settings. `type` focuses the field (a panel field also takes the keyboard, as a click would) and inserts at the caret. `key` raises the key events on QNotch's own focused element (modifiers are held for the UI thread only with `SetKeyboardState`); nothing is sent to other apps, and the real cursor never moves.
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
