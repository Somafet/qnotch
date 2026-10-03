using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Agents;

internal enum AgentStatus { Ready, Working, NeedsYou, Done }

/// <summary>One agent session. UI thread only.</summary>
internal sealed class AgentSession(string id)
{
    public string Id { get; } = id;
    public string Cwd { get; set; } = "";
    /// <summary>The project folder name, what the rows and the pill show.</summary>
    public string Name => Cwd.Length == 0 ? "Claude" : Path.GetFileName(Path.TrimEndingDirectorySeparator(Cwd));
    public AgentStatus Status { get; set; }
    /// <summary>What it waits for ("Claude needs your permission to use Bash"), only while it needs you.</summary>
    public string Message { get; set; } = "";
    /// <summary>When the status last changed (UTC).</summary>
    public DateTime Since { get; set; } = DateTime.UtcNow;
    /// <summary>Hook time of the newest event applied: async hooks can arrive out of order.</summary>
    public long At { get; set; }
    public nint Window { get; set; }
    public int Pid { get; set; }
    /// <summary>The tool a permission prompt or question waits on, so other tools' events leave "needs you" alone.</summary>
    public string? WaitingTool { get; set; }
}

/// <summary>What the views show. The list raises <see cref="Changed"/>; the pill binds to the observable properties.</summary>
internal sealed partial class AgentsState : ObservableObject
{
    public List<AgentSession> Sessions { get; } = [];
    public event Action? Changed;

    /// <summary>"api needs you" or "2 working", empty while nothing runs.</summary>
    [ObservableProperty] string _pillText = "";
    [ObservableProperty] bool _pillVisible;
    /// <summary>Some session needs you: the pill turns to the warning color.</summary>
    [ObservableProperty] bool _needsYou;

    public void Raise()
    {
        // Needs you first, then working, then the rest; newest change first within each.
        Sessions.Sort((a, b) => Rank(a.Status) != Rank(b.Status) ? Rank(a.Status) - Rank(b.Status) : b.Since.CompareTo(a.Since));
        var waiting = Sessions.Where(s => s.Status == AgentStatus.NeedsYou).ToList();
        var working = Sessions.Count(s => s.Status == AgentStatus.Working);
        NeedsYou = waiting.Count > 0;
        PillText = waiting.Count switch
        {
            1 => $"{waiting[0].Name} needs you",
            > 1 => $"{waiting.Count} need you",
            _ => working > 0 ? $"{working} working" : "",
        };
        PillVisible = PillText.Length > 0;
        Changed?.Invoke();
    }

    static int Rank(AgentStatus s) => s switch { AgentStatus.NeedsYou => 0, AgentStatus.Working => 1, AgentStatus.Done => 2, _ => 3 };
}

/// <summary>Settings, Agents (agents.json).</summary>
public sealed class AgentsConfig
{
    public bool SoundNeedsYou { get; set; } = true;
    public bool SoundDone { get; set; } = true;
}

/// <summary>One line from the hook (see <see cref="AgentHook"/>).</summary>
internal sealed record AgentEvent(string Agent, string Event, string Session, string Cwd, string? Message, string? Type, string? Tool, int Pid, long Hwnd, long At);

/// <summary>
/// Live Claude Code sessions: working, needs you, done. Claude Code runs <c>QNotch.exe agent</c> on each event and the hook sends one
/// line over a named pipe. Idle cost is one pending pipe accept; a session's end is an OS process-exit event, never a poll.
/// </summary>
public sealed partial class AgentsModule : INotchModule, ICadenceAware
{
    internal const string TabId = "agents", Icon = "";
    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    readonly AgentsState _st = new();
    readonly HashSet<int> _watched = [];
    readonly HashSet<string> _ended = [];
    ModuleContext _ctx = null!;
    AgentsConfig _cfg = null!;
    System.Windows.Threading.DispatcherTimer? _clock;
    CaptureWatch? _micWatch; // only while a sound is on: no sounds during calls
    bool _inCall;
    IDisposable? _peek;
    AgentSession? _peekFor;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _cfg = ctx.Settings.Get<AgentsConfig>(TabId);
        ctx.Tabs.Register(new TabDescriptor(TabId, "Agents", Icon, 35, () => new AgentsTab(this, _st), () => _st.Sessions.Count == 0));
        ctx.SettingsSections.Register(new SettingsSectionDescriptor(TabId, "Agents", Icon, 45, () => AgentsSettings.Create(this, _cfg, ctx.Settings.ReadOnly)));
        ctx.Segments.Register(new SegmentDescriptor("agents.pill", SegmentSlot.PillRight, 6, () => AgentsViews.Segment(_st)));
        ctx.Segments.Register(new SegmentDescriptor("agents.game", SegmentSlot.GameBar, 13, () => AgentsViews.Segment(_st), "Agents", "Working agents, and which one needs you."));
        ctx.Search.Register(new SearchSource(TabId, "Agents", Icon, 45, q => _st.Sessions
            .Where(s => s.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || s.Cwd.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(s => new SearchHit(s.Name, AgentsViews.Meta(s), () => ctx.Shell.SelectTab(TabId)))));

        if (ctx.Settings.ReadOnly) { Seed(); return; }
        _st.Changed += EndStalePeek;
        ApplySounds();
        Task.Run(Listen);
    }

    /// <summary>"4m ago" goes stale only while someone looks: refresh it every 30 s while the panel is open.</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Fast)
        {
            _clock ??= new(TimeSpan.FromSeconds(30), System.Windows.Threading.DispatcherPriority.Background, (_, _) => _st.Raise(), _ctx.Dispatcher);
            _clock.Start();
            _st.Raise();
        }
        else _clock?.Stop();
    }

    // ---------- commands (UI thread) ----------

    internal void Show(AgentSession s) { if (s.Window != 0) AgentNative.Focus(s.Window); }

    internal void OpenSettings() => _ctx.Shell.OpenSettings(TabId);

    internal void SaveSettings()
    {
        _ctx.Settings.Save(TabId, _cfg);
        ApplySounds();
    }

    internal void Dismiss(AgentSession s)
    {
        _st.Sessions.Remove(s);
        _st.Raise();
    }

    // ---------- events ----------

    async Task Listen()
    {
        for (var failures = 0; failures < 5;)
        {
            NamedPipeServerStream? s = null;
            try
            {
                s = new NamedPipeServerStream(AgentWire.PipeName, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await s.WaitForConnectionAsync();
                var client = s;
                s = null;
                failures = 0;
                _ = Task.Run(() => Serve(client));
            }
            catch (Exception ex)
            {
                s?.Dispose();
                failures++;
                Log.Warn("Agents pipe failed", ex);
                await Task.Delay(1000);
            }
        }
        Log.Warn("Agents pipe gave up after repeated failures");
    }

    async Task Serve(NamedPipeServerStream s)
    {
        using (s)
        {
            try
            {
                using var cts = new CancellationTokenSource(2000);
                using var reader = new StreamReader(s);
                var line = await reader.ReadLineAsync(cts.Token);
                var e = line is null ? null : JsonSerializer.Deserialize<AgentEvent>(line, Json);
                if (e is { Session.Length: > 0 }) _ctx.Bus.Run(() => Apply(e));
            }
            catch (Exception ex) when (ex is JsonException or OperationCanceledException or IOException) { /* one bad or slow client */ }
            catch (Exception ex) { Log.Warn("Agents event failed", ex); }
        }
    }

    void Apply(AgentEvent e)
    {
        var s = _st.Sessions.Find(x => x.Id == e.Session);
        if (e.Event == "SessionEnd")
        {
            _ended.Add(e.Session); // async hooks race: a Stop that lands after SessionEnd must not bring the row back
            if (_ended.Count > 100) _ended.Clear();
            if (s is not null) Dismiss(s);
            return;
        }
        if (e.Event == "SessionStart") _ended.Remove(e.Session); // a resumed session keeps its id
        else if (_ended.Contains(e.Session)) return;
        if (s is null) _st.Sessions.Add(s = new AgentSession(e.Session));
        else if (e.At < s.At) return;
        s.At = e.At;
        if (e.Cwd.Length > 0) s.Cwd = e.Cwd;
        if (e.Hwnd != 0) s.Window = (nint)e.Hwnd;
        if (e.Pid > 0 && s.Pid != e.Pid) { s.Pid = e.Pid; Watch(e.Pid); }

        // While it waits for you, tool events of other tools (subagents share the session id) must not clear the wait:
        // only the tool it asked about, a new prompt or the end of the turn do.
        var waiting = s.Status == AgentStatus.NeedsYou && s.WaitingTool is { } wt && e.Tool is { } tool && tool != wt;
        AgentStatus? status = e.Event switch
        {
            "SessionStart" => AgentStatus.Ready, // new, resumed or cleared
            "UserPromptSubmit" => AgentStatus.Working,
            "PostToolUse" => waiting ? null : AgentStatus.Working,
            "PreToolUse" => e.Tool == "AskUserQuestion" ? AgentStatus.NeedsYou : waiting ? null : AgentStatus.Working,
            "Notification" => e.Type switch
            {
                "permission_prompt" or "elicitation_dialog" => AgentStatus.NeedsYou,
                null when e.Message?.Contains("permission", StringComparison.OrdinalIgnoreCase) == true => AgentStatus.NeedsYou, // older versions send no type
                // Waiting for input with no Stop before it: the turn was interrupted (Esc), so it is no longer working.
                "idle_prompt" when s.Status == AgentStatus.Working => AgentStatus.Done,
                _ => null,
            },
            "Stop" => AgentStatus.Done,
            _ => null,
        };
        var was = s.Status;
        if (status is { } st)
        {
            if (st != s.Status) s.Since = DateTime.UtcNow;
            s.Status = st;
            s.Message = st == AgentStatus.NeedsYou ? e.Message ?? "Waiting for you" : "";
            s.WaitingTool = st != AgentStatus.NeedsYou ? null
                : e.Event == "PreToolUse" ? e.Tool
                : PermissionTool().Match(s.Message) is { Success: true } m ? m.Groups[1].Value : null;
        }
        _st.Raise();
        if (s.Status == was) return;
        if (s.Status == AgentStatus.NeedsYou) Alert(s, "Needs you", Icon, "WarningBrush", _cfg.SoundNeedsYou ? "Notification.IM" : null);
        // Only a finished turn: Done after an interrupt (Esc) is something the user just did themselves.
        else if (s.Status == AgentStatus.Done && e.Event == "Stop" && was == AgentStatus.Working)
            Alert(s, "Done", Glyphs.Accept, "SuccessBrush", _cfg.SoundDone ? "Notification.Default" : null);
    }

    // ---------- alerts ----------

    /// <summary>Widens the pill for a moment ("api: Needs you") and plays the sound, unless in game mode (Peek returns null) or a call.</summary>
    void Alert(AgentSession s, string what, string glyph, string brush, string? sound)
    {
        _peek?.Dispose();
        _peek = _ctx.Shell.Peek(glyph, $"{s.Name}: {what}", brush);
        _peekFor = s.Status == AgentStatus.NeedsYou ? s : null;
        if (_peek is not null && sound is not null && !_inCall) AgentNative.PlaySound(sound);
    }

    /// <summary>Answered in the terminal (or gone): the peek about it goes at once instead of lingering.</summary>
    void EndStalePeek()
    {
        if (_peekFor is not { } p || (p.Status == AgentStatus.NeedsYou && _st.Sessions.Contains(p))) return;
        _peek?.Dispose();
        _peek = null;
        _peekFor = null;
    }

    /// <summary>Watches the microphone while any sound is on, so sounds stay quiet during calls.</summary>
    void ApplySounds()
    {
        if (_cfg.SoundNeedsYou || _cfg.SoundDone)
        {
            if (_micWatch is not null) return;
            CaptureWatch w = null!;
            w = _micWatch = new CaptureWatch(CaptureWatch.Microphone, apps => _ctx.Bus.Run(() => { if (_micWatch == w) _inCall = apps.Count > 0; }));
        }
        else
        {
            _micWatch?.Dispose();
            _micWatch = null;
            _inCall = false;
        }
    }

    /// <summary>"Claude needs your permission to use Bash" names the tool it waits on.</summary>
    [System.Text.RegularExpressions.GeneratedRegex(@"permission to use (\S+)$")]
    private static partial System.Text.RegularExpressions.Regex PermissionTool();

    /// <summary>Drops every session of a process when it exits, for terminals closed without a SessionEnd.</summary>
    void Watch(int pid)
    {
        if (!_watched.Add(pid)) return;
        Task.Run(() =>
        {
            Process p;
            try { p = Process.GetProcessById(pid); }
            catch (ArgumentException) { _ctx.Bus.Run(() => Ended(pid)); return; } // already gone
            try
            {
                p.EnableRaisingEvents = true;
                p.Exited += (_, _) => { p.Dispose(); _ctx.Bus.Run(() => Ended(pid)); };
                if (p.HasExited) _ctx.Bus.Run(() => Ended(pid));
            }
            catch (Exception ex)
            {
                // An elevated agent cannot be watched from here: keep its rows, they still go on SessionEnd or Clear.
                p.Dispose();
                Log.Warn($"Cannot watch agent process {pid}", ex);
            }
        });
    }

    void Ended(int pid)
    {
        _watched.Remove(pid);
        if (_st.Sessions.RemoveAll(s => s.Pid == pid) > 0) _st.Raise();
    }

    void Seed()
    {
        var now = DateTime.UtcNow;
        _st.Sessions.AddRange(
        [
            new("1") { Cwd = @"C:\code\api", Status = AgentStatus.NeedsYou, Message = "Claude needs your permission to use Bash", Since = now.AddMinutes(-1), Window = 1 },
            new("2") { Cwd = @"C:\code\web", Status = AgentStatus.Working, Since = now.AddMinutes(-6), Window = 1 },
            new("3") { Cwd = @"C:\code\ledge", Status = AgentStatus.Done, Since = now.AddMinutes(-12), Window = 1 },
        ]);
        _st.Raise();
    }
}
