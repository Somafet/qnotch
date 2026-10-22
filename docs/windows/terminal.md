# Windows Terminal

Terminal is a local opt-in feature, off for new and existing installations. Enable it in Settings, Features and restart. It adds only a tab, with the usual independent tab visibility control. It starts in the Windows user's home folder, using PowerShell 7 from its standard installation directory when available, otherwise built-in Windows PowerShell. Both start with `-NoLogo -NoProfile`; no WSL, downloaded renderer or new app runtime dependency is needed.

The first visible Terminal starts a real ConPTY session. Closing the panel or selecting another tab retains that session. Hiding its tab also retains it. **New session** stops the old session before creating another. Turning the feature off stops and reaps its owned shell/job immediately; restarting removes the module/tab. Re-enabling after that requires a restart. Quitting also reaps the job. A kill-on-close Windows job contains the suspended shell before it is allowed to run and includes descendants, even when a child detaches its console. QNotch never kills by process name or touches an unrelated process. This ownership policy is Windows-specific.

`GeneralSettings.LocalEnabledModules` stores explicit opt-ins for default-off modules. It is excluded from setup codes. The portable `DisabledModules` preference continues to control existing default-on modules; it cannot opt Terminal in or change its local enablement. No shell path, commands, environment or execution preferences are exported. The welcome tour starts Terminal off and records an explicit selection locally.

When keyboard-opened, Terminal restores input focus, including after the global panel toggle reopens a retained tab. While its input owns the keyboard, module global shortcuts are released and later restored with their saved gestures; the shell's panel/Game mode shortcuts remain available. Arrows, Home/End, Delete, Backspace, Tab, Return, Escape and Ctrl+C reach the terminal. Escape belongs to the terminal; use the panel toggle to close it. Ctrl+V or Shift+Insert pastes up to 16,000 characters. Ctrl+Shift+C copies the visible screen. Mouse wheel and Shift+PageUp/PageDown scroll up to 500 retained lines. Terminal output is exposed through an accessible read-only Value pattern; input accepts normal Windows text composition.

The renderer implements a bounded VT screen, cursor motion/save/restore, delayed wrapping, erase/insert/delete, scroll regions, alternate screen, basic/256/true-color SGR, application cursor mode, bracketed paste and device/cursor replies. It bounds the screen at 240 columns × 100 rows and scrollback at 500 lines. CSI accumulation is bounded; OSC/DCS payloads are discarded, never executed. The input queue holds at most 64 messages, each at most 16 KiB. Output is drained and parsed on a dedicated thread, with one coalesced UI invalidation only while visible. The cursor does not blink, and there is no idle polling or hidden render loop.

This initial renderer does not promise full xterm compatibility: complex grapheme shaping, every Unicode width rule, mouse reporting, text selection, hyperlinks, graphics protocols and advanced full-screen apps remain limited. Resizing preserves cells rather than reflowing historical lines. A long-running command can continue using CPU while hidden; retaining its session does not suspend the command.

Snapshots, smoke and measure load a deterministic sample screen and ignore input without creating a shell or ConPTY. Real lifecycle/I/O validation is separate:

```powershell
dotnet run --project tests/QNotch.WindowsTests -c Release -- --conpty
./tests/QNotch.WindowsTests/Test-TerminalLifecycle.ps1 -Executable ./dist/QNotch.exe
```

The first checks actual PowerShell I/O/cwd, editing, resize, Ctrl+C, natural exit, failed startup, owned detached-child cleanup and unrelated-process survival. The second uses a uniquely named debug instance and test folder to check default-off boot, local Features opt-in/restart, real UI input, hotkey focus/retention, disable/restart and quit cleanup. It never drives the user's instance. CI runs both separately from the deterministic native smoke.

Native interop follows Microsoft's [pseudoconsole lifecycle](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session) and [VT reference](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences). Output keeps draining while `ClosePseudoConsole` emits its final frame. Null standard handles with `STARTF_USESTDHANDLES` prevent inherited redirected host pipes, matching the [Windows Terminal connection](https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalConnection/ConptyConnection.cpp).
