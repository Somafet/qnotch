namespace QNotch.Modules.Calculator;

/// <summary>
/// Answers calculations in the Search tab. Find runs on the UI thread on every keystroke, so it only reads finished answers: a new
/// expression is calculated on the thread pool, and the Search tab is asked to look again when the answer is ready.
/// </summary>
internal sealed class CalculatorSearch(ModuleContext ctx, CalculatorModule module)
{
    const int MaxQuery = 160, MaxRemembered = 32;
    readonly Dictionary<string, CalculatorLine?> _answers = new(StringComparer.Ordinal);
    readonly Queue<string> _order = new();
    CancellationTokenSource? _pending;
    string? _latest;

    public IEnumerable<SearchHit> Find(string query)
    {
        if (!LooksLikeCalculation(query))
        {
            Cancel();
            return [];
        }
        if (_answers.TryGetValue(query, out var known))
        {
            if (_latest != query) Cancel();
            return known is { Answer: { } answer } ? [Hit(query, answer, known.Copy ?? answer)] : [];
        }
        if (_latest != query) Calculate(query);
        return [];
    }

    /// <summary>Answers can depend on today's date and the current rates.</summary>
    public void Forget()
    {
        Cancel();
        _answers.Clear();
        _order.Clear();
    }

    void Cancel()
    {
        _pending?.Cancel();
        _pending = null;
        _latest = null;
    }

    void Calculate(string query)
    {
        Cancel();
        var cancel = _pending = new CancellationTokenSource();
        _latest = query;
        var token = cancel.Token;
        var functions = module.Functions; // Saved functions, only when the workspace is already open.
        Task.Run(async () =>
        {
            var engine = await module.GetEngine().ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(token);
            limit.CancelAfter(TimeSpan.FromSeconds(2)); // off the UI thread: a first use of a code path can be slow
            return engine.Quick(query, functions, limit.Token);
        }, token).ContinueWith(done =>
        {
            if (cancel.IsCancellationRequested || _latest != query) return;
            _pending = null;
            _latest = null;
            if (done.IsCanceled) return; // ran out of time: not an answer to remember
            Remember(query, done.IsCompletedSuccessfully ? done.Result : null);
            ctx.Search.Invalidate();
        }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Remember(string query, CalculatorLine? line)
    {
        if (_answers.TryAdd(query, line)) _order.Enqueue(query);
        while (_order.Count > MaxRemembered) _answers.Remove(_order.Dequeue());
    }

    SearchHit Hit(string query, string answer, string copy) => new(answer, query, () =>
    {
        try { System.Windows.Clipboard.SetText(copy); }
        catch (System.Runtime.InteropServices.COMException ex) { QNotch.Core.Log.Warn("Calculator: clipboard busy", ex); }
        ctx.Shell.ClosePanel();
    });

    static bool StartsLikeCalculation(string query)
    {
        var first = query[0];
        if (char.IsAsciiDigit(first) || first is '(' or '-' or '+' or '.' or '$' or '€' or '£' or '¥' or '√') return true;
        var i = 0;
        while (i < query.Length && char.IsAsciiLetter(query[i])) i++;
        return i > 0 && i < query.Length && query[i] == '(';
    }

    /// <summary>
    /// A cheap check that keeps ordinary searches from loading the engine or taking the first result. The query must start like a
    /// calculation (a number, sign, bracket, currency symbol or function call) and hold an operator, a conversion or a call.
    /// </summary>
    internal static bool LooksLikeCalculation(string query)
    {
        if (query.Length is < 2 or > MaxQuery || !query.Any(char.IsAsciiDigit)) return false;
        if (query.Contains('\\') || query.Contains("://", StringComparison.Ordinal) || query.Contains('@')) return false;
        if (!StartsLikeCalculation(query)) return false;
        if (query.IndexOfAny(['+', '*', '/', '^', '%', '×', '÷', '-']) >= 0) return true;
        if (query.Contains(" in ", StringComparison.OrdinalIgnoreCase) || query.Contains(" to ", StringComparison.OrdinalIgnoreCase)
            || query.Contains(" as ", StringComparison.OrdinalIgnoreCase)) return true;
        for (var i = 1; i < query.Length; i++)
            if (query[i] == '(' && char.IsLetter(query[i - 1])) return true;
        return false;
    }
}
