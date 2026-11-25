using System.Globalization;
using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class GermanPayrollTests
{
    private static readonly EvaluationContext Context=new(new(2026,10,31),WorkdayRegion:"DE"){PayrollRegion="DE"};
    private static LineResult Last(string source,EvaluationContext? context=null)
    {
        var result=SheetEvaluator.Evaluate(source,context:context??Context)[^1]; Assert.Null(result.Error); return result;
    }
    private static PayrollEvidence Evidence(LineResult result)=>Assert.Single(result.Explanation,step=>step.Payroll is not null).Payroll!;
    private static string Euros(long cents)=>(cents/100m).ToString(CultureInfo.InvariantCulture);
    private static JsonDocument Resource(string name)
    {
        using var stream=typeof(GermanPayrollTests).Assembly.GetManifestResourceStream(name)!;
        return JsonDocument.Parse(stream);
    }
    private static string Options(JsonElement profile)
    {
        var text="";
        if(profile.TryGetProperty("taxClass",out var klass)) text+=$" with tax class {klass.GetInt32()}";
        if(profile.TryGetProperty("children",out var children)) text+=$" with {children.GetInt32()} children";
        if(profile.TryGetProperty("childAllowance",out var allowance)) text+=$" with child allowance {allowance.GetString()}";
        if(profile.TryGetProperty("churchTax",out var church)) text+=$" with church tax {church.GetInt32()}%";
        if(profile.TryGetProperty("saxony",out var saxony) && saxony.GetBoolean()) text+=" with Saxony";
        if(profile.TryGetProperty("healthSurcharge",out var surcharge)) text+=$" with health surcharge {surcharge.GetString()}%";
        if(profile.TryGetProperty("childlessSurcharge",out var childless) && !childless.GetBoolean()) text+=" without childless surcharge";
        return text;
    }
    private static string Amount(long cents,string period)=>period=="month"?Euros(cents)+" EUR/month":Euros(cents);

    public static IEnumerable<object[]> TableRows()
    {
        using var document=Resource("Calc.GermanWageTaxTable");
        return document.RootElement.GetProperty("general").GetProperty("rows").EnumerateArray()
            .Where(row=>row.GetProperty("annualGross").GetInt32()>24000).Select(row=>new object[]{row.GetRawText()}).ToArray();
    }
    [Theory]
    [MemberData(nameof(TableRows))]
    public void OfficialBmfTestTableMatchesThroughSheetGrammar(string json)
    {
        // Pruftabelle footnotes: ALV=KRV=PKV=0, KVZ=2.90 (the default), PVZ=0 in class II and 1 otherwise.
        using var document=JsonDocument.Parse(json); var row=document.RootElement;
        var gross=row.GetProperty("annualGross").GetInt32(); var expected=row.GetProperty("annualWageTaxByClass").EnumerateArray().Select(v=>v.GetInt32()).ToArray();
        for(var klass=1;klass<=6;klass++)
        {
            var source=$"{gross} gross in DE for 2026 with tax class {klass}"+(klass==2?" without childless surcharge":"");
            var german=Evidence(Last(source)).German!;
            Assert.Equal(expected[klass-1],german.WageTax);
            Assert.Equal("annual",german.Period);
        }
    }

    public static IEnumerable<object[]> OracleGroups()
    {
        using var document=Resource("Calc.GermanPayrollOracle");
        return document.RootElement.GetProperty("groups").EnumerateArray().Select(g=>new object[]{g.GetRawText()}).ToArray();
    }
    [Theory]
    [MemberData(nameof(OracleGroups))]
    public void ForwardMatchesOfficialPseudoCodeOracle(string json)
    {
        using var document=JsonDocument.Parse(json); var group=document.RootElement;
        var period=group.GetProperty("period").GetString()!; var tail=" gross in DE for 2026"+Options(group.GetProperty("profile"));
        foreach(var item in group.GetProperty("cases").EnumerateArray())
        {
            long L(string name)=>item.GetProperty(name).GetInt64();
            decimal E(string name)=>L(name)/100m;
            var result=Last(Amount(L("gross"),period)+tail); var evidence=Evidence(result); var german=evidence.German!;
            Assert.Equal(Amount(L("net"),period),result.Display);
            Assert.Equal(E("gross"),german.Gross); Assert.Equal(E("net"),german.Net);
            Assert.Equal(E("wageTax"),german.WageTax); Assert.Equal(E("solidarity"),german.Solidarity);
            Assert.Equal(E("churchBase"),german.ChurchTaxBase); Assert.Equal(E("churchTax"),german.ChurchTax);
            Assert.Equal(E("pension"),german.Pension); Assert.Equal(E("unemployment"),german.Unemployment);
            Assert.Equal(E("health"),german.Health); Assert.Equal(E("care"),german.Care);
            var periods=period=="month"?12:1;
            Assert.Equal(Rational.Parse((E("net")*periods).ToString(CultureInfo.InvariantCulture)),evidence.AnnualNet);
            Assert.Equal(Rational.Parse((E("wageTax")*periods).ToString(CultureInfo.InvariantCulture)),Assert.Single(evidence.Deductions,row=>row.Name=="Wage tax").AnnualAmount);
            Assert.Equal(7,evidence.Deductions.Count);
        }
    }

    public static IEnumerable<object[]> InverseWindows()
    {
        using var document=Resource("Calc.GermanPayrollOracle");
        return document.RootElement.GetProperty("inverse").EnumerateArray().Select(g=>new object[]{g.GetRawText()}).ToArray();
    }
    [Theory]
    [MemberData(nameof(InverseWindows))]
    public void InverseReturnsLowestGrossFromExhaustiveEnumeration(string json)
    {
        using var document=JsonDocument.Parse(json); var window=document.RootElement;
        var period=window.GetProperty("period").GetString()!; var tail=" net in gross in DE for 2026"+Options(window.GetProperty("profile"));
        foreach(var target in window.GetProperty("targets").EnumerateArray())
        {
            var net=target.GetProperty("net").GetInt64();
            var result=SheetEvaluator.Evaluate(Amount(net,period)+tail,context:Context)[^1];
            if(target.GetProperty("lowestGross").ValueKind==JsonValueKind.Null) { Assert.Contains("exact net",result.Error); continue; }
            var gross=target.GetProperty("lowestGross").GetInt64();
            Assert.Null(result.Error);
            Assert.Equal(period=="month"?Euros(gross)+" EUR/month":Euros(gross),result.Display);
            Assert.Equal(net/100m,Evidence(result).German!.Net);
        }
    }

    [Theory]
    [InlineData("60000 gross in DE for 2026","37561")]
    [InlineData("60000 brutto in DE","37561")]
    [InlineData("60000 EUR gross for 2026","37561 EUR")]
    [InlineData("60000 gross for 2026","37561")]
    [InlineData("6000 EUR/month gross in DE for 2026","3641.58 EUR/month")]
    [InlineData("37561 net in gross in DE for 2026","59998.72")]
    [InlineData("60000 gross in DE for 2026 in monthly","3130.0833/month")]
    [InlineData("60000 gross in DE for 2026-12-31 with tax class 3 with 2 children with child allowance 2 with church tax 9%","42465.32")]
    [InlineData("f(x)=x gross in DE for 2026 with tax class 1\nf(60000)","37561")]
    public void ExamplesInferenceAndSavedCalls(string source,string expected)=>Assert.Equal(expected,Last(source).Display);

    [Theory]
    [InlineData("60000 gross in DE for 2025")][InlineData("60000 gross in DE for 2027-01-01")]
    [InlineData("24000 gross in DE for 2026")][InlineData("2000 EUR/month gross in DE for 2026")]
    [InlineData("60000.001 gross in DE for 2026")][InlineData("100000000.01 gross in DE for 2026")]
    [InlineData("-1 gross in DE for 2026")][InlineData("60000 kg gross in DE for 2026")][InlineData("60000% gross in DE for 2026")]
    [InlineData("60000 gross in DE for 2026 with tax class 7")][InlineData("60000 gross in DE for 2026 with tax class 0")]
    [InlineData("60000 gross in DE for 2026 with church tax 10%")][InlineData("60000 gross in DE for 2026 with child allowance 0.3")]
    [InlineData("60000 gross in DE for 2026 with tax class 5 with child allowance 1")]
    [InlineData("60000 gross in DE for 2026 with health surcharge 11%")][InlineData("60000 gross in DE for 2026 with health surcharge 2.5")]
    [InlineData("60000 gross in DE for 2026 with tax class 1 with tax class 3")]
    [InlineData("60000 gross in DE for 2026 with 2 dependants")][InlineData("60000 gross in DE for 2026 in employer cost")]
    [InlineData("60000 gross in DE for 2026 with youth relief")]
    [InlineData("100000 gross in US for 2026 with tax class 1")][InlineData("5000 gross in RO for 2026-07-01 with church tax")]
    [InlineData("5000 EUR/h gross in DE for 2026")][InlineData("1 net in gross in DE for 2026")]
    [InlineData("100000000 net in gross in DE for 2026")]
    public void UnsupportedAndIneligibleInputsFailExplicitly(string source)=>Assert.NotNull(SheetEvaluator.Evaluate(source,context:Context)[^1].Error);

    [Fact]
    public void ExplanationDisclosesProfileComponentsAndSources()
    {
        var result=Last("6000 EUR/month gross in DE for 2026");
        var detail=Assert.Single(result.Explanation,step=>step.Payroll is not null).Assumption;
        foreach(var text in new[]{"DE-employee-2026-v1","PAP LZZ 2","tax class 1","2.9% Zusatzbeitrag (2026 average)","childless care surcharge","no church tax",
            "wage tax 1074.33 EUR","pension 558.00 EUR","health 508.59 EUR","care 139.50 EUR","Übergangsbereich","bmf-steuerrechner.de"})
            Assert.Contains(text,detail);
        var evidence=Evidence(result);
        Assert.Equal("DE",evidence.Country); Assert.Equal(2026,evidence.TaxYear); Assert.Equal(5,evidence.Sources.Count);
        Assert.Equal(Rational.Parse("72000"),evidence.AnnualGross);
    }

    [Fact]
    public void ContributionCeilingsAndCareRatesFollowProfile()
    {
        var below=Evidence(Last("5812.5 EUR/month gross in DE for 2026")).German!;
        var above=Evidence(Last("9000 EUR/month gross in DE for 2026")).German!;
        Assert.Equal(508.59m,below.Health); Assert.Equal(508.59m,above.Health); // 5812.50 * 8.75 %, half up
        Assert.Equal(785.85m,above.Pension); Assert.Equal(109.85m,above.Unemployment); // 8450 * 9.3 % / 1.3 %
        Assert.Equal(139.50m,above.Care); // 5812.50 * 2.4 %
        var parent=Evidence(Last("5000 EUR/month gross in DE for 2026 with 1 children")).German!;
        Assert.Equal(90m,parent.Care); Assert.False(parent.ChildlessSurcharge);
        var three=Evidence(Last("5000 EUR/month gross in DE for 2026 with 3 children")).German!;
        Assert.Equal(65m,three.Care); // 1.8 % - 2 x 0.25 %
        var saxony=Evidence(Last("5000 EUR/month gross in DE for 2026 with Saxony")).German!;
        Assert.Equal(145m,saxony.Care); // 2.3 % + 0.6 %
        var surcharge=Evidence(Last("5000 EUR/month gross in DE for 2026 with health surcharge 1.7%")).German!;
        Assert.Equal(407.50m,surcharge.Health);
    }

    [Theory]
    [InlineData("2000000 net in gross in DE for 2026",2000000)]
    [InlineData("50000000 net in gross in DE for 2026 with tax class 6",50000000)]
    [InlineData("400000 EUR/month net in gross in DE for 2026 with church tax 8%",400000)]
    [InlineData("1500.37 EUR/month net in gross in DE for 2026 with tax class 3 with 2 children",1500.37)]
    public void InverseStaysWithinExpressionBudgetAcrossBrackets(string source,double target)
    {
        var result=SheetEvaluator.Evaluate(source,context:Context)[^1];
        if(result.Error is { } error) { Assert.Contains("exact net",error); return; }
        var german=Evidence(result).German!; Assert.Equal((decimal)target,german.Net);
        var lower=SheetEvaluator.Evaluate(source.Replace(" net in gross"," gross").Replace(target.ToString(CultureInfo.InvariantCulture),(german.Gross-0.01m).ToString(CultureInfo.InvariantCulture)),context:Context)[^1];
        Assert.NotEqual((decimal)target,Evidence(lower).German!.Net);
    }

    [Fact]
    public void SpecificationExamplesEvaluate()
    {
        using var stream=typeof(GermanPayrollTests).Assembly.GetManifestResourceStream("Calc.PayrollSpec")!;
        var spec=new StreamReader(stream).ReadToEnd().Replace("\r\n","\n");
        var section=spec[spec.IndexOf("## German 2026 employee model",StringComparison.Ordinal)..];
        var block=section[(section.IndexOf("```text\n",StringComparison.Ordinal)+8)..section.IndexOf("\n```\n",StringComparison.Ordinal)];
        var lines=block.Split('\n'); Assert.Equal(8,lines.Length);
        foreach(var line in lines) Assert.Null(SheetEvaluator.Evaluate(line,context:Context)[^1].Error);
    }

    [Fact]
    public void ExpensiveGermanSheetsShareTheExistingComputationLimit()=>
        Assert.Throws<SheetComputationLimitException>(()=>SheetEvaluator.Evaluate(string.Join('\n',Enumerable.Repeat("2000000 net in gross in DE for 2026",2000)),context:Context));

    [Fact]
    public void CurrentYearDependencyAndPinnedYearAreSeparate()
    {
        var session=new SheetEvaluationSession(); const string source="60000 gross in DE\n60000 gross in DE for 2026\n7";
        var before=session.Evaluate(source,context:Context);
        Assert.Null(before[0].Error);
        var after=session.Evaluate(source,context:Context with{Today=new(2027,1,1)});
        Assert.NotNull(after[0].Error); Assert.Equal(before[1],after[1]);
        Assert.Equal("37561",Last("60000 gross",Context with{PayrollRegion="DE"}).Display);
        Assert.Equal("37561 EUR",Last("60000 EUR gross for 2026",Context with{PayrollRegion="US"}).Display);
        using var cancelled=new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("37561 net in gross in DE for 2026",cancelled.Token,context:Context));
    }
}
