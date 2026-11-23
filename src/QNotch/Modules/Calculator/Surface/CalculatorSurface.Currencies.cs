using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using Calc.Core;
using Calc.Providers;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private CurrencyRateBook currencyRates = CurrencyRateBook.Empty;
    private CurrencyRateCache? currencyCache;
    private Task<CurrencyCacheLoad>? currencyCacheLoad;
    private bool currencyCacheLoaded;
    private bool usesCurrencyRates;
    private IReadOnlyList<CurrencyRateRequest> currencyRequests = [];
    private DispatcherTimer? currencyTimer;
    private CancellationTokenSource? currencyDownload;
    private bool currencyDownloadAutomatic;
    private Task currencyDownloadTask = Task.CompletedTask;
    private DateTimeOffset? currencyRetryNotBefore;
    private string? currencyWarning;
    private EcbRateConnection? currencyHttpClient;
    private ContextMenu? currencyMenu;
    private static DateTimeOffset CurrencyNow => TimeProvider.System.GetLocalNow();

    private async Task EnsureCurrencyCache(CancellationToken token)
    {
        if (currencyCacheLoaded) return;
        currencyCache ??= new CurrencyRateCache(dataDirectory);
        currencyCacheLoad ??= Task.Run(()=>currencyCache.Load());
        var loaded = await currencyCacheLoad.WaitAsync(token);
        if (currencyCacheLoaded) return;
        currencyRates = loaded.Book; currencyWarning = loaded.Warning; currencyCacheLoaded = true;
    }
    private void AdoptCurrencyEvaluation(SheetEvaluation evaluated)
    {
        usesCurrencyRates = evaluated.UsesCurrencyRates; currencyRequests = evaluated.CurrencyRequests;
        UpdateCurrencyStatus(); RefreshCurrencySchedule();
    }
    private bool MonthlyCurrencyRoute => currencyRates.Latest?.IsMonthly == true;
    private static string CurrencyLabel(CurrencyRateSnapshot? snapshot) => snapshot?.IsMonthly == true ? "EU monthly" : "ECB";
    private string CurrencyStatus()
    {
        if (currencyDownload is not null) return T["downloadingRates"];
        if (currencyWarning?.Contains("cache save failed",StringComparison.Ordinal)==true) return currencyRates.Latest?.IsMonthly == true ? T["euNotSaved"] : T["ecbNotSaved"];
        if (usesCurrencyRates && currencyRequests.Count > 0)
        {
            var requested = currencyRequests.Select(request=> request.Date is { } date ? currencyRates.Historical.GetValueOrDefault(date) : currencyRates.Latest).ToArray();
            if (requested.Any(snapshot=>snapshot is null)) return currencyRequests.All(request=>request.Date is not null) ? T["historyUnavailable"] : T["ratesUnavailable"];
            if (currencyRequests.All(request=>request.Date is not null))
            {
                var dates = requested.Select(snapshot=>snapshot!.AsOf).Distinct().ToArray();
                var monthly = requested[0]?.IsMonthly == true;
                if (dates.Length != 1) return monthly ? T["euMultiple"] : T["ecbMultiple"];
                var day = dates[0].ToString("yyyy-MM-dd",CultureInfo.InvariantCulture);
                return monthly ? T.Format("euDate", day) : T.Format("ecbDate", day);
            }
            if (currencyRequests.Any(request=>request.Date is not null)) return MonthlyCurrencyRoute ? T["euMixed"] : T["ecbMixed"];
        }
        if (currencyRates.Latest is not { } latest) return currencyRates.Historical.Count > 0 ? T["ecbHistoryCached"] : T["ratesUnavailable"];
        var stale = DateOnly.FromDateTime(CurrencyNow.DateTime).DayNumber - latest.AsOf.DayNumber > (latest.IsMonthly ? 35 : 3);
        var asOf = latest.AsOf.ToString(latest.IsMonthly ? "MMM yyyy" : "dd MMM",T.Culture);
        if (latest.IsMonthly) return stale ? T.Format("euStale", asOf) : T.Format("euDate", asOf);
        return stale ? T.Format("ecbStale", asOf) : T.Format("ecbDate", asOf);
    }
    private void UpdateCurrencyStatus()
    {
        CurrencyRatesAction.Visibility = usesCurrencyRates ? Visibility.Visible : Visibility.Collapsed;
        CurrencyRatesAction.Content = CurrencyStatus();
        CurrencyRatesAction.ToolTip = (currencyWarning is { } warning ? warning+"\n" : "") +
            (MonthlyCurrencyRoute ? T["ratesTipMonthly"] : T["ratesTip"]);
        System.Windows.Automation.AutomationProperties.SetName(CurrencyRatesAction,T.Format("currencyRatesNameStatus", CurrencyStatus()));
        RefreshSettings("currencies");
    }
    /// <summary>Dates the visible sheet asks for that the cache lacks and the current source covers.</summary>
    private DateOnly?[] MissingCurrencyDates() => currencyRequests.Where(request=>request.Date is { } date && !currencyRates.Historical.ContainsKey(date) &&
        date >= (MonthlyCurrencyRoute ? InforEuroRateClient.FirstDate : EcbRateClient.FirstDate) && date <= DateOnly.FromDateTime(CurrencyNow.DateTime)).Select(request=>request.Date).Distinct().ToArray();
    private void FillCurrencyMenu(ItemCollection items)
    {
        items.Add(new MenuItem { Header = CurrencyStatus(),IsEnabled = false });
        if (currencyWarning is { } warning) items.Add(new MenuItem { Header = warning,IsEnabled = false });
        var latest = new MenuItem { Header = T["downloadLatest"],IsEnabled = currencyDownload is null,
            ToolTip = T["downloadLatestTip"] };
        latest.Click += async (_,_) => await StartCurrencyDownload([null],false,false); items.Add(latest);
        var monthly = new MenuItem { Header = T["downloadMonthly"],IsEnabled = currencyDownload is null,
            ToolTip = T["downloadMonthlyTip"] };
        monthly.Click += async (_,_) => await StartCurrencyDownload([null],false,true); items.Add(monthly);
        var missing = MissingCurrencyDates();
        if (missing.Length > 0)
        {
            var history = new MenuItem { Header = T.Format("downloadHistory", missing.Length),IsEnabled = currencyDownload is null,
                ToolTip = T.Format("downloadHistoryTip", string.Join(", ",missing.Select(date=>date!.Value.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture)))) };
            var route = MonthlyCurrencyRoute;
            history.Click += async (_,_) => await StartCurrencyDownload(missing,false,route); items.Add(history);
        }
        if (currencyDownload is not null)
        { var cancel = new MenuItem { Header = T["cancelDownload"] }; cancel.Click += (_,_)=>currencyDownload?.Cancel(); items.Add(cancel); }
        var automatic = new MenuItem { Header = T["autoRates"],IsCheckable = true,IsChecked = preferences.AutoCurrencyRates,
            ToolTip = MonthlyCurrencyRoute ? T["autoRatesTipMonthly"] : T["autoRatesTip"] };
        automatic.Click += (_,_) => SetAutoCurrencyRates(automatic.IsChecked); items.Add(automatic);
        var sourceUrl = MonthlyCurrencyRoute ? InforEuroRateClient.Source : EcbRateClient.Source;
        var source = new MenuItem { Header = MonthlyCurrencyRoute ? T["rateSourceMonthly"] : T["rateSource"],
            ToolTip = MonthlyCurrencyRoute ? InforEuroRateClient.Attribution : sourceUrl };
        source.Click += (_,_)=> Open(sourceUrl); items.Add(source);
    }
    private void ShowCurrencyRates(object sender,RoutedEventArgs e)
    {
        if (currencyMenu is not null) currencyMenu.IsOpen = false;
        currencyMenu = HeldMenu(); currencyMenu.PlacementTarget = CurrencyRatesAction; currencyMenu.Placement = PlacementMode.Custom; currencyMenu.CustomPopupPlacementCallback = BelowRightEdge;
        FillCurrencyMenu(currencyMenu.Items); currencyMenu.IsOpen = true;
    }
    private void SetAutoCurrencyRates(bool enabled)
    {
        if (!TryStorageAction(()=>preferences = store.SetAutoCurrencyRates(enabled),T["settingsUnavailable"])) { RefreshSettings(); return; }
        if (!enabled) StopCurrencySchedule(true);
        RefreshCurrencySchedule();
    }
    private void StopCurrencySchedule(bool cancelAutomatic = false,bool cancelAll = false)
    {
        currencyTimer?.Stop();
        if (cancelAll || cancelAutomatic && currencyDownloadAutomatic) currencyDownload?.Cancel();
    }
    private void RefreshCurrencySchedule()
    {
        currencyTimer?.Stop();
        var now = CurrencyNow;
        var due = CurrencyRefreshPolicy.Next(preferences.AutoCurrencyRates,DateVisible,compositionActive,
            usesCurrencyRates && currencyRequests.Any(request=>request.Date is null),currencyDownload is not null,currencyRates.Latest,now,currencyRetryNotBefore);
        if (due is null) return;
        if (currencyTimer is null)
        {
            currencyTimer = new DispatcherTimer(DispatcherPriority.Background);
            currencyTimer.Tick += async (_,_)=> { currencyTimer.Stop(); await StartCurrencyDownload([null],true,MonthlyCurrencyRoute); };
        }
        currencyTimer.Interval = due > now ? due.Value-now : TimeSpan.FromMilliseconds(50);
        currencyTimer.Start();
    }
    private Task StartCurrencyDownload(DateOnly?[] dates,bool automatic,bool monthly = false)
    {
        if (!currencyDownloadTask.IsCompleted) return currencyDownloadTask;
        currencyDownloadTask = DownloadCurrencyRates(dates,automatic,monthly); return currencyDownloadTask;
    }
    private Task<CurrencyRateSnapshot> FetchCurrencyRates(DateOnly? date,bool monthly,CancellationToken token)
    {
        if (host.Demo) throw new IOException("Demo runs never go online");
        currencyHttpClient ??= new EcbRateConnection();
        return monthly ? currencyHttpClient.FetchInforEuroAsync(date,CurrencyNow,token) : currencyHttpClient.FetchAsync(date,CurrencyNow,token);
    }
    private async Task DownloadCurrencyRates(DateOnly?[] dates,bool automatic,bool monthly)
    {
        if (!ready || dates.Length is < 1 or > CurrencyRateBook.MaxHistoricalSnapshots || automatic &&
            (!preferences.AutoCurrencyRates || !DateVisible || compositionActive || !usesCurrencyRates || !currencyRequests.Any(request=>request.Date is null))) return;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        currencyDownload = cancellation; currencyDownloadAutomatic = automatic; currencyRetryNotBefore = CurrencyRefreshPolicy.Failed(CurrencyNow);
        StopCurrencySchedule(); UpdateCurrencyStatus(); var completed = 0; var book = currencyRates;
        try
        {
            await EnsureCurrencyCache(cancellation.Token); book = currencyRates;
            foreach (var date in dates.Distinct())
            {
                var snapshot = await FetchCurrencyRates(date,monthly,cancellation.Token);
                var historical = book.Historical.ToDictionary(pair=>pair.Key,pair=>pair.Value);
                if (date is { } requested)
                {
                    if (!historical.ContainsKey(requested) && historical.Count >= CurrencyRateBook.MaxHistoricalSnapshots)
                        historical.Remove(historical.OrderBy(pair=>pair.Value.RetrievedAt).First().Key);
                    historical[requested] = snapshot;
                }
                book = new(date is null ? snapshot : book.Latest,historical); completed++;
            }
            currencyWarning = null; currencyRetryNotBefore = null;
        }
        catch (OperationCanceledException) { currencyWarning = "Rate download canceled or timed out; cached data retained"; }
        catch (CurrencyRateHttpException error) { currencyWarning = "Rate provider HTTP "+(int)error.Status+"; cached data retained"; currencyRetryNotBefore = CurrencyRefreshPolicy.Failed(CurrencyNow,error.RetryAfter); }
        catch (Exception error) when (error is IOException or InvalidDataException or ArithmeticException or ArgumentException)
        { currencyWarning = "Rates unavailable; cached data retained"; }
        finally
        {
            if (completed > 0)
            {
                currencyRates = book;
                try { await Task.Run(()=>currencyCache!.Save(book)); host.RatesChanged(); }
                catch (Exception error) when (error is IOException or NotSupportedException or System.Text.Json.JsonException)
                { currencyWarning = "Downloaded rates in memory; cache save failed"; }
            }
            currencyDownload = null; currencyDownloadAutomatic = false;
            UpdateCurrencyStatus();
            if (ready && DateVisible && !compositionActive) pending = Evaluate();
            else if (ready && compositionActive && completed > 0) evaluationDeferred = true;
            RefreshCurrencySchedule();
        }
    }
}
