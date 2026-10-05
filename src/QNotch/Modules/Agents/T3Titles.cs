using System.Runtime.InteropServices;

namespace QNotch.Modules.Agents;

/// <summary>
/// Thread titles from T3 Code's database (~/.t3/userdata/state.sqlite), keyed by the id the hooks send as session_id:
/// the Claude Code session it resumes, or the Codex thread. Read through Windows' own winsqlite3, read only, so T3 keeps writing.
/// </summary>
internal static partial class T3Titles
{
    static readonly string DbPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".t3", "userdata", "state.sqlite");

    const string Query = """
        SELECT coalesce(json_extract(r.resume_cursor_json, '$.resume'), json_extract(r.resume_cursor_json, '$.threadId')), t.title
        FROM provider_session_runtime r JOIN projection_threads t USING (thread_id)
        WHERE t.deleted_at IS NULL AND t.title <> ''
        """;

    /// <summary>Session id to title; empty without T3 Code.</summary>
    public static Dictionary<string, string> Read()
    {
        var names = new Dictionary<string, string>();
        if (!File.Exists(DbPath)) return names;
        nint db = 0, stmt = 0;
        try
        {
            if (sqlite3_open_v2(DbPath, out db, OpenReadOnly, null) != 0) throw new IOException($"Opening {DbPath} failed");
            sqlite3_busy_timeout(db, 1000);
            if (sqlite3_prepare_v2(db, Query, -1, out stmt, 0) != 0) throw new IOException($"T3 Code's database changed: {Marshal.PtrToStringUTF8(sqlite3_errmsg(db))}");
            while (sqlite3_step(stmt) == Row)
                if (Marshal.PtrToStringUTF8(sqlite3_column_text(stmt, 0)) is { Length: > 0 } id && Marshal.PtrToStringUTF8(sqlite3_column_text(stmt, 1)) is { } title)
                    names[id] = title.Trim();
        }
        finally
        {
            if (stmt != 0) sqlite3_finalize(stmt);
            if (db != 0) sqlite3_close_v2(db);
        }
        return names;
    }

    const int OpenReadOnly = 1, Row = 100;
    const string Lib = "winsqlite3.dll";
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial int sqlite3_open_v2(string path, out nint db, int flags, string? vfs);
    [LibraryImport(Lib)] private static partial int sqlite3_busy_timeout(nint db, int ms);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial int sqlite3_prepare_v2(nint db, string sql, int bytes, out nint stmt, nint tail);
    [LibraryImport(Lib)] private static partial int sqlite3_step(nint stmt);
    [LibraryImport(Lib)] private static partial nint sqlite3_column_text(nint stmt, int column);
    [LibraryImport(Lib)] private static partial nint sqlite3_errmsg(nint db);
    [LibraryImport(Lib)] private static partial int sqlite3_finalize(nint stmt);
    [LibraryImport(Lib)] private static partial int sqlite3_close_v2(nint db);
}
