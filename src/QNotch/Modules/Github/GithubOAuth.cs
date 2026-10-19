using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace QNotch.Modules.Github;

/// <summary>
/// Sign in with GitHub through the OAuth device flow (spec/onboarding.md): no backend, no client secret, no redirect. Asks only for read:user.
/// The token, device code and user code are never logged. Parsing and the polling loop are free of I/O so they can be checked offline.
/// </summary>
internal static class GithubOAuth
{
    /// <summary>The public client ID of QNotch's GitHub OAuth App (Device Flow enabled, tokens do not expire). Not a secret. Were it empty,
    /// every Sign in with GitHub button would be hidden and the token paste box shown instead (<see cref="ShowSignIn"/>).</summary>
    public const string ClientId = "Ov23liS199CVpbrlXUlC";

    /// <summary>Whether to offer Sign in with GitHub: only with a client id, or as a demo in a snapshot.</summary>
    public static bool ShowSignIn(string clientId, bool demo) => clientId.Trim().Length > 0 || demo;

    const string CodeUrl = "https://github.com/login/device/code", TokenUrl = "https://github.com/login/oauth/access_token";
    const string GrantType = "urn:ietf:params:oauth:grant-type:device_code";

    public sealed record DeviceCode(string Device, string User, string VerificationUri, int ExpiresIn, int Interval);

    public enum PollKind { Pending, SlowDown, Expired, Denied, Success, Error }

    /// <summary>One token poll answer. Interval: the wait before the next poll (seconds). Message: for Error, a line for the user.</summary>
    public readonly record struct Poll(PollKind Kind, string Token = "", int Interval = 0, string Message = "");

    /// <summary>Reads the device code response. Throws <see cref="GithubException"/> with a user-facing message.</summary>
    public static DeviceCode ParseDeviceCode(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            if (Str(r, "error") is { Length: > 0 } error)
                throw new GithubException(error == "device_flow_disabled" ? "Sign in with GitHub is turned off for this app. Use a token instead."
                    : Str(r, "error_description") is { Length: > 0 } d ? d : "GitHub refused the sign-in request.", false);
            var device = Str(r, "device_code");
            var user = Str(r, "user_code");
            var uri = Str(r, "verification_uri");
            // Only ever open GitHub's own page.
            if (device is not { Length: > 0 } || user is not { Length: > 0 } || uri is null || !uri.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
                throw new GithubException("GitHub sent an unexpected response.", false);
            return new DeviceCode(device, user, uri, Int(r, "expires_in") is > 0 and var e ? e : 900, Int(r, "interval") is > 0 and var i ? i : 5);
        }
        catch (JsonException) { throw new GithubException("GitHub sent an unexpected response.", false); }
    }

    /// <summary>Reads one access token response. <paramref name="interval"/> is the current poll interval in seconds.</summary>
    public static Poll ParsePoll(string json, int interval)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return new(PollKind.Error, Message: "GitHub sent an unexpected response.");
            if (Str(r, "access_token") is { Length: > 0 } token) return new(PollKind.Success, token, interval);
            return Str(r, "error") switch
            {
                "authorization_pending" => new(PollKind.Pending, Interval: interval),
                // GitHub adds 5 seconds and usually says the new interval: use it when it is there.
                "slow_down" => new(PollKind.SlowDown, Interval: Int(r, "interval") is > 0 and var i ? i : interval + 5),
                "expired_token" => new(PollKind.Expired, Interval: interval, Message: "The code expired."),
                "access_denied" => new(PollKind.Denied, Interval: interval, Message: "Sign-in was cancelled on GitHub."),
                _ => new(PollKind.Error, Interval: interval, Message: Str(r, "error_description") is { Length: > 0 } d ? d : "GitHub sent an unexpected response."),
            };
        }
        catch (JsonException) { return new(PollKind.Error, Interval: interval, Message: "GitHub sent an unexpected response."); }
    }

    /// <summary>
    /// Polls until the user approved, denied or the code expired. <paramref name="poll"/> returns one raw response; <paramref name="delay"/>
    /// waits (a test passes a no-op). Time is counted from the waits, so the loop needs no clock. A network error ends the loop with Error:
    /// the user retries, never a tight loop. Cancellation throws <see cref="OperationCanceledException"/>.
    /// </summary>
    public static async Task<Poll> WaitForTokenAsync(DeviceCode code, Func<CancellationToken, Task<string>> poll,
        Func<TimeSpan, CancellationToken, Task> delay, CancellationToken ct)
    {
        var interval = Math.Max(1, code.Interval);
        var waited = 0;
        while (true)
        {
            await delay(TimeSpan.FromSeconds(interval), ct);
            waited += interval;
            if (waited >= code.ExpiresIn) return new(PollKind.Expired, Interval: interval, Message: "The code expired.");
            string body;
            try { body = await poll(ct); }
            catch (HttpRequestException) { return new(PollKind.Error, Interval: interval, Message: "No connection to GitHub."); }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested) { return new(PollKind.Error, Interval: interval, Message: "GitHub did not respond in time."); }
            var r = ParsePoll(body, interval);
            if (r.Kind == PollKind.Pending) continue;
            if (r.Kind == PollKind.SlowDown) { interval = Math.Max(interval, r.Interval); continue; }
            return r;
        }
    }

    // ---------- network (only after the user clicks Sign in with GitHub) ----------

    public static HttpClient Client()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        http.DefaultRequestHeaders.UserAgent.ParseAdd("QNotch");
        return http;
    }

    public static async Task<DeviceCode> RequestCodeAsync(HttpClient http, CancellationToken ct)
    {
        try
        {
            using var resp = await http.PostAsync(CodeUrl, Form(("client_id", ClientId), ("scope", "read:user")), ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode && !body.TrimStart().StartsWith('{')) throw new GithubException($"GitHub returned {(int)resp.StatusCode}.", false);
            return ParseDeviceCode(body);
        }
        catch (HttpRequestException) { throw new GithubException("No connection to GitHub.", true); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new GithubException("GitHub did not respond in time.", true); }
    }

    public static async Task<string> PollOnceAsync(HttpClient http, DeviceCode code, CancellationToken ct)
    {
        using var resp = await http.PostAsync(TokenUrl, Form(("client_id", ClientId), ("device_code", code.Device), ("grant_type", GrantType)), ct);
        return await resp.Content.ReadAsStringAsync(ct);
    }

    static FormUrlEncodedContent Form(params (string Key, string Value)[] fields) =>
        new(fields.Select(f => new KeyValuePair<string, string>(f.Key, f.Value)));

    static string? Str(JsonElement o, string name) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static int Int(JsonElement o, string name) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : 0;
}
