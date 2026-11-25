using Calc.Core;
using static Calc.Core.Tests.Practical;

namespace Calc.Core.Tests;

public class RunningTests
{
    [Theory]
    [InlineData("pace 5 km in 27 min", "5:24 /km · 8:41 /mi")]
    [InlineData("10 km at 5:30/km", "55:00")]
    [InlineData("race 10 km in 50 min to marathon", "≈ 3:50:01")]
    [InlineData("5 km / 27 min in km/h to 2 decimals", "11.11 km/h")]
    [InlineData("3 sets * 8 reps * 60 kg", "1440 kg")]
    public void PublishedReferenceExamples(string source, string display) => Assert.Equal(display, Show(source));

    [Fact]
    public void SpeedInKilometresPerHourIsExactAndNeedsNoNewSyntax()
    {
        Assert.Equal("(100/9) km/h", Show("5 km / 27 min in km/h"));
        Assert.Equal(R("100") / R("9"), InOwnUnit(Value("5 km / 27 min in km/h")));
        Assert.Equal(R("5000") / R("1620") * R("3.6"), InOwnUnit(Value("5 km / 27 min in km/h")));
    }
    [Fact]
    public void PaceIsTimePerDistanceShownPerKilometreAndPerMile()
    {
        var pace = Value("pace 5 km in 27 min");
        Assert.Equal(SheetValueKind.Practical, pace.Kind); Assert.Equal(PracticalKind.Pace, pace.Practical.Kind);
        Assert.Equal(R("1620") / R("5000"), Canonical(pace.Practical.Original!.Value));   // seconds per metre
        // 324 s/km * 1.609344 km/mi = 521.427456 s/mi, which is 8:41 to the second.
        Assert.Equal(R("324") * R("1.609344"), Canonical(pace.Practical.Original!.Value) * R("1609.344"));
        Assert.Equal("4:58 /km · 8:00 /mi", Show("pace 5 mi in 40 min"));
        Assert.Equal("5:30 /km · 8:51 /mi", Show("pace 5 km in 27:30"));
        Assert.Equal("5:30 /km · 8:51 /mi", Show("pace 5 km 27:30"));
        Assert.Equal("5:00 /km · 8:03 /mi", Show("pace 10 km in 50 min"));
        Assert.Equal("5:24 /km · 8:41 /mi", Show("pace 5000 m in 0:27:00"));
        Assert.Equal("5:24 /km · 8:41 /mi", Show("pace 5 km in 1620 s"));
        Assert.Equal("5:24 /km · 8:41 /mi", Show("pace 5 km in (20 + 7) min"));
        Assert.Equal(Show("pace 5 km in 27 min"), Show("pace (5 km in mi) in 27 min"));
        Assert.Equal("12:00 /km · 19:19 /mi", Show("pace 5 km in 1 h"));
        Assert.Equal("1:00:00 /km · 1:36:34 /mi", Show("pace 1 km in 1 h"));
    }
    [Fact]
    public void DistanceAtPaceGivesElapsedTimeInClockForm()
    {
        Assert.Equal("55:00", Show("10 km at 5:30/km"));
        Assert.Equal("55:00", Show("10 km at 5:30 per km"));
        Assert.Equal("55:00", Show("10 km at 5:30 /km"));
        Assert.Equal("8:00", Show("1 mi at 8:00/mi"));
        Assert.Equal("1:00:00", Show("10 km at 6:00/km"));
        Assert.Equal("1:45:29", Show("21.0975 km at 5:00/km"));
        Assert.Equal("22:30", Show("5 km at 4.5 min/km"));
        Assert.Equal("1:00:00", Show("1 km at 59:59.6/km"));
        Assert.Equal("5:00", Show("1000 m at 5:00/km"));
        Assert.Equal(Show("10 km at 5:30/km"), Show("(10 km in mi) at 5:30/km"));
        Assert.Equal(R("3300"), Canonical(Value("10 km at 5:30/km").Practical.Original!.Value));
        // Time over a pace is the inverse of pace from time: distance * pace = elapsed time.
        Assert.Equal(R("1620"), Canonical(Value("p = pace 5 km in 27 min\n5 km * p")));
        Assert.Equal("1620 s", Show("p = pace 5 km in 27 min\n5 km * p"));
    }
    [Fact]
    public void ClockTimesAreArithmeticOperandsWithTheirExactMagnitude()
    {
        Assert.Equal("6600 s", Show("10 km at 5:30/km\n10 km at 5:30/km\nsum"));
        Assert.Equal("3600 s", Show("10 km at 5:30/km\nprev + 5 min"));
        Assert.Equal(R("3599.6") / R("60"), InOwnUnit(Value("1 km at 59:59.6/km in min")));
        Assert.Equal(R("3599.6"), Canonical(Value("1 km at 59:59.6/km").Practical.Original!.Value));
        var step = Last("10 km at 5:30/km").Explanation[^1];
        Assert.Contains("distance * pace", step.Assumption!); Assert.Contains("m:ss below one hour", step.Assumption!);
        Assert.Contains(Last("10 km at 5:30/km\nprev + 5 min").Explanation, item => item.Operation == "practical magnitude");
    }
    [Fact]
    public void RiegelMatchesIndependentlyComputedConstants()
    {
        // 2^1.06 = 2.084931521682243 and 4.2195^1.06 were computed outside this repository (Python, double precision).
        Assert.Equal(R("2501.91782602"), Canonical(Value("race 5 km in 20 min to 10 km").Practical.Original!.Value));
        Assert.Equal(R("13800.5979998"), Canonical(Value("race 10 km in 50 min to marathon").Practical.Original!.Value));
        Assert.Equal(R("6619.20924321"), Canonical(Value("race 10 km in 50 min to half marathon").Practical.Original!.Value));
        Assert.Equal("≈ 41:42", Show("race 5 km in 20 min to 10 km"));
        Assert.Equal("≈ 1:50:19", Show("race 10 km in 50 min to half marathon"));
        Assert.True(Value("race 5 km in 20 min to 10 km").Practical.IsApproximate);
    }
    [Fact]
    public void RiegelHasItsStructuralIdentities()
    {
        // Same distance: exact and unmarked. Round trip: scaling out and back returns the input time.
        var same = Value("race 10 km in 50 min to 10 km");
        Assert.Equal("50:00", same.Display); Assert.False(same.Practical.IsApproximate);
        var back = Value("t = race 5 km in 20 min to 10 km\nrace 10 km in t to 5 km");
        var seconds = Canonical(back.Practical.Original!.Value);
        Assert.True(Math.Abs((double)seconds.Numerator / (double)seconds.Denominator - 1200) < 1e-6);
        Assert.Equal("≈ 20:00", back.Display);
        // The same distance expressed in other units, and the named targets, give the same prediction.
        var marathon = Canonical(Value("race 10 km in 50 min to marathon").Practical.Original!.Value);
        Assert.Equal(marathon, Canonical(Value("race 10000 m in 3000 s to 42.195 km").Practical.Original!.Value));
        Assert.Equal(marathon, Canonical(Value("race 10 km in 50:00 to 42195 m").Practical.Original!.Value));
        Assert.Equal(marathon, Canonical(Value("race 10 km in 0:50:00 to marathon").Practical.Original!.Value));
        Assert.Equal(Canonical(Value("race 10 km in 50 min to 5 km").Practical.Original!.Value), Canonical(Value("race 10 km in 50 min to 5k").Practical.Original!.Value));
        Assert.Equal(Canonical(Value("race 10 km in 50 min to 10 km").Practical.Original!.Value), Canonical(Value("race 10 km in 50 min to 10k").Practical.Original!.Value));
        Assert.Equal(Canonical(Value("race 10 km in 50 min to half marathon").Practical.Original!.Value), Canonical(Value("race 10 km in 50 min to half-marathon").Practical.Original!.Value));
        Assert.Equal(Canonical(Value("race 10 km in 50 min to 21.0975 km").Practical.Original!.Value), Canonical(Value("race 10 km in 50 min to half marathon").Practical.Original!.Value));
        // Longer distances take longer per kilometre.
        Assert.True((Canonical(Value("race 5 km in 20 min to 10 km").Practical.Original!.Value) - R("2400")).Numerator.Sign > 0);
        var explanation = Last("race 10 km in 50 min to marathon").Explanation[^1].Assumption!;
        Assert.Contains("T2 = T1 * (D2 / D1)^1.06", explanation); Assert.Contains("1.06", explanation); Assert.Contains("Riegel", explanation); Assert.StartsWith("Approximate input/result;", explanation);
    }
    [Theory]
    [InlineData("race 1 km in 5 min to 200 km")][InlineData("race 200 km in 20 h to 1 km")][InlineData("race 0 km in 50 min to marathon")][InlineData("race 10 km in 0 min to marathon")]
    [InlineData("race 10 km in 50 min to 0 km")][InlineData("race 10 kg in 50 min to marathon")][InlineData("race 10 km in 50 kg to marathon")][InlineData("race 10 km in 50 min to 5 kg")]
    [InlineData("pace 0 km in 27 min")][InlineData("pace 5 km in 0 min")][InlineData("pace 5 min in 27 km")][InlineData("pace -5 km in 27 min")]
    [InlineData("0 km at 5:30/km")][InlineData("10 min at 5:30/km")][InlineData("10 at 5:30/km")][InlineData("10 km at 0:00/km")]
    public void RunningInputsMustBePositiveWithTheRightDimensions(string source) => Assert.Null(Last(source).Value);
    [Theory]
    [InlineData("10 km at 5:75/km")][InlineData("pace 5 km in 27:75")][InlineData("pace 5 km in 1:75:00")][InlineData("10 km at 5:30/kg")]
    public void InvalidClockLiteralsAreNotPaces(string source) => Assert.Null(Last(source).Value);

    [Fact]
    public void PaceAndRaceWordsKeepTheirOrdinaryMeanings()
    {
        foreach (var prose in new[] { "pace", "race", "pace yourself", "race to the finish", "race car", "pace and race" })
        { var result = Last(prose); Assert.Null(result.Value); Assert.Null(result.Error); }
        Assert.Equal("2", Show("race car 2"));
        Assert.Equal("10", Show("pace = 5\npace * 2"));
        Assert.Equal("10", Show("race = 5\nrace + race"));
        Assert.Equal("5", Show("pace 5"));
        Assert.Equal("10 km", Show("race 10 km"));
        Assert.NotNull(Last("pace = 5\npace 5 km in 27 min").Error);
        Assert.Null(Last("marathon = 42\nrace 10 km in 50 min to marathon").Value);
    }
    [Fact]
    public void ExistingClockLiteralsAndRatesAreUnchanged()
    {
        // Regression anchors for behaviour that shares tokens with the new sentences (clock literals, "at" and "to").
        Assert.Equal("10:15", Show("9:30 + 45 min"));
        Assert.Equal("7 h", Show("from 9:00 to 16:00"));
        Assert.Equal("17:30", Show("5:30 pm"));
        Assert.Equal("30 min", Show("10:00 - 9:30"));
        Assert.Equal("05:30", Show("5:30"));
        Assert.Equal("05:30", Show("Meeting at 5:30"));
        Assert.Equal("2026-10-31T12:00:00", Show("2026-10-31 at 12:00"));
        Assert.Equal("1 h 6 min 40 s", Show("5 GB at 10 Mbit/s"));
        Assert.Equal("4 h 26 min 40 s", Show("100 GB at 50 Mbit/s"));
    }
    [Fact]
    public void SetsAndRepsAreDimensionlessCountsThatDoNotDisturbIdentifiers()
    {
        Assert.Equal(R("1440"), InOwnUnit(Value("3 sets * 8 reps * 60 kg")));
        Assert.Equal(R("3") * R("8") * R("60"), Canonical(Value("3 sets * 8 reps * 60 kg")));
        Assert.Equal("500 lb", Show("5 reps * 100 lb"));
        Assert.Equal("3", Show("3 sets")); Assert.Equal("1.5", Show("1.5 reps")); Assert.Equal("3", Show("3 set")); Assert.Equal("1", Show("1 rep"));
        Assert.Equal("1440 kg", Show("Bench press 3 sets * 8 reps * 60 kg"));
        Assert.Equal("1440 kg", Show("w = 60 kg\n3 sets * 8 reps * w"));
        Assert.Equal("8", Show("sets = 4\nsets * 2"));
        Assert.Equal("6", Show("set = 3\nset * 2"));
        Assert.NotNull(Last("reps = 5\n3 reps").Error);
        Assert.NotNull(Last("sets(2)").Error);
        Assert.Equal("2", Show("sets = 4\nreps = 2\n8 / sets"));
        Assert.Contains("Dimensionless count", Last("3 sets").Explanation[^1].Assumption!);
        var lines = SheetEvaluator.Evaluate("3 sets * 8 reps * 60 kg\n3 sets * 8 reps * 100 kg\nsum", default, Clock);
        Assert.Equal("3840 kg", lines[2].Display);
    }
    [Fact]
    public void RunningHelpersNeedNoClockOrTimerAndSaveAsFunctions()
    {
        var session = new SheetEvaluationSession();
        var evaluated = session.EvaluateWithFunctions("pace 5 km in 27 min\n10 km at 5:30/km\nrace 10 km in 50 min to marathon\n3 sets * 8 reps * 60 kg", FunctionLibrary.Empty, [], context: Clock);
        Assert.False(evaluated.UsesCurrentDate); Assert.False(evaluated.UsesCurrentInstant); Assert.False(evaluated.RequiresSecondRefresh);
        var update = FunctionUpdate.Prepare("eta(d) = d at 5:30/km\nforecast(t) = race 10 km in t to marathon\nsplit(t) = pace 5 km in t\nvolume(w) = 3 sets * 8 reps * w", FunctionLibrary.Empty, []);
        Assert.Equal(FunctionLibrary.LatestCatalogVersion, update.Library.MinimumCatalogVersion);
        var results = new SheetEvaluationSession().EvaluateWithFunctions("eta(10 km)\nforecast(50 min)\nsplit(27 min)\nvolume(60 kg)", update.Library, [], context: Clock).Results;
        Assert.Equal(["55:00", "≈ 3:50:01", "5:24 /km · 8:41 /mi", "1440 kg"], results.Select(r => r.Display));
        Assert.Equal(update.Library.Fingerprint, new FunctionLibrary(update.Library.Definitions).Fingerprint);
        Assert.Equal(1, new FunctionLibrary([new("plain", ["v"], "v + 1")]).MinimumCatalogVersion);
    }
}
