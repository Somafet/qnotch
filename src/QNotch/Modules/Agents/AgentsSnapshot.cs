using System.Text.Json.Serialization;
using QNotch.Core.Consumers;

namespace QNotch.Modules.Agents;

internal sealed record AgentsSnapshot(string Coverage, TrackingSnapshot Tracking, AgentSnapshot[] Sessions, SessionUsageSnapshot[] Usage);
internal sealed record TrackingSnapshot(string Hooks, string T3);
internal sealed record AgentSnapshot(string SessionId, string Provider, string Status, DateTime Since, string TrackingSource,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Title,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Project);
internal sealed record TokenSnapshot(long Tokens, double? EstimatedUsd, bool PricingComplete);
internal sealed record DayUsageSnapshot(DateOnly Day, TokenSnapshot Usage);
internal sealed record SessionUsageSnapshot(string SessionId, string Provider, string Status, string Scope, string Timezone,
    DateTime? CheckedAt, TokenSnapshot? Total, DayUsageSnapshot[] Days,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Project);

internal static class AgentsProjection
{
    public static AgentsSnapshot Capture(AgentsState state, ConsumerIdentity identity, bool details, string hooks, string t3)
    {
        if (state.Sessions.Count + state.Usage.Count > 4096 || state.Usage.Values.Sum(u => (long)u.Days.Count) > 8192)
            throw new ConsumerException("size_limit", "Too many agent records for one snapshot.");
        string Id(string id) => identity.Id("session", id);
        static string Provider(string agent) => agent is "claude" or "codex" ? agent : "unknown";
        static TokenSnapshot Tokens(Usage u) => new(u.Tokens, u.Unpriced ? null : u.Cost, !u.Unpriced);
        var sessions = state.Sessions.Select(s => new AgentSnapshot(Id(s.Id), Provider(s.Agent), s.Status switch
        {
            AgentStatus.Ready => "ready", AgentStatus.Working => "working", AgentStatus.NeedsYou => "needs_you", _ => "done",
        }, s.Since.ToUniversalTime(), s.T3Thread is null ? "hook" : "t3", details ? ConsumerProtocol.Text(s.Title) : null,
            details ? ConsumerProtocol.Text(s.Name) : null)).ToArray();
        var usage = state.Usage.Select(pair =>
        {
            var u = pair.Value;
            var ok = u.ReadComplete && u.CheckedAt is not null;
            return new SessionUsageSnapshot(Id(pair.Key), Provider(u.Agent), ok ? "ok" : "unavailable", "observed_claude_transcripts_including_subagents",
                TimeZoneInfo.Local.Id, u.CheckedAt?.ToUniversalTime(), ok ? Tokens(u.Total) : null,
                ok ? u.Days.OrderBy(d => d.Key).Select(d => new DayUsageSnapshot(d.Key, Tokens(d.Value))).ToArray() : [],
                details ? ConsumerProtocol.Text(Path.GetFileName(Path.TrimEndingDirectorySeparator(u.Cwd))) : null);
        }).ToList();
        // A live row without a transcript reading must explicitly carry unknown usage, not a fabricated zero.
        foreach (var s in state.Sessions.Where(s => !state.Usage.ContainsKey(s.Id)))
            usage.Add(new(Id(s.Id), Provider(s.Agent), s.Agent == "claude" ? "pending" : "unsupported", "observed_claude_transcripts_including_subagents",
                TimeZoneInfo.Local.Id, null, null, [], details ? ConsumerProtocol.Text(s.Name) : null));
        return new("tracked_sessions_only; usage_is_not_an_account_ledger; retained_usage_is_in_memory", new(hooks, t3), sessions, usage.ToArray());
    }
}

public sealed partial class AgentsModule
{
    ConsumerIdentity _consumerIdentity = null!;
    string _hookHealth = "initializing";
    object CaptureAgents(ConsumerRequest request) => AgentsProjection.Capture(_st, _consumerIdentity, request.Details,
        Volatile.Read(ref _hookHealth), _t3Watch?.Health ?? "initializing");
}
