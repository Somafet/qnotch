using System.Globalization;
using System.Numerics;

namespace Calc.Core;

/// <summary>Bounded one-variable real formula AST shared by equations, calculus and plotting. Sheet names are captured inputs.</summary>
internal abstract record FormulaTerm;
internal sealed record FormulaLiteral(Rational Value) : FormulaTerm;
internal sealed record FormulaVariable : FormulaTerm;
internal sealed record FormulaInput(int Index) : FormulaTerm;
internal sealed record FormulaConstant(string Name) : FormulaTerm;
internal sealed record FormulaNegate(FormulaTerm Operand) : FormulaTerm;
internal sealed record FormulaBinary(char Operation, FormulaTerm Left, FormulaTerm Right) : FormulaTerm;
internal sealed record FormulaCall(string Name, FormulaTerm Operand) : FormulaTerm;

internal static class FormulaFunctions
{
    internal const string Convention = "Double-precision evaluation; angles in radians; ln is natural, log is base 10";
    internal const int MaxNodes = 256;
    internal static bool IsSheetFunction(string name) => name.ToLowerInvariant() is "sin" or "cos" or "tan" or "asin" or "acos" or "atan" or "sinh" or "cosh" or "tanh" or "exp" or "ln" or "log";
    internal static bool IsFormulaFunction(string name) => IsSheetFunction(name) || name.ToLowerInvariant() is "sqrt" or "abs";
    internal static bool IsConstant(string name) => name.ToLowerInvariant() is "pi" or "π" or "e" or "tau" or "τ" or "phi" or "φ";
    internal static double Constant(string name) => name.ToLowerInvariant() switch { "e" => Math.E, "tau" or "τ" => Math.Tau, "phi" or "φ" => (1 + Math.Sqrt(5)) / 2, _ => Math.PI };
    internal static double Apply(string name, double x) => name switch
    {
        "sin" => Math.Sin(x), "cos" => Math.Cos(x), "tan" => Math.Tan(x), "asin" => Math.Asin(x), "acos" => Math.Acos(x), "atan" => Math.Atan(x),
        "sinh" => Math.Sinh(x), "cosh" => Math.Cosh(x), "tanh" => Math.Tanh(x), "exp" => Math.Exp(x),
        "ln" => x > 0 ? Math.Log(x) : double.NaN, "log" => x > 0 ? Math.Log10(x) : double.NaN,
        "sqrt" => x >= 0 ? Math.Sqrt(x) : double.NaN, "abs" => Math.Abs(x), _ => throw new FormatException($"Unknown formula function: {name}")
    };
    internal static int Count(FormulaTerm term)
    {
        var stack = new Stack<FormulaTerm>(); stack.Push(term); var count = 0;
        while (stack.TryPop(out var node))
        {
            if (++count > 65536) throw new ArithmeticException("Formula size limit exceeded");
            switch (node) { case FormulaNegate n: stack.Push(n.Operand); break; case FormulaCall c: stack.Push(c.Operand); break; case FormulaBinary b: stack.Push(b.Left); stack.Push(b.Right); break; }
        }
        return count;
    }
    internal static bool DependsOnVariable(FormulaTerm term) => term switch
    {
        FormulaVariable => true, FormulaNegate n => DependsOnVariable(n.Operand), FormulaCall c => DependsOnVariable(c.Operand),
        FormulaBinary b => DependsOnVariable(b.Left) || DependsOnVariable(b.Right), _ => false
    };
}

/// <summary>Exact/double bridges. Approximate results are rounded to a stated number of significant decimal digits.</summary>
internal static class FormulaNumbers
{
    internal static double ToDouble(Rational value)
    {
        var numerator = value.Numerator; var denominator = value.Denominator;
        var numeratorShift = (int)Math.Max(0, numerator.GetBitLength() - 1000); var denominatorShift = (int)Math.Max(0, denominator.GetBitLength() - 1000);
        return Math.ScaleB((double)(numerator >> numeratorShift) / (double)(denominator >> denominatorShift), numeratorShift - denominatorShift);
    }
    internal static double ToDouble(ExactNumber value)
    {
        var total = ToDouble(value.Constant);
        foreach (var term in value.Radicals) total += ToDouble(term.Coefficient) * Math.Sqrt((double)term.Radicand);
        return total;
    }
    /// <summary>Four decimals for approximate roots, widened to four significant digits below 0.001 so small distinct roots never both show as 0.</summary>
    internal static int RootPlaces(double value) => value == 0 || !double.IsFinite(value) || Math.Abs(value) >= 1e-3 ? 4 : Math.Min(24, 3 - (int)Math.Floor(Math.Log10(Math.Abs(value))));
    internal static Rational FromDouble(double value, int significant = 12)
    {
        if (!double.IsFinite(value)) throw new ArithmeticException("Result is not a finite number");
        if (value == 0) return new(0, 1);
        significant = Math.Clamp(significant, 1, 16);
        var text = value.ToString("E" + (significant - 1).ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        var split = text.IndexOf('E');
        var digits = BigInteger.Parse(text[..split].Replace(".", ""), CultureInfo.InvariantCulture);
        var shift = int.Parse(text[(split + 1)..], CultureInfo.InvariantCulture) - (significant - 1);
        return shift >= 0 ? new(digits * BigInteger.Pow(10, shift), 1) : new(digits, BigInteger.Pow(10, -shift));
    }
}

/// <summary>Sampling entry point for solvers and plotters: the value at x, or NaN/infinity when undefined. One budget step per sample.</summary>
internal sealed class Formula(FormulaTerm term, string variable, double[] inputs)
{
    internal FormulaTerm Term => term;
    internal string Variable => variable;
    internal double[] Inputs => inputs;
    internal Formula With(FormulaTerm replacement) => new(replacement, variable, inputs);
    internal double Sample(double x, ExecutionBudget budget, CancellationToken token) { budget.Step(token); return Evaluate(term, x); }
    private double Evaluate(FormulaTerm node, double x) => node switch
    {
        FormulaLiteral literal => FormulaNumbers.ToDouble(literal.Value),
        FormulaVariable => x,
        FormulaInput input => inputs[input.Index],
        FormulaConstant constant => FormulaFunctions.Constant(constant.Name),
        FormulaNegate negate => -Evaluate(negate.Operand, x),
        FormulaCall call => FormulaFunctions.Apply(call.Name, Evaluate(call.Operand, x)),
        FormulaBinary binary => Binary(binary.Operation, Evaluate(binary.Left, x), Evaluate(binary.Right, x)),
        _ => throw new FormatException("Unknown formula term")
    };
    private static double Binary(char operation, double left, double right) => operation switch
    {
        '+' => left + right, '-' => left - right, '*' => left * right, '/' => right == 0 ? double.NaN : left / right,
        '^' => Math.Pow(left, right), _ => throw new FormatException("Unknown formula operator")
    };
}

/// <summary>Scalar algebra over tokens: + - * / ^, implicit multiplication (2x, 2(x+1)), unary minus, the listed functions, pi and e.</summary>
internal sealed class FormulaParser(IReadOnlyList<Token> tokens, string variable, List<Expression> inputs, Dictionary<string, int> indices, HashSet<string>? knownNames, CancellationToken token)
{
    private int position, depth, nodes;
    private Token Current => position < tokens.Count ? tokens[position] : new(TokenKind.End, "");
    private bool Take(string text) { if (!Current.Text.Equals(text, StringComparison.OrdinalIgnoreCase)) return false; position++; return true; }
    private T Made<T>(T term) where T : FormulaTerm { if (++nodes > FormulaFunctions.MaxNodes) throw new ArithmeticException("Formula size limit exceeded"); return term; }
    internal static FormulaTerm Parse(IReadOnlyList<Token> tokens, string variable, List<Expression> inputs, Dictionary<string, int> indices, HashSet<string>? knownNames, CancellationToken token)
        => new FormulaParser(tokens, variable, inputs, indices, knownNames, token).Parse();
    private FormulaTerm Parse()
    {
        if (tokens.Count == 0) throw new FormatException("Expected a formula");
        var term = Sum();
        if (position != tokens.Count) throw new FormatException("Unexpected formula text; only scalar algebra is supported");
        return term;
    }
    private FormulaTerm Sum()
    {
        var value = Product();
        while (Current.Text is "+" or "-") { var op = Current.Text[0]; position++; value = Made(new FormulaBinary(op, value, Product())); }
        return value;
    }
    private FormulaTerm Product()
    {
        var value = Unary();
        while (true)
        {
            if (Current.Text is "*" or "/" or "·") { var op = Current.Text == "·" ? '*' : Current.Text[0]; position++; value = Made(new FormulaBinary(op, value, Unary())); }
            else if (Current.Kind == TokenKind.Name || Current.Text == "(") { RejectExponentNotation(); value = Made(new FormulaBinary('*', value, Unary())); }
            else return value;
        }
    }
    // 1e-10 tokenizes as 1, e, -, 10; reading it as 1·e - 10 would be a silent wrong number. A sheet variable named e still wins.
    private void RejectExponentNotation()
    {
        if (Current.Kind == TokenKind.Name && Current.JoinedToPrevious && position > 0 && tokens[position - 1].Kind == TokenKind.Number && KnownNameLength() == 0 &&
            (Current.Text is "e" or "E" || Current.Text.Length > 1 && Current.Text[0] is 'e' or 'E' && Current.Text.Skip(1).All(char.IsAsciiDigit)))
            throw new FormatException("Scientific notation is not supported in formulas; write 1*10^-10, or 2*e for Euler's number");
    }
    private FormulaTerm Unary()
    {
        token.ThrowIfCancellationRequested();
        if (++depth > 48) throw new ArithmeticException("Formula depth limit exceeded");
        try
        {
            if (Take("+")) return Unary();
            if (Take("-")) return Made(new FormulaNegate(Unary()));
            var value = Atom();
            if (Take("^")) value = Made(new FormulaBinary('^', value, Unary()));
            return value;
        }
        finally { depth--; }
    }
    private FormulaTerm Atom()
    {
        if (Take("(")) { var value = Sum(); if (!Take(")")) throw new FormatException("Expected formula closing parenthesis"); return value; }
        if (Current.Kind == TokenKind.Number) { var n = Rational.Parse(Current.Text); position++; return Made(new FormulaLiteral(n)); }
        if (Current.Kind != TokenKind.Name) throw new FormatException("Expected a formula term");
        var name = Current.Text; var next = position + 1 < tokens.Count ? tokens[position + 1].Text : "";
        var known = KnownNameLength();
        if (known <= 1 && !name.Equals(variable, StringComparison.OrdinalIgnoreCase) && next == "(" && FormulaFunctions.IsFormulaFunction(name))
        {
            position += 2; var argument = Sum();
            if (!Take(")")) throw new FormatException(name + " expects one argument");
            return Made(new FormulaCall(name.ToLowerInvariant(), argument));
        }
        if (known > 1) { name = string.Join(' ', tokens.Skip(position).Take(known).Select(t => t.Text)); position += known; }
        else position++;
        if (name.Equals(variable, StringComparison.OrdinalIgnoreCase)) return Made(new FormulaVariable());
        if (known == 0 && FormulaFunctions.IsConstant(name)) return Made(new FormulaConstant(name.ToLowerInvariant()));
        if (known == 0 && name == "i") throw new FormatException("Formulas are real-valued; the imaginary unit i is not supported here");
        if (known == 0 && ConstantCatalog.IsPhysical(name))
        {
            // Case-sensitive aliases must not share a case-insensitive sheet input.
            var key = "\0" + name;
            if (!indices.TryGetValue(key, out var slot)) { slot = inputs.Count; indices.Add(key, slot); inputs.Add(new ConstantExpression(name, true)); }
            return Made(new FormulaInput(slot));
        }
        if (!indices.TryGetValue(name, out var index)) { index = inputs.Count; indices.Add(name, index); inputs.Add(new NameExpression(name)); }
        return Made(new FormulaInput(index));
    }
    private int KnownNameLength()
    {
        if (knownNames is null || knownNames.Count == 0) return 0;
        var words = new List<string>(); var best = 0; var length = 0;
        for (var end = position; end < tokens.Count && tokens[end].Kind == TokenKind.Name; end++)
        {
            length += tokens[end].Text.Length + (end == position ? 0 : 1);
            if (length > 128) break;
            words.Add(tokens[end].Text);
            if (knownNames.Contains(string.Join(' ', words))) best = words.Count;
        }
        return best;
    }
}
