using System.Numerics;
using System.Globalization;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class RomanianTaxTests
{
    private static LineResult Last(string source)
    { var result=SheetEvaluator.Evaluate(source)[^1]; Assert.Null(result.Error); return result; }
    private static Rational Rational(string value)
    { var parts=value.Split('/'); return new(BigInteger.Parse(parts[0],CultureInfo.InvariantCulture),parts.Length==1?BigInteger.One:BigInteger.Parse(parts[1],CultureInfo.InvariantCulture)); }
    private static Rational Amount(LineResult result)=>result.Value!.Value.Kind==SheetValueKind.Money?result.Value.Value.Money.Magnitude.Scalar:result.Value.Value.Scalar;
    private static RomanianTaxEvidence Evidence(LineResult result)=>Assert.Single(result.Explanation,step=>step.RomanianTax is not null).RomanianTax!;
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream=typeof(RomanianTaxTests).Assembly.GetManifestResourceStream("Calc.RomanianTaxOracle")!;
        using var document=JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray().Select(item=>new object[]{item.GetRawText()}).ToArray();
    }
    [Theory]
    [MemberData(nameof(OracleCases))]
    public void IndependentExactTaxAndContributionOracle(string json)
    {
        using var document=JsonDocument.Parse(json); var item=document.RootElement;
        var result=Last(item.GetProperty("source").GetString()!); var evidence=Evidence(result);
        Assert.Equal(Rational(item.GetProperty("output").GetString()!),Amount(result));
        Assert.Equal(Rational(item.GetProperty("taxable").GetString()!),evidence.TaxableAmount);
        if(item.GetProperty("total").ValueKind==JsonValueKind.Null) Assert.Null(evidence.TotalLiability);
        else Assert.Equal(Rational(item.GetProperty("total").GetString()!),evidence.TotalLiability);
        foreach(var row in item.GetProperty("charges").EnumerateObject())
            Assert.Equal(Rational(row.Value.GetString()!),Assert.Single(evidence.Charges,charge=>charge.Name==row.Name).Amount);
        Assert.Equal(item.GetProperty("charges").EnumerateObject().Count(),evidence.Charges.Count);
        void Optional(string name,Rational? actual)
        { if(item.GetProperty(name).ValueKind==JsonValueKind.Null) Assert.Null(actual); else Assert.Equal(Rational(item.GetProperty(name).GetString()!),actual); }
        Optional("remaining",evidence.RemainingCash); Optional("pensionBase",evidence.PensionBase);
        Optional("healthBase",evidence.HealthBase); Optional("deductibleHealth",evidence.DeductibleHealth);
        Assert.Contains("BEFORE",evidence.Basis); Assert.False(evidence.InputApproximate);
    }
    [Theory]
    [InlineData("pfaNetRO(120000,20000,2026)","59130")]
    [InlineData("pfaTaxRO(120000 RON,20000 RON,2026)","40870 RON")]
    [InlineData("pfaNetRO(10000,0,2026)","6670")]
    [InlineData("pfaNetRO(10000,0,2026,0,1)","8100")]
    [InlineData("pfaNetRO(100000,0,2026,1,0)","81000")]
    [InlineData("pfaNetRO(0,1000,2026)","-1000")]
    [InlineData("microTaxRO([10000 RON,20000 RON],50000 EUR,2026)","300 RON")]
    [InlineData("microTaxRO(100000,100000,2026)","1000")]
    [InlineData("dividendTaxRO(100000 RON,2026)","16000 RON")]
    [InlineData("dividendCashRO(100000 RON,2026)","84000 RON")]
    [InlineData("investmentCassRO(dividendCashRO(100000 RON,2026),2026)","4860 RON")]
    [InlineData("investmentCassRO([12000 RON,12300 RON],2026)","2430 RON")]
    [InlineData("stockTaxRO([1000,-900],2026)","16")]
    [InlineData("stockTaxRO(1000,2026,1000)","48")]
    [InlineData("brokerTaxRO([1000,-900],365,2026)","30")]
    [InlineData("brokerTaxRO([1000 RON,1000 RON],[364,365],2026)","90 RON")]
    [InlineData("brokerGainsRO([1000 RON,-900 RON],2026)","1000 RON")]
    [InlineData("cryptoTaxRO([199,199,199],2026)","0")]
    [InlineData("cryptoTaxRO([200,200,200],2026)","96")]
    [InlineData("cryptoTaxRO([199,199,199,4,-1000],2026)","96.16")]
    [InlineData("cash=dividendCashRO(100000 RON,2026)\ncash-investmentCassRO(cash,2026)","79140 RON")]
    [InlineData("f(x)=pfaNetRO(x,20000 RON,2026)\nf(120000 RON)","59130 RON")]
    [InlineData("f(x)=brokerTaxRO(x,365,2026)\nf([1000,-900])","30")]
    public void DeclaredProfilesComposeWithListsMoneyAndSavedCalls(string source,string expected)=>Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("pfaNetRO(10000,0)")][InlineData("pfaNetRO(10000,0,2025)")][InlineData("pfaNetRO(10000,0,2027)")]
    [InlineData("pfaNetRO(-1,0,2026)")][InlineData("pfaNetRO(0,-1,2026)")]
    [InlineData("pfaNetRO(100000001,0,2026)")][InlineData("pfaNetRO(10000,0,2026,2)")]
    [InlineData("pfaNetRO(10000,0,2026,0,-1)")][InlineData("pfaNetRO(10000 EUR,0,2026)")]
    [InlineData("pfaNetRO(10000 RON/year,0,2026)")][InlineData("pfaNetRO([10000],0,2026)")]
    [InlineData("pfaNetRO(10000 kg,0,2026)")][InlineData("pfaNetRO(10000%,0,2026)")]
    [InlineData("microTaxRO(1000,100001,2026)")][InlineData("microTaxRO(1000,-1,2026)")]
    [InlineData("microTaxRO(1000,1000 RON,2026)")][InlineData("microTaxRO(-1,1000,2026)")]
    [InlineData("microTaxRO([1,2,3,4,5],1000,2026)")]
    [InlineData("dividendTaxRO(-1,2026)")][InlineData("dividendTaxRO(1000,2025)")]
    [InlineData("investmentCassRO([-1,24300],2026)")][InlineData("investmentCassRO([100000000,1],2026)")]
    [InlineData("brokerTaxRO([1000,2000],[1,2,3],2026)")][InlineData("brokerTaxRO(1000,-1,2026)")]
    [InlineData("brokerTaxRO(1000,365.5,2026)")][InlineData("brokerTaxRO(1000,365 days,2026)")]
    [InlineData("brokerTaxRO(1000,100001,2026)")][InlineData("brokerTaxRO(1000,[],2026)")]
    [InlineData("brokerTaxRO([100000000,100000000,-100000000],365,2026)")]
    [InlineData("cryptoTaxRO(1000 USD,2026)")][InlineData("stockTaxRO(1000,2026,-1)")]
    [InlineData("stockTaxRO(1000,2026,100000001)")]
    public void UnsupportedAmbiguousAndOutOfBoundInputsFail(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source)[^1].Error);

    [Fact]
    public void EvidenceDistinguishesPfaFloorAndInvestmentAggregationWithoutClockOrRates()
    {
        var pfa=Evidence(Last("pfaNetRO(10000,0,2026)"));
        Assert.Equal(new Rational(1000,1),pfa.DeductibleHealth);
        Assert.Equal(new Rational(1430,1),Assert.Single(pfa.Charges,row=>row.Name.Contains("top-up")).Amount);
        Assert.Equal(new Rational(900,1),Assert.Single(pfa.Charges,row=>row.Name=="Income tax").Amount);
        var session=new SheetEvaluationSession();
        const string source="pfaNetRO(120000 RON,20000 RON,2026)\ninvestmentCassRO([12000 RON,12300 RON],2026)";
        var evaluated=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:new(new(2027,1,1)));
        Assert.All(evaluated.Results,row=>Assert.Null(row.Error)); Assert.False(evaluated.UsesCurrentDate); Assert.False(evaluated.UsesCurrentInstant); Assert.False(evaluated.UsesCurrencyRates);
        var unchanged=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:new(new(2030,7,1)));
        Assert.Equal(0,session.LastStatistics.EvaluatedLines); Assert.Equal(2,session.LastStatistics.ReusedResults);
        Assert.Equal(evaluated.Results,unchanged.Results);
        Assert.Equal("0",Last("investmentCassRO(12000,2026)").Display);
        Assert.Equal("2430",Last("investmentCassRO([12000,12300],2026)").Display);
        var helper=Last("brokerGainsRO([1000,-900],2026)");
        Assert.Null(Evidence(helper).TotalLiability);
        Assert.Contains("tax liability not calculated",Assert.Single(helper.Explanation,step=>step.RomanianTax is not null).Assumption);
    }
    [Fact]
    public void CurrencySnapshotsAndUpstreamApproximationArePreservedWithoutImplicitConversion()
    {
        var rates=new CurrencyRateSnapshot("Test only","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["RON"]=new(5,1)});
        var result=SheetEvaluator.Evaluate("dividendTaxRO(100 EUR in RON,2026)",context:new(new(2026,10,31),CurrencyRates:new(rates,[])))[0];
        Assert.Null(result.Error); Assert.Equal("80 RON",result.Display); Assert.NotNull(result.Value!.Value.Money.RateStamp);
        Assert.Contains("not a statutory BNR",Assert.Single(result.Explanation,step=>step.RomanianTax is not null).Assumption);
        var earlier=new CurrencyRateSnapshot("Earlier test only","EUR",new(2025,12,31),new(2026,1,1,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["RON"]=new(4,1)});
        var mixed=SheetEvaluator.Evaluate("a=100 EUR in RON on 2025-12-31\nb=100 EUR in RON\ndividendTaxRO([a,b],2026)",
            context:new(new(2026,10,31),CurrencyRates:new(rates,new Dictionary<DateOnly,CurrencyRateSnapshot>{[earlier.AsOf]=earlier})));
        Assert.Null(mixed[0].Error); Assert.Null(mixed[1].Error); Assert.Contains("conflicting currency snapshots",mixed[2].Error);
        var approximate=Last("x=loan 250000 at 4.99% for 30 years\ndividendTaxRO(x RON,2026)");
        Assert.StartsWith("≈ ",approximate.Display); Assert.True(Evidence(approximate).InputApproximate);
        using var cancellation=new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("pfaNetRO(120000,0,2026)",cancellation.Token));
    }
    [Fact]
    public void ListTaxCallsShareTheWholeSheetComputationLimit()
    {
        var source="g=["+string.Join(',',Enumerable.Range(1,256))+"]\n"+string.Join('\n',Enumerable.Repeat("cryptoTaxRO(g,2026)",500));
        Assert.True(source.Length<200000);
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate(source));
    }
    [Fact]
    public void RuleManifestEnumeratesEveryImplementedModelAndOfficialSources()
    {
        using var stream=typeof(RomanianTaxTests).Assembly.GetManifestResourceStream("Calc.RomanianTaxRules")!;
        using var document=JsonDocument.Parse(stream); var root=document.RootElement;
        Assert.Equal(2026,root.GetProperty("taxYear").GetInt32()); Assert.Equal(4050,root.GetProperty("januaryMinimum").GetInt32());
        var examples=new Dictionary<string,string>{["pfanetro"]="120000,20000,2026",["pfataxro"]="120000,20000,2026",["microtaxro"]="100000,100000,2026",
            ["dividendtaxro"]="100000,2026",["dividendcashro"]="100000,2026",["stocktaxro"]="1000,2026",["brokertaxro"]="1000,365,2026",["brokergainsro"]="1000,2026",["cryptotaxro"]="1000,2026",["investmentcassro"]="24300,2026"};
        var seen=new HashSet<string>();
        foreach(var model in root.GetProperty("models").EnumerateArray())
        foreach(var function in model.GetProperty("functions").EnumerateArray())
        {
            var name=function.GetString()!.ToLowerInvariant(); Assert.True(seen.Add(name));
            var evidence=Evidence(Last(name+"("+examples[name]+")"));
            Assert.Equal(model.GetProperty("id").GetString(),evidence.RuleVersion);
            Assert.All(evidence.Sources,url=>Assert.Contains(model.GetProperty("sources").EnumerateArray(),source=>source.GetString()==url));
        }
        Assert.Equal(examples.Keys.Order(),seen.Order());
    }
    [Fact]
    public void BuiltinsCannotBeOverriddenAndInvalidSavedAritiesFailBeforeInvocation()
    {
        Assert.Throws<FormatException>(()=>new FunctionLibrary([new("pfaNetRO",["x"],"x")]));
        Assert.Throws<FormatException>(()=>new FunctionLibrary([new("f",["x"],"pfaNetRO(x,2026)")]));
        Assert.NotNull(SheetEvaluator.Evaluate("f(x)=microTaxRO(x,2026)")[0].Error);
        var session=new SheetEvaluationSession(); var before=session.Evaluate("x=10000\npfaNetRO(x,0,2026)\n2+2");
        var changed=session.Evaluate("x=20000\npfaNetRO(x,0,2026)\n2+2");
        Assert.NotEqual(before[1].Display,changed[1].Display); Assert.Equal(1,session.LastStatistics.ParsedLines); Assert.True(session.LastStatistics.ReusedResults>0);
    }
}
