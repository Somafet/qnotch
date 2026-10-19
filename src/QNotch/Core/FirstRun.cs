namespace QNotch.Core;

/// <summary>What the app does about the welcome tour at startup.</summary>
public enum TourStart
{
    /// <summary>Nothing: the tour already ran, or this is a diagnostic run.</summary>
    None,
    /// <summary>A fresh install: show the tour before any module is created.</summary>
    Show,
    /// <summary>Settings from before the tour existed: record it as done, silently.</summary>
    MarkDone,
}

/// <summary>The startup decision for the welcome tour (spec/onboarding.md, When it shows). Kept apart from the tour so a normal start loads none of it.</summary>
public static class FirstRun
{
    /// <param name="settingsExist">general.json is on disk.</param>
    /// <param name="onboardingDone">Its OnboardingDone value.</param>
    /// <param name="diagnostic">A --snapshot run: it renders the steps instead.</param>
    public static TourStart Decide(bool settingsExist, bool onboardingDone, bool diagnostic) =>
        diagnostic ? TourStart.None
        : !settingsExist ? TourStart.Show
        : onboardingDone ? TourStart.None
        : TourStart.MarkDone;
}
