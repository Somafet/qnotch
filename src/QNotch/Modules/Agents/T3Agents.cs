using QNotch.Theme;

namespace QNotch.Modules.Agents;

public sealed partial class AgentsModule
{
    /// <summary>Merge by native session id so enabling provider hooks never doubles the working count.</summary>
    void ApplyT3(List<T3Session> sessions, nint window)
    {
        var threads = sessions.Select(s => s.Thread).ToHashSet();
        var changed = _st.Sessions.RemoveAll(s => s.T3Thread is { } thread && !threads.Contains(thread)) > 0;
        foreach (var thread in _t3Dismissed.Keys.Where(t => !threads.Contains(t)).ToArray()) _t3Dismissed.Remove(thread);
        foreach (var t in sessions)
        {
            var s = _st.Sessions.Find(s => s.T3Thread == t.Thread) ?? _st.Sessions.Find(s => s.Id == t.Session);
            // Restore live work at startup, without importing the user's entire history of finished conversations.
            if (s is null && (t.Status == AgentStatus.Done || _t3Dismissed.GetValueOrDefault(t.Thread) == t.Run)) continue;
            var fresh = s is null;
            if (s is null) _st.Sessions.Add(s = new(t.Session));
            var was = s.Status;
            var newRun = s.T3Run != t.Run;
            changed |= fresh || newRun || s.Status != t.Status || s.Title != t.Title || s.Cwd != t.Cwd
                || s.Agent != t.Agent || s.Window != window || s.Message != t.Message || s.T3Thread is null;
            if (fresh || newRun || s.Status != t.Status)
                s.Since = t.Status == AgentStatus.NeedsYou ? DateTime.UtcNow : t.Since;
            (s.T3Thread, s.T3Run, s.T3Session) = (t.Thread, t.Run, t.Session);
            (s.Title, s.Cwd, s.Agent, s.Status, s.Message, s.Window) = (t.Title, t.Cwd, t.Agent, t.Status, t.Message, window);
            s.Link = ""; // Show brings T3 forward; provider app links would open a different application.
            s.WaitingTool = null;
            // A handoff can leave a provider hook row behind. Keep its usage/process identity when it is the same session.
            changed |= _st.Sessions.RemoveAll(other => other != s && other.Id == t.Session) > 0;
            if ((fresh || was != s.Status) && s.Status == AgentStatus.NeedsYou)
                Alert(s, "Needs you", Icon, "WarningBrush", _cfg.SoundNeedsYou ? _needsYouSound : null);
            else if (!fresh && was == AgentStatus.Working && s.Status == AgentStatus.Done)
                Alert(s, "Done", Glyphs.Accept, "SuccessBrush", _cfg.SoundDone ? _doneSound : null);
        }
        if (changed) _st.Raise();
    }
}
