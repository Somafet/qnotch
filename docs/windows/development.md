# Windows development

Run all commands below from the repository root on Windows x64 with the .NET 10 SDK. The solution still contains the Windows app only; Mac and website work do not require .NET.

## Build and regression checks

```powershell
dotnet build src/QNotch/QNotch.csproj -c Release -warnaserror
dotnet run --project tests/QNotch.UpdateTests -c Release
dotnet run --project tests/QNotch.PhoneShareTests -c Release
```

The updater suite covers release selection, variant selection, checksums, executable validation, cancellation, replacement/recovery, and update settings. It consumes the shared release-tag fixtures to confirm Mac tags are ignored. The phone-sharing suite covers the existing transfer protocol.

## Snapshots

```powershell
$env:QNOTCH_DATA_DIR = Join-Path $env:TEMP ('qnotch-snapshot-' + [guid]::NewGuid().ToString('N'))
src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe --snapshot snapshots
Remove-Item Env:QNOTCH_DATA_DIR
```

The snapshot command does not open the interactive app. It renders every tab and settings page to PNG and a text outline, then exits. The last line of `snapshots/snapshot.txt` must be `done`. Inspect changed PNGs and attach them to UI pull requests. CI disables native runtime error dialogs, checks the exit code, applies a 120-second timeout, and uploads `snapshots` even on failure.

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
