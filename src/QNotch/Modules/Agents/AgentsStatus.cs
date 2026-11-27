using QNotch.Core;

namespace QNotch.Modules.Agents;

/// <summary>
/// What a connected hook file says. Writing the hooks is not the end: Codex runs a new or changed hook only once the user trusts it, and Claude
/// Code sessions that were already open never read the file again. So a connection is waiting until an event of its kind has arrived.
/// Pure text and brush choices, so they are testable without WPF.
/// </summary>
internal static class AgentsStatus
{
    public static string Receiving => L.T("Connected. Receiving events.");

    /// <summary>The analytics target of an agent kind (the fixed catalog), null for anything else.</summary>
    public static string? Target(string? kind) => kind switch { "claude" => "agents_claude", "codex" => "agents_codex", _ => null };

    static string Rest(string kind) => kind == "codex"
        ? L.T("Codex runs them once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app.")
        : L.T("Waiting for the first event: start a new Claude Code session.");

    /// <summary>What the empty tab says each waiting kind needs: the hooks are added, so this is what is left to do.</summary>
    static string Next(string kind) => kind == "codex" ? L.T("Trust the hooks in Codex: /hooks in the CLI, or Settings, Hooks in the Codex app.") : L.T("Start a new Claude Code session.");

    /// <summary>What a connected hook file says while no event of these kinds has arrived since it was connected.</summary>
    public static string Waiting(IEnumerable<string> kinds) => L.T("Hooks added.") + " " + string.Join(" ", kinds.Select(Rest));

    /// <summary>What a connected hook file says, and in which brush.</summary>
    public static (string Text, string Brush) Connected(string kind, bool seen) => seen ? (Receiving, "SuccessBrush") : (Waiting([kind]), "WarningBrush");

    /// <summary>The Agents tab's placeholder when no session shows. <paramref name="connected"/> is each connected hook file's kind and whether an event arrived.</summary>
    public static (string Title, string Detail) Empty(IReadOnlyCollection<(string Kind, bool Seen)> connected)
    {
        if (connected.Count == 0)
            return (L.T("No agents running"), L.T("T3 Code sessions appear automatically. For Claude Code and Codex outside T3, connect them in Settings, Agents, then start a session."));
        if (connected.Any(c => c.Seen)) return (L.T("No agents running"), L.T("Sessions appear here when Claude Code or Codex is working. T3 Code sessions appear automatically."));
        var kinds = connected.Select(c => c.Kind).Distinct().Order().ToList();
        return (L.T("Waiting for the first event"), string.Join(" ", kinds.Select(Next)));
    }
}
