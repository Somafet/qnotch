using System.Text.Json;
using Calc.Core;

namespace Calc.Core.Tests;

public class HungarianPayrollTests
{
    private static readonly EvaluationContext Context=new(new(2026,10,31),WorkdayRegion:"HU"){PayrollRegion="HU"};
    private static LineResult Last(string source,EvaluationContext? context=null)
    {
        var result=SheetEvaluator.Evaluate(source,context:context??Context)[^1]; Assert.Null(result.Error); return result;
    }
    private static string Error(string source)=>SheetEvaluator.Evaluate(source,context:Context)[^1].Error!;
    private static PayrollEvidence Evidence(LineResult result)=>Assert.Single(result.Explanation,step=>step.Payroll is not null).Payroll!;
    private static HungarianPayrollEvidence Hu(string source)=>Evidence(Last(source)).Hungarian!;

    public static IEnumerable<object[]> OracleGroups()
    {
        using var stream=typeof(HungarianPayrollTests).Assembly.GetManifestResourceStream("Calc.HungarianPayrollOracle")!;
        using var document=JsonDocument.Parse(stream);
        return document.RootElement.GetProperty("groups").EnumerateArray().Select(g=>new object[]{g.GetRawText()}).ToArray();
    }
    private static string Options(JsonElement profile)
    {
        var text="";
        if(profile.TryGetProperty("children",out var children)) text+=$" with {children.GetInt32()} children";
        if(profile.TryGetProperty("dependants",out var dependants)) text+=$" with {dependants.GetInt32()} dependants";
        if(profile.TryGetProperty("youth",out var youth) && youth.GetBoolean()) text+=" with youth relief";
        if(profile.TryGetProperty("mothers",out var mothers) && mothers.GetBoolean()) text+=" with mothers exemption";
        if(profile.TryGetProperty("firstMarriage",out var marriage) && marriage.GetBoolean()) text+=" with first marriage";
        if(profile.TryGetProperty("guaranteed",out var guaranteed) && guaranteed.GetBoolean()) text+=" with guaranteed minimum";
        if(profile.TryGetProperty("costRatio",out var ratio)) text+=$" with cost ratio {ratio.GetInt32()}%";
        if(profile.TryGetProperty("status",out var status)) text+=status.GetString()=="pensioner"?" as pensioner":" without main job";
        return text;
    }

    [Theory]
    [MemberData(nameof(OracleGroups))]
    public void IndependentOracleForwardAndLowestInverseAgree(string json)
    {
        using var document=JsonDocument.Parse(json); var group=document.RootElement;
        var flat=group.GetProperty("model").GetString()=="atalanyado";
        var tail=" in HU for 2026"+(flat?" with átalányadó":"")+Options(group.GetProperty("profile"));
        foreach(var item in group.GetProperty("cases").EnumerateArray())
        {
            var gross=item.GetProperty(flat?"revenue":"gross").GetInt64(); var net=item.GetProperty("net").GetInt64();
            var hu=Hu($"{gross} gross"+tail);
            Assert.Equal(net,hu.Net);
            Assert.Equal(item.GetProperty("personalIncomeTax").GetInt64(),hu.PersonalIncomeTax);
            Assert.Equal(item.GetProperty("socialSecurity").GetInt64(),hu.SocialSecurity);
            Assert.Equal(item.GetProperty("familyRelief").GetInt64(),hu.FamilyContributionRelief);
            Assert.Equal(Fraction(item.GetProperty("taxBase").GetString()!),hu.TaxBase);
            if(flat)
            {
                Assert.Equal(item.GetProperty("szocho").GetInt64(),hu.SocialContributionTax);
                Assert.Equal(Fraction(item.GetProperty("income").GetString()!),hu.Income);
                Assert.Equal(Fraction(item.GetProperty("contributionBase").GetString()!),hu.SocialSecurityBase);
                // The monthly breakdown must add up exactly to the annual answer.
                Assert.Equal(12,hu.Months.Count);
                Assert.Equal(hu.SocialSecurity,hu.Months.Sum(m=>m.SocialSecurity));
                Assert.Equal(hu.SocialContributionTax,hu.Months.Sum(m=>m.SocialContributionTax));
                Assert.Equal(hu.PersonalIncomeTax,hu.Months.Sum(m=>m.IncomeTaxAdvance));
                Assert.All(hu.Months,m=>Assert.True(m.IncomeTaxAdvance>=0 && (m.Month%3==0 || m.IncomeTaxAdvance==0)));
                Assert.Equal(new Rational(hu.Net-hu.FamilyContributionRelief,1),hu.Months.Aggregate(default(Rational),(sum,m)=>sum+m.Left));
            }
            else
            {
                Assert.Equal(item.GetProperty("employerSzocho").GetInt64(),hu.SocialContributionTax);
                Assert.Equal(item.GetProperty("employerCost").GetInt64(),hu.EmployerCost);
            }
            if(net<0) continue; // negative targets are not valid inputs
            var lowest=item.GetProperty(flat?"lowestInverseRevenue":"lowestInverseGross").GetInt64();
            Assert.Equal(lowest,Hu($"{net} net in gross"+tail).Gross);
        }
    }
    private static Rational Fraction(string text)
    {
        var parts=text.Split('/');
        return parts.Length==1?Rational.Parse(parts[0]):new(System.Numerics.BigInteger.Parse(parts[0]),System.Numerics.BigInteger.Parse(parts[1]));
    }

    [Fact]
    public void PublishedNavFiguresAndDefaults()
    {
        Assert.Equal("214662",Last("322800 gross in HU for 2026").Display);
        Assert.Equal("248178",Last("373200 gross").Display); // payroll region HU, monthly default
        Assert.Equal("214662 HUF",Last("322800 HUF gross for 2026",Context with{PayrollRegion="US"}).Display);
        Assert.Equal("2575944/year",Last("322800 gross in HU for 2026 in yearly").Display);
        var nav=Hu("7000000 gross in HU for 2026 with átalányadó");
        Assert.Equal(new Rational(3850000,1),nav.Income); Assert.Equal(286980,nav.PersonalIncomeTax);
        Assert.Equal(new Rational(12*322800,1),nav.SocialSecurityBase); Assert.Equal(12*59718,nav.SocialSecurity); Assert.Equal(12*41964,nav.SocialContributionTax);
        Assert.Equal(5492836,nav.Net);
        // Monthly revenue annualizes; the answer is the monthly share of the annual net.
        Assert.Equal(Hu("7200000 gross in HU for 2026 with atalanyado").Net,Hu("600000 HUF/month gross in HU for 2026 with flat rate").Net);
        Assert.Equal("473028 HUF/month",Last("600000 HUF/month gross in HU for 2026 with átalányadó").Display);
        var employer=Hu("600000 gross in HU for 2026"); Assert.Equal(78000,employer.SocialContributionTax); Assert.Equal(678000,employer.EmployerCost);
        Assert.Equal("678000",Last("600000 gross in HU for 2026 in employer cost").Display);
    }

    [Fact]
    public void BreakdownShowsSplitPeriodAndMonths()
    {
        var flat=Evidence(Last("600000 HUF/month gross in HU for 2026 with átalányadó"));
        Assert.Equal("SZJA 303 480 · TB járulék 716 616 · szocho 503 568 · net 5 676 336 HUF per year\nAnswer is per month",PayrollBreakdownText.Summary(flat));
        var lines=PayrollBreakdownText.Lines(flat);
        Assert.Contains("  Jun: base 322 800, TB 59 718, szocho 41 964, SZJA 6 480 (Q2), left 491 838",lines);
        Assert.Contains(lines,line=>line.Contains("(21.2% of revenue)",StringComparison.Ordinal));
        Assert.EndsWith("Answer is per year",PayrollBreakdownText.Summary(Evidence(Last("7000000 gross in HU for 2026 with átalányadó"))));
        var employee=Evidence(Last("600000 gross in HU for 2026 with 2 children"));
        Assert.Equal("SZJA 10 002 · TB járulék 111 000 · net 478 998 HUF per month\nAnswer is per month",PayrollBreakdownText.Summary(employee));
        Assert.Contains("  Deductions 121 002 HUF (20.2% of gross); net 478 998 HUF a month, 5 747 976 HUF a year",PayrollBreakdownText.Lines(employee));
        Assert.Empty(Evidence(Last("600000 gross in HU for 2026")).Hungarian!.Months);
        var cli=ExplanationText.Render(Last("7000000 gross in HU for 2026 with átalányadó"));
        Assert.True(cli.IndexOf("Breakdown for 2026",StringComparison.Ordinal)<cli.IndexOf("Hungarian átalányadó revenue to net",StringComparison.Ordinal));
        Assert.Null(PayrollBreakdownText.Summary(Evidence(Last("60000 gross in DE for 2026",Context with{PayrollRegion="DE"}))));
        Assert.Null(PayrollBreakdownText.Rows(Evidence(Last("60000 gross in DE for 2026",Context with{PayrollRegion="DE"}))));
    }

    [Fact]
    public void HoverRowsListBaseDeductionsAndNet()
    {
        var flat=PayrollBreakdownText.Rows(Evidence(Last("600000 HUF/month gross in HU for 2026 with átalányadó")))!;
        Assert.Equal(["Revenue","SZJA","TB járulék","szocho","Net per year"],flat.Rows.Select(row=>row.Label));
        Assert.Equal(["−303 480","−716 616","−503 568","5 676 336 HUF"],flat.Rows.Skip(1).Select(row=>row.Amount));
        Assert.Equal(PayrollBreakdownRowKind.Total,flat.Rows[^1].Kind);
        Assert.Equal("Answer is per month",flat.Footer);
        Assert.Null(PayrollBreakdownText.Rows(Evidence(Last("7000000 gross in HU for 2026 with átalányadó")))!.Footer);
        var employee=PayrollBreakdownText.Rows(Evidence(Last("600000 gross in HU for 2026 with 2 children")))!;
        Assert.Equal(["Gross","TB járulék","SZJA","Net per month","Employer cost"],employee.Rows.Select(row=>row.Label));
        Assert.Equal(["600 000","−111 000","−10 002","478 998 HUF"],employee.Rows.Take(4).Select(row=>row.Amount));
        Assert.Null(employee.Footer);
    }

    [Fact]
    public void ConvertedAmountsSettleToWholeForints()
    {
        // 1 EUR = 1.1 USD = 385.37 HUF, so 9000 USD = 3,153,027.27… HUF.
        var snapshot=new CurrencyRateSnapshot("Fixture","EUR",new(2026,10,30),new(2026,10,31,0,0,0,TimeSpan.Zero),
            new Dictionary<string,Rational>{["EUR"]=new(1,1),["USD"]=new(11,10),["HUF"]=new(38537,100)});
        var context=Context with{CurrencyRates=new(snapshot,[])};
        var converted=Last("9000 usd gross in HU for 2026",context);
        Assert.Equal(Last("3153027 gross in HU for 2026").Value!.Value.Scalar,converted.Value!.Value.Money.Magnitude.Scalar);
        Assert.Equal("HUF",converted.Value!.Value.Money.Currency);
        Assert.Contains("converted input rounded half up to 3153027 whole HUF per month",converted.Explanation.Single(step=>step.Payroll is not null).Assumption!);
        Assert.Contains("whole-forint",Error("3153027.5 gross in HU for 2026")); // typed amounts stay exact
    }

    [Fact]
    public void AllowancesFollowStatutoryOrderAndRelief()
    {
        var youth=Hu("900000 gross in HU for 2026 with youth relief");
        Assert.Equal(new Rational(715765,1),youth.Allowances); Assert.Equal(27635,youth.PersonalIncomeTax);
        var mothers=Hu("600000 gross in HU for 2026 with mothers exemption with 2 children");
        Assert.Equal(0,mothers.PersonalIncomeTax); Assert.Equal(79998,mothers.FamilyContributionRelief); Assert.Equal(568998,mothers.Net);
        var capped=Hu("200000 gross in HU for 2026 with 3 children");
        Assert.Equal(capped.SocialSecurity,capped.FamilyContributionRelief); Assert.Equal(200000,capped.Net);
        Assert.Equal(new Rational(33335,1),Hu("600000 gross in HU for 2026 with first marriage").Allowances);
        Assert.Equal(new Rational(440000,1),Hu("1000000 gross in HU for 2026 with 1 children with 3 dependants").FamilyAllowanceUsed);
    }

    [Fact]
    public void FlatRateStatusesAndLimits()
    {
        Assert.Equal(6713020,Hu("7000000 gross in HU for 2026 with átalányadó as pensioner").Net);
        Assert.Equal(6110362,Hu("7000000 gross in HU for 2026 with átalányadó without main job").Net);
        Assert.Equal(new Rational(12*373200,1),Hu("7000000 gross in HU for 2026 with átalányadó with guaranteed minimum").SocialSecurityBase);
        Assert.Equal(new Rational(4000000,1),Hu("20000000 gross in HU for 2026 with átalányadó with cost ratio 80%").Income);
        Assert.Equal(193680000,Hu("193680000 gross in HU for 2026 with átalányadó with cost ratio 90%").Gross);
        Assert.Contains("revenue limit is 38 736 000 HUF",Error("38736001 gross in HU for 2026 with átalányadó"));
        Assert.Equal("A plain Hungarian salary is monthly, and 35 000 000 HUF a month is above the 8 333 333 HUF limit. For a yearly salary add /year, for example x/year gross in HU",
            Error("x = 35000000\nx gross in HU for 2026"));
        Assert.Equal("Hungarian salary is limited to 8 333 333 HUF a month",Error("9000000 HUF/month gross in HU for 2026"));
        Assert.Equal(Hu("35000000 HUF/year gross in HU for 2026").Net*12,Hu("2916667 gross in HU for 2026").Net*12); // yearly divides into whole months
        Assert.EndsWith("HUF/year",Last("x = 35000000 HUF\nx/year gross in HU for 2026").Display);
        Assert.Contains("45%, 80% or 90%",Error("1000000 gross in HU for 2026 with átalányadó with cost ratio 50%"));
        Assert.Contains("employee model",Error("1000000 gross in HU for 2026 with átalányadó in employer cost"));
        Assert.Contains("require with átalányadó",Error("600000 gross in HU for 2026 as pensioner"));
        Assert.Contains("either pensioner",Error("1000000 gross in HU for 2026 with átalányadó as pensioner without main job"));
        Assert.Contains("German",Error("600000 gross in HU for 2026 with tax class 3"));
        Assert.Contains("Romanian",Error("600000 gross in HU for 2026 with 1 school child"));
        Assert.Contains("Hungarian",Error("60000 gross in DE for 2026 with átalányadó"));
        Assert.Contains("2026 only",Error("600000 gross in HU for 2027"));
        Assert.Contains("whole-forint",Error("600000.5 gross in HU for 2026"));
        var explanation=Last("7000000 gross in HU for 2026 with átalányadó").Explanation.Single(step=>step.Payroll is not null).Assumption!;
        Assert.Contains(HungarianPayrollRules.FlatRateRule,explanation); Assert.Contains("before actual business costs",explanation);
    }

    [Fact]
    public void SpecExamplesEvaluate()
    {
        using var stream=typeof(HungarianPayrollTests).Assembly.GetManifestResourceStream("Calc.PayrollSpec")!;
        var spec=new StreamReader(stream).ReadToEnd().Replace("\r\n","\n");
        var section=spec[spec.IndexOf("## Hungarian 2026 models",StringComparison.Ordinal)..];
        var block=section[(section.IndexOf("```text\n",StringComparison.Ordinal)+8)..section.IndexOf("\n```\n",StringComparison.Ordinal)];
        var lines=block.Split('\n'); Assert.True(lines.Length>=10);
        foreach(var line in lines) Assert.Null(SheetEvaluator.Evaluate(line,context:Context)[^1].Error);
    }

    [Fact]
    public void CurrentYearDependencyAndCancellation()
    {
        var session=new SheetEvaluationSession(); const string source="600000 gross in HU\n600000 gross in HU for 2026\n7";
        var before=session.Evaluate(source,context:Context); Assert.Null(before[0].Error);
        var after=session.Evaluate(source,context:Context with{Today=new(2027,1,1)});
        Assert.NotNull(after[0].Error); Assert.Equal(before[1],after[1]);
        using var cancelled=new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(()=>SheetEvaluator.Evaluate("4000000 net in gross in HU for 2026 with átalányadó",cancelled.Token,context:Context));
    }
}
