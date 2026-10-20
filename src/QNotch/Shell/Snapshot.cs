using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell.Diagnostics;
using QNotch.Shell.GameMode;

namespace QNotch.Shell;

/// <summary>What a snapshot renders: the live shell and its registries, built by <c>App.Boot</c>. Tour renders every welcome tour step.</summary>
internal sealed record SnapshotScene(NotchWindow Window, ShellController Shell, Registry<TabDescriptor> Tabs, Registry<SettingsSectionDescriptor> Sections,
    CardLayout Cards, Registry<DemoState> Demos, Action<Action<FrameworkElement, string>> Tour);

/// <summary>
/// Dev tool (spec/diagnostics.md): <c>QNotch.exe --snapshot &lt;dir&gt; [--only &lt;patterns&gt;] [--appearance light|dark]</c> renders the pill in each
/// state, every tab, every Home card, the game bar, every settings section and every welcome tour step to PNG at 2x, each with its outline,
/// then exits. Runs next to a normal instance (no mutex, off-screen, nothing is saved).
/// </summary>
internal static partial class Snapshot
{
    static readonly Brush Desk = Frozen(Color.FromRgb(0x4A, 0x52, 0x60));

    /// <summary><c>--snapshot</c>: writes every view and <c>snapshot.txt</c>, then exits with 0 when the report ends in <c>done</c>, else 1.</summary>
    public static async void Run(SnapshotScene scene, DiagnosticOptions options, Action<int> exit)
    {
        var dir = options.Dir!;
        var report = Begin(options);
        var ok = false;
        try { ok = await Write(scene, dir, options, report); }
        catch (Exception ex) { report.Add($"FAILED: snapshot: {Reason(ex)}"); Log.Error("Snapshot failed", ex); }
        exit(Finish(Path.Combine(dir, "snapshot.txt"), report, ok) ? 0 : 1);
    }

    /// <summary>The report's first lines: <c>version</c>, <c>self-contained</c> and, with <c>--only</c>, <c>only</c>.</summary>
    public static List<string> Begin(DiagnosticOptions options)
    {
        var asm = typeof(Snapshot).Assembly;
        var report = new List<string>
        {
            $"version: {asm.GetName().Version}",
            "self-contained: " + (asm.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "QNotchSelfContained")?.Value ?? "false"),
        };
        if (options.Only.Count > 0) report.Add("only: " + string.Join(",", options.Only));
        return report;
    }

    /// <summary>Ends the report with <c>done</c> when <paramref name="ok"/> and no line failed, and writes it. Returns whether the run passed.</summary>
    public static bool Finish(string path, List<string> report, bool ok)
    {
        ok &= !report.Any(l => l.StartsWith("FAILED", StringComparison.Ordinal));
        if (ok) report.Add("done");
        try { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, string.Join("\n", report) + "\n"); }
        catch (Exception ex) { Log.Error("Writing the report failed", ex); return false; }
        return ok;
    }

    /// <summary>
    /// Writes every view <paramref name="options"/> includes into <paramref name="dir"/> and adds <c>&lt;view&gt;: ok</c> or <c>FAILED: …</c> to
    /// <paramref name="report"/>; a failed view does not stop the others. Leaves the panel collapsed. Returns whether every view passed.
    /// </summary>
    public static async Task<bool> Write(SnapshotScene scene, string dir, DiagnosticOptions options, List<string> report)
    {
        Directory.CreateDirectory(dir);
        var (w, shell) = (scene.Window, scene.Shell);
        var ok = true;
        bool Wants(string name) => options.Includes(name);
        void Fail(string name, string reason) { ok = false; report.Add($"FAILED: {name}: {reason}"); }
        async Task View(string name, Func<string, Task> render)
        {
            if (!Wants(name)) return;
            try { await render(Path.Combine(dir, name + ".png")); report.Add($"{name}: ok"); }
            catch (Exception ex) { Fail(name, Reason(ex)); Log.Warn($"Snapshot of {name} failed", ex); }
        }
        void Shot(string name, Action<string> render)
        {
            if (!Wants(name)) return;
            try { render(Path.Combine(dir, name + ".png")); report.Add($"{name}: ok"); }
            catch (Exception ex) { Fail(name, Reason(ex)); Log.Warn($"Snapshot of {name} failed", ex); }
        }
        void Notch(string path, double height) => Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, height), path, Desk);

        Hotkeys(dir, Fail);
        await Task.Delay(1800); // first stats sample, idle prebuild, AI app scan

        // The collapsed pill: idle, then each module state on top of idle (pill-running, pill-capture, ...).
        var states = scene.Demos.Items.Select(d => d.State).Where(s => s != "idle").Distinct().ToList();
        if (states.Select(s => "pill-" + s).Concat(["pill", "pill-peek"]).Any(Wants))
        {
            var idle = Demo(scene.Demos, "idle");
            try
            {
                await Task.Delay(400);
                Shot("pill", p => Notch(p, 84));
                await View("pill-peek", async p =>
                {
                    using (shell.Peek("\uE756", "api: Needs you", "WarningBrush"))
                    {
                        await Task.Delay(400);
                        Notch(p, 84);
                    }
                    await Task.Delay(400);
                });
                foreach (var state in states)
                    await View("pill-" + state, async p =>
                    {
                        var undo = Demo(scene.Demos, state);
                        try { await Task.Delay(400); Notch(p, 84); }
                        finally { undo(); }
                    });
            }
            finally { idle(); }
        }

        // The open panel: every tab, Home in edit mode, then each Home card on its own.
        var tabs = scene.Tabs.Items.Select(t => (t.Id, Name: Name("tab-", t.Id))).ToList();
        var cards = scene.Cards.Ordered.Select(c => (c.Id, Name: Name("card-", c.Id))).ToList();
        if (tabs.Select(t => t.Name).Concat(cards.Select(c => c.Name)).Append("tab-home-edit").Any(Wants))
        {
            shell.OpenPanel();
            await Task.Delay(600);
            foreach (var (id, name) in tabs)
                await View(name, async p =>
                {
                    shell.SelectTab(id);
                    await Task.Delay(350);
                    if (shell.ActiveTab != id) throw new InvalidOperationException($"the panel did not show the {id} tab");
                    Notch(p, NotchWindow.PanelH + 8);
                });
            await View("tab-home-edit", async p =>
            {
                shell.SelectTab("home");
                shell.IsEditMode = true;
                try { await Task.Delay(400); Notch(p, NotchWindow.PanelH + 8); }
                finally { shell.IsEditMode = false; }
            });
            if (cards.Any(c => Wants(c.Name)))
            {
                shell.SelectTab("home");
                var hidden = scene.Cards.Ordered.Where(c => !scene.Cards.IsVisible(c.Id)).Select(c => c.Id).ToList();
                foreach (var id in hidden) scene.Cards.SetVisible(id, true);
                try
                {
                    await Task.Delay(400);
                    w.RootElement.UpdateLayout();
                    foreach (var (id, name) in cards)
                        Shot(name, p =>
                        {
                            var host = scene.Cards.Hosts.FirstOrDefault(h => h.CardId == id) ?? throw new InvalidOperationException("Home has no such card");
                            Render.SavePart(host, p, (Brush)host.FindResource("SurfaceBrush"));
                        });
                }
                finally { foreach (var id in hidden) scene.Cards.SetVisible(id, false); }
            }
            shell.ClosePanel();
            await Task.Delay(400);
        }

        // Game bar: the real controller builds it from the registered segments. Forced on, then the corner layout, then back to Auto.
        if (Wants("pill-game") || Wants("gamebar-corner"))
        {
            shell.GameMode.Override = GameModeOverride.ForceOn;
            try
            {
                await Task.Delay(500);
                Shot("pill-game", p =>
                {
                    if (shell.Mode != ShellMode.GameBar) throw new InvalidOperationException("forced game mode did not show the game bar");
                    Notch(p, 60);
                });
                await View("gamebar-corner", async p =>
                {
                    shell.SetGameBarLayout(22, 0.7, 100000, 8); // far right, off the top edge: must clamp into the corner
                    await Task.Delay(300);
                    Notch(p, 60);
                });
            }
            finally
            {
                shell.GameMode.Override = GameModeOverride.ForceOff;
                shell.GameMode.SettingsChanged(); // back to the configured layout
                shell.GameMode.Override = GameModeOverride.Auto;
            }
            await Task.Delay(300);
        }

        // Settings: every section, plus a shot of the bottom of a page taller than the window (settings-<id>-end).
        try
        {
            SettingsWindow.Snapshot(scene.Sections, id => Wants(Name("settings-", id)), (el, id) =>
                Shot(Name("settings-", id), p => Render.Save(el, p)));
        }
        catch (Exception ex) { Fail("settings", Reason(ex)); Log.Warn("Settings snapshot failed", ex); }

        // Welcome tour: every step with demo rows (a connected GitHub account, a chosen place), as onboarding-<step>.png.
        if (Onboarding.TourChoices.StepIds.Select(s => "onboarding-" + s).Append("onboarding-features-ondemand").Any(Wants))
        {
            try { scene.Tour((el, name) => Shot(name, p => Render.Save(el, p))); }
            catch (Exception ex) { Fail("onboarding", Reason(ex)); Log.Warn("Welcome tour snapshot failed", ex); }
        }
        return ok;
    }

    /// <summary>Shows every demo of <paramref name="state"/>; the result undoes them in reverse.</summary>
    static Action Demo(Registry<DemoState> demos, string state)
    {
        var undo = new List<Action>();
        foreach (var d in demos.Items.Where(d => d.State == state))
        {
            try { undo.Add(d.Show()); }
            catch (Exception ex) { Log.Warn($"Demo state {d.Id} failed", ex); }
        }
        return () => { for (var i = undo.Count - 1; i >= 0; i--) undo[i](); };
    }

    /// <summary>The shell's default gestures must parse; the results go to <c>snapshot.log</c>.</summary>
    static void Hotkeys(string dir, Action<string, string> fail)
    {
        var lines = new List<string>();
        foreach (var g in new[] { "Ctrl+Alt+N", "Ctrl+Alt+G", "Alt+1", "Alt+6" })
        {
            if (HotkeyService.TryParse(g, out var mods, out var key)) lines.Add($"hotkey parse {g}: {mods}+{key}");
            else fail("hotkeys", $"{g} does not parse");
        }
        File.WriteAllText(Path.Combine(dir, "snapshot.log"), string.Join("\n", lines) + "\n");
    }

    /// <summary>A view's file name from a registry id: lowercase, <c>module.</c> dropped, anything outside a-z 0-9 . _ - as a dash.</summary>
    static string Name(string prefix, string id)
    {
        id = id.ToLowerInvariant();
        if (id.StartsWith("module.", StringComparison.Ordinal)) id = id["module.".Length..];
        return prefix + Unsafe().Replace(id, "-");
    }

    [GeneratedRegex("[^a-z0-9._-]")]
    private static partial Regex Unsafe();

    static string Reason(Exception ex) => ex.Message.ReplaceLineEndings(" ");

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
}
