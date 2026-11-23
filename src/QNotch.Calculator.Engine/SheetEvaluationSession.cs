namespace Calc.Core;

public sealed record EvaluationStatistics(int ParsedLines, int EvaluatedLines, int ReusedResults);
public sealed record SheetEvaluation(IReadOnlyList<LineResult> Results, FunctionUpdate Functions)
{
    public IReadOnlyList<UuidRequest> UuidRequests { get; init; } = [];
    public bool UsesCurrentDate { get; init; }
    public bool UsesCurrentInstant { get; init; }
    public bool UsesLocalTimeZone { get; init; }
    public bool RequiresSecondRefresh { get; init; }
    public bool UsesCurrencyRates { get; init; }
    public bool HasMoney { get; init; }
    public IReadOnlyList<CurrencyRateRequest> CurrencyRequests { get; init; } = [];
    /// <summary>Lines an untagged sheet-wide aggregate would read, in source order (block boundaries ignored).</summary>
    public IReadOnlyList<int> TotalMembers { get; init; } = [];
}

/// <summary>One current-sheet snapshot. Cancellation cannot commit a partial cache.</summary>
public sealed class SheetEvaluationSession
{
    private readonly object gate = new();
    private readonly EvaluationCache cache = new();
    public EvaluationStatistics LastStatistics { get; private set; } = new(0, 0, 0);
    public IReadOnlyList<LineResult> Evaluate(string source, CancellationToken cancellationToken = default, EvaluationContext? context = null)
        => EvaluateWithFunctions(source, FunctionLibrary.Empty, [], cancellationToken, context).Results;

    public SheetEvaluation EvaluateWithFunctions(string source, FunctionLibrary library, IReadOnlyList<FunctionReceipt> receipts, CancellationToken cancellationToken = default, EvaluationContext? context = null)
    {
        lock (gate)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = SheetEvaluator.EvaluateFunctions(source, library, receipts, cancellationToken, cache, context);
            LastStatistics = cache.Statistics;
            return result;
        }
    }
}

internal sealed class EvaluationCache
{
    internal string[] Sources = [];
    internal ParsedLine[] Scanned = [];
    internal ParsedLine[] Parsed = [];
    internal HashSet<string> Names = new(StringComparer.OrdinalIgnoreCase);
    internal LineResult[] Results = [];
    internal Dictionary<string, int>[] References = [];
    internal int[][] AggregateReferences = [];
    internal EvaluationStatistics Statistics = new(0, 0, 0);
    internal StableUuidContext? Uuids;
    internal bool[] UuidPending = [];
    internal string FunctionKey = "";
    internal DateOnly? Today;
    internal DateTimeOffset? Now;
    internal string? ZoneVersion;
    internal string? LocalZoneVersion;
    internal string? WorkdayRegion;
    internal string? PayrollRegion;
    internal string? DisplayCurrency;
    internal HolidaySet? CustomHolidays;
    internal string CurrencyRateKey = "";
    internal DateOnly? CurrencyDate;
    internal DateOnly?[][] CurrencyRequests = [];
    internal ContextDependency[] ContextDependencies = [];
}
