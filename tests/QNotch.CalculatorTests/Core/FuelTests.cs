using Calc.Core;
using static Calc.Core.Tests.Practical;

namespace Calc.Core.Tests;

public class FuelTests
{
    private const string UsGallon = "0.003785411784", UkGallon = "0.00454609", Mile = "1609.344";
    [Theory]
    [InlineData("6.5 l/100km in mpg", "36.19 mpg")]
    [InlineData("450 km at 6.5 l/100km", "29.25 L")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Show(source));

    [Fact]
    public void BareMpgIsTheUsGallonAndUkIsExplicit()
    {
        // 6.5 L per 100 km is 6.5e-3 m3 per 1e5 m; economy is the reciprocal, in miles per gallon.
        var perMetre = R("0.0065") / R("100000");
        var usMpg = R("1") / perMetre / (R(Mile) / R(UsGallon));
        var ukMpg = R("1") / perMetre / (R(Mile) / R(UkGallon));
        Assert.Equal("36.19 mpg", Show("6.5 l/100km in mpg"));
        Assert.Equal(usMpg, InOwnUnit(Value("6.5 l/100km in mpg")));
        Assert.Equal("43.46 mpg uk", Show("6.5 l/100km in mpg uk"));
        Assert.Equal(ukMpg, InOwnUnit(Value("6.5 l/100km in mpg uk")));
        // The same distance per litre: the imperial gallon is larger by 4.54609 / 3.785411784, so UK mpg is that much larger.
        Assert.Equal(R(UkGallon) / R(UsGallon), ukMpg / usMpg);
        Assert.Equal("36.19 mpg", Show("6.5 l/100km in mpg us"));
        Assert.Equal("43.46 mpg uk", Show("6.5 l/100km in mpg imp"));
    }

    [Fact]
    public void ConsumptionAndEconomyAreReciprocalBothWays()
    {
        // 36 mpg US: litres per 100 km = 100 km * 3.785411784 L / (36 * 1.609344 km).
        var expected = R("100000") * R(UsGallon) / (R("36") * R(Mile));
        Assert.Equal(expected, Canonical(Value("36 mpg in l/100km")) * R("100000"));
        Assert.Equal("6.53 l/100km", Show("36 mpg in l/100km"));
        Assert.Equal(R("36"), InOwnUnit(Value("(36 mpg in l/100km) in mpg")));
        Assert.Equal(R("7.5"), InOwnUnit(Value("(7.5 l/100km in mpg uk) in l/100km")));
        // km/l is the same family as mpg: 12.5 km/l is 8 l/100km.
        Assert.Equal("8 l/100km", Show("12.5 km/l in l/100km"));
        Assert.Equal("12.5 km/L", Show("8 l/100km in km/l"));
        Assert.True(Fails("0 mpg in l/100km")); Assert.True(Fails("-5 l/100km in mpg"));
        Assert.True(Fails("6.5 l/100km in kg")); Assert.True(Fails("6.5 l/100km in m"));
    }

    [Fact]
    public void DistanceAtConsumptionGivesFuelVolumeInTheMatchingVolumeUnit()
    {
        Assert.Equal(R("450") * R("6.5") / R("100"), InOwnUnit(Value("450 km at 6.5 l/100km")));
        // 100 miles at 25 mpg US = 4 US gallons.
        var gallons = Value("100 mi at 25 mpg");
        Assert.Equal(R("4") * R(UsGallon), Canonical(gallons));
        var imperial = Value("100 mi at 25 mpg uk");
        Assert.Equal(R("4") * R(UkGallon), Canonical(imperial));
        Assert.Equal(R("450") / R("15"), InOwnUnit(Value("450 km at 15 km/l")));
        Assert.Equal("29.25 L", Show("450 km at 6.5 L/100km"));
        Assert.True(Fails("450 kg at 6.5 l/100km")); Assert.True(Fails("0 km at 6.5 l/100km"));
        var step = Last("450 km at 6.5 l/100km").Explanation[^1].Assumption!;
        Assert.Contains("mpg is the US gallon", step); Assert.Contains("mpg uk the imperial gallon", step);
    }

    [Fact]
    public void FuelPriceGivesMoneyThroughExistingArithmetic()
    {
        // 29.25 L at 2 USD per litre.
        var cost = Last("450 km at 6.5 l/100km at 2 USD/L");
        Assert.True(cost.Error is null, cost.Error);
        Assert.Equal("58.5 USD", cost.Display);
    }

    [Fact]
    public void ConversionExplanationsStateTheGallonConvention()
    {
        Assert.Contains("US gallon", Last("6.5 l/100km in mpg").Explanation[^1].Assumption!);
        Assert.Contains("imperial gallon", Last("6.5 l/100km in mpg uk").Explanation[^1].Assumption!);
    }

    [Fact]
    public void TimeDifferenceIsSignedAndUsesTheEvaluationInstantSnapshot()
    {
        // 2026-10-31: London is on GMT (BST ended on 25 October), Tokyo is UTC+9 all year, New York is UTC-4 until 1 November.
        Assert.Equal("9 h", Show("time difference London to Tokyo"));
        Assert.Equal("-(9 h)", Show("time difference Tokyo to London"));  // the existing negative compound-duration display
        Assert.Equal("9 h", Show("time difference from London to Tokyo"));
        Assert.Equal("4 h", Show("time difference New York to London"));
        var later = Clock with { Now = new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero), Today = new DateOnly(2026, 11, 2) };
        Assert.Equal("5 h", Show("time difference New York to London", later));
    }

    [Fact]
    public void DatedFormUsesTheOffsetsOnThatDateAndNeedsNoClock()
    {
        Assert.Equal("8 h", Show("time difference London to Tokyo on 2026-07-01"));
        Assert.Equal("9 h", Show("time difference London to Tokyo on 2026-12-01"));
        var session = new SheetEvaluationSession();
        var dated = session.EvaluateWithFunctions("time difference London to Tokyo on 2026-07-01", FunctionLibrary.Empty, [], context: Clock);
        Assert.False(dated.UsesCurrentInstant); Assert.False(dated.UsesCurrentDate);
        var undated = session.EvaluateWithFunctions("time difference London to Tokyo", FunctionLibrary.Empty, [], context: Clock);
        Assert.True(undated.UsesCurrentInstant);
        Assert.False(session.EvaluateWithFunctions("2 + 2", FunctionLibrary.Empty, [], context: Clock).UsesCurrentInstant);
    }

    [Fact]
    public void TimeDifferenceRefreshesWhenTheInstantCrossesATransition()
    {
        var session = new SheetEvaluationSession(); const string source = "time difference New York to London";
        Assert.Equal("4 h", session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock).Results[0].Display);
        var after = Clock with { Now = new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero) };
        Assert.Equal("5 h", session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: after).Results[0].Display);
    }

    [Fact]
    public void TimeDifferenceNeedsAContextAndKnownZones()
    {
        Assert.Contains("evaluation context", SheetEvaluator.Evaluate("time difference London to Tokyo")[0].Error!);
        Assert.Null(Last("time difference London to Nowhereville").Value);  // an unknown zone leaves the line as prose
        Assert.Contains("UTC offsets", Last("time difference London to Tokyo").Explanation[^1].Assumption!);
        Assert.Contains("12:00 UTC on the given date", Last("time difference London to Tokyo on 2026-07-01").Explanation[^1].Assumption!);
    }

    [Theory]
    [InlineData("time difference between teams")]
    [InlineData("time difference")]
    public void TimeAsProseKeepsItsMeaning(string source) => Assert.Null(Last(source).Value);

    [Fact]
    public void FuelWordsAndVariablesKeepTheirMeaning()
    {
        Assert.Equal("5", Show("mpg = 5\nmpg"));
        Assert.Equal("10", Show("mpg = 5\nmpg * 2"));
        Assert.Equal("7", Show("at = 7\nat"));
        Assert.Equal("6 h", Show("time = 3 h\ntime * 2"));
    }

    [Fact]
    public void SavedFunctionsParseCanonicalizeAndReload()
    {
        var update = FunctionUpdate.Prepare("tank(d) = d at 6.5 l/100km\neco(c) = c in mpg\ngap() = time difference London to Tokyo on 2026-07-01", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("tank(450 km)\neco(6.5 l/100km)\ngap()", update.Library, [], context: Clock).Results;
        Assert.Equal(["29.25 L", "36.19 mpg", "8 h"], results.Select(r => r.Display));
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
    }
}
