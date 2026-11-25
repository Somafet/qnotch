using System.Globalization;

namespace Calc.Core;

/// <summary>Immutable display unit; canonical magnitude is stored separately in NumericValue.Exact.</summary>
public sealed class UnitExpression : IEquatable<UnitExpression>
{
    private readonly (UnitDefinition Unit, int Power)[] terms;
    public Dimension Dimension { get; }
    public Rational Factor { get; }
    public Rational Offset { get; }
    public bool IsTemperaturePoint { get; }
    public string Symbol { get; }
    public string Kind { get; }
    internal string Key { get; }
    private UnitExpression(IEnumerable<(UnitDefinition Unit, int Power)> values)
    {
        terms = values.Where(value => value.Power != 0).OrderBy(value => value.Unit.Id, StringComparer.Ordinal).ToArray();
        if (terms.Length > 16 || terms.Any(value => Math.Abs((long)value.Power) > 16)) throw new ArithmeticException("Unit expression limit exceeded");
        IsTemperaturePoint = terms.Any(value => value.Unit.IsTemperaturePoint);
        if (IsTemperaturePoint && (terms.Length != 1 || terms[0].Power != 1)) throw new ArithmeticException("Absolute temperature cannot form a compound unit; use delta units");
        Dimension = default; Factor = new(1, 1);
        foreach (var term in terms)
        {
            Dimension = Dimension.Combine(term.Unit.Dimension.Power(new(term.Power, 1)), 1);
            for (var i = 0; i < Math.Abs(term.Power); i++) Factor = term.Power > 0 ? Factor * term.Unit.Factor : Factor / term.Unit.Factor;
        }
        Offset = IsTemperaturePoint ? terms[0].Unit.Offset : default;
        Kind = terms.Length == 1 && terms[0].Power == 1 ? terms[0].Unit.Kind : "";
        Key = string.Join(';', terms.Select(value => value.Unit.Id + ":" + value.Power.ToString(CultureInfo.InvariantCulture)));
        static string Part((UnitDefinition Unit, int Power) term) => term.Unit.Symbol + (Math.Abs(term.Power) == 1 ? "" : "^" + Math.Abs(term.Power).ToString(CultureInfo.InvariantCulture));
        var numerator = string.Join('*', terms.Where(value => value.Power > 0).Select(Part));
        var denominator = terms.Where(value => value.Power < 0).ToArray();
        Symbol = numerator.Length == 0 && denominator.Length > 0
            ? string.Join('*', denominator.Select(term => term.Unit.Symbol + "^" + term.Power.ToString(CultureInfo.InvariantCulture)))
            : (numerator.Length == 0 ? "1" : numerator) + string.Concat(denominator.Select(term => "/" + Part(term)));
        if (Symbol.Length > 256) throw new ArithmeticException("Unit output limit exceeded");
    }
    internal static UnitExpression Single(UnitDefinition unit) => new([(unit, 1)]);
    internal UnitExpression Combine(UnitExpression other, int sign)
    {
        if (IsTemperaturePoint || other.IsTemperaturePoint) throw new ArithmeticException("Absolute temperature cannot form a compound unit; use delta units");
        var values = terms.ToDictionary(value => value.Unit.Id, value => value, StringComparer.Ordinal);
        foreach (var term in other.terms)
        { var power = values.GetValueOrDefault(term.Unit.Id).Power + sign * term.Power; values[term.Unit.Id] = (term.Unit, power); }
        // Equivalent linear units cancel by dimension, even when their scales differ (s * km/h).
        // Magnitude is canonical already; recomputing the chosen display factor preserves exactness.
        var simplified = new List<(UnitDefinition Unit, int Power)>();
        foreach (var group in values.Values.GroupBy(value => (value.Unit.Dimension, value.Unit.Kind)))
        {
            var power = group.Sum(value => value.Power);
            var preferred = group.First().Unit;
            foreach (var value in group)
                if ((value.Unit.Factor - preferred.Factor).Numerator.Sign > 0) preferred = value.Unit;
            if (power != 0) simplified.Add((preferred, power));
        }
        return new(simplified);
    }
    internal UnitExpression Power(Rational exponent)
    {
        if (IsTemperaturePoint && exponent != new Rational(1, 1)) throw new ArithmeticException("Absolute temperature cannot be raised to a power");
        var dimension = Dimension.Power(exponent);
        var powers = terms.Select(term => (term.Unit, Power: new Rational(term.Power, 1) * exponent)).ToArray();
        return powers.All(term => term.Power.Denominator == 1) ? new(powers.Select(term => (term.Unit, (int)term.Power.Numerator))) : Canonical(dimension);
    }
    /// <summary>1 for fuel consumption (volume per distance: l/100km, L/km), -1 for fuel economy (distance per volume: mpg, km/l), otherwise 0.</summary>
    internal int FuelForm()
    {
        if (terms.Length == 1) return terms[0].Power != 1 ? 0 : terms[0].Unit.Id switch { "l100km" => 1, "mpg" or "mpguk" => -1, _ => 0 };
        if (terms.Length != 2 || terms[0].Power * terms[1].Power != -1) return 0;
        var volume = terms.Where(term => term.Unit.Dimension == FuelVolumeDimension).ToArray();
        return volume.Length == 1 && terms.Any(term => term.Unit.Dimension == FuelLengthDimension) ? volume[0].Power : 0;
    }
    private static readonly Dimension FuelVolumeDimension = new(3, 0, 0, 0, 0, 0, 0, 0), FuelLengthDimension = new(1, 0, 0, 0, 0, 0, 0, 0);
    /// <summary>The volume unit a trip over this consumption is reported in: litre, US gallon or imperial gallon, or the unit's own volume term.</summary>
    internal UnitExpression FuelVolume() => terms.Length == 1 ? Single(UnitCatalog.ById(terms[0].Unit.Id switch { "mpg" => "gal", "mpguk" => "impgal", _ => "L" }))
        : Single(terms.First(term => term.Unit.Dimension == FuelVolumeDimension).Unit);
    internal UnitExpression Delta()
    {
        if (!IsTemperaturePoint) return this;
        return Single(UnitCatalog.ById("delta" + terms[0].Unit.Id.Replace("deg", "", StringComparison.Ordinal)));
    }
    internal static UnitExpression Canonical(Dimension dimension)
    {
        string[] bases = ["m", "kg", "s", "A", "deltaK", "mol", "cd", "bit"];
        return new(dimension.Components.Select((power, index) => (UnitCatalog.ById(bases[index]), power)));
    }
    public bool Equals(UnitExpression? other) => other is not null && Key == other.Key;
    public override bool Equals(object? obj) => obj is UnitExpression other && Equals(other);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Key);
    public override string ToString() => Symbol;
    internal string MoneySuffix()
    {
        static string Part((UnitDefinition Unit,int Power) term) => term.Unit.Symbol + (Math.Abs(term.Power) == 1 ? "" : "^" + Math.Abs(term.Power).ToString(CultureInfo.InvariantCulture));
        var numerator = string.Join('*',terms.Where(term => term.Power > 0).Select(Part));
        return (numerator.Length > 0 ? " " + numerator : "") + string.Concat(terms.Where(term => term.Power < 0).Select(term => "/" + Part(term)));
    }
}
