using System.Globalization;
using System.Numerics;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class PayrollTests
{
    private static EvaluationContext Context(DateOnly? today=null,string? region=null)=>new(today??new(2026,10,31),WorkdayRegion:"DE"){PayrollRegion=region};
    private static LineResult Last(string source,EvaluationContext? context=null)
    { var result=SheetEvaluator.Evaluate(source,context:context??Context())[^1]; Assert.Null(result.Error); return result; }
    private static PayrollEvidence Evidence(LineResult result)=>Assert.Single(result.Explanation,step=>step.Payroll is not null).Payroll!;
    private static Rational Parse(string value)
    { var parts=value.Split('/'); return new(BigInteger.Parse(parts[0],CultureInfo.InvariantCulture),parts.Length==1?BigInteger.One:BigInteger.Parse(parts[1],CultureInfo.InvariantCulture)); }
    private static Rational Amount(LineResult result)
    {
        var value=result.Value!.Value;
        if(value.Kind==SheetValueKind.Earnings) value=value.Earnings.Amount;
        return value.Kind==SheetValueKind.Money?value.Money.Magnitude.Scalar:value.Scalar;
    }
    public static IEnumerable<object[]> OracleCases()
    {
        using var stream=typeof(PayrollTests).Assembly.GetManifestResourceStream("Calc.PayrollOracle")!;
        using var document=JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("cases").EnumerateArray().Select(item=>new object[]{item.GetRawText()}).ToArray();
    }
    [Theory]
    [MemberData(nameof(OracleCases))]
    public void IndependentAnnualOracleChecksEveryDeductionAndExactInverse(string json)
    {
        using var document=JsonDocument.Parse(json); var entry=document.RootElement;
        var country=entry.GetProperty("country").GetString(); var gross=entry.GetProperty("grossAnnual").GetString()!; var net=entry.GetProperty("netAnnual").GetString()!;
        var result=Last($"({gross}) gross in {country} for 2026"); var evidence=Evidence(result);
        Assert.Equal(Parse(net),Amount(result)); Assert.Equal(Parse(gross),evidence.AnnualGross);
        Assert.Equal(Parse(entry.GetProperty("allowanceAnnual").GetString()!),evidence.AnnualAllowance);
        Assert.Equal(Parse(entry.GetProperty("taxableAnnual").GetString()!),evidence.AnnualTaxableIncome);
        foreach(var item in entry.GetProperty("deductionsAnnual").EnumerateObject())
            Assert.Equal(Parse(item.Value.GetString()!),Assert.Single(evidence.Deductions,row=>row.Name==item.Name).AnnualAmount);
        var inverse=Last($"({net}) net in gross in {country} for 2026");
        Assert.Equal(Parse(gross),Amount(inverse)); Assert.True(Evidence(inverse).Inverse);
    }
    [Theory]
    [InlineData("100000 gross in US","79180")]
    [InlineData("50000 gross in UK","39519.6")]
    [InlineData("100k USD gross","79180 USD")]
    [InlineData("50k GBP brut","39519.6 GBP")]
    [InlineData("50000 brutto in GB for 2026","39519.6")]
    [InlineData("79180 net in gross in US for 2026","100000")]
    [InlineData("39519.6 GBP net in gross for 2026","50000 GBP")]
    [InlineData("100000 gross in US for 2026 in monthly","6598.3333/month")]
    [InlineData("5000 GBP/month gross in UK for 2026","3779.78 GBP/month")]
    [InlineData("50000 GBP/year gross in UK for 2026","39519.6 GBP/year")]
    [InlineData("(100000 gross in US for 2026)*2","158360")]
    [InlineData("r=100000\nr gross in US for 2026","79180")]
    [InlineData("f(x)=x gross in US for 2026\nf(100000)","79180")]
    [InlineData("f(x)=x net in gross in UK for 2026\nf(39519.6)","50000")]
    [InlineData("gross=12\ngross+2","14")]
    [InlineData("net=12\nnet+2","14")]
    [InlineData("2027-03-01 net 30","2027-03-31")]
    [InlineData("0 gross in US for 2026","0")]
    [InlineData("0 net in gross in UK for 2026","0")]
    public void PublishedAndTypedExamples(string source,string expected)=>Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("-1 gross in US for 2026")][InlineData("100000001 gross in US for 2026")]
    [InlineData("100000000 net in gross in US for 2026")]
    [InlineData("10000 gross in RO for 2026")][InlineData("60000 gross in DE for 2025")]
    [InlineData("100000 gross in US for 2025")][InlineData("50000 gross in UK for 2027")]
    [InlineData("100 kg gross in US for 2026")][InlineData("100% gross in US for 2026")]
    [InlineData("100 GBP/h gross in UK for 2026")]
    [InlineData("(100 GBP/h in hourly) gross in UK for 2026")]
    [InlineData("100000 gross in US for 2026 for 2026")]
    [InlineData("100000 gross in US in UK for 2026")]
    [InlineData("100000 gross in US for 2026 nonsense")]
    [InlineData("100000 net in gross in ZZ for 2026")]
    public void UnsupportedInputsDoNotGuess(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source,context:Context())[^1].Error);

    [Fact]
    public void TaxYearBoundaryAndCountryFallbackHavePreciseContextDependencies()
    {
        Assert.NotNull(SheetEvaluator.Evaluate("50000 GBP gross",context:Context(new(2026,4,5)))[0].Error);
        Assert.Equal("39519.6 GBP",Last("50000 GBP gross",Context(new(2026,4,6))).Display);
        Assert.Equal("39519.6 GBP",Last("50000 GBP gross",Context(new(2027,4,5))).Display);
        Assert.NotNull(SheetEvaluator.Evaluate("50000 GBP gross",context:Context(new(2027,4,6)))[0].Error);
        var session=new SheetEvaluationSession(); const string source="100000 gross for 2026\n2+2";
        var first=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Context(region:"US"));
        var changed=session.EvaluateWithFunctions(source,FunctionLibrary.Empty,[],context:Context(region:"UK"));
        Assert.Equal("79180",first.Results[0].Display); Assert.Equal("68557.4",changed.Results[0].Display);
        Assert.Equal(0,session.LastStatistics.ParsedLines); Assert.Equal(1,session.LastStatistics.ReusedResults);
        var pinned=session.EvaluateWithFunctions("100000 gross in US for 2026\n50000 GBP gross for 2026",FunctionLibrary.Empty,[]);
        Assert.All(pinned.Results,result=>Assert.Null(result.Error)); Assert.False(pinned.UsesCurrentDate); Assert.False(pinned.UsesCurrencyRates); Assert.False(pinned.UsesCurrentInstant);
        Assert.Equal("79180",Last("100000 gross",Context(region:"US")).Display);
        Assert.Equal("79180 USD",Last("100000 USD gross",Context(region:"UK")).Display);
    }

    [Fact]
    public void MoneyConversionApproximationAndSalaryPeriodArePreserved()
    {
        var snapshot=new CurrencyRateSnapshot("Salary fixture","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(2,1),["GBP"]=new(1,1)});
        var context=Context() with{CurrencyRates=new(snapshot,[])};
        Assert.Equal("79180 USD",Last("50000 EUR gross in US for 2026",context).Display);
        var approximate=Last("x=loan 250000 at 4.99% for 30 years\nx USD gross in US for 2026");
        Assert.StartsWith("≈ ",approximate.Display); Assert.True(Evidence(approximate).InputApproximate);
        var hourly=Last("100000 USD gross in US for 2026 in hourly");
        Assert.Equal(new Rational(79180,254*8),Amount(hourly));
        var saved=Last("f(x)=x gross in US for 2026 in hourly\nholidays=[2026-01-02]\nf(100000 USD)");
        Assert.Equal(new Rational(79180,253*8),Amount(saved));
    }

    [Fact]
    public void GrossNetConservationAndIncrementalUpdatesRetainExactInputs()
    {
        var session=new SheetEvaluationSession(); const string source="gross amount=100000\ngross amount gross in US for 2026\n7";
        var first=session.Evaluate(source,context:Context()); var changed=session.Evaluate(source.Replace("=100000","=200000"),context:Context());
        Assert.Equal("79180",first[1].Display); Assert.Null(changed[1].Error);
        Assert.Equal(1,session.LastStatistics.ParsedLines); Assert.True(session.LastStatistics.ReusedResults>0);
        var evidence=Evidence(changed[1]); var total=default(Rational);
        foreach(var row in evidence.Deductions) total+=row.AnnualAmount;
        Assert.Equal(evidence.AnnualGross,evidence.AnnualNet+total);
        Assert.Equal(new Rational(100000,1),Amount(Last("n=100000 gross in US for 2026\nn net in gross in US for 2026")));
        using var cancel=new CancellationTokenSource(); cancel.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("79180 net in gross in US for 2026",cancel.Token));
    }

    [Fact]
    public void RuleManifestAndPublicEvidenceIdentifyOnlyAuditedModels()
    {
        using var stream=typeof(PayrollTests).Assembly.GetManifestResourceStream("Calc.PayrollRules")!;
        using var document=JsonDocument.Parse(stream);
        foreach(var model in document.RootElement.GetProperty("models").EnumerateArray())
        {
            var country=model.GetProperty("country").GetString();
            var date=country=="RO"?model.GetProperty("validFrom").GetString():"2026";
            var flat=model.GetProperty("id").GetString()=="HU-atalanyado-2026-v1";
            var evidence=Evidence(Last($"100000 gross in {country} for {date}"+(flat?" with átalányadó":"")));
            Assert.Equal(model.GetProperty("id").GetString(),evidence.RuleVersion);
            Assert.Equal(model.GetProperty("taxYear").GetInt32(),evidence.TaxYear);
            Assert.All(evidence.Sources,source=>Assert.Contains(model.GetProperty("sources").EnumerateArray(),value=>value.GetString()==source));
            if(country=="RO")
            {
                var minimum=model.GetProperty("minimumMonthlyGross").GetInt32();
                var relief=model.GetProperty("minimumRelief").GetInt32();
                var ceiling=model.GetProperty("minimumReliefGrossCeiling").GetInt32();
                var atMinimum=Evidence(Last($"{minimum} gross in RO for {date}")).Romanian!;
                Assert.Equal(new Rational(relief,1),atMinimum.MinimumRelief);
                Assert.Equal(new Rational(minimum-relief,1),atMinimum.ContributionBase);
                var atCeiling=Evidence(Last($"{ceiling} gross in RO for {date} with basic salary {minimum}")).Romanian!;
                var afterCeiling=Evidence(Last($"{ceiling+1} gross in RO for {date} with basic salary {minimum}")).Romanian!;
                Assert.Equal(new Rational(relief,1),atCeiling.MinimumRelief);
                Assert.Equal(default(Rational),afterCeiling.MinimumRelief);
            }
        }
        var german=document.RootElement.GetProperty("models").EnumerateArray().Single(model=>model.GetProperty("country").GetString()=="DE");
        var ceilings=german.GetProperty("annualCeilings"); var rates=german.GetProperty("employeeRatesPercent");
        decimal Rate(string name)=>decimal.Parse(rates.GetProperty(name).GetString()!,System.Globalization.CultureInfo.InvariantCulture)/100m;
        var high=Evidence(Last("200000 gross in DE for 2026")).German!;
        Assert.Equal(decimal.Round(ceilings.GetProperty("pensionAndUnemployment").GetInt32()*Rate("pension"),2,MidpointRounding.AwayFromZero),high.Pension);
        Assert.Equal(decimal.Round(ceilings.GetProperty("healthAndCare").GetInt32()*(Rate("healthGeneral")+Rate("healthSurchargeDefaultFull")/2),2,MidpointRounding.AwayFromZero),high.Health);
        Assert.Equal(decimal.Round(ceilings.GetProperty("healthAndCare").GetInt32()*(Rate("care")+Rate("childlessCareSurcharge")),2,MidpointRounding.AwayFromZero),high.Care);
        var models=document.RootElement.GetProperty("models").EnumerateArray().ToArray();
        var hu=models.Single(model=>model.GetProperty("id").GetString()=="HU-atalanyado-2026-v1");
        Assert.Equal(HungarianPayrollRules.TaxFreeIncome,hu.GetProperty("taxFreeIncome").GetInt64());
        Assert.Equal(HungarianPayrollRules.RevenueCeiling,hu.GetProperty("revenueCeiling").GetInt64());
        Assert.Equal(HungarianPayrollRules.RetailRevenueCeiling,hu.GetProperty("retailRevenueCeiling").GetInt64());
        var employee=models.Single(model=>model.GetProperty("id").GetString()=="HU-employee-2026-v1");
        Assert.Equal(HungarianPayrollRules.MinimumWage,employee.GetProperty("minimumWage").GetInt64());
        Assert.Equal(HungarianPayrollRules.GuaranteedMinimumWage,employee.GetProperty("guaranteedMinimumWage").GetInt64());
        Assert.Equal(HungarianPayrollRules.YouthMonthlyCap,employee.GetProperty("monthlyAllowances").GetProperty("youthCap").GetInt64());
        Assert.Equal(7,models.Length);
    }

    [Fact]
    public void ExpensiveSalarySheetsShareTheExistingComputationLimit()
    {
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate(string.Join('\n',Enumerable.Repeat("79180 net in gross in US for 2026",5000))));
    }
}
