using System.Globalization;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class DateTests
{
    private static readonly EvaluationContext Clock = new(new DateOnly(2026,10,30));
    public static IEnumerable<object[]> Fixtures()
    {
        using var stream = typeof(DateTests).Assembly.GetManifestResourceStream("Calc.DateFixtures")!;
        using var json = JsonDocument.Parse(stream);
        return json.RootElement.GetProperty("cases").EnumerateArray().Select(item => new object[]
            { item.GetProperty("source").GetString()!, item.GetProperty("expected").GetString()! }).ToArray();
    }
    [Theory]
    [MemberData(nameof(Fixtures))]
    public void GregorianFixturesUseAnExplicitSnapshot(string source, string expected)
    {
        var result = SheetEvaluator.Evaluate(source, context: Clock);
        Assert.All(result, value => Assert.Null(value.Error));
        Assert.Equal(expected, result[^1].Display);
        var pasted = SheetEvaluator.Evaluate(result[^1].Display, context: Clock)[0];
        Assert.Null(pasted.Error); Assert.Equal(result[^1].Value, pasted.Value);
    }
    [Fact]
    public void DatesAndPeriodsCannotPretendToBeNumbers()
    {
        var date = SheetEvaluator.Evaluate("2024-02-29")[0].Value!.Value;
        Assert.Equal(SheetValueKind.Date, date.Kind); Assert.False(date.IsRational); Assert.False(date.IsPercentage);
        Assert.Throws<ArithmeticException>(() => date.Scalar);
        Assert.Throws<ArithmeticException>(() => date.Exact);
        Assert.Throws<ArithmeticException>(() => date.Unit);
        Assert.Equal(new SheetValue(new Rational(0,1)), default(SheetValue));
        Assert.NotNull(SheetEvaluator.Evaluate("today")[0].Error);
        Assert.Equal("2026-10-30", SheetEvaluator.Evaluate("today", context: Clock)[0].Display);
    }
    [Fact]
    public void CurrentDateChangesInvalidateResultsAndCallsWithoutChangingSource()
    {
        var session = new SheetEvaluationSession(); var source = "start=today\nstart+1day\n7";
        session.Evaluate(source, context: Clock);
        Assert.Equal("2026-11-01", session.Evaluate(source, context:new(new DateOnly(2026,10,31)))[1].Display);
        Assert.Equal(0, session.LastStatistics.ParsedLines);
        var missing = session.Evaluate(source); Assert.Null(missing[0].Value); Assert.Null(missing[1].Value);
        Assert.Equal("2026-10-31", session.Evaluate(source, context:Clock)[1].Display);
        var functions = FunctionUpdate.Prepare("f()=g()\ng()=today", FunctionLibrary.Empty, []);
        Assert.False(session.EvaluateWithFunctions("1+1",functions.Library,[],context:Clock).UsesCurrentDate);
        Assert.True(session.EvaluateWithFunctions("f()",functions.Library,[],context:Clock).UsesCurrentDate);
        Assert.Equal("2026-11-01", session.EvaluateWithFunctions("f()",functions.Library,[],context:new(new DateOnly(2026,11,1))).Results[0].Display);
    }
    [Fact]
    public void AClockDependentErrorStillSchedulesItsFutureReevaluation()
    {
        var session=new SheetEvaluationSession(); const string source="age of 2026-11-01";
        var early=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Clock);
        Assert.Null(early.Results[0].Value);Assert.NotNull(early.Results[0].Error);Assert.True(early.UsesCurrentDate);
        var reached=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:new(new DateOnly(2026,11,1)));
        Assert.Equal("0",reached.Results[0].Display);Assert.True(reached.UsesCurrentDate);Assert.Equal(0,session.LastStatistics.ParsedLines);
    }
    [Fact]
    public void ExistingNamesAndCallsRemainNamesAndCalls()
    {
        var result = SheetEvaluator.Evaluate("today=7\ntoday+1\nin box=9\nin box+1\nage(x)=x+2\nage(3)\nf(today)=today+1day\nf(2024-02-28)");
        Assert.Equal("8",result[1].Display); Assert.Equal("10",result[3].Display); Assert.Equal("5",result[5].Display); Assert.Equal("2024-02-29",result[7].Display);
        var session = new SheetEvaluationSession();
        Assert.False(session.EvaluateWithFunctions("today=7\ntoday+1",FunctionLibrary.Empty,[],context:Clock).UsesCurrentDate);
        var previous = FunctionUpdate.Prepare("f()=2024 - 01 - 01",FunctionLibrary.Empty,[]);
        var changed = session.EvaluateWithFunctions("f()=2024-01-01\nf()",previous.Library,previous.Receipts);
        Assert.True(changed.Functions.HasChanges); Assert.Equal("2024-01-01",changed.Results[1].Display);
    }
    [Fact]
    public void DayDifferencesMatchAnIndependentGregorianCount()
    {
        static int Count(int year,int month,int day)
        {
            var y=year-1; var count=365*y+y/4-y/100+y/400+day-1;
            int[] lengths=[31,28,31,30,31,30,31,31,30,31,30,31];
            for(var m=1;m<month;m++) count+=lengths[m-1]+(m==2 && year%4==0 && (year%100!=0 || year%400==0)?1:0);
            return count;
        }
        var random=new Random(7047);
        for(var trial=0;trial<500;trial++)
        {
            var y=random.Next(1,10000);var m=random.Next(1,13);var d=random.Next(1,29);
            var source=$"{y:D4}-{m:D2}-{d:D2} - 0001-01-01";
            var answer=SheetEvaluator.Evaluate(source)[0]; Assert.Null(answer.Error);
            Assert.Equal(new Rational((long)Count(y,m,d)*86400,1),answer.Value!.Value.Exact.Rational);
        }
        Assert.Equal("146097 day",SheetEvaluator.Evaluate("2001-01-01 - 1601-01-01")[0].Display);
    }
    [Fact]
    public void MonthEndsMatchIndependentIntegerCalendarArithmetic()
    {
        static int Length(int y,int m) => m==2 ? y%4==0 && (y%100!=0 || y%400==0)?29:28 : new[]{31,28,31,30,31,30,31,31,30,31,30,31}[m-1];
        var random=new Random(7031);
        for(var trial=0;trial<500;trial++)
        {
            var y=random.Next(200,9800);var m=random.Next(1,13);var d=Length(y,m);var shift=random.Next(-240,241);
            var index=y*12+m-1+shift;var targetY=index/12;var targetM=index%12+1;var targetD=Math.Min(d,Length(targetY,targetM));
            var value=SheetEvaluator.Evaluate($"{y:D4}-{m:D2}-{d:D2} + ({shift} months)")[0];
            Assert.Null(value.Error);Assert.Equal($"{targetY:D4}-{targetM:D2}-{targetD:D2}",value.Display);
        }
    }
    [Fact]
    public void CalendarLimitsAndCancellationDoNotCommitPartialResults()
    {
        var session=new SheetEvaluationSession();session.Evaluate("today+1month",context:Clock);var before=session.LastStatistics;
        using var cancel=new CancellationTokenSource();cancel.Cancel();
        Assert.Throws<OperationCanceledException>(()=>session.Evaluate("today+2months",cancel.Token,Clock));
        Assert.Equal(before,session.LastStatistics);
        Assert.Equal("2026-11-30",session.Evaluate("today+1month",context:Clock)[0].Display);
        Assert.Equal(1,session.LastStatistics.ReusedResults);
        Assert.NotNull(SheetEvaluator.Evaluate("today+120001months",context:Clock)[0].Error);
        Assert.NotNull(SheetEvaluator.Evaluate(string.Concat(Enumerable.Repeat("in ",20))+"1day",context:Clock)[0].Error);
    }
    [Theory]
    [InlineData("2023-02-29")]
    [InlineData("1900-02-29")]
    [InlineData("2024-13-01")]
    [InlineData("2024-2-3")]
    [InlineData("2024-02-3")]
    [InlineData("2024-000-01")]
    [InlineData("0000-01-01")]
    [InlineData("31 apr 2024")]
    [InlineData("29 feb 24")]
    [InlineData("today+1")]
    [InlineData("today+1 h")]
    [InlineData("today+0.5 day")]
    [InlineData("today+1 m")]
    [InlineData("today+tomorrow")]
    [InlineData("2 day-today")]
    [InlineData("today*2")]
    [InlineData("-today")]
    [InlineData("today%")]
    [InlineData("sqrt(today)")]
    [InlineData("today to 2 decimals")]
    [InlineData("today in day")]
    [InlineData("today #x\ntomorrow #x\nsum #x")]
    [InlineData("9999-12-31+1 day")]
    [InlineData("0001-01-01-1day")]
    [InlineData("1 month / 2")]
    [InlineData("100% month")]
    [InlineData("1 month*1month")]
    [InlineData("today ago")]
    [InlineData("age of tomorrow")]
    [InlineData("days between 1 and 2")]
    [InlineData("next 0")]
    public void InvalidCalendarDomainsHaveNoNumericFallback(string source)
    {
        var result=SheetEvaluator.Evaluate(source,context:Clock)[^1];Assert.Null(result.Value);Assert.NotNull(result.Error);
    }
}
