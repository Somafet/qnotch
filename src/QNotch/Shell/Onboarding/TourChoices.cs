using QNotch.Core;

namespace QNotch.Shell.Onboarding;

/// <summary>FirstRun: shown automatically on a fresh install, before any module exists. OnDemand: Settings, General, Show welcome tour.</summary>
public enum TourMode { FirstRun, OnDemand }

/// <summary>Finished: the primary button of the last step. Skipped: Skip, Esc or closing the window.</summary>
public enum TourEnd { Finished, Skipped }

/// <summary>
/// What the user chose in the welcome tour, and how it lands in <see cref="GeneralSettings"/> (spec/onboarding.md). No WPF: the checks in
/// tests/QNotch.OnboardingTests drive it directly. A skip never discards a choice already made.
/// </summary>
public sealed class TourChoices
{
    /// <summary>Stable step ids, in order (snapshots, logs, tests).</summary>
    public static readonly IReadOnlyList<string> StepIds = ["welcome", "open", "features", "connect", "finish"];

    readonly List<string> _ids;
    bool _updatesTouched, _startTouched;

    public TourChoices(TourMode mode, GeneralSettings gs, IEnumerable<string> moduleIds)
    {
        Mode = mode;
        _ids = moduleIds.ToList();
        Off = mode == TourMode.FirstRun ? new(StringComparer.OrdinalIgnoreCase) : new(gs.DisabledModules, StringComparer.OrdinalIgnoreCase);
        // The tour shows the defaults on a fresh install, the current values when opened from Settings.
        Updates = mode == TourMode.FirstRun || gs.CheckForUpdates;
        StartWithWindows = mode == TourMode.FirstRun || gs.StartWithWindows;
    }

    public TourMode Mode { get; }

    /// <summary>Feature switches only on a first run: a running app cannot drop a module without a restart, so on demand it is a read-only list.</summary>
    public bool FeaturesEditable => Mode == TourMode.FirstRun;

    /// <summary>Module ids switched off (every switch starts on).</summary>
    public HashSet<string> Off { get; }
    public bool IsOn(string id) => !Off.Contains(id);

    public void SetOn(string id, bool on)
    {
        if (!FeaturesEditable) return;
        if (on) Off.Remove(id); else Off.Add(id);
    }

    public bool Updates { get; private set; }
    public void SetUpdates(bool on) { Updates = on; _updatesTouched = true; }

    public bool StartWithWindows { get; private set; }
    public void SetStartWithWindows(bool on) { StartWithWindows = on; _startTouched = true; }

    /// <summary>DisabledModules after the tour: ids the tour does not offer (an old id, a module of a newer version) stay, then the switched-off
    /// ones in <paramref name="ids"/> order.</summary>
    public static List<string> DisabledModules(IEnumerable<string> ids, IReadOnlySet<string> off, IEnumerable<string> existing)
    {
        var list = ids.ToList();
        var known = list.ToHashSet(StringComparer.OrdinalIgnoreCase);
        return existing.Where(x => !known.Contains(x)).Concat(list.Where(off.Contains)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// Writes the result into <paramref name="gs"/> (the caller saves it). Finished: everything as shown. Skipped: features as toggled so far,
    /// updates on unless the user turned them off (on demand: unchanged unless touched), Start with Windows only if touched. A first run always
    /// records the update choice, because the tour showed it, so Settings, Updates does not ask again.
    /// </summary>
    public void Apply(GeneralSettings gs, TourEnd end)
    {
        if (FeaturesEditable) gs.DisabledModules = DisabledModules(_ids, Off, gs.DisabledModules);
        var finished = end == TourEnd.Finished;
        if (finished || _updatesTouched || Mode == TourMode.FirstRun)
        {
            gs.CheckForUpdates = Updates;
            gs.UpdateChecksChoiceMade = true;
        }
        if (finished || _startTouched) gs.StartWithWindows = StartWithWindows;
        gs.OnboardingDone = true;
    }
}
