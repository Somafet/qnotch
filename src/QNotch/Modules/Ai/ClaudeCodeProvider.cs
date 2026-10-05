using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using QNotch.Core;

namespace QNotch.Modules.Ai;

/// <summary>Claude Code: reads the local OAuth token and asks Anthropic's usage endpoint. The token never leaves this class except to api.anthropic.com and is never logged.</summary>
internal sealed class ClaudeCodeProvider : IUsageProvider
{
    // cedar_ember=1 adds the banked resets (the Claude CLI asks the same way); skip_spend=1 leaves out the spend block QNotch does not show.
    const string Url = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1";

    static readonly Lazy<HttpClient> Http = new(() => new HttpClient(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(20),
    }) { Timeout = TimeSpan.FromSeconds(20) });

    static readonly (string Key, string Label)[] Windows =
    [
        ("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet"),
    ];

    /// <summary>The newest version the native installer has unpacked; a known recent one when Claude Code came from npm.</summary>
    static readonly Lazy<string> CliVersion = new(() =>
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share", "claude", "versions");
            if (Directory.Exists(dir) && Directory.GetFileSystemEntries(dir).Select(Path.GetFileName).Select(n => Version.TryParse(n, out var v) ? v : null).Max() is { } max)
                return max.ToString();
        }
        catch (Exception ex) { Log.Warn("Reading the Claude Code version failed", ex); }
        return "2.1.289";
    });

    readonly string _dir;

    ClaudeCodeProvider(string dir, string id, string account) { _dir = dir; Id = id; Account = account; }

    public string Id { get; }
    public string Name => "Claude Code";
    /// <summary>Account name until the user picks one: "Default" or the folder suffix.</summary>
    public string Account { get; }
    public string Dir => _dir;

    /// <summary>One provider per account: the default config folder, plus every signed-in ~/.claude-* folder (accounts kept apart with CLAUDE_CONFIG_DIR).</summary>
    public static List<ClaudeCodeProvider> Discover()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var main = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (string.IsNullOrWhiteSpace(main)) main = Path.Combine(home, ".claude");
        var list = new List<ClaudeCodeProvider> { new(main, "claude", "Default") };
        try
        {
            foreach (var d in Directory.GetDirectories(home, ".claude-*").Order())
            {
                if (string.Equals(d, Path.TrimEndingDirectorySeparator(main), StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(d, ".credentials.json"))) continue;
                var tag = Path.GetFileName(d)[".claude-".Length..];
                list.Add(new(d, "claude:" + tag, tag));
            }
        }
        catch (Exception ex) { Log.Warn("Looking for Claude Code accounts failed", ex); }
        return list;
    }

    public async Task<UsageResult> FetchAsync(CancellationToken ct)
    {
        var file = Path.Combine(_dir, ".credentials.json");
        if (!File.Exists(file)) return UsageResult.Unavailable("Not signed in. Sign in to Claude Code to see usage.");

        string token, plan;
        try
        {
            await using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var doc = await JsonDocument.ParseAsync(fs, cancellationToken: ct);
            if (!doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth) || oauth.ValueKind != JsonValueKind.Object
                || oauth.GetStringOrNull("accessToken") is not { Length: > 0 } t)
                return UsageResult.Unavailable("Signed in without a subscription. Usage needs a Claude Pro or Max login.");
            token = t;
            plan = PlanName(oauth.GetStringOrNull("subscriptionType"), oauth.GetStringOrNull("rateLimitTier"));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return UsageResult.Unavailable("Claude Code credentials could not be read.");
        }

        using var req = new HttpRequestMessage(HttpMethod.Get, Url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        // Banked resets are only reported to the Claude CLI, and only to a recent version of it, so speak as the installed one.
        req.Headers.UserAgent.ParseAdd($"claude-cli/{CliVersion.Value} (external, cli)");
        using var resp = await Http.Value.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct);

        if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            return UsageResult.Unavailable("Sign-in expired. Open Claude Code once to renew it.");
        if (resp.StatusCode == HttpStatusCode.TooManyRequests)
            return UsageResult.Unavailable("Rate limited by Anthropic. Will retry on the next refresh.");
        if (!resp.IsSuccessStatusCode)
        {
            Log.Warn($"Claude usage endpoint returned {(int)resp.StatusCode}");
            return UsageResult.Unavailable($"Usage endpoint returned HTTP {(int)resp.StatusCode}.");
        }

        using var body = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        var list = new List<UsageWindow>();
        foreach (var (key, label) in Windows)
        {
            if (!body.RootElement.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) continue;
            if (!w.TryGetProperty("utilization", out var u) || u.ValueKind != JsonValueKind.Number) continue;
            DateTime? resets = DateTimeOffset.TryParse(w.GetStringOrNull("resets_at"), out var r) ? r.LocalDateTime : null;
            list.Add(new UsageWindow(label, Math.Clamp(u.GetDouble(), 0, 100), resets));
        }
        return list.Count > 0 ? UsageResult.Ok(list, plan, DateTime.Now, Banked(body.RootElement)) : UsageResult.Unavailable("Unexpected response from the usage endpoint.");
    }

    /// <summary>Counts the grants usable right now; the expiry is that of the next grant, the one a reset would spend. Null when nothing is usable.</summary>
    static BankedResets? Banked(JsonElement root)
    {
        if (!root.TryGetProperty("cedar_ember", out var ce) || ce.ValueKind != JsonValueKind.Object
            || !ce.TryGetProperty("eligible", out var el) || el.ValueKind != JsonValueKind.True
            || !ce.TryGetProperty("grants", out var grants) || grants.ValueKind != JsonValueKind.Array) return null;
        var nextId = ce.GetStringOrNull("next_grant_id");
        var count = 0;
        DateTime? expires = null;
        var hasNext = false;
        string? label = null;
        foreach (var g in grants.EnumerateArray())
        {
            if (g.ValueKind != JsonValueKind.Object || g.TryGetProperty("paused", out var p) && p.ValueKind == JsonValueKind.True
                || g.TryGetProperty("usable_now", out var u) && u.ValueKind == JsonValueKind.False) continue;
            DateTime? ends = DateTimeOffset.TryParse(g.GetStringOrNull("ends_at"), out var e) ? e.LocalDateTime : null;
            if (ends <= DateTime.Now) continue;
            if (g.TryGetProperty("resets_left", out var n) && n.ValueKind == JsonValueKind.Number && n.TryGetInt32(out var left) && left > 0) count += left;
            if (g.GetStringOrNull("id") == nextId) { hasNext = true; expires = ends; label = g.GetStringOrNull("label"); }
        }
        return hasNext && count > 0 ? new BankedResets(count, expires, label) : null;
    }

    static string PlanName(string? sub, string? tier)
    {
        if (string.IsNullOrEmpty(sub)) return "";
        var name = char.ToUpperInvariant(sub[0]) + sub[1..];
        var m = tier is null ? Match.Empty : Regex.Match(tier, @"(\d+)x");
        return m.Success ? $"{name} {m.Value}" : name;
    }
}

internal static class JsonExt
{
    public static string? GetStringOrNull(this JsonElement e, string prop) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
