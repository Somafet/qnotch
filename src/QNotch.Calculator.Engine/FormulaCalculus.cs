namespace Calc.Core;

/// <summary>Symbolic differentiation over the formula AST with light constant folding and a bounded result size.</summary>
internal static class FormulaDerivative
{
    private const int MaxNodes = 4096;
    internal static FormulaTerm Differentiate(FormulaTerm term, CancellationToken token)
    {
        var nodes = 0;
        T Made<T>(T node) where T : FormulaTerm { token.ThrowIfCancellationRequested(); if (++nodes > MaxNodes) throw new ArithmeticException("Derivative size limit exceeded"); return node; }
        static bool Is(FormulaTerm node, int value) => node is FormulaLiteral literal && literal.Value == new Rational(value, 1);
        FormulaTerm Literal(Rational value) => Made(new FormulaLiteral(value));
        FormulaTerm Add(FormulaTerm a, FormulaTerm b) => Is(a, 0) ? b : Is(b, 0) ? a : a is FormulaLiteral x && b is FormulaLiteral y ? Literal(x.Value + y.Value) : Made(new FormulaBinary('+', a, b));
        FormulaTerm Sub(FormulaTerm a, FormulaTerm b) => Is(b, 0) ? a : Is(a, 0) ? Neg(b) : a is FormulaLiteral x && b is FormulaLiteral y ? Literal(x.Value - y.Value) : Made(new FormulaBinary('-', a, b));
        FormulaTerm Mul(FormulaTerm a, FormulaTerm b) => Is(a, 0) || Is(b, 0) ? Literal(new(0, 1)) : Is(a, 1) ? b : Is(b, 1) ? a : a is FormulaLiteral x && b is FormulaLiteral y ? Literal(x.Value * y.Value) : Made(new FormulaBinary('*', a, b));
        FormulaTerm Div(FormulaTerm a, FormulaTerm b) => Is(a, 0) ? a : Is(b, 1) ? a : Made(new FormulaBinary('/', a, b));
        FormulaTerm Pow(FormulaTerm a, FormulaTerm b) => Is(b, 1) ? a : Is(b, 0) ? Literal(new(1, 1)) : Made(new FormulaBinary('^', a, b));
        FormulaTerm Neg(FormulaTerm a) => a is FormulaLiteral x ? Literal(new Rational(-1, 1) * x.Value) : a is FormulaNegate n ? n.Operand : Made(new FormulaNegate(a));
        FormulaTerm Call(string name, FormulaTerm a) => Made(new FormulaCall(name, a));
        FormulaTerm D(FormulaTerm node)
        {
            switch (node)
            {
                case FormulaVariable: return Literal(new(1, 1));
                case FormulaLiteral or FormulaInput or FormulaConstant: return Literal(new(0, 1));
                case FormulaNegate negate: return Neg(D(negate.Operand));
                case FormulaBinary { Operation: '+' } b: return Add(D(b.Left), D(b.Right));
                case FormulaBinary { Operation: '-' } b: return Sub(D(b.Left), D(b.Right));
                case FormulaBinary { Operation: '*' } b: return Add(Mul(D(b.Left), b.Right), Mul(b.Left, D(b.Right)));
                case FormulaBinary { Operation: '/' } b: return Div(Sub(Mul(D(b.Left), b.Right), Mul(b.Left, D(b.Right))), Pow(b.Right, Literal(new(2, 1))));
                case FormulaBinary { Operation: '^' } b:
                    if (!FormulaFunctions.DependsOnVariable(b.Right))
                        return Mul(Mul(b.Right, Pow(b.Left, Sub(b.Right, Literal(new(1, 1))))), D(b.Left));
                    // General power: u^v (v' ln u + v u'/u).
                    return Mul(node, Add(Mul(D(b.Right), Call("ln", b.Left)), Div(Mul(b.Right, D(b.Left)), b.Left)));
                case FormulaCall call:
                    var u = call.Operand; var du = D(u);
                    FormulaTerm inner = call.Name switch
                    {
                        "sin" => Call("cos", u), "cos" => Neg(Call("sin", u)), "tan" => Div(Literal(new(1, 1)), Pow(Call("cos", u), Literal(new(2, 1)))),
                        "asin" => Div(Literal(new(1, 1)), Call("sqrt", Sub(Literal(new(1, 1)), Pow(u, Literal(new(2, 1)))))),
                        "acos" => Neg(Div(Literal(new(1, 1)), Call("sqrt", Sub(Literal(new(1, 1)), Pow(u, Literal(new(2, 1))))))),
                        "atan" => Div(Literal(new(1, 1)), Add(Literal(new(1, 1)), Pow(u, Literal(new(2, 1))))),
                        "sinh" => Call("cosh", u), "cosh" => Call("sinh", u), "tanh" => Div(Literal(new(1, 1)), Pow(Call("cosh", u), Literal(new(2, 1)))),
                        "exp" => node, "ln" => Div(Literal(new(1, 1)), u), "log" => Div(Literal(new(1, 1)), Mul(u, Call("ln", Literal(new(10, 1))))),
                        "sqrt" => Div(Literal(new(1, 1)), Mul(Literal(new(2, 1)), node)), "abs" => Div(u, node),
                        _ => throw new FormatException($"Unknown formula function: {call.Name}")
                    };
                    return Mul(inner, du);
                default: throw new FormatException("Unknown formula term");
            }
        }
        return D(term);
    }
}

/// <summary>Exact rational coefficient extraction when the formula is a polynomial in the variable; null otherwise.</summary>
internal static class FormulaPolynomial
{
    internal const int MaxDegree = 16;
    internal static Rational[]? TryExtract(FormulaTerm term, Rational?[] inputs, EquationPolynomial math, CancellationToken token)
    {
        Rational[]? Walk(FormulaTerm node)
        {
            token.ThrowIfCancellationRequested();
            switch (node)
            {
                case FormulaLiteral literal: return math.Trim([literal.Value]);
                case FormulaVariable: return [new(0, 1), new(1, 1)];
                case FormulaInput input: return inputs[input.Index] is { } value ? math.Trim([value]) : null;
                case FormulaConstant: return null;
                case FormulaNegate negate: return Walk(negate.Operand) is { } operand ? math.Scale(operand, new(-1, 1)) : null;
                case FormulaCall: return null;
                case FormulaBinary binary:
                    var left = Walk(binary.Left); if (left is null) return null;
                    var right = Walk(binary.Right); if (right is null) return null;
                    switch (binary.Operation)
                    {
                        case '+': return math.Sum(left, right);
                        case '-': return math.Sum(left, right, true);
                        case '*': return left.Length + right.Length - 2 > MaxDegree ? null : math.Product(left, right);
                        case '/': return right.Length == 1 ? math.Scale(left, new Rational(1, 1) / right[0]) : right.Length == 0 ? throw new ArithmeticException("Division by zero in formula") : null;
                        case '^':
                            if (right.Length > 1 || right.Length == 1 && (right[0].Denominator != 1 || right[0].Numerator.Sign < 0)) return null;
                            if (left.Length == 1) return ConstantPower(left[0], right.Length == 0 ? System.Numerics.BigInteger.Zero : right[0].Numerator);
                            // A variable base of degree >= 1 exceeds MaxDegree at exponent MaxDegree + 1, so the clamp only feeds the guard.
                            var exponent = right.Length == 0 ? 0 : (int)System.Numerics.BigInteger.Min(right[0].Numerator, MaxDegree + 1);
                            return (left.Length - 1) * exponent > MaxDegree ? null : math.Power(left, exponent);
                        default: throw new FormatException("Unknown formula operator");
                    }
                default: throw new FormatException("Unknown formula term");
            }
        }
        return Walk(term);
    }
    // Exact constant power with the true exponent; beyond the 4096-bit rational bound the formula takes the numeric path.
    private static Rational[]? ConstantPower(Rational value, System.Numerics.BigInteger exponent)
    {
        if (exponent.IsZero) return [new(1, 1)];
        var bits = Math.Max(System.Numerics.BigInteger.Abs(value.Numerator).GetBitLength(), value.Denominator.GetBitLength());
        if (bits > 1 && exponent * bits > 4096) return null;
        if (System.Numerics.BigInteger.Abs(value.Numerator).IsOne && value.Denominator.IsOne) return [new(value.Numerator.Sign < 0 && !exponent.IsEven ? -1 : 1, 1)];
        var power = (int)exponent;
        return [new(System.Numerics.BigInteger.Pow(value.Numerator, power), System.Numerics.BigInteger.Pow(value.Denominator, power))];
    }
}

/// <summary>Adaptive Gauss-Kronrod 7/15 integration with a QUADPACK-style error estimate and a subdivision bound.</summary>
internal static class FormulaIntegration
{
    private static readonly double[] Nodes = [0.991455371120812639206854697526329, 0.949107912342758524526189684047851, 0.864864423359769072789712788640926, 0.741531185599394439863864773280788,
        0.586087235467691130294144838258730, 0.405845151377397166906606412076961, 0.207784955007898467600689403773245, 0];
    private static readonly double[] KronrodWeights = [0.022935322010529224963732008058970, 0.063092092629978553290700663189204, 0.104790010322250183839876322541518, 0.140653259715525918745189590510238,
        0.169004726639267902826583426598550, 0.190350578064785409913256402421014, 0.204432940075298892414161999234649, 0.209482141084727828012999174891714];
    private static readonly double[] GaussWeights = [0.129484966168869693270611432679082, 0.279705391489276667901467771423780, 0.381830050505118944950369775488975, 0.417959183673469387755102040816327];
    internal const int MaxIntervals = 512;
    internal const double AbsoluteTolerance = 1e-12, RelativeTolerance = 1e-10;
    internal static (double Value, double Error, int Intervals) Integrate(Formula formula, double lower, double upper, ExecutionBudget budget, CancellationToken token)
    {
        if (!double.IsFinite(lower) || !double.IsFinite(upper)) throw new ArithmeticException("Integration bounds must be finite numbers");
        if (lower == upper) return (0, 0, 0);
        var sign = 1.0; if (lower > upper) { (lower, upper) = (upper, lower); sign = -1; }
        var intervals = new List<(double A, double B, double Value, double Error)> { Rule(formula, lower, upper, budget, token) };
        while (true)
        {
            var total = 0.0; var error = 0.0; var worst = 0;
            for (var i = 0; i < intervals.Count; i++) { total += intervals[i].Value; error += intervals[i].Error; if (intervals[i].Error > intervals[worst].Error) worst = i; }
            if (error <= Math.Max(AbsoluteTolerance, RelativeTolerance * Math.Abs(total))) return (sign * total, error, intervals.Count);
            if (intervals.Count >= MaxIntervals) throw new ArithmeticException("Integral did not converge within " + MaxIntervals + " subintervals; the integrand may be singular or oscillate rapidly");
            var (a, b, _, _) = intervals[worst]; var middle = (a + b) / 2;
            if (middle <= a || middle >= b) throw new ArithmeticException("Integral did not converge; the integrand may be singular");
            intervals[worst] = Rule(formula, a, middle, budget, token); intervals.Add(Rule(formula, middle, b, budget, token));
        }
    }
    private static (double A, double B, double Value, double Error) Rule(Formula formula, double a, double b, ExecutionBudget budget, CancellationToken token)
    {
        var center = (a + b) / 2; var half = (b - a) / 2;
        var centerValue = Sample(formula, center, budget, token);
        var kronrod = centerValue * KronrodWeights[7]; var gauss = centerValue * GaussWeights[3];
        var values = new double[7]; var mirrored = new double[7];
        for (var j = 0; j < 7; j++)
        {
            var offset = half * Nodes[j];
            values[j] = Sample(formula, center - offset, budget, token); mirrored[j] = Sample(formula, center + offset, budget, token);
            kronrod += KronrodWeights[j] * (values[j] + mirrored[j]);
            if ((j & 1) == 1) gauss += GaussWeights[j / 2] * (values[j] + mirrored[j]);
        }
        var mean = kronrod / 2; var spread = KronrodWeights[7] * Math.Abs(centerValue - mean);
        for (var j = 0; j < 7; j++) spread += KronrodWeights[j] * (Math.Abs(values[j] - mean) + Math.Abs(mirrored[j] - mean));
        spread *= half;
        var error = Math.Abs((kronrod - gauss) * half);
        if (spread != 0 && error != 0) error = spread * Math.Min(1, Math.Pow(200 * error / spread, 1.5));
        return (a, b, kronrod * half, error);
    }
    private static double Sample(Formula formula, double x, ExecutionBudget budget, CancellationToken token)
    {
        var value = formula.Sample(x, budget, token);
        if (!double.IsFinite(value)) throw new ArithmeticException("Integrand is undefined or infinite at " + FormulaNumbers.FromDouble(x, 6) + "; the integral is not computed");
        return value;
    }
}

/// <summary>Bounded sign-change scan with bisection refinement. Finds bracketed simple roots only; no completeness claim.</summary>
internal static class FormulaRoots
{
    internal const int Samples = 2000, MaxRoots = 16, Bisections = 100;
    internal const double DefaultLower = -10, DefaultUpper = 10;
    internal static (double[] Roots, bool Truncated) Scan(Formula formula, double lower, double upper, ExecutionBudget budget, CancellationToken token)
    {
        if (!double.IsFinite(lower) || !double.IsFinite(upper) || lower >= upper) throw new ArithmeticException("Search domain must be finite with lower < upper");
        var roots = new List<double>(); var truncated = false;
        var step = (upper - lower) / Samples;
        var previousX = lower; var previous = formula.Sample(lower, budget, token);
        if (previous == 0) roots.Add(lower);
        for (var i = 1; i <= Samples; i++)
        {
            var x = i == Samples ? upper : lower + i * step; var value = formula.Sample(x, budget, token);
            if (double.IsFinite(value) && double.IsFinite(previous))
            {
                if (value == 0) Keep(roots, x, ref truncated);
                else if (previous != 0 && Math.Sign(value) != Math.Sign(previous))
                {
                    if (roots.Count >= MaxRoots) truncated = true; // Further brackets are reported, not refined, so the budget stays bounded.
                    else if (Refine(formula, previousX, x, previous, value, budget, token) is { } root) Keep(roots, root, ref truncated);
                }
            }
            previousX = x; previous = value;
        }
        return (roots.ToArray(), truncated);
    }
    private static void Keep(List<double> roots, double root, ref bool truncated)
    {
        if (roots.Count > 0 && Math.Abs(roots[^1] - root) <= 1e-9 * Math.Max(1, Math.Abs(root))) return;
        if (roots.Count >= MaxRoots) { truncated = true; return; }
        roots.Add(root);
    }
    private static double? Refine(Formula formula, double a, double b, double fa, double fb, ExecutionBudget budget, CancellationToken token)
    {
        var scale = Math.Max(1, Math.Max(Math.Abs(fa), Math.Abs(fb)));
        for (var i = 0; i < Bisections; i++)
        {
            var middle = (a + b) / 2; if (middle <= a || middle >= b) break;
            var fm = formula.Sample(middle, budget, token);
            if (!double.IsFinite(fm)) return null;
            if (fm == 0) return middle;
            if (Math.Sign(fm) == Math.Sign(fa)) { a = middle; fa = fm; } else { b = middle; fb = fm; }
            if (b - a <= 1e-15 * Math.Max(1, Math.Abs(middle))) break;
        }
        var root = (a + b) / 2; var residual = formula.Sample(root, budget, token);
        // A discontinuity such as a tan pole also changes sign; only a small residual is a root.
        return double.IsFinite(residual) && Math.Abs(residual) <= 1e-6 * scale ? root : null;
    }
}
