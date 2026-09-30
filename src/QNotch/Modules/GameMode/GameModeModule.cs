using System.ComponentModel;
using System.Windows.Interop;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Theme;
using MediaState = QNotch.Core.MediaState;

namespace QNotch.Modules.GameMode;

/// <summary>
/// Game mode: turns the notch into a passive one-line status bar while a fullscreen app owns the foreground.
/// Fully event driven: foreground changes (shell hook), WM_DISPLAYCHANGE, size changes of the foreground window (own scoped hook),
/// the override event and settings edits. Nothing runs while nothing changes; the only timer is a one-shot 250 ms entry debounce.
/// </summary>
public sealed class GameModeModule : INotchModule
{
    public string Id => "gamemode";

    ModuleContext _ctx = null!;
    GameModeSettings _s = null!;
    GameBar _bar = null!;
    DispatcherTimer? _entry, _sizeDebounce;
    readonly SizeWatcher _size = new();
    bool _active;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _s = ctx.Settings.Get<GameModeSettings>(Id);
        ctx.SettingsSections.Register(new SettingsSectionDescriptor("gamemode", "Game mode", Glyphs.Game, 20, () => GameModeSection.Create(ctx, this)));

#if DEBUG
        RunSelfTest();
#else
        if (Environment.GetCommandLineArgs().Contains("--selftest-gamemode")) RunSelfTest();
#endif

        _bar = new GameBar { DataContext = ctx.State };
        ctx.Shell.SetGameBarView(_bar);
        ApplyLayout();
        RefreshSegments();

        // Segment flags depend on a few live values; name-filtered, so a stats sample costs a couple of string compares.
        ctx.State.Media.PropertyChanged += OnDataChanged;
        ctx.State.Stats.PropertyChanged += OnDataChanged;

        ctx.Shell.Foreground.Changed += _ => Request();
        ctx.Shell.GameModeOverrideChanged += _ => Request();
        ctx.Shell.AddHwndHook(OnHwndMessage);
        _size.Changed += OnSizeChanged;

        // The app may start while a game already owns the foreground.
        ctx.Dispatcher.BeginInvoke(DispatcherPriority.Background, () => Request());
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

    void OnDataChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(StatsState.GpuAvailable):
            case nameof(StatsState.HasBattery):
            case nameof(MediaState.HasSession):
            case nameof(MediaState.IsPlaying):
            case nameof(MediaState.Title): RefreshSegments(); break;
        }
    }

    // ---------- settings (called by the settings page) ----------

    /// <summary>Persist, re-apply layout and segments; <paramref name="redetect"/> also re-evaluates the foreground (toggle or list edits).</summary>
    public void SettingsChanged(bool redetect = false)
    {
        _ctx.Settings.Save(Id, _s);
        ApplyLayout();
        RefreshSegments();
        if (redetect) Request();
    }

    void ApplyLayout()
    {
        _bar.FontSize = Math.Clamp(Math.Round(_s.Height * 0.5), 10, 16);
        _ctx.Shell.SetGameBarLayout(_s.Height, _s.Opacity, _s.OffsetX, _s.OffsetY);
    }

    void RefreshSegments()
    {
        var g = _ctx.State.GameMode;
        var st = _ctx.State.Stats;
        var m = _ctx.State.Media;
        g.ShowMedia = _s.ShowMedia && m.HasSession && m.IsPlaying && m.Title.Length > 0;
        g.ShowCpu = _s.ShowCpu;
        g.ShowGpu = _s.ShowGpu && st.GpuAvailable;   // a dead GPU counter means no segment, never "0%"
        st.GpuWanted = _active && g.ShowGpu;          // the sampler queries GPU at the slow cadence only while it is shown
        g.ShowRam = _s.ShowRam;
        g.ShowNet = _s.ShowNet;
        g.ShowBattery = _s.ShowBattery && st.HasBattery;
        g.ShowClock = _s.ShowClock;
    }

    // ---------- detection ----------

    /// <summary>Re-evaluate what should happen now. Entry is debounced, exit is immediate.</summary>
    void Request(bool confirmed = false)
    {
        try
        {
            var shell = _ctx.Shell;
            var ov = shell.GameModeOverride;
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
            var facts = GameModeNative.Probe(fg, shell.Hwnd, shell.Monitor);
            var verdict = GameClassifier.Classify(facts, _s.AlwaysGame, _s.NeverGame, out var reason);
            if (verdict == GameVerdict.Ignore) return;

            _size.Watch(fg);
            if (verdict == GameVerdict.NotGame) { CancelEntry(); Apply(false, "Off"); }
            else if (_active) { CancelEntry(); _ctx.State.GameMode.Reason = reason; }
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
            _sizeDebounce = new DispatcherTimer(DispatcherPriority.Normal, _ctx.Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
            _sizeDebounce.Tick += (_, _) => { _sizeDebounce.Stop(); Request(); };
        }
        _sizeDebounce.Stop();
        _sizeDebounce.Start();
    }

    void StartEntry()
    {
        if (_entry is null)
        {
            _entry = new DispatcherTimer(DispatcherPriority.Normal, _ctx.Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
            _entry.Tick += (_, _) => { _entry.Stop(); Request(confirmed: true); };
        }
        _entry.Start();
    }

    void CancelEntry() => _entry?.Stop();

    void Apply(bool active, string reason)
    {
        _ctx.State.GameMode.Reason = reason;
        if (active == _active) return;
        _active = active;
        RefreshSegments();
        _ctx.State.GameMode.IsActive = active;
        _ctx.Shell.SetGameBarActive(active);   // shell: click-through, hides pill and panel; leaving restores them with a short fade
        Log.Info(active ? $"Game bar on ({reason})" : "Game bar off");
    }
}
