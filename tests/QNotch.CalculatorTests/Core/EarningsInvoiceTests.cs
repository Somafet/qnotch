using Calc.Core;

namespace Calc.Core.Tests;

public class EarningsInvoiceTests
{
    private static EvaluationContext Context(string region="DE",int year=2026) => new(new(year,10,31),WorkdayRegion:region);
    private static LineResult Last(string source,EvaluationContext? context=null)
    { var value=SheetEvaluator.Evaluate(source,context:context ?? Context())[^1]; Assert.Null(value.Error); return value; }
    private static SheetValue Amount(LineResult result) => result.Value!.Value.Kind==SheetValueKind.Earnings?result.Value.Value.Earnings.Amount:result.Value.Value;
    private static Rational Magnitude(LineResult result) => Amount(result).Kind==SheetValueKind.Money?Amount(result).Money.Magnitude.Scalar:Amount(result).Scalar;
    [Theory]
    [InlineData("5000 eur/month in yearly","60000 EUR/year")]
    [InlineData("90000 eur/year in monthly","7500 EUR/month")]
    [InlineData("60k/year in monthly","5000/month")]
    [InlineData("100 eur/month","100 EUR/month")]
    [InlineData("100 EUR per month in annually","1200 EUR/year")]
    [InlineData("100 yearly in monthly","8.3333/month")]
    [InlineData("$100/month in yearly","1200 USD/year")]
    [InlineData("r=100/month\nr*2","200/month")]
    [InlineData("r=100 EUR/month\nr+10%","110 EUR/month")]
    [InlineData("r=100 EUR/month\nr*3 months","300 EUR")]
    [InlineData("100 EUR/year * 6 months","50 EUR")]
    [InlineData("100 EUR/month * 1 year","1200 EUR")]
    [InlineData("100/month+1200/year","200/month")]
    [InlineData("100/month / (1200/year)","1")]
    [InlineData("abs(-100 EUR/month)","100 EUR/month")]
    [InlineData("double 100 EUR/month","200 EUR/month")]
    [InlineData("((100/3) EUR/month) to 1 decimal","33.3 EUR/month")]
    [InlineData("100 EUR/h in daily","800 EUR/workday")]
    [InlineData("800 EUR/day in hourly","100 EUR/hour")]
    [InlineData("r=800 EUR/day in hourly\nr * 8 h","800 EUR")]
    [InlineData("r=100 EUR/h in daily\nr * 8 h","800 EUR")]
    [InlineData("100 EUR/h * 8 h","800 EUR")]
    [InlineData("100 EUR/day * 2 days","200 EUR")]
    [InlineData("100/month\n1200/year\nsum","200/month")]
    [InlineData("100/month\n1200/year\naverage","100/month")]
    [InlineData("f(x)=x EUR/month in yearly\nf(5000)","60000 EUR/year")]
    [InlineData("5000 EUR/month\nprev in yearly","60000 EUR/year")]
    [InlineData("5000 EUR/month\nL1 in yearly","60000 EUR/year")]
    [InlineData("(loan 1200 at 0% for 1 year) to 2 decimals","100")]
    [InlineData("1 mar 2027 net 30","2027-03-31")]
    [InlineData("2028-02-28 net 2","2028-03-01")]
    [InlineData("2027-12-20 net 10","2027-12-30")]
    [InlineData("2027-03-26 net 1","2027-03-27")]
    [InlineData("2027-03-26 net 0","2027-03-26")]
    [InlineData("issued=2027-03-01\nterm=30\nissued net term","2027-03-31")]
    [InlineData("f(d)=d net 30\nf(2027-03-01)","2027-03-31")]
    [InlineData("(2027-03-01 net 30)+1 day","2027-04-01")]
    [InlineData("late fee 1000 at 0.1%/day for 45 days","45")]
    [InlineData("late fee 1000 EUR at 0.1% per day for 12 h","0.5 EUR")]
    [InlineData("late fee 1000 at 0/day for 45 days","0")]
    [InlineData("late fee 0 at 0.1%/day for 45 days","0")]
    [InlineData("late fee 1000 at 0.1%/day for 0 days","0")]
    [InlineData("f(p)=late fee p at 0.1%/day for 45 days\nf(1000 EUR)","45 EUR")]
    [InlineData("(late fee 1000 at 0.1%/day for 45 days)+1000","1045")]
    [InlineData("net=100\nnet+2","102")]
    [InlineData("late fee=12\nlate fee+2","14")]
    [InlineData("month=2\n100/month","50")]
    public void PublicAndTypedExamples(string source,string expected) => Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("100/month+100")][InlineData("100 EUR/month+100 EUR")]
    [InlineData("100/month * 1 day")][InlineData("100/month * (1 year + 1 day)")]
    [InlineData("100/month+(100/h in hourly)")]
    [InlineData("100/month*100/month")][InlineData("100/(100/month)")]
    [InlineData("100/month in hourly", "RO")][InlineData("100 EUR in monthly")]
    [InlineData("10 kg/month")][InlineData("10%/year")]
    [InlineData("100/year + 1 h")][InlineData("100/month!")]
    [InlineData("2027-03-01 net -1")][InlineData("2027-03-01 net 1.5")]
    [InlineData("2027-03-01 net 30 days")][InlineData("9999-12-31 net 1")]
    [InlineData("100 net 30")][InlineData("2027-03-01 net 10%")]
    [InlineData("late fee 1000 at -1%/day for 30 days")]
    [InlineData("late fee -1000 at 0.1%/day for 30 days")]
    [InlineData("late fee 1000 at 0.1%/month for 30 days")]
    [InlineData("late fee 1000 at 0.1%/day for -30 days")]
    [InlineData("late fee 1000 at 0.1%/day for 2 months")]
    [InlineData("late fee 1000 at 0.1%/day for 45")]
    public void InvalidDomainsAreExplicit(string source,string region="DE") => Assert.NotNull(SheetEvaluator.Evaluate(source,context:Context(region))[^1].Error);

    [Fact]
    public void AnnualHoursUseEnumeratedWorkdaysAndConversionsInvertExactly()
    {
        foreach(var region in new[]{"DE","US","WEEKDAYS"})
        foreach(var year in new[]{2026,2027,2028,2032})
        {
            var calendar=new WorkdayCalendar(region); var excluded=calendar.Holidays(year).Select(value=>value.Date).ToHashSet();
            var start=new DateOnly(year,1,1);
            var days=Enumerable.Range(0,DateTime.IsLeapYear(year)?366:365).Select(i=>start.AddDays(i)).Count(date=>date.DayOfWeek is not DayOfWeek.Saturday and not DayOfWeek.Sunday && !excluded.Contains(date));
            Assert.Equal(new Rational(60000,days*8),Magnitude(Last("60k/year in hourly",Context(region,year))));
            Assert.Equal(new Rational(450*days,12),Magnitude(Last("450 EUR/day in monthly",Context(region,year))));
            Assert.Equal(new Rational(60000,1),Magnitude(Last("r=60k/year in hourly\nr in yearly",Context(region,year))));
        }
    }

    [Fact]
    public void CustomHolidaysAndContextChangesInvalidateOnlyConsumers()
    {
        var context=Context("WEEKDAYS");
        Assert.Equal(new Rational(60000,260*8),Magnitude(Last("holidays=[2026-01-02]\n60k/year in hourly",context)));
        var session=new SheetEvaluationSession(); const string source="60k/year\nprev in hourly\n2+2";
        var before=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context); Assert.Null(before.Results[1].Error);
        var after=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context with{Today=new(2028,1,1)});
        Assert.NotEqual(before.Results[1].Display,after.Results[1].Display);
        Assert.Equal(0,session.LastStatistics.ParsedLines); Assert.Equal(2,session.LastStatistics.ReusedResults);
        var changed=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context with{Today=new(2028,1,1),WorkdayRegion="DE"});
        Assert.NotEqual(after.Results[1].Display,changed.Results[1].Display); Assert.Equal(2,session.LastStatistics.ReusedResults);
        var noContext=session.EvaluateWithFunctions("5000 EUR/month in yearly\n100 EUR/h in daily\n2027-03-01 net 30\nlate fee 1000 at 0.1%/day for 45 days",FunctionLibrary.Empty,[]);
        Assert.All(noContext.Results,result=>Assert.Null(result.Error));
        Assert.False(noContext.UsesCurrentDate); Assert.False(noContext.UsesCurrentInstant); Assert.False(noContext.UsesCurrencyRates);
    }

    [Fact]
    public void DueDatesMatchDayNumberArithmeticAcrossLeapAndYearBoundaries()
    {
        var random=new Random(817263);
        for(var i=0;i<150;i++)
        {
            var date=new DateOnly(random.Next(1900,2090),random.Next(1,13),random.Next(1,29)); var days=random.Next(0,730);
            var result=Last($"{date:yyyy-MM-dd} net {days}");
            Assert.Equal(date.DayNumber+days,result.Value!.Value.Date.DayNumber);
        }
    }

    [Fact]
    public void FeesAreLinearAndDisplayPrecisionDoesNotChangeAmounts()
    {
        Assert.Equal(new Rational(1,4320),Magnitude(Last("late fee 1 at 1/3/day for 1 min")));
        var random=new Random(1729);
        for(var i=0;i<50;i++)
        {
            var principal=random.Next(1,100000); var bps=random.Next(0,100); var days=random.Next(0,730);
            Assert.Equal(new Rational((long)principal*bps*days,10000),Magnitude(Last($"late fee {principal} at {bps}/10000/day for {days} days")));
        }
        Assert.Equal("0.01 EUR",Last("fee=late fee 1 EUR at 0.01%/day for 1 day\nfee*100").Display);
    }

    [Fact]
    public void ApproximationCurrencySnapshotsAndSavedCallsArePreserved()
    {
        Assert.StartsWith("≈ ",Last("x=loan 250000 at 4.99% for 30 years\nx/month in yearly").Display);
        var snapshot=new CurrencyRateSnapshot("Earnings fixture","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(2,1)});
        var context=Context() with{CurrencyRates=new(snapshot,[])};
        Assert.Equal("120000 USD/year",Last("5000 EUR/month in USD in yearly",context).Display);
        Assert.Equal("100 EUR/month",Last("(100/month) EUR",context).Display);
        Assert.Equal("150 EUR/month",Last("100 EUR/month+100 USD/month",context).Display);
        var session=new SheetEvaluationSession(); var result=session.EvaluateWithFunctions("f(x)=x/year in hourly\nf(60000)",FunctionLibrary.Empty,[],context:context);
        Assert.Null(result.Results[1].Error); Assert.True(result.UsesCurrentDate);
        using var cancellation=new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("60k/year in hourly",cancellation.Token,context));
    }

    [Fact]
    public void SavedEarningsCallsConsumeTheCallersHolidayDeclarations()
    {
        var source="f(x)=x/year in hourly\nholidays=[2026-01-02]\nf(60000)";
        Assert.Equal(new Rational(60000,260*8),Magnitude(Last(source,Context("WEEKDAYS"))));
        var session=new SheetEvaluationSession(); var first=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Context("WEEKDAYS"));
        var changed=session.EvaluateWithFunctions(source.Replace("2026-01-02","2026-01-03"),FunctionLibrary.Empty,[],context:Context("WEEKDAYS"));
        Assert.Null(changed.Results[^1].Error); Assert.NotEqual(first.Results[^1].Display,changed.Results[^1].Display);
        Assert.Equal(new Rational(60000,261*8),changed.Results[^1].Value!.Value.Earnings.Amount.Scalar);
    }

    [Fact]
    public void DatedRateScopesAndConflictingEarningsSnapshotsRemainExplicit()
    {
        CurrencyRateSnapshot Snapshot(int dollars,DateOnly date)=>new("Earnings fixture","EUR",date,new(2026,10,31,0,0,0,TimeSpan.Zero),new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(dollars,1)});
        var context=Context() with{CurrencyRates=new(Snapshot(2,new(2026,10,30)),new Dictionary<DateOnly,CurrencyRateSnapshot>{[new(2024,1,1)]=Snapshot(3,new(2023,12,29))})};
        Assert.Equal("300 USD/month",Last("100 EUR/month in USD on 2024-01-01",context).Display);
        var result=SheetEvaluator.Evaluate("a=100 EUR/month in USD on 2024-01-01\nb=100 EUR/month in USD\na+b",context:context)[^1];
        Assert.Contains("different rate snapshots",result.Error);
    }

    [Fact]
    public void WorkingDayOutputCannotBeConfusedWithAnElapsedDayRate()
    {
        Assert.Equal("100 EUR/day",Last("100 EUR/day").Display);
        Assert.Equal("100 EUR/workday",Last("100 EUR/day in daily").Display);
        Assert.Equal("100 EUR",Last("r=100 EUR/day in daily\nr*8h").Display);
        Assert.Equal("300 EUR",Last("r=100 EUR/day in daily\nr*1day").Display);
    }
}
