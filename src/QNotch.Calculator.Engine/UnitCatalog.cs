using System.Text.Json;

namespace Calc.Core;

public sealed record UnitDefinition(string Id, string Symbol, Dimension Dimension, Rational Factor, Rational Offset, bool IsTemperaturePoint, string Source, string Kind = "");

/// <summary>Bounded, versioned exact definitions. Symbols preserve case; full names ignore case.</summary>
public static class UnitCatalog
{
    private static readonly Dictionary<string, UnitDefinition> symbols = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, UnitDefinition> names = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, UnitDefinition> ids = new(StringComparer.Ordinal);
    public static IReadOnlyList<UnitDefinition> Units { get; }
    static UnitCatalog()
    {
        using var stream = typeof(UnitCatalog).Assembly.GetManifestResourceStream("Calc.Units")!;
        using var document = JsonDocument.Parse(stream);
        if (document.RootElement.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Unsupported unit catalog");
        var sources = document.RootElement.GetProperty("sources"); var definitions = new List<UnitDefinition>();
        foreach (var item in document.RootElement.GetProperty("units").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!; var symbol = item.GetProperty("symbol").GetString()!;
            var dimension = Dimension.From(item.GetProperty("dimension").EnumerateArray().Select(value => value.GetInt32()).ToArray());
            var factor = ParseFactor(item.GetProperty("factor").GetString()!);
            var offset = item.TryGetProperty("offset", out var offsetValue) ? ParseFactor(offsetValue.GetString()!) : default;
            var point = item.TryGetProperty("point", out var pointValue) && pointValue.GetBoolean();
            if (id.Length is 0 or > 32 || symbol.Length is 0 or > 32 || factor.Numerator.Sign <= 0 ||
                (point && dimension != new Dimension(0,0,0,0,1,0,0,0)) || (!point && !offset.Numerator.IsZero)) throw new InvalidDataException("Invalid unit definition");
            var kind = item.TryGetProperty("kind", out var kindValue) ? kindValue.GetString()! : "";
            if (kind is not "" and not "absorbedDose" and not "equivalentDose" and not "frequency" and not "activity") throw new InvalidDataException("Invalid quantity kind");
            var definition = new UnitDefinition(id, symbol, dimension, factor, offset, point, sources.GetProperty(item.GetProperty("source").GetString()!).GetString()!, kind);
            ids.Add(id, definition); definitions.Add(definition);
            foreach (var alias in item.GetProperty("symbols").EnumerateArray()) Add(symbols, alias.GetString()!, definition);
            foreach (var alias in item.GetProperty("names").EnumerateArray()) Add(names, alias.GetString()!, definition);
        }
        if (definitions.Count > 512 || symbols.Count + names.Count > 4096) throw new InvalidDataException("Unit catalog limit exceeded");
        Units = definitions.AsReadOnly();
        static void Add(Dictionary<string, UnitDefinition> target, string key, UnitDefinition value)
        {
            if (key.Length is 0 or > 64 || key.Any(char.IsWhiteSpace)) throw new InvalidDataException("Invalid unit alias");
            if (target.TryGetValue(key, out var old) && old != value) throw new InvalidDataException("Ambiguous unit alias: " + key);
            target[key] = value;
        }
    }
    private static Rational ParseFactor(string value)
    {
        var parts = value.Split('/');
        if (parts.Length is < 1 or > 2) throw new InvalidDataException("Invalid unit factor");
        return parts.Length == 1 ? Rational.Parse(value) : Rational.Parse(parts[0]) / Rational.Parse(parts[1]);
    }
    internal static UnitDefinition ById(string id) => ids[id];
    internal static bool TryGet(string text, out UnitDefinition unit)
        => symbols.TryGetValue(text, out unit!) || names.TryGetValue(text, out unit!);
    internal static bool TryToken(string text, out UnitExpression unit)
    {
        if (RateSyntax.TrySpeedUnit(text, out unit!)) return true;
        if (TryGet(text, out var definition)) { unit = UnitExpression.Single(definition); return true; }
        if (text.Length > 1 && text[^1] is '2' or '3' or '²' or '³' && TryGet(text[..^1], out definition))
        { unit = UnitExpression.Single(definition).Power(new(text[^1] is '2' or '²' ? 2 : 3, 1)); return true; }
        unit = null!; return false;
    }
    internal static string? CanonicalToken(IReadOnlyList<Token> tokens, int index, HashSet<string> parameters)
    {
        if (tokens[index].Kind != TokenKind.Name || parameters.Contains(tokens[index].Text) || index + 1 < tokens.Count && tokens[index + 1].Text == "(") return null;
        return TryToken(tokens[index].Text, out var unit) ? "@UNIT:" + unit.Key : null;
    }
    internal static int SymbolLength(string source, int start)
    {
        if (source[start] != '°') return 0;
        return start + 1 < source.Length && source[start + 1] is 'C' or 'F' or 'R' ? 2 : 0;
    }
}
