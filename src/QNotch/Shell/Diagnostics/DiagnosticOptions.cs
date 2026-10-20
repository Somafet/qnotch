namespace QNotch.Shell.Diagnostics;

public enum DiagnosticMode { None, Snapshot, SmokeTest, Measure, DebugControl }

/// <summary>
/// The shared diagnostics flags (spec/diagnostics.md): the mode and its directory, <c>--data-dir</c>, <c>--only</c> and <c>--appearance</c>
/// (the legacy positional <c>light</c> is an alias). Plain parsing: no WPF types, so <c>Program.Main</c> can use it before the app starts.
/// </summary>
public sealed record DiagnosticOptions(DiagnosticMode Mode, string? Dir, string? DataDir, IReadOnlyList<string> Only, string? Appearance)
{
    /// <summary>True for the modes that render and exit: no mutex, demo data, nothing saved.</summary>
    public bool RunsOnce => Mode is DiagnosticMode.Snapshot or DiagnosticMode.SmokeTest or DiagnosticMode.Measure;

    public static DiagnosticOptions Parse(IReadOnlyList<string> args)
    {
        var mode = DiagnosticMode.None;
        string? dir = null, dataDir = null, appearance = null;
        var only = new List<string>();
        for (var i = 0; i < args.Count; i++)
        {
            string? Next() => i + 1 < args.Count ? args[++i] : null;
            switch (args[i])
            {
                case "--snapshot": mode = DiagnosticMode.Snapshot; dir = Full(Next()); break;
                case "--smoke-test": mode = DiagnosticMode.SmokeTest; dir = Full(Next()); break;
                case "--measure": mode = DiagnosticMode.Measure; dir = Full(Next()); break;
                case "--debug-control": mode = DiagnosticMode.DebugControl; break;
                case "--data-dir": dataDir = Full(Next()); break;
                case "--only": only.AddRange((Next() ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)); break;
                case "--appearance": appearance = Next()?.ToLowerInvariant() is { } a && a is "light" or "dark" ? a : null; break;
                case "light": appearance ??= "light"; break;
            }
        }
        return new(mode, dir, dataDir, only, appearance);
    }

    /// <summary>Whether a view's file name without <c>.png</c> passes <c>--only</c> (<c>*</c> matches any run of characters).</summary>
    public bool Includes(string name) => Only.Count == 0 || Only.Any(p => Matches(p, name));

    static bool Matches(string pattern, string name)
    {
        var parts = pattern.Split('*');
        if (parts.Length == 1) return string.Equals(pattern, name, StringComparison.OrdinalIgnoreCase);
        if (!name.StartsWith(parts[0], StringComparison.OrdinalIgnoreCase) || !name.EndsWith(parts[^1], StringComparison.OrdinalIgnoreCase)) return false;
        var at = parts[0].Length;
        var end = name.Length - parts[^1].Length;
        for (var i = 1; i < parts.Length - 1; i++)
        {
            var hit = name.IndexOf(parts[i], at, StringComparison.OrdinalIgnoreCase);
            if (hit < 0 || hit + parts[i].Length > end) return false;
            at = hit + parts[i].Length;
        }
        return at <= end;
    }

    static string? Full(string? path) => path is { Length: > 0 } ? Path.GetFullPath(path) : null;
}
