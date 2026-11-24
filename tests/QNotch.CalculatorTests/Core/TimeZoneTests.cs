using System.Text.Json;
using Calc.Core;
using NodaTime;
using NodaTime.TimeZones;

namespace Calc.Core.Tests;

public class TimeZoneTests
{
    private static readonly EvaluationContext Clock = new(new(2026, 10, 30), new DateTimeOffset(2026, 10, 30, 12, 0, 0, TimeSpan.Zero));
    [Theory]
    [InlineData("2026-10-30 15:00 London in Tokyo", "2026-10-31T00:00:00+09:00")]
    [InlineData("15:00 London in Tokyo", "2026-10-31T00:00:00+09:00")]
    [InlineData("2026-07-01 at 15:00 Europe/London in Asia/Tokyo", "2026-07-01T23:00:00+09:00")]
    [InlineData("2026-10-30T15:00Z in New York", "2026-10-30T11:00:00-04:00")]
    [InlineData("now", "2026-10-30T12:00:00Z")]
    [InlineData("now in New York", "2026-10-30T08:00:00-04:00")]
    [InlineData("now in unix", "1793361600")]
    [InlineData("unix 0", "1970-01-01T00:00:00Z")]
    [InlineData("unix -0.0000001", "1969-12-31T23:59:59.9999999Z")]
    [InlineData("unix 0.0000001 in unix", "0.0000001")]
    [InlineData("unix -0.5 in Tokyo", "1970-01-01T08:59:59.5+09:00")]
    [InlineData("1970-01-01T05:30:00+05:30 in unix", "0")]
    [InlineData("1970-01-01T00:00:00Z in Kathmandu", "1970-01-01T05:30:00+05:30")]
    [InlineData("2026-10-30 12:00 UTC in Kathmandu", "2026-10-30T17:45:00+05:45")]
    [InlineData("2026-10-30 12:00 UTC in Pacific/Chatham", "2026-10-31T01:45:00+13:45")]
    [InlineData("2026-10-30 24:00 UTC", "2026-10-31T00:00:00Z")]
    [InlineData("2026-03-08 01:59:59 New York + 1s", "2026-03-08T03:00:00-04:00")]
    [InlineData("2026-03-08 01:00 New York + 24h", "2026-03-09T02:00:00-04:00")]
    [InlineData("2026-03-07 12:00 New York + 1day", "2026-03-08T13:00:00-04:00")]
    [InlineData("2026-02-08 12:00 New York + 1month", "2026-03-08T12:00:00-04:00")]
    [InlineData("2026-03-08 03:00 New York - 2026-03-08 01:00 New York", "1 h")]
    [InlineData("2026-03-08 03:00 - 2026-03-08 01:00", "2 h")]
    [InlineData("2026-10-25 02:30 Budapest earlier in UTC", "2026-10-25T00:30:00Z")]
    [InlineData("2026-10-25 02:30 Budapest later in UTC", "2026-10-25T01:30:00Z")]
    [InlineData("2026-11-01 01:30 New York earlier in UTC", "2026-11-01T05:30:00Z")]
    [InlineData("2026-11-01 01:30 New York later in UTC", "2026-11-01T06:30:00Z")]
    [InlineData("2026-03-15 12:00 London in New York", "2026-03-15T08:00:00-04:00")]
    [InlineData("2026-10-30T12:00:00.1234567-02:30 in UTC", "2026-10-30T14:30:00.1234567Z")]
    [InlineData("2026-10-30 12:00 UTC+18:00 in UTC-18:00", "2026-10-29T00:00:00-18:00")]
    [InlineData("1890-01-01 12:00 Europe/Paris in unix", "-2524478961")]
    [InlineData("1890-01-01 12:00 Europe/Paris", "1890-01-01T12:00:00+00:09:21")]
    [InlineData("d=2026-10-30\nt=15:00\nz=d at t Europe/Budapest\nz in Tokyo", "2026-10-30T23:00:00+09:00")]
    [InlineData("f(d,t)=d at t Europe/Budapest\nf(2026-10-30,15:00) in UTC", "2026-10-30T14:00:00Z")]
    [InlineData("f()=now\ng()=f() in unix\ng()", "1793361600")]
    [InlineData("1970-01-01 at 00:00", "1970-01-01T00:00:00")]
    [InlineData("2024-01-31T23:00+1month", "2024-02-29T23:00:00")]
    [InlineData("2026-10-30T12:00Z + 0.0000001s", "2026-10-30T12:00:00.0000001Z")]
    public void PinnedZoneAndExactTimestampExamples(string source, string expected)
    {
        var answers = SheetEvaluator.Evaluate(source, context: Clock); Assert.All(answers, answer => Assert.Null(answer.Error));
        var result = answers[^1]; Assert.Equal(expected, result.Display);
        var pasted = SheetEvaluator.Evaluate(result.Display, context: Clock)[0]; Assert.Null(pasted.Error);
        Assert.Equal(result.Value!.Value.Kind, pasted.Value!.Value.Kind);
        if (result.Value.Value.Kind == SheetValueKind.ZonedMoment) Assert.Equal(result.Value.Value.Moment.Instant, pasted.Value.Value.Moment.Instant);
        else if (result.Value.Value.Kind == SheetValueKind.Number)
        { Assert.Equal(result.Value.Value.Exact, pasted.Value.Value.Exact); Assert.Equal(result.Value.Value.Unit?.Dimension, pasted.Value.Value.Unit?.Dimension); }
        else Assert.Equal(result.Value, pasted.Value);
    }
    [Theory]
    [InlineData("2026-03-29 02:30 Budapest")]
    [InlineData("2026-10-25 02:30 Budapest")]
    [InlineData("2026-03-08 02:30 New York")]
    [InlineData("2026-11-01 01:30 New York")]
    [InlineData("2011-12-30 12:00 Pacific/Apia")]
    [InlineData("2026-03-29 02:30 Budapest earlier")]
    [InlineData("2026-03-29 02:30 Budapest later")]
    [InlineData("2026-02-28 02:30 Budapest + 1month 1day")]
    [InlineData("2026-10-30 12:00 UTC+18:01")]
    [InlineData("2026-10-30 12:00 UTC+2:00")]
    [InlineData("2026-10-30T12:00+02:60")]
    [InlineData("2026-10-30T12:00+02:00:60")]
    [InlineData("2026-10-30T12:00+02:00:00.1")]
    [InlineData("2026-10-30 12:00 CST")]
    [InlineData("now in IST")]
    [InlineData("unix 0.00000001")]
    [InlineData("unix 10^1000")]
    [InlineData("unix 100%")]
    [InlineData("unix 1s")]
    [InlineData("2026-10-30 12:00 in Tokyo")]
    [InlineData("now + 1")]
    [InlineData("now + today")]
    [InlineData("now * 2")]
    [InlineData("now in h")]
    [InlineData("sqrt(now)")]
    [InlineData("-now")]
    [InlineData("2026-10-30T12:00Z - 2026-10-30T12:00")]
    [InlineData("9999-12-31T24:00 UTC")]
    [InlineData("0001-01-01T00:00+18:00")]
    [InlineData("9999-12-31T23:59:59.9999999Z+0.0000001s")]
    [InlineData("9999-12-31T23:59:59 UTC-18:00")]
    [InlineData("unix 253402300799.9999999 in UTC+18:00")]
    public void AmbiguityGapsTypeAndRangeErrorsAreExplicit(string source)
    {
        var result = SheetEvaluator.Evaluate(source, context: Clock)[^1]; Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
    [Fact]
    public void ContextMustBeProvidedAndErrorDependenciesRefresh()
    {
        var session = new SheetEvaluationSession(); const string source = "now in unix\n15:00 London in Tokyo\n2+2";
        var missing = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, []);
        Assert.True(missing.UsesCurrentInstant); Assert.True(missing.UsesCurrentDate); Assert.NotNull(missing.Results[0].Error); Assert.NotNull(missing.Results[1].Error);
        var fixedClock = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock);
        Assert.Equal("1793361600", fixedClock.Results[0].Display); Assert.Equal(1, session.LastStatistics.ReusedResults);
        var next = session.EvaluateWithFunctions(source, FunctionLibrary.Empty, [], context: Clock with { Now = Clock.Now!.Value.AddSeconds(1) });
        Assert.Equal("1793361601", next.Results[0].Display); Assert.Equal(2, session.LastStatistics.ReusedResults);
        var midnight = session.Evaluate(source, context: Clock with { Today = Clock.Today!.Value.AddDays(1) });
        Assert.Equal("2026-11-01T00:00:00+09:00", midnight[1].Display);
    }
    [Fact]
    public void NestedClockFunctionsRefreshWithoutActivatingUnusedFunctions()
    {
        var update = FunctionUpdate.Prepare("f()=now\ng()=f() in unix", FunctionLibrary.Empty, []);
        var session = new SheetEvaluationSession();
        Assert.False(session.EvaluateWithFunctions("2+2", update.Library, [], context: Clock).UsesCurrentInstant);
        var first = session.EvaluateWithFunctions("g()\n2+2", update.Library, [], context: Clock);
        Assert.True(first.UsesCurrentInstant); Assert.False(first.UsesCurrentDate);
        var next = session.EvaluateWithFunctions("g()\n2+2", update.Library, [], context: Clock with { Now = Clock.Now!.Value.AddSeconds(1) });
        Assert.Equal("1793361601", next.Results[0].Display); Assert.Equal(1, session.LastStatistics.ReusedResults);
        Assert.False(session.EvaluateWithFunctions("2026-10-30 12:00 London in Tokyo", update.Library, [], context: Clock).UsesCurrentDate);
    }
    [Fact]
    public void ZoneRuleSnapshotChangesInvalidateOnlyZoneReaders()
    {
        static IDateTimeZoneProvider Provider(int hours) => new DateTimeZoneCache(new SingleZoneSource(DateTimeZone.ForOffset(Offset.FromHours(hours)), "test-" + hours));
        var session = new SheetEvaluationSession(); const string source = "2026-10-30T12:00 Europe/London in unix\nnow in unix\n2+2";
        var a = session.Evaluate(source, context: Clock with { TimeZones = Provider(1) });
        var b = session.Evaluate(source, context: Clock with { TimeZones = Provider(2) });
        Assert.Equal(a[0].Value!.Value.Scalar - new Rational(3600, 1), b[0].Value!.Value.Scalar); Assert.Equal(2, session.LastStatistics.ReusedResults);
    }
    private sealed class SingleZoneSource(DateTimeZone zone, string version) : IDateTimeZoneSource
    {
        public string VersionId => version;
        public IEnumerable<string> GetIds() => ["Europe/London"];
        public DateTimeZone ForId(string id) => zone;
        public string? GetSystemDefaultId() => null;
    }
    [Fact]
    public void EveryManifestZoneAndCityResolvesAndCarriesThePinnedVersion()
    {
        using var stream = typeof(SheetEvaluator).Assembly.GetManifestResourceStream("Calc.TimeZones")!;
        using var json = JsonDocument.Parse(stream); var root = json.RootElement;
        Assert.Equal(root.GetProperty("version").GetString(), DateTimeZoneProviders.Tzdb.VersionId);
        foreach (var id in root.GetProperty("ids").EnumerateArray().Select(item => item.GetString()!))
        {
            var result = SheetEvaluator.Evaluate("2026-01-15 12:00 " + id, context: Clock)[0]; Assert.True(result.Error is null, id + ": " + result.Error);
        }
        foreach (var alias in root.GetProperty("aliases").EnumerateObject())
        {
            var result = SheetEvaluator.Evaluate("2026-01-15 12:00 " + alias.Name, context: Clock)[0]; Assert.True(result.Error is null, alias.Name + ": " + result.Error);
            Assert.Equal(alias.Value.GetString(), result.Value!.Value.Moment.ZoneId);
        }
    }
    [Fact]
    public void DeclaredNamesCallsAndReceiptsKeepTheirRoles()
    {
        var results = SheetEvaluator.Evaluate("now=7\nnow+1\nunix=9\nunix+1\nnow(x)=x+2\nnow(3)\nf(now)=now+1\nf(4)\nLondon=4\nLondon+1", context: Clock);
        Assert.Equal("8", results[1].Display); Assert.Equal("10", results[3].Display); Assert.Equal("5", results[5].Display); Assert.Equal("5", results[7].Display); Assert.Equal("5", results[9].Display);
        var update = FunctionUpdate.Prepare("f()=2026-10-30 12:00 Etc/GMT+2", FunctionLibrary.Empty, []);
        var changed = FunctionUpdate.Prepare("f()=2026-10-30 12:00 Etc/GMT-2", update.Library, update.Receipts);
        Assert.True(changed.HasChanges);
        var attached = FunctionUpdate.Prepare("f()=2026-10-30T12:00UTC+02:00", FunctionLibrary.Empty, []);
        Assert.True(FunctionUpdate.Prepare("f()=2026-10-30T12:00UTC +02:00", attached.Library, attached.Receipts).HasChanges);
    }
    [Fact]
    public void CancellationCannotReplaceThePreviousClockSnapshot()
    {
        var session = new SheetEvaluationSession(); session.Evaluate("now in unix\n2+2", context: Clock); var before = session.LastStatistics;
        using var canceled = new CancellationTokenSource(); canceled.Cancel();
        Assert.Throws<OperationCanceledException>(() => session.Evaluate("now in Tokyo", canceled.Token, Clock));
        Assert.Equal(before, session.LastStatistics);
        Assert.Equal("1793361600", session.Evaluate("now in unix\n2+2", context: Clock)[0].Display); Assert.Equal(2, session.LastStatistics.ReusedResults);
    }
    [Fact]
    public void SeededUnixOffsetsMatchIndependentIntegerTickArithmetic()
    {
        var random = new Random(8031);
        for (var i = 0; i < 500; i++)
        {
            var seconds = random.NextInt64(-2208988800, 4102444800); var offset = random.Next(-72, 73) * 900;
            var absolute = Math.Abs(offset); var zone = $"UTC{(offset < 0 ? '-' : '+')}{absolute / 3600:D2}:{absolute / 60 % 60:D2}";
            var result = SheetEvaluator.Evaluate($"unix {seconds} in {zone}")[0]; Assert.Null(result.Error);
            var expected = new DateTime(1970, 1, 1).AddTicks((seconds + offset) * TimeSpan.TicksPerSecond);
            var moment = result.Value!.Value.Moment;
            Assert.Equal(expected, moment.Instant.InZone(DateTimeZone.ForOffset(Offset.FromSeconds(offset))).LocalDateTime.ToDateTimeUnspecified());
            Assert.Equal(seconds, SheetEvaluator.Evaluate(result.Display + " in unix")[0].Value!.Value.Scalar.Numerator);
        }
    }
}
