using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell.GameMode;

/// <summary>Game mode settings page: override, detection, bar look and position, segments, per-process lists.</summary>
public static class GameModeSection
{
    static T Res<T>(string key) => (T)Application.Current.FindResource(key);

    internal static FrameworkElement Create(GameModeController game, Shortcuts keys, Registry<SegmentDescriptor> segments)
    {
        var s = game.Settings;
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
        void ShowStatus()
        {
            status.Text = game.IsActive ? $"Game bar showing. {game.Reason}." : "Game bar not showing. Normal notch is active.";
            dot.SetResourceReference(TextBlock.ForegroundProperty, game.IsActive ? "AccentBrush" : "TextTertiaryBrush");
        }
        Action onState = ShowStatus;
        ShowStatus();
        page.Children.Add(bar);

        // Override: same state as the hotkey and the tray menu.
        var seg = new StackPanel { Orientation = Orientation.Horizontal };
        var radios = new Dictionary<GameModeOverride, RadioButton>();
        foreach (var (mode, label) in new[] { (GameModeOverride.Auto, "Auto"), (GameModeOverride.ForceOn, "Force on"), (GameModeOverride.ForceOff, "Force off") })
        {
            var m = mode;
            var rb = new RadioButton { Style = Res<Style>("SegmentButton"), Content = label, GroupName = "gm-override", IsChecked = game.Override == m };
            rb.Checked += (_, _) => game.Override = m;
            radios[m] = rb;
            seg.Children.Add(rb);
        }
        var segBox = new Border { CornerRadius = new CornerRadius(8), Child = seg };
        segBox.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        Action<GameModeOverride> onOverride = m => radios[m].IsChecked = true;
        page.Children.Add(UiKit.Row("Mode", $"Auto follows the detection below. Cycle with {(keys.Find("gamemode") is { Gesture.Length: > 0 } k ? k.Gesture + " or " : "")}the tray icon.", segBox));

        // Subscribe only while the page is on screen.
        page.Loaded += (_, _) => { game.StatusChanged += onState; game.OverrideChanged += onOverride; ShowStatus(); onOverride(game.Override); };
        page.Unloaded += (_, _) => { game.StatusChanged -= onState; game.OverrideChanged -= onOverride; };

        page.Children.Add(UiKit.Row("Automatic detection", "Show the bar when a fullscreen or borderless fullscreen app has the foreground, and apply the lists below.",
            UiKit.Toggle(s.AutoDetect, v => { s.AutoDetect = v; game.SettingsChanged(true); })));

        // Look
        page.Children.Add(Section("Bar"));
        page.Children.Add(UiKit.Row("Opacity", null, Slider(30, 100, 5, s.Opacity * 100, v => $"{v:0}%", v => { s.Opacity = v / 100; game.SettingsChanged(); }, out _)));
        page.Children.Add(UiKit.Row("Height", null, Slider(16, 40, 2, s.Height, v => $"{v:0} px", v => { s.Height = v; game.SettingsChanged(); }, out _)));

        // Position
        bool sync = false;
        Slider sx = null!, sy = null!;
        var xBox = Slider(-1500, 1500, 10, s.OffsetX, v => Math.Abs(v) >= 1500 ? "Edge" : $"{v:0} px", v => { if (sync) return; s.OffsetX = v; game.SettingsChanged(); }, out sx);
        var yBox = Slider(0, 400, 4, s.OffsetY, v => $"{v:0} px", v => { if (sync) return; s.OffsetY = v; game.SettingsChanged(); }, out sy);
        var presets = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, x) in new[] { ("Left", -10000.0), ("Center", 0.0), ("Right", 10000.0) })
        {
            var px = x;
            var b = new Button { Content = label, Margin = new Thickness(presets.Children.Count == 0 ? 0 : 8, 0, 0, 0) };
            b.Click += (_, _) =>
            {
                s.OffsetX = px;
                sync = true; sx.Value = Math.Clamp(px, sx.Minimum, sx.Maximum); sync = false;   // offsets beyond the slider range clamp to the screen edge
                game.SettingsChanged();
            };
            presets.Children.Add(b);
        }
        page.Children.Add(UiKit.Row("Position", "Anchor along the top edge, then fine tune. Keep the bar clear of a game's HUD.", presets));
        page.Children.Add(UiKit.Row("Horizontal offset", null, xBox));
        page.Children.Add(UiKit.Row("Vertical offset", "Above 0 the bar floats free of the top edge as a capsule.", yBox));

        // Segments
        page.Children.Add(Section("Segments"));
        page.Children.Add(Muted("Segments without data stay hidden. A frame rate slot is reserved for a later version."));
        foreach (var sd in segments.Items.Where(x => x.Slot == SegmentSlot.GameBar))
        {
            var id = sd.Id;
            page.Children.Add(UiKit.Row(sd.Title, sd.Hint, UiKit.Toggle(game.IsSegmentOn(id), v => game.SetSegment(id, v))));
        }

        // Per-process lists
        page.Children.Add(Section("Apps"));
        var always = new ListEditor("Always use game mode", "Process names that get the bar whenever they are in the foreground, even windowed.", s.AlwaysGame, game);
        var never = new ListEditor("Never use game mode", "Exempt apps, for example a borderless video player you still want to click. Wins over the list above.", s.NeverGame, game);
        always.Other = never; never.Other = always;
        page.Children.Add(always.Root);
        page.Children.Add(never.Root);
        return page;
    }

    static TextBlock Section(string text) =>
        new() { Text = text, Style = Res<Style>("Title"), Margin = new Thickness(0, 8, 0, 12) };

    static TextBlock Muted(string text) =>
        new() { Text = text, Style = Res<Style>("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -6, 0, 12) };

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
        readonly GameModeController _game;
        readonly StackPanel _rows = new();
        readonly TextBox _input = new() { Height = 30 };
        public ListEditor? Other;
        public StackPanel Root { get; } = new() { Margin = new Thickness(0, 0, 0, 20) };

        public ListEditor(string title, string hint, List<string> list, GameModeController game)
        {
            _list = list; _game = game;
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
            x.Click += (_, _) => { _list.Remove(name); _game.SettingsChanged(true); Rebuild(); };
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
            _game.SettingsChanged(true);
            Rebuild();
        }

        // Only when asked: enumerating processes is not free, so it never runs in the background.
        async void ShowRunning(Button anchor)
        {
            anchor.IsEnabled = false;
            var names = await Task.Run(() =>
            {
                var set = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var p in Process.GetProcesses())
                {
                    try { if (p.MainWindowHandle != 0 && p.Id != Environment.ProcessId) set.Add(p.ProcessName); }
                    catch { /* access denied */ }
                    finally { p.Dispose(); }
                }
                return set;
            });
            anchor.IsEnabled = true;
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
