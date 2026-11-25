namespace Calc.Core;

/// <summary>Inputs of the BMF 2026 machine wage-tax program used by Calc (current wage only).
/// Names in comments are the official PAP parameters. Statutory pension, unemployment, health and care
/// insurance are fixed (KRV = ALV = PKV = 0).</summary>
internal sealed record GermanWageTaxInput(
    int Period,                     // LZZ: 1 year, 2 month, 3 week, 4 day
    decimal WageCents,              // RE4, whole cents for the period
    int TaxClass = 1,               // STKL 1..6
    decimal ChildAllowances = 0,    // ZKF, one decimal place
    decimal HealthSurchargePercent = 0, // KVZ, full kassenindividueller Zusatzbeitragssatz
    bool Saxony = false,            // PVS
    bool ChildlessSurcharge = false,// PVZ
    int CareDiscounts = 0,          // PVA 0..4
    bool Church = false             // R > 0
);

internal readonly record struct GermanWageTaxResult(decimal WageTaxCents,decimal SolidarityCents,decimal ChurchBaseCents,
    decimal AnnualWage,decimal AnnualTableAllowances,decimal AnnualProvisionAllowance,decimal AnnualTaxableIncome,decimal AnnualTax);

/// <summary>
/// Hand port of "Programmablaufplan für die maschinelle Berechnung der vom Arbeitslohn einzubehaltenden Lohnsteuer,
/// des Solidaritätszuschlags und der Maßstabsteuer für die Kirchenlohnsteuer für 2026" (BMF 12.11.2025,
/// BStBl 2025 I S. 1948, Anlage 1; pseudo-code Lohnsteuer2026.xml version 1.0). Only the current-wage path:
/// no Versorgungsbezüge, Altersentlastungsbetrag, Freibetrag/Hinzurechnung, factor method or sonstige Bezüge.
/// Uses System.Decimal with the PAP's explicit scales and rounding directions; values stay far inside its range.
/// </summary>
internal static class GermanWageTax2026
{
    private const decimal Bbgrvalv = 101400m, Avsatzan = 0.013m, Rvsatzan = 0.093m, Bbgkvpv = 69750m;
    private const decimal W1stkl5 = 14071m, W2stkl5 = 34939m, W3stkl5 = 222260m, Gfb = 12348m, SolzfreiBase = 20350m;
    private static decimal Down(decimal value,int scale)
    {
        var factor = Pow10(scale); return decimal.Truncate(value * factor) / factor;
    }
    private static decimal Up(decimal value,int scale)
    {
        var factor = Pow10(scale); var scaled = value * factor; var whole = decimal.Truncate(scaled);
        return (whole == scaled ? whole : whole + Math.Sign(scaled)) / factor;
    }
    private static decimal Pow10(int scale) => scale switch { 0 => 1m, 2 => 100m, 6 => 1000000m, _ => throw new ArgumentOutOfRangeException(nameof(scale)) };

    private sealed class State(GermanWageTaxInput input)
    {
        public readonly GermanWageTaxInput In = input;
        public decimal Kvsatzan, Pvsatzan, Solzfrei, Zre4j, Zre4, Zre4vp, Ztabfb, Anp, Sap, Efa, Kfb, Vsp, Vspr, Vspkvpv, Zve, X, St;
        public int Kztab = 1;
    }

    internal static GermanWageTaxResult Calculate(GermanWageTaxInput input)
    {
        if (input.Period is < 1 or > 4 || input.TaxClass is < 1 or > 6 || input.WageCents < 0 || input.CareDiscounts is < 0 or > 4 || input.ChildAllowances < 0)
            throw new ArgumentOutOfRangeException(nameof(input));
        var s = new State(input);
        // MPARA
        s.Kvsatzan = input.HealthSurchargePercent / 2m / 100m + 0.07m;
        s.Pvsatzan = input.Saxony ? 0.023m : 0.018m;
        s.Pvsatzan = input.ChildlessSurcharge ? s.Pvsatzan + 0.006m : s.Pvsatzan - input.CareDiscounts * 0.0025m;
        s.Solzfrei = SolzfreiBase;
        // MRE4JL (VBEZ, LZZFREIB, LZZHINZU are zero in Calc's profile)
        s.Zre4j = input.Period switch
        {
            1 => Down(input.WageCents / 100m,2),
            2 => Down(input.WageCents * 12m / 100m,2),
            3 => Down(input.WageCents * 360m / 700m,2),
            _ => Down(input.WageCents * 360m / 100m,2),
        };
        // MRE4 / MRE4ALTE: no pension payments and no age relief; MRE4ABZ
        Mre4abz(s);
        // MBERECH
        Mztabfb(s);
        Mlstjahr(s);
        var lstjahr = Down(s.St,0);
        var wageTax = Anteil(input.Period,lstjahr * 100m);
        var taxable = s.Zve; var tableAllowances = s.Ztabfb; var provision = s.Vsp;
        decimal jbmg;
        if (input.ChildAllowances > 0)
        {
            s.Ztabfb += s.Kfb; Mre4abz(s); Mlstjahr(s); jbmg = Down(s.St,0);
        }
        else jbmg = lstjahr;
        // MSOLZ
        s.Solzfrei *= s.Kztab;
        decimal solidarity = 0m;
        if (jbmg > s.Solzfrei)
        {
            var solzj = Down(jbmg * 5.5m / 100m,2);
            var solzmin = Down((jbmg - s.Solzfrei) * 11.9m / 100m,2);
            if (solzmin < solzj) solzj = solzmin;
            solidarity = Anteil(input.Period,Down(solzj * 100m,0));
        }
        var churchBase = input.Church ? Anteil(input.Period,jbmg * 100m) : 0m;
        return new(wageTax,solidarity,churchBase,s.Zre4j,tableAllowances,provision,taxable,lstjahr);
    }
    private static void Mre4abz(State s)
    {
        s.Zre4 = Down(s.Zre4j,2); if (s.Zre4 < 0) s.Zre4 = 0;
        s.Zre4vp = s.Zre4j;
    }
    private static void Mztabfb(State s)
    {
        s.Anp = 0; var klass = s.In.TaxClass;
        if (klass < 6 && s.Zre4 > 0) s.Anp = s.Zre4 < 1230m ? Up(s.Anp + s.Zre4,0) : s.Anp + 1230m;
        s.Kztab = 1;
        switch (klass)
        {
            case 1: s.Sap = 36; s.Kfb = Down(s.In.ChildAllowances * 9756m,0); break;
            case 2: s.Efa = 4260; s.Sap = 36; s.Kfb = Down(s.In.ChildAllowances * 9756m,0); break;
            case 3: s.Kztab = 2; s.Sap = 36; s.Kfb = Down(s.In.ChildAllowances * 9756m,0); break;
            case 4: s.Sap = 36; s.Kfb = Down(s.In.ChildAllowances * 4878m,0); break;
            case 5: s.Sap = 36; s.Kfb = 0; break;
            default: s.Kfb = 0; break;
        }
        s.Ztabfb = Down(s.Efa + s.Anp + s.Sap,2);
    }
    private static void Mlstjahr(State s)
    {
        Upevp(s);
        s.Zve = s.Zre4 - s.Ztabfb - s.Vsp;
        // UPMLST
        if (s.Zve < 1) { s.Zve = 0; s.X = 0; } else s.X = Down(s.Zve / s.Kztab,0);
        if (s.In.TaxClass < 5) Uptab26(s); else Mst56(s);
    }
    private static void Upevp(State s)
    {
        s.Vspr = Down(Math.Min(s.Zre4vp,Bbgrvalv) * Rvsatzan,2);
        // MVSPKVPV, statutory health/care insurance (PKV = 0)
        s.Vspkvpv = Down(Math.Min(s.Zre4vp,Bbgkvpv) * (s.Kvsatzan + s.Pvsatzan),2);
        s.Vsp = Up(s.Vspkvpv + s.Vspr,0);
        if (s.In.TaxClass == 6) return; // ALV = 0; MVSPHB is skipped only in class VI
        // MVSPHB
        var vspalv = Down(Avsatzan * Math.Min(s.Zre4vp,Bbgrvalv),2);
        var vsphb = Down(vspalv + s.Vspkvpv,2); if (vsphb > 1900m) vsphb = 1900m;
        var vspn = Up(s.Vspr + vsphb,0);
        if (vspn > s.Vsp) s.Vsp = vspn;
    }
    private static void Mst56(State s)
    {
        var zzx = s.X;
        if (zzx > W2stkl5)
        {
            Up56(s,W2stkl5);
            s.St = zzx > W3stkl5
                ? Down(Down(s.St + (W3stkl5 - W2stkl5) * 0.42m,0) + (zzx - W3stkl5) * 0.45m,0)
                : Down(s.St + (zzx - W2stkl5) * 0.42m,0);
        }
        else
        {
            Up56(s,zzx);
            if (zzx > W1stkl5)
            {
                var vergl = s.St; Up56(s,W1stkl5);
                var hoch = Down(s.St + (zzx - W1stkl5) * 0.42m,0);
                s.St = hoch < vergl ? hoch : vergl;
            }
        }
    }
    private static void Up56(State s,decimal zx)
    {
        s.X = Down(zx * 1.25m,0); Uptab26(s); var st1 = s.St;
        s.X = Down(zx * 0.75m,0); Uptab26(s); var st2 = s.St;
        var diff = (st1 - st2) * 2m; var mist = Down(zx * 0.14m,0);
        s.St = mist > diff ? mist : diff;
    }
    private static void Uptab26(State s)
    {
        var x = s.X;
        if (x < Gfb + 1) s.St = 0;
        else if (x < 17800m)
        {
            var y = Down((x - Gfb) / 10000m,6);
            s.St = Down((y * 914.51m + 1400m) * y,0);
        }
        else if (x < 69879m)
        {
            var y = Down((x - 17799m) / 10000m,6);
            s.St = Down((y * 173.1m + 2397m) * y + 1034.87m,0);
        }
        else if (x < 277826m) s.St = Down(x * 0.42m - 11135.63m,0);
        else s.St = Down(x * 0.45m - 19470.38m,0);
        s.St *= s.Kztab;
    }
    private static decimal Anteil(int period,decimal jw) => period switch
    {
        1 => jw,
        2 => Down(jw / 12m,0),
        3 => Down(jw * 7m / 360m,0),
        _ => Down(jw / 360m,0),
    };
}
