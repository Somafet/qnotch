using System.Text.Json;

namespace QNotch.Modules.Agents;

/// <summary>
/// Thread names from Codex's session_index.jsonl: one line per name ({"id","thread_name"}), newest last, so a rename is a later line.
/// Picks up where the last read stopped. Not thread safe: the module runs one read at a time, on the thread pool.
/// </summary>
internal sealed class CodexTitles
{
    readonly Dictionary<string, string> _names = [];
    long _offset;

    /// <summary>CODEX_HOME or ~/.codex, like <see cref="CodexHooks.Find"/>.</summary>
    static string Path
    {
        get
        {
            var dir = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrWhiteSpace(dir)) dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            return System.IO.Path.Combine(dir, "session_index.jsonl");
        }
    }

    /// <summary>Thread id to name, a copy the UI thread may keep.</summary>
    public Dictionary<string, string> Read()
    {
        try
        {
            using var fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (fs.Length < _offset) { _offset = 0; _names.Clear(); } // rewritten: start over
            fs.Position = _offset;
            var data = new byte[fs.Length - _offset];
            data = data[..fs.ReadAtLeast(data, data.Length, throwOnEndOfStream: false)];
            var done = 0;
            for (int nl; (nl = data.AsSpan(done).IndexOf((byte)'\n')) >= 0; done += nl + 1) Add(data.AsSpan(done, nl));
            _offset += done; // a line still being written waits for the next read
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* not there yet, or locked: try again on the next event */ }
        return new(_names);
    }

    void Add(ReadOnlySpan<byte> line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line.ToArray());
            var root = doc.RootElement;
            if (root.TryGetProperty("id", out var id) && id.GetString() is { } i && root.TryGetProperty("thread_name", out var n) && n.GetString() is { Length: > 0 } name)
                _names[i] = name.Trim();
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException) { }
    }
}
