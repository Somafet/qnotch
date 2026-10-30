using System.Diagnostics;
using System.Globalization;
using QNotch.Core;

namespace QNotch.Modules.Agents;

internal sealed record T3Session(string Thread, string Session, string Run, string Agent, string Title, string Cwd,
    AgentStatus Status, DateTime Since, string Message, string Link = "");

/// <summary>T3's durable run state, independent of whether its provider executes user hooks.</summary>
internal static class T3Sessions
{
    internal const string Query = """
        SELECT t.thread_id, coalesce(json_extract(p.payload_json, '$.nativeThreadRef.nativeId'), ''),
               r.run_id, coalesce(json_extract(p.payload_json, '$.nativeThreadRef.driver'), r.provider), t.title,
               coalesce(json_extract(t.payload_json, '$.worktreePath'), project.workspace_root, ''),
               r.status, coalesce(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at),
               coalesce((SELECT q.kind FROM orchestration_v2_projection_runtime_requests q
                         JOIN orchestration_v2_projection_nodes n ON n.node_id = q.node_id
                         WHERE q.thread_id = t.thread_id AND n.run_id = r.run_id AND q.status = 'pending'
                         ORDER BY q.created_at DESC LIMIT 1), '')
        FROM orchestration_v2_projection_threads t
        JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
             AND r.ordinal = (SELECT max(latest.ordinal) FROM orchestration_v2_projection_runs latest
                              WHERE latest.thread_id = t.thread_id AND latest.status <> 'queued')
        LEFT JOIN orchestration_v2_projection_provider_threads p ON p.provider_thread_id = r.provider_thread_id
        LEFT JOIN projection_projects project ON project.project_id = t.project_id
        WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
        """;

    public static List<T3Session> Read(string path)
    {
        // The first path component is T3's environment id, not its project or native provider session id.
        var environment = "";
        try { environment = File.ReadAllText(Path.Combine(Path.GetDirectoryName(path)!, "environment-id")).Trim(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* focus the app when its identity is unavailable */ }
        return T3Titles.ReadRows(path, Query).Select(row =>
        {
            var active = row[6] is "preparing" or "starting" or "running" or "waiting";
            var status = active ? row[8].Length > 0 ? AgentStatus.NeedsYou : AgentStatus.Working : AgentStatus.Done;
            var agent = row[3].StartsWith("codex", StringComparison.OrdinalIgnoreCase) ? "codex"
                : row[3].StartsWith("claude", StringComparison.OrdinalIgnoreCase) ? "claude" : row[3];
            var since = DateTime.TryParse(row[7], CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var at)
                ? at : DateTime.UtcNow;
            return new T3Session(row[0], row[1].Length > 0 ? row[1] : "t3:" + row[0], row[2], agent, row[4].Trim(), row[5], status, since,
                status != AgentStatus.NeedsYou ? "" : row[8] == "user_input" ? "T3 Code is waiting for your answer" : "T3 Code needs your permission",
                ThreadLink(environment, row[0]));
        }).ToList();
    }

    /// <summary>Only locally constructed thread links go to the Windows protocol handler.</summary>
    internal static string ThreadLink(string environment, string thread) =>
        Guid.TryParseExact(environment, "D", out _) && Guid.TryParseExact(thread, "D", out _)
            ? $"t3code://threads/{environment}/{thread}" : "";
}

/// <summary>
/// SQLite writes its WAL as well as the main file. Coalesce their notifications to at most one read per second;
/// no recurring poll and no UI-thread I/O. Watching the parent also discovers a later T3 install or database migration.
/// </summary>
internal sealed class T3SessionWatch
{
    readonly Action<List<T3Session>, nint> _changed;
    readonly Timer _timer;
    readonly object _gate = new();
    FileSystemWatcher? _watcher;
    Process? _app;
    bool _scheduled, _reading, _dirty, _failed;
    string _health = "initializing";
    public string Health => Volatile.Read(ref _health);

    public T3SessionWatch(Action<List<T3Session>, nint> changed)
    {
        _changed = changed;
        _timer = new(_ => Read());
        Schedule(0);
    }

    void Schedule(int delay = 1000)
    {
        lock (_gate)
        {
            _dirty = true;
            if (_scheduled || _reading) return;
            _scheduled = true;
            _timer.Change(delay, Timeout.Infinite);
        }
    }

    void WatchFiles()
    {
        var dir = T3Titles.DataDir;
        while (!Directory.Exists(dir)) dir = Path.GetDirectoryName(dir)!;
        if (_watcher?.Path == dir) return;
        _watcher?.Dispose();
        _watcher = new(dir, dir == T3Titles.DataDir ? "statev2.sqlite*" : "*")
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.DirectoryName,
        };
        void Changed(object sender, FileSystemEventArgs e)
        {
            // Reading SQLite can touch its shared-memory file. It contains no new session data.
            if (dir != T3Titles.DataDir || e.Name is "statev2.sqlite" or "statev2.sqlite-wal") Schedule();
        }
        _watcher.Changed += Changed;
        _watcher.Created += Changed;
        _watcher.Deleted += Changed;
        _watcher.Renamed += (sender, e) => Changed(sender, e);
        _watcher.Error += (_, _) => Schedule();
        _watcher.EnableRaisingEvents = true;
    }

    nint AppWindow()
    {
        if (_app is not null)
        {
            if (!_app.HasExited) { _app.Refresh(); return _app.MainWindowHandle; }
            _app.Dispose();
            _app = null;
        }
        foreach (var name in new[] { "T3 Code (Beta)", "T3 Code", "t3code" })
            foreach (var p in Process.GetProcessesByName(name))
            {
                try
                {
                    if (_app is null && p.MainWindowHandle != 0)
                    {
                        p.EnableRaisingEvents = true;
                        p.Exited += (_, _) => Schedule();
                        _app = p;
                    }
                }
                catch (InvalidOperationException) { /* exited during discovery */ }
                finally { if (p != _app) p.Dispose(); }
            }
        return _app?.MainWindowHandle ?? 0;
    }

    void Read()
    {
        lock (_gate) { _scheduled = false; _reading = true; _dirty = false; }
        try
        {
            WatchFiles();
            var window = AppWindow();
            var sessions = window == 0 ? [] : T3Sessions.Read(Path.Combine(T3Titles.DataDir, "statev2.sqlite"));
            Volatile.Write(ref _health, window == 0 ? "inactive" : File.Exists(Path.Combine(T3Titles.DataDir, "statev2.sqlite")) ? "ready" : "unavailable");
            _changed(sessions, window);
            _failed = false;
        }
        catch (Exception ex)
        {
            Volatile.Write(ref _health, "unavailable");
            if (!_failed) Log.Warn("Reading T3 Code sessions failed", ex);
            _failed = true;
        }
        finally
        {
            lock (_gate)
            {
                _reading = false;
                if (_dirty) { _scheduled = true; _timer.Change(1000, Timeout.Infinite); }
            }
        }
    }
}
