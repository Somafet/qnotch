using System.Net.Http;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Modules.Github;
using QNotch.Shell.Onboarding;
using QNotch.Shell.Settings;
using static QNotch.Modules.Github.GithubOAuth;

// Welcome tour checks (spec/onboarding.md, Verification): the show/no-show decision, DisabledModules from the feature choices, what a finished
// or skipped tour writes, and the GitHub device flow against canned responses. No window, no network, no settings files.
var failures = 0;
var checks = 0;

// ---------- when it shows ----------

await Test("fresh install shows the tour", () =>
{
    Assert(FirstRun.Decide(settingsExist: false, onboardingDone: false, diagnostic: false) == TourStart.Show);
    return Task.CompletedTask;
});
await Test("existing settings without the flag mark it done silently", () =>
{
    Assert(FirstRun.Decide(settingsExist: true, onboardingDone: false, diagnostic: false) == TourStart.MarkDone);
    return Task.CompletedTask;
});
await Test("flag set: nothing", () =>
{
    Assert(FirstRun.Decide(settingsExist: true, onboardingDone: true, diagnostic: false) == TourStart.None);
    // A flag in a file is never ignored, and a missing file always wins over a stale in-memory value.
    Assert(FirstRun.Decide(settingsExist: false, onboardingDone: true, diagnostic: false) == TourStart.Show);
    return Task.CompletedTask;
});
await Test("diagnostic runs never show it", () =>
{
    foreach (var exists in new[] { false, true })
        foreach (var done in new[] { false, true })
            Assert(FirstRun.Decide(exists, done, diagnostic: true) == TourStart.None);
    return Task.CompletedTask;
});
await Test("on demand: features are read-only, first run: editable", () =>
{
    var gs = new GeneralSettings { DisabledModules = ["note"] };
    var onDemand = new TourChoices(TourMode.OnDemand, gs, Ids(), DefaultOff());
    Assert(!onDemand.FeaturesEditable);
    onDemand.SetOn("note", true);
    onDemand.SetOn("media", false);
    Assert(!onDemand.IsOn("note") && onDemand.IsOn("media"));
    onDemand.Apply(gs, TourEnd.Finished);
    Assert(gs.DisabledModules.SequenceEqual(["note"]));
    Assert(new TourChoices(TourMode.FirstRun, new GeneralSettings(), Ids(), DefaultOff()).FeaturesEditable);
    return Task.CompletedTask;
});
await Test("OnboardingDone is never in a setup code", () =>
{
    var general = SetupCode.ShellSections.Single(s => s.Id == "general");
    Assert(!general.Shared.Fields.Any(f => f.StartsWith(nameof(GeneralSettings.OnboardingDone), StringComparison.OrdinalIgnoreCase)));
    Assert(typeof(GeneralSettings).GetProperty(nameof(GeneralSettings.OnboardingDone)) is not null);
    return Task.CompletedTask;
});

// ---------- feature choices ----------

await Test("declared feature defaults apply; DisabledModules lists switched-off default-on modules in order", () =>
{
    var gs = new GeneralSettings();
    var c = new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff());
    Assert(ModuleList.All.All(m => c.IsOn(m.Id) == m.DefaultEnabled));
    c.SetOn("weather", false);
    c.SetOn("agents", false);
    c.SetOn("clipboard", false);
    c.SetOn("clipboard", true);
    c.Apply(gs, TourEnd.Finished);
    var expected = Ids().Where(id => id is "weather" or "agents").ToList();
    Assert(gs.DisabledModules.SequenceEqual(expected), string.Join(",", gs.DisabledModules));
    return Task.CompletedTask;
});
await Test("untouched features keep their defaults, also when skipped", () =>
{
    var gs = new GeneralSettings();
    new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff()).Apply(gs, TourEnd.Skipped);
    Assert(gs.DisabledModules.Count == 0);
    return Task.CompletedTask;
});
await Test("a skip keeps the features toggled so far", () =>
{
    var gs = new GeneralSettings();
    var c = new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff());
    c.SetOn("github", false);
    c.Apply(gs, TourEnd.Skipped);
    Assert(gs.DisabledModules.SequenceEqual(["github"]));
    return Task.CompletedTask;
});
await Test("ids the tour does not offer stay in DisabledModules", () =>
{
    var list = TourChoices.DisabledModules(["a", "b", "c"], new HashSet<string>(["c", "a"], StringComparer.OrdinalIgnoreCase), ["future", "B", "notegithub"]);
    Assert(list.SequenceEqual(["future", "notegithub", "a", "c"]), string.Join(",", list));
    return Task.CompletedTask;
});
await Test("every module is in exactly one Features group", () =>
{
    var grouped = ModuleList.TourGroups.SelectMany(g => g.Ids).ToList();
    Assert(grouped.Count == grouped.Distinct().Count());
    Assert(Ids().OrderBy(x => x).SequenceEqual(grouped.OrderBy(x => x)), string.Join(",", Ids().Except(grouped)));
    Assert(ModuleList.All.All(m => m.Glyph.Length > 0));
    return Task.CompletedTask;
});

// ---------- finish and skip ----------

await Test("finish applies the switches as shown", () =>
{
    var gs = new GeneralSettings();
    var c = new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff());
    Assert(c.Updates && c.StartWithWindows); // on by default in the tour
    c.SetUpdates(false);
    c.Apply(gs, TourEnd.Finished);
    Assert(!gs.CheckForUpdates && gs.UpdateChecksChoiceMade && gs.StartWithWindows && gs.OnboardingDone);
    return Task.CompletedTask;
});
await Test("skip on a first run: updates on and chosen, start at login unchanged", () =>
{
    var gs = new GeneralSettings();
    new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff()).Apply(gs, TourEnd.Skipped);
    Assert(gs.CheckForUpdates && gs.UpdateChecksChoiceMade && !gs.StartWithWindows && gs.OnboardingDone);
    return Task.CompletedTask;
});
await Test("skip keeps toggles the user already changed", () =>
{
    var gs = new GeneralSettings();
    var c = new TourChoices(TourMode.FirstRun, gs, Ids(), DefaultOff());
    c.SetUpdates(false);
    c.SetStartWithWindows(true);
    c.Apply(gs, TourEnd.Skipped);
    Assert(!gs.CheckForUpdates && gs.UpdateChecksChoiceMade && gs.StartWithWindows);
    return Task.CompletedTask;
});
await Test("on demand: a skip changes nothing but the flag", () =>
{
    var gs = new GeneralSettings { CheckForUpdates = false, UpdateChecksChoiceMade = true, StartWithWindows = true, OnboardingDone = true };
    new TourChoices(TourMode.OnDemand, gs, Ids(), DefaultOff()).Apply(gs, TourEnd.Skipped);
    Assert(!gs.CheckForUpdates && gs.StartWithWindows && gs.OnboardingDone);
    return Task.CompletedTask;
});
await Test("on demand: the finish switches start at the current values", () =>
{
    var gs = new GeneralSettings { CheckForUpdates = false, UpdateChecksChoiceMade = true, StartWithWindows = false };
    var c = new TourChoices(TourMode.OnDemand, gs, Ids(), DefaultOff());
    Assert(!c.Updates && !c.StartWithWindows);
    c.Apply(gs, TourEnd.Finished);
    Assert(!gs.CheckForUpdates && !gs.StartWithWindows);
    return Task.CompletedTask;
});

// ---------- GitHub device flow ----------

await Test("device code response", () =>
{
    var d = ParseDeviceCode("""{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}""");
    Assert(d.User == "WDJB-MJHT" && d.VerificationUri == "https://github.com/login/device" && d.ExpiresIn == 900 && d.Interval == 5);
    Throws<GithubException>(() => ParseDeviceCode("""{"error":"device_flow_disabled","error_description":"Device flow is disabled"}"""));
    Throws<GithubException>(() => ParseDeviceCode("""{"device_code":"x","user_code":"A-B","verification_uri":"https://evil.example/login/device"}"""));
    Throws<GithubException>(() => ParseDeviceCode("not json"));
    return Task.CompletedTask;
});
await Test("poll responses: pending, slow_down, expired, denied, success, unknown", () =>
{
    Assert(ParsePoll("""{"error":"authorization_pending","error_description":"..."}""", 5) is { Kind: PollKind.Pending, Interval: 5 });
    Assert(ParsePoll("""{"error":"slow_down","interval":10}""", 5) is { Kind: PollKind.SlowDown, Interval: 10 });
    Assert(ParsePoll("""{"error":"slow_down"}""", 5) is { Kind: PollKind.SlowDown, Interval: 10 });
    Assert(ParsePoll("""{"error":"expired_token"}""", 5) is { Kind: PollKind.Expired, Message: "The code expired." });
    Assert(ParsePoll("""{"error":"access_denied"}""", 5) is { Kind: PollKind.Denied, Message: "Sign-in was cancelled on GitHub." });
    Assert(ParsePoll("""{"access_token":"gho_16C7e42F292c6912E7710c838347Ae178B4a","token_type":"bearer","scope":"read:user"}""", 5) is { Kind: PollKind.Success, Token: "gho_16C7e42F292c6912E7710c838347Ae178B4a" });
    Assert(ParsePoll("""{"error":"incorrect_device_code","error_description":"The device_code provided is not valid."}""", 5) is { Kind: PollKind.Error, Message: "The device_code provided is not valid." });
    Assert(ParsePoll("<html>", 5) is { Kind: PollKind.Error });
    Assert(ParsePoll("[]", 5) is { Kind: PollKind.Error });
    return Task.CompletedTask;
});
await Test("polling waits the interval, slows down when asked, then returns the token", async () =>
{
    var (r, waits) = await Run(Code(interval: 5), ["""{"error":"authorization_pending"}""", """{"error":"slow_down","interval":10}""", """{"error":"authorization_pending"}""", """{"access_token":"gho_abc","token_type":"bearer"}"""]);
    Assert(r is { Kind: PollKind.Success, Token: "gho_abc" });
    Assert(waits.SequenceEqual([5, 5, 10, 10]), string.Join(",", waits));
});
await Test("slow_down without an interval adds 5 seconds", async () =>
{
    var (r, waits) = await Run(Code(interval: 5), ["""{"error":"slow_down"}""", """{"error":"slow_down"}""", """{"access_token":"t"}"""]);
    Assert(r.Kind == PollKind.Success && waits.SequenceEqual([5, 10, 15]), string.Join(",", waits));
});
await Test("expired_token and access_denied end the polling", async () =>
{
    var (expired, w1) = await Run(Code(), ["""{"error":"authorization_pending"}""", """{"error":"expired_token"}"""]);
    Assert(expired.Kind == PollKind.Expired && w1.Count == 2);
    var (denied, w2) = await Run(Code(), ["""{"error":"access_denied"}"""]);
    Assert(denied.Kind == PollKind.Denied && w2.Count == 1);
});
await Test("the code runs out after expires_in without another request", async () =>
{
    var (r, waits) = await Run(Code(interval: 5, expiresIn: 12), ["""{"error":"authorization_pending"}""", """{"error":"authorization_pending"}""", """{"error":"authorization_pending"}"""]);
    Assert(r.Kind == PollKind.Expired && waits.Count == 3, string.Join(",", waits));
});
await Test("a network error stops polling with a message (no tight retry loop)", async () =>
{
    var polls = 0;
    var r = await WaitForTokenAsync(Code(), _ => { polls++; throw new HttpRequestException("offline"); }, (_, _) => Task.CompletedTask, CancellationToken.None);
    Assert(r is { Kind: PollKind.Error, Message: "No connection to GitHub." } && polls == 1);
});
await Test("cancel stops polling", async () =>
{
    using var cts = new CancellationTokenSource();
    var polls = 0;
    try
    {
        await WaitForTokenAsync(Code(), _ => { polls++; cts.Cancel(); return Task.FromResult("""{"error":"authorization_pending"}"""); },
            (_, ct) => { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }, cts.Token);
        Assert(false, "expected cancellation");
    }
    catch (OperationCanceledException) { }
    Assert(polls == 1);
});
await Test("no client id: sign-in stays hidden and the token box is the way in", () =>
{
    Assert(!ShowSignIn("", demo: false));
    Assert(!ShowSignIn("  ", demo: false));
    Assert(ShowSignIn("", demo: true)); // snapshots show the sign-in UI with a made-up code
    Assert(ShowSignIn("Ov23liExample", demo: false));
    Assert(ShowSignIn(ClientId, demo: false)); // the shipped app offers it
    return Task.CompletedTask;
});

Console.WriteLine($"{checks - failures}/{checks} onboarding checks passed.");
return failures == 0 ? 0 : 1;

static List<string> Ids() => ModuleList.All.Select(m => m.Id).ToList();
static IEnumerable<string> DefaultOff() => ModuleList.All.Where(m => !m.DefaultEnabled).Select(m => m.Id);

static DeviceCode Code(int interval = 5, int expiresIn = 900) => new("dev", "WDJB-MJHT", "https://github.com/login/device", expiresIn, interval);

/// <summary>Runs the polling loop over canned responses; returns the result and every wait in seconds.</summary>
static async Task<(Poll Result, List<int> Waits)> Run(DeviceCode code, string[] responses)
{
    var waits = new List<int>();
    var i = 0;
    var r = await WaitForTokenAsync(code, _ => Task.FromResult(responses[Math.Min(i++, responses.Length - 1)]),
        (t, _) => { waits.Add((int)t.TotalSeconds); return Task.CompletedTask; }, CancellationToken.None);
    return (r, waits);
}

async Task Test(string name, Func<Task> test)
{
    checks++;
    try { await test(); Console.WriteLine("PASS " + name); }
    catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex); }
}

static void Assert(bool condition, [System.Runtime.CompilerServices.CallerArgumentExpression(nameof(condition))] string? what = null)
{
    if (!condition) throw new Exception("Assertion failed: " + what);
}

static void Throws<T>(Action a) where T : Exception
{
    try { a(); }
    catch (T) { return; }
    throw new Exception($"Expected {typeof(T).Name}");
}
