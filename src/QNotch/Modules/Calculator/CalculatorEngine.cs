using System.Globalization;
using Calc.Core;

namespace QNotch.Modules.Calculator;

/// <summary>One answered Search line. Answer is display text, Copy keeps the exact reusable form.</summary>
internal sealed record CalculatorLine(string? Answer, string? Copy);

/// <summary>
/// Answers for Search. Created on the thread pool on first use, so a QNotch that never calculates never loads the engine. Evaluation is
/// safe from any thread; the session serializes its own work. The sheet view has its own session.
/// </summary>
internal sealed class CalculatorEngine
{
    readonly SheetEvaluationSession _quick = new();
    readonly LocalZoneSnapshot? _zone;
    readonly string _region;
    readonly ResultFormat _format = new(null, NumberStyle.FromCulture(CultureInfo.CurrentCulture));
    readonly CalculatorRates _rates;

    public CalculatorEngine(string dataDir, bool readOnly)
    {
        _rates = new CalculatorRates(dataDir, readOnly);
        try { _zone = LocalZoneSnapshot.FromTimeZoneInfo(TimeZoneInfo.Local); }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or InvalidTimeZoneException)
        { QNotch.Core.Log.Warn("Calculator: local time zone unavailable", ex); }
        _region = Region();
        _rates.Load();
        _quick.Evaluate("1 + 1", default, Context()); // pays the first-use cost here, off the UI thread
    }

    public void ReloadRates() => _rates.Load();

    static string Region()
    {
        try { return new RegionInfo(CultureInfo.CurrentCulture.Name).TwoLetterISORegionName; }
        catch (ArgumentException) { return ""; }
    }

    EvaluationContext Context()
    {
        var now = TimeProvider.System.GetUtcNow();
        var instant = new DateTimeOffset(now.UtcTicks - now.UtcTicks % TimeSpan.TicksPerSecond, TimeSpan.Zero);
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, TimeZoneInfo.Local).DateTime);
        return new EvaluationContext(today, instant, LocalZone: _zone, WorkdayRegion: _region, CurrencyRates: _rates.Book);
    }

    /// <summary>One expression for Search. Null unless it is a real calculation whose answer says something the query did not.</summary>
    public CalculatorLine? Quick(string expression, object? functions, CancellationToken token)
    {
        var library = functions as FunctionLibrary ?? FunctionLibrary.Empty;
        var results = _quick.EvaluateWithFunctions(expression, library, [], token, Context()).Results;
        if (results.Count != 1 || results[0] is not { Error: null, IsDeclaration: false, Value: { } value } result) return null;
        // Uuid and dice lines have no stable answer outside a sheet, and pictures do not fit a result row.
        if (value.Kind is SheetValueKind.Plot or SheetValueKind.Chart or SheetValueKind.Table || result.Pending is not null) return null;
        var line = Line(result, value);
        return string.Equals(line.Answer, expression.Trim(), StringComparison.OrdinalIgnoreCase) ? null : line;
    }

    CalculatorLine Line(LineResult result, SheetValue value)
    {
        var (answer, copy) = SheetDisplay.Present(result, value, _format);
        return new(answer, copy);
    }
}
