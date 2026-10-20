namespace QNotch.Modules.Agents;

/// <summary>
/// <c>--smoke-test</c>: the real hook (<c>QNotch.exe agent</c>) sends a prompt event over this instance's pipe and the board shows the
/// session working. Only the pipe starts (the read-only run starts no listener). A prompt event plays no sound and shows no peek.
/// </summary>
public sealed partial class AgentsModule : ISmokeChecks
{
    bool _smokeListening;

    public IEnumerable<SmokeCheck> SmokeChecks(SmokeContext ctx)
    {
        yield return new("agents-hook", () => HookCheck(ctx));
    }

    async Task<string?> HookCheck(SmokeContext ctx)
    {
        if (!_smokeListening) { _smokeListening = true; _ = Task.Run(Listen); }
        var pipe = $@"\\.\pipe\{AgentWire.PipeName}";
        for (var i = 0; i < 40 && !File.Exists(pipe); i++) await Task.Delay(50);
        if (!File.Exists(pipe)) return $"the pipe {pipe} did not open";
        var id = "smoke-" + Guid.NewGuid().ToString("N")[..8];
        var cwd = Path.Combine(Path.GetTempPath(), "qnotch-smoke-project");
        var json = System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { ["hook_event_name"] = "UserPromptSubmit", ["session_id"] = id, ["cwd"] = cwd });
        var r = await ctx.RunVerb(["agent"], json);
        ctx.Log($"pipe {pipe}, hook exit {r?.Code.ToString() ?? "timeout"}, session {id}");
        if (r is not { Code: 0 }) return $"the hook exited {r?.Code.ToString() ?? "late"}";
        AgentSession? s = null;
        for (var i = 0; i < 60 && s is null; i++)
        {
            await Task.Delay(50);
            s = _st.Sessions.Find(x => x.Id == id);
        }
        if (s is null) return "the board never showed the session";
        ctx.Log($"board: {s.Name} {s.Status}, pill '{_st.PillText}'");
        var ok = s.Status == AgentStatus.Working && s.Cwd == cwd && _st.PillVisible;
        Dismiss(s);
        return ok ? null : $"the session is {s.Status} in '{s.Cwd}', pill '{_st.PillText}', expected Working in {cwd}";
    }
}
