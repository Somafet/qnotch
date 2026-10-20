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
