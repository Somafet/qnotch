using Calc.Core;
using Calc.Providers;
using QNotch.Core;

namespace QNotch.Modules.Calculator;

/// <summary>The saved exchange rates, read for Search answers. Downloads belong to the sheet view; this never goes online.</summary>
internal sealed class CalculatorRates(string dataDir, bool readOnly)
{
    readonly CurrencyRateCache _cache = new(dataDir);
    volatile CurrencyRateBook _book = CurrencyRateBook.Empty;

    public CurrencyRateBook Book => _book;

    public void Load()
    {
        if (readOnly) return;
        var loaded = _cache.Load();
        _book = loaded.Book;
        if (loaded.Warning is { } warning) Log.Warn("Calculator rates: " + warning);
    }
}
