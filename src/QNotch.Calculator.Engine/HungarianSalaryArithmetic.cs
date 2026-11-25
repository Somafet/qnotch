using System.Globalization;
using System.Numerics;

namespace Calc.Core;

internal sealed record HungarianSalaryOptions(bool FlatRate=false,int? CostRatio=null,bool GuaranteedMinimum=false,bool Pensioner=false,
    bool MothersExemption=false,bool FirstMarriage=false);

/// <summary>Hungarian 2026 amounts in whole forints. Employee fields are one month; flat-rate (átalányadó) fields are the tax year.</summary>
public sealed record HungarianPayrollEvidence(string Profile,string Period,long Gross,long Net,Rational Income,long TaxFreeIncome,
    Rational TaxableIncome,Rational Allowances,Rational FamilyAllowanceUsed,Rational TaxBase,long PersonalIncomeTax,Rational SocialSecurityBase,
    long SocialSecurity,long FamilyContributionRelief,Rational SocialContributionTaxBase,long SocialContributionTax,long EmployerCost,
    int Children,int Dependants,bool YouthExemption,bool MothersExemption,bool FirstMarriage,int? CostRatio,string? Status)
{
    /// <summary>Átalányadó only: the twelve monthly liabilities. Family contribution relief is settled annually and excluded.</summary>
    public IReadOnlyList<HungarianPayrollMonth> Months { get; init; } = [];
    /// <summary>"month" or "year" for the line's answer; null when an hourly/daily target converts it.</summary>
    public string? AnswerPeriod { get; init; }
}

/// <summary>One átalányadó month. Contributions are monthly liabilities (NAV collects them quarterly); the SZJA advance
/// on cumulative income appears in each quarter's last month. Left is revenue minus these three payments.</summary>
public sealed record HungarianPayrollMonth(int Month,Rational Revenue,Rational Income,Rational ContributionBase,long SocialSecurity,
    long SocialContributionTax,long IncomeTaxAdvance,Rational Left);

/// <summary>Hungary 2026: a full-month employee (15% SZJA, 18.5% TB járulék, employer 13% szocho) and a whole-year
/// átalányadózó sole trader with evenly earned revenue and the NAV quarterly göngyölítés of contribution bases.</summary>
public static class HungarianPayrollRules
{
    public const string EmployeeRule="HU-employee-2026-v1", FlatRateRule="HU-atalanyado-2026-v1";
    public const long MinimumWage=322800, GuaranteedMinimumWage=373200, TaxFreeIncome=1936800, YouthMonthlyCap=715765, FirstMarriageMonthly=33335;
    public const long RevenueCeiling=38736000, RetailRevenueCeiling=193680000;
}

internal sealed class HungarianSalaryArithmetic(ExecutionBudget budget,CancellationToken token,MoneyArithmetic money,EvaluationContext context,ContextReads reads)
{
    internal const string EmployeeRule=HungarianPayrollRules.EmployeeRule, FlatRateRule=HungarianPayrollRules.FlatRateRule;
    internal const long MinimumWage=HungarianPayrollRules.MinimumWage, GuaranteedMinimumWage=HungarianPayrollRules.GuaranteedMinimumWage,
        TaxFreeIncome=HungarianPayrollRules.TaxFreeIncome, YouthMonthlyCap=HungarianPayrollRules.YouthMonthlyCap, FirstMarriageMonthly=HungarianPayrollRules.FirstMarriageMonthly;
    internal const long RevenueCeiling=HungarianPayrollRules.RevenueCeiling, RetailRevenueCeiling=HungarianPayrollRules.RetailRevenueCeiling, MaxMonthlyGross=PayrollArithmetic.MaxAnnualGross/12;
    // Rounded net differs from the exact (unrounded) net, which never decreases with gross, by at most
    // 1.5 HUF (employee) and 19 HUF (flat rate: 24 monthly contributions, tax and relief); a lower amount can
    // therefore exceed a higher amount's net by at most twice that.
    internal const long EmployeeDipBound=3, FlatRateDipBound=40;
    private const long Scale=3600; // flat-rate quantities in 1/3600 HUF: twelfths of a percentage share, then thirds for quarters
    internal static readonly string[] EmployeeSources=[
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/73.-Szja-adoalap-kedvezmenyek-2026.-03.19",
        "https://njt.hu/jogszabaly/1995-117-00-00",
        "https://njt.hu/jogszabaly/2019-122-00-00",
        "https://njt.hu/jogszabaly/2018-52-00-00",
        "https://njt.hu/jogszabaly/2025-426-20-22"];
    internal static readonly string[] FlatRateSources=[
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/100.-Az-egyeni-vallalkozok-atalanyadozasanak-alapveto-szabalyai-2026.-02.-20",
        "https://nav.gov.hu/pfile/file?path=/ugyfeliranytu/nezzen-utana/inf_fuz/2026/73.-Szja-adoalap-kedvezmenyek-2026.-03.19",
        "https://njt.hu/jogszabaly/1995-117-00-00",
        "https://njt.hu/jogszabaly/2019-122-00-00",
        "https://njt.hu/jogszabaly/2018-52-00-00",
        "https://njt.hu/jogszabaly/2025-426-20-22"];

    internal sealed record Profile(int Children,int Dependants,bool Youth,bool Mothers,bool FirstMarriage,bool MainJob,bool Pensioner,int CostRatio,bool Guaranteed)
    {
        internal long MonthlyFamilyFrame=>Children==0?0:Children*(Dependants switch{1=>133340L,2=>266660L,_=>440000L});
        internal long MinimumBase=>Guaranteed?GuaranteedMinimumWage:MinimumWage;
    }

    internal sealed record Result(long Gross,long Net,Rational Income,Rational Taxable,Rational Allowances,Rational FamilyUsed,Rational TaxBase,long Tax,
        Rational SocialBase,long SocialSecurity,long Relief,Rational SzochoBase,long Szocho,long EmployerCost);

    private static long Round(BigInteger numerator,BigInteger denominator)
    {
        if(numerator.Sign<0) throw new ArithmeticException("Negative Hungarian payroll rounding input");
        return (long)((2*numerator+denominator)/(2*denominator));
    }
    private static Rational R(BigInteger numerator,long denominator=1)=>new(numerator,denominator);

    /// <summary>Employee: one full month in whole forints, each amount rounded half up.</summary>
    internal static Result Employee(long gross,Profile profile)
    {
        var tb=Round(gross*185L,1000);
        long remaining=gross, allowances=0;
        long Take(long cap) { var used=Math.Min(remaining,cap); remaining-=used; allowances+=used; return used; }
        if(profile.Mothers) Take(remaining);
        if(profile.Youth) Take(YouthMonthlyCap);
        if(profile.FirstMarriage) Take(FirstMarriageMonthly);
        var family=Take(profile.MonthlyFamilyFrame);
        var tax=Round(remaining*15L,100);
        var relief=Math.Min(tb,Round((profile.MonthlyFamilyFrame-family)*15L,100));
        var szocho=Round(gross*13L,100);
        return new(gross,gross-tb+relief-tax,R(gross),R(gross),R(allowances),R(family),R(remaining),tax,R(gross),tb,relief,R(gross),szocho,gross+szocho);
    }

    /// <summary>Allowances in statutory order over <paramref name="months"/> eligible months, in 1/3600 HUF.</summary>
    private static (long Allowances,long Family,long Remaining) FlatAllowances(long taxable,long months,Profile profile)
    {
        long remaining=taxable, allowances=0;
        long Take(long cap) { var used=Math.Min(remaining,cap); remaining-=used; allowances+=used; return used; }
        if(profile.Mothers) Take(remaining);
        if(profile.Youth) Take(months*YouthMonthlyCap*Scale);
        if(profile.FirstMarriage) Take(months*FirstMarriageMonthly*Scale);
        var family=Take(months*profile.MonthlyFamilyFrame*Scale);
        return (allowances,family,remaining);
    }

    /// <summary>Flat rate: whole-year revenue earned evenly, quarterly cumulative contribution bases with a monthly minimum.
    /// When <paramref name="months"/> is supplied it receives each month's liabilities, with the SZJA advance
    /// on cumulative quarterly income in the quarter's last month.</summary>
    internal static Result FlatRate(long revenue,Profile profile,List<HungarianPayrollMonth>? months=null)
    {
        var monthly=revenue*(100L-profile.CostRatio)*3; // monthly income in 1/3600 HUF
        var income=12*monthly; var taxFree=TaxFreeIncome*Scale;
        long previous=0, tb=0, szocho=0, eligibleTb=0, advanced=0;
        for(var quarter=1;quarter<=4;quarter++)
        {
            var cumulative=Math.Max(0,3*quarter*monthly-taxFree);
            var rolled=Math.Max(0,cumulative-previous)/3; // exact: both terms are multiples of three
            var minimum=profile.MainJob?profile.MinimumBase*Scale:0;
            var actual=Math.Max(rolled,minimum);
            var eligible=rolled>=minimum?actual:Math.Min(minimum,monthly);
            for(var month=0;month<3;month++)
            {
                previous+=actual;
                long monthTb=0, monthSzocho=0, advance=0;
                if(!profile.Pensioner)
                {
                    monthTb=Round(actual*(BigInteger)185,Scale*1000L); monthSzocho=Round(actual*(BigInteger)13,Scale*100L);
                    tb+=monthTb; szocho+=monthSzocho; eligibleTb+=Round(eligible*(BigInteger)185,Scale*1000L);
                }
                if(months is null) continue;
                if(month==2)
                {
                    var due=Round(FlatAllowances(cumulative,3*quarter,profile).Remaining*(BigInteger)15,Scale*100L);
                    advance=due-advanced; advanced=due;
                }
                months.Add(new(3*(quarter-1)+month+1,R(revenue,12),R(monthly,Scale),R(profile.Pensioner?0:actual,Scale),monthTb,monthSzocho,advance,
                    R(revenue,12)-R(monthTb+monthSzocho+advance)));
            }
        }
        var socialBase=profile.Pensioner?0:previous;
        var taxable=Math.Max(0,income-taxFree);
        var (allowances,family,remaining)=FlatAllowances(taxable,12,profile);
        var frame=12*profile.MonthlyFamilyFrame*Scale;
        var tax=Round(remaining*(BigInteger)15,Scale*100L);
        var relief=profile.Pensioner?0:Math.Min(eligibleTb,Round((frame-family)*(BigInteger)15,Scale*100L));
        return new(revenue,revenue-tax-tb+relief-szocho,R(income,Scale),R(taxable,Scale),R(allowances,Scale),R(family,Scale),R(remaining,Scale),tax,
            R(socialBase,Scale),tb,relief,R(socialBase,Scale),szocho,revenue);
    }

    private Result Forward(long gross,Profile profile)
    { budget.Step(token); token.ThrowIfCancellationRequested(); return profile.CostRatio>0?FlatRate(gross,profile):Employee(gross,profile); }

    /// <summary>Lowest whole-forint gross whose rounded net equals the target, using the bounded rounding dip.</summary>
    private long Inverse(long target,long low,long high,long dip,Profile profile)
    {
        if(Forward(high,profile).Net<target) throw new ArithmeticException("Target net exceeds the supported Hungarian gross bound");
        long crossing;
        if(Forward(low,profile).Net>=target) crossing=low;
        else
        {
            long below=low, above=high; // Net(below) < target <= Net(above)
            while(above-below>1)
            {
                var middle=below+(above-below)/2;
                if(Forward(middle,profile).Net>=target) above=middle; else below=middle;
            }
            crossing=above;
        }
        long? lowest=null;
        for(var gross=crossing-1;gross>=low;gross--)
        {
            var net=Forward(gross,profile).Net;
            if(net==target) lowest=gross;
            if(net<target-dip) break;
        }
        if(lowest is { } found) return found;
        for(var gross=crossing;gross<=high;gross++)
        {
            var net=Forward(gross,profile).Net;
            if(net==target) return gross;
            if(net>target+dip) break;
        }
        throw new ArithmeticException("No whole-forint amount within the supported Hungarian profile produces this exact net");
    }

    private Profile Options(SalaryExpression expression,out HungarianSalaryOptions hu)
    {
        hu=expression.Hungarian??new();
        var children=0;
        if(expression.German is { } de)
        {
            if(de with{Children=0}!=new GermanSalaryOptions()) throw new ArithmeticException("Tax class, church tax, child allowance, health surcharge, Saxony and childless-surcharge options require German salary rules");
            children=de.Children;
        }
        int? dependants=null; var youth=false; var mainJob=true;
        if(expression.Romanian is { } ro)
        {
            if(ro with{Dependants=null,YouthRelief=false,MainJob=true}!=new RomanianSalaryOptions()) throw new ArithmeticException("School children, basic salary and minimum relief options require Romanian salary rules");
            dependants=ro.Dependants; youth=ro.YouthRelief; mainJob=ro.MainJob;
        }
        var total=dependants??children;
        if(children>total) throw new ArithmeticException("Hungarian beneficiary children must be included in the total dependant count");
        if(total>0 && children==0) throw new ArithmeticException("Hungarian family allowance needs the number of beneficiary children, for example with 2 children");
        if(hu.FlatRate)
        {
            if(expression.EmployerCost) throw new ArithmeticException("Employer cost applies to the Hungarian employee model, not átalányadó");
            if(hu.Pensioner && !mainJob) throw new ArithmeticException("Choose either pensioner or secondary (without main job) átalányadó status");
            if(hu.GuaranteedMinimum && (hu.Pensioner || !mainJob)) throw new ArithmeticException("The guaranteed minimum base applies only to main-occupation átalányadó");
        }
        else
        {
            if(hu.CostRatio is not null || hu.GuaranteedMinimum || hu.Pensioner) throw new ArithmeticException("Cost ratio, guaranteed minimum and pensioner options require with átalányadó");
            if(!mainJob) throw new ArithmeticException("without main job applies to Hungarian átalányadó (secondary activity), not to the employee model");
        }
        return new(children,total,youth,hu.MothersExemption,hu.FirstMarriage,mainJob && !hu.Pensioner,hu.Pensioner,hu.FlatRate?hu.CostRatio??45:0,hu.GuaranteedMinimum);
    }

    internal PayrollResult Evaluate(SalaryExpression expression,SheetValue value,string origin)
    {
        var profile=Options(expression,out var hu); var flat=hu.FlatRate;
        var year=expression.Year ?? expression.PayrollDate?.Year;
        if(year is null) { reads.Dependencies|=ContextDependency.Date; year=context.RequireToday().Year; }
        if(year!=2026) throw new ArithmeticException($"Hungarian salary rules unavailable for {year}; supported 2026 only");
        var hadPeriod=value.Kind==SheetValueKind.Earnings;
        var period=hadPeriod?value.Earnings.Period:flat?EarningsPeriod.Year:EarningsPeriod.Month;
        if(period is not EarningsPeriod.Month and not EarningsPeriod.Year) throw new ArithmeticException("Annualize hourly/workday earnings explicitly before applying salary rules");
        var amount=hadPeriod?value.Earnings.Amount:value;
        string? outputCurrency=null; CurrencyRateStamp? stamp=null;
        if(amount.Kind==SheetValueKind.Money)
        {
            var converted=money.Convert(amount.Money,"HUF"); outputCurrency="HUF"; stamp=converted.RateStamp; amount=new(converted.Magnitude);
        }
        var number=amount.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("Hungarian salary requires a rational HUF amount without units or percentages");
        var approximate=number.IsApproximate;
        // Model unit: employee month, flat-rate year.
        var unitInput=flat?(period==EarningsPeriod.Month?number.Scalar*new Rational(12,1):number.Scalar):(period==EarningsPeriod.Year?number.Scalar/new Rational(12,1):number.Scalar);
        // A currency conversion rarely lands on whole forints; settle it to the nearest forint and disclose that.
        var convertedRounding=outputCurrency is not null && unitInput.Denominator!=BigInteger.One && unitInput.Numerator.Sign>=0;
        if(convertedRounding) unitInput=new(Round(unitInput.Numerator,unitInput.Denominator),1);
        if(unitInput.Denominator!=BigInteger.One || unitInput.Numerator.Sign<0) throw new ArithmeticException(flat?"Átalányadó requires nonnegative whole-forint annual revenue":"Hungarian salary requires nonnegative whole-forint monthly amounts");
        var ceiling=flat?(profile.CostRatio==90?RetailRevenueCeiling:RevenueCeiling):MaxMonthlyGross;
        var input=unitInput.Numerator>long.MaxValue/2?long.MaxValue/2:(long)unitInput.Numerator;
        string Forints(long value)=>value.ToString("N0",CultureInfo.InvariantCulture).Replace(',',' ');
        if(!expression.Inverse && input>ceiling) throw new ArithmeticException(flat?$"Átalányadó revenue limit is {Forints(ceiling)} HUF for 2026 at a {profile.CostRatio}% cost ratio":
            period==EarningsPeriod.Month && !hadPeriod?$"A plain Hungarian salary is monthly, and {Forints(input)} HUF a month is above the {Forints(ceiling)} HUF limit. For a yearly salary add /year, for example x/year gross in HU":
            $"Hungarian salary is limited to {Forints(ceiling)} HUF a month");
        var gross=expression.Inverse?Inverse(input,0,ceiling,flat?FlatRateDipBound:EmployeeDipBound,profile):input;
        var result=Forward(gross,profile);
        var returned=expression.EmployerCost?result.EmployerCost:expression.Inverse?result.Gross:result.Net;
        var factor=flat?(period==EarningsPeriod.Month?new Rational(1,12):new Rational(1,1)):(period==EarningsPeriod.Year?new Rational(12,1):new Rational(1,1));
        var output=Output(new Rational(returned,1)*factor);
        if(hadPeriod) output=new(new EarningsValue(output,period));
        string F(long forints)=>forints.ToString("N0",CultureInfo.InvariantCulture).Replace(',',' ')+" HUF";
        string Q(Rational forints)=>Display(forints)+" HUF";
        var detail=flat?FlatDetail(expression,origin,profile,result,F,Q):EmployeeDetail(expression,origin,profile,result,F,Q);
        detail+=(convertedRounding?$"; converted input rounded half up to {input.ToString(CultureInfo.InvariantCulture)} whole HUF per {(flat?"year":"month")}":"")+(expression.Inverse?$"; lowest whole-forint {(flat?"revenue":"gross")} producing the exact net, verified by recomputing; other amounts may produce the same rounded net":"")+
            (approximate?"; upstream amount is approximate":"; exact represented amount")+
            (money.Provenance is { } provenance?"; "+provenance+"; generic exchange-rate conversion, not a statutory MNB conversion":"");
        if(expression.OutputPeriod is { } target)
        {
            var rate=hadPeriod?output:new SheetValue(new EarningsValue(output,flat?EarningsPeriod.Year:EarningsPeriod.Month));
            var math=new ExactArithmetic(budget,token);
            var converter=new EarningsArithmetic(math,money,new WorkdayArithmetic(budget,token),context,reads,token);
            output=converter.Convert(rate,target); detail+="; "+converter.Assumption;
        }
        var sources=flat?FlatRateSources:EmployeeSources;
        detail+="; rule sources "+string.Join("; ",sources);
        var months=new Rational(flat?1:12,1);
        var deductions=new List<PayrollDeduction>{new("Personal income tax (SZJA)",new Rational(result.Tax,1)*months),
            new("Social security contribution (TB járulék)",new Rational(result.SocialSecurity,1)*months),
            new("Family contribution relief",new Rational(-result.Relief,1)*months)};
        if(flat) deductions.Add(new("Social contribution tax (szocho)",new Rational(result.Szocho,1)));
        var status=flat?(profile.Pensioner?"pensioner":profile.MainJob?"main occupation":"secondary"):null;
        var evidenceHu=new HungarianPayrollEvidence(flat?"átalányadó":"employee",flat?"year":"month",result.Gross,result.Net,result.Income,flat?TaxFreeIncome:0,
            result.Taxable,result.Allowances,result.FamilyUsed,result.TaxBase,result.Tax,result.SocialBase,result.SocialSecurity,result.Relief,
            result.SzochoBase,result.Szocho,result.EmployerCost,profile.Children,profile.Dependants,profile.Youth,profile.Mothers,profile.FirstMarriage,
            flat?profile.CostRatio:null,status);
        if(flat)
        {
            var schedule=new List<HungarianPayrollMonth>(12); FlatRate(gross,profile,schedule);
            evidenceHu=evidenceHu with{Months=schedule.AsReadOnly()};
        }
        evidenceHu=evidenceHu with{AnswerPeriod=expression.OutputPeriod switch{null=>period==EarningsPeriod.Month?"month":"year",
            EarningsPeriod.Month=>"month",EarningsPeriod.Year=>"year",_=>null}};
        var evidence=new PayrollEvidence("HU",2026,flat?FlatRateRule:EmployeeRule,new Rational(result.Gross,1)*months,new Rational(result.Net,1)*months,
            (result.Allowances+new Rational(flat?TaxFreeIncome:0,1))*months,result.TaxBase*months,deductions.AsReadOnly(),expression.Inverse,approximate,
            flat?"Hungarian 2026 átalányadó tax year; revenue earned evenly, quarterly cumulative contribution bases":"Hungarian 2026 full-month employee; annual fields project twelve identical months")
            {Sources=Array.AsReadOnly(sources),Hungarian=evidenceHu};
        return new(output,detail,evidence);

        SheetValue Output(Rational forints)
        {
            var value=new NumericValue(forints){DisplayDecimalPlaces=4,IsApproximate=approximate};
            return outputCurrency is null?new(value):new(new MoneyValue(value,outputCurrency,stamp));
        }
    }

    private static string Display(Rational value)
    {
        var whole=BigInteger.DivRem(value.Numerator,value.Denominator,out var remainder);
        var text=whole.ToString("N0",CultureInfo.InvariantCulture).Replace(',',' ');
        return remainder.IsZero?text:text+"."+((long)(remainder*100/value.Denominator)).ToString("00",CultureInfo.InvariantCulture)+"…";
    }
    private static string Allowances(Profile profile)=>
        (profile.Mothers?"mothers' exemption asserted (under-30 or two/three/four-child mothers, no cap); ":"")+
        (profile.Youth?"under-25 exemption asserted (715 765 HUF monthly cap); ":"")+
        (profile.FirstMarriage?"first-marriage allowance asserted (33 335 HUF monthly base); ":"")+
        (profile.Children>0?$"family allowance for {profile.Children} beneficiary of {profile.Dependants} dependant(s), {profile.MonthlyFamilyFrame.ToString("N0",CultureInfo.InvariantCulture).Replace(',',' ')} HUF monthly base, claimed in full by this person; ":"")+
        (profile.Mothers||profile.Youth||profile.FirstMarriage||profile.Children>0?"":"no tax allowances; ");
    private static string EmployeeDetail(SalaryExpression expression,string origin,Profile profile,Result r,Func<long,string> F,Func<Rational,string> Q)=>
        $"Hungarian salary {(expression.Inverse?"net to gross":"gross to net")}; HU from {origin}; {EmployeeRule}; 2026 full-month employee, monthly whole-forint amounts; "+Allowances(profile)+
        $"gross {F(r.Gross)}; TB járulék 18.5% {F(r.SocialSecurity)}; allowances {Q(r.Allowances)}; SZJA base {Q(r.TaxBase)}; SZJA 15% {F(r.Tax)}"+
        (r.Relief>0?$"; family contribution relief {F(r.Relief)} (15% of unused family allowance, at most the TB járulék)":"")+
        $"; net {F(r.Net)}; employer szocho 13% {F(r.Szocho)}; employer cost {F(r.EmployerCost)}"+
        "; each amount rounded half up to whole forints; allowances in statutory order; no benefits, cafeteria, part-month, disability (személyi) allowance, KIVA or other employer relief, voluntary funds or minimum-base cases"+
        "; bare amounts default to monthly HUF model units; yearly amounts are twelve identical months";
    private static string FlatDetail(SalaryExpression expression,string origin,Profile profile,Result r,Func<long,string> F,Func<Rational,string> Q)=>
        $"Hungarian átalányadó {(expression.Inverse?"net to revenue":"revenue to net")}; HU from {origin}; {FlatRateRule}; 2026 whole tax year, "+
        (profile.Pensioner?"pensioner (no TB járulék or szocho)":profile.MainJob?$"main occupation with monthly minimum base {(profile.Guaranteed?"guaranteed minimum wage 373 200 HUF (activity requires secondary qualification)":"minimum wage 322 800 HUF")}":"secondary activity beside 36-hour employment or full-time study (no minimum base)")+
        $"; cost ratio {profile.CostRatio}%; revenue {F(r.Gross)}; income {Q(r.Income)}; tax-free part {F(TaxFreeIncome)}; taxable income {Q(r.Taxable)}; "+Allowances(profile)+
        $"SZJA base {Q(r.TaxBase)}; SZJA 15% {F(r.Tax)}; annual TB járulék and szocho base {Q(r.SocialBase)}; TB járulék 18.5% {F(r.SocialSecurity)}"+
        (r.Relief>0?$"; family contribution relief {F(r.Relief)}":"")+$"; szocho 13% {F(r.Szocho)}; net {F(r.Net)}"+
        "; net is revenue less SZJA, contributions and szocho only, before actual business costs, local business tax (HIPA), VAT and chamber fees"+
        "; revenue earned evenly over a full insured year, quarterly cumulative (göngyölítéses) bases with monthly contributions rounded half up to whole forints; no suspension, sick pay or part-year activity"+
        "; bare amounts are annual revenue; monthly amounts annualize by twelve";
}
