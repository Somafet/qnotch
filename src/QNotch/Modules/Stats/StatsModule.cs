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

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Cards.Register(new CardDescriptor("stats", "System", 10, () => new StatsCard { DataContext = ctx.State.Stats }));
        ctx.Bus.Subscribe<StatsSample>(Apply);
        ctx.Bus.Subscribe<ClockTick>(t => ctx.State.Stats.Clock = t.Text);

        _sampleTimer = new Timer(SampleTick, null, 300, Timeout.Infinite);
        _clockTimer = new Timer(_ => ClockTickCb(), null, 0, Timeout.Infinite);
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
            // GPU counters can be expensive: at the slow cadence only sample them while cheap.
            int? gpu = _gpu.Available && (_fast || _gpu.AvgMs < 4) ? _gpu.Sample() : null;
            _ctx.Bus.Post(_sampler.Sample(gpu));
        }
        catch (Exception ex) { Log.Warn("Stats sample failed", ex); }
        finally { _sampleTimer.Change(_intervalMs, Timeout.Infinite); }
    }

    void ClockTickCb()
    {
        var now = DateTime.Now;
        _ctx.Bus.Post(new ClockTick(now.ToString("HH:mm")));
        _clockTimer.Change(60_000 - (now.Second * 1000 + now.Millisecond) + 30, Timeout.Infinite);
    }

    // ---------- UI thread ----------

    void Apply(StatsSample s)
    {
        var st = _ctx.State.Stats;
        st.HasSample = true;
        st.CpuPercent = s.Cpu;
        st.CpuText = $"{s.Cpu}%";
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
