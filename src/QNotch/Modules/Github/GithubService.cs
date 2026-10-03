using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using QNotch.Core;

namespace QNotch.Modules.Github;

sealed class GithubException(string message, bool offline) : Exception(message)
{
    public bool Offline { get; } = offline;
}

/// <summary>
/// Contribution calendar provider. All I/O runs on the thread pool; results reach <see cref="GithubState"/> through the bus.
/// One-shot timer (hourly, 10 min after a failure): nothing runs between refreshes. The last response is cached in github-cache.json.
/// </summary>
internal sealed class GithubService
{
    static readonly string CacheFile = Path.Combine(Paths.DataDir, "github-cache.json");
    static readonly JsonSerializerOptions CacheJson = new() { PropertyNameCaseInsensitive = true };
    static readonly TimeSpan Interval = TimeSpan.FromHours(1), RetryAfterError = TimeSpan.FromMinutes(10);

    const string CalendarQuery = "query { viewer { login contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel } } } } } }";

    readonly ModuleContext _ctx;
    readonly GithubState _s;
    readonly Timer _timer;
    readonly bool _demo = Environment.GetEnvironmentVariable("QNOTCH_GITHUB_DEMO") == "1";
    int _busy;

    public GithubService(ModuleContext ctx, GithubState state)
    {
        _ctx = ctx;
        _s = state;
        _timer = new Timer(_ => _ = RefreshAsync(), null, Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>Loads the token state and disk cache off the UI thread, then schedules the first refresh.</summary>
    public void Start() => Task.Run(() =>
    {
        try
        {
            if (_demo) { var demo = GithubData.Demo(); _ctx.Bus.Run(() => { _s.GithubHasToken = true; Show(demo, false, ""); }); return; }
            var has = !string.IsNullOrEmpty(CredentialStore.Read());
            var cache = has ? ReadCache() : null;
            _ctx.Bus.Run(() =>
            {
                _s.GithubHasToken = has;
                if (!has) _s.GithubStatus = GithubStatus.NoToken;
                else if (cache is not null) Show(cache, false, "");
            });
            if (!has) return;
            var age = cache is null ? Interval : DateTime.UtcNow - cache.FetchedUtc;
            var wait = age >= Interval - TimeSpan.FromMinutes(5) ? TimeSpan.FromSeconds(3) : Interval - age;
            _timer.Change(wait, Timeout.InfiniteTimeSpan);
        }
        catch (Exception ex) { Log.Warn("GitHub start failed", ex); }
    });

    /// <summary>Panel opened: the relative "updated" text is the only thing that ages.</summary>
    public void RefreshTexts()
    {
        if (_s.GithubGraph is { } d) _s.GithubUpdatedText = UpdatedText(d, _s.GithubStale);
    }

    /// <summary>Safe to call from the UI thread: the whole refresh (credential read, JSON parse, cache write) runs on the thread pool.</summary>
    public Task RefreshAsync() => Task.Run(RefreshCore);

    async Task RefreshCore()
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            if (_demo) return;
            var token = CredentialStore.Read();
            if (string.IsNullOrEmpty(token)) { _ctx.Bus.Run(() => { _s.GithubHasToken = false; _s.GithubStatus = GithubStatus.NoToken; }); return; }
            _ctx.Bus.Run(() => { _s.GithubRefreshing = true; if (_s.GithubGraph is null) _s.GithubStatus = GithubStatus.Loading; });
            var next = Interval;
            try
            {
                var data = await FetchAsync(token);
                WriteCache(data);
                _ctx.Bus.Run(() => Show(data, false, ""));
            }
            catch (GithubException ex)
            {
                next = RetryAfterError;
                _ctx.Bus.Run(() => Fail(ex.Message, ex.Offline));
            }
            _timer.Change(next, Timeout.InfiniteTimeSpan);
        }
        catch (Exception ex)
        {
            Log.Warn("GitHub refresh failed", ex);
            _timer.Change(RetryAfterError, Timeout.InfiniteTimeSpan);
            _ctx.Bus.Run(() => Fail("Something went wrong. See the log.", false));
        }
        finally
        {
            _ctx.Bus.Run(() => _s.GithubRefreshing = false);
            Volatile.Write(ref _busy, 0);
        }
    }

    /// <summary>Validates a token without storing it. Returns a one-line result for the settings page.</summary>
    public static async Task<(bool Ok, string Message)> TestAsync(string token)
    {
        try
        {
            var data = await QueryAsync(token, "query { viewer { login } }");
            return (true, $"Connected as @{data.GetProperty("viewer").GetProperty("login").GetString()}.");
        }
        catch (GithubException ex) { return (false, ex.Message); }
    }

    /// <summary>Stores the token in Credential Manager and fetches right away.</summary>
    public async Task<bool> SaveTokenAsync(string token)
    {
        if (!await Task.Run(() => CredentialStore.Write(token))) return false;
        _s.GithubHasToken = true;
        _s.GithubMessage = "";
        if (_s.GithubGraph is null) _s.GithubStatus = GithubStatus.Loading;
        _ = RefreshAsync();
        return true;
    }

    /// <summary>Removes the token and the cached activity.</summary>
    public async Task ClearTokenAsync()
    {
        _timer.Change(Timeout.Infinite, Timeout.Infinite);
        await Task.Run(() => { CredentialStore.Delete(); try { File.Delete(CacheFile); } catch { } });
        _s.GithubHasToken = false;
        _s.GithubGraph = null;
        _s.GithubStale = false;
        _s.GithubMessage = _s.GithubTotalText = _s.GithubStreakText = _s.GithubUpdatedText = _s.GithubLogin = "";
        _s.GithubStatus = GithubStatus.NoToken;
    }

    // ---------- UI thread ----------

    void Show(GithubData d, bool stale, string message)
    {
        // Unchanged data keeps the same graph object, so the contribution grid is not redrawn.
        if (_s.GithubGraph is null || _s.GithubGraph.Signature() != d.Signature()) _s.GithubGraph = d;
        else _s.GithubGraph.FetchedUtc = d.FetchedUtc;
        var shown = _s.GithubGraph;
        _s.GithubLogin = shown.Login;
        _s.GithubTotalText = shown.Total == 1 ? "1 contribution" : $"{shown.Total:N0} contributions";
        var streak = shown.Streak();
        _s.GithubStreakText = streak > 0 ? $"{streak} day streak" : "No active streak";
        _s.GithubStale = stale;
        _s.GithubMessage = message;
        _s.GithubUpdatedText = UpdatedText(shown, stale);
        _s.GithubStatus = GithubStatus.Ready;
    }

    void Fail(string message, bool offline)
    {
        if (_s.GithubGraph is { } d)
        {
            _s.GithubStale = true;
            _s.GithubMessage = offline ? "Offline, showing saved activity." : $"Could not refresh: {message}";
            _s.GithubUpdatedText = UpdatedText(d, true);
            _s.GithubStatus = GithubStatus.Ready;
        }
        else
        {
            _s.GithubMessage = message;
            _s.GithubStatus = GithubStatus.Error;
        }
    }

    static string UpdatedText(GithubData d, bool stale)
    {
        var age = DateTime.UtcNow - d.FetchedUtc;
        var ago = age.TotalMinutes < 1 ? "just now" : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago" : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago" : $"{(int)age.TotalDays} d ago";
        return (stale ? "Saved " : "Updated ") + ago;
    }

    // ---------- thread pool ----------

    static async Task<GithubData> FetchAsync(string token)
    {
        var data = await QueryAsync(token, CalendarQuery);
        var viewer = data.GetProperty("viewer");
        var cal = viewer.GetProperty("contributionsCollection").GetProperty("contributionCalendar");
        var days = new List<GithubDay>(371);
        foreach (var week in cal.GetProperty("weeks").EnumerateArray())
            foreach (var day in week.GetProperty("contributionDays").EnumerateArray())
                days.Add(new GithubDay(DateOnly.Parse(day.GetProperty("date").GetString()!), day.GetProperty("contributionCount").GetInt32(),
                    day.GetProperty("contributionLevel").GetString() switch { "FIRST_QUARTILE" => 1, "SECOND_QUARTILE" => 2, "THIRD_QUARTILE" => 3, "FOURTH_QUARTILE" => 4, _ => 0 }));
        days.Sort((a, b) => a.Date.CompareTo(b.Date));
        return new GithubData
        {
            Login = viewer.GetProperty("login").GetString() ?? "",
            FetchedUtc = DateTime.UtcNow,
            Total = cal.GetProperty("totalContributions").GetInt32(),
            Days = days,
        };
    }

    /// <summary>POSTs a GraphQL query and returns its "data" element. Throws <see cref="GithubException"/> with a user-facing message.</summary>
    static async Task<JsonElement> QueryAsync(string token, string query)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.github.com/graphql")
        {
            Content = new StringContent(JsonSerializer.Serialize(new { query }), Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Headers.UserAgent.ParseAdd("QNotch");
        try
        {
            using var resp = await http.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            if (resp.StatusCode == HttpStatusCode.Unauthorized) throw new GithubException("GitHub rejected the token. Check it in Settings.", false);
            if (resp.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests) throw new GithubException("GitHub refused the request (rate limit or missing permission).", false);
            if (!resp.IsSuccessStatusCode) throw new GithubException($"GitHub returned {(int)resp.StatusCode}.", false);
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.TryGetProperty("errors", out var errors) && errors.GetArrayLength() > 0)
                throw new GithubException(errors[0].TryGetProperty("message", out var m) ? m.GetString() ?? "GitHub returned an error." : "GitHub returned an error.", false);
            return root.GetProperty("data").Clone();
        }
        catch (HttpRequestException) { throw new GithubException("No connection to GitHub.", true); }
        catch (TaskCanceledException) { throw new GithubException("GitHub did not respond in time.", true); }
        catch (JsonException) { throw new GithubException("GitHub sent an unexpected response.", false); }
    }

    static GithubData? ReadCache()
    {
        try { return File.Exists(CacheFile) ? JsonSerializer.Deserialize<GithubData>(File.ReadAllText(CacheFile), CacheJson) is { Days.Count: > 0 } d ? d : null : null; }
        catch (Exception ex) { Log.Warn("GitHub cache unreadable", ex); return null; }
    }

    void WriteCache(GithubData d)
    {
        if (_ctx.Settings.ReadOnly) return;
        try
        {
            var tmp = CacheFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(d, CacheJson));
            File.Move(tmp, CacheFile, true);
        }
        catch (Exception ex) { Log.Warn("GitHub cache write failed", ex); }
    }
}
