using System.Text.Json;
using NodaTime;

namespace Calc.Core;

internal static class ZoneCatalog
{
    private static readonly HashSet<string> ids;
    private static readonly Dictionary<string, string> aliases;
    internal static readonly string ManifestVersion;
    static ZoneCatalog()
    {
        using var stream = typeof(ZoneCatalog).Assembly.GetManifestResourceStream("Calc.TimeZones")!;
        using var document = JsonDocument.Parse(stream); var root = document.RootElement;
        ManifestVersion = root.GetProperty("version").GetString()!;
        ids = root.GetProperty("ids").EnumerateArray().Select(item => item.GetString()!).ToHashSet(StringComparer.Ordinal);
        aliases = root.GetProperty("aliases").EnumerateObject().ToDictionary(item => item.Name, item => item.Value.GetString()!, StringComparer.OrdinalIgnoreCase);
        if (ids.Count > 1024 || aliases.Count > 1024 || aliases.Any(pair => !ids.Contains(pair.Value))) throw new InvalidDataException("Invalid time-zone manifest");
    }
    internal static int IdLength(string text, int start)
    {
        var end = start;
        while (end < text.Length && end - start < 128 && (char.IsAsciiLetterOrDigit(text[end]) || text[end] is '/' or '_' or '-' or '+')) end++;
        for (var cursor = end; cursor > start; cursor--)
            if ((cursor == text.Length || !(char.IsAsciiLetterOrDigit(text[cursor]) || text[cursor] is '/' or '_')) &&
                text.AsSpan(start, cursor - start).IndexOfAny('/', '-', '+') >= 0 && ids.Contains(text[start..cursor])) return cursor - start;
        return 0;
    }
    internal static bool TryAlias(string name, out string id)
    {
        if (name.Equals("local", StringComparison.OrdinalIgnoreCase)) { id = "@LOCAL"; return true; }
        if (name.Equals("UTC", StringComparison.OrdinalIgnoreCase) || name.Equals("GMT", StringComparison.OrdinalIgnoreCase) || name == "Z") { id = "UTC"; return true; }
        if (aliases.TryGetValue(name, out id!)) return true;
        if (ids.Contains(name)) { id = name; return true; }
        return false;
    }
    internal static DateTimeZone Resolve(string id, EvaluationContext context, ContextReads reads, out string version)
    {
        if (id == "@LOCAL") { var local = context.RequireLocalZone(reads); version = local.Version; return local.Rules; }
        if (id == "UTC") { version = "fixed offset"; return DateTimeZone.Utc; }
        if (id.StartsWith("UTC", StringComparison.Ordinal) && id.Length > 3)
        {
            var parts = id[4..].Split(':');
            if (id[3] is not '+' and not '-' || parts.Length is < 2 or > 3 || parts.Any(part => part.Length != 2 || !part.All(char.IsAsciiDigit)))
                throw new FormatException("UTC offset requires ±HH:mm[:ss]");
            var h = int.Parse(parts[0]); var m = int.Parse(parts[1]); var s = parts.Length == 3 ? int.Parse(parts[2]) : 0;
            if (h > 18 || m > 59 || s > 59 || h == 18 && (m != 0 || s != 0)) throw new ArithmeticException("UTC offset must be within ±18:00");
            version = "fixed offset"; return DateTimeZone.ForOffset(Offset.FromSeconds((h * 3600 + m * 60 + s) * (id[3] == '-' ? -1 : 1)));
        }
        reads.Dependencies |= ContextDependency.ZoneRules;
        version = context.Zones.VersionId;
        return context.Zones.GetZoneOrNull(id) ?? throw new ArithmeticException("Time-zone rules unavailable: " + id);
    }
}
