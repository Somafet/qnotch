namespace Calc.Core;

internal sealed class PracticalArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    internal const string EngineeringAssumption = "Engineering display: exponent multiple of three, six significant figures and available decimal SI units; original exact magnitude and approximation provenance retained; copied expression reconstructs the represented value";
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "engineering" or "weightedmean" or "grades" or "molarmass" or "moles" or "massof";
    internal static void ValidateArity(string name, int count)
    {
        var key = name.ToLowerInvariant();
        if (key == "engineering") { if (count is < 1 or > 2) throw new FormatException("engineering expects a value and optional represented-approximation flag"); }
        else if (count != (key == "molarmass" ? 1 : 2)) throw new FormatException($"{name} has an invalid argument count");
    }
    internal SheetValue Engineering(SheetValue[] args)
    {
        ValidateArity("engineering", args.Length); var number = args[0].Number;
        if (args.Length == 2)
        {
            var flag = args[1].Number;
            if (flag.Unit is not null || flag.IsPercentage || flag.IsApproximate || !flag.IsRational || flag.Scalar != default && flag.Scalar != new Rational(1, 1)) throw new ArithmeticException("Represented-approximation flag must be exact 0 or 1");
            number = number with { IsApproximate = number.IsApproximate || flag.Scalar == new Rational(1, 1) };
        }
        return new(new EngineeringValue(number, math, budget, token));
    }
    internal SheetValue Grades(SheetValue[] scores, SheetValue[] weights)
    {
        if (scores.Length is < 1 or > SheetList.MaxItems || scores.Length != weights.Length) throw new ArithmeticException("Weighted grades require equal nonempty score/weight lists of at most 1024 entries");
        var sum = default(ExactNumber); var total = default(ExactNumber); var approximate = false;
        var percentScores = scores[0].IsPercentage; var percentWeights = weights[0].IsPercentage;
        for (var i = 0; i < scores.Length; i++)
        {
            budget.Step(token); var score = scores[i].Number; var weight = weights[i].Number;
            if (score.Unit is not null || weight.Unit is not null || !weight.IsRational || weight.Exact.Rational.Numerator.Sign < 0 || score.IsPercentage != percentScores || weight.IsPercentage != percentWeights)
                throw new ArithmeticException("Grades require dimensionless scores, nonnegative rational weights and consistent percentage types");
            approximate |= score.IsApproximate || weight.IsApproximate;
            budget.Step(token); var product = math.Multiply(score.Exact, weight.Exact);
            budget.Step(token); sum = math.Add(sum, product);
            budget.Step(token); total = math.Add(total, weight.Exact);
        }
        if (total.IsZero) throw new ArithmeticException("Total grade weight must be positive");
        budget.Step(token);
        return new NumericValue(math.Divide(sum, total), percentScores) { IsApproximate = approximate, DisplayDecimalPlaces = 4 };
    }
}
