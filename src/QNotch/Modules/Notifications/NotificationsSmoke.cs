using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace QNotch.Modules.Notifications;

/// <summary>
/// <c>--smoke-test</c>: the real <c>QNotch.exe notify --wait</c> against this instance's pipe, answered through the module as a click would,
/// and one raw pipe request. Only the pipe starts (the read-only run starts no servers); never the HTTP endpoint or its token.
/// </summary>
public sealed partial class NotificationsModule : ISmokeChecks
{
    const string SmokeApp = "QNotch smoke";

    public IEnumerable<SmokeCheck> SmokeChecks(SmokeContext ctx)
    {
        yield return new("notify-cli", () => NotifyCli(ctx));
        yield return new("notify-transport", () => NotifyTransport(ctx));
        yield return new("notify-manual-mute", () => ManualMute(ctx));
    }

    async Task<bool> EnsurePipe()
    {
        if (_server is null)
        {
            _server = new NotifyServer(HandleAsync, () => "", s => _ctx.Bus.Run(() => _st.PipeStatus = s), _ => { });
            _server.StartPipe();
        }
        for (var i = 0; i < 40 && !File.Exists($@"\\.\pipe\{Wire.PipeName}"); i++) await Task.Delay(50);
        return File.Exists($@"\\.\pipe\{Wire.PipeName}");
    }

    async Task<string?> NotifyCli(SmokeContext ctx)
    {
        if (!await EnsurePipe()) return $@"the pipe \\.\pipe\{Wire.PipeName} did not open";
        ctx.Log($@"pipe \\.\pipe\{Wire.PipeName}");
        var run = ctx.RunVerb(["notify", "--title", "Smoke test", "--body", "Answer from the smoke test", "--app", SmokeApp, "--id", "smoke-cli",
            "--action", "approve=Approve", "--action", "deny=Deny", "--timeout", "20"], timeoutMs: 25000);
        Note? note = null;
        for (var i = 0; i < 100 && note is null && !run.IsCompleted; i++)
        {
            await Task.Delay(50);
            note = _st.Items.FirstOrDefault(n => n.Id == "smoke-cli" && n.Pending);
        }
        if (note is null)
        {
            var early = await run;
            return $"no waiting notification arrived (notify exited {early?.Code.ToString() ?? "late"}: {early?.Err.Trim()})";
        }
        ctx.Log($"posted: {note.Title}, actions {string.Join(", ", note.Actions.Select(a => a.Id))}, toast {(_st.Toast == note ? "shown" : "not shown")}");
        if (note.Actions.FirstOrDefault(a => a.Id == "approve") is not { } approve) return "the notification has no approve action";
        Invoke(approve); // what the toast's button does
        var r = await run;
        Dismiss(note);
        if (r is not { } done) return "notify --wait did not return after the answer";
        ctx.Log($"notify exit {done.Code}, stdout '{done.Out.Trim()}', stderr '{done.Err.Trim()}'");
        if (done.Code != 0) return $"notify exited {done.Code}, expected 0";
        return done.Out.Trim() == "approve" ? null : $"notify printed '{done.Out.Trim()}', expected 'approve'";
    }

    async Task<string?> NotifyTransport(SmokeContext ctx)
    {
        if (!await EnsurePipe()) return $@"the pipe \\.\pipe\{Wire.PipeName} did not open";
        async Task<JsonElement> Send(string json)
        {
            using var pipe = new NamedPipeClientStream(".", Wire.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(2000);
            await pipe.WriteAsync(Encoding.UTF8.GetBytes(json + "\n"));
            using var reader = new StreamReader(pipe, Encoding.UTF8);
            using var cts = new CancellationTokenSource(5000);
            var line = await reader.ReadLineAsync(cts.Token) ?? "";
            ctx.Log($"-> {json}\n<- {line}");
            using var doc = JsonDocument.Parse(line);
            return doc.RootElement.Clone();
        }
        var posted = await Send($$"""{"title":"Smoke transport","app":"{{SmokeApp}}","id":"smoke-pipe","ttl":0}""");
        if (!posted.TryGetProperty("ok", out var ok) || !ok.GetBoolean() || posted.GetProperty("id").GetString() != "smoke-pipe") return "the pipe did not accept the notification";
        for (var i = 0; i < 40 && _st.Items.All(n => n.Id != "smoke-pipe"); i++) await Task.Delay(50);
        if (_st.Items.All(n => n.Id != "smoke-pipe")) return "the accepted notification never reached the history";
        var gone = await Send("""{"op":"dismiss","id":"smoke-pipe"}""");
        if (!gone.TryGetProperty("ok", out var ok2) || !ok2.GetBoolean()) return "the pipe did not accept the dismiss";
        for (var i = 0; i < 40 && _st.Items.Any(n => n.Id == "smoke-pipe"); i++) await Task.Delay(50);
        return _st.Items.Any(n => n.Id == "smoke-pipe") ? "the dismissed notification stayed in the history" : null;
    }

    async Task<string?> ManualMute(SmokeContext ctx)
    {
        var wasMuted = _st.Muted;
        var sound = _cfg.Sound;
        var notes = new List<Note>();
        Note Add(string id, bool pending = false)
        {
            var n = new Note { Id = "mute-" + id, App = "Mute test " + id, Title = id, Level = NoteLevel.Error, Pending = pending };
            if (pending)
            {
                n.Waiter = new(TaskCreationOptions.RunContinuationsAsynchronously);
                n.Actions = [new NoteAction { Owner = n, Id = "yes", Label = "Yes" }];
            }
            notes.Add(n);
            Post(n, 10);
            return n;
        }
        _ctx.Shell.ClosePanel();
        SetCadence(Cadence.Slow);
        try
        {
            _cfg.Sound = false;
            SetMuted(false);
            var existing = Add("existing", pending: true);
            var waiter = existing.Waiter!;
            if (_st.Toast is null) return "fixture did not create a waiting toast";
            var button = (System.Windows.Controls.Primitives.ToggleButton)NotificationMuteViews.Button(this, _st, compact: true);
            var settings = (System.Windows.Controls.CheckBox)NotificationMuteViews.Button(this, _st);
            var settingsPeer = new System.Windows.Automation.Peers.CheckBoxAutomationPeer(settings);
            var settingsToggle = (System.Windows.Automation.Provider.IToggleProvider)settingsPeer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Toggle);
            var peer = new System.Windows.Automation.Peers.ToggleButtonAutomationPeer(button);
            ((System.Windows.Automation.Provider.IToggleProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Toggle)).Toggle();
            if (!_st.Muted || _st.Toast is not null || _transient is not null || _toastTimer?.IsEnabled == true) return "accessible mute did not clear alerts";
            if (settingsToggle.ToggleState != System.Windows.Automation.ToggleState.On) return "quick mute did not update Settings";
            settingsToggle.Toggle();
            if (_st.Muted || button.IsChecked == true || _st.Toast is not null) return "Settings unmute did not synchronize or replayed an alert";
            settingsToggle.Toggle();
            if (!_st.Muted || button.IsChecked != true) return "Settings mute did not synchronize the quick toggle";
            if (waiter.Task.IsCompleted || !existing.Pending || existing.Read) return "mute changed the existing wait/read state";
            _ctx.Shell.ClosePanel();
            SetCadence(Cadence.Slow);
            _cfg.Sound = true; // suppressed path must return before Toast and sound playback
            var transient = Add("error");
            var pending = Add("pending", pending: true);
            var reply = pending.Waiter!;
            if (_st.Toast is not null || _fast || transient.Read || pending.Read) return "muted error/pending notification alerted or was silently read";
            if (!pending.Pending || reply.Task.IsCompleted || !_st.Items.Contains(transient)) return "muted history/wait semantics lost";
            if (await NotifyCli(ctx) is { } cliError) return "muted CLI: " + cliError;
            if (await NotifyTransport(ctx) is { } transportError) return "muted transport: " + transportError;
            if (_st.Toast is not null) return "muted CLI/pipe notification showed a toast";
            foreach (var ended in new[] { false, true })
            {
                var req = new NotifyRequest { Id = "mute-lifecycle-" + ended, Title = "Lifecycle", App = "Mute lifecycle", Wait = true, Timeout = .1 };
                var gone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                if (ended) gone.SetResult();
                var response = await HandleAsync(req, () => gone.Task);
                await Task.Delay(50);
                if (!response.Json.Contains("timeout", StringComparison.Ordinal) || Find(req.Id) is not { Pending: false } expired)
                    return "muted timeout/disconnect lifecycle changed";
                notes.Add(expired);
            }
            SetMuted(false);
            if (_st.Toast is not null) return "unmute replayed an old alert";
            Invoke(pending.Actions[0]);
            var result = await reply.Task;
            if (result.Result != "clicked" || result.Action != "yes") return "muted-period answer was not delivered";
            Dismiss(existing);
            if ((await waiter.Task).Result != "dismissed") return "existing waiter dismissal changed";
            SetCall(["Smoke call"]);
            var call = Add("call", pending: true);
            if (_st.Toast != call) return "manual mute changed the pending exception during calls";
            SetMuted(true);
            if (_st.Toast is not null || !call.Pending) return "mute failed to suppress pending call toast";
            ctx.Log("Accessible quick toggle, existing/waiting peek cancellation, muted unread error/history, no replay, answer/dismiss replies and quiet-call pending exception passed.");
            return null;
        }
        finally
        {
            _cfg.Sound = sound;
            foreach (var n in notes) Dismiss(n);
            SetCall([]);
            SetMuted(wasMuted);
        }
    }
}
