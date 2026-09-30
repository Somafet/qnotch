using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Stats;

/// <summary>Clock text, posted on minute boundaries only.</summary>
internal sealed record ClockTick(string Text);

/// <summary>
/// Samples system stats on the thread pool (1 s at Cadence.Fast, 5 s at Cadence.Slow) and posts results through the EventBus.
/// The state is updated with set-if-changed properties, so unchanged text never invalidates a visual.
/// </summary>
public sealed class StatsModule : INotchModule, ICadenceAware
{
    public string Id => "stats";

    ModuleContext _ctx = null!;
    SystemSampler? _sampler;
    GpuSampler? _gpu;
    Timer _sampleTimer = null!, _clockTimer = null!;
    volatile int _intervalMs = 5000;
    volatile bool _fast;
    /// <summary>True while the game bar shows the GPU segment: the sampler then queries GPU at the slow cadence. Read on the thread pool.</summary>
    volatile bool _gpuWanted;
    readonly StatsState _st = new();

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Cards.Register(new CardDescriptor("stats", "System", 10, () => new StatsCard { DataContext = _st }));
        ctx.Segments.Register(new SegmentDescriptor("stats.pill", SegmentSlot.PillRight, 10, () => StatsSegments.Pill(_st)));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.cpu", SegmentSlot.GameBar, 20, () => StatsSegments.GameCpu(_st), "CPU"));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.gpu", SegmentSlot.GameBar, 30, () => StatsSegments.GameGpu(_st, on => _gpuWanted = on), "GPU", "Only when the system reports GPU usage."));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.ram", SegmentSlot.GameBar, 40, () => StatsSegments.GameRam(_st), "Memory"));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.net", SegmentSlot.GameBar, 50, () => StatsSegments.GameNet(_st), "Network"));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.battery", SegmentSlot.GameBar, 60, () => StatsSegments.GameBattery(_st), "Battery", "Only on devices with a battery."));
        ctx.Segments.Register(new SegmentDescriptor("stats.game.clock", SegmentSlot.GameBar, 70, () => StatsSegments.GameClock(_st), "Clock"));
        ctx.Bus.Subscribe<StatsSample>(Apply);
        ctx.Bus.Subscribe<ClockTick>(t => _st.Clock = t.Text);

        // Timers are created idle and armed after assignment: a callback must never see a null field.
        _sampleTimer = new Timer(SampleTick, null, Timeout.Infinite, Timeout.Infinite);
        _clockTimer = new Timer(_ => ClockTickCb(), null, Timeout.Infinite, Timeout.Infinite);
        _sampleTimer.Change(300, Timeout.Infinite);
        _clockTimer.Change(0, Timeout.Infinite);

        // A one-shot timer does not count time asleep: re-arm on resume and on clock or time-zone changes.
        ctx.Shell.AddHwndHook(OnHwndMessage);
    }

    const int WM_TIMECHANGE = 0x1E, WM_POWERBROADCAST = 0x218, PBT_APMRESUMEAUTOMATIC = 0x12;

    nint OnHwndMessage(nint hwnd, int msg, nint w, nint l, ref bool handled)
    {
        if (msg == WM_TIMECHANGE || (msg == WM_POWERBROADCAST && (int)w == PBT_APMRESUMEAUTOMATIC))
        {
            _clockTimer.Change(0, Timeout.Infinite);
            _sampleTimer.Change(0, Timeout.Infinite);
        }
        return 0;
    }

    public void SetCadence(Cadence cadence)
    {
        _fast = cadence == Cadence.Fast;
        _intervalMs = _fast ? 1000 : 5000;
        if (_fast) _sampleTimer?.Change(0, Timeout.Infinite); // refresh immediately when the panel opens
    }

    // ---------- thread pool ----------

    void SampleTick(object? _)
    {
        try
        {
            _sampler ??= new SystemSampler();
            _gpu ??= new GpuSampler();
            // The PDH GPU query is the expensive part: only while the panel is open or the game bar shows a GPU segment.
            int? gpu = _gpu.Available && (_fast || _gpuWanted) ? _gpu.Sample() : null;
            _ctx.Bus.Post(_sampler.Sample(gpu) with { GpuAvailable = _gpu.Available });
        }
        catch (Exception ex) { Log.Warn("Stats sample failed", ex); }
        finally { _sampleTimer.Change(_intervalMs, Timeout.Infinite); }
    }

    void ClockTickCb()
    {
        try
        {
            var now = DateTime.Now;
            _ctx.Bus.Post(new ClockTick(now.ToString("HH:mm")));
            _clockTimer.Change(60_000 - (now.Second * 1000 + now.Millisecond) + 30, Timeout.Infinite);
        }
        catch (Exception ex) { Log.Warn("Clock tick failed", ex); }
    }

    // ---------- UI thread ----------

    void Apply(StatsSample s)
    {
        var st = _st;
        st.HasSample = true;
        st.CpuPercent = s.Cpu;
        st.CpuText = $"{s.Cpu}%";
        st.GpuAvailable = s.GpuAvailable;
        st.GpuPercent = s.Gpu;
        st.GpuText = s.Gpu is { } g ? $"{g}%" : "n/a";
        st.RamUsedBytes = s.RamUsed;
        st.RamTotalBytes = s.RamTotal;
        st.RamPercent = s.RamTotal > 0 ? (int)(s.RamUsed * 100 / s.RamTotal) : 0;
        st.RamText = s.RamTotal > 0 ? $"{s.RamUsed / 1073741824.0:0.0}/{s.RamTotal / 1073741824.0:0.0} GB" : "n/a";
        st.NetDownBps = s.NetDown ?? 0;
        st.NetUpBps = s.NetUp ?? 0;
        st.NetDownText = Rate(s.NetDown);
        st.NetUpText = Rate(s.NetUp);
        st.HasBattery = s.HasBattery;
        st.IsCharging = s.Charging;
        st.BatteryPercent = s.BatteryPercent;
        st.BatteryText = s.BatteryPercent is { } b ? $"{b}%" : "";
        st.BatteryGlyph = !s.HasBattery ? "" : s.Charging ? Glyphs.BatteryCharging
            : s.BatteryPercent is { } p ? (p >= 95 ? Glyphs.Battery : ((char)(0xE850 + p / 10)).ToString()) : Glyphs.Battery;
    }

    static string Rate(double? bps) => bps switch
    {
        null => "n/a",
        >= 1024 * 1024 => $"{bps / 1048576.0:0.0} MB/s",
        _ => $"{bps / 1024.0:0} KB/s",
    };
}
