using Calc.Core;

namespace Calc.Core.Tests;

/// <summary>Shared helpers for the practical-helper tests: evaluation with a fixed host snapshot and exact decimal literals as rationals.</summary>
internal static class Practical
{
    internal static readonly EvaluationContext Clock = new(new DateOnly(2026, 10, 31), new DateTimeOffset(2026, 10, 31, 12, 0, 0, TimeSpan.Zero));
    internal static LineResult Last(string source, EvaluationContext? context = null) => SheetEvaluator.Evaluate(source, default, context ?? Clock)[^1];
    internal static SheetValue Value(string source, EvaluationContext? context = null)
    {
        var result = Last(source, context);
        Assert.True(result.Error is null, source.Replace("\n", " / ") + " => " + result.Error);
        return result.Value!.Value;
    }
    internal static string Show(string source, EvaluationContext? context = null) => Value(source, context).Display;
    internal static bool Fails(string source, EvaluationContext? context = null) => Last(source, context).Error is not null;
    /// <summary>Exact rational from a decimal literal, independent of the evaluator's parser.</summary>
    internal static Rational R(string decimalText) => Rational.Parse(decimalText);
    /// <summary>The canonical (SI) rational magnitude of a numeric result.</summary>
    internal static Rational Canonical(SheetValue value) => value.Number.Exact.Rational;
    /// <summary>The magnitude in the result's own unit.</summary>
    internal static Rational InOwnUnit(SheetValue value) => Canonical(value) / value.Number.Unit!.Factor;
}
