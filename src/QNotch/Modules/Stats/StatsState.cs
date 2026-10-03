using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Modules.Stats;

/// <summary>System stats. Text properties are ready to render: "--" means not sampled yet, "n/a" means unavailable (never a fake 0).</summary>
public sealed partial class StatsState : ObservableObject
{
    [ObservableProperty] bool _hasSample;
    /// <summary>False once the GPU counters proved unusable.</summary>
    [ObservableProperty] bool _gpuAvailable = true;
    [ObservableProperty] int _cpuPercent;
    [ObservableProperty] int? _gpuPercent;
    [ObservableProperty] long _ramUsedBytes;
    [ObservableProperty] long _ramTotalBytes;
    [ObservableProperty] double _netDownBps;
    [ObservableProperty] double _netUpBps;
    [ObservableProperty] int? _batteryPercent;
    [ObservableProperty] bool _isCharging;
    [ObservableProperty] bool _hasBattery;
    [ObservableProperty] string _clock = "";

    [ObservableProperty] string _cpuText = "--";
    [ObservableProperty] string _gpuText = "n/a";
    /// <summary>" 61°C" (leading space: it follows the GPU percentage in the game bar), empty when unknown.</summary>
    [ObservableProperty] string _gpuTempText = "";
    [ObservableProperty] string _ramText = "--";
    [ObservableProperty] int _ramPercent;
    [ObservableProperty] string _netDownText = "--";
    [ObservableProperty] string _netUpText = "--";
    [ObservableProperty] string _batteryText = "";
    [ObservableProperty] string _batteryGlyph = "";
}
