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

    /// <summary>The answer that opens the second step, which asks what was missing.</summary>
    public const string MissingFeature = "quit_missing_feature";

    /// <summary>The most characters of what-was-missing text that are sent.</summary>
    public const int MissingMaxLength = 200;

    /// <summary>The text the second step sends as <c>missing_feature</c>: trimmed, every run of whitespace or control characters made one
    /// space, cut to <see cref="MissingMaxLength"/> without splitting a surrogate pair. Null when nothing is left.</summary>
    public static string? CleanMissing(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var sb = new System.Text.StringBuilder(Math.Min(text.Length, MissingMaxLength));
        var gap = false;
        foreach (var c in text)
        {
            if (char.IsWhiteSpace(c) || char.IsControl(c)) { gap = sb.Length > 0; continue; }
            if (gap) { sb.Append(' '); gap = false; }
            sb.Append(c);
            if (sb.Length >= MissingMaxLength) break;
        }
        if (sb.Length > MissingMaxLength) sb.Length = MissingMaxLength;
        if (sb.Length > 0 && char.IsHighSurrogate(sb[^1])) sb.Length--;
        if (sb.Length > 0 && sb[^1] == ' ') sb.Length--; // the cut fell just after a gap
        return sb.Length == 0 ? null : sb.ToString();
    }

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
