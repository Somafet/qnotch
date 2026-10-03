# Contributing to QNotch

Thanks for helping. Bug reports, fixes and new extensions are all welcome.

## Before you start

- **Bugs:** open an issue with your Windows version, what you did, and `%APPDATA%\QNotch\logs\qnotch.log` if it has anything relevant.
- **Small fixes:** send a pull request directly.
- **New extensions or larger changes:** open an issue first with a sentence on what it does and where it shows (card, tab, pill, game bar). Space in the panel and the pill is limited, so it is worth agreeing on that before you write the code.

## Build and check your change

You need the .NET 10 SDK on Windows (x64).

```powershell
dotnet build -c Release
src\QNotch\bin\Release\net10.0-windows10.0.22621.0\win-x64\QNotch.exe --snapshot snapshots
```

`--snapshot` renders every tab and settings page to PNG plus a text outline, then exits. It runs next to your normal QNotch and saves nothing. Look at the PNGs for every UI change, and attach the relevant ones to your pull request. CI runs the same build (warnings are errors) and snapshot on every pull request.

To try a change without touching your own settings, set `QNOTCH_DATA_DIR` to an empty folder, and `QNOTCH_INSTANCE` to any suffix so it runs next to your normal instance.

## Writing an extension

Read [ARCHITECTURE.md](ARCHITECTURE.md) first: "Add a new extension" is the checklist. In short:

- Everything lives in `src/QNotch/Modules/<Name>/`. The only line outside it is your entry in `Modules/ModuleList.cs`.
- If you need something from the shell (a new `IShell` member, a theme key), say so in the pull request instead of working around it.
- Honor `ctx.Settings.ReadOnly`: in a snapshot run show demo data and start no providers.
- The [performance rules](ARCHITECTURE.md#performance-rules-hard) are hard limits. Most importantly, nothing runs faster than once a second while the notch is collapsed, and nothing blocks the UI thread. Measure idle CPU and memory before and after.
- No new NuGet packages without discussing it first. Prefer P/Invoke and the Windows APIs the project already projects.
- Secrets (tokens) go in Windows Credential Manager, never in a JSON file. Anything that sends user data over the network says in its settings where the data goes, and can be turned off there.

## Style

Match the code around you: short, plain C#, comments that explain why, not what. Keep copy short and concrete. Keep pull requests focused on one change.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
