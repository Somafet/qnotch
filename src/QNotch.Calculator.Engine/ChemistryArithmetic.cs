using System.Collections.ObjectModel;
using System.Text.Json;

namespace Calc.Core;

public sealed record AtomicWeight(int AtomicNumber, string Symbol, string Name, Rational? Weight, Rational? QuotedUncertainty, string Notes);
public static class AtomicWeightCatalog
{
    private static readonly Dictionary<string, AtomicWeight> symbols = new(StringComparer.Ordinal);
    public static IReadOnlyList<AtomicWeight> Elements { get; }
    public static string RuleId { get; }
    public static string Source { get; }
    static AtomicWeightCatalog()
    {
        using var stream = typeof(AtomicWeightCatalog).Assembly.GetManifestResourceStream("Calc.AtomicWeights")!;
        using var doc = JsonDocument.Parse(stream); var root = doc.RootElement;
        if (root.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Unsupported atomic-weight catalog");
        RuleId = root.GetProperty("ruleId").GetString()!; Source = root.GetProperty("source").GetString()!;
        var elements = new List<AtomicWeight>();
        foreach (var item in root.GetProperty("elements").EnumerateArray())
        {
            Rational? Read(string name) => item.GetProperty(name).ValueKind == JsonValueKind.Null ? null : Rational.Parse(item.GetProperty(name).GetString()!);
            var element = new AtomicWeight(item.GetProperty("atomicNumber").GetInt32(), item.GetProperty("symbol").GetString()!, item.GetProperty("name").GetString()!, Read("weight"), Read("quotedUncertainty"), item.GetProperty("notes").GetString()!);
            if (element.AtomicNumber != elements.Count + 1 || element.Symbol.Length is < 1 or > 2 || element.Weight is { } w && w.Numerator.Sign <= 0 || element.Weight.HasValue != element.QuotedUncertainty.HasValue)
                throw new InvalidDataException("Invalid atomic-weight definition");
            symbols.Add(element.Symbol, element); elements.Add(element);
        }
        if (elements.Count != 118 || elements.Count(element => element.Weight is not null) != 84) throw new InvalidDataException("Incomplete atomic-weight catalog");
        Elements = elements.AsReadOnly();
    }
    internal static AtomicWeight Get(string symbol) => symbols.TryGetValue(symbol, out var element) ? element : throw new ArithmeticException("Unknown case-sensitive element: " + symbol);
}

public sealed record ChemicalContribution(string Symbol, int Atoms, Rational AtomicWeight, Rational QuotedUncertainty, Rational GramsPerMole);
public sealed record ChemistryEvidence(string Formula, string RuleId, Rational NominalGramsPerMole, IReadOnlyList<ChemicalContribution> Composition, string Source);

internal sealed class ChemistryArithmetic(ExecutionBudget budget, CancellationToken token)
{
    internal const string Assumption = "Nominal molar mass from CIAAW abridged 2024 weights; natural isotope variation and quoted atomic-weight uncertainties are not propagated; not an exact physical constant, isotope-specific mass or purity model";
    private void Step() => budget.Step(token);
    internal ChemistryEvidence Formula(string text)
    {
        if (text.Length is < 1 or > 512) throw new ArithmeticException("Chemical formula must contain 1–512 characters");
        text = string.Concat(text.Select(c => c is >= '₀' and <= '₉' ? (char)('0' + c - '₀') : c));
        var position = 0; var depth = 0;
        int Count()
        {
            if (position == text.Length || !char.IsAsciiDigit(text[position])) return 1;
            var value = 0;
            while (position < text.Length && char.IsAsciiDigit(text[position]))
            { Step(); var digit = text[position++] - '0'; if (value > 100000 || value * 10L + digit > 1_000_000) throw new ArithmeticException("Chemical atom/count limit exceeded"); value = value * 10 + digit; }
            if (value == 0) throw new ArithmeticException("Chemical counts must be positive integers");
            return value;
        }
        void Add(Dictionary<string, int> output, string symbol, int count)
        { Step(); var total = (long)output.GetValueOrDefault(symbol) + count; if (total > 1_000_000) throw new ArithmeticException("Chemical atom/count limit exceeded"); output[symbol] = (int)total; }
        Dictionary<string, int> Group(char close = '\0')
        {
            if (++depth > 16) throw new ArithmeticException("Chemical grouping depth exceeds 16");
            var output = new Dictionary<string, int>(StringComparer.Ordinal); var terms = 0;
            while (position < text.Length && text[position] != close && text[position] is not '.' and not '·')
            {
                Step(); var c = text[position++];
                if (c is '(' or '[')
                {
                    var nested = Group(c == '(' ? ')' : ']');
                    if (position >= text.Length || text[position++] != (c == '(' ? ')' : ']')) throw new FormatException("Unclosed chemical group");
                    var multiplier = Count();
                    foreach (var entry in nested)
                    { if ((long)entry.Value * multiplier > 1_000_000) throw new ArithmeticException("Chemical atom/count limit exceeded"); Add(output, entry.Key, entry.Value * multiplier); }
                }
                else
                {
                    if (c is < 'A' or > 'Z') throw new FormatException("Chemical elements require case-sensitive symbols and matched groups");
                    var symbol = c.ToString();
                    if (position < text.Length && text[position] is >= 'a' and <= 'z') symbol += text[position++];
                    _ = AtomicWeightCatalog.Get(symbol); Add(output, symbol, Count());
                }
                terms++;
            }
            depth--;
            if (terms == 0) throw new FormatException("Chemical groups cannot be empty");
            return output;
        }
        var atoms = new Dictionary<string, int>(StringComparer.Ordinal);
        while (position < text.Length)
        {
            Step(); var multiplier = Count(); var group = Group();
            foreach (var entry in group)
            { if ((long)entry.Value * multiplier > 1_000_000) throw new ArithmeticException("Chemical atom/count limit exceeded"); Add(atoms, entry.Key, entry.Value * multiplier); }
            if (position == text.Length) break;
            if (text[position++] is not '.' and not '·' || position == text.Length) throw new FormatException("Invalid chemical adduct separator");
        }
        if (atoms.Values.Sum(value => (long)value) > 1_000_000) throw new ArithmeticException("Chemical formula exceeds one million atoms");
        var total = default(Rational); var contributions = new List<ChemicalContribution>();
        foreach (var entry in atoms.OrderBy(entry => AtomicWeightCatalog.Get(entry.Key).AtomicNumber))
        {
            Step(); var element = AtomicWeightCatalog.Get(entry.Key);
            if (element.Weight is not { } weight) throw new ArithmeticException("Standard atomic weight unavailable for " + element.Symbol + "; an isotope mass is not guessed");
            var contribution = weight * new Rational(entry.Value, 1); Step(); total += contribution;
            contributions.Add(new(entry.Key, entry.Value, weight, element.QuotedUncertainty!.Value, contribution));
        }
        return new(text, AtomicWeightCatalog.RuleId, total, contributions.AsReadOnly(), AtomicWeightCatalog.Source);
    }
    internal (SheetValue Value, ChemistryEvidence Evidence) Evaluate(ChemistryExpression expression, SheetValue? input)
    {
        var evidence = Formula(expression.Formula);
        var grams = UnitExpression.Single(UnitCatalog.ById("g")); var moles = UnitExpression.Single(UnitCatalog.ById("mol"));
        if (input is null) return (new(new NumericValue(new ExactNumber(evidence.NominalGramsPerMole / new Rational(1000, 1)), grams.Combine(moles, -1)) { IsApproximate = true }), evidence);
        var number = input.Value.Number;
        if (number.IsPercentage || number.Unit is null || !number.IsRational || number.Exact.Rational.Numerator.Sign < 0) throw new ArithmeticException("Chemical conversion requires a nonnegative rational mass or amount-of-substance quantity");
        var mass = new Dimension(0, 1, 0, 0, 0, 0, 0, 0); var amount = new Dimension(0, 0, 0, 0, 0, 1, 0, 0);
        var target = expression.Target!; Rational result;
        Step();
        if (number.Unit.Dimension == mass && target.Dimension == amount) result = number.Exact.Rational * new Rational(1000, 1) / evidence.NominalGramsPerMole;
        else if (number.Unit.Dimension == amount && target.Dimension == mass) result = number.Exact.Rational * evidence.NominalGramsPerMole / new Rational(1000, 1);
        else throw new ArithmeticException("Chemical conversion requires mass ↔ amount of substance; use ordinary unit conversion within one dimension");
        return (new(new NumericValue(new ExactNumber(result), target) { IsApproximate = true, DisplayDecimalPlaces = 4 }), evidence);
    }
}
