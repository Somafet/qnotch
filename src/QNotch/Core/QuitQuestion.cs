namespace QNotch.Core;

/// <summary>
/// The first-week quit question (spec/analytics.md, Quit question): when QNotch is quit by the user on a new install it asks once for the main
/// reason. Pure decision and fixed answers, so a normal start loads none of the dialog.
/// </summary>
public static class QuitQuestion
{
    /// <summary>The question only goes to installs whose first run was less than this many days ago.</summary>
    public const int Days = 7;

    /// <summary>The fixed answers in display order: the analytics target and the button text. Skip, Esc and closing record <see cref="Skipped"/>.</summary>
    public static readonly IReadOnlyList<(string Target, string Label)> Answers =
    [
        ("quit_in_the_way", "It gets in my way"),
        ("quit_not_useful", "Nothing in it I'd use"),
        ("quit_missing_feature", "It's missing something I need"),
        ("quit_not_working", "Something didn't work"),
        ("quit_just_trying", "Just having a look"),
        ("quit_back_later", "Closing it for now, I'll be back"),
    ];

    public const string Skipped = "quit_skipped";

    /// <summary>Every target this question can record.</summary>
    public static IEnumerable<string> Targets => Answers.Select(a => a.Target).Append(Skipped);

    /// <param name="firstRun">When this install's first run was recorded (UTC); null for installs from before it existed.</param>
    /// <param name="asked">The question was shown to this install before.</param>
    /// <param name="analyticsOn">Usage data is enabled (preference and environment) and delivery is configured: otherwise the answer goes nowhere.</param>
    /// <param name="normalRun">Not a --snapshot, --smoke-test, --measure, --debug-control or read-only run.</param>
    /// <param name="gameMode">The shell is showing the game bar.</param>
    /// <param name="now">The current time. A clock earlier than <paramref name="firstRun"/> is not trusted: no question.</param>
    public static bool ShouldAsk(DateTimeOffset? firstRun, bool asked, bool analyticsOn, bool normalRun, bool gameMode, DateTimeOffset now)
    {
        if (firstRun is not { } first || asked || !analyticsOn || !normalRun || gameMode) return false;
        var age = now - first;
        return age >= TimeSpan.Zero && age < TimeSpan.FromDays(Days);
    }
}
