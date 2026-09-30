using System.Text;
using System.Text.Json;

namespace QNotch.Modules.Ai;

/// <summary>
/// Codex: no documented usage endpoint, so nothing is sent over the network and no token is read. Codex writes the account
/// rate limits it received into its local session logs (rate_limits on token_count events); this reads the newest reading.
/// The figures are as fresh as the last Codex turn, and windows that have already reset are dropped.
/// </summary>
internal sealed class CodexProvider : IUsageProvider
{
    const int TailBytes = 512 * 1024, MaxFiles = 8;

    public string Id => "codex";
    public string Name => "Codex";

    public Task<UsageResult> FetchAsync(CancellationToken ct) => Task.Run(() => Read(ct), ct);

    static UsageResult Read(CancellationToken ct)
    {
        var home = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(home)) home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        var auth = Path.Combine(home, "auth.json");
        if (!File.Exists(auth)) return UsageResult.Unavailable("Not signed in. Sign in to Codex to see usage.");

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(auth));
            if (!doc.RootElement.TryGetProperty("tokens", out var t) || t.ValueKind != JsonValueKind.Object)
                return UsageResult.Unavailable("Signed in with an API key. Plan usage needs a ChatGPT login.");
        }
        catch { return UsageResult.Unavailable("Codex sign-in file could not be read."); }

        var sessions = Path.Combine(home, "sessions");
        if (!Directory.Exists(sessions)) return UsageResult.Unavailable("No Codex sessions yet. Run a task to get a reading.");

        var now = DateTime.Now;
        var checkedFiles = 0;
        foreach (var file in NewestRollouts(sessions))
        {
            ct.ThrowIfCancellationRequested();
            if (checkedFiles++ >= MaxFiles) break;
            var r = ReadFile(file, now);
            if (r is not null) return r;
        }
        return UsageResult.Unavailable("No recent rate limit reading. Run a Codex task to refresh it.");
    }

    /// <summary>Sessions live in YYYY/MM/DD folders, so walk them newest first instead of enumerating everything.</summary>
    static IEnumerable<string> NewestRollouts(string root)
    {
        foreach (var y in Sub(root))
            foreach (var m in Sub(y))
                foreach (var d in Sub(m))
                {
                    string[] files;
                    try { files = Directory.GetFiles(d, "rollout-*.jsonl"); } catch { continue; }
                    Array.Sort(files, StringComparer.OrdinalIgnoreCase);
                    for (var i = files.Length - 1; i >= 0; i--) yield return files[i];
                }

        static IEnumerable<string> Sub(string dir)
        {
            string[] subs;
            try { subs = Directory.GetDirectories(dir); } catch { return []; }
            Array.Sort(subs, StringComparer.OrdinalIgnoreCase);
            Array.Reverse(subs);
            return subs;
        }
    }

    static UsageResult? ReadFile(string file, DateTime now)
    {
        string text;
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Max(0, fs.Length - TailBytes);
            fs.Seek(start, SeekOrigin.Begin);
            var buf = new byte[fs.Length - start];
            fs.ReadExactly(buf);
            text = Encoding.UTF8.GetString(buf);
            if (start > 0) { var nl = text.IndexOf('\n'); text = nl >= 0 ? text[(nl + 1)..] : ""; }
        }
        catch { return null; }

        var lines = text.Split('\n');
        for (var i = lines.Length - 1; i >= 0; i--)
        {
            var line = lines[i];
            if (!line.Contains("\"rate_limits\":{", StringComparison.Ordinal)) continue;
            try
            {
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                if (!root.TryGetProperty("payload", out var p) || !p.TryGetProperty("rate_limits", out var rl) || rl.ValueKind != JsonValueKind.Object) continue;
                var at = DateTimeOffset.TryParse(root.GetStringOrNull("timestamp"), out var ts) ? ts.LocalDateTime : now;
                var windows = new List<UsageWindow>();
                foreach (var key in new[] { "primary", "secondary" })
                    if (rl.TryGetProperty(key, out var w) && ParseWindow(w, at) is { } uw && (uw.ResetsAt is null || uw.ResetsAt > now))
                        windows.Add(uw);
                if (windows.Count > 0) return UsageResult.Ok(windows, PlanName(rl.GetStringOrNull("plan_type")), at);
            }
            catch (JsonException) { /* truncated or foreign line */ }
        }
        return null;
    }

    static UsageWindow? ParseWindow(JsonElement w, DateTime readAt)
    {
        if (w.ValueKind != JsonValueKind.Object || !w.TryGetProperty("used_percent", out var u) || u.ValueKind != JsonValueKind.Number) return null;
        DateTime? resets = null;
        if (w.TryGetProperty("resets_at", out var ra) && ra.ValueKind == JsonValueKind.Number)
            resets = DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64()).LocalDateTime;
        else if (w.TryGetProperty("resets_in_seconds", out var rs) && rs.ValueKind == JsonValueKind.Number)
            resets = readAt.AddSeconds(rs.GetDouble());
        var minutes = w.TryGetProperty("window_minutes", out var wm) && wm.ValueKind == JsonValueKind.Number ? wm.GetInt32() : 0;
        return new UsageWindow(Label(minutes), Math.Clamp(u.GetDouble(), 0, 100), resets);
    }

    static string Label(int minutes) => minutes switch
    {
        300 => "5-hour",
        10080 => "Weekly",
        <= 0 => "Limit",
        _ when minutes % 1440 == 0 => $"{minutes / 1440}-day",
        _ when minutes % 60 == 0 => $"{minutes / 60}-hour",
        _ => $"{minutes}-min",
    };

    static string? PlanName(string? plan) => string.IsNullOrEmpty(plan) ? null
        : plan.Equals("prolite", StringComparison.OrdinalIgnoreCase) ? "Pro Lite"
        : char.ToUpperInvariant(plan[0]) + plan[1..];
}
