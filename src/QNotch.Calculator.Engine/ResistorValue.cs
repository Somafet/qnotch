using System.Text.Json;

namespace Calc.Core;

public sealed record ResistorColorDefinition(string Name, int? Digit, int MultiplierExponent, Rational? Tolerance);

/// <summary>Pinned commercial markings; never fetches rules or infers a physical component's orientation.</summary>
public static class ResistorColorCatalog
{
    private static readonly Dictionary<string, ResistorColorDefinition> names = new(StringComparer.OrdinalIgnoreCase);
    public static IReadOnlyList<ResistorColorDefinition> Colors { get; }
    public static string RuleId { get; }
    public static string Source { get; }
    static ResistorColorCatalog()
    {
        using var stream = typeof(ResistorColorCatalog).Assembly.GetManifestResourceStream("Calc.ResistorColors")!;
        using var doc = JsonDocument.Parse(stream); var root = doc.RootElement;
        if (root.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Unsupported resistor color catalog");
        RuleId = root.GetProperty("ruleId").GetString()!; Source = root.GetProperty("source").GetString()!;
        var colors = new List<ResistorColorDefinition>();
        foreach (var item in root.GetProperty("colors").EnumerateArray())
        {
            var digit = item.GetProperty("digit"); var tolerance = item.GetProperty("tolerancePercent");
            var color = new ResistorColorDefinition(item.GetProperty("name").GetString()!, digit.ValueKind == JsonValueKind.Null ? null : digit.GetInt32(),
                item.GetProperty("multiplierExponent").GetInt32(), tolerance.ValueKind == JsonValueKind.Null ? null : Rational.Parse(tolerance.GetString()!) / new Rational(100, 1));
            if (color.Name.Length is < 1 or > 16 || color.Digit is < 0 or > 9 || color.MultiplierExponent is < -2 or > 9 || color.Tolerance is { } t && t.Numerator.Sign <= 0)
                throw new InvalidDataException("Invalid resistor color definition");
            names.Add(color.Name, color); colors.Add(color);
        }
        if (colors.Count != 12 || colors.Count(color => color.Digit is not null) != 10) throw new InvalidDataException("Incomplete resistor colors");
        names.Add("grey", names["gray"]); Colors = colors.AsReadOnly();
    }
    internal static bool TryGet(string name, out ResistorColorDefinition color) => names.TryGetValue(name, out color!);
}

/// <summary>Immutable physical marking with nominal magnitude and stated component tolerance, not a measured resistance.</summary>
public sealed class ResistorValue : IEquatable<ResistorValue>
{
    public Rational NominalOhms { get; }
    public Rational Tolerance { get; }
    public Rational MinimumOhms => NominalOhms * (new Rational(1, 1) - Tolerance);
    public Rational MaximumOhms => NominalOhms * (new Rational(1, 1) + Tolerance);
    public int SignificantDigits { get; }
    public IReadOnlyList<string> Bands { get; }
    public bool ShowColors { get; }
    public NumericValue Nominal { get; }
    internal ResistorValue(Rational ohms, Rational tolerance, IEnumerable<string> bands, int digits, bool showColors)
    {
        NominalOhms = ohms; Tolerance = tolerance; SignificantDigits = digits; Bands = Array.AsReadOnly(bands.ToArray()); ShowColors = showColors;
        var unit = (ohms - new Rational(1_000_000, 1)).Numerator.Sign >= 0 ? "Mohm" : (ohms - new Rational(1000, 1)).Numerator.Sign >= 0 ? "kohm" : "ohm";
        Nominal = new(new ExactNumber(ohms), UnitExpression.Single(UnitCatalog.ById(unit)));
    }
    public string Display => ShowColors ? string.Join(' ', Bands) : Nominal.Display + " ±" + (Tolerance * new Rational(100, 1)) + "%";
    // Both modes round-trip the actual marking, including significant digits and tolerance.
    public string CopyText => ShowColors ? string.Join(' ', Bands) : "resistor(" + NominalOhms + " ohm," + Tolerance * new Rational(100, 1) + "%," + SignificantDigits + ")";
    public bool Equals(ResistorValue? other) => ReferenceEquals(this, other) || other is not null && NominalOhms == other.NominalOhms && Tolerance == other.Tolerance && SignificantDigits == other.SignificantDigits && ShowColors == other.ShowColors && Bands.SequenceEqual(other.Bands);
    public override bool Equals(object? obj) => obj is ResistorValue other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(NominalOhms, Tolerance, SignificantDigits, ShowColors);
    public override string ToString() => Display;
}
