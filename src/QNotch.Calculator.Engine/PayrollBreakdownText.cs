using System.Globalization;
using System.Numerics;

namespace Calc.Core;

/// <summary>Readable payroll breakdowns shared by the Windows hover/F1 surfaces and the CLI explanation.
/// It formats evidence the evaluator already produced and never computes a separate answer.</summary>
public static class PayrollBreakdownText
{
    private static string F(long forints)=>forints.ToString("N0",CultureInfo.InvariantCulture).Replace(',',' ');
    private static string F(Rational value)
    {
        var whole=BigInteger.DivRem(value.Numerator,value.Denominator,out var remainder);
        if(remainder.IsZero) return F((long)whole);
        var rounded=(long)((2*value.Numerator+value.Denominator)/(2*value.Denominator)); // nonnegative display amounts
        return "≈"+F(rounded);
    }
    private static string Percent(long part,long whole,string of)=>whole==0?"":" ("+(100m*part/whole).ToString("0.0",CultureInfo.InvariantCulture)+"% of "+of+")";
    private static readonly string[] MonthNames=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

    /// <summary>One hover line: where the money goes, and the answer's period.</summary>
    public static string? Summary(PayrollEvidence evidence)
    {
        if(evidence.Hungarian is not { } hu) return null;
        var per=hu.Period=="year"?"year":"month";
        var parts=new List<string>{"SZJA "+F(hu.PersonalIncomeTax),"TB járulék "+F(hu.SocialSecurity)};
        if(hu.Profile=="átalányadó") parts.Add("szocho "+F(hu.SocialContributionTax));
        if(hu.FamilyContributionRelief>0) parts.Add("relief +"+F(hu.FamilyContributionRelief));
        parts.Add("net "+F(hu.Net)+" HUF");
        var answer=hu.AnswerPeriod is { } period?"Answer is per "+period:"";
        return string.Join(" · ",parts)+" per "+per+(answer.Length>0?"\n"+answer:"");
    }

    /// <summary>Hover-card rows: the base amount, what is taken or added back, then net for the evidence period.</summary>
    public static PayrollBreakdown? Rows(PayrollEvidence evidence)
    {
        if(evidence.Hungarian is not { } hu) return null;
        var per=hu.Period=="year"?"year":"month";
        var flat=hu.Profile=="átalányadó";
        var rows=new List<PayrollBreakdownRow>{new(flat?"Revenue":"Gross",F(hu.Gross),PayrollBreakdownRowKind.Base)};
        if(flat)
        {
            rows.Add(new("SZJA","−"+F(hu.PersonalIncomeTax),PayrollBreakdownRowKind.Deduction));
            rows.Add(new("TB járulék","−"+F(hu.SocialSecurity),PayrollBreakdownRowKind.Deduction));
            rows.Add(new("szocho","−"+F(hu.SocialContributionTax),PayrollBreakdownRowKind.Deduction));
        }
        else
        {
            rows.Add(new("TB járulék","−"+F(hu.SocialSecurity),PayrollBreakdownRowKind.Deduction));
            rows.Add(new("SZJA","−"+F(hu.PersonalIncomeTax),PayrollBreakdownRowKind.Deduction));
        }
        if(hu.FamilyContributionRelief>0) rows.Add(new("Family relief","+"+F(hu.FamilyContributionRelief),PayrollBreakdownRowKind.Credit));
        rows.Add(new("Net per "+per,F(hu.Net)+" HUF",PayrollBreakdownRowKind.Total));
        if(!flat) rows.Add(new("Employer cost",F(hu.EmployerCost)+" HUF",PayrollBreakdownRowKind.Info));
        return new(rows,hu.AnswerPeriod is { } period&&period!=per?"Answer is per "+period:null);
    }

    /// <summary>F1 lines: totals, then (átalányadó) the twelve months.</summary>
    public static IReadOnlyList<string> Lines(PayrollEvidence evidence)
    {
        if(evidence.Hungarian is not { } hu) return [];
        var lines=new List<string>();
        if(hu.Profile=="átalányadó")
        {
            var paid=hu.PersonalIncomeTax+hu.SocialSecurity+hu.SocialContributionTax-hu.FamilyContributionRelief;
            lines.Add($"Breakdown for 2026 (átalányadó, {hu.Status}, {hu.CostRatio}% cost ratio):");
            lines.Add($"  Revenue {F(hu.Gross)} HUF; income {F(hu.Income)} HUF; tax-free {F(hu.TaxFreeIncome)} HUF");
            lines.Add($"  SZJA {F(hu.PersonalIncomeTax)} HUF; TB járulék {F(hu.SocialSecurity)} HUF; szocho {F(hu.SocialContributionTax)} HUF"+
                (hu.FamilyContributionRelief>0?$"; family contribution relief −{F(hu.FamilyContributionRelief)} HUF":""));
            lines.Add($"  Taxes and contributions {F(paid)} HUF{Percent(paid,hu.Gross,"revenue")}; net {F(hu.Net)} HUF a year, about {F(new Rational(hu.Net,12))} HUF a month");
            lines.Add("Monthly (contributions are due monthly, paid quarterly; SZJA advance after each quarter):");
            foreach(var month in hu.Months)
                lines.Add($"  {MonthNames[month.Month-1]}: base {F(month.ContributionBase)}, TB {F(month.SocialSecurity)}, szocho {F(month.SocialContributionTax)}"+
                    (month.Month%3==0?$", SZJA {F(month.IncomeTaxAdvance)} (Q{month.Month/3})":"")+$", left {F(month.Left)}");
            if(hu.FamilyContributionRelief>0) lines.Add($"  Family contribution relief of {F(hu.FamilyContributionRelief)} HUF is settled in the annual return");
        }
        else
        {
            var deductions=hu.SocialSecurity+hu.PersonalIncomeTax-hu.FamilyContributionRelief;
            lines.Add("Monthly breakdown (employee):");
            lines.Add($"  Gross {F(hu.Gross)} HUF; TB járulék {F(hu.SocialSecurity)} HUF; SZJA {F(hu.PersonalIncomeTax)} HUF"+
                (hu.FamilyContributionRelief>0?$"; family contribution relief +{F(hu.FamilyContributionRelief)} HUF":""));
            lines.Add($"  Deductions {F(deductions)} HUF{Percent(deductions,hu.Gross,"gross")}; net {F(hu.Net)} HUF a month, {F(12*hu.Net)} HUF a year");
            lines.Add($"  Employer szocho {F(hu.SocialContributionTax)} HUF; employer cost {F(hu.EmployerCost)} HUF a month");
        }
        return lines;
    }
}

public enum PayrollBreakdownRowKind { Base, Deduction, Credit, Total, Info }
public sealed record PayrollBreakdownRow(string Label,string Amount,PayrollBreakdownRowKind Kind);
/// <summary>Footer names the answer's period only when it differs from the rows' period.</summary>
public sealed record PayrollBreakdown(IReadOnlyList<PayrollBreakdownRow> Rows,string? Footer);
