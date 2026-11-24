using System.Numerics;
using Calc.Core;

namespace Calc.Core.Tests;

public class StatisticsTests
{
    private static LineResult Last(string source, EvaluationContext? context = null)
    { var result = SheetEvaluator.Evaluate(source, context:context)[^1]; Assert.Null(result.Error); return result; }
    [Theory]
    [InlineData("[1,2,3]", "[1, 2, 3]")]
    [InlineData("[]", "[]")]
    [InlineData("sum([120,340,89])", "549")]
    [InlineData("sum([])", "0")]
    [InlineData("count([])", "0")]
    [InlineData("count([1,2,3])", "3")]
    [InlineData("sum([1,2],3,[4,5])", "15")]
    [InlineData("sum([1/3,1/3])", "2/3")]
    [InlineData("mean(1,2,3,4)", "2.5")]
    [InlineData("average([1,2,3,4])", "2.5")]
    [InlineData("avg([1,2],[3,4])", "2.5")]
    [InlineData("median(1,3,2)", "2")]
    [InlineData("median([4,1,3,2])", "2.5")]
    [InlineData("median([7])", "7")]
    [InlineData("stdev(2,4,4,4,5,5,7,9)", "2.1381")]
    [InlineData("stddev([2,4,4,4,5,5,7,9])", "2.1381")]
    [InlineData("stdevp([2,4,4,4,5,5,7,9])", "2")]
    [InlineData("variancep([2,4,4,4,5,5,7,9])", "4")]
    [InlineData("variance([2,4,4,4,5,5,7,9])", "4.5714")]
    [InlineData("stdevp([7])", "0")]
    [InlineData("variance([1000000000000000000000000,1000000000000000000000001,1000000000000000000000002])", "1")]
    [InlineData("percentile([3,7,9,12],90)", "11.1")]
    [InlineData("percentile([3,7,9,12],90%)", "11.1")]
    [InlineData("percentile([3,7,9,12],0)", "3")]
    [InlineData("percentile([3,7,9,12],100)", "12")]
    [InlineData("percentile([10,20],0.5)", "10.05")]
    [InlineData("min([3,-1,2])", "-1")]
    [InlineData("max([3,-1,2])", "3")]
    [InlineData("min([2 m,100 cm])", "1 m")]
    [InlineData("max([1 m,200 cm])", "2 m")]
    [InlineData("mean([1 m,200 cm])", "1.5 m")]
    [InlineData("median([1 m,200 cm,3 m])", "2 m")]
    [InlineData("variancep([1 m,3 m])", "1 m^2")]
    [InlineData("stdev([1 m,3 m])", "1.4142 m")]
    [InlineData("mean([0 °C,68 °F])", "10 °C")]
    [InlineData("median([0 °C,20 °C])", "10 °C")]
    [InlineData("variancep([0 °C,20 °C])", "100 deltaC^2")]
    [InlineData("stdevp([0 °C,20 °C])", "10 deltaC")]
    [InlineData("mean([10%,20%])", "15%")]
    [InlineData("stdev([10%,20%])", "7.0711%")]
    [InlineData("variance([10%,20%])", "0.005")]
    [InlineData("percentile([10%,20%],50)", "15%")]
    [InlineData("x=[1,2,3]\nmean(x)", "2")]
    [InlineData("f(x)=mean(x)\nf([1,2,3])", "2")]
    [InlineData("f(x,y)=sum([x,y])\nf(2,3)", "5")]
    [InlineData("f()=[1,2,3]\nsum(f())", "6")]
    [InlineData("npv(10%,[100,200,300])", "481.5928")]
    [InlineData("npv(0,[100,200],300)", "600")]
    [InlineData("holidays=[]\n4\n5\nx=[1,2,3]\nsum", "9")]
    public void PublishedAndTypedExamples(string source, string expected) => Assert.Equal(expected, Last(source).Display);

    [Fact]
    public void StatisticsKeepExactUnderlyingFractionsAndRadicals()
    {
        Assert.Equal(new Rational(2,3), Last("mean([0,1,1])").Value!.Value.Scalar);
        Assert.Equal(new Rational(32,7), Last("variance([2,4,4,4,5,5,7,9])").Value!.Value.Scalar);
        var source = "x=stdev([2,4,4,4,5,5,7,9])\nx*x";
        Assert.Equal(new Rational(32,7), Last(source).Value!.Value.Scalar);
        Assert.False(Last("stdev([1,3])").Value!.Value.Number.IsApproximate);
        Assert.Equal("1.414214", Last("stdev([1,3]) to 6 decimals").Display);
        Assert.Equal(new Rational(2,1), Last("x=[sqrt(8),sqrt(2),sqrt(18)]\nmedian(x)^2").Value!.Value.Scalar / new Rational(4,1));
    }
    [Fact]
    public void ListsAreImmutableAndCompareByTheirTypedContents()
    {
        var source = new[] { new SheetValue(new Rational(1,1)), new SheetValue(new Rational(2,1)) };
        var list = new SheetList(source); source[0] = new(new Rational(9,1));
        Assert.Equal(new Rational(1,1), list.Values[0].Scalar);
        Assert.Equal(list, new SheetList([new(new Rational(1,1)),new(new Rational(2,1))]));
        Assert.NotEqual(list, new SheetList([new(new Rational(2,1)),new(new Rational(1,1))]));
        Assert.Throws<NotSupportedException>(() => ((IList<SheetValue>)list.Values)[0] = new(new Rational(3,1)));
    }
    [Fact]
    public void MaximumListsHaveBoundedPreviewsAndCompleteFormattedCopies()
    {
        var literal = "["+string.Join(',',Enumerable.Range(1,1024))+"]";
        var value = Last(literal).Value!.Value;
        Assert.Equal(1024, value.List.Values.Count); Assert.Contains('…', value.Display); Assert.True(value.Display.Length <= 516);
        Assert.DoesNotContain('…', value.CopyText); Assert.EndsWith("1023, 1024]", value.CopyText);
        Assert.Equal(1023, value.CopyText.Count(c => c == ','));
        Assert.Equal("524800", Last("data="+literal+"\nsum(data)").Display);
        Assert.Equal("512.5", Last("data="+literal+"\nmedian(data)").Display);
        Assert.Equal("524800", Last("data="+literal+"\nnpv(0,data)").Display);
        Assert.NotNull(SheetEvaluator.Evaluate("["+string.Join(',',Enumerable.Range(1,1025))+"]")[0].Error);
        Assert.NotNull(SheetEvaluator.Evaluate("data="+literal+"\nsum(data,data)")[^1].Error);
    }
    [Fact]
    public void NumericListsAndEmptyListsDoNotChangeHolidayRules()
    {
        var context = new EvaluationContext(WorkdayRegion:"WEEKDAYS");
        var result = SheetEvaluator.Evaluate("days=[24 dec]\nholidays=days\n2027-12-23+1 working day\nholidays=[]\n2027-12-23+1 working day", context:context);
        Assert.Equal("2027-12-27", result[2].Display); Assert.Equal("2027-12-24", result[4].Display);
        Assert.Equal(SheetValueKind.HolidayList, result[3].Value!.Value.Kind);
        Assert.Equal(SheetValueKind.List, Last("[]").Value!.Value.Kind);
        Assert.NotNull(SheetEvaluator.Evaluate("holidays=[1,2]")[0].Error);
        Assert.Null(Last("holidays=[1,2]\n5").Error);
    }
    [Fact]
    public void ListDependenciesCacheInvalidationAndFunctionsAreTyped()
    {
        var session = new SheetEvaluationSession(); var source = "x=1\ndata=[x,2,3]\nmean(data)\n7";
        session.EvaluateWithFunctions(source, FunctionLibrary.Empty, []);
        var changed = session.EvaluateWithFunctions(source.Replace("x=1","x=4"), FunctionLibrary.Empty, []);
        Assert.Equal("3", changed.Results[2].Display); Assert.Equal(1, session.LastStatistics.ParsedLines);
        Assert.Equal(1, session.LastStatistics.ReusedResults); Assert.Equal(new[]{1}, changed.Results[2].Dependencies);
        Assert.Equal("3", Last("n=3\nf(x)=percentile(x,50)\nf([n,1,7])").Display);
        Assert.All(SheetEvaluator.Evaluate("a=[b,1]\nb=mean(a)"), result => Assert.Equal("Circular dependency", result.Error));
    }
    [Fact]
    public void MixedMoneySamplesUseOneSnapshotAndDoNotLoseApproximation()
    {
        var snapshot = new CurrencyRateSnapshot("Fixture", "EUR", new(2026,10,30), new(2026,10,31,0,0,0,TimeSpan.Zero),new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(2,1)});
        var context = new EvaluationContext(new(2026,10,31), CurrencyRates:new(snapshot,[]));
        Assert.Equal("20 EUR", Last("sum([10 EUR,20 USD])",context).Display);
        Assert.Equal("10 EUR", Last("median([10 EUR,20 USD])",context).Display);
        Assert.Equal("5 EUR", Last("stdevp([10 EUR,40 USD])",context).Display);
        Assert.Equal("20 EUR", Last("npv(0,[10 EUR,20 USD])",context).Display);
        var converted = Last("mean([10 EUR,40 USD])",context);
        Assert.Equal(snapshot.Key, converted.Value!.Value.Money.RateSnapshotKey);
        Assert.Contains(converted.Explanation, step => step.Assumption?.Contains("Fixture") == true);
        foreach (var operation in new[]{"mean(data)","median(data)","stdev(data)","percentile(data,50)","min(data)","sum(data)","npv(0,data)"})
            Assert.StartsWith("≈ ", Last("x=loan 250000 at 4.99% for 30 years\ndata=[x,2]\n"+operation).Display);
        Assert.Equal("2", Last("x=loan 250000 at 4.99% for 30 years\ncount([x,2])").Display);
    }
    [Fact]
    public void RatesInvalidateOnlyTheListConsumerAndHistoricalScopeReachesItsCashFlows()
    {
        CurrencyRateSnapshot Rates(int dollars) => new("Fixture", "EUR", new(2026,10,30), new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(dollars,1)});
        var session = new SheetEvaluationSession();
        var first = new EvaluationContext(new(2026,10,31), CurrencyRates:new(Rates(2),[]));
        var source = "data=[100 EUR,100 USD]\nmean(data)\n7";
        var initial = session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:first);
        Assert.True(initial.UsesCurrencyRates); Assert.True(initial.HasMoney);
        var updated = session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:first with { CurrencyRates=new(Rates(4),[]) });
        Assert.Equal("62.5 EUR", updated.Results[1].Display);
        Assert.Equal(0, session.LastStatistics.ParsedLines); Assert.Equal(1, session.LastStatistics.EvaluatedLines); Assert.Equal(2, session.LastStatistics.ReusedResults);
        var historical = new CurrencyRateSnapshot("Historical", "EUR", new(2023,12,29),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(3,1)});
        var context = first with { CurrencyRates=new(Rates(2),new Dictionary<DateOnly,CurrencyRateSnapshot>{[new(2024,1,1)]=historical}) };
        Assert.Equal("400 USD", Last("f()=[100 EUR,100 USD]\nnpv(0,f()) in USD on 2024-01-01",context).Display);
        var noWork = new SheetEvaluationSession().EvaluateWithFunctions("sum([1 EUR,2 EUR])\n[3,4]",FunctionLibrary.Empty,[]);
        Assert.False(noWork.UsesCurrencyRates); Assert.False(noWork.UsesCurrentDate); Assert.False(noWork.UsesCurrentInstant);
    }
    [Fact]
    public void SeededSamplesMatchPairwiseVarianceAndIntegerOrderOracles()
    {
        var random = new Random(22054);
        for (var trial = 0; trial < 250; trial++)
        {
            var values = Enumerable.Range(0,random.Next(2,30)).Select(_=>random.Next(-1000,1001)).ToArray();
            var ordered = values.Order().ToArray(); var n = values.Length;
            var literal = "["+string.Join(',',values)+"]";
            Assert.Equal(new Rational(values.Sum(),n), Last("mean("+literal+")").Value!.Value.Scalar);
            var middle = n%2 == 1 ? new Rational(ordered[n/2],1) : new Rational(ordered[n/2-1]+ordered[n/2],2);
            Assert.Equal(middle, Last("median("+literal+")").Value!.Value.Scalar);
            var pairs = BigInteger.Zero;
            for (var a = 0; a < n; a++) for (var b = a+1; b < n; b++) pairs += BigInteger.Pow(values[a]-values[b],2);
            var variance = new Rational(pairs,n*(n-1));
            Assert.Equal(variance, Last("variance("+literal+")").Value!.Value.Scalar);
            var percentile = random.Next(0,101); var rank = (n-1)*percentile; var index = rank/100; var weight = rank%100;
            var expected = weight == 0 ? new Rational(ordered[index],1) : new Rational(ordered[index]*(100-weight)+ordered[index+1]*weight,100);
            Assert.Equal(expected, Last($"percentile({literal},{percentile})").Value!.Value.Scalar);
            var shifted = "["+string.Join(',',values.Reverse().Select(value=>value+1000000))+ "]";
            Assert.Equal(variance, Last("variance("+shifted+")").Value!.Value.Scalar);
        }
    }
    [Theory]
    [InlineData("mean([])")]
    [InlineData("min([])")]
    [InlineData("max([])")]
    [InlineData("median([])")]
    [InlineData("stdev([1])")]
    [InlineData("variance([1])")]
    [InlineData("percentile([],50)")]
    [InlineData("percentile([1,2],-1)")]
    [InlineData("percentile([1,2],101)")]
    [InlineData("percentile([1,2],50 m)")]
    [InlineData("percentile([1,2],sqrt(2))")]
    [InlineData("sum([1,unknown])")]
    [InlineData("mean([1 m,2 kg])")]
    [InlineData("mean([1%,2])")]
    [InlineData("mean([1 EUR,2])")]
    [InlineData("mean([0 °C,10 deltaC])")]
    [InlineData("sum([0 °C,10 °C])")]
    [InlineData("variance([1 EUR,2 EUR])")]
    [InlineData("sum([[1,2],[3,4]])")]
    [InlineData("[1,2026-10-31]")]
    [InlineData("count([1,today])")]
    [InlineData("mean()")]
    [InlineData("percentile([1,2])")]
    [InlineData("f(x)=percentile(x)\nf([1,2])")]
    [InlineData("npv(0,[])")]
    public void InvalidSamplesAreErrorsInsteadOfSkippedData(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void ListsRetainCancellationDepthAndSharedComputationBounds()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("mean([1,2,3])",cancellation.Token));
        var nested = new string('[',70)+"1"+new string(']',70);
        Assert.NotNull(SheetEvaluator.Evaluate(nested)[0].Error);
        var data = "data=["+string.Join(',',Enumerable.Range(1,1024))+"]\n";
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate(data+string.Join('\n',Enumerable.Repeat("median(data)",60))));
    }
}
