using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Shell.Settings;
using QNotch.Theme;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// The welcome tour (spec/onboarding.md): a standalone, centered, draggable window without a title bar. Steps: welcome, open, features,
/// connect (left out when no enabled feature has a setup row) and finish. Return activates the primary button, Esc skips, closing the
/// window counts as Skip. UI thread only.
/// </summary>
internal sealed class TourWindow : Window
{
    public const double W = 760, H = 520;

    readonly TourChoices _c;
    readonly GeneralSettings _gs;
    readonly SettingsStore _store;
    readonly Shortcuts _keys;
    readonly IReadOnlyList<ModuleInfo> _modules;
    readonly Action<string>? _openSettings;
    readonly SetupContext _setup;
    readonly Dictionary<string, Border?> _rows = new();
    readonly Style _ring;

    readonly Grid _root, _stage;
    readonly StackPanel _dots;
    readonly Button _back, _skip, _primary;
    List<string> _steps = [];
    int _index;
    bool _ended, _closing;

    // Open step
    Border? _capsHost;
    TextBlock? _tryText;
    Button? _change;
    bool _recording, _tried;
    string _note = "";

    /// <summary>Snapshot: no transitions, nothing activates.</summary>
    internal bool NoAnimation { get; init; }

    /// <summary>The user finished with Open QNotch: the caller opens the panel on Home with the keyboard.</summary>
    public bool OpenPanel { get; private set; }

    public string StepId => _steps[_index];
    public IReadOnlyList<string> Steps => _steps;

    public TourWindow(TourChoices choices, GeneralSettings gs, SettingsStore store, Shortcuts keys, IReadOnlyList<ModuleInfo> modules, Action<string>? openSettings)
    {
        _c = choices; _gs = gs; _store = store; _keys = keys; _modules = modules; _openSettings = openSettings;
        _setup = new SetupContext { Settings = store, Shortcuts = keys };

        Title = "Welcome to QNotch";
        // Always dark, like the notch at night: the dark palette overrides the app's for everything in this window.
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Theme/Theme.Dark.xaml") });
        Width = W; Height = H;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        FontFamily = (FontFamily)FindResource("UiFont");
        FontSize = 12;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
        SetResourceReference(BackgroundProperty, "WindowBrush");
        SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        try { Icon = AppIcon.Render(32); } catch { }
        // No title bar, but the system frame stays for the shadow and the rounded corners.
        System.Windows.Shell.WindowChrome.SetWindowChrome(this, new System.Windows.Shell.WindowChrome
        {
            CaptionHeight = 0, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0, 0, 0, 1), UseAeroCaptionButtons = false,
        });
        SourceInitialized += (_, _) => Frame();

        _ring = FocusRing();

        _root = new Grid { Width = W, Height = H, ClipToBounds = true };
        _root.SetResourceReference(Panel.BackgroundProperty, "WindowBrush");
        _root.RowDefinitions.Add(new RowDefinition());
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _stage = new Grid();
        _root.Children.Add(_stage);

        var close = new Button { Style = (Style)FindResource("IconButton"), Content = Glyphs.Close, ToolTip = "Close", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 10, 10, 0), FocusVisualStyle = _ring };
        close.Click += (_, _) => Close();
        _root.Children.Add(close);

        // Footer: progress dots on the left, Skip, Back and the primary button on the right.
        _dots = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        _skip = new Button { Style = (Style)FindResource("LinkButton"), Margin = new Thickness(0, 0, 18, 0), FocusVisualStyle = _ring, Padding = new Thickness(2, 4, 2, 4) };
        _back = new Button { Content = "Back", Padding = new Thickness(16, 7, 16, 7), Margin = new Thickness(0, 0, 8, 0), FocusVisualStyle = _ring };
        _primary = new Button { Style = (Style)FindResource("AccentButton"), Padding = new Thickness(20, 7, 20, 7), MinWidth = 116, FocusVisualStyle = _ring };
        _skip.Click += (_, _) => End(TourEnd.Skipped);
        _back.Click += (_, _) => Go(_index - 1);
        _primary.Click += (_, _) => Primary();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(_skip);
        buttons.Children.Add(_back);
        buttons.Children.Add(_primary);
        var footerGrid = new Grid();
        footerGrid.Children.Add(_dots);
        footerGrid.Children.Add(buttons);
        var footer = new Border { Padding = new Thickness(28, 14, 20, 14), BorderThickness = new Thickness(0, 1, 0, 0), Child = footerGrid };
        footer.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        Grid.SetRow(footer, 1);
        _root.Children.Add(footer);
        Content = _root;

        _root.MouseLeftButtonDown += (_, e) => { if (!_closing && IsLoaded && !Interactive(e.OriginalSource as DependencyObject)) { try { DragMove(); } catch (InvalidOperationException) { } } };
        PreviewKeyDown += OnPreviewKey;
        KeyDown += OnKey;
        // The tour reads key presses itself (Try it now, Change): global hotkeys would swallow them while it has focus.
        Activated += (_, _) => _keys.Suspended = true;
        Deactivated += (_, _) => { if (!_recording) _keys.Suspended = false; };
        Closing += (_, _) => { _closing = true; if (!_ended) End(TourEnd.Skipped); };
        Closed += (_, _) => _keys.Suspended = false;

        _steps = ComputeSteps();
        Go(0);
        Loaded += (_, _) => { if (!NoAnimation) _primary.Focus(); };
    }

    // ---------- steps ----------

    List<string> ComputeSteps() => TourChoices.StepIds.Where(id => id != "connect" || Rows().Count > 0).ToList();

    /// <summary>Setup rows of the enabled features, in the order of the Features step. Built once per module and kept, so a typed token or a
    /// picked place survives Back and Continue.</summary>
    List<Border> Rows()
    {
        var list = new List<Border>();
        foreach (var info in Ordered())
        {
            if (info.Setup is null || !_c.IsOn(info.Id)) continue;
            if (!_rows.TryGetValue(info.Id, out var row))
            {
                try { row = info.Setup(_setup) is { } r ? RowCard(r) : null; }
                catch (Exception ex) { Log.Error($"Setup row '{info.Id}' failed", ex); row = null; }
                _rows[info.Id] = row;
            }
            if (row is not null) list.Add(row);
        }
        return list;
    }

    /// <summary>Modules in the Features step order: the groups from ModuleList, then any module no group names.</summary>
    IEnumerable<ModuleInfo> Ordered() => Groups().SelectMany(g => g.Modules);

    List<(string Title, List<ModuleInfo> Modules)> Groups()
    {
        var byId = _modules.ToDictionary(m => m.Id, StringComparer.OrdinalIgnoreCase);
        var groups = ModuleList.TourGroups.Select(g => (g.Title, Modules: g.Ids.Where(byId.ContainsKey).Select(id => byId[id]).ToList())).ToList();
        var named = ModuleList.TourGroups.SelectMany(g => g.Ids).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var rest = _modules.Where(m => !named.Contains(m.Id)).ToList();
        if (rest.Count > 0)
        {
            if (groups.Count == 0) groups.Add(("Features", rest));
            else groups[^1].Modules.AddRange(rest);
        }
        return groups.Where(g => g.Modules.Count > 0).ToList();
    }

    internal void Go(int index, bool? forward = null)
    {
        if (index < 0 || index >= _steps.Count) return;
        var fwd = forward ?? index >= _index;
        StopRecording();
        _index = index;
        var id = _steps[index];
        var view = Build(id);
        _stage.Children.Clear();
        _stage.Children.Add(view);
        Ring(view);

        _back.Visibility = index == 0 ? Visibility.Collapsed : Visibility.Visible;
        _skip.Content = id == "welcome" ? "Skip setup" : "Skip";
        _primary.Content = id switch { "welcome" => "Get started", "finish" => "Open QNotch", _ => "Continue" };
        Dots();

        if (!NoAnimation && Motion.Enabled && IsLoaded)
        {
            var d = TimeSpan.FromMilliseconds(220);
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            var shift = new TranslateTransform();
            view.RenderTransform = shift;
            view.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
            shift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(fwd ? 28 : -28, 0, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        }
        if (IsLoaded && !NoAnimation) Dispatcher.BeginInvoke(() => _primary.Focus(), System.Windows.Threading.DispatcherPriority.Input);
    }

    void Primary()
    {
        if (_recording) { StopRecording(); return; }
        if (_index < _steps.Count - 1)
        {
            if (StepId == "features") _steps = ComputeSteps(); // the Connect step follows the feature choices
            Go(_index + 1, true);
        }
        else End(TourEnd.Finished);
    }

    void End(TourEnd end)
    {
        if (_ended) return;
        _ended = true;
        StopRecording();
        try
        {
            _c.Apply(_gs, end);
            _store.Save("general", _gs);
            Log.Info($"Welcome tour {(end == TourEnd.Finished ? "finished" : "skipped at " + StepId)} ({_c.Mode}); features off: {(_c.Off.Count == 0 ? "none" : string.Join(", ", _c.Off))}");
        }
        catch (Exception ex) { Log.Error("Saving the welcome tour choices failed", ex); }
        OpenPanel = end == TourEnd.Finished;
        if (!_closing) Close();
    }

    /// <summary>Snapshot: leave without applying anything.</summary>
    internal void Discard()
    {
        _ended = true;
        Close();
    }

    void Dots()
    {
        _dots.Children.Clear();
        for (var i = 0; i < _steps.Count; i++)
        {
            var on = i == _index;
            var dot = new Border { Width = on ? 18 : 6, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 6, 0) };
            dot.SetResourceReference(Border.BackgroundProperty, on ? "AccentBrush" : i < _index ? "TextTertiaryBrush" : "StrokeStrongBrush");
            _dots.Children.Add(dot);
        }
        AutomationProperties.SetName(_dots, $"Step {_index + 1} of {_steps.Count}");
    }

    // ---------- step views ----------

    /// <summary>Hero (illustration) on top, then title, subtitle and the step's own content.</summary>
    FrameworkElement Build(string id)
    {
        var (heroHeight, hero, title, subtitle, content) = id switch
        {
            "welcome" => (262.0, WelcomeHero(), "Welcome to QNotch", "Everything you glance at, in the notch at the top of your screen.", (FrameworkElement?)null),
            "open" => (226.0, OpenHero(), "Open it from anywhere", "Hover the notch, or press your shortcut.", OpenContent()),
            "features" => (380.0, FeaturesHero(), "Pick your features",
                _c.FeaturesEditable ? "You can change these any time in Settings, Features." : "A change applies after a restart.", FeaturesContent()),
            "connect" => (138.0, ConnectHero(), "Connect your accounts", "Optional. Everything else works without them.", ConnectContent()),
            _ => (136.0, FinishHero(), "Final touches", "A few last choices. Settings has everything else.", FinishContent()),
        };
        var g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(heroHeight) });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition());
        var backdrop = TourArt.Backdrop(heroHeight);
        backdrop.Children.Add(hero);
        g.Children.Add(backdrop);

        var text = new StackPanel { Margin = new Thickness(40, id == "features" ? 10 : 22, 40, 0), HorizontalAlignment = HorizontalAlignment.Center };
        var t = TourArt.Text(title, id == "features" ? 20 : 22, weight: FontWeights.SemiBold);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        AutomationProperties.SetHeadingLevel(t, AutomationHeadingLevel.Level1);
        text.Children.Add(t);
        var s = TourArt.Text(subtitle, 13, "TextSecondaryBrush");
        s.HorizontalAlignment = HorizontalAlignment.Center;
        s.Margin = new Thickness(0, 6, 0, 0);
        s.TextWrapping = TextWrapping.Wrap;
        s.TextAlignment = TextAlignment.Center;
        if (id == "features" && content is Button link)
        {
            // On demand: the link sits next to the subtitle (the tiles leave no room under it).
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            row.Children.Add(s);
            link.Margin = new Thickness(10, 6, 0, 0);
            link.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(link);
            text.Children.Add(row);
            content = null;
        }
        else text.Children.Add(s);
        Grid.SetRow(text, 1);
        if (content is null) { Grid.SetRowSpan(text, 2); text.VerticalAlignment = VerticalAlignment.Center; text.Margin = new Thickness(40, 0, 40, 6); }
        g.Children.Add(text);
        if (content is not null)
        {
            Grid.SetRow(content, 2);
            g.Children.Add(content);
        }
        AutomationProperties.SetAutomationId(g, "onboarding-" + id);
        return g;
    }

    static FrameworkElement WelcomeHero()
    {
        var s = new Grid();
        s.Children.Add(TourArt.LivePill());
        var panel = TourArt.MiniPanel(580, 182);
        panel.Margin = new Thickness(0, 54, 0, 0);
        s.Children.Add(panel);
        return s;
    }

    FrameworkElement OpenHero()
    {
        var s = new Grid();
        // The pointer resting on the pill, which lights its edge like a hover.
        var pill = TourArt.LivePill();
        pill.SetResourceReference(Border.BorderBrushProperty, "AccentBrush");
        s.Children.Add(pill);
        var pointer = TourArt.Pointer();
        pointer.HorizontalAlignment = HorizontalAlignment.Center;
        pointer.VerticalAlignment = VerticalAlignment.Top;
        pointer.Margin = new Thickness(184, 29, 0, 0);
        s.Children.Add(pointer);

        var keys = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 84, 0, 0) };
        var or = TourArt.Text("or press", 11.5, "TextTertiaryBrush");
        or.HorizontalAlignment = HorizontalAlignment.Center;
        or.Margin = new Thickness(0, 0, 0, 12);
        keys.Children.Add(or);
        _capsHost = new Border { HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 48 };
        keys.Children.Add(_capsHost);
        s.Children.Add(keys);
        Caps();
        return s;
    }

    Shortcut? Toggle => _keys.Find("toggle");

    void Caps()
    {
        if (_capsHost is null) return;
        _capsHost.Child = _recording ? Recording() : TourArt.KeyCaps(Toggle?.Gesture ?? "", 18, _tried);
        if (_tryText is not null)
        {
            var g = Toggle?.Gesture ?? "";
            var (text, brush) = _note.Length > 0 ? (_note, "DangerBrush")
                : _recording ? ("Press the new shortcut. Esc cancels, Backspace turns it off.", "TextSecondaryBrush")
                : _tried ? ("That's it", "SuccessBrush")
                : g.Length == 0 ? ("The shortcut is off. Hovering the notch still works.", "TextSecondaryBrush")
                : ($"Try it now: press {g}.", "TextSecondaryBrush");
            _tryText.Text = text;
            _tryText.SetResourceReference(TextBlock.ForegroundProperty, brush);
            ((FrameworkElement)_tryText.Tag).Visibility = _tried && !_recording && _note.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        if (_change is not null) _change.Content = _recording ? "Cancel" : "Change";
    }

    static FrameworkElement Recording()
    {
        var b = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1.5), Padding = new Thickness(22, 0, 22, 0), Height = 48 };
        b.SetResourceReference(Border.BorderBrushProperty, "AccentBrush");
        b.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        b.Child = TourArt.Text("Press the new shortcut", 15, "TextPrimaryBrush", FontWeights.SemiBold);
        return b;
    }

    FrameworkElement OpenContent()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 22, 0, 0) };
        var check = TourArt.Glyph(Glyphs.Accept, 13, "SuccessBrush");
        check.Margin = new Thickness(0, 0, 7, 0);
        _tryText = TourArt.Text("", 12.5);
        _tryText.Tag = check;
        AutomationProperties.SetLiveSetting(_tryText, AutomationLiveSetting.Polite);
        row.Children.Add(check);
        row.Children.Add(_tryText);
        _change = new Button { Content = "Change", Margin = new Thickness(16, 0, 0, 0), Padding = new Thickness(14, 5, 14, 5) };
        AutomationProperties.SetName(_change, "Change the shortcut");
        _change.Click += (_, _) => { if (_recording) StopRecording(); else StartRecording(); };
        row.Children.Add(_change);
        Caps();
        return row;
    }

    void StartRecording()
    {
        if (Toggle is null) return;
        _recording = true;
        _note = "";
        _keys.Suspended = true;
        Caps();
    }

    void StopRecording()
    {
        if (!_recording) return;
        _recording = false;
        Caps();
    }

    void OnPreviewKey(object sender, KeyEventArgs e)
    {
        if (StepId != "open" || _ended) return;
        if (_recording)
        {
            e.Handled = true;
            var chord = HotkeysSection.Read(e, out var gesture);
            switch (chord)
            {
                case HotkeysSection.Chord.Incomplete: return;
                case HotkeysSection.Chord.Cancel: StopRecording(); return;
                case HotkeysSection.Chord.NeedsModifier: _note = "Add Ctrl or Alt."; Caps(); _note = ""; return;
                case HotkeysSection.Chord.Unsupported: _note = "That key is not supported."; Caps(); _note = ""; return;
            }
            var s = Toggle!;
            var other = _keys.Set(s, chord == HotkeysSection.Chord.Clear ? "" : gesture);
            _recording = false;
            _tried = false;
            _note = other is not null ? $"Used by {other.Title}." : TakenNote(s);
            Caps();
            _note = "";
            return;
        }
        // Try it now: the shortcut pressed while the tour has focus (global hotkeys are suspended, so the window sees it).
        if (HotkeysSection.Read(e, out var pressed) == HotkeysSection.Chord.Gesture && Same(pressed, Toggle?.Gesture ?? ""))
        {
            e.Handled = true;
            _tried = true;
            Caps();
        }
    }

    /// <summary>Registers the new gesture for a moment to learn whether another app owns it, then suspends again while the tour has focus.</summary>
    string TakenNote(Shortcut s)
    {
        if (_store.ReadOnly || s.Gesture.Length == 0) return "";
        _keys.Suspended = false;
        var taken = s.Taken;
        _keys.Suspended = IsActive;
        return taken ? "Taken by another app. Pick another one." : "";
    }

    static bool Same(string a, string b) =>
        a.Length > 0 && b.Length > 0 && HotkeyService.TryParse(a, out var ma, out var ka) && HotkeyService.TryParse(b, out var mb, out var kb) && ma == mb && ka == kb;

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Handled || _ended) return;
        if (e.Key == Key.Escape) { e.Handled = true; End(TourEnd.Skipped); }
        else if (e.Key == Key.Enter) { e.Handled = true; Primary(); }
    }

    // ---------- features ----------

    FrameworkElement FeaturesHero()
    {
        var groups = Groups();
        var grid = new Grid { Margin = new Thickness(28, 40, 28, 6) };
        for (var i = 0; i < groups.Count * 2 - 1; i++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = i % 2 == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(14) });
        for (var i = 0; i < groups.Count; i++)
        {
            var col = Group(groups[i].Title, groups[i].Modules);
            Grid.SetColumn(col, i * 2);
            grid.Children.Add(col);
        }
        return grid;
    }

    FrameworkElement Group(string title, List<ModuleInfo> modules)
    {
        var col = new StackPanel();
        var head = new Grid { Margin = new Thickness(2, 0, 2, 8) };
        var label = TourArt.Text(title.ToUpperInvariant(), 10.5, "TextSecondaryBrush", FontWeights.SemiBold);
        AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level2);
        head.Children.Add(label);
        col.Children.Add(head);
        var toggles = new List<CheckBox>();
        if (_c.FeaturesEditable)
        {
            var all = new Button { Style = (Style)FindResource("LinkButton"), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(2, 0, 2, 0) };
            void Label() => all.Content = modules.Any(m => _c.IsOn(m.Id)) ? "Turn all off" : "Turn all on";
            all.Click += (_, _) =>
            {
                var on = !modules.Any(m => _c.IsOn(m.Id));
                foreach (var t in toggles) t.IsChecked = on;
            };
            AutomationProperties.SetHelpText(all, title);
            head.Children.Add(all);
            foreach (var m in modules) col.Children.Add(Tile(m, toggles, Label));
            Label();
        }
        else foreach (var m in modules) col.Children.Add(Tile(m, toggles, null));
        return col;
    }

    Border Tile(ModuleInfo m, List<CheckBox> toggles, Action? changed)
    {
        var on = _c.IsOn(m.Id);
        var chip = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
        chip.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        var glyph = TourArt.Glyph(m.Glyph.Length > 0 ? m.Glyph : Glyphs.Apps, 14, on ? "AccentBrush" : "TextTertiaryBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        chip.Child = glyph;

        var text = new StackPanel { Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        var name = TourArt.Text(m.Title, 12.5, weight: FontWeights.SemiBold);
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(name);
        var desc = TourArt.Text(m.Description, 10.5, "TextTertiaryBrush");
        desc.TextTrimming = TextTrimming.CharacterEllipsis;
        desc.Margin = new Thickness(0, 1, 0, 0);
        text.Children.Add(desc);

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(chip);
        Grid.SetColumn(text, 1);
        g.Children.Add(text);

        var tile = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Padding = new Thickness(9, 5, 10, 5), Margin = new Thickness(0, 0, 0, 5), Child = g, ToolTip = m.Description, Tag = NoDrag };
        tile.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        tile.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        if (_c.FeaturesEditable)
        {
            var toggle = UiKit.Toggle();
            toggle.IsChecked = on;
            toggle.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(toggle, m.Title);
            AutomationProperties.SetHelpText(toggle, m.Description);
            AutomationProperties.SetAutomationId(toggle, "feature-" + m.Id);
            void Set(bool v)
            {
                _c.SetOn(m.Id, v);
                glyph.SetResourceReference(TextBlock.ForegroundProperty, v ? "AccentBrush" : "TextTertiaryBrush");
                name.Opacity = v ? 1 : 0.6;
                changed?.Invoke();
                _steps = ComputeSteps();
                Dots();
            }
            toggle.Checked += (_, _) => Set(true);
            toggle.Unchecked += (_, _) => Set(false);
            toggles.Add(toggle);
            Grid.SetColumn(toggle, 2);
            g.Children.Add(toggle);
            tile.Cursor = Cursors.Hand;
            tile.MouseLeftButtonUp += (_, e) => { if (!Interactive(e.OriginalSource as DependencyObject, cards: false)) toggle.IsChecked = toggle.IsChecked != true; };
        }
        else
        {
            var state = TourArt.Text(on ? "On" : "Off", 11, on ? "SuccessBrush" : "TextTertiaryBrush", FontWeights.SemiBold);
            Grid.SetColumn(state, 2);
            g.Children.Add(state);
            name.Opacity = on ? 1 : 0.6;
        }
        return tile;
    }

    FrameworkElement? FeaturesContent()
    {
        if (_c.FeaturesEditable || _openSettings is null) return null;
        var link = new Button { Content = "Change in Settings", Style = (Style)FindResource("LinkButton"), FontSize = 13 };
        link.Click += (_, _) => _openSettings("features");
        return link;
    }

    // ---------- connect ----------

    static FrameworkElement ConnectHero()
    {
        var cards = new TourArt.UniformGrid3(3, 12);
        cards.Grid.Width = 520;
        cards.Grid.Margin = new Thickness(0, 20, 0, 0);
        cards.Grid.VerticalAlignment = VerticalAlignment.Top;
        cards.Add(TourArt.GithubCard(98));
        cards.Add(TourArt.WeatherCard("Berlin", 98));
        cards.Add(TourArt.AgentsCard(98));
        return cards.Grid;
    }

    FrameworkElement ConnectContent()
    {
        var list = new StackPanel { Margin = new Thickness(56, 14, 56, 12) };
        foreach (var card in Rows())
        {
            (card.Parent as Panel)?.Children.Remove(card);
            list.Children.Add(card);
        }
        var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        return scroll;
    }

    /// <summary>A module's setup row in a card: icon chip, title and status, its action on the right, its detail underneath.</summary>
    static Border RowCard(SetupRow r)
    {
        var chip = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(9), VerticalAlignment = VerticalAlignment.Center };
        chip.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        var glyph = TourArt.Glyph(r.Glyph, 15, "AccentBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        chip.Child = glyph;

        var text = new StackPanel { Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        var title = TourArt.Text(r.Title, 13, weight: FontWeights.SemiBold);
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
        text.Children.Add(title);
        r.Status.FontSize = 11.5;
        r.Status.TextWrapping = TextWrapping.Wrap;
        r.Status.Margin = new Thickness(0, 2, 0, 0);
        AutomationProperties.SetLiveSetting(r.Status, AutomationLiveSetting.Polite);
        text.Children.Add(r.Status);

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.Children.Add(chip);
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        r.Action.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(r.Action, 2);
        g.Children.Add(r.Action);
        if (r.Detail is { } d)
        {
            Grid.SetRow(d, 1);
            Grid.SetColumn(d, 1);
            Grid.SetColumnSpan(d, 2);
            d.Margin = new Thickness(12, d.Margin.Top, 0, 0);
            g.Children.Add(d);
        }
        var card = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 8), Child = g, Tag = NoDrag };
        card.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        AutomationProperties.SetName(card, r.Title);
        return card;
    }

    // ---------- finish ----------

    static FrameworkElement FinishHero()
    {
        var s = new Grid();
        s.Children.Add(TourArt.PeekPill(Glyphs.Accept, "QNotch is ready", "SuccessBrush"));
        var glance = new Border { Height = 24, CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 0, 12, 0), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 46, 0, 0) };
        glance.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        glance.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var g = TourArt.Glyph(Glyphs.Music, 11, "AccentBrush");
        g.Margin = new Thickness(0, 0, 6, 0);
        row.Children.Add(g);
        row.Children.Add(TourArt.Text("Midnight City", 11, "TextSecondaryBrush"));
        glance.Child = row;
        s.Children.Add(glance);
        return s;
    }

    FrameworkElement FinishContent()
    {
        var grid = new Grid { Margin = new Thickness(40, 18, 40, 12), VerticalAlignment = VerticalAlignment.Top };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        var prefs = new StackPanel();
        prefs.Children.Add(Pref("Check for updates automatically", "Looks for a new release on GitHub every six hours.", _c.Updates, _c.SetUpdates, "finish-updates"));
        var sep = new Border { Height = 1, Margin = new Thickness(0, 10, 0, 10) };
        sep.SetResourceReference(Border.BackgroundProperty, "StrokeBrush");
        prefs.Children.Add(sep);
        prefs.Children.Add(Pref("Start with Windows", "Opens QNotch when you sign in.", _c.StartWithWindows, _c.SetStartWithWindows, "finish-autostart"));
        var left = Card(prefs);
        grid.Children.Add(left);

        var tips = new StackPanel();
        var head = TourArt.Text("Tips", 12, "TextSecondaryBrush", FontWeights.SemiBold);
        head.Margin = new Thickness(0, 0, 0, 6);
        AutomationProperties.SetHeadingLevel(head, AutomationHeadingLevel.Level2);
        tips.Children.Add(head);
        foreach (var tip in Tips())
        {
            var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var dot = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(1, 6, 9, 0), VerticalAlignment = VerticalAlignment.Top };
            dot.SetResourceReference(Shape.FillProperty, "AccentBrush");
            row.Children.Add(dot);
            var t = TourArt.Text(tip, 12, "TextPrimaryBrush");
            t.TextWrapping = TextWrapping.Wrap;
            Grid.SetColumn(t, 1);
            row.Children.Add(t);
            tips.Children.Add(row);
        }
        var right = Card(tips);
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        return grid;

        static Border Card(UIElement child)
        {
            var b = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(14, 12, 14, 12), Child = child };
            b.SetResourceReference(Border.BackgroundProperty, "CardBrush");
            b.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
            return b;
        }
    }

    static FrameworkElement Pref(string title, string hint, bool value, Action<bool> set, string id)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Margin = new Thickness(0, 0, 12, 0) };
        text.Children.Add(TourArt.Text(title, 12.5, weight: FontWeights.SemiBold));
        var h = TourArt.Text(hint, 11, "TextTertiaryBrush");
        h.TextWrapping = TextWrapping.Wrap;
        h.Margin = new Thickness(0, 2, 0, 0);
        text.Children.Add(h);
        g.Children.Add(text);
        var toggle = UiKit.Toggle(value, set);
        toggle.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(toggle, title);
        AutomationProperties.SetAutomationId(toggle, id);
        Grid.SetColumn(toggle, 1);
        g.Children.Add(toggle);
        return g;
    }

    /// <summary>Real gestures only: the tray (the shell's), then each enabled feature's own tip.</summary>
    List<string> Tips()
    {
        var list = new List<string> { "Right-click the tray icon for Settings and Game mode." };
        foreach (var m in _modules)
        {
            if (m.Tip is null || !_c.IsOn(m.Id)) continue;
            try { if (m.Tip(_setup) is { Length: > 0 } t) list.Add(t); }
            catch (Exception ex) { Log.Warn($"Tip of '{m.Id}' failed", ex); }
        }
        return list;
    }

    // ---------- chrome ----------

    /// <summary>Rounded corners and a border in the theme's stroke color (Windows 11), dark frame in dark mode.</summary>
    void Frame()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0) return;
        int dark = 1;
        Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4); // DWMWA_USE_IMMERSIVE_DARK_MODE
        int round = 2;
        Native.DwmSetWindowAttribute(hwnd, 33, ref round, 4); // DWMWA_WINDOW_CORNER_PREFERENCE: round
        if (TryFindResource("WindowBrush") is SolidColorBrush b)
        {
            int bgr = b.Color.R | (b.Color.G << 8) | (b.Color.B << 16);
            Native.DwmSetWindowAttribute(hwnd, 35, ref bgr, 4); // caption color, in case the frame ever shows
        }
        int border = 0x00332E2E; // BGR: a quiet edge
        Native.DwmSetWindowAttribute(hwnd, 34, ref border, 4);
    }

    /// <summary>Keyboard focus ring for the tour's controls (the shared styles hide focus visuals for mouse users).</summary>
    static Style FocusRing()
    {
        var rect = new FrameworkElementFactory(typeof(Rectangle));
        rect.SetValue(Shape.StrokeThicknessProperty, 2.0);
        rect.SetValue(Rectangle.RadiusXProperty, 9.0);
        rect.SetValue(Rectangle.RadiusYProperty, 9.0);
        rect.SetValue(FrameworkElement.MarginProperty, new Thickness(-3));
        rect.SetResourceReference(Shape.StrokeProperty, "AccentBrush");
        var style = new Style();
        style.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate { VisualTree = rect }));
        return style;
    }

    /// <summary>Gives every button and switch in a new step the focus ring (modules build their own rows).</summary>
    void Ring(DependencyObject root)
    {
        if (root is ButtonBase or CheckBox && root is FrameworkElement fe) fe.FocusVisualStyle = _ring;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()) Ring(child);
    }

    sealed class NoDragTag;
    static readonly NoDragTag NoDrag = new();

    /// <summary>True when the press started on a control or a card, so it is not a window drag (or, for a tile, not a tile click).</summary>
    static bool Interactive(DependencyObject? d, bool cards = true)
    {
        for (; d is not null; d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is ButtonBase or TextBoxBase or PasswordBox or ListBoxItem or ScrollBar or Selector || (cards && d is FrameworkElement { Tag: NoDragTag })) return true;
        return false;
    }
}
