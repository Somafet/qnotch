using System.Windows;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell.Diagnostics;
using QNotch.Shell.GameMode;

namespace QNotch.Shell;

/// <summary>
/// Dev tool: <c>QNotch.exe --snapshot &lt;dir&gt; [light]</c> renders the pill, every tab, the game bar (plus its corner layout), every
/// settings section and every welcome tour step to PNG at 2x, then exits. Runs next to a normal instance (no mutex, off-screen, nothing is saved).
/// </summary>
internal static class Snapshot
{
    static readonly Brush Desk = Frozen(Color.FromRgb(0x4A, 0x52, 0x60));

    public static async Task Run(string dir, NotchWindow w, ShellController shell, Registry<TabDescriptor> tabs,
        Registry<SettingsSectionDescriptor> sections, Action<Action<FrameworkElement, string>> tour, Action exit)
    {
        var report = new List<string>();
        try
        {
            Directory.CreateDirectory(dir);
            await Task.Delay(1800); // first stats sample and idle prebuild
            Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 84), Path.Combine(dir, "pill.png"), Desk);
            using (shell.Peek("\uE756", "api: Needs you", "WarningBrush"))
            {
                await Task.Delay(400);
                Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 84), Path.Combine(dir, "pill-peek.png"), Desk);
            }
            await Task.Delay(400);

            shell.OpenPanel();
            await Task.Delay(600);
            foreach (var t in tabs.Items)
            {
                shell.SelectTab(t.Id);
                await Task.Delay(350);
                Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, NotchWindow.PanelH + 8), Path.Combine(dir, $"tab-{t.Id}.png"), Desk);
            }
            shell.SelectTab("home");
            shell.IsEditMode = true;
            await Task.Delay(400);
            Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, NotchWindow.PanelH + 8), Path.Combine(dir, "tab-home-edit.png"), Desk);
            shell.IsEditMode = false;
            shell.ClosePanel();
            await Task.Delay(400);

            // Game bar: the real controller builds it from the registered segments. Forced on, then the corner layout, then back to Auto.
            shell.GameMode.Override = GameModeOverride.ForceOn;
            await Task.Delay(500);
            Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 60), Path.Combine(dir, "gamebar.png"), Desk);
            shell.SetGameBarLayout(22, 0.7, 100000, 8); // far right, off the top edge: must clamp into the corner
            await Task.Delay(300);
            Render.Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 60), Path.Combine(dir, "gamebar-corner.png"), Desk);
            shell.GameMode.Override = GameModeOverride.ForceOff;
            shell.GameMode.SettingsChanged(); // back to the configured layout
            shell.GameMode.Override = GameModeOverride.Auto;
            await Task.Delay(300);

            SettingsWindow.Snapshot(sections, (el, id) =>
                Render.Save(el, Path.Combine(dir, $"settings-{id}.png")));

            // Welcome tour: every step with demo rows (a connected GitHub account, a chosen place), as onboarding-<step>.png.
            tour((el, name) =>
            {
                Render.Save(el, Path.Combine(dir, name + ".png"));
                report.Add($"{name}: ok");
            });

            foreach (var g in new[] { "Ctrl+Alt+N", "Ctrl+Alt+G", "Alt+1", "Alt+6" })
                report.Add($"hotkey parse {g}: {(HotkeyService.TryParse(g, out var mods, out var key) ? $"{mods}+{key}" : "FAILED")}");
            report.Add($"version: {typeof(Snapshot).Assembly.GetName().Version}");
            report.Add("self-contained: " + System.Reflection.CustomAttributeExtensions.GetCustomAttributes<System.Reflection.AssemblyMetadataAttribute>(typeof(Snapshot).Assembly)
                .FirstOrDefault(a => a.Key == "QNotchSelfContained")?.Value);
            report.Add("done");
        }
        catch (Exception ex) { report.Add($"FAILED: {ex}"); Log.Error("Snapshot failed", ex); }
        finally
        {
            try { File.WriteAllLines(Path.Combine(dir, "snapshot.txt"), report); } catch { }
            exit();
        }
    }

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
}
