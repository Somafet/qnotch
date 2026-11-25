namespace Calc.Core;

/// <summary>Deterministic typed sheet evaluation with explicit dependencies and no UI/network access.</summary>
public static class SheetEvaluator
{
    public const int MaxCharacters = 200_000;
    public const int MaxLines = 10_000;
    public const int MaxDependencyEdges = 100_000;
    public const int MaxSheetSteps = 500_000;
    public static IReadOnlyList<LineResult> Evaluate(string source, CancellationToken cancellationToken = default, EvaluationContext? context = null)
        => EvaluateFunctions(source, FunctionLibrary.Empty, [], cancellationToken, null, context).Results;

    internal static IReadOnlyList<LineResult> EvaluateCached(string source, CancellationToken cancellationToken, EvaluationCache? cache)
        => EvaluateFunctions(source, FunctionLibrary.Empty, [], cancellationToken, cache).Results;

    internal static SheetEvaluation EvaluateFunctions(string source, FunctionLibrary library, IReadOnlyList<FunctionReceipt> receipts, CancellationToken cancellationToken, EvaluationCache? cache, EvaluationContext? context = null)
    {
        context ??= new();
        if (source.Length > MaxCharacters) throw new ArgumentException("Sheet exceeds 200,000 characters");
        var sourceLines = source.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        if (sourceLines.Length > MaxLines) throw new ArgumentException("Sheet exceeds 10,000 lines");
        var tables = TableSyntax.Layout(sourceLines, cancellationToken);
        var parsed = new ParsedLine[sourceLines.Length];
        var scanned = new ParsedLine[sourceLines.Length];
        var parsedCount = 0; var evaluatedCount = 0; var reusedCount = 0;
        bool Unchanged(int i) => cache is not null && i < cache.Sources.Length && cache.Sources[i] == tables.Keys[i];
        var assignments = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < parsed.Length; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            parsed[i] = scanned[i] = Unchanged(i) ? cache!.Scanned[i] : tables.Scan(i, sourceLines, cancellationToken) ?? SheetSyntax.Scan(sourceLines[i], cancellationToken);
            if (parsed[i].Assignment is { } name)
            {
                if (!assignments.TryGetValue(name, out var indices)) assignments[name] = indices = [];
                indices.Add(i);
            }
        }
        var names = assignments.Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);
        // A user variable keeps its name; the automatic table of that name is then reachable only through its line.
        foreach (var table in tables.Blocks)
            if (table.Automatic && assignments.TryGetValue(table.Name, out var named) && named.Count > 1) named.Remove(table.Start);
        var functions = FunctionUpdate.Prepare(source, scanned, library, receipts, cancellationToken);
        var functionKey = functions.CacheKey;
        var sameNames = cache is not null && cache.Names.SetEquals(names);
        for (var i = 0; i < parsed.Length; i++)
            if (sameNames && Unchanged(i)) parsed[i] = cache!.Parsed[i];
            else { parsed[i] = SheetSyntax.Parse(parsed[i], names, cancellationToken); parsedCount++; }
        var syntax = parsed.ToArray();
        for (var i = 0; i < parsed.Length; i++)
            if (functions.Errors.TryGetValue(i, out var error)) parsed[i] = parsed[i] with { Error = error };
        var blockMembers = new List<int>[parsed.Length];
        var members = new List<int>();
        var tags = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        var totalMembers = new List<int>();
        for (var i = 0; i < parsed.Length; i++)
        {
            if (parsed[i].Boundary) members = [];
            blockMembers[i] = members;
            if (parsed[i].Directive is not null || parsed[i].FunctionName is not null || parsed[i].Assignment?.Equals("holidays", StringComparison.OrdinalIgnoreCase) == true || ExpressionEvaluation.SheetAggregate(parsed[i].Expression) is not null || ExpressionEvaluation.IsPresentation(parsed[i].Expression) || parsed[i].Expression is null && parsed[i].Error is null) continue;
            members.Add(i); totalMembers.Add(i);
            foreach (var tag in parsed[i].Tags)
            {
                if (!tags.TryGetValue(tag, out var tagged)) tags[tag] = tagged = [];
                tagged.Add(i);
            }
        }
        var dependencies = new int[parsed.Length][];
        var aggregateReferences = new int[parsed.Length][];
        var references = new Dictionary<string, int>[parsed.Length];
        var consumers = new List<int>[parsed.Length];
        var remaining = new int[parsed.Length];
        var results = new LineResult[parsed.Length];
        var edgeCount = 0;
        for (var i = 0; i < parsed.Length; i++) consumers[i] = [];
        for (var i = 0; i < parsed.Length; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            dependencies[i] = []; aggregateReferences[i] = []; references[i] = new(StringComparer.OrdinalIgnoreCase);
            results[i] = new(i, null, parsed[i].Error);
            if (parsed[i].Expression is not { } expression) continue;
            try
            {
                var required = new HashSet<int>();
                if (ExpressionEvaluation.Walk(expression).Any(node => node is WorkdayPeriodExpression or WorkdayCountExpression or EarningsConvertExpression or SalaryExpression { OutputPeriod: EarningsPeriod.Hour or EarningsPeriod.Day } || node is CallExpression call && functions.Library.UsesWorkdayCalendar(call.Name)) &&
                    assignments.TryGetValue("holidays", out var holidayDefinitions))
                {
                    var precedingHoliday = holidayDefinitions.BinarySearch(i);
                    if (precedingHoliday < 0) precedingHoliday = ~precedingHoliday;
                    if (precedingHoliday > 0)
                    { var target = holidayDefinitions[precedingHoliday - 1]; references[i]["\0holidays"] = target; required.Add(target); }
                }
                HashSet<int>? aggregateTargets = null;
                foreach (var node in ExpressionEvaluation.Walk(expression))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (node is CallExpression call && functions.BlockedNames.Contains(call.Name))
                        throw new FormatException($"Invalid function definition: {call.Name}");
                    if (node is NameExpression name)
                    {
                        int target;
                        if (SheetSyntax.IsLineReference(name.Name, out var line)) target = line;
                        else if (name.Name.Equals("prev", StringComparison.OrdinalIgnoreCase)) target = i - 1;
                        else
                        {
                            if (!assignments.TryGetValue(name.Name, out var definitions)) throw new FormatException($"Unknown variable: {name.Name}");
                            var preceding = definitions.BinarySearch(i);
                            if (preceding < 0) preceding = ~preceding;
                            target = preceding > 0 ? definitions[preceding - 1] : definitions[0];
                        }
                        if (target < 0 || target >= parsed.Length) throw new FormatException("Invalid line reference");
                        references[i][name.Name] = target; required.Add(target);
                    }
                    else if (node is AggregateExpression or ChartExpression { Data: null })
                    {
                        aggregateTargets ??= [];
                        var tag = node is AggregateExpression aggregate ? aggregate.Tag : ((ChartExpression)node).Tag;
                        IEnumerable<int> candidates = tag is null ? blockMembers[i].TakeWhile(n => n < i) : tags.GetValueOrDefault(tag) ?? [];
                        foreach (var target in candidates)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            required.Add(target);
                            aggregateTargets.Add(target);
                            if (required.Count + edgeCount > MaxDependencyEdges) throw new ArithmeticException("Sheet dependency limit exceeded");
                        }
                    }
                    if (required.Count + edgeCount > MaxDependencyEdges) throw new ArithmeticException("Sheet dependency limit exceeded");
                }
                dependencies[i] = required.Order().ToArray(); edgeCount += required.Count;
                aggregateReferences[i] = aggregateTargets?.Order().ToArray() ?? [];
                remaining[i] = required.Count;
                foreach (var target in required) consumers[target].Add(i);
            }
            catch (Exception e) when (e is FormatException or ArithmeticException) { results[i] = new(i, null, e.Message); }
        }
        var queue = new Queue<int>(Enumerable.Range(0, parsed.Length).Where(i => remaining[i] == 0));
        var completed = new bool[parsed.Length];
        var contextDependencies = new ContextDependency[parsed.Length];
        var currencyRequests = new DateOnly?[parsed.Length][];
        for (var i = 0; i < parsed.Length; i++) currencyRequests[i] = [];
        var uuidRequests = new HashSet<UuidRequest>(); var uuidPending = new bool[parsed.Length];
        var sheetBudget = new SharedExecutionBudget();
        while (queue.TryDequeue(out var i))
        {
            cancellationToken.ThrowIfCancellationRequested();
            completed[i] = true;
            if (results[i].Error is null && parsed[i].Expression is { } expression)
            {
                var reads = new ContextReads();
                try
                {
                    // A symbol-set change can turn prose/errors into expressions with the same empty dependency set.
                    bool SameContext() => cache is not null &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.Uuid) || cache.Uuids?.Key(i) == context.Uuids?.Key(i)) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.Dice) || cache.Uuids?.DiceKey(i) == context.Uuids?.DiceKey(i)) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.Date) || cache.Today == context.Today) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.PayrollRegion) || cache.PayrollRegion == context.PayrollRegion) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.DisplayCurrency) || cache.DisplayCurrency == context.DisplayCurrency) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.Instant) || cache.Now == context.Now) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.ZoneRules) || cache.ZoneVersion == context.Zones.VersionId) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.LocalZone) || cache.LocalZoneVersion == context.LocalZone?.Version) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.WorkdayCalendar) || cache.WorkdayRegion == context.WorkdayRegion && Equals(cache.CustomHolidays, context.CustomHolidays)) &&
                        (!cache.ContextDependencies[i].HasFlag(ContextDependency.CurrencyRates) || cache.CurrencyRateKey == (context.CurrencyRates ?? CurrencyRateBook.Empty).Key && cache.CurrencyDate == context.CurrencyDate);
                    if (sameNames && Unchanged(i) && SameContext() && !cache!.UuidPending[i] && cache.FunctionKey == functionKey && cache.Results[i].Dependencies.SequenceEqual(dependencies[i]) &&
                        cache.AggregateReferences[i].SequenceEqual(aggregateReferences[i]) && (parsed[i].Expression is not ChartExpression { Data: null } || aggregateReferences[i].All(Unchanged)) &&
                        cache.References[i].Count == references[i].Count && references[i].All(p => cache.References[i].TryGetValue(p.Key, out var target) && target == p.Value) &&
                        dependencies[i].All(d => d < cache.Results.Length && cache.Results[d].Value == results[d].Value && cache.Results[d].Error == results[d].Error))
                    {
                        results[i] = cache.Results[i]; contextDependencies[i] = cache.ContextDependencies[i]; reusedCount++;
                        currencyRequests[i] = cache.CurrencyRequests[i];
                    }
                    else
                    {
                    SheetValue Read(int target) => results[target].Value ?? throw new FormatException(results[target].Pending is null ? $"Dependency L{target + 1} unavailable" : $"L{target + 1} not rolled yet");
                    var aggregateValues = aggregateReferences[i].Length > 0 ? aggregateReferences[i].Select(Read).ToArray() : [];
                    var lineContext = references[i].TryGetValue("\0holidays", out var holidayLine) ? context with { CustomHolidays = Read(holidayLine).Holidays } : context;
                    if (context.Uuids is not null) lineContext = lineContext with { UuidLine = i, UuidPath = "" };
                    if (parsed[i].Expression is ChartExpression { Data: null }) lineContext = lineContext with { AggregateLabels = aggregateReferences[i].Select(target => WorksheetSyntax.Label(parsed[target], sourceLines[target], target, cancellationToken)).ToArray() };
                    var budget = new ExecutionBudget(sheetBudget);
                    var evaluated = ExpressionEvaluation.Evaluate(expression, name => Read(references[i][name]), aggregateValues, cancellationToken,
                        (name, args, callContext) => functions.BlockedNames.Contains(name) ? throw new FormatException($"Invalid function definition: {name}") :
                            functions.Library.Invoke(name, args, budget, cancellationToken, context: callContext, contextReads: reads), budget, functions.Library.Describe, lineContext, reads);
                    contextDependencies[i] = reads.Dependencies;
                    var holidayDeclaration = parsed[i].Assignment?.Equals("holidays", StringComparison.OrdinalIgnoreCase) == true;
                    if (holidayDeclaration && evaluated.Value.Kind == SheetValueKind.List && evaluated.Value.List.Values.Count == 0) evaluated = (new SheetValue(HolidaySet.Empty), evaluated.Steps);
                    if (holidayDeclaration && evaluated.Value.Kind != SheetValueKind.HolidayList) throw new FormatException("holidays requires a date list");
                    var (shown, shownStep) = DisplayConversion(expression, evaluated.Value, lineContext, reads, budget, cancellationToken);
                    contextDependencies[i] = reads.Dependencies;
                    var steps = shownStep is null ? evaluated.Steps : [.. evaluated.Steps, shownStep];
                    results[i] = new(i, evaluated.Value, null) { IsDeclaration = holidayDeclaration, IsAggregate = ExpressionEvaluation.SheetAggregate(expression) is not null, Dependencies = Array.AsReadOnly(dependencies[i]), Explanation = Array.AsReadOnly(steps), Shown = shown };
                    evaluatedCount++;
                    }
                }
                catch (DiceUnrolledException e) { contextDependencies[i] = reads.Dependencies; results[i] = new(i, null, null) { Pending = e.Preview, Explanation = Array.AsReadOnly(e.Steps), Dependencies = Array.AsReadOnly(dependencies[i]) }; }
                catch (Exception e) when (e is FormatException or ArithmeticException) { contextDependencies[i] = reads.Dependencies; results[i] = new(i, null, e.Message) { Dependencies = Array.AsReadOnly(dependencies[i]) }; }
                if (reads.UuidRequestCount > 0)
                {
                    foreach(var request in reads.UuidRequests)uuidRequests.Add(request);
                    if(uuidRequests.Count>StableUuidContext.MaxBindings)throw new SheetComputationLimitException();
                }
                uuidPending[i] = reads.UuidRequestCount>0 || dependencies[i].Any(d=>uuidPending[d]);
                if (reads.CurrencyRequestCount > 0) currencyRequests[i] = reads.CurrencyRequests.ToArray();
            }
            foreach (var consumer in consumers[i]) if (--remaining[consumer] == 0) queue.Enqueue(consumer);
        }
        for (var i = 0; i < parsed.Length; i++)
            if (!completed[i]) results[i] = new(i, null, "Circular dependency") { Dependencies = Array.AsReadOnly(dependencies[i]) };
        cancellationToken.ThrowIfCancellationRequested();
        var usesCurrentDate = contextDependencies.Any(value => value.HasFlag(ContextDependency.Date));
        var usesCurrentInstant = contextDependencies.Any(value => value.HasFlag(ContextDependency.Instant));
        var usesLocalTimeZone = contextDependencies.Any(value => value.HasFlag(ContextDependency.LocalZone));
        var requiresSecondRefresh = contextDependencies.Any(value => value.HasFlag(ContextDependency.SecondTick));
        var requestedRates = currencyRequests.SelectMany(value=>value).Distinct().Take(CurrencyRateBook.MaxHistoricalSnapshots+2).ToArray();
        if (requestedRates.Count(value=>value is not null) > CurrencyRateBook.MaxHistoricalSnapshots)
            throw new ArgumentException("Currency rate date limit exceeded (64 historical dates)");
        cancellationToken.ThrowIfCancellationRequested();
        if (cache is not null)
        {
            cache.Sources = tables.Keys; cache.Scanned = scanned; cache.Parsed = syntax; cache.Names = names;
            cache.Results = results; cache.References = references; cache.Statistics = new(parsedCount, evaluatedCount, reusedCount);
            cache.AggregateReferences = aggregateReferences;
            cache.FunctionKey = functionKey; cache.Uuids = context.Uuids; cache.UuidPending = uuidPending;
            cache.Today = context.Today;
            cache.Now = context.Now;
            cache.ZoneVersion = contextDependencies.Any(value => value.HasFlag(ContextDependency.ZoneRules)) ? context.Zones.VersionId : null;
            cache.ContextDependencies = contextDependencies;
            cache.LocalZoneVersion = usesLocalTimeZone ? context.LocalZone?.Version : null;
            cache.WorkdayRegion = context.WorkdayRegion; cache.CustomHolidays = context.CustomHolidays;
            cache.PayrollRegion = context.PayrollRegion; cache.DisplayCurrency = context.DisplayCurrency;
            cache.CurrencyRateKey = (context.CurrencyRates ?? CurrencyRateBook.Empty).Key; cache.CurrencyDate = context.CurrencyDate; cache.CurrencyRequests = currencyRequests;
        }
        var published = uuidPending.Any(p=>p) ? results.Select((row,i)=>uuidPending[i]?row with { Value=null, Error="UUID generation pending", Explanation=[] }:row).ToArray() : results;
        return new(Array.AsReadOnly(published), functions) { UsesCurrentDate = usesCurrentDate, UsesCurrentInstant = usesCurrentInstant,
            UsesLocalTimeZone = usesLocalTimeZone, RequiresSecondRefresh = requiresSecondRefresh, UuidRequests = Array.AsReadOnly(uuidRequests.ToArray()),
            UsesCurrencyRates = contextDependencies.Any(value => value.HasFlag(ContextDependency.CurrencyRates)),
            HasMoney = results.Any(value => value.Value?.Kind is SheetValueKind.Money or SheetValueKind.UsagePrice || value.Value is { Kind: SheetValueKind.List } list && list.List.HasMoney),
            TotalMembers = totalMembers.AsReadOnly(),
            CurrencyRequests = Array.AsReadOnly(requestedRates.OrderBy(value=>value).Select(value=>new CurrencyRateRequest(value)).ToArray()) };
    }

    /// <summary>Shows a plain monetary result in the default currency. A line that names its target currency keeps it,
    /// and a missing or incompatible rate leaves the original amount.</summary>
    private static (SheetValue? Value, CalculationStep? Step) DisplayConversion(Expression expression, SheetValue value, EvaluationContext context, ContextReads reads, ExecutionBudget budget, CancellationToken cancellationToken)
    {
        if (value.Kind != SheetValueKind.Money) return default;
        reads.Dependencies |= ContextDependency.DisplayCurrency;
        if (context.DisplayCurrency is not { } target || value.Money.Currency == target ||
            ExpressionEvaluation.Walk(expression).Any(node => node is CurrencyConvertExpression conversion && conversion.Currency == value.Money.Currency)) return default;
        try
        {
            var converter = new MoneyArithmetic(new ExactArithmetic(budget, cancellationToken), context with { CurrencyDate = null }, reads);
            var shown = new SheetValue(converter.Convert(value.Money, target));
            return (shown, new("show in default currency", [value.Display], shown.Display, "Shown in default currency; references keep " + value.Money.Currency + "; " + converter.Provenance));
        }
        catch (ArithmeticException) { return default; }
    }
}
