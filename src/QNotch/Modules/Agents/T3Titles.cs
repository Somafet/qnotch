using System.Runtime.InteropServices;

namespace QNotch.Modules.Agents;

/// <summary>
/// Thread titles from T3 Code's database (~/.t3/userdata/statev2.sqlite, or legacy state.sqlite), keyed by the id hooks send as session_id:
/// the Claude Code session it resumes, or the Codex thread. Read through Windows' own winsqlite3, read only, so T3 keeps writing.
/// </summary>
internal static partial class T3Titles
{
    internal static readonly string DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".t3", "userdata");

    const string Query = """
        SELECT coalesce(json_extract(r.resume_cursor_json, '$.resume'), json_extract(r.resume_cursor_json, '$.threadId')), t.title
        FROM provider_session_runtime r JOIN projection_threads t USING (thread_id)
        WHERE t.deleted_at IS NULL AND t.title <> ''
        """;

    /// <summary>Session id to title; empty without T3 Code.</summary>
    public static Dictionary<string, string> Read()
    {
        var names = new Dictionary<string, string>();
        var current = Path.Combine(DataDir, "statev2.sqlite");
        var query = File.Exists(current) ? """
            SELECT json_extract(p.payload_json, '$.nativeThreadRef.nativeId'), t.title
            FROM orchestration_v2_projection_provider_threads p
            JOIN orchestration_v2_projection_threads t USING (thread_id)
            WHERE t.deleted_at IS NULL AND t.title <> ''
            """ : Query;
        var path = File.Exists(current) ? current : Path.Combine(DataDir, "state.sqlite");
        foreach (var row in ReadRows(path, query))
            if (row[0].Length > 0) names[row[0]] = row[1].Trim();
        return names;
    }

    /// <summary>One short, read-only SQLite snapshot. Never return a partial result on a busy or changed database.</summary>
    internal static List<string[]> ReadRows(string path, string query)
    {
        var rows = new List<string[]>();
        if (!File.Exists(path)) return rows;
        nint db = 0, stmt = 0;
        try
        {
            if (sqlite3_open_v2(path, out db, OpenReadOnly, null) != 0) throw new IOException($"Opening {path} failed");
            sqlite3_busy_timeout(db, 1000);
            if (sqlite3_prepare_v2(db, query, -1, out stmt, 0) != 0) throw new IOException($"T3 Code's database changed: {Marshal.PtrToStringUTF8(sqlite3_errmsg(db))}");
            int result;
            while ((result = sqlite3_step(stmt)) == Row)
            {
                var row = new string[sqlite3_column_count(stmt)];
                for (var i = 0; i < row.Length; i++) row[i] = Marshal.PtrToStringUTF8(sqlite3_column_text(stmt, i)) ?? "";
                rows.Add(row);
            }
            if (result != Done) throw new IOException($"Reading T3 Code failed: {Marshal.PtrToStringUTF8(sqlite3_errmsg(db))}");
        }
        finally
        {
            if (stmt != 0) sqlite3_finalize(stmt);
            if (db != 0) sqlite3_close_v2(db);
        }
        return rows;
    }

    const int OpenReadOnly = 1, Row = 100, Done = 101;
    const string Lib = "winsqlite3.dll";
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial int sqlite3_open_v2(string path, out nint db, int flags, string? vfs);
    [LibraryImport(Lib)] private static partial int sqlite3_busy_timeout(nint db, int ms);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial int sqlite3_prepare_v2(nint db, string sql, int bytes, out nint stmt, nint tail);
    [LibraryImport(Lib)] private static partial int sqlite3_step(nint stmt);
    [LibraryImport(Lib)] private static partial nint sqlite3_column_text(nint stmt, int column);
    [LibraryImport(Lib)] private static partial int sqlite3_column_count(nint stmt);
    [LibraryImport(Lib)] private static partial nint sqlite3_errmsg(nint db);
    [LibraryImport(Lib)] private static partial int sqlite3_finalize(nint stmt);
    [LibraryImport(Lib)] private static partial int sqlite3_close_v2(nint db);
}
