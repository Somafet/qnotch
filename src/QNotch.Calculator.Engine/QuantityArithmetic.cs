namespace Calc.Core;

internal sealed class QuantityArithmetic(ExactArithmetic math)
{
    private static void Plain(NumericValue value)
    { if (value.Unit is not null) throw new ArithmeticException("Expected a dimensionless value"); }
    private static void Linear(NumericValue value)
    { if (value.Unit?.IsTemperaturePoint == true) throw new ArithmeticException("Use temperature differences for scaling, products and ratios"); }
    private static void Compatible(NumericValue a, NumericValue b)
    {
        if (a.Unit?.Dimension != b.Unit?.Dimension) throw new ArithmeticException("Incompatible dimensions");
        CompatibleKinds(a.QuantityKind, b.QuantityKind);
    }
    private static void CompatibleKinds(string? a, string? b)
    { if (!string.IsNullOrEmpty(a) && !string.IsNullOrEmpty(b) && a != b) throw new ArithmeticException("Incompatible quantity kinds"); }
    internal ExactNumber DisplayMagnitude(NumericValue value) => value.Unit is { } unit
        ? math.Scale(math.Subtract(value.Exact, new(unit.Offset)), new Rational(1, 1) / unit.Factor) : value.Exact;
    internal NumericValue Attach(NumericValue value, UnitExpression unit)
    {
        Plain(value);
        if (value.IsPercentage) throw new ArithmeticException("A percentage cannot be a unit magnitude");
        return Checked(Metadata(Result(math.Add(math.Scale(value.Exact, unit.Factor), new(unit.Offset)), unit), value));
    }
    private NumericValue Checked(NumericValue value)
    {
        if (value.Unit?.IsTemperaturePoint == true && math.Sign(value.Exact) < 0) throw new ArithmeticException("Temperature is below absolute zero");
        if (value.QuantityKind == TimeArithmetic.WorkedKind && value.Unit?.Dimension == TimeArithmetic.TimeDimension && math.Sign(value.Exact) < 0)
            throw new ArithmeticException("Deductions exceed the worked interval");
        return value;
    }
    internal NumericValue Convert(NumericValue value, UnitExpression unit)
    {
        if (value.Unit is not null && value.Unit.Dimension != unit.Dimension && value.Unit.FuelForm() is var form and not 0 && unit.FuelForm() == -form)
        {
            if (math.Sign(value.Exact) <= 0) throw new ArithmeticException("Fuel consumption and economy must be positive to convert");
            return value with { Exact = math.Divide(ExactArithmetic.One, value.Exact), Unit = unit, QuantityKind = "", DisplayDecimalPlaces = 2 };
        }
        if (value.Unit is null || value.Unit.Dimension != unit.Dimension) throw new ArithmeticException("Incompatible conversion dimensions");
        CompatibleKinds(value.QuantityKind, unit.Kind);
        if (value.Unit.IsTemperaturePoint != unit.IsTemperaturePoint) throw new ArithmeticException("Cannot convert a temperature point to a difference");
        return value with { Unit = unit, QuantityKind = string.IsNullOrEmpty(value.QuantityKind) ? unit.Kind : value.QuantityKind, UseCompoundDuration = false, UseDaysInDuration = false,
            DisplayDecimalPlaces = unit.FuelForm() != 0 ? 2 : value.DisplayDecimalPlaces };
    }
    internal NumericValue Scale(NumericValue value, Rational factor)
    { Linear(value); return Checked(value with { Exact = math.Scale(value.Exact, factor) }); }
    internal NumericValue Unary(string operation, NumericValue value)
    {
        if (operation == "+") return value;
        if (operation == "-") return value.Unit?.IsTemperaturePoint == true
            ? Attach(new(math.Negate(DisplayMagnitude(value))), value.Unit) : Checked(value with { Exact = math.Negate(value.Exact) });
        Plain(value);
        if (operation == "%") return Metadata(new(math.Scale(value.Exact, new Rational(1, 100)), true), value);
        throw new FormatException("Unknown operator");
    }
    internal NumericValue Binary(string operation, NumericValue left, NumericValue right)
        => Metadata(BinaryCore(operation, left, right), left, right);
    private NumericValue BinaryCore(string operation, NumericValue left, NumericValue right)
    {
        if (operation is "+" or "-")
        {
            if (!left.IsPercentage && right.IsPercentage)
            {
                Linear(left);
                var delta = math.Multiply(left.Exact, right.Exact);
                return Checked(left with { Exact = operation == "+" ? math.Add(left.Exact, delta) : math.Subtract(left.Exact, delta) });
            }
            Compatible(left, right);
            var lp = left.Unit?.IsTemperaturePoint == true; var rp = right.Unit?.IsTemperaturePoint == true;
            if (lp && rp && operation == "+" || !lp && rp && operation == "-") throw new ArithmeticException("Invalid temperature-point arithmetic");
            var unit = lp && rp ? left.Unit!.Delta() : rp ? right.Unit : left.Unit;
            var result = operation == "+" ? math.Add(left.Exact, right.Exact) : math.Subtract(left.Exact, right.Exact);
            return Checked(unit is null ? new(result, left.IsPercentage && right.IsPercentage) : new(result, unit)
                { QuantityKind = string.IsNullOrEmpty(left.QuantityKind) ? right.QuantityKind : left.QuantityKind,
                  UseCompoundDuration = left.UseCompoundDuration || right.UseCompoundDuration, UseDaysInDuration = left.UseDaysInDuration || right.UseDaysInDuration });
        }
        if (operation == "^")
        {
            Plain(right);
            var exponent = right.Scalar; var unit = left.Unit?.Power(exponent);
            var powered = Result(exponent.Denominator == 2 && left.IsApproximate ? math.Power(Root(left), new(exponent.Numerator, 1)) : math.Power(left.Exact, exponent), unit);
            return exponent == new Rational(1, 1) ? powered with { QuantityKind = left.QuantityKind } : powered;
        }
        Linear(left); Linear(right);
        var divide = operation == "/";
        if (!divide && operation is not "*" and not "of") throw new FormatException("Unknown operator");
        UnitExpression? combined = left.Unit is null ? divide ? right.Unit?.Power(new(-1, 1)) : right.Unit :
            right.Unit is null ? left.Unit : left.Unit.Combine(right.Unit, divide ? -1 : 1);
        var exact = divide ? math.Divide(left.Exact, right.Exact) : math.Multiply(left.Exact, right.Exact);
        var answer = combined is null ? new NumericValue(exact, divide && left.IsPercentage && !right.IsPercentage) : Result(exact, combined);
        if (answer.Unit is not null && right.Unit is null) answer = answer with { QuantityKind = left.QuantityKind };
        if (answer.Unit is not null && left.Unit is null && !divide) answer = answer with { QuantityKind = right.QuantityKind };
        if (answer.Unit?.Dimension == TimeArithmetic.TimeDimension) answer = answer with { UseCompoundDuration = left.UseCompoundDuration || right.UseCompoundDuration, UseDaysInDuration = left.UseDaysInDuration || right.UseDaysInDuration };
        return Checked(answer);
    }
    // An approximate input has no exact radical worth extracting; its root stays a marked double.
    private ExactNumber Root(NumericValue value) => value.IsApproximate && math.Sign(value.Exact) > 0 ? new(FormulaNumbers.FromDouble(Math.Sqrt(FormulaNumbers.ToDouble(value.Exact)))) : math.SquareRoot(value.Exact);
    private static NumericValue Result(ExactNumber value, UnitExpression? unit)
        => unit is null || unit.Dimension == default ? new(value) : new(value, unit);
    internal NumericValue Function(string name, NumericValue[] args)
        => Metadata(FunctionCore(name, args), args);
    private NumericValue FunctionCore(string name, NumericValue[] args)
    {
        var key = name.ToLowerInvariant(); var count = key is "abs" or "sqrt" ? 1 : 2;
        if (args.Length != count) throw new FormatException($"{name} expects {count} argument(s)");
        var a = args[0]; var b = count == 2 ? args[1] : new NumericValue(new Rational(1, 1));
        if (key == "sqrt")
        {
            var unit = a.Unit?.Power(new(1, 2));
            return Result(Root(a), unit);
        }
        if (key == "abs") { Linear(a); return a with { Exact = math.Sign(a.Exact) < 0 ? math.Negate(a.Exact) : a.Exact }; }
        if (key is "whole" or "beforediscount")
        {
            Linear(a); Plain(b);
            if (!b.IsPercentage) throw new FormatException("Expected percentage");
            return a with { Exact = math.Divide(a.Exact, key == "whole" ? b.Exact : math.Subtract(ExactArithmetic.One, b.Exact)), IsPercentage = false };
        }
        Compatible(a, b); Linear(a); Linear(b);
        return key switch
        {
            "share" => new(math.Divide(a.Exact, b.Exact), true),
            "change" or "markup" => new(math.Divide(math.Subtract(b.Exact, a.Exact), a.Exact), true),
            "margin" => new(math.Divide(math.Subtract(b.Exact, a.Exact), b.Exact), true),
            _ => throw new FormatException($"Unknown function: {name}")
        };
    }
    internal NumericValue Aggregate(IReadOnlyList<NumericValue> values, bool average, CancellationToken token)
    {
        if (values.Count == 0) throw new ArithmeticException("No values to aggregate");
        var first = values[0]; var sum = default(ExactNumber); var kind = first.QuantityKind;
        foreach (var value in values)
        {
            token.ThrowIfCancellationRequested(); Compatible(first, value);
            CompatibleKinds(kind, value.QuantityKind);
            if (kind.Length == 0) kind = value.QuantityKind;
            if (first.Unit?.IsTemperaturePoint != value.Unit?.IsTemperaturePoint) throw new ArithmeticException("Cannot mix temperature points and differences in an aggregate");
            if (!average) Linear(value);
            sum = math.Add(sum, value.Exact);
        }
        if (average) sum = math.Scale(sum, new(1, values.Count));
        return Metadata(first.Unit is { } unit ? Checked(new(sum, unit) { QuantityKind = kind, UseCompoundDuration = values.Any(value => value.UseCompoundDuration), UseDaysInDuration = values.Any(value => value.UseDaysInDuration) }) : new(sum, values.All(value => value.IsPercentage)), values);
    }
    internal NumericValue Round(RoundingKind kind, NumericValue value, NumericValue precision, CancellationToken token)
        => RoundCore(kind, value, precision, token) with { IsApproximate = value.IsApproximate || precision.IsApproximate, DisplayDecimalPlaces = null };
    private NumericValue RoundCore(RoundingKind kind, NumericValue value, NumericValue precision, CancellationToken token)
    {
        if (value.Unit is not { } unit) { Plain(precision); return ExactRounding.Apply(kind, value, precision, token, math); }
        var quantum = precision;
        if (kind == RoundingKind.Increment)
        {
            Compatible(value, precision); Linear(precision);
            quantum = new(math.Scale(precision.Exact, new Rational(1, 1) / unit.Factor));
        }
        else Plain(precision);
        var rounded = ExactRounding.Apply(kind, new(DisplayMagnitude(value)), quantum, token, math);
        return Checked(Attach(rounded, unit) with { QuantityKind = value.QuantityKind, UseCompoundDuration = value.UseCompoundDuration, UseDaysInDuration = value.UseDaysInDuration });
    }
    private static NumericValue Metadata(NumericValue result, IReadOnlyList<NumericValue> inputs)
    {
        var approximate = result.IsApproximate; var places = result.DisplayDecimalPlaces; var notation = result.UseConstantNotation;
        foreach (var value in inputs)
        {
            approximate |= value.IsApproximate; notation |= value.UseConstantNotation;
            if (value.DisplayDecimalPlaces is { } count) places = Math.Max(places ?? 0, count);
        }
        return result with { IsApproximate = approximate, DisplayDecimalPlaces = places, UseConstantNotation = notation };
    }
    private static NumericValue Metadata(NumericValue result, NumericValue first, NumericValue second = default)
        => result with { IsApproximate = result.IsApproximate || first.IsApproximate || second.IsApproximate, UseConstantNotation = result.UseConstantNotation || first.UseConstantNotation || second.UseConstantNotation,
            DisplayDecimalPlaces = result.DisplayDecimalPlaces is null && first.DisplayDecimalPlaces is null && second.DisplayDecimalPlaces is null ? null :
                Math.Max(result.DisplayDecimalPlaces ?? 0, Math.Max(first.DisplayDecimalPlaces ?? 0, second.DisplayDecimalPlaces ?? 0)) };
}
