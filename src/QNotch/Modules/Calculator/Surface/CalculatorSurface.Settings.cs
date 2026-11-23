using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Calc.Core;
using Calc.Documents;
using Calc.Providers;
using QNotch.Theme;

namespace Calc.Windows;

/// <summary>
/// The Calculator page in QNotch's Settings. It is built from the current state and rebuilt when that state changes, so it holds no copy of
/// any setting; every control commits through the same preference, sync and currency paths as the sheet.
/// </summary>
public partial class CalculatorSurface
{
    private PreferencesDocument preferences = new(1, null);
    private ContentControl? settingsHost;
    private bool settingsRefreshQueued;

    private string WorkdayRegion => preferences.WorkdayRegion ?? SystemWorkdayRegion();
    private static string SystemWorkdayRegion()
    {
        try { return new RegionInfo(CultureInfo.CurrentCulture.Name).TwoLetterISORegionName; }
        catch (ArgumentException) { return ""; }
    }

    /// <summary>The page for the Settings window. It rebuilds itself while it is showing.</summary>
    internal FrameworkElement CreateSettingsPage()
    {
        var page = new ContentControl { Focusable = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        page.Loaded += (_, _) => { settingsHost = page; page.Content = BuildSettings(); };
        page.Unloaded += (_, _) => { if (ReferenceEquals(settingsHost, page)) settingsHost = null; };
        page.Content = BuildSettings();
        return page;
    }

    /// <summary>Shows a changed state on the page, once, after the current input settles. An open drop-down is never pulled away.</summary>
    private void RefreshSettings(string? section = null)
    {
        if (settingsHost is null || settingsRefreshQueued) return;
        settingsRefreshQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            settingsRefreshQueued = false;
            if (settingsHost is not { } host) return;
            var open = Descendants(host).OfType<ComboBox>().FirstOrDefault(box => box.IsDropDownOpen);
            if (open is not null) { open.DropDownClosed += Deferred; return; }
            var focused = Keyboard.FocusedElement is FrameworkElement element && host.IsAncestorOf(element) ? AutomationProperties.GetAutomationId(element) : null;
            host.Content = BuildSettings();
            if (!string.IsNullOrEmpty(focused))
            {
                host.UpdateLayout();
                Descendants(host).OfType<UIElement>().FirstOrDefault(item => AutomationProperties.GetAutomationId(item) == focused)?.Focus();
            }
            void Deferred(object? sender, EventArgs e) { open.DropDownClosed -= Deferred; RefreshSettings(); }
        });
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }

    private FrameworkElement BuildSettings()
    {
        var page = UiKit.Page(T["calculatorSettings"]);
        page.Children.Add(UiKit.SettingsIntro(T["calculatorSettingsIntro"]));
        page.Children.Add(GeneralGroup());
        page.Children.Add(DisplayGroup());
        page.Children.Add(CurrencyGroup());
        page.Children.Add(SyncGroup());
        page.Children.Add(AboutGroup());
        return page;
    }

    private static StackPanel Group(string title, IEnumerable<FrameworkElement?> rows) => UiKit.SettingsGroup(rows.OfType<FrameworkElement>(), title);
    private static Grid Row(string label, string? hint, FrameworkElement control) => UiKit.SettingsRow(label, hint, control);

    private FrameworkElement GeneralGroup()
    {
        var languages = UiText.Languages.Select(language => (language.Name, (string?)language.Code)).Prepend((T["systemLanguage"], null));
        var system = SystemWorkdayRegion();
        var regions = new (string, string?)[] { (T.Format("systemRegion", system.Length == 0 ? T["unavailable"] : system), null),
            (T["germany"], "DE"), (T["us"], "US"), (T["weekdays"], "WEEKDAYS") };
        return Group(T["general"], [
            Row(T["language"], null, Choice("calculator-settings-language", languages, preferences.Language, code => CommitPreference(saved => saved with { Language = code }))),
            Row(T["workdayCalendar"], null, Choice("calculator-settings-workday", regions, preferences.WorkdayRegion, SelectWorkdayRegion)),
        ]);
    }

    private FrameworkElement DisplayGroup()
    {
        ComboBox Display<TChoice>(string id, IEnumerable<(string, TChoice)> choices, TChoice current, Func<PreferencesDocument, TChoice, PreferencesDocument> choose) =>
            Choice(id, choices, current, value => CommitPreference(saved => choose(saved, value)), value => ApplyDisplay(choose(preferences, value)), () => ApplyDisplay(preferences));
        return Group(T["appearance"], [
            Row(T["textSize"], null, Display("calculator-settings-text-size", TextSizeChoices(), preferences.FontSize ?? DefaultFontSize, WithFontSize)),
            Row(T["decimalPlaces"], null, Display("calculator-settings-decimal-places", DecimalPlaceChoices(), preferences.DecimalPlaces, (saved, places) => saved with { DecimalPlaces = places })),
            Row(T["numberFormat"], null, Display("calculator-settings-number-format", NumberStyleChoices(), preferences.NumberStyle, (saved, id) => saved with { NumberStyle = id })),
        ]);
    }

    private FrameworkElement CurrencyGroup()
    {
        var codes = new[] { preferences.DefaultCurrency, SystemCurrency() }.OfType<string>().Concat(DefaultCurrencyChoices).Distinct();
        var currencies = codes.Select(code => (code + "  " + CurrencyCatalog.ByCode(code).Name, (string?)code)).Prepend((T["none"], null));
        var idle = currencyDownload is null;
        var status = CurrencyStatus() + (currencyWarning is { } warning ? "\n" + warning : "");
        var latest = idle ? ActionButton("calculator-settings-download-latest", T["download"], async () => await StartCurrencyDownload([null], false, false), tip: T["downloadLatestTip"])
            : ActionButton("calculator-settings-cancel-download", T["cancelDownload"], () => currencyDownload?.Cancel());
        var missing = MissingCurrencyDates();
        var route = MonthlyCurrencyRoute;
        var sourceUrl = route ? InforEuroRateClient.Source : EcbRateClient.Source;
        return Group(T["currencyRates"],
        [
            Row(T["defaultCurrency"], null, Choice("calculator-settings-default-currency", currencies, preferences.DefaultCurrency, SelectDefaultCurrency)),
            Row(T["downloadLatest"], status, latest),
            Row(T["downloadMonthly"], null, ActionButton("calculator-settings-download-monthly", T["download"], async () => await StartCurrencyDownload([null], false, true), idle, T["downloadMonthlyTip"])),
            missing.Length == 0 ? null : Row(T.Format("downloadHistory", missing.Length), null, ActionButton("calculator-settings-download-history", T["download"],
                async () => await StartCurrencyDownload(missing, false, route), idle,
                T.Format("downloadHistoryTip", string.Join(", ", missing.Select(date => date!.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)))))),
            Row(T["autoRates"], route ? T["autoRatesTipMonthly"] : T["autoRatesTip"], Toggle("calculator-settings-auto-rates", preferences.AutoCurrencyRates, SetAutoCurrencyRates)),
            Row(route ? T["rateSourceMonthly"] : T["rateSource"], route ? InforEuroRateClient.Attribution : sourceUrl, ActionButton("calculator-settings-rate-source", T["openLink"], () => Open(sourceUrl))),
        ]);
    }

    private FrameworkElement SyncGroup()
    {
        if (syncSession?.Folder is not { } folder)
            return Group(T["syncFolder"], [Row(T["syncFolderTip"], null, ActionButton("calculator-settings-sync-choose", T["chooseFolder"], ChooseSyncFolder))]);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(ActionButton("calculator-settings-sync-change", T["changeFolder"], ChooseSyncFolder));
        actions.Children.Add(ActionButton("calculator-settings-sync-stop", T["stopSyncing"], () => SetSyncFolder(null), tip: T["stopSyncingTip"]));
        return Group(T["syncFolder"], [Row(folder, null, actions)]);
    }

    private FrameworkElement AboutGroup() => Group(T["about"], [
        Row(T["help"], "F1", ActionButton("calculator-settings-help", T["openLink"], ShowHelp)),
        Row(T["thirdPartyNotices"], T["thirdPartyNoticesTip"], ActionButton("calculator-settings-notices", T["openLink"], ShowNotices)),
    ]);

    private static Button ActionButton(string id, string text, Action click, bool enabled = true, string? tip = null)
    {
        var button = new Button { Content = text, IsEnabled = enabled, ToolTip = tip, MinWidth = 84, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(6, 0, 0, 0) };
        AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => click();
        return button;
    }

    private static CheckBox Toggle(string id, bool value, Action<bool> set)
    {
        var toggle = UiKit.Toggle(value, set);
        AutomationProperties.SetAutomationId(toggle, id);
        return toggle;
    }

    /// <summary>A drop-down of choices. Highlighting a choice can preview it; closing without choosing ends the preview.</summary>
    private static ComboBox Choice<TChoice>(string id, IEnumerable<(string Text, TChoice Value)> choices, TChoice selected, Action<TChoice> choose,
        Action<TChoice>? preview = null, Action? endPreview = null)
    {
        var box = new ComboBox { MinWidth = 190, MaxWidth = 260, MaxDropDownHeight = 300, FontSize = 12 };
        AutomationProperties.SetAutomationId(box, id);
        foreach (var (text, value) in choices)
        {
            var item = new PreviewComboBoxItem { Content = text, Tag = value };
            if (preview is not null) item.Highlighted = () => preview(value);
            box.Items.Add(item);
            if (EqualityComparer<TChoice>.Default.Equals(value, selected)) box.SelectedItem = item;
        }
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem { Tag: var value }) choose((TChoice)value!); };
        if (endPreview is not null) box.DropDownClosed += (_, _) => endPreview();
        return box;
    }

    private void ShowHelp() => OpenWritten(CalculatorAssets.WriteHelp);
    private void ShowNotices() => OpenWritten(CalculatorAssets.WriteNotices);

    private void OpenWritten(Func<string, string> write)
    {
        try { Open(write(dataDirectory)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { SaveState.Text = T["helpUnavailable"]; SaveState.ToolTip = error.Message; }
    }

    private void Open(string target)
    {
        if (host.Demo) return; // Snapshot runs never launch a browser or viewer.
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception error) when (error is Win32Exception or FileNotFoundException or InvalidOperationException) { SaveState.Text = T["helpUnavailable"]; }
    }

    /// <summary>Currencies the ECB reference rates cover, offered as defaults beside the region's own currency.</summary>
    internal static readonly string[] DefaultCurrencyChoices = ["AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "ISK",
        "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"];
    private static string? SystemCurrency()
    {
        try { var code = new RegionInfo(CultureInfo.CurrentCulture.Name).ISOCurrencySymbol; return CurrencyCatalog.TryCode(code, out _) ? code : null; }
        catch (ArgumentException) { return null; }
    }
    private void SelectDefaultCurrency(string? code)
    {
        var saved = TryStorageAction(() =>
        {
            preferences = store.UpdatePreferences(saved => saved with { DefaultCurrency = code });
            if (compositionActive) { evaluationDeferred = true; return; }
            if (!dirty && !unavailable) SaveState.Text = "";
            pending = Evaluate();
        }, T["settingsUnavailable"]);
        if (!saved) RefreshSettings();
    }
    private void SelectWorkdayRegion(string? region)
    {
        var saved = TryStorageAction(() =>
        {
            preferences = store.SetWorkdayRegion(region);
            if (compositionActive) { evaluationDeferred = true; return; }
            if (!dirty && !unavailable) SaveState.Text = "";
            pending = Evaluate();
        }, T["settingsUnavailable"]);
        if (!saved) RefreshSettings();
    }
}

/// <summary>Combo box item reporting highlight changes; WPF highlights for both keyboard navigation and pointer hover.</summary>
internal sealed class PreviewComboBoxItem : ComboBoxItem
{
    internal Action? Highlighted { get; set; }
    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.Property == IsHighlightedProperty && e.NewValue is true) Highlighted?.Invoke();
    }
}
