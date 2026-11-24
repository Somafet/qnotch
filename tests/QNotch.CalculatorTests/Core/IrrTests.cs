using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class IrrTests
{
    private static LineResult Last(string source, EvaluationContext? context=null)
    { var result=SheetEvaluator.Evaluate(source,context:context)[^1]; Assert.Null(result.Error); return result; }
    private static IrrEvidence Evidence(LineResult result) => Assert.Single(result.Explanation,step=>step.Irr is not null).Irr!;
    private static double Real(Rational value) => (double)value.Numerator/(double)value.Denominator;
    private static void Contains(IrrRootInterval interval,Rational root)
    {
        Assert.True(interval.LowerRate.Numerator*root.Denominator <= root.Numerator*interval.LowerRate.Denominator);
        Assert.True(interval.UpperRate.Numerator*root.Denominator >= root.Numerator*interval.UpperRate.Denominator);
    }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream=typeof(IrrTests).Assembly.GetManifestResourceStream("Calc.IrrOracle")!;
        using var document=JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray().Select(item=>new object[]{item.GetRawText()}).ToArray();
    }
    private static Rational OracleRational(string text)
    {
        var parts=text.Split('/'); return new(BigInteger.Parse(parts[0],CultureInfo.InvariantCulture),parts.Length==2?BigInteger.Parse(parts[1],CultureInfo.InvariantCulture):BigInteger.One);
    }
    [Theory]
    [MemberData(nameof(OracleCases))]
    public void IndependentSympyIntervalsVerifyCountsAndEverySelectedRoot(string json)
    {
        using var document=JsonDocument.Parse(json); var entry=document.RootElement;
        var cash=string.Join(',',entry.GetProperty("cash").EnumerateArray().Select(value=>value.GetInt32()));
        var expected=entry.GetProperty("distinctPositiveDiscountRoots").GetInt32();
        if(expected==0)
        { Assert.Contains("No admissible IRR",SheetEvaluator.Evaluate($"irr([{cash}])")[0].Error); return; }
        var roots=entry.GetProperty("roots").EnumerateArray().ToArray();
        for(var i=0;i<roots.Length;i++)
        {
            var lower=roots[i].GetProperty("lower").GetString()!; var upper=roots[i].GetProperty("upper").GetString()!;
            var answer=Last($"irr([{cash}],({lower}))"); var evidence=Evidence(answer);
            Assert.Equal(expected,evidence.DistinctRoots); Assert.Equal(i,evidence.SelectedRoot);
            Contains(evidence.Roots[i],OracleRational(lower)); Contains(evidence.Roots[i],OracleRational(upper));
            Assert.Equal(expected,evidence.Roots.Count);
        }
    }
    [Fact]
    public void FinancialFunctionSyntaxDoesNotConsumeTheIranianCurrencyCode()
    {
        Assert.Equal("100 IRR",Last("IRR 100").Display); Assert.Equal("100 IRR",Last("100 IRR").Display);
        Assert.Equal("100 IRR",Last("(40+60) IRR").Display); Assert.Equal("10%",Last("IRR(-100,110)").Display);
    }
    [Theory]
    [InlineData("irr(-1000,300,400,500)", "≈ 8.8963%")]
    [InlineData("irr([-1000,300,400,500])", "≈ 8.8963%")]
    [InlineData("irr(-100,110)", "10%")]
    [InlineData("irr([-100,50])", "-50%")]
    [InlineData("irr([-100,100])", "0%")]
    [InlineData("irr([0,-100,110,0])", "10%")]
    [InlineData("irr([-100,200,-100])", "0%")]
    [InlineData("irr([1,-4,6,-4,1])", "0%")]
    [InlineData("irr([-100 EUR,110 EUR])", "10%")]
    [InlineData("f(x)=irr([-100,x])\nf(110)", "10%")]
    public void ScalarListAndRepeatedRootCases(string source,string expected) => Assert.Equal(expected,Last(source).Display);
    [Fact]
    public void AllRootsAreCountedAndGuessSelectionIsExplicit()
    {
        var first=Last("irr([-100,230,-132])"); var evidence=Evidence(first);
        Assert.Equal(2,evidence.DistinctRoots); Assert.Equal(0,evidence.SelectedRoot);
        Contains(evidence.Roots[0],new(1,10)); Contains(evidence.Roots[1],new(1,5));
        Assert.Contains("10%",first.Display); Assert.Contains(first.Explanation,step=>step.Assumption?.Contains("Sturm") == true);
        var second=Evidence(Last("irr([-100,230,-132],19%)")); Assert.Equal(1,second.SelectedRoot);
        var tie=Evidence(Last("irr([-100,230,-132],15%)")); Assert.True(tie.ToleranceTie); Assert.Equal(0,tie.SelectedRoot);
        var repeated=Evidence(Last("irr([-2,5,-4,1],-60%)"));
        Assert.Equal(2,repeated.DistinctRoots); Contains(repeated.Roots[0],new(-1,2)); Contains(repeated.Roots[1],default);
        Assert.Equal(0,repeated.SelectedRoot);
    }
    [Fact]
    public void SelectedIntervalAndNpvIndependentlyVerifyThePublishedRoot()
    {
        var result=Last("irr([-1000,300,400,500])"); var evidence=Evidence(result); var interval=evidence.Roots[evidence.SelectedRoot];
        Assert.InRange(Real(result.Value!.Value.Scalar),.0889633946933,.0889633946935);
        Assert.True(Real(interval.UpperRate)-Real(interval.LowerRate)<=1e-14);
        var rate=Real(result.Value.Value.Scalar);
        var npv=-1000+300/(1+rate)+400/Math.Pow(1+rate,2)+500/Math.Pow(1+rate,3);
        Assert.InRange(npv,-1e-9,1e-9);
        Assert.True(result.Value.Value.Number.IsApproximate);
        Assert.Contains(result.Explanation,step=>step.Assumption?.Contains("time 0") == true && step.Assumption.Contains("not automatically annualized"));
    }
    [Fact]
    public void MaximumCashFlowCountAndSparseHighDegreeRootsAreNotArtificiallyTruncated()
    {
        var zeros="[-100,"+string.Join(',',Enumerable.Repeat("0",1022))+",110]";
        var result=Last("irr("+zeros+")");
        var rate=Real(result.Value!.Value.Scalar);
        Assert.InRange(Math.Pow(1+rate,1023),1.1-1e-10,1.1+1e-10);
        Assert.Equal(1,Evidence(result).DistinctRoots);
        var cash=new int[101]; cash[0]=2; cash[50]=-3; cash[100]=1;
        var multiple=Last("irr(["+string.Join(',',cash)+"],-1%)");
        var evidence=Evidence(multiple); Assert.Equal(2,evidence.DistinctRoots);
        Assert.InRange(Real(evidence.Roots[0].LowerRate),Math.Pow(2,-1d/50)-1-1e-12,Math.Pow(2,-1d/50)-1+1e-12);
        Contains(evidence.Roots[1],default);
    }
    [Fact]
    public void DecimalHalfwayRootsHaveVerifiedDisplayRounding()
    {
        // (q - 2) * (2000001*q - 2000000) has rate 0.0000005, a four-decimal percentage halfway.
        var result=Last("irr([4000000,-6000002,2000001],0)");
        Assert.EndsWith("0.0001%",result.Display); Contains(Evidence(result).Roots[^1],new(1,2000000));
    }
    [Fact]
    public void SeededTwoPeriodFlowsHaveExactInverseRatesAndScaleInvariance()
    {
        var random=new Random(11097);
        for(var i=0;i<200;i++)
        {
            var outlay=random.Next(1,10000); var income=random.Next(1,20000); var scale=random.Next(1,100);
            var expected=new Rational(income-outlay,outlay);
            var first=Last($"irr([-{outlay},{income}])"); Assert.Equal(expected,first.Value!.Value.Scalar);
            Assert.False(first.Value.Value.Number.IsApproximate); Assert.True(Evidence(first).Roots[0].Exact);
            Assert.Equal(expected,Last($"irr([{outlay*scale},-{income*scale}])").Value!.Value.Scalar);
        }
    }
    [Fact]
    public void CurrencyContextAndApproximateInputsRetainTheirProvenance()
    {
        var snapshot=new CurrencyRateSnapshot("Fixture","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(2,1)});
        var context=new EvaluationContext(new(2026,10,31),CurrencyRates:new(snapshot,[]));
        var result=Last("irr([-100 EUR,220 USD])",context); Assert.Equal("10%",result.Display);
        Assert.Contains(result.Explanation,step=>step.Assumption?.Contains("Fixture") == true);
        var approximate=Last("x=loan 250000 at 4.99% for 30 years\nirr([-x,x*1.1])");
        Assert.True(Evidence(approximate).InputApproximate); Assert.StartsWith("≈ ",approximate.Display);
        var session=new SheetEvaluationSession(); var noWork=session.EvaluateWithFunctions("irr([-100,110])\n7",FunctionLibrary.Empty,[]);
        Assert.False(noWork.UsesCurrencyRates); Assert.False(noWork.UsesCurrentDate); Assert.False(noWork.UsesCurrentInstant);
    }
    [Fact]
    public void DependenciesAndSavedFunctionsReuseUnrelatedResults()
    {
        var session=new SheetEvaluationSession(); var source="outlay=100\nf(x)=irr([-outlay,x])\n7";
        // Functions remain parameter-only; a captured sheet operand is not a financial closure.
        Assert.NotNull(session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[]).Results[1].Error);
        source="outlay=100\nf(x,y)=irr([-x,y])\nf(outlay,110)\n7";
        session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[]);
        var next=session.EvaluateWithFunctions(source.Replace("outlay=100","outlay=200"),FunctionLibrary.Empty,[]);
        Assert.Equal("-45%",next.Results[2].Display); Assert.Equal(1,session.LastStatistics.ParsedLines); Assert.True(session.LastStatistics.ReusedResults>0);
    }
    [Fact]
    public void RateChangesInvalidateOnlyTheConsumerAndConflictingDatesAreRefused()
    {
        CurrencyRateSnapshot Snapshot(int dollars,DateOnly date) => new("Fixture","EUR",date,new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(dollars,1)});
        var current=Snapshot(2,new(2026,10,30)); var historic=Snapshot(3,new(2023,12,29));
        var context=new EvaluationContext(new(2026,10,31),CurrencyRates:new(current,new Dictionary<DateOnly,CurrencyRateSnapshot>{[new(2024,1,1)]=historic}));
        var session=new SheetEvaluationSession(); var source="flows=[-100 EUR,220 USD]\nirr(flows)\n7";
        session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context);
        var changed=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:context with { CurrencyRates=new(Snapshot(4,new(2026,10,30)),[]) });
        Assert.Equal("-45%",changed.Results[1].Display); Assert.Equal(0,session.LastStatistics.ParsedLines);
        Assert.Equal(1,session.LastStatistics.EvaluatedLines); Assert.Equal(2,session.LastStatistics.ReusedResults);
        var bad=SheetEvaluator.Evaluate("a=100 EUR in USD on 2024-01-01\nb=110 EUR in USD\nirr([-a,b])",context:context)[^1];
        Assert.Contains("different currency snapshots",bad.Error);
    }
    [Theory]
    [InlineData("irr([])")]
    [InlineData("irr([0,0,0])")]
    [InlineData("irr([1,2,3])")]
    [InlineData("irr([-1,-2,-3])")]
    [InlineData("irr([1,-1,1])")]
    [InlineData("irr(1)")]
    [InlineData("irr()")]
    [InlineData("irr([-100,110],-100%)")]
    [InlineData("irr([-100,110],1 m)")]
    [InlineData("irr([-100,110],sqrt(2))")]
    [InlineData("irr([-100,110],10%,20%)")]
    [InlineData("irr(-100,[110])")]
    [InlineData("irr([-100 EUR,110])")]
    [InlineData("irr([-100 EUR/h,110 EUR/h])")]
    [InlineData("irr([-100,unknown])")]
    [InlineData("irr([-100,10%])")]
    public void InvalidOrNoRootInputsDoNotPublishGuesses(string source) => Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);
    [Fact]
    public void CancellationAndCostlyIsolationRemainBounded()
    {
        using var cancel=new CancellationTokenSource(); cancel.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("irr([-1000,300,400,500])",cancel.Token));
        var random=new Random(3072);
        var dense="irr(["+string.Join(',',Enumerable.Range(0,300).Select(_=>random.Next(-1000000,1000001)))+"])";
        Assert.NotNull(SheetEvaluator.Evaluate(dense)[0].Error);
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate(string.Join('\n',Enumerable.Repeat("irr([-1000,300,400,500])",7000))));
    }
}
