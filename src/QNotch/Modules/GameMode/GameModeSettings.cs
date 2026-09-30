namespace QNotch.Modules.GameMode;

/// <summary>gamemode.json. Opacity is 0..1; heights and offsets are DIPs. Process lists hold executable names ("game.exe").</summary>
public sealed class GameModeSettings
{
    /// <summary>Automatic detection (fullscreen rules and both process lists). The manual override works regardless.</summary>
    public bool AutoDetect { get; set; } = true;
    public double Opacity { get; set; } = 0.70;
    public double Height { get; set; } = 22;
    /// <summary>Offset of the bar center from the monitor's top-center (positive = right / down). Large values reach the corners.</summary>
    public double OffsetX { get; set; }
    public double OffsetY { get; set; }

    public bool ShowMedia { get; set; } = true;
    public bool ShowCpu { get; set; } = true;
    public bool ShowGpu { get; set; } = true;
    public bool ShowRam { get; set; } = true;
    public bool ShowNet { get; set; } = true;
    public bool ShowBattery { get; set; } = true;
    public bool ShowClock { get; set; } = true;

    /// <summary>Always game mode while one of these is in the foreground (even windowed).</summary>
    public List<string> AlwaysGame { get; set; } = new();
    /// <summary>Never game mode for these (a borderless video player you still want to interact with). Wins over the allow list.</summary>
    public List<string> NeverGame { get; set; } = new();
}
