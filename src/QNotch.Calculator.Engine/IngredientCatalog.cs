using System.Text.Json;

namespace Calc.Core;

/// <summary>Grams per US customary cup of one ingredient, with the source of that number. An estimate for the ingredient as commonly measured, not a property of a sample.</summary>
public sealed record IngredientDefinition(string Id, Rational GramsPerCup, string Source, string Note, IReadOnlyList<string> Names);

/// <summary>Pinned, bounded ingredient densities (<c>Ingredients.json</c>, rebuilt by <c>tools/build-ingredient-catalog.py</c> from a retained USDA extract).</summary>
public static class IngredientCatalog
{
    public const int MaxWords = 4;
    private static readonly Dictionary<string, IngredientDefinition> names = new(StringComparer.Ordinal);
    public static IReadOnlyList<IngredientDefinition> Ingredients { get; }
    public static string Basis { get; }
    public static string Dataset { get; }
    static IngredientCatalog()
    {
        using var stream = typeof(IngredientCatalog).Assembly.GetManifestResourceStream("Calc.Ingredients")!;
        using var document = JsonDocument.Parse(stream); var root = document.RootElement;
        if (root.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Unsupported ingredient catalog");
        Basis = root.GetProperty("basis").GetString()!;
        var dataset = root.GetProperty("dataset"); Dataset = dataset.GetProperty("name").GetString() + " (" + dataset.GetProperty("file").GetString() + ")";
        var list = new List<IngredientDefinition>();
        foreach (var item in root.GetProperty("ingredients").EnumerateArray())
        {
            var aliases = item.GetProperty("names").EnumerateArray().Select(name => name.GetString()!).ToArray();
            var definition = new IngredientDefinition(item.GetProperty("id").GetString()!, Rational.Parse(item.GetProperty("gramsPerCup").GetString()!), item.GetProperty("source").GetString()!,
                item.TryGetProperty("note", out var note) ? note.GetString()! : "", Array.AsReadOnly(aliases));
            if (definition.Source.Length == 0 || definition.GramsPerCup.Numerator.Sign <= 0 || definition.GramsPerCup.Above(new Rational(1000, 1)) || aliases.Length == 0) throw new InvalidDataException("Invalid ingredient definition");
            foreach (var alias in aliases)
            {
                if (alias.Length is 0 or > 64 || alias != alias.ToLowerInvariant() || alias.Split(' ').Length > MaxWords || !names.TryAdd(alias, definition)) throw new InvalidDataException("Invalid ingredient name: " + alias);
            }
            list.Add(definition);
        }
        if (list.Count is 0 or > 128) throw new InvalidDataException("Ingredient catalog limit exceeded");
        Ingredients = list.AsReadOnly();
    }
    public static bool TryGet(string name, out IngredientDefinition definition) => names.TryGetValue(string.Join(' ', name.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)), out definition!);
    /// <summary>The longest ingredient name starting at <paramref name="start"/>; a hyphen between words reads as a space.</summary>
    internal static bool TryMatch(IReadOnlyList<Token> tokens, int start, out IngredientDefinition? definition, out int length)
    {
        definition = null; length = 0;
        var words = new List<string>(); var ends = new List<int>();
        for (var index = start; index < tokens.Count && words.Count < MaxWords; index++)
        {
            if (tokens[index].Text == "-" && words.Count > 0 && index + 1 < tokens.Count && tokens[index + 1].Kind == TokenKind.Name) continue;
            if (tokens[index].Kind != TokenKind.Name) break;
            words.Add(tokens[index].Text.ToLowerInvariant()); ends.Add(index + 1 - start);
        }
        for (var count = words.Count; count > 0; count--)
            if (names.TryGetValue(string.Join(' ', words.Take(count)), out definition)) { length = ends[count - 1]; return true; }
        return false;
    }
}
