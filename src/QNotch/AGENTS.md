# Windows agent instructions

Read [ARCHITECTURE.md](../../ARCHITECTURE.md) and [the Windows development guide](../../docs/windows/development.md). Commands below run from the repository root. These rules also apply to the Windows test projects and packaging changes.

## After every Windows feature

Rebuild the executable so it can be tried immediately:

```powershell
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64
```

This writes `dist\QNotch.exe`. If a normal QNotch instance locks it, you may stop that process, publish, and restart it without asking. For parallel test instances, use unique `QNOTCH_INSTANCE` and `QNOTCH_DATA_DIR` values and only stop processes you started, by PID.

Always start the interactive app through Explorer, never directly:

```powershell
explorer.exe dist\QNotch.exe
```

One exception: a test instance for the debug channel (`--debug-control`) may be launched directly when it has its own `--data-dir` and a unique `QNOTCH_INSTANCE`, because its data never mixes with the user's. Such a run never opens the welcome tour by itself; pre-seed that folder with `general.json` (`"UpdateChecksChoiceMade": true, "CheckForUpdates": false`) so no Updates prompt or update check follows, end it with `QNotch.exe debug quit` (or stop it by PID), and never drive the user's own instance. See [Debug channel](../../docs/windows/development.md#debug-channel).

Packaged agent hosts can give directly launched children a private `%APPDATA%` under `%LOCALAPPDATA%\Packages\...\LocalCache\Roaming\QNotch`. Settings saved there are invisible to the app the user launches, and the reverse also applies. Reading `%APPDATA%\QNotch` from an agent shell may likewise inspect the private copy. Use an explicit test data directory when inspecting or verifying settings.

Snapshot and CLI tests are noninteractive exceptions: run `--snapshot` with isolated data, inspect the generated PNGs for UI changes, and check `snapshot.txt` ends in `done`.

Keep both publish profiles' intermediate/output paths separate. Do not rename `QNotch.exe` or `QNotch-self-contained.zip`, change the ZIP's single root `QNotch.exe`, or broaden updater URL, checksum, architecture, or version validation.
