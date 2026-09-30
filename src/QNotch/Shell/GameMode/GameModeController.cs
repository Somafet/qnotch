using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;

namespace QNotch.Shell.GameMode;

/// <summary>
/// Game mode: turns the notch into a passive one-line status bar while a fullscreen app owns the foreground. A shell feature, not a module.
/// Fully event driven: foreground changes, WM_DISPLAYCHANGE, size changes of the foreground window (own scoped hook), the override and
/// settings edits. Nothing runs while nothing changes; the only timers are one-shot 250 ms debounces.
/// The bar content comes from the registered <see cref="SegmentSlot.GameBar"/> segments (modules own their data visibility, the user
/// toggle lives here). The constructor is cheap: <see cref="Start"/> reads gamemode.json and installs the hooks after the first frame.
/// </summary>
internal sealed class GameModeController
{
    const string FileId = "gamemode";

    readonly ShellController _shell;
    readonly SettingsStore _store;
    readonly ForegroundWatcher _foreground;
    readonly Registry<SegmentDescriptor> _segments;
    readonly SegmentHost _host = new();
    readonly Dictionary<string, Border> _wraps = new();
    readonly SizeWatcher _size = new();
    GameModeSettings _s = new();
    StackPanel? _bar;
    DispatcherTimer? _entry, _sizeDebounce;
    GameModeOverride _override;
    bool _active;
    string _reason = "Off";

    internal GameModeController(ShellController shell, SettingsStore store, ForegroundWatcher foreground, Registry<SegmentDescriptor> segments)
    {
        _shell = shell; _store = store; _foreground = foreground; _segments = segments;
    }

    /// <summary>Auto / ForceOn / ForceOff. Driven by the hotkey, the tray menu and the settings page. Runtime only, starts at Auto.</summary>
    public GameModeOverride Override
    {
        get => _override;
        set { if (_override == value) return; _override = value; OverrideChanged?.Invoke(value); }
    }
    public event Action<GameModeOverride>? OverrideChanged;
    public void CycleOverride() => Override = (GameModeOverride)(((int)_override + 1) % 3);

    public bool IsActive => _active;
    /// <summary>Why the bar is (or is not) showing, for the settings page: "Fullscreen: game.exe", "Forced on", "Off".</summary>
    public string Reason => _reason;
    public event Action? StatusChanged;

    internal GameModeSettings Settings => _s;

    /// <summary>Loads gamemode.json (migrating the legacy segment flags), runs the self-test, installs the hooks, makes the first decision.</summary>
    public void Start()
    {
        _s = _store.Get<GameModeSettings>(FileId);
        if (_s.MigrateLegacy()) _store.Save(FileId, _s);

#if DEBUG
        RunSelfTest();
#else
        if (Environment.GetCommandLineArgs().Contains("--selftest-gamemode")) RunSelfTest();
#endif

        ApplyLayout();
        _foreground.Changed += _ => Request();
        OverrideChanged += _ => Request();
        _shell.AddHwndHook(OnHwndMessage);
        _size.Changed += OnSizeChanged;

        // The app may start while a game already owns the foreground.
        _shell.Dispatcher.BeginInvoke(DispatcherPriority.Background, () => Request());
    }

    static void RunSelfTest()
    {
        var failed = GameClassifier.SelfTest();
        if (failed.Count == 0) Log.Info("GameMode self-test: all cases passed");
        else Log.Error("GameMode self-test failed: " + string.Join(", ", failed));
    }

    nint OnHwndMessage(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        if (msg == Native.WM_DISPLAYCHANGE) Request();
        return 0;
    }

    // ---------- settings (called by the settings page) ----------

    /// <summary>Persist, re-apply layout and toggles; <paramref name="redetect"/> also re-evaluates the foreground (toggle or list edits).</summary>
    internal void SettingsChanged(bool redetect = false)
    {
        _store.Save(FileId, _s);
        ApplyLayout();
        ApplyToggles();
        if (redetect) Request();
    }

    internal bool IsSegmentOn(string id) => !_s.Segments.TryGetValue(id, out var on) || on;

    internal void SetSegment(string id, bool on)
    {
        _s.Segments[id] = on;
        SettingsChanged();
    }

    void ApplyLayout()
    {
        if (_bar is not null) System.Windows.Documents.TextElement.SetFontSize(_bar, Math.Clamp(Math.Round(_s.Height * 0.5), 10, 16));
        _shell.SetGameBarLayout(_s.Height, _s.Opacity, _s.OffsetX, _s.OffsetY);
    }

    void ApplyToggles()
    {
        foreach (var (id, wrap) in _wraps) wrap.Visibility = IsSegmentOn(id) ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---------- the bar ----------

    /// <summary>Builds the strip on first entry (the segment factories run then, not at startup) and keeps it in step with later registrations.</summary>
    void EnsureBar()
    {
        if (_bar is not null) return;
        _bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false, Focusable = false };
        FillBar();
        _segments.Changed += FillBar;
        ApplyLayout();
        _shell.SetGameBarView(_bar);
    }

    void FillBar()
    {
        _bar!.Children.Clear();
        foreach (var d in _segments.Items)
        {
            if (d.Slot != SegmentSlot.GameBar) continue;
            if (!_wraps.TryGetValue(d.Id, out var wrap))
            {
                if (_host.Get(d) is not { } el) continue;
                el.Margin = new Thickness(0, 0, 12, 0);
                _wraps[d.Id] = wrap = new Border { Child = el, Visibility = IsSegmentOn(d.Id) ? Visibility.Visible : Visibility.Collapsed };
            }
            _bar.Children.Add(wrap);
        }
    }

    // ---------- detection ----------

    /// <summary>Re-evaluate what should happen now. Entry is debounced, exit is immediate.</summary>
    void Request(bool confirmed = false)
    {
        try
        {
            var ov = _override;
            if (ov != GameModeOverride.Auto || !_s.AutoDetect)
            {
                CancelEntry();
                _sizeDebounce?.Stop();
                _size.Stop();
                Apply(ov == GameModeOverride.ForceOn, ov switch { GameModeOverride.ForceOn => "Forced on", GameModeOverride.ForceOff => "Forced off", _ => "Detection is off" });
                return;
            }

            var fg = Native.GetForegroundWindow();
            if (fg == 0) return;
            var facts = GameModeNative.Probe(fg, _shell.Hwnd, _shell.Monitor);
            var verdict = GameClassifier.Classify(facts, _s.AlwaysGame, _s.NeverGame, out var reason);
            if (verdict == GameVerdict.Ignore) return;

            _size.Watch(fg);
            if (verdict == GameVerdict.NotGame) { CancelEntry(); Apply(false, "Off"); }
            else if (_active) { CancelEntry(); SetReason(reason); }
            else if (confirmed) Apply(true, reason);
            else if (_entry is not { IsEnabled: true }) StartEntry();
        }
        catch (Exception ex) { Log.Warn("Game mode evaluation failed", ex); }
    }

    /// <summary>The location hook only wakes us; the probe (OpenProcess and friends) runs once after the window stopped moving.</summary>
    void OnSizeChanged()
    {
        if (_sizeDebounce is null)
        {
            _sizeDebounce = new DispatcherTimer(DispatcherPriority.Normal, _shell.Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
            _sizeDebounce.Tick += (_, _) => { _sizeDebounce.Stop(); Request(); };
        }
        _sizeDebounce.Stop();
        _sizeDebounce.Start();
    }

    void StartEntry()
    {
        if (_entry is null)
        {
            _entry = new DispatcherTimer(DispatcherPriority.Normal, _shell.Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
            _entry.Tick += (_, _) => { _entry.Stop(); Request(confirmed: true); };
        }
        _entry.Start();
    }

    void CancelEntry() => _entry?.Stop();

    void SetReason(string reason)
    {
        if (_reason == reason) return;
        _reason = reason;
        StatusChanged?.Invoke();
    }

    void Apply(bool active, string reason)
    {
        SetReason(reason);
        if (active == _active) return;
        _active = active;
        if (active) EnsureBar();
        StatusChanged?.Invoke();
        _shell.SetGameBarActive(active);   // shell: click-through, hides pill and panel; leaving restores them with a short fade
        Log.Info(active ? $"Game bar on ({reason})" : "Game bar off");
    }
}
