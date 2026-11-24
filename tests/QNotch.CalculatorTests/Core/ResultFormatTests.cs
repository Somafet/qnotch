using System.Globalization;
using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class ResultFormatTests
{
    private static readonly EvaluationContext Context = new(new DateOnly(2027, 1, 5));
    private static LineResult Line(string source) => SheetEvaluator.Evaluate(source, context: Context)[0];
    private static string Show(string source, ResultFormat format)
    {
        var line = Line(source); Assert.Null(line.Error);
        return ResultFormatter.Format(line, format);
    }
    private static readonly NumberStyle Period = NumberStyle.FromId("period", CultureInfo.InvariantCulture);
    private static readonly NumberStyle Comma = NumberStyle.FromId("comma", CultureInfo.InvariantCulture);

    [Fact]
    public void DefaultFormatIsTheCanonicalDisplayForEveryKind()
    {
        var source = string.Join('\n', "1/3", "2^70", "12.5%", "5 km + 300 m", "1234.567 EUR", "2027-01-05 + 3 days", "09:00 + 90 min", "c", "sqrt(8)",
            "0xFF", "192.0.2.1/24", "[1, 2.5, 3]", "[[1,2],[3,4]]", "text(\"a.b,c 1234\")", "x = 4", "x * 1000", "1234.5 to 2 decimals");
        foreach (var line in SheetEvaluator.Evaluate(source, context: Context))
            Assert.Equal(line.Display, ResultFormatter.Format(line, ResultFormat.Default));
    }

    // Independent oracle: half away from zero with BigInteger arithmetic, then the invariant shortest decimal.
    private static string RoundOracle(BigInteger p, BigInteger q, int places)
    {
        var scale = BigInteger.Pow(10, places);
        var magnitude = (BigInteger.Abs(p) * scale * 2 + q) / (2 * q);
        if (magnitude.IsZero) return "0";
        var digits = magnitude.ToString(CultureInfo.InvariantCulture).PadLeft(places + 1, '0');
        var text = places == 0 ? digits : (digits[..^places] + "." + digits[^places..]).TrimEnd('0').TrimEnd('.');
        return (p.Sign < 0 ? "-" : "") + text;
    }
    [Fact]
    public void DecimalPlacesRoundDisplayedFractionsAgainstAnIndependentOracle()
    {
        var random = new Random(5005);
        for (var i = 0; i < 400; i++)
        {
            var q = random.Next(2, 5000); var p = (long)random.Next(-2_000_000, 2_000_000);
            if (p == 0) continue;
            var places = random.Next(0, 9);
            Assert.Equal(RoundOracle(p, q, places), Show($"{p}/{q}", new(places)));
        }
    }
    [Fact]
    public void SeparatorsMatchDotNetGroupingForRoundedValues()
    {
        // Oracle: System.Decimal with a custom NumberFormatInfo; values stay well inside decimal range.
        var random = new Random(611);
        foreach (var (style, group, separator) in new[] { (Period, ".", ","), (Comma, ",", "."), (NumberStyle.FromId("space", CultureInfo.InvariantCulture), NumberStyle.Space, ","), (NumberStyle.FromId("apostrophe", CultureInfo.InvariantCulture), "'", ".") })
        {
            var info = new NumberFormatInfo { NumberGroupSeparator = group, NumberDecimalSeparator = separator, NegativeSign = "-" };
            for (var i = 0; i < 200; i++)
            {
                var q = random.Next(1, 400); var p = (long)random.Next(-900_000_000, 900_000_000) * random.Next(1, 1000);
                if (Math.Abs(p) < q) continue;
                var places = random.Next(0, 7);
                var expected = Math.Round((decimal)p / q, places, MidpointRounding.AwayFromZero).ToString("#,0." + new string('#', Math.Max(1, places)), info);
                Assert.Equal(expected, Show($"{p}/{q}", new(places, style)));
            }
        }
    }
    [Theory]
    [InlineData("1234567.891", "1.234.567,891")]
    [InlineData("-1234.5", "-1.234,5")]
    [InlineData("12345.5%", "12.345,5%")]
    [InlineData("1234.5 km", "1.234,5 km")]
    [InlineData("1234.5 m^2", "1.234,5 m^2")]
    [InlineData("12345/7", "12345/7")]
    [InlineData("sqrt(20000)", "100*sqrt(2)")]
    [InlineData("999", "999")]
    public void PeriodStyleRewritesOnlyTheMagnitude(string source, string expected) => Assert.Equal(expected, Show(source, new(null, Period)));

    [Fact]
    public void MoneyKeepsMinorUnitsAndCurrencyCode()
    {
        var plain = Show("1234567.5 EUR", ResultFormat.Default);
        Assert.Equal("1234567.5 EUR", plain);
        Assert.Equal("1.234.567,5 EUR", Show("1234567.5 EUR", new(null, Period)));
        Assert.Equal("3,33 EUR", Show("10 EUR / 3", new(null, Period)));
        // Decimal places do not override a currency's minor units.
        Assert.Equal(plain, Show("1234567.5 EUR", new(0)));
    }
    [Fact]
    public void ConstantNotationGroupsAndExponentsFollowTheStyle()
    {
        var light = Show("c", ResultFormat.Default);
        Assert.Equal(light.Replace(",", "."), Show("c", new(null, Period)));
        var planck = Show("planck", ResultFormat.Default);
        Assert.Contains("e-34", planck);
        Assert.Equal(planck.Replace(".", ","), Show("planck", new(null, Period)));
    }
    [Fact]
    public void StructuredValuesKeepTheirCanonicalForm()
    {
        var style = new ResultFormat(2, Period);
        foreach (var source in new[] { "2027-01-05 + 3 days", "09:00 + 90 min", "192.0.2.1/24", "0xFFFF", "[1.25, 2.5]", "text(\"1234.5\")", "[[1.5,2],[3,4]]" })
        {
            var line = Line(source); Assert.Null(line.Error);
            Assert.Equal(line.Display, ResultFormatter.Format(line, style));
        }
    }
    [Fact]
    public void DomainPrecisionOutranksThePreferenceAndValuesStayExact()
    {
        SheetValue approximate = new NumericValue(new Rational(1, 3)) { DisplayDecimalPlaces = 4 };
        Assert.Equal("0.3333", ResultFormatter.Format(approximate, new(1)));
        // A sheet rounding produces an exact value; the display preference then applies to it like any other.
        Assert.Equal("1.2", Show("1.23456789 to 4 decimals", new(1)));
        var line = Line("1/3");
        Assert.Equal("0.33", ResultFormatter.Format(line, new(2)));
        Assert.Equal("1/3", line.Display);
        Assert.Equal("1/3", line.Value!.Value.CopyText);
        Assert.Equal(new Rational(1, 3), line.Value!.Value.Scalar);
    }
    [Fact]
    public void ErrorsAndDeclarationsAreNotFormatted()
    {
        var results = SheetEvaluator.Evaluate("f(x) = x * 12345.678\nunknownThing + 1", context: Context);
        Assert.Null(results[0].Value);
        Assert.Equal(results[0].Display, ResultFormatter.Format(results[0], new(2, Period)));
        Assert.NotNull(results[1].Error);
        Assert.Equal(results[1].Display, ResultFormatter.Format(results[1], new(2, Period)));
    }
    [Theory]
    [InlineData("en-US", ",", '.')]
    [InlineData("de-DE", ".", ',')]
    [InlineData("fr-FR", NumberStyle.Space, ',')]
    [InlineData("ja-JP", ",", '.')]
    [InlineData("ro-RO", ".", ',')]
    public void SystemStyleReadsTheRegionalFormat(string culture, string group, char separator)
    {
        var style = NumberStyle.FromId("system", CultureInfo.GetCultureInfo(culture));
        Assert.Equal(group, style.GroupSeparator); Assert.Equal(separator, style.DecimalSeparator);
    }
    [Fact]
    public void InvalidStylesAndPrecisionAreRejected()
    {
        Assert.Throws<ArgumentException>(() => new NumberStyle(",", ','));
        Assert.Throws<ArgumentException>(() => new NumberStyle("_", '.'));
        Assert.Throws<ArgumentException>(() => new NumberStyle("", ';'));
        Assert.Throws<ArgumentException>(() => NumberStyle.FromId("roman", CultureInfo.InvariantCulture));
        Assert.Throws<ArgumentException>(() => ResultFormatter.Format(Line("1"), new(ResultFormat.MaxDecimalPlaces + 1)));
        Assert.Equal("1,234.56", Comma.Example);
    }
}
