using Calc.Core;
using NodaTime;

namespace Calc.Core.Tests;

public class CountdownTests
{
    private static readonly EvaluationContext Clock = new(new(2026, 10, 30), new DateTimeOffset(2026, 10, 30, 12, 0, 0, TimeSpan.Zero),
        LocalZone: new(DateTimeZone.Utc, "test UTC"));
    [Theory]
    [InlineData("until 13:30", "1 h 30 min")]
    [InlineData("until 09:00", "0 s")]
    [InlineData("until 12:00", "0 s")]
    [InlineData("until 24:00", "12 h")]
    [InlineData("until today", "0 s")]
    [InlineData("until tomorrow", "12 h")]
    [InlineData("until monday", "2 day 12 h")]
    [InlineData("until friday", "0 s")]
    [InlineData("until next friday", "6 day 12 h")]
    [InlineData("until last monday", "0 s")]
    [InlineData("until Christmas", "55 day 12 h")]
    [InlineData("until new year", "62 day 12 h")]
    [InlineData("until New Years Day", "62 day 12 h")]
    [InlineData("until 25 dec", "55 day 12 h")]
    [InlineData("until dec 25", "55 day 12 h")]
    [InlineData("days until christmas", "56 day")]
    [InlineData("until 2026-11-01", "1 day 12 h")]
    [InlineData("until 2026-10-30 13:00", "1 h")]
    [InlineData("until 2026-10-30T13:00Z", "1 h")]
    [InlineData("until 2026-10-30T13:00+01:00", "0 s")]
    [InlineData("until 2026-10-30 22:00 Tokyo", "1 h")]
    [InlineData("until 2026-10-30 22:00 in Tokyo", "1 h")]
    [InlineData("until 22:00 in Tokyo in min", "60 min")]
    [InlineData("until now in Tokyo", "0 s")]
    [InlineData("until 2026-10-30 in Tokyo", "0 s")]
    [InlineData("until 2026-10-30 15:00 London", "3 h")]
    [InlineData("until tomorrow at 13:00", "1 day 1 h")]
    [InlineData("until today+2day", "1 day 12 h")]
    [InlineData("until Christmas 18:00", "56 day 6 h")]
    [InlineData("until 2026-10-30T12:00:00.0000001Z", "0.0000001 s")]
    [InlineData("until 2020-01-01", "0 s")]
    [InlineData("until 13:00 in min", "60 min")]
    [InlineData("(until 13:00) * 2", "2 h")]
    [InlineData("(until 13:00) / 7", "(8 min + (240/7) s)")]
    [InlineData("deadline=tomorrow\nuntil deadline", "12 h")]
    [InlineData("f(d)=until d\nf(2026-11-01)", "1 day 12 h")]
    [InlineData("f()=until Christmas\nf()", "55 day 12 h")]
    [InlineData("a=until 13:00\nb=until 15:00\nsum", "4 h")]
    [InlineData("a=until 2026-11-01\nb=until 2026-11-02\naverage", "2 day")]
    [InlineData("until 2026-10-30T12:00:01.555Z to 2 decimals", "1.56 s")]
    [InlineData("15:00 in Tokyo", "2026-10-31T00:00:00+09:00")]
    [InlineData("2026-10-30T15:00 in Tokyo", "2026-10-31T00:00:00+09:00")]
    [InlineData("2026-10-30 15:00 local in Tokyo", "2026-10-31T00:00:00+09:00")]
    public void ExactCountdownAndRelatedLocalZoneExamples(string source, string expected)
    {
        var answers = SheetEvaluator.Evaluate(source, context: Clock); Assert.All(answers, answer => Assert.Null(answer.Error));
        var result = answers[^1]; Assert.Equal(expected, result.Display);
        var pasted = SheetEvaluator.Evaluate(result.Display, context: Clock)[0]; Assert.Null(pasted.Error);
        if (result.Value!.Value.Kind == SheetValueKind.Number)
        { Assert.Equal(result.Value.Value.Exact, pasted.Value!.Value.Exact); Assert.Equal(result.Value.Value.Unit?.Dimension, pasted.Value.Value.Unit?.Dimension); }
        else Assert.Equal(result.Value.Value.Moment.Instant, pasted.Value!.Value.Moment.Instant);
    }
    [Fact]
    public void PublishedChristmasExampleHasAnIndependentElapsedTimeDerivation()
    {
        var context = Clock with { Today = new(2026, 10, 15), Now = new(2026, 10, 15, 20, 40, 0, TimeSpan.Zero) };
        Assert.Equal("71 day", SheetEvaluator.Evaluate("days until christmas", context: context)[0].Display);
        Assert.Equal("70 day 3 h 20 min", SheetEvaluator.Evaluate("until Christmas", context: context)[0].Display);
    }
    [Theory]
    [InlineData("until 1")]
    [InlineData("until 1month")]
    [InlineData("until 1h")]
    [InlineData("until 50%")]
    [InlineData("until")]
    [InlineData("until 2026-03-29 02:30 Budapest")]
    [InlineData("until 2026-10-25 02:30 Budapest")]
    [InlineData("until 2011-12-30 Pacific/Apia")]
    [InlineData("until 31 feb")]
    [InlineData("until 29 feb 2025")]
    [InlineData("until 9999-12-31T24:00Z")]
    public void InvalidEndpointsAndSkippedOrAmbiguousWallTimesFail(string source)
    {
        var result = SheetEvaluator.Evaluate(source, context: Clock)[^1]; Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
    [Fact]
    public void ExpiredFixedDeadlineRetainsClockDependencyWithoutSecondTicks()
    {
        var session = new SheetEvaluationSession(); const string source = "until 2026-10-30T12:00:01Z\n2+2";
        var active = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock);
        Assert.True(active.UsesCurrentInstant); Assert.True(active.RequiresSecondRefresh); Assert.False(active.UsesCurrentDate); Assert.False(active.UsesLocalTimeZone);
        var expired = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock with { Now = Clock.Now!.Value.AddSeconds(2) });
        Assert.Equal("0 s", expired.Results[0].Display); Assert.True(expired.UsesCurrentInstant); Assert.False(expired.RequiresSecondRefresh); Assert.Equal(1, session.LastStatistics.ReusedResults);
        var cached = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock with { Now = Clock.Now.Value.AddSeconds(2) });
        Assert.False(cached.RequiresSecondRefresh); Assert.Equal(2, session.LastStatistics.ReusedResults);
        var rollback = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock);
        Assert.Equal("1 s", rollback.Results[0].Display); Assert.True(rollback.RequiresSecondRefresh);
        Assert.Contains(expired.Results[0].Explanation, step => step.Operation == "countdown" && step.Assumption!.Contains("Expired"));
    }
    [Fact]
    public void MidnightAndAnnualOrWeekdayOccurrencesUseDateSnapshots()
    {
        var session = new SheetEvaluationSession(); const string source = "until 01:00\nuntil Christmas\n2+2";
        var expired = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock);
        Assert.True(expired.UsesCurrentDate); Assert.True(expired.UsesLocalTimeZone);
        var midnight = Clock with { Today = new(2026, 10, 31), Now = new(2026, 10, 31, 0, 0, 0, TimeSpan.Zero) };
        Assert.Equal("1 h", session.Evaluate(source, context: midnight)[0].Display); Assert.True(session.LastStatistics.ReusedResults > 0);
        var christmasDay = Clock with { Today = new(2026, 12, 25), Now = new(2026, 12, 25, 12, 0, 0, TimeSpan.Zero) };
        Assert.Equal("0 s", session.Evaluate("until Christmas", context: christmasDay)[0].Display);
        Assert.Equal("363 day 12 h", session.Evaluate("until Christmas", context: christmasDay with { Today = new(2026, 12, 26), Now = new(2026, 12, 26, 12, 0, 0, TimeSpan.Zero) })[0].Display);
        Assert.Equal("2028-02-29", SheetEvaluator.Evaluate("29 feb", context: Clock)[0].Display);
        Assert.Equal("1904-02-29", SheetEvaluator.Evaluate("29 feb", context: Clock with { Today = new(1896, 3, 1) })[0].Display);
        Assert.NotNull(SheetEvaluator.Evaluate("29 feb", context: Clock with { Today = new(9997, 1, 1) })[0].Error);
    }
    [Fact]
    public void DstElapsedIntervalsAndStrictLocalResolutionUseInjectedRules()
    {
        var zone = new LocalZoneSnapshot(DateTimeZoneProviders.Tzdb["America/New_York"], DateTimeZoneProviders.Tzdb.VersionId);
        var spring = Clock with { Today = new(2026, 3, 8), Now = new(2026, 3, 8, 5, 0, 0, TimeSpan.Zero), LocalZone = zone };
        Assert.Equal("23 h", SheetEvaluator.Evaluate("until tomorrow", context: spring)[0].Display);
        Assert.Equal("2 h", SheetEvaluator.Evaluate("until 03:00", context: spring)[0].Display);
        Assert.NotNull(SheetEvaluator.Evaluate("until 02:30", context: spring)[0].Error);
        var autumn = spring with { Today = new(2026, 11, 1), Now = new(2026, 11, 1, 4, 0, 0, TimeSpan.Zero) };
        Assert.Equal("1 day 1 h", SheetEvaluator.Evaluate("until tomorrow", context: autumn)[0].Display);
        Assert.NotNull(SheetEvaluator.Evaluate("until 01:30", context: autumn)[0].Error);
        Assert.Equal("1 h 30 min", SheetEvaluator.Evaluate("until 01:30 local earlier", context: autumn)[0].Display);
        Assert.Equal("2 h 30 min", SheetEvaluator.Evaluate("until 01:30 local later", context: autumn)[0].Display);
        Assert.Equal("2 h 30 min", SheetEvaluator.Evaluate("until 01:30 in local later", context: autumn)[0].Display);
    }
    [Fact]
    public void LocalRuleChangesAndMissingSnapshotsInvalidateOnlyReaders()
    {
        var session = new SheetEvaluationSession(); const string source = "until 2026-10-30T14:00\nnow in unix\n2+2";
        var missing = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock with { LocalZone = null });
        Assert.True(missing.UsesLocalTimeZone); Assert.NotNull(missing.Results[0].Error);
        var a = session.Evaluate(source, context: Clock); Assert.Equal("2 h", a[0].Display); Assert.Equal(2, session.LastStatistics.ReusedResults);
        var b = session.Evaluate(source, context: Clock with { LocalZone = new(DateTimeZone.ForOffset(Offset.FromHours(1)), "test UTC+1") });
        Assert.Equal("1 h", b[0].Display); Assert.Equal(2, session.LastStatistics.ReusedResults);
        var noNow = session.EvaluateWithFunctions("until 2026-11-01", FunctionLibrary.Empty, [], context: Clock with { Now = null });
        Assert.NotNull(noNow.Results[0].Error); Assert.True(noNow.UsesCurrentInstant); Assert.False(noNow.RequiresSecondRefresh);
        Assert.Equal("1 day 12 h", session.Evaluate("until 2026-11-01", context: Clock)[0].Display);
    }
    [Fact]
    public void SavedFunctionsOnlyRefreshWhenCalledAndDeclaredNamesRemainNames()
    {
        var update = FunctionUpdate.Prepare("f(d)=until d\ng()=f(2026-11-01)", FunctionLibrary.Empty, []);
        var session = new SheetEvaluationSession();
        Assert.False(session.EvaluateWithFunctions("2+2", update.Library, [], context: Clock).UsesCurrentInstant);
        var active = session.EvaluateWithFunctions("g()\n2+2", update.Library, [], context: Clock); Assert.True(active.RequiresSecondRefresh);
        Assert.Contains(active.Results[0].Explanation, step => step.Operation == "countdown" && step.Assumption!.Contains("2026-11-01T00:00:00Z") && step.Assumption.Contains("test UTC"));
        var next = session.EvaluateWithFunctions("g()\n2+2", update.Library, [], context: Clock with { Now = Clock.Now!.Value.AddSeconds(1) });
        Assert.Equal("1 day 11 h 59 min 59 s", next.Results[0].Display); Assert.Equal(1, session.LastStatistics.ReusedResults);
        var names = SheetEvaluator.Evaluate("until=7\nuntil+1\nChristmas=9\nChristmas+1\nfriday=3\nfriday+1\nuntil(x)=x+2\nuntil(4)\nf(christmas)=christmas+1\nf(5)", context: Clock);
        Assert.Equal("8", names[1].Display); Assert.Equal("10", names[3].Display); Assert.Equal("4", names[5].Display); Assert.Equal("6", names[7].Display); Assert.Equal("6", names[9].Display);
    }
    [Fact]
    public void ExactPositiveCountdownsMatchIndependentTickSubtraction()
    {
        var random = new Random(9031);
        for (var trial = 0; trial < 500; trial++)
        {
            var ticks = random.NextInt64(-TimeSpan.TicksPerDay, TimeSpan.TicksPerDay * 100);
            var target = Clock.Now!.Value.AddTicks(ticks);
            var result = SheetEvaluator.Evaluate("until " + target.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", System.Globalization.CultureInfo.InvariantCulture), context: Clock)[0];
            Assert.Null(result.Error); Assert.Equal(new Rational(Math.Max(0, ticks), TimeSpan.TicksPerSecond), result.Value!.Value.Exact.Rational);
        }
    }
    [Fact]
    public void CancelledCountdownDoesNotReplaceThePreviousClockCache()
    {
        var session = new SheetEvaluationSession(); session.Evaluate("until tomorrow", context: Clock); var before = session.LastStatistics;
        using var canceled = new CancellationTokenSource(); canceled.Cancel();
        Assert.Throws<OperationCanceledException>(() => session.Evaluate("until Christmas", canceled.Token, Clock)); Assert.Equal(before, session.LastStatistics);
        Assert.Equal("12 h", session.Evaluate("until tomorrow", context: Clock)[0].Display); Assert.Equal(1, session.LastStatistics.ReusedResults);
    }
    [Fact]
    public void CapturedBclRulesResolveSyntheticDstAndVersionChangesWithoutReadingTheOsZone()
    {
        static TimeZoneInfo Make(int baseHours)
        {
            var start = TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 3, 2, DayOfWeek.Sunday);
            var end = TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 11, 1, DayOfWeek.Sunday);
            var rule = TimeZoneInfo.AdjustmentRule.CreateAdjustmentRule(new DateTime(2026, 1, 1), new DateTime(2026, 12, 31), TimeSpan.FromHours(1), start, end);
            return TimeZoneInfo.CreateCustomTimeZone("test-local", TimeSpan.FromHours(baseHours), "test", "standard", "summer", [rule]);
        }
        var local = LocalZoneSnapshot.FromTimeZoneInfo(Make(-5));
        Assert.Equal(local.Version, LocalZoneSnapshot.FromTimeZoneInfo(Make(-5)).Version);
        Assert.NotEqual(local.Version, LocalZoneSnapshot.FromTimeZoneInfo(Make(-4)).Version);
        var context = Clock with { Today = new(2026, 3, 8), Now = new(2026, 3, 8, 5, 0, 0, TimeSpan.Zero), LocalZone = local };
        Assert.Equal("23 h", SheetEvaluator.Evaluate("until tomorrow", context: context)[0].Display);
        Assert.NotNull(SheetEvaluator.Evaluate("until 02:30", context: context)[0].Error);
    }
}
