using System.Globalization;
using System.Text.Json;

namespace Calc.Core;

public sealed record CurrencyDefinition(string Code, string Name, int Digits, string Kind, IReadOnlyList<string> Aliases);

public static class CurrencyCatalog
{
    private static readonly Dictionary<string,CurrencyDefinition> codes = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string,CurrencyDefinition> aliases = new(StringComparer.OrdinalIgnoreCase);
    private static readonly string[] symbols;
    public static IReadOnlyList<CurrencyDefinition> Definitions { get; }
    public const string Version = "2026-10-31";
    static CurrencyCatalog()
    {
        using var stream = typeof(CurrencyCatalog).Assembly.GetManifestResourceStream("Calc.Currencies")!;
        using var json = JsonDocument.Parse(stream);
        var values = new List<CurrencyDefinition>();
        foreach (var item in json.RootElement.GetProperty("currencies").EnumerateArray())
        {
            var code = item.GetProperty("code").GetString()!; var name = item.GetProperty("name").GetString()!;
            var digits = item.GetProperty("digits").GetInt32(); var kind = item.GetProperty("kind").GetString()!;
            var names = item.GetProperty("aliases").EnumerateArray().Select(value => value.GetString()!).ToArray();
            if (!ValidCode(code) || name.Length is < 1 or > 256 || digits is < 0 or > 8 || names.Length > 16 || names.Any(value => value.Length is < 1 or > 64) || values.Count >= 512)
                throw new InvalidDataException("Invalid currency catalog");
            var definition = new CurrencyDefinition(code, name, digits, kind, Array.AsReadOnly(names));
            codes.Add(code, definition); aliases.Add(code, definition);
            foreach (var alias in names) aliases.Add(alias, definition);
            values.Add(definition);
        }
        Definitions = values.AsReadOnly();
        symbols = aliases.Keys.Where(value => value.Any(character => char.GetUnicodeCategory(character) == UnicodeCategory.CurrencySymbol))
            .Append("¥").Append("￥").OrderByDescending(value => value.Length).ToArray();
    }
    public static bool ValidCode(string? value) => value is { Length:3 } && value.All(character => character is >= 'A' and <= 'Z');
    public static bool TryCode(string value, out CurrencyDefinition currency) => codes.TryGetValue(value, out currency!);
    public static CurrencyDefinition ByCode(string value) => TryCode(value, out var currency) ? currency : throw new ArithmeticException("Unknown currency code");
    internal static int SymbolLength(string text, int position)
    {
        foreach (var symbol in symbols)
            if (text.AsSpan(position).StartsWith(symbol, StringComparison.Ordinal)) return symbol.Length;
        return 0;
    }
    internal static bool TryMatch(IReadOnlyList<Token> tokens, int position, out CurrencyDefinition currency, out int length)
    {
        currency = null!; length = 0;
        if (position >= tokens.Count || tokens[position].Kind is not TokenKind.Name and not TokenKind.Currency) return false;
        if (tokens[position].Text is "¥" or "￥") throw new FormatException("Ambiguous currency symbol; use JPY or CNY");
        for (var count = Math.Min(3, tokens.Count - position); count > 0; count--)
        {
            if (tokens.Skip(position).Take(count).Any(token => token.Kind is not TokenKind.Name and not TokenKind.Currency)) continue;
            var name = string.Join(' ',tokens.Skip(position).Take(count).Select(token => token.Text));
            if (!aliases.TryGetValue(name, out currency!)) continue;
            // Preserve existing physical cup syntax; explicit uppercase CUP means Cuban peso.
            if (count == 1 && name != currency.Code && UnitCatalog.TryToken(name, out _)) continue;
            length = count; return true;
        }
        return false;
    }
}
