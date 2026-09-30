using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Shell.Settings;
using QNotch.Theme;

namespace QNotch.Modules.GameMode;

/// <summary>Game mode settings page: override, detection, bar look and position, segments, per-process lists.</summary>
public static class GameModeSection
{
    static T Res<T>(string key) => (T)Application.Current.FindResource(key);

    public static FrameworkElement Create(ModuleContext ctx, GameModeModule module)
    {
        var s = ctx.Settings.Get<GameModeSettings>(module.Id);
        var shell = ctx.Shell;
        var page = UiKit.Page("Game mode");

        // Live status: what the bar is doing right now and why.
        var status = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var dot = UiKit.Glyph(Glyphs.Game, 14);
        var bar = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 16) };
        bar.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        dot.Margin = new Thickness(0, 0, 10, 0);
        sp.Children.Add(dot);
        sp.Children.Add(status);
        bar.Child = sp;
        var gs = ctx.State.GameMode;
        void ShowStatus()
        {
            status.Text = gs.IsActive ? $"Game bar showing. {gs.Reason}." : $"Game bar not showing. Normal notch is active.";
            dot.SetResourceReference(TextBlock.ForegroundProperty, gs.IsActive ? "AccentBrush" : "TextTertiaryBrush");
        }
        PropertyChangedEventHandler onState = (_, _) => ShowStatus();
        ShowStatus();
        page.Children.Add(bar);

        // Override: same state as the hotkey and the tray menu.
        var seg = new StackPanel { Orientation = Orientation.Horizontal };
        var radios = new Dictionary<GameModeOverride, RadioButton>();
        foreach (var (mode, label) in new[] { (GameModeOverride.Auto, "Auto"), (GameModeOverride.ForceOn, "Force on"), (GameModeOverride.ForceOff, "Force off") })
        {
            var m = mode;
            var rb = new RadioButton { Style = Res<Style>("SegmentButton"), Content = label, GroupName = "gm-override", IsChecked = shell.GameModeOverride == m };
            rb.Checked += (_, _) => shell.GameModeOverride = m;
            radios[m] = rb;
            seg.Children.Add(rb);
        }
        var segBox = new Border { CornerRadius = new CornerRadius(8), Child = seg };
        segBox.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        Action<GameModeOverride> onOverride = m => radios[m].IsChecked = true;
        page.Children.Add(UiKit.Row("Mode", $"Auto follows the detection below. Cycle with {shell.General.GameModeHotkey} or from the tray icon.", segBox));

        // Subscribe only while the page is on screen.
        page.Loaded += (_, _) => { gs.PropertyChanged += onState; shell.GameModeOverrideChanged += onOverride; ShowStatus(); onOverride(shell.GameModeOverride); };
        page.Unloaded += (_, _) => { gs.PropertyChanged -= onState; shell.GameModeOverrideChanged -= onOverride; };

        page.Children.Add(UiKit.Row("Automatic detection", "Show the bar when a fullscreen or borderless fullscreen app has the foreground, and apply the lists below.",
            GeneralSection.Toggle(s.AutoDetect, v => { s.AutoDetect = v; module.SettingsChanged(true); })));

        // Look
        page.Children.Add(Section("Bar"));
        page.Children.Add(UiKit.Row("Opacity", null, Slider(30, 100, 5, s.Opacity * 100, v => $"{v:0}%", v => { s.Opacity = v / 100; module.SettingsChanged(); }, out _)));
        page.Children.Add(UiKit.Row("Height", null, Slider(16, 40, 2, s.Height, v => $"{v:0} px", v => { s.Height = v; module.SettingsChanged(); }, out _)));

        // Position
        bool sync = false;
        Slider sx = null!, sy = null!;
        var xBox = Slider(-1500, 1500, 10, s.OffsetX, v => Math.Abs(v) >= 1500 ? "Edge" : $"{v:0} px", v => { if (sync) return; s.OffsetX = v; module.SettingsChanged(); }, out sx);
        var yBox = Slider(0, 400, 4, s.OffsetY, v => $"{v:0} px", v => { if (sync) return; s.OffsetY = v; module.SettingsChanged(); }, out sy);
        var presets = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, x) in new[] { ("Left", -10000.0), ("Center", 0.0), ("Right", 10000.0) })
        {
            var px = x;
            var b = new Button { Content = label, Margin = new Thickness(presets.Children.Count == 0 ? 0 : 8, 0, 0, 0) };
            b.Click += (_, _) =>
            {
                s.OffsetX = px;
                sync = true; sx.Value = Math.Clamp(px, sx.Minimum, sx.Maximum); sync = false;   // offsets beyond the slider range clamp to the screen edge
                module.SettingsChanged();
            };
            presets.Children.Add(b);
        }
        page.Children.Add(UiKit.Row("Position", "Anchor along the top edge, then fine tune. Keep the bar clear of a game's HUD.", presets));
        page.Children.Add(UiKit.Row("Horizontal offset", null, xBox));
        page.Children.Add(UiKit.Row("Vertical offset", "Above 0 the bar floats free of the top edge as a capsule.", yBox));

        // Segments
        page.Children.Add(Section("Segments"));
        page.Children.Add(Muted("GPU and battery only appear when the system reports them. A frame rate slot is reserved for a later version."));
        page.Children.Add(Seg("Now playing", "Title and artist, only while something plays.", s.ShowMedia, v => s.ShowMedia = v, module));
        page.Children.Add(Seg("CPU", null, s.ShowCpu, v => s.ShowCpu = v, module));
        page.Children.Add(Seg("GPU", null, s.ShowGpu, v => s.ShowGpu = v, module));
        page.Children.Add(Seg("Memory", null, s.ShowRam, v => s.ShowRam = v, module));
        page.Children.Add(Seg("Network", null, s.ShowNet, v => s.ShowNet = v, module));
        page.Children.Add(Seg("Battery", null, s.ShowBattery, v => s.ShowBattery = v, module));
        page.Children.Add(Seg("Clock", null, s.ShowClock, v => s.ShowClock = v, module));

        // Per-process lists
        page.Children.Add(Section("Apps"));
        var always = new ListEditor("Always use game mode", "Process names that get the bar whenever they are in the foreground, even windowed.", s.AlwaysGame, module);
        var never = new ListEditor("Never use game mode", "Exempt apps, for example a borderless video player you still want to click. Wins over the list above.", s.NeverGame, module);
        always.Other = never; never.Other = always;
        page.Children.Add(always.Root);
        page.Children.Add(never.Root);
        return page;
    }

    static TextBlock Section(string text) =>
        new() { Text = text, Style = Res<Style>("Title"), Margin = new Thickness(0, 8, 0, 12) };

    static TextBlock Muted(string text) =>
        new() { Text = text, Style = Res<Style>("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -6, 0, 12) };

    static Grid Seg(string label, string? hint, bool value, Action<bool> set, GameModeModule module) =>
        UiKit.Row(label, hint, GeneralSection.Toggle(value, v => { set(v); module.SettingsChanged(); }));

    static StackPanel Slider(double min, double max, double step, double value, Func<double, string> format, Action<double> set, out Slider slider)
    {
        var label = new TextBlock { Width = 64, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Text = format(value) };
        var s = slider = new Slider { Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max), Width = 180, SmallChange = step, LargeChange = step * 5, TickFrequency = step, IsSnapToTickEnabled = true };
        s.ValueChanged += (_, e) => { label.Text = format(e.NewValue); set(e.NewValue); };
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        p.Children.Add(s);
        p.Children.Add(label);
        return p;
    }

    /// <summary>Add/remove editor for a process name list. Names are stored as "name.exe", lower case, unique across both lists.</summary>
    sealed class ListEditor
    {
        readonly List<string> _list;
        readonly GameModeModule _module;
        readonly StackPanel _rows = new();
        readonly TextBox _input = new() { Height = 30 };
        public ListEditor? Other;
        public StackPanel Root { get; } = new() { Margin = new Thickness(0, 0, 0, 20) };

        public ListEditor(string title, string hint, List<string> list, GameModeModule module)
        {
            _list = list; _module = module;
            Root.Children.Add(new TextBlock { Text = title, FontSize = 13 });
            Root.Children.Add(new TextBlock { Text = hint, Style = Res<Style>("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 8) });

            var add = new Button { Content = "Add", Style = Res<Style>("AccentButton"), Margin = new Thickness(8, 0, 0, 0), Height = 30 };
            var pick = new Button { Content = "Running apps", Margin = new Thickness(8, 0, 0, 0), Height = 30 };
            var input = new Grid();
            input.ColumnDefinitions.Add(new ColumnDefinition());
            input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(add, 1); Grid.SetColumn(pick, 2);
            input.Children.Add(_input); input.Children.Add(add); input.Children.Add(pick);
            _input.ToolTip = "Executable name, for example game.exe";
            _input.KeyDown += (_, e) => { if (e.Key == Key.Enter) Add(_input.Text); };
            add.Click += (_, _) => Add(_input.Text);
            pick.Click += (_, _) => ShowRunning(pick);
            Root.Children.Add(input);
            _rows.Margin = new Thickness(0, 8, 0, 0);
            Root.Children.Add(_rows);
            Rebuild();
        }

        public void Rebuild()
        {
            _rows.Children.Clear();
            if (_list.Count == 0) { _rows.Children.Add(new TextBlock { Text = "No apps added.", Style = Res<Style>("Muted"), Margin = new Thickness(2, 4, 0, 0) }); return; }
            foreach (var name in _list.ToArray()) _rows.Children.Add(Row(name));
        }

        FrameworkElement Row(string name)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var x = new Button { Content = Glyphs.Close, Style = Res<Style>("IconButton"), ToolTip = "Remove", Width = 26, Height = 26 };
            Grid.SetColumn(x, 1);
            x.Click += (_, _) => { _list.Remove(name); _module.SettingsChanged(true); Rebuild(); };
            g.Children.Add(x);
            var b = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 2, 4, 2), Margin = new Thickness(0, 0, 0, 4), Child = g };
            b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
            b.MouseEnter += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlHoverBrush");
            b.MouseLeave += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
            return b;
        }

        void Add(string text)
        {
            var n = GameClassifier.Normalize(text);
            if (n.Length == 0 || n.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return;
            var name = n + ".exe";
            _input.Clear();
            if (_list.Any(e => GameClassifier.Normalize(e) == n)) return;
            if (Other is { } o && o._list.RemoveAll(e => GameClassifier.Normalize(e) == n) > 0) o.Rebuild();
            _list.Add(name);
            _module.SettingsChanged(true);
            Rebuild();
        }

        // Only when asked: enumerating processes is not free, so it never runs in the background.
        void ShowRunning(Button anchor)
        {
            var names = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in Process.GetProcesses())
            {
                try { if (p.MainWindowHandle != 0 && p.Id != Environment.ProcessId) names.Add(p.ProcessName); }
                catch { /* access denied */ }
                finally { p.Dispose(); }
            }
            var menu = new ContextMenu { PlacementTarget = anchor, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom, MaxHeight = 320 };
            foreach (var n in names.Take(60))
            {
                var item = new MenuItem { Header = n + ".exe" };
                item.Click += (_, _) => Add(n);
                menu.Items.Add(item);
            }
            if (menu.Items.Count == 0) menu.Items.Add(new MenuItem { Header = "No windowed apps found", IsEnabled = false });
            menu.IsOpen = true;
        }
    }
}
