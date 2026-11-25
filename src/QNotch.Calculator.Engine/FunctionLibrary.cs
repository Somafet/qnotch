using System.Security.Cryptography;
using System.Text;

namespace Calc.Core;

public sealed record FunctionDefinition(string Name, IReadOnlyList<string> Parameters, string Body);
public sealed record FunctionReceipt(string Key, int Count);
internal sealed record FunctionDirective(string Key, FunctionDefinition? Definition, string Name);

public sealed class SheetComputationLimitException() : ArgumentException("Sheet computation limit exceeded");

internal sealed class SharedExecutionBudget
{
    private int steps;
    internal void Step()
    {
        if (++steps > SheetEvaluator.MaxSheetSteps) throw new SheetComputationLimitException();
    }
}

internal sealed class ExecutionBudget(SharedExecutionBudget? shared = null)
{
    private int steps;
    private int scopes;
    private sealed class ScopeLease(Action leave) : IDisposable { public void Dispose() => leave(); }
    internal IDisposable Scope()
    {
        if (++scopes > 64) { scopes--; throw new ArithmeticException("Evaluation scope depth limit exceeded"); }
        return new ScopeLease(() => scopes--);
    }
    internal void Step(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (++steps > 16384) throw new ArithmeticException("Expression step limit exceeded");
        shared?.Step();
    }
}

/// <summary>Immutable, parameter-only function scope. No captured sheet values or host capabilities.</summary>
public sealed class FunctionLibrary
{
    public const int MaxFunctions = 128;
    public const int MaxDefinitionCharacters = 64000;
    private readonly Dictionary<string, (FunctionDefinition Definition, Expression Body)> compiled = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> uuidFunctions = new(StringComparer.OrdinalIgnoreCase);
    public bool HasUuid => uuidFunctions.Count > 0;
    public int MinimumCatalogVersion { get; }
    internal bool UsesUuid(string name) => uuidFunctions.Contains(name);
    private readonly HashSet<string> workdayFunctions = new(StringComparer.OrdinalIgnoreCase);
    internal bool UsesWorkdayCalendar(string name) => workdayFunctions.Contains(name);
    public static FunctionLibrary Empty { get; } = new([]);
    public IReadOnlyList<FunctionDefinition> Definitions { get; }
    public string Fingerprint { get; }
    public FunctionLibrary(IEnumerable<FunctionDefinition> definitions, CancellationToken token = default)
    {
        var copies = new List<FunctionDefinition>(); var characters = 0;
        foreach (var definition in definitions)
        {
            token.ThrowIfCancellationRequested();
            if (definition is null || !ValidIdentifier(definition.Name, 64) || IsBuiltin(definition.Name) || SheetSyntax.IsReserved(definition.Name) || definition.Name.Equals("forget", StringComparison.OrdinalIgnoreCase))
                throw new FormatException("Invalid or reserved function name");
            if (definition.Parameters is null || definition.Parameters.Count > 16 || definition.Parameters.Any(p => !ValidIdentifier(p, 32)) ||
                definition.Parameters.Distinct(StringComparer.OrdinalIgnoreCase).Count() != definition.Parameters.Count)
                throw new FormatException("Invalid function parameters");
            if (string.IsNullOrWhiteSpace(definition.Body) || definition.Body.Length > 4096) throw new FormatException("Function body must contain 1–4096 characters");
            characters += definition.Name.Length + definition.Body.Length + definition.Parameters.Sum(p => p.Length);
            if (copies.Count == MaxFunctions || characters > MaxDefinitionCharacters) throw new ArithmeticException("Function library limit exceeded");
            var copy = definition with { Parameters = Array.AsReadOnly(definition.Parameters.ToArray()) };
            var scopeNames = copy.Parameters.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var body = ParseBody(copy.Body, scopeNames, token);
            if (!compiled.TryAdd(copy.Name, (copy, body))) throw new FormatException("Duplicate function name");
            copies.Add(copy);
        }
        var graph = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in compiled)
        {
            var parameters = pair.Value.Definition.Parameters.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var dependencies = new HashSet<string>(StringComparer.OrdinalIgnoreCase); graph[pair.Key] = dependencies;
            foreach (var node in ExpressionEvaluation.Walk(pair.Value.Body))
            {
                token.ThrowIfCancellationRequested();
                if (node is NameExpression variable && !parameters.Contains(variable.Name)) throw new FormatException($"Function {pair.Key} has an unbound parameter: {variable.Name}");
                if (node is CallExpression call)
                {
                    int arity;
                    if (RateArithmetic.IsFunction(call.Name)) { RateArithmetic.ValidateArity(call.Name,call.Arguments.Length);continue; }
                    if (DeveloperArithmetic.IsFunction(call.Name)) { DeveloperArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (TextArithmetic.IsFunction(call.Name)) { TextArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (NetworkArithmetic.IsFunction(call.Name)) { NetworkArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (IntegerArithmetic.IsFunction(call.Name)) { IntegerArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (PracticalArithmetic.IsFunction(call.Name)) { PracticalArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (HelperArithmetic.IsFunction(call.Name)) { HelperArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (ElectricalArithmetic.IsFunction(call.Name)) { ElectricalArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (MatrixArithmetic.IsFunction(call.Name)) { MatrixArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (ComplexArithmetic.IsFunction(call.Name)) { ComplexArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (PrimeArithmetic.IsFunction(call.Name)) { PrimeArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (RomanianTaxArithmetic.IsFunction(call.Name)) { RomanianTaxArithmetic.ValidateArity(call.Name,call.Arguments.Length); continue; }
                    if (StatisticsArithmetic.IsFunction(call.Name)) { StatisticsArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (FinancialArithmetic.IsFunction(call.Name)) { FinancialArithmetic.ValidateArity(call.Name, call.Arguments.Length); continue; }
                    if (IsBuiltin(call.Name)) arity = BuiltinArity(call.Name);
                    else if (compiled.TryGetValue(call.Name, out var callee)) { dependencies.Add(call.Name); arity = callee.Definition.Parameters.Count; }
                    else throw new FormatException($"Unknown function: {call.Name}");
                    if (call.Arguments.Length != arity) throw new FormatException($"{call.Name} expects {arity} argument(s)");
                }
            }
        }
        var depths = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        while (depths.Count < graph.Count)
        {
            var progress = false;
            foreach (var pair in graph)
            {
                token.ThrowIfCancellationRequested();
                if (depths.ContainsKey(pair.Key) || pair.Value.Any(name => !depths.ContainsKey(name))) continue;
                var depth = pair.Value.Count == 0 ? 1 : pair.Value.Max(name => depths[name]) + 1;
                if (depth > 32) throw new ArithmeticException("Function call depth limit exceeded");
                depths[pair.Key] = depth; progress = true;
                if (ExpressionEvaluation.Walk(compiled[pair.Key].Body).Any(node => node is UuidExpression) || pair.Value.Any(uuidFunctions.Contains)) uuidFunctions.Add(pair.Key);
                if (ExpressionEvaluation.Walk(compiled[pair.Key].Body).Any(node => node is WorkdayPeriodExpression or WorkdayCountExpression or EarningsConvertExpression or SalaryExpression { OutputPeriod: EarningsPeriod.Hour or EarningsPeriod.Day }) || pair.Value.Any(workdayFunctions.Contains))
                    workdayFunctions.Add(pair.Key);
            }
            if (!progress) throw new FormatException("Recursive functions are not supported");
        }
        var rateSyntax = compiled.Values.Any(value => ExpressionEvaluation.Walk(value.Body).Any(node => node is UsageCountExpression or UsageConvertExpression or UsagePriceExpression or RateForExpression or TimestampJoinExpression || node is CallExpression call && RateArithmetic.IsFunction(call.Name)) ||
            BodyTokens(value.Definition.Body,token,value.Definition.Parameters.ToHashSet(StringComparer.OrdinalIgnoreCase)).Any(t=>t.Kind==TokenKind.Name&&!value.Definition.Parameters.Contains(t.Text,StringComparer.OrdinalIgnoreCase)&&RateSyntax.TrySpeedUnit(t.Text,out _)));
        var latestSyntax = compiled.Values.Any(value => ExpressionEvaluation.Walk(value.Body).Any(RequiresLatestCatalog));
        var formulaSyntax = compiled.Values.Any(value => ExpressionEvaluation.Walk(value.Body).Any(RequiresFormulaCatalog));
        MinimumCatalogVersion = latestSyntax ? LatestCatalogVersion : formulaSyntax ? FormulaCatalogVersion : rateSyntax ? 3 : HasUuid ? 2 : 1;
        Definitions = copies.AsReadOnly();
        Fingerprint = Hash(string.Join('\n', copies.OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase).Select(Canonical)));
    }
    internal (SheetValue Value, CalculationStep[] Steps) Invoke(string name, SheetValue[] arguments, ExecutionBudget budget, CancellationToken token, int depth = 0, EvaluationContext? context = null, ContextReads? contextReads = null)
    {
        budget.Step(token);
        if (depth >= 32) throw new ArithmeticException("Function call depth limit exceeded");
        if (!compiled.TryGetValue(name, out var function)) throw new FormatException($"Unknown function: {name}");
        if (arguments.Length != function.Definition.Parameters.Count) throw new FormatException($"{name} expects {function.Definition.Parameters.Count} argument(s)");
        var scope = function.Definition.Parameters.Select((p, i) => (p, arguments[i])).ToDictionary(p => p.p, p => p.Item2, StringComparer.OrdinalIgnoreCase);
        return ExpressionEvaluation.Evaluate(function.Body, parameter => scope[parameter], [], token,
            (callee, args, callContext) => Invoke(callee, args, budget, token, depth + 1, callContext, contextReads), budget, Describe, context, contextReads);
    }
    internal string? Describe(string name)
    {
        if (!compiled.TryGetValue(name, out var function)) return null;
        var text = function.Definition.Name + "(" + string.Join(", ", function.Definition.Parameters) + ") = " + function.Definition.Body;
        return text.Length <= 256 ? text : text[..256] + "…";
    }
    /// <summary>Catalog schema rule: 4 marks formula syntax (solve, integral, derivative, pi/e/tau/phi and formula sheet functions); 5 marks complex, prime, physical-constant, practical-helper, fuel-unit, plot, chart and table syntax. Older readers reject a body above their version. A later phase adds its nodes or names to the newest predicate and raises LatestCatalogVersion.</summary>
    public const int LatestCatalogVersion = 5, FormulaCatalogVersion = 4;
    internal static bool RequiresFormulaCatalog(Expression node) => node is EquationExpression or IntegralExpression or DerivativeExpression or ConstantExpression ||
        node is CallExpression call && (FormulaFunctions.IsSheetFunction(call.Name) || EquationSyntax.Function(call.Name));
    internal static bool RequiresLatestCatalog(Expression node) => node is ConstantExpression { Name: var name } && !FormulaFunctions.IsConstant(name) || node is ImaginaryExpression or HelperExpression or PlotExpression or ChartExpression or TableExpression ||
        node is UnitExpressionNode { Unit: var unit } && unit.FuelForm() != 0 ||
        node is CallExpression call && (ComplexArithmetic.IsFunction(call.Name) || PrimeArithmetic.IsFunction(call.Name) || HelperArithmetic.IsFunction(call.Name) || TableArithmetic.IsFunction(call.Name));
    internal static Expression ParseBody(string body, HashSet<string> scopeNames, CancellationToken token)
    {
        if (EquationSyntax.Prefix(body)) return EquationSyntax.Parse(body, scopeNames, token);
        var tokens = ExpressionParser.Tokenize(body, token, scopeNames);
        return WorksheetSyntax.TryParse(tokens, scopeNames, token) ?? new ExpressionParser(tokens, token, scopeNames).Parse();
    }
    private static Token[] BodyTokens(string body, CancellationToken token, HashSet<string> scopeNames) => EquationSyntax.Prefix(body)
        ? EquationSyntax.Sides(body).SelectMany(side => ExpressionParser.Tokenize(side, token, scopeNames)).ToArray() : ExpressionParser.Tokenize(body, token, scopeNames);
    internal static bool IsBuiltin(string name) => TableArithmetic.IsFunction(name) || ComplexArithmetic.IsFunction(name) || PrimeArithmetic.IsFunction(name) || RateArithmetic.IsFunction(name) || name.Equals("uuid", StringComparison.OrdinalIgnoreCase) || FormulaFunctions.IsSheetFunction(name) || EquationSyntax.Function(name) || CalculusSyntax.IsFunction(name) || DeveloperArithmetic.IsFunction(name) || TextArithmetic.IsFunction(name) || NetworkArithmetic.IsFunction(name) || IntegerArithmetic.IsFunction(name) || PracticalArithmetic.IsFunction(name) || HelperArithmetic.IsFunction(name) || ElectricalArithmetic.IsFunction(name) || MatrixArithmetic.IsFunction(name) || RomanianTaxArithmetic.IsFunction(name) || StatisticsArithmetic.IsFunction(name) || FinancialArithmetic.IsFunction(name) || name.ToLowerInvariant() is "share" or "whole" or "beforediscount" or "change" or "markup" or "margin" or "abs" or "sqrt";
    internal static int BuiltinArity(string name) => EquationSyntax.Function(name) ? EquationSyntax.Arity(name) : CalculusSyntax.IsFunction(name) ? CalculusSyntax.Arity(name) : FormulaFunctions.IsSheetFunction(name) || name.ToLowerInvariant() is "abs" or "sqrt" ? 1 : 2;
    internal static bool ValidIdentifier(string? value, int limit) => value is { Length: > 0 } && value.Length <= limit &&
        (char.IsLetter(value[0]) || value[0] == '_') && value.All(c => char.IsLetterOrDigit(c) || c == '_' || KeywordCatalog.IsMark(c));
    internal static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    internal static string Canonical(FunctionDefinition definition)
    {
        var parameters = definition.Parameters.ToHashSet(StringComparer.OrdinalIgnoreCase);
        // Ordinary names remain case-insensitive; chemical literals are not (Co is cobalt, CO carbon monoxide).
        var body = ParseBody(definition.Body, parameters, default);
        var formulas = ExpressionEvaluation.Walk(body).OfType<ChemistryExpression>().Select(expression => expression.Formula).ToArray();
        string Text(string source)
        {
            var tokens = ExpressionParser.Tokenize(source, default, parameters);
            return string.Join(' ', Enumerable.Range(0, tokens.Length).Select(i =>
                tokens[i].Kind == TokenKind.Text ? "@TEXT:" + tokens[i].Text :
                i > 0 && tokens[i - 1].Kind == TokenKind.Time && TimeSyntax.IsMeridiem(tokens[i].Text) ? "@MERIDIEM:" + tokens[i].Text.ToUpperInvariant() :
                i > 0 && tokens[i].JoinedToPrevious && tokens[i - 1].Kind == TokenKind.Number && NumberLanguage.IsShortSuffix(tokens[i].Text)
                    ? NumberLanguage.CanonicalToken(tokens, i) : UnitCatalog.CanonicalToken(tokens, i, parameters) ?? NumberLanguage.CanonicalToken(tokens, i)));
        }
        var canonicalBody = EquationSyntax.Prefix(definition.Body) ? "SOLVE " + string.Join(" = ", EquationSyntax.Sides(definition.Body).Select(Text)) : Text(definition.Body);
        return definition.Name.ToUpperInvariant() + "(" + string.Join(',', definition.Parameters.Select(p => p.ToUpperInvariant())) + ")=" + canonicalBody +
            (formulas.Length == 0 ? "" : "|CHEM:" + string.Join('|', formulas));
    }
}
