namespace Calc.Core;

/// <summary>Bounded complex arithmetic over exact parts. Results fall back to marked doubles only where no simple exact form exists.</summary>
internal sealed class ComplexArithmetic(ExactArithmetic math, QuantityArithmetic quantities, ExecutionBudget budget, CancellationToken token)
{
    internal const string Convention = "Exact parts where representable; principal values, arg in radians over (-pi, pi]; plain numbers only: no units, money, lists or matrices";
    internal const string Refusal = "Complex values combine only with plain numbers, not units, percentages, money, lists or matrices";
    private const string ExponentError = "Complex powers require an exact integer or half-integer exponent from -1024 to 1024";
    private const int SmallRootBits = 24; // Trial square extraction stays far inside the expression budget.
    private readonly record struct Parts(ExactNumber Re, ExactNumber Im, bool Approximate);
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "re" or "im" or "conj" or "arg";
    internal static void ValidateArity(string name, int count)
    { if (count != 1) throw new FormatException($"{name} expects 1 argument(s)"); }
    private static bool Plain(SheetValue value) => value.Kind == SheetValueKind.Number && value.Number.Unit is null && !value.IsPercentage;
    private static Parts Operand(SheetValue value) => value.Kind == SheetValueKind.Complex ? new(value.Complex.Real, value.Complex.Imaginary, value.Complex.IsApproximate) :
        Plain(value) ? new(value.Exact, default, value.Number.IsApproximate) : throw new ArithmeticException(Refusal);
    private static SheetValue Make(ExactNumber re, ExactNumber im, bool approximate) => im.IsZero ? new NumericValue(re) { IsApproximate = approximate } : new SheetValue(new ComplexValue(re, im, approximate));
    private static SheetValue Make(Parts z) => Make(z.Re, z.Im, z.Approximate);
    private static ExactNumber Approximate(double value) => new(FormulaNumbers.FromDouble(value));
    private bool Negative(SheetValue value) => Plain(value) && math.Sign(value.Exact) < 0;
    /// <summary>True when a binary operation has a complex operand or takes a half-integer power of a negative real.</summary>
    internal bool Applies(string operation, SheetValue left, SheetValue right) => left.Kind == SheetValueKind.Complex || right.Kind == SheetValueKind.Complex ||
        operation == "^" && Negative(left) && Plain(right) && !right.Number.IsApproximate && right.IsRational && right.Scalar.Denominator == 2;
    internal bool Applies(string name, SheetValue[] args) => IsFunction(name) || args.Length == 1 && (name.Equals("abs", StringComparison.OrdinalIgnoreCase) && args[0].Kind == SheetValueKind.Complex ||
        name.Equals("sqrt", StringComparison.OrdinalIgnoreCase) && (args[0].Kind == SheetValueKind.Complex || Negative(args[0])));
    private Parts Sum(Parts a, Parts b, bool subtract = false) => new(subtract ? math.Subtract(a.Re, b.Re) : math.Add(a.Re, b.Re), subtract ? math.Subtract(a.Im, b.Im) : math.Add(a.Im, b.Im), a.Approximate || b.Approximate);
    private Parts Product(Parts a, Parts b) => new(math.Subtract(math.Multiply(a.Re, b.Re), math.Multiply(a.Im, b.Im)), math.Add(math.Multiply(a.Re, b.Im), math.Multiply(a.Im, b.Re)), a.Approximate || b.Approximate);
    private ExactNumber Norm(Parts z) => math.Add(math.Multiply(z.Re, z.Re), math.Multiply(z.Im, z.Im));
    private Parts Quotient(Parts a, Parts b)
    {
        var norm = Norm(b); var product = Product(a, b with { Im = math.Negate(b.Im) });
        return product with { Re = math.Divide(product.Re, norm), Im = math.Divide(product.Im, norm) };
    }
    internal static SheetValue Literal(Rational coefficient) => Make(default, new(coefficient), false);
    internal SheetValue Binary(string operation, SheetValue left, SheetValue right)
    {
        budget.Step(token);
        var a = Operand(left);
        if (operation == "^") return Make(Power(a, right));
        var b = Operand(right);
        return Make(operation switch
        {
            "+" => Sum(a, b), "-" => Sum(a, b, true), "*" or "of" => Product(a, b), "/" => Quotient(a, b),
            _ => throw new ArithmeticException("Unsupported complex operation: " + operation)
        });
    }
    internal SheetValue Unary(string operation, SheetValue value)
    {
        budget.Step(token); var z = Operand(value);
        return operation switch
        {
            "+" => Make(z), "-" => Make(z with { Re = math.Negate(z.Re), Im = math.Negate(z.Im) }),
            _ => throw new ArithmeticException("Unsupported complex operation: " + operation)
        };
    }
    internal SheetValue Scale(SheetValue value, Rational factor)
    { budget.Step(token); var z = Operand(value); return Make(z with { Re = math.Scale(z.Re, factor), Im = math.Scale(z.Im, factor) }); }
    internal SheetValue Round(RoundingKind kind, SheetValue value, NumericValue precision)
    {
        budget.Step(token); var z = Operand(value);
        return Make(quantities.Round(kind, new(z.Re), precision, token).Exact, quantities.Round(kind, new(z.Im), precision, token).Exact, z.Approximate);
    }
    private Parts Power(Parts z, SheetValue exponent)
    {
        if (exponent.Kind == SheetValueKind.Complex) throw new ArithmeticException("Complex exponents are not supported");
        if (!Plain(exponent) || exponent.Number.IsApproximate || !exponent.IsRational) throw new ArithmeticException(ExponentError);
        var power = exponent.Scalar; var magnitude = System.Numerics.BigInteger.Abs(power.Numerator);
        if (power.Denominator > 2 || magnitude > 1024) throw new ArithmeticException(ExponentError);
        if (power.Denominator == 2) z = Root(z);
        var count = (int)magnitude; var answer = new Parts(ExactArithmetic.One, default, z.Approximate);
        while (count > 0)
        {
            budget.Step(token);
            if ((count & 1) != 0) answer = Product(answer, z);
            count >>= 1; if (count > 0) z = Product(z, z);
        }
        return power.Numerator.Sign < 0 ? Quotient(new(ExactArithmetic.One, default, false), answer) : answer;
    }
    /// <summary>A rational root stays exact when it is a perfect square or small enough to extract squares; null otherwise.</summary>
    private ExactNumber? ExactRoot(Rational value)
    {
        var n = math.IntegerRoot(value.Numerator); var d = math.IntegerRoot(value.Denominator);
        if (n * n == value.Numerator && d * d == value.Denominator) return new(new Rational(n, d));
        return value.Numerator.GetBitLength() <= SmallRootBits && value.Denominator.GetBitLength() <= SmallRootBits ? math.SquareRoot(new(value)) : null;
    }
    private Parts Root(Parts z)
    {
        budget.Step(token); var approximate = z.Approximate; var half = new Rational(1, 2);
        if (z.Im.IsZero && math.Sign(z.Re) >= 0)
            return approximate ? new(Approximate(Math.Sqrt(FormulaNumbers.ToDouble(z.Re))), default, true) : new(math.SquareRoot(z.Re), default, false);
        if (z.Im.IsZero)
            return approximate ? new(default, Approximate(Math.Sqrt(-FormulaNumbers.ToDouble(z.Re))), true) : new(default, math.SquareRoot(math.Negate(z.Re)), false);
        if (!approximate && z.Re.IsRational && z.Im.IsRational && ExactRoot((z.Re.Rational * z.Re.Rational) + (z.Im.Rational * z.Im.Rational)) is { IsRational: true } modulus)
        {
            var outer = ExactRoot((modulus.Rational + z.Re.Rational) * half); var inner = ExactRoot((modulus.Rational - z.Re.Rational) * half);
            if (outer is { } re && inner is { } im) return new(re, math.Sign(z.Im) < 0 ? math.Negate(im) : im, false);
        }
        double a = FormulaNumbers.ToDouble(z.Re), b = FormulaNumbers.ToDouble(z.Im), large = Math.Sqrt((Hypot(a, b) + Math.Abs(a)) / 2), small = Math.Abs(b) / (2 * large);
        var sign = b < 0 ? -1 : 1;
        return a >= 0 ? new(Approximate(large), Approximate(sign * small), true) : new(Approximate(small), Approximate(sign * large), true);
    }
    private static double Hypot(double a, double b) { var scale = Math.Max(Math.Abs(a), Math.Abs(b)); return scale == 0 ? 0 : scale * Math.Sqrt(a / scale * (a / scale) + b / scale * (b / scale)); }
    private SheetValue Modulus(Parts z)
    {
        var norm = Norm(z);
        if (!z.Approximate && norm.IsRational && ExactRoot(norm.Rational) is { } exact) return new NumericValue(exact);
        return new NumericValue(FormulaNumbers.FromDouble(Hypot(FormulaNumbers.ToDouble(z.Re), FormulaNumbers.ToDouble(z.Im)))) { IsApproximate = true };
    }
    private SheetValue Angle(Parts z)
    {
        if (z.Im.IsZero && z.Re.IsZero) throw new ArithmeticException("arg is undefined at 0");
        if (z.Im.IsZero && math.Sign(z.Re) > 0) return new NumericValue(new Rational(0, 1)) { IsApproximate = z.Approximate };
        return new NumericValue(FormulaNumbers.FromDouble(Math.Atan2(FormulaNumbers.ToDouble(z.Im), FormulaNumbers.ToDouble(z.Re)))) { IsApproximate = true };
    }
    internal SheetValue Function(string name, SheetValue[] args)
    {
        ValidateArity(name, args.Length); budget.Step(token); var z = Operand(args[0]);
        return name.ToLowerInvariant() switch
        {
            "re" => Make(z.Re, default, z.Approximate), "im" => Make(z.Im, default, z.Approximate), "conj" => Make(z with { Im = math.Negate(z.Im) }),
            "abs" => Modulus(z), "arg" => Angle(z), "sqrt" => Make(Root(z)),
            _ => throw new FormatException($"Unknown function: {name}")
        };
    }
}
