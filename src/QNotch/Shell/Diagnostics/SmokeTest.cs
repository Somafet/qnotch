using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Shell.GameMode;
using QNotch.Shell.Onboarding;

namespace QNotch.Shell.Diagnostics;

/// <summary>
/// <c>QNotch.exe --smoke-test &lt;dir&gt;</c> (spec/diagnostics.md, Smoke checks): everything <c>--snapshot</c> writes, then the shared checks
/// against the real shell, which comes on screen at the top of its monitor for them. It drives the shell through its own methods and key
/// handling, never the real pointer or keyboard, and asserts on what Windows reports (foreground window, window rectangle). Taking the
/// foreground is left to Windows: where it refuses (the smoke process received no input), the keyboard checks say so as a skip.
/// Report <c>smoke.txt</c>, details in <c>smoke.log</c>, the app log as <c>qnotch.log</c>.
/// </summary>
internal sealed partial class SmokeTest
{
    /// <summary>A module with a tab, a card, a settings section, pill and game bar segments and a search source: the one the probe turns off.</summary>
    const string ProbeOff = "notifications";
    const int CheckTimeoutMs = 45000;
    static readonly string[] Roles = ["Button", "Toggle", "Tab", "Field", "SecureField", "Slider", "PopUp", "Item", "Link"];

    readonly DiagnosticOptions _o;
    readonly DiagnosticHost _h;
    readonly string _dir;
    readonly StringBuilder _log = new();
    nint _foreground;
    /// <summary>Game mode detection saw a fullscreen app in front: the keyboard checks leave its foreground alone.</summary>
    bool _gameInFront;

    SmokeTest(DiagnosticOptions o, DiagnosticHost h) { _o = o; _h = h; _dir = o.Dir!; }

    NotchWindow W => _h.Window;
    ShellController S => _h.Shell;

    public static async void Run(DiagnosticOptions o, DiagnosticHost h, Action<int> exit)
    {
        var t = new SmokeTest(o, h);
        var report = Snapshot.Begin(o);
        var ok = false;
        try
        {
            ok = await Snapshot.Write(h.Scene, t._dir, o, report);
            await t.Checks(report);
        }
        catch (Exception ex)
        {
            report.Add($"FAILED: smoke test: {ex.Message.ReplaceLineEndings(" ")}");
            t.Log(ex.ToString());
            Core.Log.Error("Smoke test failed", ex);
        }
        finally
        {
            try
            {
                File.WriteAllText(Path.Combine(t._dir, "smoke.log"), t._log.ToString().ReplaceLineEndings("\n"));
                var appLog = Path.Combine(Paths.LogDir, "qnotch.log");
                if (File.Exists(appLog)) File.Copy(appLog, Path.Combine(t._dir, "qnotch.log"), true);
            }
            catch (Exception ex) { Core.Log.Warn("Writing the smoke log failed", ex); }
            exit(Snapshot.Finish(Path.Combine(t._dir, "smoke.txt"), report, ok) ? 0 : 1);
        }
    }

    void Log(string line) => _log.Append(line).Append('\n');

    async Task Checks(List<string> report)
    {
        // On screen for the checks, the same way a normal start places it. Game mode is held off so a fullscreen app in front does not interfere.
        W.Offscreen = false;
        W.Reposition();
        _gameInFront = S.GameMode.IsActive;
        S.GameMode.Override = GameModeOverride.ForceOff;
        await Task.Delay(500);
        _foreground = Native.GetForegroundWindow();
        Log($"foreground at start: {Describe(_foreground)}; fullscreen app in front: {_gameInFront}");
        var probe = StartProbe();
        try
        {
            var modules = new Dictionary<string, SmokeCheck>();
            var ctx = new SmokeContext(Log);
            foreach (var (_, m) in _h.Modules)
                if (m is ISmokeChecks c)
                    foreach (var check in c.SmokeChecks(ctx)) modules[check.Name] = check;

            async Task Check(string name, Func<Task<string?>> run)
            {
                Log($"\n[{name}]");
                string? r;
                try
                {
                    var task = run();
                    r = await Task.WhenAny(task, Task.Delay(CheckTimeoutMs)) == task ? await task : $"timed out after {CheckTimeoutMs / 1000} s";
                }
                catch (Exception ex) { r = ex.Message.ReplaceLineEndings(" "); Log(ex.ToString()); }
                Log(r is null ? "ok" : r);
                report.Add(r is null ? $"check {name}: ok" : r.StartsWith("skip: ", StringComparison.Ordinal) ? $"check {name}: {r}" : $"FAILED: check {name}: {r}");
                await Reset();
            }
            Task<string?> Foreground(Func<Task<string?>> run) =>
                _gameInFront ? Task.FromResult<string?>("skip: a fullscreen app is in front (game mode detection), so the smoke test leaves its foreground alone") : run();
            Task<string?> Module(string name) => modules.Remove(name, out var c) ? c.Run() : Task.FromResult<string?>("no module provides this check");

            await Check("placement", () => Task.FromResult(Placement()));
            await Check("presentation", PresentationCheck);
            await Check("hover-keeps-focus", HoverKeepsFocus);
            await Check("hotkey-toggle", () => Foreground(HotkeyToggle));
            await Check("hotkey-search", () => Foreground(HotkeySearch));
            await Check("escape-collapses", () => Foreground(EscapeCollapses));
            await Check("module-disabled", () => ModuleDisabled(probe));
            await Check("module-toggle", () => Task.FromResult<string?>("skip: modules apply on restart on Windows (Settings, Features asks for one)"));
            await Check("edit-mode", EditMode);
            await Check("pin", Pin);
            await Check("notify-cli", () => Module("notify-cli"));
            await Check("notify-transport", () => Module("notify-transport"));
            await Check("agents-hook", () => Module("agents-hook"));
            await Check("game-mode", GameModeCheck);
            await Check("accessible-names", () => Task.FromResult(AccessibleNames()));
            await Check("onboarding", Onboarding);
            await Check("debug-channel", () => Foreground(DebugChannelCheck));
            foreach (var (name, c) in modules.ToList()) await Check(name, c.Run);
        }
        finally
        {
            // Hand the foreground back if a keyboard check left it with QNotch.
            if (Ours(Native.GetForegroundWindow()) && _foreground != 0 && Native.IsWindowVisible(_foreground)) Native.SetForegroundWindow(_foreground);
            W.Offscreen = true;
            W.Reposition();
        }
    }

    /// <summary>Between checks: collapsed, Home, no edit mode, not pinned, game mode held off.</summary>
    async Task Reset()
    {
        S.IsEditMode = false;
        _h.Settings.Pinned = false;
        S.GameMode.Override = GameModeOverride.ForceOff;
        S.ClosePanel();
        S.SelectTab("home");
        await Until(() => S.Mode == ShellMode.Collapsed, 1500);
        await Task.Delay(250); // the close animation
    }

    // ---------- checks ----------

    string? Placement()
    {
        var mon = Monitors.Get(_h.Settings.MonitorIndex);
        var s = mon.Scale;
        Native.GetWindowRect(W.Hwnd, out var r);
        double X(double px) => (px - mon.Bounds.Left) / s;
        double Y(double px) => (px - mon.Bounds.Top) / s;
        var monW = mon.Bounds.Width / s;
        var a = W.Surface.PointToScreen(new Point(0, 0));
        var b = W.Surface.PointToScreen(new Point(W.Surface.ActualWidth, W.Surface.ActualHeight));
        var (winX, winY, winW, winH) = (X(r.Left), Y(r.Top), r.Width / s, r.Height / s);
        var (surfX, surfY, surfW, surfH) = (X(a.X), Y(a.Y), (b.X - a.X) / s, (b.Y - a.Y) / s);
        var onMonitor = Native.MonitorFromWindow(W.Hwnd, 2) == mon.Handle;
        Log($"monitor {mon.Label(_h.Settings.MonitorIndex)}, scale {s:0.##}, {monW:0.#} x {mon.Bounds.Height / s:0.#} DIPs");
        Log($"window {winX:0.#},{winY:0.#} {winW:0.#} x {winH:0.#} DIPs; surface {surfX:0.#},{surfY:0.#} {surfW:0.#} x {surfH:0.#} DIPs; on that monitor: {onMonitor}");
        var problems = new List<string>();
        if (!onMonitor) problems.Add("the window is not on the chosen monitor");
        if (Math.Abs(winY) > 1) problems.Add($"the window top is {winY:0.#} DIPs from the monitor top");
        if (Math.Abs(winX + winW / 2 - monW / 2) > 1) problems.Add($"the window is {winX + winW / 2 - monW / 2:0.#} DIPs off center");
        if (Math.Abs(winW - NotchWindow.WinW) > 1 || Math.Abs(winH - NotchWindow.WinH) > 1) problems.Add($"the window is {winW:0} x {winH:0} DIPs, not {NotchWindow.WinW} x {NotchWindow.WinH}");
        if (Math.Abs(surfY) > 1) problems.Add($"the pill top is {surfY:0.#} DIPs below the monitor edge");
        if (Math.Abs(surfX + surfW / 2 - monW / 2) > 1) problems.Add($"the pill is {surfX + surfW / 2 - monW / 2:0.#} DIPs off center");
        if (Math.Abs(surfH - NotchWindow.PillH) > 1) problems.Add($"the pill is {surfH:0.#} DIPs tall, not {NotchWindow.PillH}");
        return problems.Count == 0 ? null : string.Join("; ", problems);
    }

    async Task<string?> HoverKeepsFocus()
    {
        var before = Native.GetForegroundWindow();
        S.Hover(true); // what the surface's MouseEnter reports; the dwell timer opens the panel
        var opened = await Until(() => S.Mode == ShellMode.Expanded, _h.Settings.HoverDwellMs + 1500);
        await Task.Delay(300);
        var after = Native.GetForegroundWindow();
        Log($"foreground before {Describe(before)}, after {Describe(after)}; window keyboard {W.HasKeyboard}, active {W.IsActive}");
        S.Hover(false);
        if (!opened) return "the hover dwell did not open the panel";
        if (W.HasKeyboard || W.IsActive || Ours(after)) return $"opening on hover took the keyboard (foreground {Describe(after)})";
        return null;
    }

    async Task<string?> HotkeyToggle()
    {
        if (_h.Shortcuts.Find("toggle") is not { } toggle) return "no toggle shortcut is declared";
        var before = Native.GetForegroundWindow();
        toggle.Action(); // what WM_HOTKEY runs
        await Task.Delay(400);
        var (opened, kb, fg, active) = (S.Mode == ShellMode.Expanded, W.HasKeyboard, Native.GetForegroundWindow(), W.IsActive);
        toggle.Action();
        var closed = await Until(() => S.Mode == ShellMode.Collapsed, 1500);
        await Task.Delay(300);
        var back = Native.GetForegroundWindow();
        Log($"open {opened}, asked for the keyboard {kb}, foreground {Describe(fg)}, active {active}; pressed again: closed {closed}, foreground {Describe(back)}");
        if (!opened) return "the toggle action did not open the panel";
        if (!kb) return "the panel opened without taking the keyboard";
        if (!closed) return "pressed again, the panel stayed open";
        if (fg != W.Hwnd) return $"skip: Windows kept the foreground with {Describe(fg)}: this process may not take it without input (the real hotkey may); the panel opened and closed again";
        if (!active) return "QNotch has the foreground but its window is not active";
        if (before != 0 && before != W.Hwnd && Native.IsWindowVisible(before) && back != before) return $"closing gave the foreground to {Describe(back)}, not back to {Describe(before)}";
        return null;
    }

    async Task<string?> HotkeySearch()
    {
        if (_h.Shortcuts.Find("search") is not { } search) return "no search shortcut is declared";
        search.Action();
        await Task.Delay(500);
        var box = Find(W.RootElement, "search-field") as TextBox;
        var (open, tab, fg, focused, logical) = (S.Mode == ShellMode.Expanded, S.ActiveTab, Native.GetForegroundWindow(), box?.IsKeyboardFocused == true,
            box is not null && FocusManager.GetFocusedElement(W) == box);
        Log($"open {open}, tab {tab}, search-field keyboard focus {focused}, focus within the window {logical}, foreground {Describe(fg)}");
        if (!open) return "the search action did not open the panel";
        if (tab != "search") return $"the panel opened on {tab}, not search";
        if (box is null) return "the Search tab has no search-field";
        if (fg != W.Hwnd)
            return logical ? $"skip: Windows kept the foreground with {Describe(fg)}: this process may not take it without input; Search opened with search-field focused within the window"
                : "the cursor is not in search-field";
        return focused ? null : "QNotch has the foreground but search-field does not have the keyboard";
    }

    async Task<string?> EscapeCollapses()
    {
        if (!S.OpenPanelWithKeyboard("home")) return "the panel did not open";
        await Task.Delay(400);
        // Escape goes where WPF would route it: the focused element if it is in the window, else the window. The window's own key handling closes.
        var target = Keyboard.FocusedElement is DependencyObject d && Window.GetWindow(d) == W && d is UIElement u ? u : W;
        var handled = Press(target, Key.Escape);
        var closed = await Until(() => S.Mode == ShellMode.Collapsed, 1500);
        Log($"Escape to {target.GetType().Name}: handled {handled}, closed {closed}, keyboard released {!W.HasKeyboard}");
        return closed ? (W.HasKeyboard ? "the panel closed but kept the keyboard" : null) : "Escape did not close the panel";
    }

    /// <summary>A probe child boots with one module off, writes what it registered and built, and exits. Started early, read here.</summary>
    Task<string?> StartProbe() => Task.Run<string?>(async () =>
    {
        var root = Path.Combine(Path.GetTempPath(), $"qnotch-probe-{Guid.NewGuid():N}");
        try
        {
            var psi = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in DiagnosticRun.ProbeArgs(Path.Combine(root, "out"), Path.Combine(root, "data"), ProbeOff)) psi.ArgumentList.Add(a);
            psi.Environment["QNOTCH_INSTANCE"] = (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") ?? "smoke") + "-probe";
            using var p = Process.Start(psi)!;
            if (!await Task.Run(() => p.WaitForExit(60000))) { try { p.Kill(); } catch { } return "error: the probe did not exit within 60 s"; }
            var log = Path.Combine(root, "out", "probe.log");
            return p.ExitCode == 0 && File.Exists(log) ? File.ReadAllText(log) : $"error: the probe exited {p.ExitCode} without probe.log";
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    });

    async Task<string?> ModuleDisabled(Task<string?> probe)
    {
        if (ModuleList.All.All(m => m.Id != ProbeOff)) return $"skip: there is no {ProbeOff} module to turn off";
        var text = await probe ?? "";
        if (text.StartsWith("error: ", StringComparison.Ordinal)) return text[7..];
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Log($"probe with {ProbeOff} off: {lines.Count(l => l.StartsWith("module "))} modules, {lines.Count(l => l.StartsWith("tab "))} tabs, {lines.Count(l => l.StartsWith("card "))} cards, " +
            $"{lines.Count(l => l.StartsWith("section "))} sections, {lines.Count(l => l.StartsWith("segment "))} segments, {lines.Count(l => l.StartsWith("id "))} element ids");
        bool Of(string id) => id == ProbeOff || id.StartsWith(ProbeOff + ".", StringComparison.Ordinal) || id.EndsWith("-" + ProbeOff, StringComparison.Ordinal);
        var leaks = lines.Where(l => l.Split(' ') is [var kind, var id, ..] && kind != "off" && Of(id)).ToList();
        foreach (var l in leaks) Log("still there: " + l);
        if (!lines.Any(l => l.StartsWith("module ")) || !lines.Contains("tab home")) return "the probe built no shell (see smoke.log)";
        return leaks.Count == 0 ? null : $"with {ProbeOff} off, {leaks.Count} of its parts still exist: {string.Join(", ", leaks.Take(4))}";
    }

    async Task<string?> EditMode()
    {
        if (!Motion.Enabled) return "skip: edit mode needs animations, and Windows animation effects or Reduce motion turn them off here";
        S.OpenPanel();
        S.SelectTab("home");
        await Task.Delay(400);
        S.IsEditMode = true;
        if (!S.IsEditMode) return "edit mode did not turn on";
        S.Hover(true);
        S.Hover(false); // the pointer leaves
        await Task.Delay(_h.Settings.LeaveDelayMs + 400);
        if (S.Mode != ShellMode.Expanded) return "the pointer leaving closed the panel in edit mode";
        var hosts = _h.Layout.Hosts.Select(x => x.CardId).ToList();
        if (hosts.Count < 2) return "Home has fewer than two cards to move";
        var (a, b) = (hosts[0], hosts[1]);
        string? saved = null;
        void OnSaved(string id, string json) { if (id == "general") saved = json; }
        _h.Store.Saved += OnSaved;
        _h.Layout.Move(a, b); // what dropping the dragged card on another does
        _h.Store.Saved -= OnSaved;
        var now = _h.Layout.Hosts.Select(x => x.CardId).ToList();
        var order = new List<string?>();
        if (saved is not null) { using var doc = JsonDocument.Parse(saved); order = doc.RootElement.GetProperty("CardOrder").EnumerateArray().Select(e => e.GetString()).ToList(); }
        Log($"moved {a} onto {b}: shown {string.Join(", ", now.Take(4))}; saved general.json CardOrder {string.Join(", ", order.Take(4))}");
        _h.Layout.Move(a, b); // and back
        if (now.IndexOf(a) != 1 || now.IndexOf(b) != 0) return $"Home shows {string.Join(", ", now.Take(3))} after moving {a} onto {b}";
        if (saved is null) return "the move was not saved";
        return order.IndexOf(a) > order.IndexOf(b) && order.IndexOf(b) >= 0 ? null : "the saved card order does not have the move";
    }

    async Task<string?> Pin()
    {
        S.OpenPanel();
        await Task.Delay(400);
        if (Find(W.RootElement, "panel-pin") is not ToggleButton pin) return "the panel has no panel-pin";
        Toggle(pin);
        if (!_h.Settings.Pinned) return "panel-pin did not pin the panel";
        S.Hover(true);
        S.Hover(false);
        await Task.Delay(_h.Settings.LeaveDelayMs + 400);
        var stayed = S.Mode == ShellMode.Expanded;
        Toggle(pin);
        var closed = await Until(() => S.Mode == ShellMode.Collapsed, _h.Settings.LeaveDelayMs + 1000);
        var pointer = W.IsPointerOver();
        Log($"pinned: open after the pointer left {stayed}; unpinned: closed {closed} (pointer really over the notch: {pointer})");
        if (!stayed) return "the pinned panel closed when the pointer left";
        return closed || pointer ? null : "unpinned, the panel stayed open with the pointer away";
    }

    async Task<string?> GameModeCheck()
    {
        var gm = S.GameMode;
        gm.Override = GameModeOverride.ForceOn;
        var entered = await Until(() => S.Mode == ShellMode.GameBar, 2000);
        await Task.Delay(300);
        var (tryOpen, kbOpen) = (S.TryOpenPanel("home"), S.OpenPanelWithKeyboard("home"));
        _h.Shortcuts.Find("toggle")?.Action();
        S.Hover(true);
        await Task.Delay(_h.Settings.HoverDwellMs + 300);
        S.Hover(false);
        var stayed = S.Mode == ShellMode.GameBar;
        var bar = W.IsGameBar && W.GameBarHost.Visibility == Visibility.Visible && W.GameBarHost.Content is not null && W.GameBarHost.ActualWidth > 0;
        Log($"forced on: game bar {entered}, bar shown {bar} ({W.GameBarHost.ActualWidth:0} DIPs wide), TryOpenPanel {tryOpen}, OpenPanelWithKeyboard {kbOpen}, after toggle and hover still the bar {stayed}");
        gm.Override = GameModeOverride.Auto;
        var left = await Until(() => S.Mode != ShellMode.GameBar, 2000);
        Log($"back to Auto: left the bar {left}, detection active {gm.IsActive} ({gm.Reason})");
        if (!entered) return "forced game mode did not show the game bar";
        if (tryOpen || kbOpen) return "the panel opened in game mode";
        if (!stayed) return "the toggle or hover left game mode";
        if (!bar) return "the game bar is not visible";
        return left || gm.IsActive ? null : "back to Auto the game bar stayed with nothing fullscreen";
    }

    /// <summary>Every interactive control line in every outline this run wrote has a name.</summary>
    string? AccessibleNames()
    {
        var unnamed = new List<string>();
        var files = Directory.GetFiles(_dir, "*.txt").Where(f => Path.GetFileName(f) != "smoke.txt").OrderBy(f => f).ToList();
        foreach (var f in files)
        {
            var n = 0;
            foreach (var line in File.ReadLines(f))
            {
                n++;
                if (Unnamed().Match(line) is { Success: true } m && Roles.Contains(m.Groups[1].Value)) unnamed.Add($"{Path.GetFileName(f)}:{n}: {line.Trim()}");
            }
        }
        Log($"{files.Count} outlines");
        foreach (var u in unnamed) Log(u);
        return unnamed.Count == 0 ? null : $"{unnamed.Count} unnamed controls, first {unnamed[0]} (all in smoke.log)";
    }

    [GeneratedRegex(@"^\s*\[(\w+)\](?! "")")]
    private static partial Regex Unnamed();

    async Task<string?> Onboarding()
    {
        var open = Application.Current.Windows.OfType<TourWindow>().Where(t => t.IsVisible).ToList();
        Log($"fresh data root (no general.json): {!_h.Store.Exists("general")}; tour windows open before asking: {open.Count}");
        if (open.Count > 0) return "the welcome tour opened by itself";

        // As Settings, General, Show welcome tour opens it, but off screen, never activated, settled, and on a copy of the settings.
        var gs = JsonSerializer.Deserialize<GeneralSettings>(JsonSerializer.Serialize(_h.Settings, SettingsStore.Json), SettingsStore.Json)!;
        var store = new SettingsStore { ReadOnly = true };
        TourWindow Show()
        {
            var w = new TourWindow(new TourChoices(TourMode.OnDemand, gs, ModuleList.All.Select(m => m.Id)), gs, store, _h.Shortcuts, ModuleList.All, _ => { })
            {
                NoAnimation = true, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0, ShowActivated = false, ShowInTaskbar = false,
            };
            w.Show();
            return w;
        }

        var tour = Show();
        var closed = false;
        tour.Closed += (_, _) => closed = true;
        var steps = tour.Steps.ToList();
        Log($"steps: {string.Join(", ", steps)}");
        foreach (var step in steps)
        {
            await Task.Delay(80);
            if (closed) return $"the tour closed before {step}";
            if (tour.StepId != step) { tour.Discard(); return $"Return showed {tour.StepId}, expected {step}"; }
            if (Find((DependencyObject)tour.Content, "onboarding-" + step) is null) { tour.Discard(); return $"step {step} has no onboarding-{step} root"; }
            Press(tour, Key.Enter);
        }
        await Until(() => closed, 1000);
        Log($"Return on the last step: closed {closed}, open the panel {tour.OpenPanel}");
        if (!closed) { tour.Discard(); return "Return on the last step did not finish the tour"; }
        if (!tour.OpenPanel) return "finishing the tour did not ask to open the panel";
        if (!steps.SequenceEqual(TourChoices.StepIds.Where(steps.Contains)) || steps.Count < 4) return $"unexpected steps: {string.Join(", ", steps)}";

        var skip = Show();
        var skipped = false;
        skip.Closed += (_, _) => skipped = true;
        Press(skip, Key.Enter);
        await Task.Delay(80);
        var second = skip.StepId;
        Press(skip, Key.Escape);
        await Until(() => skipped, 1000);
        Log($"Esc on {second}: closed {skipped}, open the panel {skip.OpenPanel}");
        if (!skipped) { skip.Discard(); return "Esc did not skip the tour"; }
        return skip.OpenPanel ? "Esc finished the tour instead of skipping it" : null;
    }

    /// <summary>The channel stays shut in a smoke run; opened in process on a pipe of its own, ping, state, select-tab and outline answer as documented.</summary>
    async Task<string?> DebugChannelCheck()
    {
        static bool PipeExists(string name) => File.Exists(@"\\.\pipe\" + name);
        if (PipeExists(DebugCli.PipeName)) return $"the debug channel {DebugCli.PipeName} is open in a smoke run";
        var pipe = $"QNotch.Debug.smoke-{Guid.NewGuid():N}";
        string[] requests =
        [
            """{"id":1,"cmd":"ping"}""", """{"id":2,"cmd":"state"}""", """{"id":3,"cmd":"select-tab","args":{"id":"search"}}""",
            """{"id":4,"cmd":"state"}""", """{"id":5,"cmd":"outline"}""", """{"cmd":"nope"}""", """{"id":7,"cmd":"close"}""",
        ];
        List<string> replies;
        using (_h.OpenDebug(pipe)) replies = await DebugCli.ExchangeAsync(pipe, requests);
        foreach (var r in replies) Log("<- " + (r.Length > 240 ? r[..240] + "..." : r));
        if (replies.Count != requests.Length) return $"{replies.Count} of {requests.Length} responses";
        var doc = replies.Select(r => JsonDocument.Parse(r).RootElement).ToList();
        for (var i = 0; i < doc.Count; i++)
        {
            var bad = i == 5; // the unknown command
            if (doc[i].GetProperty("ok").GetBoolean() == bad) return $"request {i + 1} answered {replies[i]}";
            if (!bad && (!doc[i].TryGetProperty("id", out var id) || id.GetInt32() != i + 1)) return $"request {i + 1}: its id was not echoed";
        }
        var ping = doc[0].GetProperty("result");
        if (ping.GetProperty("platform").GetString() != "Windows" || ping.GetProperty("pid").GetInt32() != Environment.ProcessId || ping.GetProperty("data_dir").GetString() != Paths.DataDir)
            return "ping does not describe this process";
        var before = doc[1].GetProperty("result");
        if (before.GetProperty("panel").GetString() != "collapsed" || before.GetProperty("modules").GetArrayLength() != ModuleList.All.Count) return "state before select-tab is wrong";
        var after = doc[3].GetProperty("result");
        if (after.GetProperty("panel").GetString() != "open" || after.GetProperty("tab").GetString() != "search")
            return $"after select-tab the panel is {after.GetProperty("panel")} on {after.GetProperty("tab")}";
        if (doc[4].GetProperty("result").GetProperty("text").GetString() is not { } text || !text.Contains("#tab-search selected", StringComparison.Ordinal))
            return "the outline does not show the Search tab selected";
        if (!await Until(() => S.Mode == ShellMode.Collapsed, 1500)) return "close left the panel open";
        return await Until(() => !PipeExists(pipe), 1000) ? null : "the pipe stayed open after the channel was disposed";
    }

    // ---------- helpers ----------

    /// <summary>A key press the way WPF delivers one: PreviewKeyDown, then KeyDown unless handled.</summary>
    static bool Press(UIElement target, Key key)
    {
        var e = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(target)!, Environment.TickCount, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        target.RaiseEvent(e);
        if (e.Handled) return true;
        e.RoutedEvent = Keyboard.KeyDownEvent;
        target.RaiseEvent(e);
        return e.Handled;
    }

    /// <summary>A click on a toggle, through its automation peer.</summary>
    static void Toggle(ToggleButton t) => ((IToggleProvider)new ToggleButtonAutomationPeer(t)).Toggle();

    static FrameworkElement? Find(DependencyObject root, string automationId)
    {
        var stack = new Stack<DependencyObject>([root]);
        while (stack.Count > 0)
        {
            var o = stack.Pop();
            if (o is FrameworkElement fe && System.Windows.Automation.AutomationProperties.GetAutomationId(fe) == automationId) return fe;
            for (int i = 0, n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(o); i < n; i++) stack.Push(System.Windows.Media.VisualTreeHelper.GetChild(o, i));
        }
        return null;
    }

    static async Task<bool> Until(Func<bool> done, int ms)
    {
        var sw = Stopwatch.StartNew();
        while (!done())
        {
            if (sw.ElapsedMilliseconds > ms) return false;
            await Task.Delay(30);
        }
        return true;
    }

    static bool Ours(nint hwnd) => hwnd != 0 && Native.GetWindowThreadProcessId(hwnd, out var pid) != 0 && pid == Environment.ProcessId;

    static string Describe(nint hwnd) => hwnd == 0 ? "none" : $"{Native.ClassNameOf(hwnd)}{(Ours(hwnd) ? " (QNotch)" : "")}";
}
