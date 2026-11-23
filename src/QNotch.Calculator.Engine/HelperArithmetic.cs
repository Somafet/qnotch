using System.Numerics;

namespace Calc.Core;

/// <summary>
/// Bounded practical estimators: cooking, body metrics, running, home materials and fuel. Every model, constant and default is disclosed in the step assumption;
/// results are formula estimates (never medical or professional advice) and keep exact values unless a floating-point model is involved.
/// </summary>
internal static class RationalOrder { internal static bool Above(this Rational value, Rational other) => (value - other).Numerator.Sign > 0; }

internal sealed partial class HelperArithmetic(ExactArithmetic math, ExecutionBudget budget, EvaluationContext context, ContextReads reads, CancellationToken token)
{
    internal readonly record struct Outcome(SheetValue Value, string Operation, string Assumption);
    internal static readonly Dimension Mass = new(0, 1, 0, 0, 0, 0, 0, 0), Length = new(1, 0, 0, 0, 0, 0, 0, 0), Time = new(0, 0, 1, 0, 0, 0, 0, 0),
        Area = new(2, 0, 0, 0, 0, 0, 0, 0), Volume = new(3, 0, 0, 0, 0, 0, 0, 0), TimePerLength = new(-1, 0, 1, 0, 0, 0, 0, 0), PerLength = new(-1, 0, 0, 0, 0, 0, 0, 0),
        Density = new(-3, 1, 0, 0, 0, 0, 0, 0);
    internal static bool IsFunction(string name) => name.Equals("bmi", StringComparison.OrdinalIgnoreCase);
    internal static void ValidateArity(string name, int count)
    { if (count != 2) throw new FormatException(name + " expects a mass and a height"); }
    internal Outcome Function(string name, SheetValue[] args) { ValidateArity(name, args.Length); return Bmi(args[0], args[1]); }
    internal Outcome Evaluate(HelperExpression node, SheetValue[] inputs)
    {
        budget.Step(token);
        return node.Kind switch
        {
            HelperKind.Bmr => Bmr(inputs, node.Words[0]), HelperKind.Tdee => Tdee(inputs, node.Words[0], node.Words[1]), HelperKind.HeartZones => HeartZones(inputs[0], node.Words[0]),
            HelperKind.Pace => Pace(inputs[0], inputs[1]), HelperKind.RunTime => RunTime(inputs[0], inputs[1]), HelperKind.Race => Race(inputs[0], inputs[1], inputs[2]),
            HelperKind.Paint => Paint(inputs, node.Words), HelperKind.Tiles => Tiles(inputs), HelperKind.Concrete => Concrete(inputs, node.Words),
            HelperKind.FuelTrip => FuelTrip(inputs), HelperKind.TimeDifference => TimeDifference(inputs, node.Words[0], node.Words[1]),
            HelperKind.Scale => Scale(inputs[0], inputs[1], inputs[2]), HelperKind.Ingredient => Ingredient(inputs[0], node.Words[0], node.Unit!),
            HelperKind.Count => new(inputs[0], node.Words[0], "Dimensionless count label: the number is unchanged"),
            _ => throw new FormatException("Unknown helper")
        };
    }
    private static NumericValue NumberOf(SheetValue value, string role) => value.Kind == SheetValueKind.Number ? value.Number : throw new ArithmeticException(role + " must be a number or quantity");
    private static bool Approximate(params SheetValue[] values) => values.Any(value => value.Kind == SheetValueKind.Number && value.Number.IsApproximate);
    /// <summary>The canonical (SI) rational magnitude of a quantity of the given dimension, strictly positive unless <paramref name="allowZero"/>.</summary>
    private static Rational Quantity(SheetValue value, Dimension dimension, string role, string hint, bool allowZero = false)
    {
        var number = NumberOf(value, role);
        if (number.IsPercentage || number.Unit is null || number.Unit.Dimension != dimension || number.Unit.IsTemperaturePoint) throw new ArithmeticException(role + " must be a " + hint + " quantity");
        if (!number.IsRational) throw new ArithmeticException(role + " must be an exact rational quantity");
        var magnitude = number.Exact.Rational;
        if (magnitude.Numerator.Sign < 0 || magnitude.Numerator.IsZero && !allowZero) throw new ArithmeticException(role + " must be positive");
        return magnitude;
    }
    private static Rational Plain(SheetValue value, string role)
    {
        var number = NumberOf(value, role);
        if (number.IsPercentage || number.Unit is not null || !number.IsRational) throw new ArithmeticException(role + " must be a plain exact number");
        return number.Exact.Rational;
    }
    private static SheetValue Result(NumericValue value) => new(value);
    private static NumericValue Seconds(Rational seconds, bool approximate = false) => new(new ExactNumber(seconds), UnitExpression.Single(UnitCatalog.ById("s"))) { IsApproximate = approximate };
    private static BigInteger CeilingOfPositive(Rational value) => BigInteger.Divide(value.Numerator + value.Denominator - 1, value.Denominator);
}
