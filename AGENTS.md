# Agent instructions

See [ARCHITECTURE.md](ARCHITECTURE.md) for the code layout and rules.

## After every feature

Rebuild the exe so it can be tried out right away:

```
dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64
```

This writes `dist\QNotch.exe`. If QNotch is running it locks the exe: feel free to kill the process, publish, and start it again without asking.

Always start it through Explorer, never directly:

```
explorer.exe dist\QNotch.exe
```

The Claude desktop app is a packaged (MSIX) app, so a process it starts directly gets a private copy of `%APPDATA%` (`%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\QNotch`). Settings saved in that instance are invisible to the QNotch the user starts themselves, and the other way around. The same applies when you inspect `%APPDATA%\QNotch` from an agent shell: you see the private copy, not the real folder.
