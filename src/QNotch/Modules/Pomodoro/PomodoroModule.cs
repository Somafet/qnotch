using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using QNotch.Theme;

namespace QNotch.Modules.Pomodoro; // not "Timer": that name would hide System.Threading.Timer in every module

public sealed class TimerSettings { public int Minutes { get; set; } = 25; }

internal sealed partial class TimerState : ObservableObject
{
    /// <summary>"24:59" for the card.</summary>
    [ObservableProperty] string _text = "";
    /// <summary>What the pill and the game bar show: "25m" while collapsed, "0:42" in the last minute or while the panel is open, "Time is up".</summary>
    [ObservableProperty] string _shortText = "";
    /// <summary>"Paused", "Time is up" or empty.</summary>
    [ObservableProperty] string _status = "";
    [ObservableProperty] bool _isRunning;
    /// <summary>Running, paused or just finished: the pill shows the timer.</summary>
    [ObservableProperty] bool _isActive;
    [ObservableProperty] int _minutes;
}

/// <summary>
/// Countdown with Pomodoro presets. The end is a wall clock time, so ticks only refresh the text: once a second while the panel is
/// open or in the last minute, once a minute while collapsed. No timer exists while nothing runs.
/// </summary>
public sealed class PomodoroModule : INotchModule, ICadenceAware
{
    const string Id = "timer", Clock = "", Reset = "";
    static readonly int[] Presets = [5, 15, 25, 50];
    static readonly TimeSpan Second = TimeSpan.FromSeconds(1), Minute = TimeSpan.FromMinutes(1);

    readonly TimerState _st = new();
    ModuleContext _ctx = null!;
    TimerSettings _s = null!;
    DispatcherTimer _tick = null!;
    TimeSpan _left;   // while not running
    DateTime _end;    // while running
    bool _fast, _done;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _s = ctx.Settings.Get<TimerSettings>(Id);
        _tick = new DispatcherTimer(DispatcherPriority.Background, ctx.Dispatcher);
        _tick.Tick += (_, _) => Refresh();

        ctx.Cards.Register(new CardDescriptor(Id, "Timer", 26, Card));
        ctx.Segments.Register(new SegmentDescriptor("timer.pill", SegmentSlot.PillRight, 7, () => Segment(gap: true)));
        ctx.Segments.Register(new SegmentDescriptor("timer.game", SegmentSlot.GameBar, 65, () => Segment(gap: false), "Timer", "Time left, only while a timer runs."));

        SetMinutes(Math.Clamp(_s.Minutes, 1, 180), save: false);
        if (ctx.Settings.ReadOnly) { _left = new TimeSpan(0, 18, 42); _st.IsActive = true; _st.Status = "Paused"; Refresh(); } // snapshot run: frozen demo
    }

    public void SetCadence(Cadence cadence)
    {
        _fast = cadence == Cadence.Fast;
        if (_st.IsRunning) Refresh();
    }

    // ---------- commands (UI thread) ----------

    void Toggle()
    {
        if (_st.IsRunning) { _left = _end - DateTime.UtcNow; _tick.Stop(); _st.IsRunning = false; _st.Status = "Paused"; }
        else
        {
            if (_left <= TimeSpan.Zero) _left = TimeSpan.FromMinutes(_st.Minutes);
            _end = DateTime.UtcNow + _left;
            _done = false;
            _st.IsRunning = _st.IsActive = true;
            _st.Status = "";
        }
        Refresh();
    }

    void SetMinutes(int minutes, bool save = true)
    {
        _tick.Stop();
        _done = false;
        _st.Minutes = minutes;
        _left = TimeSpan.FromMinutes(minutes);
        _st.IsRunning = _st.IsActive = false;
        _st.Status = "";
        if (save && !_ctx.Settings.ReadOnly) { _s.Minutes = minutes; _ctx.Settings.Save(Id, _s); }
        Refresh();
    }

    void Finished()
    {
        _tick.Stop();
        _done = true;
        _st.IsRunning = false;
        // Pomodoro: a break is lined up after a focus block and the other way around. Other lengths just repeat.
        _st.Minutes = _st.Minutes switch { 25 or 50 => 5, 5 => 25, var m => m };
        _left = TimeSpan.FromMinutes(_st.Minutes);
        _st.Status = _st.ShortText = "Time is up";
        _st.Text = Long(_left);
        System.Media.SystemSounds.Exclamation.Play();
        _ctx.Shell.TryOpenPanel("home", 5000);
    }

    // ---------- text and the next tick ----------

    void Refresh()
    {
        if (_done) return;
        var left = _st.IsRunning ? _end - DateTime.UtcNow : _left;
        if (_st.IsRunning && left <= TimeSpan.Zero) { Finished(); return; }
        var seconds = _fast || left <= Minute || !_st.IsRunning;
        _st.Text = Long(left);
        _st.ShortText = seconds ? _st.Text : $"{Math.Ceiling(left.TotalMinutes):0}m";
        if (!_st.IsRunning) return;
        // Wake just after the shown value goes stale.
        var unit = seconds ? Second : Minute;
        var wait = TimeSpan.FromTicks(left.Ticks % unit.Ticks);
        _tick.Stop();
        _tick.Interval = wait + TimeSpan.FromMilliseconds(15);
        _tick.Start();
    }

    /// <summary>Rounded up, so a fresh 25 minutes reads "25:00" and the last second reads "0:01".</summary>
    static string Long(TimeSpan t)
    {
        var s = (long)Math.Ceiling(Math.Max(0, t.TotalSeconds));
        return $"{s / 60}:{s % 60:00}";
    }

    // ---------- views ----------

    FrameworkElement Card()
    {
        Button Icon(string tip, Action click)
        {
            var b = new Button { Style = (Style)Application.Current.FindResource("IconButton"), ToolTip = tip };
            b.Click += (_, _) => click();
            return b;
        }

        var time = new TextBlock { FontSize = 28, FontWeight = FontWeights.SemiBold, ToolTip = "Scroll to change the length" };
        UiKit.Bind(time, TextBlock.TextProperty, _st, nameof(TimerState.Text));
        var status = UiKit.Text("", "Muted");
        status.VerticalAlignment = VerticalAlignment.Bottom;
        status.Margin = new Thickness(8, 0, 0, 6);
        UiKit.Bind(status, TextBlock.TextProperty, _st, nameof(TimerState.Status));

        var play = Icon("Start or pause", Toggle);
        var reset = Icon("Reset", () => SetMinutes(_st.Minutes));
        reset.Content = Reset;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        buttons.Children.Add(play);
        buttons.Children.Add(reset);
        DockPanel.SetDock(buttons, Dock.Right);
        var top = new DockPanel();
        top.Children.Add(buttons);
        top.Children.Add(time);
        top.Children.Add(status);

        var presets = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-2, 8, -2, 0) };
        var radios = new Dictionary<int, RadioButton>();
        foreach (var m in Presets)
        {
            var rb = new RadioButton { Style = (Style)Application.Current.FindResource("SegmentButton"), Content = m.ToString(), GroupName = "timer-preset", FontSize = 12, ToolTip = $"{m} minutes" };
            rb.Click += (_, _) => SetMinutes(m);
            radios[m] = rb;
            presets.Children.Add(rb);
        }

        // Transparent background so the wheel works anywhere on the card body.
        var root = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Background = System.Windows.Media.Brushes.Transparent };
        root.Children.Add(top);
        root.Children.Add(presets);
        root.MouseWheel += (_, e) =>
        {
            e.Handled = true;
            if (!_st.IsActive) SetMinutes(Math.Clamp(_st.Minutes + Math.Sign(e.Delta), 1, 180));
        };

        void Sync()
        {
            play.Content = _st.IsRunning ? Glyphs.Pause : Glyphs.Play;
            foreach (var (m, rb) in radios) rb.IsChecked = m == _st.Minutes;
        }
        _st.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(TimerState.IsRunning) or nameof(TimerState.Minutes)) Sync(); };
        Sync();
        return root;
    }

    /// <summary>Pill and game bar: clock glyph and the time left, collapsed while no timer is active.</summary>
    FrameworkElement Segment(bool gap)
    {
        var glyph = UiKit.Glyph(Clock, 12, "AccentBrush");
        glyph.VerticalAlignment = VerticalAlignment.Center;
        glyph.Margin = new Thickness(0, 0, 5, 0);
        var text = new TextBlock { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(text, TextBlock.TextProperty, _st, nameof(TimerState.ShortText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (gap) p.Margin = new Thickness(0, 0, 12, 0); // same gap the stats pill puts between its parts
        p.Children.Add(glyph);
        p.Children.Add(text);
        return UiKit.BindVisible(p, _st, nameof(TimerState.IsActive));
    }
}
