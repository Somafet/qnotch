namespace QNotch.Core;

/// <summary>
/// Pure rules for where a moved pill stays (spec/notch-position.md). NotchNudge does the moving; this decides the mode, the spot
/// and the one-time per-app hint.
/// </summary>
public static class NotchPlacement
{
    public const string HintText = "Each app keeps its own pill spot · Settings";
    public const int HintMs = 6000;

    /// <summary>The saved choice, or for settings from before it existed: per app when app spots were already saved
    /// (nobody's layout changes on update), otherwise one spot for every app.</summary>
    public static NotchPositionMode Resolve(NotchPositionMode? saved, int savedAppSpots) =>
        saved ?? (savedAppSpots > 0 ? NotchPositionMode.PerApp : NotchPositionMode.Everywhere);

    /// <summary>Where the pill sits while <paramref name="app"/> is in front (DIPs from the display center, ±10000 for an edge).</summary>
    public static double Spot(NotchPositionMode mode, double everywhere, IReadOnlyDictionary<string, double> appSpots, string app) =>
        mode == NotchPositionMode.Everywhere ? everywhere : appSpots.TryGetValue(app, out var x) ? x : 0;

    /// <summary>The hint peeks once, the first time the pill moves by itself because another app came to the front, and only where a
    /// peek can show (collapsed, not in game mode). A move it could not show on leaves it for the next one.</summary>
    public static bool ShouldHint(NotchPositionMode mode, bool shown, double from, double to, bool collapsed, bool gameMode) =>
        mode == NotchPositionMode.PerApp && !shown && Math.Abs(from - to) > 0.5 && collapsed && !gameMode;
}
