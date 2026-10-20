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
}
