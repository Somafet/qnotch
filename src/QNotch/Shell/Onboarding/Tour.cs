using System.Windows;
using QNotch.Core;
using QNotch.Modules;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// Entry points of the welcome tour. App calls these from methods of their own, so a normal start never loads the tour's types.
/// </summary>
public static class Tour
{
    static TourWindow? _open;

    /// <summary>
    /// Fresh install: runs the tour modally before any module exists, so the feature choices apply without a restart. Always records
    /// OnboardingDone (also when the tour fails). Returns true when the user finished with Open QNotch.
    /// </summary>
    public static bool RunFirst(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts, IReadOnlyList<ModuleInfo> modules)
    {
        TourWindow? w = null;
        try
        {
            w = new TourWindow(new TourChoices(TourMode.FirstRun, gs, modules.Select(m => m.Id)), gs, store, shortcuts, modules, null);
            w.ShowDialog();
            return w.OpenPanel;
        }
        catch (Exception ex)
        {
            Log.Error("Welcome tour failed", ex);
            try { w?.Close(); } catch { }
            if (!gs.OnboardingDone)
            {
                new TourChoices(TourMode.FirstRun, gs, modules.Select(m => m.Id)).Apply(gs, TourEnd.Skipped);
                store.Save("general", gs);
            }
            return false;
        }
    }

    /// <summary>Settings, General, Show welcome tour: runs while the app runs, with the Features step read-only.</summary>
    public static void ShowOnDemand(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts, IReadOnlyList<ModuleInfo> modules,
        Action<string> openSettings, Action openPanel)
    {
        if (_open is { } existing) { existing.Activate(); return; }
        try
        {
            var w = _open = new TourWindow(new TourChoices(TourMode.OnDemand, gs, modules.Select(m => m.Id)), gs, store, shortcuts, modules, openSettings);
            w.Closed += (_, _) =>
            {
                _open = null;
                if (w.OpenPanel) openPanel();
            };
            w.Show();
            w.Activate();
        }
        catch (Exception ex)
        {
            _open = null;
            Log.Error("Welcome tour failed", ex);
        }
    }

    /// <summary>Snapshot: renders every step (demo rows, nothing saved) through <paramref name="save"/> as onboarding-&lt;step&gt;, plus the
    /// read-only Features step of a tour opened from Settings.</summary>
    internal static void Snapshot(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts, IReadOnlyList<ModuleInfo> modules, Action<FrameworkElement, string> save)
    {
        foreach (var mode in new[] { TourMode.FirstRun, TourMode.OnDemand })
        {
            var w = new TourWindow(new TourChoices(mode, gs, modules.Select(m => m.Id)), gs, store, shortcuts, modules, _ => { })
            {
                NoAnimation = true, WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0, ShowActivated = false, ShowInTaskbar = false,
            };
            w.Show();
            try
            {
                for (var i = 0; i < w.Steps.Count; i++)
                {
                    if (mode == TourMode.OnDemand && w.Steps[i] != "features") continue;
                    w.Go(i);
                    w.UpdateLayout();
                    var root = (FrameworkElement)w.Content;
                    save(root, mode == TourMode.FirstRun ? $"onboarding-{w.StepId}" : $"onboarding-{w.StepId}-ondemand");
                }
            }
            finally { w.Discard(); }
        }
    }
}
