using System.Numerics;
using Calc.Core;
using static Calc.Core.Tests.Practical;

namespace Calc.Core.Tests;

public class HomeEstimateTests
{
    [Theory]
    [InlineData("paint 40 m2 2 coats", "8 L")]
    [InlineData("tiles 12 m2", "13.2 m^2")]
    [InlineData("concrete 2 m3", "184")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Show(source));

    private static Rational Ceiling(Rational value) => new(BigInteger.Divide(value.Numerator + value.Denominator - 1, value.Denominator), 1);

    [Fact]
    public void PaintIsAreaTimesCoatsOverCoverageWithDisclosedDefaults()
    {
        Assert.Equal(R("8"), InOwnUnit(Value("paint 40 m2 2 coats")));
        Assert.Equal("4 L", Show("paint 40 m2"));
        Assert.Equal("4 L", Show("paint 40 m2 1 coat"));
        Assert.Equal("15 L", Show("paint 40 m2 3 coats at 8 m2/l"));
        // 40 m2 * 2 coats / 12 m2 per litre = 20/3 L: the exact value is kept, the display shows two decimals.
        var third = Value("paint 40 m2 2 coats at 12 m2/l");
        Assert.Equal(R("40") * R("2") / R("12"), InOwnUnit(third)); Assert.Equal("6.67 L", third.Display);
        var step = Last("paint 40 m2 2 coats").Explanation[^1];
        Assert.Contains("10 m2 per litre", step.Assumption!); Assert.Contains("2 coats at 10 m2/l (default)", step.Assumption!); Assert.Contains("no allowance for openings", step.Assumption!);
        Assert.Contains("at 12 m2/l", Last("paint 40 m2 2 coats at 12 m2/l").Explanation[^1].Assumption!);
        Assert.DoesNotContain("(default)", Last("paint 40 m2 2 coats at 12 m2/l").Explanation[^1].Assumption!);
    }
    [Fact]
    public void PaintAcceptsAreaAndCoverageInOtherUnits()
    {
        // 400 ft2 = 400 * 0.3048^2 m2 exactly.
        Assert.Equal(R("400") * R("0.3048") * R("0.3048") * R("2") / R("10"), InOwnUnit(Value("paint 400 ft2 2 coats")));
        var coverage = R("120") * R("0.3048") * R("0.3048") / R("0.003785411784");   // 120 ft2 per US gallon, in m2 per m3
        Assert.Equal(R("40") * R("2") / coverage * R("1000"), InOwnUnit(Value("paint 40 m2 2 coats at 120 ft2/gal")));
        Assert.Equal("40 L", Show("paint 4000000 cm2"));
        Assert.Equal(Show("paint 40 m2 2 coats"), Show("paint (40 m2) (2) coats"));
        Assert.Equal(Show("paint 40 m2 2 coats"), Show("paint 0.004 ha 2 coats"));
        Assert.Equal("8000 mL", Show("paint 40 m2 2 coats in ml"));
    }
    [Theory]
    [InlineData("paint 40 m2 0 coats")][InlineData("paint 40 m2 2.5 coats")][InlineData("paint 40 m2 21 coats")][InlineData("paint 40 m2 -1 coats")][InlineData("paint 0 m2")]
    [InlineData("paint 40 m2 2 coats at 0 m2/l")][InlineData("paint 40 m2 2 coats at 12 m")][InlineData("paint 40 m 2 coats")][InlineData("paint 40 kg")][InlineData("paint -40 m2")]
    public void PaintInputsAreBounded(string source) => Assert.Null(Last(source).Value);

    [Fact]
    public void TilesAddWasteAndKeepTheAreaUnit()
    {
        Assert.Equal(R("12") * R("1.1"), InOwnUnit(Value("tiles 12 m2")));
        Assert.Equal("13.8 m^2", Show("tiles 12 m2 15% waste")); Assert.Equal("13.8 m^2", Show("tiles 12 m2 waste 15%")); Assert.Equal("13.8 m^2", Show("tiles 12 m2 with 15% waste"));
        Assert.Equal("13.8 m^2", Show("tiles 12 m2 15 percent waste"));
        Assert.Equal("12 m^2", Show("tiles 12 m2 0% waste")); Assert.Equal("24 m^2", Show("tiles 12 m2 100% waste")); Assert.Equal("13.26 m^2", Show("tiles 12 m2 10.5% waste"));
        var feet = Value("tiles 129 ft2");
        Assert.Equal(R("129") * R("1.1"), InOwnUnit(feet)); Assert.Equal("141.9 ft^2", feet.Display);
        Assert.Equal(R("129") * R("0.3048") * R("0.3048") * R("1.1"), Canonical(feet));
        Assert.Equal(R("12") * R("1.1") / (R("0.3048") * R("0.3048")), InOwnUnit(Value("tiles 12 m2 in ft2")));
        Assert.Equal(R("132000"), InOwnUnit(Value("tiles 120000 cm2")));
        var step = Last("tiles 12 m2").Explanation[^1].Assumption!;
        Assert.Contains("default waste 10%", step); Assert.Contains("used 10% waste (default)", step); Assert.Contains("whole-tile counts", step);
        Assert.Contains("used 15% waste", Last("tiles 12 m2 15% waste").Explanation[^1].Assumption!);
    }
    [Theory]
    [InlineData("tiles 12 m2 101% waste")][InlineData("tiles 12 m2 15 waste")][InlineData("tiles 0 m2")][InlineData("tiles -12 m2")][InlineData("tiles 12 m")][InlineData("tiles 12 m3")][InlineData("tiles 12 m2 -5% waste")]
    public void TileInputsAreBounded(string source) => Assert.Null(Last(source).Value);

    [Fact]
    public void ConcreteBagsAreVolumeTimesDensityOverBagMassRoundedUp()
    {
        Assert.Equal(R("2") * R("2300") / R("25"), Canonical(Value("concrete 2 m3")));   // exactly 184 bags
        Assert.Equal("92", Show("concrete 1 m3"));
        Assert.Equal("185", Show("concrete 2.0001 m3")); Assert.Equal("184", Show("concrete 1.99999 m3"));
        Assert.Equal("1", Show("concrete 0.001 m3")); Assert.Equal("1", Show("concrete 0.0108 m3")); Assert.Equal("2", Show("concrete 0.0109 m3"));
        Assert.Equal("115", Show("concrete 2 m3 40 kg bags")); Assert.Equal("192", Show("concrete 2 m3 at 2400 kg/m3")); Assert.Equal("120", Show("concrete 2 m3 40 kg bags at 2400 kg/m3"));
        Assert.Equal("184", Show("concrete 2000 L")); Assert.Equal("184", Show("concrete 2000000 cm3"));
        // Another unit system, computed with exact definitions and an independent ceiling.
        Assert.Equal(Ceiling(R("2") * R("0.9144") * R("0.9144") * R("0.9144") * R("2300") / R("25")), Canonical(Value("concrete 2 yd3")));
        Assert.Equal("141", Show("concrete 2 yd3"));
        Assert.Equal(Ceiling(R("70") * R("0.3048") * R("0.3048") * R("0.3048") * R("2300") / R("25")), Canonical(Value("concrete 70 ft3")));
        Assert.Equal(Ceiling(R("2") * R("2300") / (R("50") * R("0.45359237"))), Canonical(Value("concrete 2 m3 50 lb bags")));
        var step = Last("concrete 2 m3").Explanation[^1].Assumption!;
        Assert.Contains("2300 kg/m3", step); Assert.Contains("25 kg bags", step); Assert.Contains("(defaults)", step); Assert.Contains("rounded up", step); Assert.Contains("4600 kg of concrete", step);
    }
    [Theory]
    [InlineData("concrete 0 m3")][InlineData("concrete -2 m3")][InlineData("concrete 2 m2")][InlineData("concrete 2 m3 0 kg bags")][InlineData("concrete 2 m3 40 m bags")][InlineData("concrete 2 m3 at 0 kg/m3")][InlineData("concrete 2 m3 at 2400 kg")]
    public void ConcreteInputsAreBounded(string source) => Assert.Null(Last(source).Value);

    [Fact]
    public void SentencesAreNotEstimatesWithoutTheirCompleteGrammar()
    {
        foreach (var prose in new[] { "paint", "tiles", "concrete", "paint the wall", "tiles are cold", "concrete jungle", "paint and tiles and concrete" })
        { var result = Last(prose); Assert.Null(result.Value); Assert.Null(result.Error); }
        Assert.Equal("40", Show("paint 40")); Assert.Equal("12", Show("tiles 12")); Assert.Equal("2", Show("concrete 2"));
        Assert.Equal("40 m^2", Show("walls 40 m2"));
        Assert.Equal("6", Show("paint = 3\npaint * 2")); Assert.Equal("6", Show("tiles = 3\ntiles + tiles")); Assert.Equal("6", Show("concrete = 3\nconcrete * 2"));
        Assert.Null(Last("tiles = 5\ntiles 12 m2").Value); Assert.Null(Last("paint = 5\npaint 40 m2 2 coats").Value);
        Assert.Equal("8 L", Show("coats = 5\nwaste = 3\npaint 40 m2 2 coats"));
        Assert.Equal("13.2 m^2", Show("waste = 3\ntiles 12 m2"));
        Assert.Equal("13.8 m^2", Show("w = 15%\ntiles 12 m2 w waste"));
        Assert.Equal("8 L", Show("n = 2\npaint 40 m2 n coats"));
    }
    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("cover(a, n) = paint a n coats\nflooring(a, w) = tiles a w waste\nbags(v) = concrete v\nmix(v, b, d) = concrete v b bags at d", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("cover(40 m2, 2)\nflooring(12 m2, 15%)\nbags(2 m3)\nmix(2 m3, 40 kg, 2400 kg/m3)", update.Library, [], context: Clock).Results;
        Assert.Equal(["8 L", "13.8 m^2", "184", "120"], results.Select(r => r.Display));
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
        var session = new SheetEvaluationSession();
        var evaluated = session.EvaluateWithFunctions("paint 40 m2 2 coats\ntiles 12 m2\nconcrete 2 m3", FunctionLibrary.Empty, [], context: Clock);
        Assert.False(evaluated.UsesCurrentDate); Assert.False(evaluated.UsesCurrentInstant); Assert.False(evaluated.RequiresSecondRefresh);
    }
}
