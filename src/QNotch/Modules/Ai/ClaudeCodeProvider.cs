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
    const string Url = "https://api.anthropic.com/api/oauth/usage";

    static readonly Lazy<HttpClient> Http = new(() => new HttpClient(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(20),
    }) { Timeout = TimeSpan.FromSeconds(20) });

    static readonly (string Key, string Label)[] Windows =
    [
        ("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet"),
    ];

    public string Id => "claude";
    public string Name => "Claude Code";

    public async Task<UsageResult> FetchAsync(CancellationToken ct)
    {
        var dir = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (string.IsNullOrWhiteSpace(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
        var file = Path.Combine(dir, ".credentials.json");
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
        req.Headers.UserAgent.ParseAdd("QNotch/1.0");
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
        return list.Count > 0 ? UsageResult.Ok(list, plan, DateTime.Now) : UsageResult.Unavailable("Unexpected response from the usage endpoint.");
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
