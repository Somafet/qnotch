namespace QNotch.Modules.NoteGithub;

/// <summary>One day of the contribution calendar. Level is 0 to 4 (GitHub's own quartiles).</summary>
public sealed record GithubDay(DateOnly Date, int Count, int Level);

/// <summary>A fetched contribution calendar (also the on-disk cache shape). Immutable once built.</summary>
public sealed class GithubData
{
    public string Login { get; set; } = "";
    public DateTime FetchedUtc { get; set; }
    public int Total { get; set; }
    public List<GithubDay> Days { get; set; } = [];

    /// <summary>Consecutive days with contributions ending today (a still-empty today does not break the streak).</summary>
    public int Streak()
    {
        int i = Days.Count - 1, n = 0;
        if (i >= 0 && Days[i].Count == 0) i--;
        for (; i >= 0 && Days[i].Count > 0; i--) n++;
        return n;
    }

    /// <summary>Cheap content identity: equal signatures mean the graph does not need to be redrawn.</summary>
    public int Signature()
    {
        var h = new HashCode();
        h.Add(Total);
        foreach (var d in Days) { h.Add(d.Date.DayNumber); h.Add(d.Count); }
        return h.ToHashCode();
    }

    /// <summary>Deterministic fake data for the snapshot and demo mode (QNOTCH_GITHUB_DEMO=1).</summary>
    public static GithubData Demo()
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        var rng = new Random(7);
        var days = new List<GithubDay>();
        var total = 0;
        for (var d = today.AddDays(-364); d <= today; d = d.AddDays(1))
        {
            var weekend = d.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;
            var c = rng.NextDouble() < (weekend ? 0.35 : 0.8) ? rng.Next(1, weekend ? 6 : 14) : 0;
            if ((today.DayNumber - d.DayNumber) < 40) c = Math.Max(c, 1); // a live streak
            total += c;
            days.Add(new GithubDay(d, c, c == 0 ? 0 : c < 3 ? 1 : c < 6 ? 2 : c < 10 ? 3 : 4));
        }
        return new GithubData { Login = "octocat", FetchedUtc = DateTime.UtcNow.AddMinutes(-7), Total = total, Days = days };
    }
}
