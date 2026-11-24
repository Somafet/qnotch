using System.Globalization;
using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class ConstantTests
{
    private static LineResult Last(string source) => SheetEvaluator.Evaluate(source)[^1];
    private static SheetValue Value(string source) { var result = Last(source); Assert.Null(result.Error); return result.Value!.Value; }
    private static double Double(Rational value) => (double)value.Numerator / (double)value.Denominator;
    private static Rational Published(string text)
    {
        var parts = text.Split('e'); var exponent = parts.Length == 2 ? int.Parse(parts[1], CultureInfo.InvariantCulture) : 0;
        var scale = BigInteger.Pow(10, Math.Abs(exponent));
        return Rational.Parse(parts[0]) * (exponent < 0 ? new Rational(1, scale) : new Rational(scale, 1));
    }
    private static void Near(string source, double expected, double relative)
    {
        var value = Value(source).Number.Exact;
        var actual = value.IsRational ? Double(value.Rational) : throw new Xunit.Sdk.XunitException("Expected a rational magnitude");
        Assert.InRange(actual, expected - Math.Abs(expected) * relative, expected + Math.Abs(expected) * relative);
    }

    [Fact]
    public void PublishedReferenceExample()
    {
        var value = Value("c");
        Assert.Equal("299,792,458 m/s", value.Display); Assert.Equal("299792458 m/s", value.CopyText); Assert.False(value.Number.IsApproximate);
    }

    // Values as printed by NIST for CODATA 2022 and the 2019 SI definitions, inspected 31 October 2026.
    [Theory]
    [InlineData("c", "299792458", "m/s", false)]
    [InlineData("planck", "6.62607015e-34", "J*s", false)]
    [InlineData("elementary_charge", "1.602176634e-19", "C", false)]
    [InlineData("boltzmann", "1.380649e-23", "J/deltaK", false)]
    [InlineData("avogadro", "6.02214076e23", "mol^-1", false)]
    [InlineData("standard_gravity", "9.80665", "m/s^2", false)]
    [InlineData("gravitational_constant", "6.67430e-11", "m^3/kg/s^2", true)]
    [InlineData("vacuum_permittivity", "8.8541878188e-12", "F/m", true)]
    [InlineData("vacuum_permeability", "1.25663706127e-6", "N/A^2", true)]
    [InlineData("electron_mass", "9.1093837139e-31", "kg", true)]
    [InlineData("proton_mass", "1.67262192595e-27", "kg", true)]
    public void PinnedValuesMatchPublishedDigits(string name, string published, string unit, bool measured)
    {
        var value = Value(name).Number;
        Assert.Equal(Published(published), value.Exact.Rational); Assert.Equal(unit, value.Unit!.Symbol); Assert.Equal(measured, value.IsApproximate);
    }
    [Theory]
    [InlineData("gravitational_constant", "0.00015e-11")]
    [InlineData("vacuum_permittivity", "0.0000000014e-12")]
    [InlineData("vacuum_permeability", "0.00000000020e-6")]
    [InlineData("electron_mass", "0.0000000028e-31")]
    [InlineData("proton_mass", "0.00000000052e-27")]
    public void MeasuredConstantsRetainUncertaintyAndAreMarked(string name, string uncertainty)
    {
        var line = Last(name);
        Assert.StartsWith("≈ ", line.Display);
        var assumption = line.Explanation[^1].Assumption!;
        Assert.Contains("CODATA 2022", assumption); Assert.StartsWith("Approximate input/result", assumption);
        Assert.Contains(uncertainty, assumption.Split("; ")[1]); // Hover shows the first two segments, so the uncertainty must be among them.
    }
    [Theory]
    [InlineData("c", "exact by the 2019 SI definition")]
    [InlineData("standard_gravity", "1901 CGPM")]
    [InlineData("gas_constant", "exact product")]
    [InlineData("hbar", "truncated")]
    public void ExactnessAndSourceAreExplained(string name, string text) => Assert.Contains(text, Last(name).Explanation[^1].Assumption);

    // Independent routes between constants. Tolerances come from the published relative uncertainties.
    [Fact]
    public void GasConstantIsExactlyAvogadroTimesBoltzmann()
    {
        Assert.Equal("0 J/deltaK/mol", Value("gas_constant - avogadro * boltzmann").Display);
        Assert.False(Value("gas_constant").Number.IsApproximate);
        Assert.StartsWith("8.314462618", Value("gas_constant").Display);
    }
    [Fact]
    public void ReducedPlanckMatchesARecomputationWithFiftyDigitsOfPi()
    {
        var pi = Rational.Parse("3.14159265358979323846264338327950288419716939937510");
        var expected = Published("6.62607015e-34") / (new Rational(2, 1) * pi);
        var actual = Value("hbar").Number; Assert.True(actual.IsApproximate);
        var difference = (actual.Exact.Rational - expected) / expected;
        Assert.True(BigInteger.Abs(difference.Numerator) * BigInteger.Pow(10, 26) < difference.Denominator);
        Assert.StartsWith("≈ 1.054571817", actual.Display); // NIST prints 1.054 571 817...
    }
    [Fact]
    public void PublishedDerivedConstantsAreReproduced()
    {
        Near("elementary_charge * avogadro", 96485.33212, 1e-9); // Faraday constant, exact
        Near("electron_mass * c^2", 8.1871057880e-14, 1e-9); // CODATA 2022 electron mass energy equivalent
        Near("electron_mass * c^2 / elementary_charge", 510998.95069, 1e-9); // 0.51099895069 MeV
        Near("proton_mass / electron_mass", 1836.152673426, 1e-9); // CODATA 2022 proton-electron mass ratio
        Near("boltzmann * 300 deltaK", 4.141947e-21, 1e-12);
    }
    [Fact]
    public void VacuumConstantsAgreeWithTheSpeedOfLight()
    {
        // c^2 = 1/(epsilon0 mu0). Both are measured with relative uncertainty near 1.6e-10.
        Near("c^2 * vacuum_permittivity * vacuum_permeability", 1, 5e-10);
        var derived = Value("1/sqrt(vacuum_permittivity * vacuum_permeability)");
        Assert.True(derived.Number.IsApproximate); Assert.Equal("m/s", derived.Number.Unit!.Symbol);
        Near("1/sqrt(vacuum_permittivity * vacuum_permeability)", 299792458, 5e-10);
    }
    [Fact]
    public void MathematicalConstantsSatisfyTheirIdentities()
    {
        Assert.Equal("≈ 3.14159265358979", Value("pi").Display); Assert.Equal("≈ 6.28318530717959", Value("tau").Display);
        Assert.Equal("≈ 2.71828182845905", Value("e + 0").Display); Assert.Equal("≈ 1.61803398874989", Value("phi").Display);
        Assert.Equal("0", Value("phi^2 - phi - 1").Display); Assert.False(Value("phi^2 - phi - 1").Number.IsApproximate); // phi^2 = phi + 1 exactly
        Assert.Equal("0.5 + 0.5*sqrt(5)", Value("phi").CopyText); Assert.Equal(Value("(1 + sqrt(5))/2").Exact, Value("phi").Exact);
        Assert.Equal("1", Value("phi * (phi - 1)").CopyText);
        Assert.True(Value("pi").Number.IsApproximate); Assert.False(Value("phi").Number.IsApproximate);
        Near("tau / pi", 2, 1e-13);
    }
    [Theory]
    [InlineData("c", "speed_of_light lightspeed")]
    [InlineData("planck", "planck_constant")]
    [InlineData("hbar", "ħ ℏ reduced_planck")]
    [InlineData("elementary_charge", "e_charge q_e")]
    [InlineData("boltzmann", "boltzmann_constant k_B")]
    [InlineData("avogadro", "avogadro_constant N_A")]
    [InlineData("gas_constant", "molar_gas_constant")]
    [InlineData("gravitational_constant", "newton_constant G_N")]
    [InlineData("standard_gravity", "g0 g_n")]
    [InlineData("vacuum_permittivity", "epsilon0 eps0 ε0 ε₀")]
    [InlineData("vacuum_permeability", "mu0 μ0 µ0 μ₀")]
    [InlineData("electron_mass", "m_e")]
    [InlineData("proton_mass", "m_p")]
    [InlineData("pi", "π")]
    [InlineData("tau", "τ")]
    [InlineData("phi", "φ")]
    public void EveryAliasResolvesToTheSameValue(string name, string aliases)
    {
        foreach (var alias in aliases.Split(' ')) { Assert.Equal(Value(name), Value(alias)); Assert.Equal(Value(name + " + " + name), Value(alias + " + " + alias)); }
    }
    [Theory]
    [InlineData("c = 5\nc", "5")]
    [InlineData("c = 5\nc * 2", "10")]
    [InlineData("hbar = 2\nhbar", "2")]
    [InlineData("phi = 3\nphi", "3")]
    [InlineData("tau = 4\ntau", "4")]
    [InlineData("planck = 7\nplanck", "7")]
    [InlineData("pi = 3\npi", "3")]
    [InlineData("e = 3\ne", "3")]
    public void UserVariablesWinEverywhere(string source, string display) => Assert.Equal(display, Last(source).Display);
    [Fact]
    public void AVariableDefinedLaterStillWins() => Assert.Equal("10", SheetEvaluator.Evaluate("c * 2\nc = 5")[0].Display);
    [Fact]
    public void ParametersWinOverConstants()
    {
        var update = FunctionUpdate.Prepare("f(c) = c * 2", FunctionLibrary.Empty, []);
        Assert.Equal("6", new SheetEvaluationSession().EvaluateWithFunctions("f(3)", update.Library, []).Results[0].Display);
    }
    [Theory]
    [InlineData("3 h", "3 h")]
    [InlineData("5 m", "5 m")]
    [InlineData("2 g", "2 g")]
    [InlineData("1 kg", "1 kg")]
    [InlineData("5 g0", "5 g0")]
    [InlineData("2 C", "2 C")]
    [InlineData("3 h in min", "180 min")]
    [InlineData("21 celsius in fahrenheit", "69.8 °F")]
    [InlineData("100 °C in K", "373.15 K")]
    [InlineData("2k", "2000")]
    [InlineData("5M", "5000000")]
    [InlineData("3 million", "3000000")]
    [InlineData("half of 10", "5")]
    public void UnitsAndMultipliersWinInUnitPosition(string source, string display) => Assert.Equal(display, Value(source).Display);
    [Theory]
    [InlineData("5 c")]
    [InlineData("180 c in f")]
    public void LowercaseCIsNotACelsiusUnitAndNeverBecomesAMultipleOfLightSpeed(string source)
    {
        var result = Last(source);
        Assert.Null(result.Value); Assert.Equal("Unexpected text", result.Error);
    }
    [Theory]
    [InlineData("c 5", "5")]
    [InlineData("e 5", "5")]
    [InlineData("phi 12", "12")]
    public void LabelsBeforeNumbersStayLabels(string source, string display) => Assert.Equal(display, Value(source).Display);
    [Theory]
    [InlineData("e")]
    [InlineData("C")]
    [InlineData("Planck")]
    [InlineData("Boltzmann")]
    [InlineData("a b c")]
    [InlineData("c in f")]
    [InlineData("c in h")]
    [InlineData("speed of light")]
    public void ProseStaysProse(string source) { var result = SheetEvaluator.Evaluate(source)[0]; Assert.Null(result.Value); Assert.Null(result.Error); }
    [Theory]
    [InlineData("c in km/s", "299,792.458 km/s")]
    [InlineData("c in m/s", "299,792,458 m/s")]
    [InlineData("standard_gravity in m/s^2", "9.80665 m/s^2")]
    [InlineData("c to 3 sig figs", "300000000 m/s")]
    [InlineData("pi to 3 decimals", "≈ 3.142")]
    [InlineData("phi to 4 decimals", "1.618")]
    [InlineData("c * 2", "599,584,916 m/s")]
    [InlineData("2 * c", "599,584,916 m/s")]
    [InlineData("-c", "-299,792,458 m/s")]
    [InlineData("c * 5 s", "1,498,962,290 m")]
    [InlineData("pi/3", "≈ 1.0471975511966")]
    public void ConversionsRoundingAndArithmeticKeepCompactNotation(string source, string display) => Assert.Equal(display, Value(source).Display);
    [Fact]
    public void ConversionToARepeatingDecimalIsMarkedAsRounded()
    {
        var value = Value("c in mph");
        Assert.Equal("≈ 670,616,629.384395 mph", value.Display); Assert.False(value.Number.IsApproximate); // 299792458 / 0.44704
        Assert.Contains("/", value.CopyText);
    }
    [Fact]
    public void CopyKeepsCompleteDigitsAndPastesBack()
    {
        var value = Value("planck");
        Assert.Equal("6.62607015e-34 J*s", value.Display); Assert.StartsWith("0.000000000000000000000000000000000662607015", value.CopyText);
        Assert.Equal(value.Exact, Value(value.CopyText).Exact); Assert.Equal("6.02214076e23 mol^-1", Value("avogadro").Display);
        Assert.Equal("89875517873681764 m^2/s^2", Value("c^2").CopyText); // 299792458^2
    }
    [Fact]
    public void OrdinaryNumbersAreNotRegrouped()
    {
        Assert.Equal("1000000 m", Value("1000000 m").Display); Assert.Equal("299792458", Value("299792458").Display);
        Assert.Equal("≈ 15.71 USD", Value("$5 * pi").Display);
    }
    [Fact]
    public void ConstantsWorkInsideFormulas()
    {
        Assert.Equal("x = 299792458", Value("solve x = c").Display);
        Assert.Equal("x = 149896229", Value("solve 2x = c").Display);
        Assert.Equal("149896229", Value("integral(c*x, 0, 1)").Display); // c/2 by the polynomial antiderivative
        Assert.Equal("3", Value("derivative(gas_constant/gas_constant*3*x, 7)").Display);
        Near("r = solve x = tau\nsolutionRoot(r, 1)", Math.Tau, 1e-9);
        Assert.Equal("x ≈ 1.618", Value("solve x = phi").Display);
        Near("derivative(tau*x^2, 1)", 2 * Math.Tau, 1e-9); // 2 tau x at x = 1, through the symbolic path because tau is not rational
        Near("integral(phi*x, 0, 2)", 2 * (1 + Math.Sqrt(5)) / 2, 1e-9); // phi x^2/2 from 0 to 2
    }
    [Fact]
    public void MeasuredConstantsMakeFormulaResultsApproximateAndDiscloseTheDroppedUnit()
    {
        var line = Last("solve x = 2 * gravitational_constant");
        Assert.True(line.Value!.Value.Equation.IsApproximate);
        Assert.Contains(line.Explanation, step => step.Assumption?.Contains("formulas do not track dimensions") == true && step.Assumption.Contains("0.00015e-11"));
    }
    [Theory]
    [InlineData("c = 3\nsolve x = c", "x = 3")]
    [InlineData("solve c^2 = 4 for c", "c = -2 or c = 2")]
    [InlineData("hbar = 2\nintegral(hbar*x, 0, 1)", "1")]
    public void FormulaNamesFollowTheSamePrecedence(string source, string display) => Assert.Equal(display, Last(source).Display);
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("energy(m) = m * c^2\nhalfc(x) = solve 2y = c for y", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var reloaded = new FunctionLibrary(update.Library.Definitions);
        Assert.Equal(update.Library.Fingerprint, reloaded.Fingerprint);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("energy(2)\nhalfc(0)", reloaded, []).Results;
        Assert.Equal("179751035747363528", results[0].Value!.Value.CopyText.Split(' ')[0]); // 2 * 299792458^2
        Assert.Equal("y = 149896229", results[1].Display);
    }
}
