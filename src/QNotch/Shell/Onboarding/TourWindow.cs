using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using System.Windows.Threading;
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
/// Motion (spec/onboarding.md, Motion): opacity and render transforms only, through <see cref="TourMotion"/>. With motion off (the user's
/// Reduce motion or Windows' animation setting) steps crossfade in 120 ms and nothing slides, scales, staggers or loops. A snapshot shows
/// every step settled. The one loop (the key caps on the open step) runs only while that step shows and the window is not minimized.
/// </summary>
internal sealed class TourWindow : Window
{
    public const double W = 760, H = 520;

    /// <summary>A built step: its root and the parts that move on their own in transitions.</summary>
    sealed record View(string Id, Grid Root, FrameworkElement Hero, FrameworkElement Title, FrameworkElement Subtitle, FrameworkElement? Body);

    readonly TourChoices _c;
    readonly GeneralSettings _gs;
    readonly SettingsStore _store;
    readonly Shortcuts _keys;
    readonly IReadOnlyList<ModuleInfo> _modules;
    readonly Action<string>? _openSettings;
    readonly SetupContext _setup;
    readonly Dictionary<string, Border?> _rows = new();
    readonly Style _ring;
    readonly bool _styled;
    readonly List<Action> _cleanup = [];
    readonly HashSet<CheckBox> _slides = [];

    readonly Grid _root, _stage;
    readonly Grid _dots;
    readonly StackPanel _dotRow;
    readonly Border _dotPill;
    readonly Button _back, _skip, _primary;
    readonly TextBlock _primaryText;
    List<string> _steps = [];
    int _index;
    View? _view;
    bool _ended, _closeNow, _entered;

    // Open step
    Border? _capsHost, _glow;
    FrameworkElement? _pointer;
    TextBlock? _tryText;
    Button? _change;
    bool _recording, _tried;
    string _note = "";
    DispatcherTimer? _capsLoop;

    // Hero moments
    Border? _wPill, _wPanel, _readyGlance;
    List<UIElement> _wCards = [];
    readonly List<Border> _tiles = [];
    readonly List<Border> _cells = [];
    readonly Dictionary<string, Border> _heroCards = new(StringComparer.OrdinalIgnoreCase);
    readonly List<Border> _rowCards = [];
    Path? _readyCheck;
    Border? _githubArt;

    /// <summary>Snapshot: no motion at all, every step settled; nothing activates.</summary>
    internal bool NoAnimation { get; init; }

    /// <summary>The user finished with Open QNotch: the caller opens the panel on Home with the keyboard (unless <see cref="Arrived"/>).</summary>
    public bool OpenPanel { get; private set; }

    /// <summary>Called when the flying tour reaches the notch (opens the panel while it lands). Null on a first run: App opens it after boot.</summary>
    public Action? Arrive { get; set; }

    /// <summary><see cref="Arrive"/> already ran.</summary>
    public bool Arrived { get; private set; }

    public string StepId => _steps[_index];
    public IReadOnlyList<string> Steps => _steps;

    /// <summary>Full motion: slides, scales, staggers, the loop.</summary>
    bool Anim => !NoAnimation && Motion.Enabled && IsLoaded && IsVisible;
    /// <summary>At least the reduced-motion crossfades.</summary>
    bool Fades => !NoAnimation && IsLoaded && IsVisible;

    public TourWindow(TourChoices choices, GeneralSettings gs, SettingsStore store, Shortcuts keys, IReadOnlyList<ModuleInfo> modules, Action<string>? openSettings)
    {
        _c = choices; _gs = gs; _store = store; _keys = keys; _modules = modules; _openSettings = openSettings;
        _setup = new SetupContext { Settings = store, Shortcuts = keys };

        Title = "Welcome to QNotch";
        // Always dark, like the notch at night: the dark palette overrides the app's for everything in this window.
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Theme/Theme.Dark.xaml") });
        // Buttons with hover fades and a press squash, only when motion is on (the shared styles otherwise).
        _styled = Motion.Enabled;
        if (_styled) Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Shell/Onboarding/TourStyles.xaml") });
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
        _stage = new Grid { ClipToBounds = true };
        _root.Children.Add(_stage);

        var close = new Button { Style = (Style)FindResource("IconButton"), Content = Glyphs.Close, ToolTip = "Close", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 10, 10, 0), FocusVisualStyle = _ring };
        close.Click += (_, _) => Close();
        _root.Children.Add(close);

        // Footer: progress dots on the left, Skip, Back and the primary button on the right.
        _dotRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6, 0, 0, 0) };
        _dotPill = new Border { Width = 18, Height = 6, CornerRadius = new CornerRadius(3), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        _dotPill.SetResourceReference(Border.BackgroundProperty, "AccentBrush");
        _dots = new Grid { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
        _dots.Children.Add(_dotRow);
        _dots.Children.Add(_dotPill);
        _skip = new Button { Style = ButtonStyle("LinkButton"), Margin = new Thickness(0, 0, 18, 0), FocusVisualStyle = _ring, Padding = new Thickness(2, 4, 2, 4) };
        _back = new Button { Content = "Back", Padding = new Thickness(16, 7, 16, 7), Margin = new Thickness(0, 0, 8, 0), FocusVisualStyle = _ring };
        if (_styled) _back.Style = (Style)FindResource("TourButton");
        _primaryText = new TextBlock();
        _primary = new Button { Style = ButtonStyle("AccentButton"), Padding = new Thickness(20, 7, 20, 7), MinWidth = 116, FocusVisualStyle = _ring, Content = _primaryText };
        AutomationProperties.SetAutomationId(_skip, "onboarding-skip");
        AutomationProperties.SetAutomationId(_back, "onboarding-back");
        AutomationProperties.SetAutomationId(_primary, "onboarding-primary");
        _skip.Click += (_, _) => End(TourEnd.Skipped);
        _back.Click += (_, _) => { QNotch.Core.Analytics.Track("onboarding", "back", "onboarding"); Go(_index - 1, false); };
        _primary.Click += (_, _) => Primary();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(_skip);
        buttons.Children.Add(_back);
        buttons.Children.Add(_primary);
        var footerGrid = new Grid();
        footerGrid.Children.Add(_dots);
        footerGrid.Children.Add(buttons);
        var footer = new Border { Padding = new Thickness(22, 14, 20, 14), BorderThickness = new Thickness(0, 1, 0, 0), Child = footerGrid };
        footer.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        Grid.SetRow(footer, 1);
        _root.Children.Add(footer);
        Content = _root;

        _root.MouseLeftButtonDown += (_, e) => { if (!_ended && IsLoaded && !Interactive(e.OriginalSource as DependencyObject)) { try { DragMove(); } catch (InvalidOperationException) { } } };
        PreviewKeyDown += OnPreviewKey;
        KeyDown += OnKey;
        // The tour reads key presses itself (Try it now, Change): global hotkeys would swallow them while it has focus.
        Activated += (_, _) => _keys.Suspended = true;
        Deactivated += (_, _) => { if (!_recording) _keys.Suspended = false; };
        // Loops never run unseen: minimizing or hiding stops them, restoring starts them again.
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) StopLoops(); else ResumeLoops(); };
        IsVisibleChanged += (_, e) => { if (!(bool)e.NewValue) StopLoops(); };
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            _keys.Suspended = false;
            StopLoops();
            foreach (var c in _cleanup) c();
            _cleanup.Clear();
        };

        _steps = ComputeSteps();
        Go(0);
        Loaded += (_, _) =>
        {
            if (NoAnimation) return;
            _primary.Focus();
            Entrance();
        };
    }

    Style ButtonStyle(string shared) => (Style)FindResource(_styled ? shared switch { "AccentButton" => "TourAccentButton", "LinkButton" => "TourLinkButton", _ => "TourButton" } : shared);

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
        StopLoops();
        _index = index;
        var id = _steps[index];
        var old = _view;
        var view = _view = Build(id);
        _stage.Children.Add(view.Root);
        Ring(view.Root);
        if (old is not null) Leave(old, fwd);

        _back.Visibility = index == 0 ? Visibility.Collapsed : Visibility.Visible;
        _skip.Content = id == "welcome" ? "Skip setup" : "Skip";
        PrimaryLabel(id switch { "welcome" => "Get started", "finish" => "Open QNotch", _ => "Continue" });
        Dots();

        // The first step enters with the window (Entrance); later ones right away.
        if (_entered) { Intro(view, fwd); Moment(view); }
        if (IsLoaded && !NoAnimation) Dispatcher.BeginInvoke(() => _primary.Focus(), DispatcherPriority.Input);
    }

    /// <summary>The outgoing step: fades and slides away (the hero half as far), then leaves the tree. Reduced motion: a 120 ms fade.</summary>
    void Leave(View old, bool fwd)
    {
        old.Root.IsHitTestVisible = false;
        void Remove() => _stage.Children.Remove(old.Root);
        if (!Fades) { Remove(); return; }
        if (Anim)
        {
            var dx = fwd ? -24 : 24;
            TourMotion.Run(TourMotion.Xf(old.Hero).Move, TranslateTransform.XProperty, 0, dx / 2, 160, 0, TourMotion.In);
            foreach (var part in new[] { old.Title, old.Subtitle, old.Body })
                if (part is not null) TourMotion.Run(TourMotion.Xf(part).Move, TranslateTransform.XProperty, 0, dx, 160, 0, TourMotion.In);
            // Opacity drops early (ease-out) so the two steps barely overlap: a fade-through, not a double exposure.
            TourMotion.Run(old.Root, OpacityProperty, 1, 0, 120, 0, TourMotion.Out, Remove);
        }
        else TourMotion.Run(old.Root, OpacityProperty, 1, 0, 120, 0, TourMotion.Out, Remove);
        old.Root.Opacity = 0; // the end state, should the fade be cut short
    }

    /// <summary>The incoming step: from the side it is coming from; the hero moves half as far (parallax), then title, subtitle and body
    /// follow 30 ms apart. Reduced motion: a 120 ms fade.</summary>
    void Intro(View v, bool fwd)
    {
        if (!Fades) return;
        if (!Anim) { TourMotion.Run(v.Root, OpacityProperty, 0, 1, 120); return; }
        var dx = fwd ? 24 : -24;
        TourMotion.Run(v.Root, OpacityProperty, 0, 1, 180, 70, TourMotion.Out);
        TourMotion.Run(TourMotion.Xf(v.Hero).Move, TranslateTransform.XProperty, dx / 2, 0, 260, 50, TourMotion.Out);
        var delay = 80.0;
        foreach (var part in new[] { v.Title, v.Subtitle, v.Body })
        {
            if (part is null) continue;
            TourMotion.Enter(part, dx, 0, 240, delay);
            delay += 30;
        }
    }

    /// <summary>The window comes in: fade, scale from 0.96 and a 12 px rise (300 ms), then the first step's own moment.</summary>
    void Entrance()
    {
        if (_entered) return;
        _entered = true;
        if (_view is not { } v || !Fades) { _root.Opacity = 1; return; }
        if (Anim)
        {
            var (scale, move) = TourMotion.Xf(_root, new Point(0.5, 0.5));
            TourMotion.Run(_root, OpacityProperty, 0, 1, 300, 0, TourMotion.Out);
            TourMotion.Run(scale, ScaleTransform.ScaleXProperty, 0.96, 1, 300, 0, TourMotion.Out);
            TourMotion.Run(scale, ScaleTransform.ScaleYProperty, 0.96, 1, 300, 0, TourMotion.Out);
            TourMotion.Run(move, TranslateTransform.YProperty, 12, 0, 300, 0, TourMotion.Out);
            var delay = 140.0;
            foreach (var part in new[] { v.Title, v.Subtitle, v.Body })
            {
                if (part is null) continue;
                TourMotion.Enter(part, 0, 8, 260, delay);
                delay += 30;
            }
            Moment(v);
        }
        else TourMotion.Run(_root, OpacityProperty, 0, 1, 120);
    }

    void Primary()
    {
        if (_recording) { StopRecording(); return; }
        QNotch.Core.Analytics.Track("onboarding", "next", "onboarding");
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
        if (end == TourEnd.Finished) { QNotch.Core.Analytics.Track("onboarding", "finish", "onboarding"); } else { QNotch.Core.Analytics.Track("onboarding", "skip", "onboarding"); }
        _ended = true;
        StopRecording();
        StopLoops();
        try
        {
            _c.Apply(_gs, end);
            _store.Save("general", _gs);
            Log.Info($"Welcome tour {(end == TourEnd.Finished ? "finished" : "skipped at " + StepId)} ({_c.Mode}); features off: {(_c.Off.Count == 0 ? "none" : string.Join(", ", _c.Off))}");
        }
        catch (Exception ex) { Log.Error("Saving the welcome tour choices failed", ex); }
        OpenPanel = end == TourEnd.Finished;
        _root.IsHitTestVisible = false;
        var motion = Anim && !Dispatcher.HasShutdownStarted;
        if (end == TourEnd.Finished && motion)
        {
            // Handoff: the tour flies into the notch and the panel opens as it lands.
            TourFlight.Fly(this, _root, _gs.MonitorIndex, () => { Arrived = Arrive is not null; Arrive?.Invoke(); }, CloseNow);
            return;
        }
        if (motion)
        {
            // Skip or close: a quick fade and a slight shrink (160 ms), then the window goes.
            var (scale, _) = TourMotion.Xf(_root, new Point(0.5, 0.5));
            TourMotion.Run(scale, ScaleTransform.ScaleXProperty, 1, 0.98, 160, 0, TourMotion.In);
            TourMotion.Run(scale, ScaleTransform.ScaleYProperty, 1, 0.98, 160, 0, TourMotion.In);
            TourMotion.Run(_root, OpacityProperty, 1, 0, 160, 0, TourMotion.In, CloseNow);
            return;
        }
        CloseNow();
    }

    void CloseNow()
    {
        if (_closeNow) return;
        _closeNow = true;
        try { Close(); } catch (InvalidOperationException) { } // already closing
    }

    /// <summary>Closing the window counts as Skip; with motion the close waits for the exit animation.</summary>
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_closeNow) return;
        if (Dispatcher.HasShutdownStarted) // app exit: no animation, and the close cannot be held back
        {
            if (!_ended) { _closeNow = true; End(TourEnd.Skipped); }
            return;
        }
        e.Cancel = true;
        if (!_ended) End(TourEnd.Skipped);
    }

    /// <summary>Snapshot: leave without applying anything.</summary>
    internal void Discard()
    {
        _ended = true;
        CloseNow();
    }

    /// <summary>The primary label crossfades when it changes (Get started, Continue, Open QNotch).</summary>
    void PrimaryLabel(string text)
    {
        if (_primaryText.Text == text) return;
        AutomationProperties.SetName(_primary, text);
        if (!Fades || _primaryText.Text.Length == 0) { _primaryText.Text = text; return; }
        var (outMs, inMs) = Anim ? (70.0, 130.0) : (50.0, 70.0); // reduced motion: a 120 ms crossfade in all
        TourMotion.Run(_primaryText, OpacityProperty, 1, 0, outMs, 0, TourMotion.In, () =>
        {
            _primaryText.Text = text;
            TourMotion.Run(_primaryText, OpacityProperty, 0, 1, inMs, 0, TourMotion.Out);
        });
        _primaryText.Opacity = 1;
    }

    /// <summary>Fixed dots (20 px apart) with one accent pill riding over the active one: it slides with a little stretch, nothing is laid out again.</summary>
    void Dots()
    {
        if (_dotRow.Children.Count != _steps.Count)
        {
            _dotRow.Children.Clear();
            for (var i = 0; i < _steps.Count; i++)
                _dotRow.Children.Add(new Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, i == _steps.Count - 1 ? 0 : 14, 0) });
        }
        for (var i = 0; i < _steps.Count; i++)
            ((Ellipse)_dotRow.Children[i]).SetResourceReference(Shape.FillProperty, i < _index ? "TextTertiaryBrush" : "StrokeStrongBrush");
        var (scale, move) = TourMotion.Xf(_dotPill, new Point(0.5, 0.5));
        var from = move.X;
        var to = _index * 20.0;
        if (Anim && Math.Abs(from - to) > 0.5)
        {
            TourMotion.Run(move, TranslateTransform.XProperty, from, to, 260, 0, TourMotion.Out);
            var stretch = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
            stretch.KeyFrames.Add(new DiscreteDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            stretch.KeyFrames.Add(new EasingDoubleKeyFrame(1.4, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(110)), TourMotion.Out));
            stretch.KeyFrames.Add(new EasingDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(260)), TourMotion.Out));
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, stretch);
        }
        else move.X = to;
        AutomationProperties.SetName(_dots, $"Step {_index + 1} of {_steps.Count}");
    }

    // ---------- step views ----------

    /// <summary>Hero (illustration) on top, then title, subtitle and the step's own content.</summary>
    View Build(string id)
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
        FrameworkElement sub = s;
        if (id == "features" && content is Button link)
        {
            // On demand: the link sits next to the subtitle (the tiles leave no room under it).
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            row.Children.Add(s);
            link.Margin = new Thickness(10, 6, 0, 0);
            link.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(link);
            sub = row;
            content = null;
        }
        text.Children.Add(sub);
        Grid.SetRow(text, 1);
        if (content is null) { Grid.SetRowSpan(text, 2); text.VerticalAlignment = VerticalAlignment.Center; text.Margin = new Thickness(40, 0, 40, 6); }
        g.Children.Add(text);
        if (content is not null)
        {
            Grid.SetRow(content, 2);
            g.Children.Add(content);
        }
        AutomationProperties.SetAutomationId(g, "onboarding-" + id);
        return new View(id, g, hero, t, sub, content);
    }

    /// <summary>The step's own hero moment, once on entering it (full motion only).</summary>
    void Moment(View v)
    {
        if (!Anim) return;
        switch (v.Id)
        {
            case "welcome": WelcomeMoment(); break;
            case "open": OpenMoment(); break;
            case "features":
                for (var i = 0; i < _tiles.Count; i++) TourMotion.Enter(_tiles[i], 0, 10, 220, 60 + Math.Min(i * 20, 300));
                break;
            case "connect": ConnectMoment(); break;
            case "finish": FinishMoment(); break;
        }
    }

    FrameworkElement WelcomeHero()
    {
        var s = new Grid();
        _wPill = TourArt.LivePill();
        s.Children.Add(_wPill);
        _wCards = [];
        _wPanel = TourArt.MiniPanel(580, 182, _wCards);
        _wPanel.Margin = new Thickness(0, 54, 0, 0);
        s.Children.Add(_wPanel);
        return s;
    }

    /// <summary>The pill drops out of the bezel, its segments light up one by one, then the panel unfolds from it and the cards follow.</summary>
    void WelcomeMoment()
    {
        if (_wPill is null || _wPanel is null) return;
        var (_, drop) = TourMotion.Xf(_wPill);
        TourMotion.Run(drop, TranslateTransform.YProperty, -46, 0, 380, 60, TourMotion.OutQuint);
        if (_wPill.Child is Panel segments)
            for (var i = 0; i < segments.Children.Count; i++)
                TourMotion.Run(segments.Children[i], OpacityProperty, 0, 1, 180, 240 + i * 50, TourMotion.Out);
        var (unfold, _) = TourMotion.Xf(_wPanel, new Point(0.5, 0));
        TourMotion.Run(unfold, ScaleTransform.ScaleYProperty, 0.72, 1, 320, 420, TourMotion.Out);
        TourMotion.Run(_wPanel, OpacityProperty, 0, 1, 220, 420, TourMotion.Out);
        for (var i = 0; i < _wCards.Count; i++) TourMotion.Enter(_wCards[i], 0, 10, 260, 520 + i * 60);
    }

    FrameworkElement OpenHero()
    {
        var s = new Grid();
        // The pointer resting on the pill, which lights its edge like a hover.
        var pill = TourArt.LivePill();
        _glow = new Border { CornerRadius = pill.CornerRadius, BorderThickness = pill.BorderThickness, IsHitTestVisible = false };
        _glow.SetResourceReference(Border.BorderBrushProperty, "AccentBrush");
        var pillHost = new Grid { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
        pillHost.Children.Add(pill);
        pillHost.Children.Add(_glow);
        s.Children.Add(pillHost);
        var pointer = TourArt.Pointer();
        pointer.HorizontalAlignment = HorizontalAlignment.Center;
        pointer.VerticalAlignment = VerticalAlignment.Top;
        pointer.Margin = new Thickness(184, 29, 0, 0);
        _pointer = pointer;
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

    /// <summary>The cursor glides to the pill and lights it, then the key caps start pressing themselves, every 3 s.</summary>
    void OpenMoment()
    {
        if (_pointer is not null)
        {
            TourMotion.Enter(_pointer, 80, 64, 560, 140, TourMotion.OutQuint);
        }
        if (_glow is not null) TourMotion.Run(_glow, OpacityProperty, 0, 1, 180, 620, TourMotion.Out);
        StartCapsLoop(950);
    }

    void StartCapsLoop(int firstMs)
    {
        StopLoops();
        if (!Anim || _tried || _recording || _ended || WindowState == WindowState.Minimized) return;
        var timer = _capsLoop = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(firstMs) };
        timer.Tick += (_, _) =>
        {
            if (!Anim || StepId != "open") { StopLoops(); return; }
            timer.Interval = TimeSpan.FromSeconds(3);
            PressCaps(together: false);
        };
        timer.Start();
    }

    void StopLoops()
    {
        _capsLoop?.Stop();
        _capsLoop = null;
    }

    void ResumeLoops()
    {
        if (!_ended && _steps.Count > 0 && StepId == "open") StartCapsLoop(600);
    }

    /// <summary>Ctrl, Alt, N pressed in turn (or all at once, when the user just did it).</summary>
    void PressCaps(bool together)
    {
        if (_capsHost?.Child is not Panel caps) return;
        for (var i = 0; i < caps.Children.Count; i++) TourMotion.Press(caps.Children[i], together ? 0 : i * 130);
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
        StopLoops();
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
        if (_steps.Count > 0 && StepId == "open") StartCapsLoop(1200);
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
            StartCapsLoop(1200);
            return;
        }
        // Try it now: the shortcut pressed while the tour has focus (global hotkeys are suspended, so the window sees it).
        if (HotkeysSection.Read(e, out var pressed) == HotkeysSection.Chord.Gesture && Same(pressed, Toggle?.Gesture ?? ""))
        {
            e.Handled = true;
            var first = !_tried;
            _tried = true;
            StopLoops();
            Caps();
            // The caps go down together, then the check springs in.
            if (Anim)
            {
                PressCaps(together: true);
                if (first && _tryText?.Tag is UIElement check) TourMotion.Pop(check, 0.6, 420, 140);
            }
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
        _tiles.Clear();
        var grid = new Grid { Margin = new Thickness(28, 40, 28, 6) };
        for (var i = 0; i < groups.Count * 2 - 1; i++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = i % 2 == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(14) });
        var columns = new List<List<Border>>();
        for (var i = 0; i < groups.Count; i++)
        {
            var tiles = new List<Border>();
            var col = Group(groups[i].Title, groups[i].Modules, tiles);
            columns.Add(tiles);
            Grid.SetColumn(col, i * 2);
            grid.Children.Add(col);
        }
        // Stagger order: row by row, left to right.
        for (var r = 0; r < columns.Max(c => c.Count); r++)
            foreach (var c in columns)
                if (r < c.Count) _tiles.Add(c[r]);
        return grid;
    }

    FrameworkElement Group(string title, List<ModuleInfo> modules, List<Border> tiles)
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
            var all = new Button { Style = ButtonStyle("LinkButton"), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(2, 0, 2, 0) };
            void Label() => all.Content = modules.Any(m => _c.IsOn(m.Id)) ? "Turn all off" : "Turn all on";
            all.Click += (_, _) =>
            {
                var on = !modules.Any(m => _c.IsOn(m.Id));
                if (!Anim) { foreach (var t in toggles) t.IsChecked = on; return; }
                // A ripple down the group, 30 ms per tile.
                var i = 0;
                var ripple = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(30) };
                ripple.Tick += (_, _) =>
                {
                    if (i >= toggles.Count || !IsVisible) { ripple.Stop(); for (; i < toggles.Count; i++) toggles[i].IsChecked = on; return; }
                    toggles[i++].IsChecked = on;
                };
                toggles[i++].IsChecked = on;
                ripple.Start();
            };
            AutomationProperties.SetHelpText(all, title);
            head.Children.Add(all);
            foreach (var m in modules) col.Children.Add(Tile(m, toggles, tiles, Label));
            Label();
        }
        else foreach (var m in modules) col.Children.Add(Tile(m, toggles, tiles, null));
        return col;
    }

    Border Tile(ModuleInfo m, List<CheckBox> toggles, List<Border> tiles, Action? changed)
    {
        var on = _c.IsOn(m.Id);
        // Two glyphs, accent and muted, crossfade when the switch changes.
        var glyphOn = TourArt.Glyph(m.Glyph.Length > 0 ? m.Glyph : Glyphs.Apps, 14, "AccentBrush");
        var glyphOff = TourArt.Glyph(m.Glyph.Length > 0 ? m.Glyph : Glyphs.Apps, 14, "TextTertiaryBrush");
        glyphOn.HorizontalAlignment = glyphOff.HorizontalAlignment = HorizontalAlignment.Center;
        glyphOn.Opacity = on ? 1 : 0;
        glyphOff.Opacity = on ? 0 : 1;
        var chip = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center, Child = new Grid { Children = { glyphOff, glyphOn } } };
        chip.SetResourceReference(Border.BackgroundProperty, "ControlBrush");

        var text = new StackPanel { Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        var name = TourArt.Text(m.Title, 12.5, weight: FontWeights.SemiBold);
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(name);
        var desc = TourArt.Text(m.Description, 10.5, "TextTertiaryBrush");
        desc.TextTrimming = TextTrimming.CharacterEllipsis;
        desc.Margin = new Thickness(0, 1, 0, 0);
        text.Children.Add(desc);

        // Chip and text dim together when the feature is off.
        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        body.Children.Add(chip);
        Grid.SetColumn(text, 1);
        body.Children.Add(text);
        body.Opacity = on ? 1 : 0.55;

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(body);

        var tile = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Padding = new Thickness(9, 5, 10, 5), Margin = new Thickness(0, 0, 0, 5), Child = g, ToolTip = m.Description, Tag = NoDrag };
        tile.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        tile.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        tiles.Add(tile);
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
                QNotch.Core.Analytics.Track("onboarding", "change_feature", target: m.Id, enabled: v); _c.SetOn(m.Id, v);
                Fade(glyphOn, v ? 1 : 0);
                Fade(glyphOff, v ? 0 : 1);
                Fade(body, v ? 1 : 0.55);
                changed?.Invoke();
                _steps = ComputeSteps();
                Dots();
            }
            toggle.Checked += (_, _) => Set(true);
            toggle.Unchecked += (_, _) => Set(false);
            toggles.Add(toggle);
            Grid.SetColumn(toggle, 1);
            g.Children.Add(toggle);
            tile.Cursor = Cursors.Hand;
            tile.MouseLeftButtonUp += (_, e) => { if (!Interactive(e.OriginalSource as DependencyObject, cards: false)) toggle.IsChecked = toggle.IsChecked != true; };
        }
        else
        {
            var state = TourArt.Text(on ? "On" : "Off", 11, on ? "SuccessBrush" : "TextTertiaryBrush", FontWeights.SemiBold);
            Grid.SetColumn(state, 1);
            g.Children.Add(state);
        }
        return tile;
    }

    /// <summary>Opacity to <paramref name="to"/> in 150 ms (at once without motion).</summary>
    void Fade(UIElement el, double to)
    {
        if (Anim) TourMotion.Run(el, OpacityProperty, el.Opacity, to, 150, 0, TourMotion.Out);
        else { el.BeginAnimation(OpacityProperty, null); el.Opacity = to; }
    }

    FrameworkElement? FeaturesContent()
    {
        if (_c.FeaturesEditable || _openSettings is null) return null;
        var link = new Button { Content = "Change in Settings", Style = ButtonStyle("LinkButton"), FontSize = 13 };
        link.Click += (_, _) => _openSettings("features");
        return link;
    }

    // ---------- connect ----------

    FrameworkElement ConnectHero()
    {
        _cells.Clear();
        _heroCards.Clear();
        var cards = new TourArt.UniformGrid3(3, 12);
        cards.Grid.Width = 520;
        cards.Grid.Margin = new Thickness(0, 20, 0, 0);
        cards.Grid.VerticalAlignment = VerticalAlignment.Top;
        _githubArt = TourArt.GithubCard(98, _cells);
        foreach (var card in new[] { _githubArt, TourArt.WeatherCard("Berlin", 98), TourArt.AgentsCard(98) })
        {
            cards.Add(card);
            if (((Grid)card.Child).Children[0] is TextBlock title) _heroCards[title.Text] = card;
        }
        return cards.Grid;
    }

    FrameworkElement ConnectContent()
    {
        var list = new StackPanel { Margin = new Thickness(56, 14, 56, 12) };
        _rowCards.Clear();
        foreach (var card in Rows())
        {
            (card.Parent as Panel)?.Children.Remove(card);
            TourMotion.Clear(card);
            list.Children.Add(card);
            _rowCards.Add(card);
        }
        var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        return scroll;
    }

    /// <summary>The hero cards come in one by one and the contribution graph fills in a diagonal wave; the rows follow.</summary>
    void ConnectMoment()
    {
        var i = 0;
        foreach (var card in _heroCards.Values) TourMotion.Enter(card, 0, 12, 280, 60 + i++ * 60);
        Wave(160);
        for (var r = 0; r < _rowCards.Count; r++) TourMotion.Enter(_rowCards[r], 0, 8, 240, 160 + r * 50);
    }

    /// <summary>The contribution graph fills cell by cell along the diagonals (about 400 ms).</summary>
    void Wave(double delay)
    {
        if (!Anim) return;
        foreach (var cell in _cells)
            TourMotion.Run(cell, OpacityProperty, 0, 1, 140, delay + (int)cell.Tag * 18, TourMotion.Out);
    }

    /// <summary>A module's setup row in a card: icon chip, title and status, its action on the right, its detail underneath.</summary>
    Border RowCard(SetupRow r)
    {
        var chip = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(9), VerticalAlignment = VerticalAlignment.Center };
        chip.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        var glyph = TourArt.Glyph(r.Glyph, 15, "AccentBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        chip.Child = glyph;
        // Success badge on the chip: springs in when the row connects something.
        var badge = new Border { Width = 15, Height = 15, CornerRadius = new CornerRadius(7.5), BorderThickness = new Thickness(1.5), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -5, -5), Visibility = Visibility.Collapsed };
        badge.SetResourceReference(Border.BackgroundProperty, "SuccessBrush");
        badge.SetResourceReference(Border.BorderBrushProperty, "CardBrush");
        var tick = TourArt.Glyph(Glyphs.Accept, 8, "SurfaceBrush");
        tick.HorizontalAlignment = HorizontalAlignment.Center;
        tick.FontWeight = FontWeights.Bold;
        badge.Child = tick;
        AutomationProperties.SetName(badge, "Connected");
        var chipHost = new Grid { VerticalAlignment = VerticalAlignment.Center, Children = { chip, badge } };

        var text = new StackPanel { Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        var title = TourArt.Text(r.Title, 13, weight: FontWeights.SemiBold);
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level2);
        text.Children.Add(title);
        r.Status.FontSize = 11.5;
        r.Status.TextWrapping = TextWrapping.Wrap;
        r.Status.Margin = new Thickness(0, 2, 0, 0);
        AutomationProperties.SetLiveSetting(r.Status, AutomationLiveSetting.Polite);
        text.Children.Add(r.Status);
        // The status fades in afresh whenever its text changes.
        var textProp = DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty, typeof(TextBlock));
        EventHandler onText = (_, _) => { if (Anim && r.Status.IsVisible) TourMotion.Run(r.Status, OpacityProperty, 0.15, 1, 200, 0, TourMotion.Out); };
        textProp.AddValueChanged(r.Status, onText);
        _cleanup.Add(() => textProp.RemoveValueChanged(r.Status, onText));
        r.Succeeded += () =>
        {
            badge.Visibility = Visibility.Visible;
            if (!Anim) return;
            TourMotion.Pop(badge, 0.4, 460);
            if (_heroCards.TryGetValue(r.Title, out var art))
            {
                if (art == _githubArt) Wave(0); // the GitHub graph fills again
                else TourMotion.Pop(art, 0.94, 420);
            }
        };

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.Children.Add(chipHost);
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

    FrameworkElement FinishHero()
    {
        var s = new Grid();
        s.Children.Add(TourArt.ReadyPill(out var check));
        _readyCheck = check;
        var glance = new Border { Height = 24, CornerRadius = new CornerRadius(12), Padding = new Thickness(10, 0, 12, 0), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 46, 0, 0) };
        glance.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        glance.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var g = TourArt.Glyph(Glyphs.Music, 11, "AccentBrush");
        g.Margin = new Thickness(0, 0, 6, 0);
        row.Children.Add(g);
        row.Children.Add(TourArt.Text("Midnight City", 11, "TextSecondaryBrush"));
        glance.Child = row;
        _readyGlance = glance;
        s.Children.Add(glance);
        return s;
    }

    /// <summary>The check draws its stroke, then the glance chip pops in under the pill.</summary>
    void FinishMoment()
    {
        if (_readyCheck is not null) TourMotion.Run(_readyCheck, Shape.StrokeDashOffsetProperty, TourArt.CheckLength, 0, 350, 220, TourMotion.Out);
        if (_readyGlance is not null) TourMotion.Pop(_readyGlance, 0.8, 420, 520);
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

    /// <summary>Every button and switch in a new step (modules build their own rows): the focus ring, the tour's moving button looks, and a
    /// sliding switch knob.</summary>
    void Ring(DependencyObject root)
    {
        if (root is ButtonBase or CheckBox && root is FrameworkElement fe) fe.FocusVisualStyle = _ring;
        if (_styled && root is Button b)
        {
            if (b.Style is null) b.Style = (Style)FindResource("TourButton");
            else if (ReferenceEquals(b.Style, TryFindResource("AccentButton"))) b.Style = (Style)FindResource("TourAccentButton");
            else if (ReferenceEquals(b.Style, TryFindResource("LinkButton"))) b.Style = (Style)FindResource("TourLinkButton");
        }
        if (root is CheckBox cb && ReferenceEquals(cb.Style, TryFindResource("ToggleSwitch")) && _slides.Add(cb))
        {
            // The template jumps the knob to the other side; a render offset from where it was makes it slide there.
            cb.Checked += (_, _) => Knob(cb, -16);
            cb.Unchecked += (_, _) => Knob(cb, 16);
        }
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()) Ring(child);
    }

    void Knob(CheckBox cb, double from)
    {
        if (!Anim || cb.Template?.FindName("Knob", cb) is not FrameworkElement knob) return;
        TourMotion.Run(TourMotion.Xf(knob).Move, TranslateTransform.XProperty, from, 0, 150, 0, TourMotion.Out);
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
