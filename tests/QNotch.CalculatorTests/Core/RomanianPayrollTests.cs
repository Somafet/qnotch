using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class RomanianPayrollTests
{
    private static readonly EvaluationContext Context=new(new(2026,10,31),WorkdayRegion:"DE"){PayrollRegion="RO"};
    private static LineResult Last(string source,EvaluationContext? context=null)
    {
        var result=SheetEvaluator.Evaluate(source,context:context??Context)[^1]; Assert.Null(result.Error); return result;
    }
    private static PayrollEvidence Evidence(LineResult result)=>Assert.Single(result.Explanation,step=>step.Payroll is not null).Payroll!;
    private static Rational R(int n)=>new(n,1);
    public static IEnumerable<object[]> OracleGroups()
    {
        using var stream=typeof(RomanianPayrollTests).Assembly.GetManifestResourceStream("Calc.RomanianPayrollOracle")!;
        using var document=JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("groups").EnumerateArray().Select(g=>new object[]{g.GetRawText()}).ToArray();
    }
    private static string Options(JsonElement profile,int minimum)
    {
        var text="";
        if(profile.TryGetProperty("dependants",out var dependants)) text+=$" with {dependants.GetInt32()} dependants";
        if(profile.TryGetProperty("schoolChildren",out var children)) text+=$" with {children.GetInt32()} school children";
        if(profile.TryGetProperty("youthRelief",out var youth) && youth.GetBoolean()) text+=" with youth relief";
        if(profile.TryGetProperty("mainJob",out var main) && !main.GetBoolean()) text+=" without main job";
        if(profile.TryGetProperty("minimumRelief",out var relief) && !relief.GetBoolean()) text+=" without minimum relief";
        if(profile.TryGetProperty("basicAtMinimum",out var basic) && basic.GetBoolean()) text+=$" with basic salary {minimum}";
        return text;
    }
    [Theory]
    [MemberData(nameof(OracleGroups))]
    public void OfficialTableDecimalOracleAndExhaustiveInverseAgree(string json)
    {
        using var document=JsonDocument.Parse(json); var group=document.RootElement;
        var tail=$" in RO for {group.GetProperty("month").GetString()}"+Options(group.GetProperty("profile"),group.GetProperty("minimum").GetInt32());
        foreach(var item in group.GetProperty("cases").EnumerateArray())
        {
            int I(string name)=>item.GetProperty(name).GetInt32();
            var result=Last($"{I("gross")} gross"+tail); var evidence=Evidence(result); var ro=evidence.Romanian!;
            Assert.NotNull(ro); Assert.Equal(R(I("net")),result.Value!.Value.Scalar);
            Assert.Equal(R(I("gross")),ro.MonthlyGross); Assert.Equal(R(I("net")),ro.MonthlyNet);
            Assert.Equal(R(I("basicSalary")),ro.MonthlyBasicSalary); Assert.Equal(R(I("contributionBase")),ro.ContributionBase);
            Assert.Equal(R(I("minimumRelief")),ro.MinimumRelief); Assert.Equal(R(I("baseDeduction")),ro.BaseDeduction);
            Assert.Equal(R(I("youthDeduction")),ro.YouthDeduction); Assert.Equal(R(I("childDeduction")),ro.ChildDeduction);
            Assert.Equal(R(I("appliedDeduction")),ro.AppliedDeduction); Assert.Equal(R(I("taxableIncome")),ro.TaxableIncome);
            Assert.Equal(R(I("employerContribution")),ro.EmployerContribution); Assert.Equal(R(I("employerCost")),ro.EmployerCost);
            foreach(var (name,key) in new[]{("CAS employee pension","cas"),("CASS employee health","cass"),("Income tax","incomeTax")})
                Assert.Equal(R(I(key)*12),Assert.Single(evidence.Deductions,row=>row.Name==name).AnnualAmount);
            Assert.Equal(R(I("gross")*12),evidence.AnnualGross); Assert.Equal(R(I("net")*12),evidence.AnnualNet);
            Assert.Equal(R(I("appliedDeduction")*12),evidence.AnnualAllowance);
            var inverse=Last($"{I("net")} net in gross"+tail);
            Assert.Equal(R(I("lowestInverseGross")),inverse.Value!.Value.Scalar);
            Assert.Equal(R(I("net")),Evidence(inverse).Romanian!.MonthlyNet);
        }
    }
    [Theory]
    [InlineData("5000 gross in RO","2981")]
    [InlineData("10000 brut in RO","5850")]
    [InlineData("4325 gross in RO","2699")]
    [InlineData("3000 net in gross in RO","5036")]
    [InlineData("5000 lei gross","2981 RON")]
    [InlineData("5000 RON/month gross for 2026-07-01","2981 RON/month")]
    [InlineData("60000 RON/year gross for 2026-07-01","35772 RON/year")]
    [InlineData("5000 RON gross in RO for 2026-07-01 in yearly","35772 RON/year")]
    [InlineData("5000 gross in RO in employer cost","5113")]
    [InlineData("4325 RON gross in employer cost","4418 RON")]
    [InlineData("4050 gross in RO for 2026-06-30","2574")]
    [InlineData("4050 gross in RO for 2026-06-01 in employer cost","4134")]
    [InlineData("4325 gross in RO without minimum relief","2616")]
    [InlineData("5000 gross in RO with 1 school child","3013")]
    [InlineData("5000 gross in RO with 2 dependants and 1 school child","3034")]
    [InlineData("5000 gross in RO with youth relief","3046")]
    [InlineData("5000 gross in RO without main job","2925")]
    [InlineData("f(x)=x gross in RO for 2026-07-01 with 1 school child\nf(5000)","3013")]
    [InlineData("net=3\ngross=4\nnet+gross","7")]
    [InlineData("100000 gross in US for 2026-06-01","79180")]
    [InlineData("50000 gross in UK for 2027-04-05","39519.6")]
    public void PublishedExamplesTypedPeriodsAndProfileOptions(string source,string expected)=>Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("5000 gross in RO for 2026")]
    [InlineData("5000 gross in RO for 2025-12-31")][InlineData("5000 gross in RO for 2027-01-01")]
    [InlineData("4050 gross in RO for 2026-07-01")][InlineData("4324 gross in RO")]
    [InlineData("5000.5 gross in RO")][InlineData("3000.5 net in gross in RO")]
    [InlineData("60001 RON/year gross in RO")][InlineData("8333334 gross in RO")]
    [InlineData("5000 gross in RO with -1 dependants")][InlineData("5000 gross in RO with 101 dependants")]
    [InlineData("5000 gross in RO with 1 dependants and 2 school children")]
    [InlineData("5000 gross in RO with 1 school child without main job")]
    [InlineData("5000 gross in RO with youth relief without main job")]
    [InlineData("5000 gross in RO with basic salary 5100")][InlineData("5000 gross in RO with basic salary 4000")]
    [InlineData("5000 gross in RO with 1 dependants with 2 dependants")]
    [InlineData("5000 gross in RO with age 25")][InlineData("5000 gross in RO without deductions")]
    [InlineData("5000 gross in RO for 2026-07-01 for 2026")]
    [InlineData("5000 gross in RO for 2026-02-30")]
    [InlineData("5000 gross in US for 2026 with 1 school child")]
    [InlineData("5000 gross in UK for 2026 in employer cost")]
    [InlineData("1 net in gross in RO")][InlineData("8333333 net in gross in RO")]
    [InlineData("5000 kg gross in RO")][InlineData("5000% gross in RO")]
    public void AmbiguousUnsupportedAndIneligibleInputsFailExplicitly(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source,context:Context)[^1].Error);

    [Fact]
    public void MonthRolloverRegionInferenceAndPinnedCallsInvalidateOnlyConsumers()
    {
        var session=new SheetEvaluationSession(); const string source="5000 RON gross\n5000 RON gross for 2026-06-01\n7";
        var before=session.Evaluate(source,context:Context with{Today=new(2026,6,30)});
        var after=session.Evaluate(source,context:Context with{Today=new(2026,7,1)});
        Assert.NotEqual(before[0].Display,after[0].Display); Assert.Equal(before[1],after[1]);
        Assert.Equal(0,session.LastStatistics.ParsedLines); Assert.Equal(2,session.LastStatistics.ReusedResults);
        Assert.True(session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Context with{Today=new(2026,7,1)}).UsesCurrentDate);
        var pinned=session.EvaluateWithFunctions("f(x)=x gross in RO for 2026-06-01\nf(5000 RON)",FunctionLibrary.Empty,[]);
        Assert.Null(pinned.Results[^1].Error); Assert.False(pinned.UsesCurrentDate);
        Assert.Equal("2981",Last("5000 gross for 2026-07-01").Display);
        Assert.Equal("2981 RON",Last("5000 RON gross for 2026-07-01",Context with{PayrollRegion="US"}).Display);
        Assert.NotNull(SheetEvaluator.Evaluate("5000 gross",context:Context with{PayrollRegion=new string('X',100000)})[0].Error);
    }
    [Fact]
    public void RoundingJumpsUseLowestExactInverseAndNeverGlobalMonotoneSearch()
    {
        Assert.Equal("2699",Last("4325 gross in RO").Display);
        Assert.Equal("2614",Last("4326 gross in RO").Display);
        Assert.Equal("4326",Last("2614 net in gross in RO").Display);
        Assert.Equal("4325",Last("2699 net in gross in RO").Display);
        var edge=Last("6325 gross in RO with 4 dependants and youth relief");
        var after=Last("6326 gross in RO with 4 dependants and youth relief");
        Assert.True(edge.Value!.Value.Scalar.Numerator>after.Value!.Value.Scalar.Numerator);
        Assert.Equal(after.Value.Value.Scalar,Evidence(Last($"{after.Display} net in gross in RO with 4 dependants and youth relief")).Romanian!.MonthlyNet);
    }
    [Fact]
    public void PinnedRuleMonthRemainsGregorianAcrossDisplayCultures()
    {
        var previous=System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture=new("ar-SA");
            var result=Last("5000 RON gross in RO for 2026-07-01");
            Assert.Equal("2981 RON",result.Display);
            Assert.Contains("payroll month 2026-07",Assert.Single(result.Explanation,step=>step.Payroll is not null).Assumption);
        }
        finally { System.Globalization.CultureInfo.CurrentCulture=previous; }
    }
    [Fact]
    public void CurrencyContextSourceEvidenceAndSharedBoundsRemainExplicit()
    {
        var snapshot=new CurrencyRateSnapshot("Test only","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=R(1),["RON"]=R(5)});
        var result=Last("1000 EUR gross in RO for 2026-07-01",Context with{CurrencyRates=new(snapshot,[])});
        Assert.Equal("2981 RON",result.Display); Assert.Contains("not statutory BNR",Assert.Single(result.Explanation,step=>step.Payroll is not null).Assumption);
        var evidence=Evidence(result); Assert.Equal("RO-employee-2026-H2-v1",evidence.RuleVersion);
        Assert.Equal(new DateOnly(2026,7,1),evidence.Romanian!.PayrollMonth);
        Assert.Equal(4,evidence.Sources.Count); Assert.Contains("Whole-leu",evidence.Basis);
        var cap=Last("8333333 gross in RO for 2026-07-01"); Assert.Equal(R(8333333*12),Evidence(cap).AnnualGross);
        using var cancelled=new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("3000 net in gross in RO",cancelled.Token,context:Context));
    }
}
