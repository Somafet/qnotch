using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class TimeIntervalTests
{
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(TimeIntervalTests).Assembly.GetManifestResourceStream("Calc.TimeFixtures")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[] { item.GetProperty("source").GetString()!, item.GetProperty("expected").GetString()!, item.TryGetProperty("error", out var error) && error.GetBoolean() }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void ExactClockAndIntervalFixtures(string source, string expected, bool error)
    {
        var answers = SheetEvaluator.Evaluate(source); var result = answers[^1]; Assert.Equal(expected, result.Display);
        if (error) { Assert.Null(result.Value); Assert.NotNull(result.Error); return; }
        Assert.All(answers, answer => Assert.Null(answer.Error));
        var pasted = SheetEvaluator.Evaluate(result.Display)[0]; Assert.Null(pasted.Error);
        Assert.Equal(result.Value!.Value.Kind, pasted.Value!.Value.Kind);
        if (result.Value.Value.Kind == SheetValueKind.Time) Assert.Equal(result.Value, pasted.Value);
        else
        {
            Assert.Equal(result.Value.Value.Exact, pasted.Value.Value.Exact);
            Assert.Equal(result.Value.Value.Unit?.Dimension, pasted.Value.Value.Unit?.Dimension);
            Assert.Equal(result.Value.Value.IsPercentage, pasted.Value.Value.IsPercentage);
        }
    }
    [Fact]
    public void ClockValuesHaveNoImplicitNumericOrDateMeaning()
    {
        var value = SheetEvaluator.Evaluate("09:15")[0].Value!.Value;
        Assert.Equal(SheetValueKind.Time, value.Kind); Assert.False(value.IsRational); Assert.False(value.IsPercentage);
        Assert.Throws<ArithmeticException>(() => value.Scalar); Assert.Throws<ArithmeticException>(() => value.Date);
        Assert.Equal(new ClockTime(new TimeOnly(9, 15)), value.Time);
        Assert.False(new SheetEvaluationSession().EvaluateWithFunctions("09:15–17:40", FunctionLibrary.Empty, []).UsesCurrentDate);
    }
    [Fact]
    public void SeededRangesMatchIndependentMinuteEnumeration()
    {
        var random = new Random(1107);
        for (var trial = 0; trial < 1000; trial++)
        {
            var start = random.Next(1440); var end = random.Next(1440); var expected = 0;
            for (var minute = start; minute != end; minute = (minute + 1) % 1440) expected++;
            var source = $"{start / 60:D2}:{start % 60:D2}–{end / 60:D2}:{end % 60:D2}";
            var result = SheetEvaluator.Evaluate(source)[0]; Assert.Null(result.Error);
            Assert.Equal(new Rational(expected * 60, 1), result.Value!.Value.Exact.Rational);
            var breakMinutes = random.Next(0, expected + 1);
            Assert.Equal(new Rational((expected - breakMinutes) * 60, 1), SheetEvaluator.Evaluate(source + $" - {breakMinutes} min")[0].Value!.Value.Exact.Rational);
            Assert.NotNull(SheetEvaluator.Evaluate(source + $" - {expected + 1} min")[0].Error);
        }
    }
    [Fact]
    public void SeededClockShiftsRetainEveryExplicitDay()
    {
        var random = new Random(1111);
        for (var trial = 0; trial < 400; trial++)
        {
            var start = random.Next(1440); var shift = random.Next(-10000, 10001); var total = start + shift;
            var day = (int)Math.Floor(total / 1440m); var minute = total - day * 1440;
            var result = SheetEvaluator.Evaluate($"{start / 60:D2}:{start % 60:D2} + ({shift} min)")[0]; Assert.Null(result.Error);
            Assert.Equal(day, result.Value!.Value.Time.DayOffset);
            Assert.Equal(new TimeOnly(minute / 60, minute % 60), result.Value.Value.Time.Time);
        }
    }
    [Fact]
    public void NamesFunctionsAndReceiptsRespectClockLiteralRoles()
    {
        var source = "from home=7\nfrom home+1\nfrom(x)=x+1\nfrom(2)\nf(h)=20/h\nf(4)";
        var result = SheetEvaluator.Evaluate(source); Assert.Equal("8", result[1].Display); Assert.Equal("3", result[3].Display); Assert.Equal("5", result[5].Display);
        var first = FunctionUpdate.Prepare("f()=9:15pm", FunctionLibrary.Empty, []);
        Assert.False(FunctionUpdate.Prepare("F()=9:15 PM", first.Library, first.Receipts).HasChanges);
        var changed = new SheetEvaluationSession().EvaluateWithFunctions("f()=9:15am\nf()", first.Library, first.Receipts);
        Assert.True(changed.Functions.HasChanges); Assert.Equal("09:15", changed.Results[1].Display);
    }
    [Fact]
    public void IntervalChangesInvalidateDependentsAndExplanations()
    {
        var session = new SheetEvaluationSession(); const string source = "start=22:00\nfrom start to 06:00\nprev-30min\n2+2";
        session.Evaluate(source); var changed = session.Evaluate(source.Replace("22:00", "21:00"));
        Assert.Equal("9 h", changed[1].Display); Assert.Equal("8 h 30 min", changed[2].Display); Assert.True(session.LastStatistics.ReusedResults > 0);
        Assert.Contains(changed[1].Explanation, step => step.Operation == "clock interval" && step.Assumption!.Contains("rolls over once"));
        var failed = session.Evaluate(source.Replace("22:00", "25:00")); Assert.Null(failed[1].Value); Assert.Null(failed[2].Value);
    }
    [Fact]
    public void DurationFormattingRemainsExactForLargeOrFractionalResults()
    {
        var result = SheetEvaluator.Evaluate("(09:00–10:00)/7")[0]; Assert.Null(result.Error);
        var pasted = SheetEvaluator.Evaluate(result.Display)[0]; Assert.Null(pasted.Error); Assert.Equal(result.Value!.Value.Exact, pasted.Value!.Value.Exact);
        var large = SheetEvaluator.Evaluate("(09:00–10:00)*10^1000")[0]; Assert.Null(large.Error); Assert.True(large.Display.Length <= 2048);
        Assert.Equal(new Rational(BigInteger.Pow(10, 1000) * 3600, 1), large.Value!.Value.Exact.Rational);
    }
    [Fact]
    public void EquivalentRateUnitsCancelWithoutChangingCanonicalMagnitude()
    {
        foreach (var source in new[] { "(09:00–10:30)*10km/h", "(09:00–10:30)*10000m/h", "(09:00–10:30)*250m/90s" })
        {
            var value = SheetEvaluator.Evaluate(source)[0]; Assert.Null(value.Error);
            Assert.Equal(new Rational(15000, 1), value.Value!.Value.Exact.Rational); Assert.Equal(new Dimension(1, 0, 0, 0, 0, 0, 0, 0), value.Value.Value.Unit!.Dimension);
        }
    }
    [Fact]
    public void CancellationAndPrecisionLimitsDoNotReplaceTheLastSnapshot()
    {
        var session = new SheetEvaluationSession(); session.Evaluate("09:00–10:00"); var before = session.LastStatistics;
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => session.Evaluate("09:00–11:00", cancellation.Token)); Assert.Equal(before, session.LastStatistics);
        Assert.Equal("1 h", session.Evaluate("09:00–10:00")[0].Display); Assert.Equal(1, session.LastStatistics.ReusedResults);
        Assert.NotNull(SheetEvaluator.Evaluate("09:00+10^1000 s")[0].Error);
    }
    [Theory]
    [InlineData("9:5")]
    [InlineData("25:00")]
    [InlineData("24:01")]
    [InlineData("09:60")]
    [InlineData("09:00:60")]
    [InlineData("09:00:0")]
    [InlineData("09:00:00.00000001")]
    [InlineData("09:00.5")]
    [InlineData("13:00pm")]
    [InlineData("00:00am")]
    [InlineData("24:00pm")]
    [InlineData("09:00+10")]
    [InlineData("09:00+1m")]
    [InlineData("09:00+1month")]
    [InlineData("09:00+0.00000001s")]
    [InlineData("09:00+09:00")]
    [InlineData("09:00*2")]
    [InlineData("-09:00")]
    [InlineData("09:00%")]
    [InlineData("sqrt(09:00)")]
    [InlineData("09:00 in h")]
    [InlineData("09:00 to 2 decimals")]
    [InlineData("09:00–10:00-61min")]
    [InlineData("(09:00–10:00)*-1")]
    [InlineData("24:00–01:00")]
    [InlineData("1m–2m")]
    [InlineData("09:00–2026-10-30")]
    [InlineData("1h-09:00")]
    [InlineData("09:00+3660001day")]
    [InlineData("from 09:00")]
    public void InvalidClockDomainsNeverBecomePlausibleNumbers(string source)
    {
        var result = SheetEvaluator.Evaluate(source)[0]; Assert.Null(result.Value); Assert.NotNull(result.Error);
    }
}
