using System.Globalization;
using System.Numerics;

namespace Calc.Core;

internal enum ConstantExactness { Exact, Truncated, Measured }
/// <summary>One pinned constant. Value is a decimal in the stated SI unit; Names are space-separated, case-sensitive aliases.</summary>
internal sealed record ConstantEntry(string Title, string Names, string Value, string Unit, ConstantExactness Exactness, string Source, string? Uncertainty = null)
{
    internal string Assumption => Title + (Uncertainty is null ? "" : ", standard uncertainty " + Uncertainty + " " + Unit) + "; " + Source;
}

/// <summary>Pinned offline constants: CODATA 2022 and exact SI 2019 definitions. Units, user variables and the older grammar win over every alias here.</summary>
internal static class ConstantCatalog
{
    private const string Si = "exact by the 2019 SI definition", Codata = "CODATA 2022 (NIST); measured", Mathematical = "Mathematical constant to 15 significant digits";
    internal const string FormulaNote = "; SI magnitude; formulas do not track dimensions";
    private const int NotationDigits = 15, NotationBits = 96;
    internal static readonly ConstantEntry[] Entries =
    [
        new("Speed of light in vacuum", "c speed_of_light lightspeed", "299792458", "m/s", ConstantExactness.Exact, Si),
        new("Planck constant", "planck planck_constant", "6.62607015e-34", "J*s", ConstantExactness.Exact, Si),
        new("Reduced Planck constant h/2pi", "hbar ħ ℏ reduced_planck", "1.054571817646156391262428003e-34", "J*s", ConstantExactness.Truncated, "exact by definition but irrational; CODATA 2022; truncated to 28 digits"),
        new("Elementary charge", "elementary_charge e_charge q_e", "1.602176634e-19", "C", ConstantExactness.Exact, Si),
        new("Boltzmann constant", "boltzmann boltzmann_constant k_B", "1.380649e-23", "J/deltaK", ConstantExactness.Exact, Si),
        new("Avogadro constant", "avogadro avogadro_constant N_A", "6.02214076e23", "/mol", ConstantExactness.Exact, Si),
        new("Molar gas constant N_A*k", "gas_constant molar_gas_constant", "8.31446261815324", "J/deltaK/mol", ConstantExactness.Exact, "exact product of two 2019 SI definitions"),
        new("Newtonian constant of gravitation", "gravitational_constant newton_constant G_N", "6.67430e-11", "m^3/kg/s^2", ConstantExactness.Measured, Codata, "0.00015e-11"),
        new("Standard acceleration of gravity", "standard_gravity g0 g_n", "9.80665", "m/s^2", ConstantExactness.Exact, "exact by the 1901 CGPM definition"),
        new("Vacuum electric permittivity", "vacuum_permittivity epsilon0 eps0 ε0 ε₀", "8.8541878188e-12", "F/m", ConstantExactness.Measured, Codata, "0.0000000014e-12"),
        new("Vacuum magnetic permeability", "vacuum_permeability mu0 μ0 µ0 μ₀", "1.25663706127e-6", "N/A^2", ConstantExactness.Measured, Codata, "0.00000000020e-6"),
        new("Electron mass", "electron_mass m_e", "9.1093837139e-31", "kg", ConstantExactness.Measured, Codata, "0.0000000028e-31"),
        new("Proton mass", "proton_mass m_p", "1.67262192595e-27", "kg", ConstantExactness.Measured, Codata, "0.00000000052e-27"),
        new(Mathematical, "pi π", "3.14159265358979", "", ConstantExactness.Truncated, "approximate"),
        new(Mathematical, "tau τ", "6.28318530717959", "", ConstantExactness.Truncated, "approximate"),
        new(Mathematical, "e", "2.71828182845905", "", ConstantExactness.Truncated, "approximate"),
        new("Golden ratio (1 + sqrt(5))/2", "phi φ", "phi", "", ConstantExactness.Exact, "exact radical; display rounded to 15 significant digits")
    ];
    private static readonly Dictionary<string, ConstantEntry> names = Entries.SelectMany(entry => entry.Names.Split(' ').Select(name => (name, entry))).ToDictionary(pair => pair.name, pair => pair.entry, StringComparer.Ordinal);
    internal static bool TryFind(string name, out ConstantEntry entry) => names.TryGetValue(name, out entry!) || FormulaFunctions.IsConstant(name) && names.TryGetValue(name.ToLowerInvariant(), out entry!);
    internal static bool IsPhysical(string name) => names.TryGetValue(name, out var entry) && entry.Unit.Length > 0;
    /// <summary>A lone word that evaluates instead of staying prose. Foundation keeps a lone e as prose.</summary>
    internal static bool IsLoneValue(string name) => name == "i" || name != "e" && names.ContainsKey(name);
    /// <summary>"c in mph" is all name tokens, so it reads as prose unless the target unit fits the constant.</summary>
    internal static bool IsConversionLine(IReadOnlyList<Token> tokens)
    {
        if (tokens.Count < 3 || tokens[1].Text is not ("in" or "to") || !names.TryGetValue(tokens[0].Text, out var entry) || entry.Unit.Length == 0) return false;
        var position = 2;
        return UnitParser.TryParse(tokens, ref position, null, out var unit) && position == tokens.Count && unit.Dimension == Unit(entry).Dimension;
    }
    /// <summary>"pi to 3 decimals" would otherwise lose "pi to" as a leading label before the number.</summary>
    internal static bool IsRoundingLine(IReadOnlyList<Token> tokens)
    {
        if (tokens.Count < 3 || tokens[0].Text != "i" && !TryFind(tokens[0].Text, out _)) return false;
        var to = KeywordCatalog.Match(tokens, 1, KeywordRole.To);
        return to > 0 && (KeywordCatalog.Match(tokens, 1 + to, KeywordRole.Nearest) > 0 || KeywordCatalog.Match(tokens, 2 + to, KeywordRole.Decimals) > 0 || KeywordCatalog.Match(tokens, 2 + to, KeywordRole.Significant) > 0);
    }
    private static UnitExpression Unit(ConstantEntry entry)
    {
        var position = 0;
        return UnitParser.TryParse(ExpressionParser.Tokenize(entry.Unit, default), ref position, null, out var unit) ? unit : throw new InvalidDataException("Invalid constant unit: " + entry.Unit);
    }
    private static Rational Decimal(string text)
    {
        var split = text.IndexOf('e');
        if (split < 0) return Rational.Parse(text);
        var exponent = int.Parse(text[(split + 1)..], CultureInfo.InvariantCulture); var scale = BigInteger.Pow(10, Math.Abs(exponent));
        return Rational.Parse(text[..split]) * (exponent < 0 ? new Rational(1, scale) : new Rational(scale, 1));
    }
    /// <summary>The value with its unit and notation; a formula takes the plain SI magnitude.</summary>
    internal static NumericValue Resolve(ConstantEntry entry, bool magnitude)
    {
        var exact = entry.Value == "phi" ? Phi() : new ExactNumber(Decimal(entry.Value));
        var value = entry.Unit.Length == 0 || magnitude ? new NumericValue(exact) : new NumericValue(exact, Unit(entry));
        return value with { IsApproximate = entry.Exactness != ConstantExactness.Exact, UseConstantNotation = !magnitude };
    }
    private static ExactNumber Phi() => new(new SortedDictionary<BigInteger, Rational> { [1] = new(1, 2), [5] = new(1, 2) });
    /// <summary>Comma-grouped decimal for everyday magnitudes, scientific otherwise, at most 15 significant digits. Reports rounding so the caller can mark it.</summary>
    internal static string Notation(ExactNumber value, ExactArithmetic math, out bool rounded)
    {
        var rational = value.IsRational ? value.Rational : math.Bounds(value, NotationBits).Lower;
        rounded = !value.IsRational;
        if (rational.Numerator.IsZero) return "0";
        var n = BigInteger.Abs(rational.Numerator); var d = rational.Denominator;
        var exponent = n.ToString(CultureInfo.InvariantCulture).Length - d.ToString(CultureInfo.InvariantCulture).Length;
        if (exponent >= 0 ? n < d * BigInteger.Pow(10, exponent) : n * BigInteger.Pow(10, -exponent) < d) exponent--;
        var shift = NotationDigits - 1 - exponent;
        var top = shift >= 0 ? n * BigInteger.Pow(10, shift) : n; var bottom = shift >= 0 ? d : d * BigInteger.Pow(10, -shift);
        var scaled = (2 * top + bottom) / (2 * bottom);
        rounded |= scaled * bottom != top;
        if (scaled == BigInteger.Pow(10, NotationDigits)) { scaled /= 10; exponent++; }
        var digits = scaled.ToString(CultureInfo.InvariantCulture).TrimEnd('0');
        var sign = rational.Numerator.Sign < 0 ? "-" : "";
        if (exponent is < -3 or >= NotationDigits) return sign + digits[0] + (digits.Length > 1 ? "." + digits[1..] : "") + "e" + exponent.ToString(CultureInfo.InvariantCulture);
        if (exponent < 0) return sign + "0." + new string('0', -exponent - 1) + digits;
        var whole = digits.Length > exponent ? digits[..(exponent + 1)] : digits.PadRight(exponent + 1, '0');
        return sign + long.Parse(whole, CultureInfo.InvariantCulture).ToString("N0", CultureInfo.InvariantCulture) + (digits.Length > exponent + 1 ? "." + digits[(exponent + 1)..] : "");
    }
}
