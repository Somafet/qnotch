using System.Globalization;
using System.Numerics;

namespace Calc.Core;

public sealed record AmortizationYear(int Year, int Payments, SheetValue Interest, SheetValue Principal, SheetValue Balance);
internal sealed record FinancialResult(SheetValue Value, string Assumption, IReadOnlyList<AmortizationYear>? Schedule = null)
{
    internal IrrEvidence? Irr { get; init; }
    internal GrowthEvidence? Growth { get; init; }
}

/// <summary>Bounded financial models. Exact fractions first; explicitly marked 34-significant-digit fallback.</summary>
internal sealed partial class FinancialArithmetic(ExecutionBudget budget, CancellationToken token, MoneyArithmetic money)
{
    internal const int MaxPeriods = 1200;
    private bool approximate;
    private MoneyValue? template;
    private static readonly Rational One = new(1, 1);
    internal static bool IsFunction(string name) => IsPlanningFunction(name) || name.ToLowerInvariant() is "pmt" or "fv" or "pv" or "npv" or "irr";
    internal static void ValidateArity(string name, int count)
    {
        if (IsPlanningFunction(name)) { ValidatePlanningArity(name,count); return; }
        if (name.Equals("irr",StringComparison.OrdinalIgnoreCase))
        { if (count is < 1 or > 16) throw new FormatException("irr expects scalar cash flows or a list with an optional guess"); return; }
        var minimum = name.Equals("npv", StringComparison.OrdinalIgnoreCase) ? 2 : 3;
        var maximum = minimum == 2 ? 16 : 5;
        if (count < minimum || count > maximum) throw new FormatException($"{name} expects {minimum}–{maximum} arguments");
    }
    private Rational Normalize(BigInteger numerator, BigInteger denominator)
    {
        budget.Step(token);
        if (denominator.IsZero) throw new ArithmeticException("Undefined financial result; zero divisor");
        if (denominator.Sign < 0) { numerator = -numerator; denominator = -denominator; }
        var common = BigInteger.GreatestCommonDivisor(numerator, denominator);
        numerator /= common; denominator /= common;
        if (numerator.GetBitLength() <= 4096 && denominator.GetBitLength() <= 4096) return new(numerator, denominator);
        approximate = true;
        // Inputs have bounded components; temporary products have at most 8193 bits.
        // Round only on overflow. No logarithms, doubles, unbounded precision or silent zero underflow.
        var magnitude = BigInteger.Abs(numerator);
        var exponent = magnitude.ToString(CultureInfo.InvariantCulture).Length - denominator.ToString(CultureInfo.InvariantCulture).Length;
        if (exponent >= 0 ? magnitude < denominator * BigInteger.Pow(10, exponent) : magnitude * BigInteger.Pow(10, -exponent) < denominator) exponent--;
        var places = 33 - exponent;
        if (Math.Abs(places) > 1233) throw new ArithmeticException("Financial precision limit exceeded");
        var quantum = BigInteger.Pow(10, Math.Abs(places));
        var scaledNumerator = places >= 0 ? magnitude * quantum : magnitude;
        var scaledDenominator = places >= 0 ? denominator : denominator * quantum;
        var whole = BigInteger.DivRem(scaledNumerator, scaledDenominator, out var remainder);
        if (remainder * 2 >= scaledDenominator) whole++;
        return places >= 0 ? new(numerator.Sign * whole, quantum) : new(numerator.Sign * whole * quantum, 1);
    }
    private Rational Add(Rational a, Rational b) => Normalize(a.Numerator*b.Denominator+b.Numerator*a.Denominator, a.Denominator*b.Denominator);
    private Rational Negate(Rational a) => new(-a.Numerator, a.Denominator);
    private Rational Subtract(Rational a, Rational b) => Add(a, Negate(b));
    private Rational Multiply(Rational a, Rational b) => Normalize(a.Numerator*b.Numerator, a.Denominator*b.Denominator);
    private Rational Divide(Rational a, Rational b) => Normalize(a.Numerator*b.Denominator, a.Denominator*b.Numerator);
    private Rational Plain(SheetValue value, bool percentage = false)
    {
        var number = value.Number;
        if (!number.IsRational || number.Unit is not null || !percentage && number.IsPercentage)
            throw new ArithmeticException("Financial inputs require rational scalars or monetary amounts");
        approximate |= number.IsApproximate;
        return number.Scalar;
    }
    private Rational Rate(SheetValue value)
    {
        var rate = Plain(value, true);
        if (rate.Numerator <= -rate.Denominator) throw new ArithmeticException("Financial rate must be greater than -100% per stated period");
        return rate;
    }
    private int Periods(SheetValue value, bool allowZero)
    {
        var count = Plain(value);
        if (value.Number.IsApproximate || count.Denominator != 1 || count.Numerator < (allowZero ? 0 : 1) || count.Numerator > MaxPeriods)
            throw new ArithmeticException($"Financial periods must be an exact integer from {(allowZero ? 0 : 1)} to {MaxPeriods}");
        return (int)count.Numerator;
    }
    private void SetTemplate(IEnumerable<SheetValue> cash)
    {
        template = null;
        foreach (var value in cash) if (value.Kind == SheetValueKind.Money) { template = value.Money; break; }
    }
    private Rational Cash(SheetValue value)
    {
        if (value.Kind != SheetValueKind.Money)
        {
            var scalar = Plain(value);
            if (template is not null && !scalar.Numerator.IsZero) throw new ArithmeticException("Do not mix bare and currency cash flows; only bare zero is currency-neutral");
            return scalar;
        }
        var converted = money.Convert(value.Money, template!.Currency);
        if (template.RateStamp is not null && converted.RateStamp is not null && template.RateSnapshotKey != converted.RateSnapshotKey)
            throw new ArithmeticException("Financial cash flows use different currency snapshots");
        template = new(template.Magnitude, template.Currency, template.RateStamp ?? converted.RateStamp);
        return Plain(new SheetValue(converted.Magnitude));
    }
    private SheetValue Output(Rational amount)
    {
        var number = new NumericValue(amount) { IsApproximate = approximate, DisplayDecimalPlaces = 4 };
        return template is null ? new(number) : new(new MoneyValue(number, template.Currency, template.RateStamp));
    }
    private (Rational Growth, Rational Annuity) Series(Rational rate, int periods)
    {
        budget.Step(token);
        if (periods == 0) return (One, default);
        var (growth, annuity) = Series(rate, periods / 2);
        var doubledAnnuity = Multiply(annuity, Add(One, growth));
        var doubledGrowth = Multiply(growth, growth);
        return periods % 2 == 0 ? (doubledGrowth, doubledAnnuity) :
            (Multiply(doubledGrowth, Add(One, rate)), Add(doubledAnnuity, doubledGrowth));
    }
    private string Assumption(string detail) => detail + "; constant rate and equal periods; no taxes, fees, insurance or changing returns; source amounts retained; display rounding is not payment settlement" +
        (approximate ? "; ≈ bounded arithmetic rounded to 34 significant digits when exact components exceeded 4096 bits, or an input was already approximate; not a certified error interval" : "; exact rational computation") +
        (money.Provenance is { } source ? "; " + source : "");
    internal FinancialResult Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length);
        if (IsPlanningFunction(name)) return PlanningFunction(name,args);
        if (name.Equals("irr",StringComparison.OrdinalIgnoreCase)) return Irr(args);
        var key = name.ToLowerInvariant(); var rate = Rate(args[0]);
        if (key == "npv")
        {
            var flows = StatisticsArithmetic.Flatten(args.Skip(1), budget, token);
            if (flows.Length == 0) throw new ArithmeticException("NPV requires at least one cash flow");
            SetTemplate(flows); var cash = flows.Select(Cash).ToArray(); var result = default(Rational);
            for (var i = cash.Length - 1; i >= 0; i--) result = Divide(Add(result, cash[i]), Add(One, rate));
            return new(Output(result), Assumption("NPV: first cash flow at period 1; signed incoming/outgoing cash flows; add time-zero investment separately"));
        }
        var n = Periods(args[1], key != "pmt");
        var timing = args.Length == 5 ? Periods(args[4], true) : 0;
        if (timing > 1) throw new ArithmeticException("Financial payment timing must be 0 (end) or 1 (beginning)");
        SetTemplate(args.Skip(2).Take(Math.Min(2, args.Length - 2)));
        var a = Cash(args[2]); var b = args.Length >= 4 ? Cash(args[3]) : default;
        var (growth, annuity) = Series(rate, n);
        if (timing == 1) annuity = Multiply(annuity, Add(One, rate));
        var answer = key switch
        {
            "pmt" => Divide(Add(Multiply(a, growth), b), annuity),
            "fv" => Negate(Add(Multiply(b, growth), Multiply(a, annuity))),
            "pv" => Divide(Negate(Add(b, Multiply(a, annuity))), growth),
            _ => throw new FormatException("Unknown financial function")
        };
        return new(Output(answer), Assumption((key == "pmt" ? "PMT: positive payment for positive borrowed principal (opposite Excel PMT sign); pv*growth - payment*annuity + fv = 0" :
            key == "fv" ? "FV: signed cash flows; -(pv*growth + payment*annuity)" : "PV: signed cash flows; -(fv + payment*annuity)/growth") +
            "; rate is per period; " + n + " periods; payments at " + (timing == 0 ? "end" : "beginning")));
    }
    private FinancialResult Irr(SheetValue[] args)
    {
        SheetValue[] flows; var guess = new Rational(1,10);
        if (args[0].Kind == SheetValueKind.List)
        {
            if (args.Length > 2) throw new FormatException("IRR list form is irr(cashFlows[,guess])");
            flows = StatisticsArithmetic.Flatten(args.Take(1),budget,token);
            if (args.Length == 2) guess = Rate(args[1]);
        }
        else
        {
            if (args.Any(value=>value.Kind==SheetValueKind.List)) throw new FormatException("Use irr(cashFlows[,guess]) for list inputs");
            flows = StatisticsArithmetic.Flatten(args,budget,token);
        }
        SetTemplate(flows); var cash = flows.Select(Cash).ToArray();
        var solution = new IrrSolver(budget,token).Solve(cash,guess);
        var evidence = solution.Evidence with { InputApproximate=approximate };
        var selected = evidence.Roots[evidence.SelectedRoot];
        var output = new NumericValue(solution.Rate,true) { IsApproximate=approximate || !selected.Exact, DisplayDecimalPlaces=4 };
        static string Percent(Rational rate) => new NumericValue(rate,true) { DisplayDecimalPlaces=4 }.Display;
        var candidates = string.Join(", ",evidence.Roots.Take(8).Select(root=>Percent(FractionMidpoint(root.LowerRate,root.UpperRate))));
        var assumption = "IRR: first cash flow at time 0, equal intervals, result per interval (not automatically annualized); " + flows.Length + " ordered flows; " +
            evidence.DistinctRoots + " distinct admissible rate(s) > -100%, repeated roots counted once; " + evidence.Method +
            "; candidates " + candidates + (evidence.Roots.Count > 8 ? ", …" : "") + "; nearest supplied/default guess " + Percent(guess) +
            "; within relative distance tolerance 1e-12, lower rate wins" + (evidence.ToleranceTie ? "; tolerance tie applied" : "") +
            "; selected root has " + (selected.Exact ? "an exact rational substitution" : "a certified rate enclosure with relative width <= 1e-14 (absolute near zero) and stable four-decimal percentage display") +
            (approximate ? "; certificate concerns represented inputs; upstream amount/guess approximation remains" : "; exact represented cash flows") +
            (money.Provenance is { } source ? "; " + source : "");
        return new(new SheetValue(output),assumption) { Irr=evidence };
    }
    private static Rational FractionMidpoint(Rational a,Rational b)
    {
        var n = a.Numerator*b.Denominator+b.Numerator*a.Denominator; var d = 2*a.Denominator*b.Denominator;
        var common=BigInteger.GreatestCommonDivisor(n,d); return new(n/common,d/common);
    }
    internal FinancialResult Plan(FinancialPlanExpression expression, SheetValue[] args)
    {
        SetTemplate([args[0], ..args.Skip(3).Where(value => !value.IsPercentage)]);
        var amount = Cash(args[0]);
        if (amount.Numerator.Sign < 0) throw new ArithmeticException("Loan, investment and contribution amounts must be nonnegative");
        var annualRate = Rate(args[1]);
        var term = args[2];
        if (term.Kind != SheetValueKind.CalendarPeriod || term.Period.Days != 0 || term.Period.Months is < 1 or > MaxPeriods)
            throw new ArithmeticException("Financial term must contain 1–1200 whole calendar months");
        var monthly = expression.Kind is "loan" or "mortgage" or "amortize" || expression.Frequency == 12;
        if (!monthly && term.Period.Months % 12 != 0) throw new ArithmeticException("Annual compounding requires whole years; use compounded monthly for a monthly term");
        var frequency = monthly ? 12 : 1;
        var n = term.Period.Months / (12/frequency); var rate = Divide(annualRate, new(frequency, 1));
        if (args.Length == 4)
        {
            var down = args[3].IsPercentage ? Multiply(amount, Plain(args[3], true)) : Cash(args[3]);
            if (down.Numerator.Sign < 0 || Subtract(amount, down).Numerator.Sign < 0) throw new ArithmeticException("Down payment must be between zero and the purchase price");
            amount = Subtract(amount, down);
        }
        var (growth, annuity) = Series(rate, n);
        if (expression.Kind is "loan" or "mortgage" or "amortize")
        {
            var payment = Divide(Multiply(amount, growth), annuity);
            var total = Multiply(payment, new(n, 1)); var interest = Subtract(total, amount);
            var rows = new List<AmortizationYear>();
            if (expression.Kind == "amortize")
            {
                var previous = amount;
                for (var paid = 0; paid < n; paid += 12)
                {
                    var count = Math.Min(12, n-paid); var end = paid+count;
                    var remaining = Series(rate, n-end); var elapsed = Series(rate, end);
                    var balance = Divide(Multiply(Multiply(amount, elapsed.Growth), remaining.Annuity), annuity);
                    var principal = Subtract(previous, balance);
                    rows.Add(new(rows.Count+1, count, Output(Subtract(Multiply(payment, new(count, 1)), principal)), Output(principal), Output(balance)));
                    previous = balance;
                }
            }
            // A later schedule row may activate fallback; mark every output consistently.
            if (approximate) rows = rows.Select(row => row with { Interest = Mark(row.Interest), Principal = Mark(row.Principal), Balance = Mark(row.Balance) }).ToList();
            return new(Output(payment), Assumption("Monthly end-of-period payment; nominal annual rate / 12; " + n + " payments; borrowed " + Output(amount).Display +
                "; total paid " + Output(total).Display + "; total interest " + Output(interest).Display + "; annual rows cover 12 payments, final row may be shorter"), rows.AsReadOnly());
        }
        var result = Multiply(amount, expression.Kind == "save" ? annuity : growth);
        var contributed = expression.Kind == "save" ? Multiply(amount, new(n, 1)) : amount;
        var addedGrowth = Subtract(result, contributed);
        return new(Output(result), Assumption((expression.Kind == "save" ? "End-of-period contributions" : "Lump-sum growth") + "; nominal annual rate / " + frequency +
            "; " + n + " periods; contributed " + Output(contributed).Display + "; growth " + Output(addedGrowth).Display));
    }
    private static SheetValue Mark(SheetValue value) => value.Kind == SheetValueKind.Money ? new(new MoneyValue(value.Money.Magnitude with { IsApproximate = true }, value.Money.Currency, value.Money.RateStamp)) : new(value.Number with { IsApproximate = true });
}
