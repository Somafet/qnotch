namespace Calc.Core;

internal sealed record EquationExpression(string Variable, FormulaTerm Left, FormulaTerm Right, Expression[] Inputs, bool HasDomain) : Expression;
internal sealed record IntegralExpression(string Variable, FormulaTerm Body, Expression[] Inputs) : Expression;
internal sealed record DerivativeExpression(string Variable, FormulaTerm Body, Expression[] Inputs) : Expression;
internal sealed record ConstantExpression(string Name, bool Magnitude = false) : Expression;

/// <summary>solve left = right [for name] [from lower to upper]; either tail order. A sheet variable named solve disables the sentence.</summary>
internal static class EquationSyntax
{
    internal static bool Prefix(string text) => text.Length > 6 && text.StartsWith("solve", StringComparison.OrdinalIgnoreCase) && char.IsWhiteSpace(text[5]) &&
        text.Contains('=') && !text[6..].TrimStart().StartsWith('=');
    internal static bool Function(string name) => name.ToLowerInvariant() is "solutionroot" or "solutioncount";
    internal static int Arity(string name) => name.Equals("solutionRoot", StringComparison.OrdinalIgnoreCase) ? 2 : 1;
    internal static string[] Sides(string text)
    {
        var sides = text[5..].Split('=');
        if (sides.Length != 2) throw new FormatException("An equation requires exactly one equality");
        return sides;
    }
    internal static EquationExpression Parse(string text, HashSet<string>? names, CancellationToken token)
    {
        var sides = Sides(text);
        var left = ExpressionParser.Tokenize(sides[0], token, names); var right = ExpressionParser.Tokenize(sides[1], token, names);
        var variable = "x"; int from = -1, to = -1, forAt = -1, nesting = 0; var end = right.Length;
        for (var i = 0; i < end; i++)
        {
            token.ThrowIfCancellationRequested(); var t = right[i].Text;
            if (t == "(") nesting++; else if (t == ")") nesting--;
            else if (nesting == 0 && right[i].Kind == TokenKind.Name)
            {
                if (t.Equals("for", StringComparison.OrdinalIgnoreCase) && forAt < 0) forAt = i;
                else if (t.Equals("from", StringComparison.OrdinalIgnoreCase) && from < 0) from = i;
                else if (t.Equals("to", StringComparison.OrdinalIgnoreCase) && from >= 0 && to < 0) to = i;
            }
        }
        if (nesting != 0) throw new FormatException("Unbalanced equation parentheses");
        int formulaEnd, domainEnd = end;
        if (forAt >= 0)
        {
            if (forAt + 1 >= end || right[forAt + 1].Kind != TokenKind.Name || !FunctionLibrary.ValidIdentifier(right[forAt + 1].Text, 32)) throw new FormatException("Use for followed by one variable name");
            variable = right[forAt + 1].Text;
            if (from < 0) { if (forAt + 2 != end) throw new FormatException("Use for followed by one variable name"); formulaEnd = forAt; }
            else if (forAt + 2 == from) formulaEnd = forAt;
            else if (from < forAt && forAt + 2 == end) { formulaEnd = from; domainEnd = forAt; }
            else throw new FormatException("Use for name and from lower to upper after the equation");
        }
        else formulaEnd = from >= 0 ? from : end;
        if (from >= 0 && (to <= from + 1 || to >= domainEnd - 1)) throw new FormatException("Use from lower to upper after the equation");
        var inputs = new List<Expression>(); var indices = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var leftTerm = FormulaParser.Parse(left, variable, inputs, indices, names, token);
        var rightTerm = FormulaParser.Parse(right.Take(formulaEnd).ToArray(), variable, inputs, indices, names, token);
        if (from >= 0)
        {
            inputs.Add(new ExpressionParser(right.Skip(from + 1).Take(to - from - 1).ToArray(), token, names).Parse());
            inputs.Add(new ExpressionParser(right.Skip(to + 1).Take(domainEnd - to - 1).ToArray(), token, names).Parse());
        }
        return new(variable, leftTerm, rightTerm, inputs.ToArray(), from >= 0);
    }
}

internal static class CalculusSyntax
{
    internal static bool IsFunction(string name) => name.ToLowerInvariant() is "integral" or "derivative";
    internal static int Arity(string name) => name.Equals("integral", StringComparison.OrdinalIgnoreCase) ? 3 : 2;
}

internal sealed partial class ExpressionParser
{
    /// <summary>integral(formula, lower, upper[, variable]) and derivative(formula, point[, variable]); the formula is parsed, not evaluated.</summary>
    private Expression ParseCalculus(string name)
    {
        var integral = name.Equals("integral", StringComparison.OrdinalIgnoreCase);
        var segments = new List<(int Start, int End)>(); var start = position; var nesting = 0;
        for (; position < tokens.Count; position++)
        {
            var text = tokens[position].Text;
            if (text is "(" or "[") nesting++;
            else if (text is ")" or "]") { if (nesting == 0) break; nesting--; }
            else if (text == "," && nesting == 0) { segments.Add((start, position)); start = position + 1; }
        }
        if (position >= tokens.Count) throw new FormatException("Expected )");
        segments.Add((start, position)); position++;
        var minimum = CalculusSyntax.Arity(name);
        if (segments.Count < minimum || segments.Count > minimum + 1)
            throw new FormatException(integral ? "integral expects (formula, lower, upper) with an optional variable name" : "derivative expects (formula, point) with an optional variable name");
        var variable = "x";
        if (segments.Count > minimum)
        {
            var (s, e) = segments[^1];
            if (e - s != 1 || tokens[s].Kind != TokenKind.Name || !FunctionLibrary.ValidIdentifier(tokens[s].Text, 32)) throw new FormatException("Name the variable with one identifier as the last argument");
            variable = tokens[s].Text;
        }
        var inputs = new List<Expression>(); var indices = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        Token[] Slice((int Start, int End) segment) => tokens.Skip(segment.Start).Take(segment.End - segment.Start).ToArray();
        var body = FormulaParser.Parse(Slice(segments[0]), variable, inputs, indices, knownNames, cancellationToken);
        for (var i = 1; i < minimum; i++) inputs.Add(new ExpressionParser(Slice(segments[i]), cancellationToken, knownNames, questionDepth + 1).Parse());
        return integral ? new IntegralExpression(variable, body, inputs.ToArray()) : new DerivativeExpression(variable, body, inputs.ToArray());
    }
}

/// <summary>Evaluates formula nodes: exact polynomial paths, numeric fallbacks marked approximate, and the sheet-level transcendental functions.</summary>
internal sealed class FormulaArithmetic(ExactArithmetic math, ExecutionBudget budget, CancellationToken token)
{
    private readonly EquationPolynomial polynomials = new(math, budget, token);
    internal static NumericValue Require(SheetValue value, string role)
    {
        if (value.Kind != SheetValueKind.Number || value.Number.Unit is not null) throw new ArithmeticException(role + " must be a dimensionless number");
        return value.Number;
    }
    internal static (Formula Formula, Rational?[] Exact, bool Approximate) Prepare(FormulaTerm term, string variable, SheetValue[] inputs, int count)
    {
        var doubles = new double[count]; var exact = new Rational?[count]; var approximate = false;
        for (var i = 0; i < count; i++)
        {
            var number = Require(inputs[i], "Formula input " + (i + 1));
            doubles[i] = FormulaNumbers.ToDouble(number.Exact); exact[i] = number.Exact.IsRational ? number.Exact.Rational : null; approximate |= number.IsApproximate;
        }
        return (new Formula(term, variable, doubles), exact, approximate);
    }
    private static NumericValue Approximate(double value, int significant = 12) => new(FormulaNumbers.FromDouble(value, significant)) { IsApproximate = true };
    private Rational RationalBound(NumericValue value, bool lower) => value.Exact.IsRational ? value.Exact.Rational : lower ? math.Bounds(value.Exact, 64).Lower : math.Bounds(value.Exact, 64).Upper;
    internal (SheetValue Value, string Assumption) Solve(EquationExpression equation, SheetValue[] inputs)
    {
        var constants = equation.Inputs.Length - (equation.HasDomain ? 2 : 0);
        var difference = new FormulaBinary('-', equation.Left, equation.Right);
        var (formula, exact, approximate) = Prepare(difference, equation.Variable, inputs, constants);
        NumericValue? lower = equation.HasDomain ? Require(inputs[^2], "Domain bound") : null, upper = equation.HasDomain ? Require(inputs[^1], "Domain bound") : null;
        if (lower is { } lo && upper is { } hi && math.Sign(math.Subtract(hi.Exact, lo.Exact)) <= 0) throw new ArithmeticException("Use from lower to upper with lower < upper");
        var polynomial = FormulaPolynomial.TryExtract(difference, exact, polynomials, token);
        if (polynomial is not null)
        {
            var solved = polynomials.Solve(polynomial, lower is { } l ? RationalBound(l, true) : null, upper is { } u ? RationalBound(u, false) : null);
            bool Inside(EquationRoot root) => root.Value.IsApproximate ? (lower is null || FormulaNumbers.ToDouble(root.Value.Exact) >= FormulaNumbers.ToDouble(lower.Value.Exact)) && (upper is null || FormulaNumbers.ToDouble(root.Value.Exact) <= FormulaNumbers.ToDouble(upper.Value.Exact))
                : (lower is null || math.Sign(math.Subtract(root.Value.Exact, lower.Value.Exact)) >= 0) && (upper is null || math.Sign(math.Subtract(root.Value.Exact, upper.Value.Exact)) <= 0);
            var roots = solved.Roots.Where(Inside).Select(root => approximate ? root with { Value = root.Value with { IsApproximate = true, DisplayDecimalPlaces = root.Value.DisplayDecimalPlaces ?? FormulaNumbers.RootPlaces(FormulaNumbers.ToDouble(root.Value.Exact)) } } : root);
            var scope = solved.Identity ? EquationSolutionScope.Identity : EquationSolutionScope.AllRealRoots;
            var summary = solved.Identity ? "Identity: every real value solves it" : "Exact: all distinct real roots" + (lower is null ? "" : " in the stated domain") + "; complex roots out of scope";
            return (new(new EquationValue(equation.Variable, roots, scope, solved.Method, summary, inDomain: lower is not null)), "Polynomial equation; exact arithmetic; complex roots out of scope");
        }
        var a = lower is { } dl ? FormulaNumbers.ToDouble(dl.Exact) : FormulaRoots.DefaultLower; var b = upper is { } dh ? FormulaNumbers.ToDouble(dh.Exact) : FormulaRoots.DefaultUpper;
        var (found, truncated) = FormulaRoots.Scan(formula, a, b, budget, token);
        var window = "[" + FormulaNumbers.FromDouble(a, 6) + ", " + FormulaNumbers.FromDouble(b, 6) + "]";
        var method = "Sign-change scan of " + FormulaRoots.Samples + " samples on " + window + " with bisection refinement; " + FormulaFunctions.Convention;
        var numeric = new EquationValue(equation.Variable, found.Select(root => new EquationRoot(Approximate(root) with { DisplayDecimalPlaces = FormulaNumbers.RootPlaces(root) })), EquationSolutionScope.BracketedRoots, method,
            "Approximate: " + (found.Length == 0 ? "no sign change found in " + window + ", not proof of no solution" : found.Length + " bracketed root(s) in " + window + "; no completeness claim"), truncated);
        return (new(numeric), "Nonpolynomial equation; bracketed roots only, no completeness claim; " + FormulaFunctions.Convention);
    }
    internal (SheetValue Value, string Assumption) Integrate(IntegralExpression integral, SheetValue[] inputs)
    {
        var (formula, exact, approximate) = Prepare(integral.Body, integral.Variable, inputs, inputs.Length - 2);
        var lower = Require(inputs[^2], "Lower bound"); var upper = Require(inputs[^1], "Upper bound");
        approximate |= lower.IsApproximate || upper.IsApproximate;
        if (FormulaPolynomial.TryExtract(integral.Body, exact, polynomials, token) is { } polynomial)
        {
            var antiderivative = polynomials.Antiderivative(polynomial);
            var value = math.Subtract(polynomials.EvaluateExact(antiderivative, upper.Exact), polynomials.EvaluateExact(antiderivative, lower.Exact));
            return (new NumericValue(value) { IsApproximate = approximate }, "Exact polynomial antiderivative evaluated at both bounds; dimensionless definite integral");
        }
        var (result, error, intervals) = FormulaIntegration.Integrate(formula, FormulaNumbers.ToDouble(lower.Exact), FormulaNumbers.ToDouble(upper.Exact), budget, token);
        var digits = error <= 0 ? 12 : (int)Math.Clamp(Math.Floor(Math.Log10(Math.Abs(result) / error)), 2, 12);
        var rounded = Math.Abs(result) <= FormulaIntegration.AbsoluteTolerance && error <= FormulaIntegration.AbsoluteTolerance ? new NumericValue(new Rational(0, 1)) { IsApproximate = true } : Approximate(result, digits);
        return (rounded, "Adaptive Gauss-Kronrod 7/15 over " + intervals + " subinterval(s), estimated error ≤ " + error.ToString("0.#E+0", System.Globalization.CultureInfo.InvariantCulture) + "; " + FormulaFunctions.Convention + "; infinite bounds and singularities unsupported");
    }
    internal (SheetValue Value, string Assumption) Differentiate(DerivativeExpression derivative, SheetValue[] inputs)
    {
        var (formula, exact, approximate) = Prepare(derivative.Body, derivative.Variable, inputs, inputs.Length - 1);
        var point = Require(inputs[^1], "Derivative point"); approximate |= point.IsApproximate;
        if (FormulaPolynomial.TryExtract(derivative.Body, exact, polynomials, token) is { } polynomial)
            return (new NumericValue(polynomials.EvaluateExact(polynomials.Derivative(polynomial), point.Exact)) { IsApproximate = approximate }, "Exact polynomial derivative evaluated at the point");
        var slope = FormulaDerivative.Differentiate(derivative.Body, token);
        var value = formula.With(slope).Sample(FormulaNumbers.ToDouble(point.Exact), budget, token);
        if (!double.IsFinite(value)) throw new ArithmeticException("Derivative is undefined at " + point.Display);
        return (Approximate(value), "Symbolic derivative d/d" + derivative.Variable + " = " + FormulaText.Render(slope, derivative.Variable) + ", evaluated at the point; " + FormulaFunctions.Convention);
    }
    internal SheetValue SheetFunction(string name, SheetValue[] args)
    {
        if (args.Length != 1) throw new FormatException(name + " expects 1 argument");
        var argument = Require(args[0], name + " argument");
        var value = FormulaFunctions.Apply(name.ToLowerInvariant(), FormulaNumbers.ToDouble(argument.Exact));
        if (!double.IsFinite(value)) throw new ArithmeticException(name + " is undefined at " + argument.Display);
        budget.Step(token); return Approximate(value);
    }
    internal SheetValue SolutionFunction(string name, SheetValue[] args)
    {
        if (args.Length != EquationSyntax.Arity(name)) throw new FormatException(name + " expects " + EquationSyntax.Arity(name) + " argument(s)");
        if (args[0].Kind != SheetValueKind.Equation) throw new ArithmeticException(name + " expects a solve result");
        var equation = args[0].Equation; budget.Step(token);
        if (equation.Scope == EquationSolutionScope.Identity) throw new ArithmeticException("An identity has no finite root list");
        if (name.Equals("solutionCount", StringComparison.OrdinalIgnoreCase)) return new(new Rational(equation.Roots.Count, 1));
        var index = Require(args[1], "Root index").Exact;
        if (!index.IsRational || index.Rational.Denominator != 1 || index.Rational.Numerator < 1 || index.Rational.Numerator > equation.Roots.Count)
            throw new ArithmeticException("Root index must be a whole number from 1 to " + equation.Roots.Count);
        return equation.Roots[(int)index.Rational.Numerator - 1].Value;
    }
}

/// <summary>Bounded readable rendering of a formula for explanations.</summary>
internal static class FormulaText
{
    internal static string Render(FormulaTerm term, string variable)
    {
        var text = Write(term, variable, 0);
        return text.Length <= 200 ? text : text[..200] + "…";
    }
    private static string Write(FormulaTerm node, string variable, int depth)
    {
        if (depth > 64) return "…";
        return node switch
        {
            FormulaLiteral literal => literal.Value.ToString(), FormulaVariable => variable, FormulaInput input => "c" + (input.Index + 1), FormulaConstant constant => constant.Name,
            FormulaNegate negate => "-(" + Write(negate.Operand, variable, depth + 1) + ")",
            FormulaCall call => call.Name + "(" + Write(call.Operand, variable, depth + 1) + ")",
            FormulaBinary binary => "(" + Write(binary.Left, variable, depth + 1) + " " + binary.Operation + " " + Write(binary.Right, variable, depth + 1) + ")",
            _ => "?"
        };
    }
}
