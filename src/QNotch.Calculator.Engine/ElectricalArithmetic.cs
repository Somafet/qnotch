using System.Numerics;

namespace Calc.Core;

internal sealed class ElectricalArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    internal const string ParallelAssumption = "Passive DC parallel resistance; reciprocal sum 1 / sum(1/R); zero is an ideal short; nonnegative finite inputs; no frequency/temperature/lead or tolerance interval model";
    internal static readonly Dimension ResistanceDimension = new(2, 1, -3, -2, 0, 0, 0, 0);
    internal static SheetValue PreferElectricalUnit(SheetValue left, SheetValue right, SheetValue result)
    {
        if (left.Kind != SheetValueKind.Number || right.Kind != SheetValueKind.Number || left.Number.Unit is null || right.Number.Unit is null || left.Number.Unit.Dimension.Current == 0 && right.Number.Unit.Dimension.Current == 0 || result.Kind != SheetValueKind.Number || result.Number.Unit is not { } unit) return result;
        string? id = unit.Dimension == ResistanceDimension ? "ohm" : unit.Dimension == new Dimension(0, 0, 0, 1, 0, 0, 0, 0) ? "A" :
            unit.Dimension == new Dimension(2, 1, -3, -1, 0, 0, 0, 0) ? "V" : unit.Dimension == new Dimension(2, 1, -3, 0, 0, 0, 0, 0) ? "W" : null;
        return id is null ? result : new(result.Number with { Unit = UnitExpression.Single(UnitCatalog.ById(id)) });
    }
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "parallel" or "resistor" or "resistorcolors";
    internal static void ValidateArity(string name, int count)
    {
        if (name.Equals("parallel", StringComparison.OrdinalIgnoreCase))
        { if (count is < 1 or > 16) throw new FormatException("parallel expects 1–16 resistance arguments or a list"); }
        else if (count is < 1 or > 3) throw new FormatException($"{name} expects resistance, optional tolerance and optional significant digits");
    }
    private void Step() => budget.Step(token);
    internal static string MarkingAssumption(ResistorValue value) => $"Commercial {value.SignificantDigits}-digit marking; ±{value.Tolerance * new Rational(100, 1)}% of nominal; resistance range {value.MinimumOhms}–{value.MaximumOhms} ohm; {ResistorColorCatalog.RuleId}; {ResistorColorCatalog.Source}; caller supplies band order; not a measured value or power rating; arithmetic uses nominal resistance and does not propagate tolerance intervals";
    internal static string NominalAssumption(ResistorValue value) => $"Nominal resistance used from {string.Join(' ', value.Bands)} (±{value.Tolerance * new Rational(100, 1)}%); component tolerance intervals are not propagated through arithmetic";
    private static Rational Power10(int exponent) => exponent >= 0 ? new(BigInteger.Pow(10, exponent), 1) : new(1, BigInteger.Pow(10, -exponent));
    internal ResistorValue Decode(IReadOnlyList<string> bands, bool colors = false)
    {
        if (bands.Count is < 3 or > 5) throw new ArithmeticException("Resistor requires three, four or five commercial bands");
        var definitions = bands.Select(name => ResistorColorCatalog.TryGet(name, out var color) ? color : throw new ArithmeticException("Unknown resistor color")).ToArray();
        var digits = bands.Count == 5 ? 3 : 2; var significant = 0;
        for (var i = 0; i < digits; i++)
        {
            Step(); var digit = definitions[i].Digit ?? throw new ArithmeticException("Gold/silver cannot be significant-digit bands");
            if (i == 0 && digit == 0) throw new ArithmeticException("First significant band cannot be black; zero-ohm jumper markings are not implemented");
            significant = significant * 10 + digit;
        }
        var tolerance = bands.Count == 3 ? new Rational(1, 5) : definitions[^1].Tolerance ?? throw new ArithmeticException("Invalid commercial tolerance band");
        var nominal = new Rational(significant, 1) * Power10(definitions[digits].MultiplierExponent);
        return new(nominal, tolerance, definitions.Select(color => color.Name), digits, colors);
    }
    private static NumericValue Resistance(SheetValue input, bool allowBare)
    {
        var number = input.Kind == SheetValueKind.Resistor ? input.Resistor.Nominal : input.Number;
        if (number.IsPercentage || number.Unit?.IsTemperaturePoint == true || number.Unit is null && !allowBare || number.Unit is not null && number.Unit.Dimension != ResistanceDimension)
            throw new ArithmeticException("Expected a resistance quantity (or an explicitly allowed bare ohm magnitude)");
        return number;
    }
    internal ResistorValue Encode(SheetValue[] args, bool colors)
    {
        var number = Resistance(args[0], true);
        if (!number.IsRational || number.IsApproximate || number.Exact.Rational.Numerator.Sign <= 0) throw new ArithmeticException("Color encoding requires a positive exact rational resistance");
        var ohms = number.Exact.Rational;
        var original = args[0].Kind == SheetValueKind.Resistor ? args[0].Resistor : null;
        var tolerance = original?.Tolerance ?? new Rational(1, 5);
        if (args.Length >= 2)
        {
            var value = args[1].Number;
            if (value.Unit is not null || !value.IsRational || value.IsApproximate) throw new ArithmeticException("Tolerance requires an exact percentage or percent number");
            tolerance = value.IsPercentage ? value.Scalar : value.Scalar / new Rational(100, 1);
        }
        var toleranceColor = ResistorColorCatalog.Colors.SingleOrDefault(color => color.Tolerance == tolerance);
        if (tolerance != new Rational(1, 5) && toleranceColor is null) throw new ArithmeticException("Unsupported commercial tolerance; use 20, 10, 5, 2, 1, 0.5, 0.25, 0.1 or 0.05 percent");
        int? requestedDigits = original?.SignificantDigits;
        if (args.Length == 3)
        {
            var digits = args[2].Number;
            if (digits.Unit is not null || digits.IsPercentage || !digits.IsRational || digits.IsApproximate || digits.Scalar != new Rational(2, 1) && digits.Scalar != new Rational(3, 1))
                throw new ArithmeticException("Significant digits must be exactly 2 or 3");
            requestedDigits = (int)digits.Scalar.Numerator;
        }
        foreach (var digits in requestedDigits is { } count ? new[] { count } : new[] { 2, 3 })
        {
            if (digits == 3 && toleranceColor is null) continue; // A four-band three-digit code without tolerance is ambiguous.
            for (var exponent = -2; exponent <= 9; exponent++)
            {
                Step(); var significant = ohms / Power10(exponent);
                if (significant.Denominator != 1 || significant.Numerator < BigInteger.Pow(10, digits - 1) || significant.Numerator >= BigInteger.Pow(10, digits)) continue;
                var text = significant.Numerator.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var bands = text.Select(character => ResistorColorCatalog.Colors.Single(color => color.Digit == character - '0').Name).ToList();
                bands.Add(ResistorColorCatalog.Colors.Single(color => color.MultiplierExponent == exponent).Name);
                if (toleranceColor is not null) bands.Add(toleranceColor.Name);
                return Decode(bands, colors);
            }
        }
        throw new ArithmeticException("Resistance has no exact supported two/three-digit color code; provide a supported tolerance for three digits; values are never rounded to a preferred series");
    }
    internal NumericValue Parallel(SheetValue[] args)
    {
        var inputs = new List<SheetValue>();
        foreach (var arg in args)
        {
            if (arg.Kind == SheetValueKind.List) foreach (var item in arg.List.Values) Add(item);
            else Add(arg);
        }
        if (inputs.Count == 0) throw new ArithmeticException("Parallel resistance requires at least one input");
        var first = Resistance(inputs[0], true); var unitful = first.Unit is not null;
        var reciprocal = default(ExactNumber); var zero = false; var approximate = false; var numbers = new List<NumericValue>();
        foreach (var input in inputs)
        {
            Step(); var number = Resistance(input, true);
            if ((number.Unit is not null) != unitful) throw new ArithmeticException("Do not mix bare and unit-bearing parallel resistances");
            var sign = math.Sign(number.Exact);
            if (sign < 0) throw new ArithmeticException("Passive parallel resistance cannot be negative");
            approximate |= number.IsApproximate;
            if (sign == 0) zero = true;
            numbers.Add(number);
        }
        if (!zero) foreach (var number in numbers) { Step(); var conductance = math.Divide(ExactArithmetic.One, number.Exact); Step(); reciprocal = math.Add(reciprocal, conductance); }
        Step(); var exact = zero ? default : math.Divide(ExactArithmetic.One, reciprocal);
        return (first with { Exact = exact, IsApproximate = approximate, DisplayDecimalPlaces = 4, UseCompoundDuration = false, UseDaysInDuration = false });
        void Add(SheetValue value) { Step(); if (inputs.Count == SheetList.MaxItems) throw new ArithmeticException("Parallel network exceeds 1024 branches"); inputs.Add(value); }
    }
}
