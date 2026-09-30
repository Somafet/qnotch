using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell;

/// <summary>
/// Dev tool: <c>QNotch.exe --snapshot &lt;dir&gt; [light]</c> renders the pill, every tab, the game bar (if a view is set) and every
/// settings section to PNG at 2x, then exits. Runs next to a normal instance (no mutex, off-screen, nothing is saved).
/// </summary>
internal static class Snapshot
{
    static readonly Brush Desk = Frozen(Color.FromRgb(0x4A, 0x52, 0x60));

    public static async void Run(string dir, NotchWindow w, ShellController shell, Registry<TabDescriptor> tabs,
        Registry<SettingsSectionDescriptor> sections, AppState state, Action exit)
    {
        var report = new List<string>();
        try
        {
            Directory.CreateDirectory(dir);
            await Task.Delay(1800); // first stats sample and idle prebuild
            Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 84), Path.Combine(dir, "pill.png"), Desk);

            if (!state.Media.HasSession)
            {
                var m = state.Media;
                m.Title = "Midnight City"; m.Artist = "M83"; m.HasSession = true; m.IsPlaying = true;
                await Task.Delay(500);
                Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 84), Path.Combine(dir, "pill-media.png"), Desk);
                m.HasSession = false; m.IsPlaying = false; m.Title = ""; m.Artist = "";
                await Task.Delay(400);
            }

            shell.OpenPanel();
            await Task.Delay(600);
            foreach (var t in tabs.Items)
            {
                shell.SelectTab(t.Id);
                await Task.Delay(350);
                Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, NotchWindow.PanelH + 8), Path.Combine(dir, $"tab-{t.Id}.png"), Desk);
            }
            shell.SelectTab("home");
            shell.IsEditMode = true;
            await Task.Delay(400);
            Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, NotchWindow.PanelH + 8), Path.Combine(dir, "tab-home-edit.png"), Desk);
            shell.IsEditMode = false;
            shell.ClosePanel();
            await Task.Delay(400);

            // Game bar: the module's view if it set one, otherwise a dummy that exercises the shell plumbing.
            var dummy = !w.HasGameBarView;
            if (dummy)
            {
                shell.SetGameBarView(new System.Windows.Controls.TextBlock { Text = "Game bar preview  CPU 12%  RAM 9.1 GB  18:30", FontSize = 11, Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center });
                shell.SetGameBarLayout(22, 0.7, 0, 0);
                report.Add("gamebar: no module view set, rendered a dummy");
            }
            shell.SetGameBarActive(true);
            await Task.Delay(500);
            Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 60), Path.Combine(dir, "gamebar.png"), Desk);
            if (dummy)
            {
                shell.SetGameBarLayout(22, 0.7, 100000, 8); // far right, off the top edge: must clamp into the corner
                await Task.Delay(300);
                Save(w.RootElement, new Rect(0, 0, NotchWindow.WinW, 60), Path.Combine(dir, "gamebar-corner.png"), Desk);
            }
            shell.SetGameBarActive(false);
            if (dummy) shell.SetGameBarView(null);

            SettingsWindow.Snapshot(sections, (el, id) =>
                Save(el, new Rect(0, 0, el.ActualWidth, el.ActualHeight), Path.Combine(dir, $"settings-{id}.png"), (Brush)el.FindResource("WindowBrush")));

            foreach (var g in new[] { "Ctrl+Alt+N", "Ctrl+Alt+G", "Alt+1", "Alt+6" })
                report.Add($"hotkey parse {g}: {(HotkeyService.TryParse(g, out var mods, out var key) ? $"{mods}+{key}" : "FAILED")}");
            report.Add("done");
        }
        catch (Exception ex) { report.Add($"FAILED: {ex}"); Log.Error("Snapshot failed", ex); }
        finally
        {
            try { File.WriteAllLines(Path.Combine(dir, "snapshot.txt"), report); } catch { }
            exit();
        }
    }

    /// <summary>Renders <paramref name="crop"/> of <paramref name="el"/> (DIPs) over a flat background at 2x.</summary>
    static void Save(FrameworkElement el, Rect crop, string path, Brush background)
    {
        el.UpdateLayout();
        int W(double v) => (int)Math.Ceiling(v * 2);
        var full = new RenderTargetBitmap(W(el.ActualWidth), W(el.ActualHeight), 192, 192, PixelFormats.Pbgra32);
        full.Render(el);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(background, null, new Rect(0, 0, crop.Width, crop.Height));
            dc.DrawImage(full, new Rect(-crop.X, -crop.Y, el.ActualWidth, el.ActualHeight));
        }
        var outBmp = new RenderTargetBitmap(W(crop.Width), W(crop.Height), 192, 192, PixelFormats.Pbgra32);
        outBmp.Render(dv);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(outBmp));
        using var fs = File.Create(path);
        enc.Save(fs);
    }

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
}
