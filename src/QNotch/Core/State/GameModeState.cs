using CommunityToolkit.Mvvm.ComponentModel;

namespace QNotch.Core;

/// <summary>
/// Game mode: whether the bar is showing and which segments it draws. The segment flags already combine the user toggle with data
/// availability (for example no GPU counter means no GPU segment), so the bar view only binds and never decides.
/// </summary>
public sealed partial class GameModeState : ObservableObject
{
    [ObservableProperty] bool _isActive;
    /// <summary>Why the bar is (or is not) showing, for the settings page: "Fullscreen: game.exe", "Forced on", "Off".</summary>
    [ObservableProperty] string _reason = "Off";

    [ObservableProperty] bool _showMedia;
    [ObservableProperty] bool _showCpu;
    [ObservableProperty] bool _showGpu;
    [ObservableProperty] bool _showRam;
    [ObservableProperty] bool _showNet;
    [ObservableProperty] bool _showBattery;
    [ObservableProperty] bool _showClock;

    /// <summary>Reserved slot for a frame-time readout (out of scope for v1: needs a presentation hook). Hidden while empty.</summary>
    [ObservableProperty] string _fpsText = "";
    [ObservableProperty] bool _showFps;
}

public sealed partial class AppState
{
    public GameModeState GameMode { get; } = new();
}
