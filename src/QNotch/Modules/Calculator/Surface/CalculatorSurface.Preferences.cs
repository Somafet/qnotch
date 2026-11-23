using System.Globalization;
using System.Windows.Automation;
using System.Windows.Markup;
using Calc.Core;
using Calc.Documents;

namespace Calc.Windows;

/// <summary>Display and language preferences. Each applies in place: source, dirty state, undo and caret stay as they are.</summary>
public partial class CalculatorSurface
{
    internal const int DefaultFontSize = 15; // Calc's 20 is sized for a full window; the panel is compact.
    internal static readonly int[] FontSizes = [12, 13, 14, 15, 16, 18, 20, 22, 24, 28];
    internal static readonly int?[] DecimalChoices = [null, 0, 1, 2, 3, 4, 6, 8, 10];
    private static UiText T => UiText.Current;
    private ResultFormat resultFormat = ResultFormat.Default;
    /// <summary>Presentation of one result under the current display preferences; values and copies stay canonical.</summary>
    private string Shown(LineResult answer) => answer.Value is { } value ? QNotch.Modules.Calculator.SheetDisplay.Present(answer, value, resultFormat).Answer : ResultFormatter.Format(answer, resultFormat);
    private static ResultFormat FormatFor(PreferencesDocument value) =>
        new(value.DecimalPlaces, NumberStyle.FromId(value.NumberStyle, CultureInfo.CurrentCulture));

    private void ApplyPreferences()
    {
        ApplyLanguage(); ApplyDisplay(preferences);
    }
    /// <summary>Applies a committed or previewed text size and result format without evaluating again.</summary>
    private void ApplyDisplay(PreferencesDocument shown)
    {
        var size = shown.FontSize ?? DefaultFontSize; var format = FormatFor(shown);
        var resized = Editor.FontSize != size;
        Placeholder.FontSize = size;
        if (!resized && format == resultFormat) return;
        foreach (var editor in editors.Values.Concat(closedEditors.Values).Append(Editor).Distinct()) editor.FontSize = size;
        resultFormat = format;
        if (!ready) return;
        if (resized) { Editor.ShowWorksheet([]); Editor.ShowWorksheet(answers); }
        ClearResults(); Editor.UpdateLayout(); DrawResults();
    }
    private void ApplyLanguage()
    {
        var previous = UiText.Current;
        UiText.Current = UiText.For(UiText.Resolve(preferences.Language, CultureInfo.CurrentUICulture));
        // A status shown before the switch, such as "Link copied", follows the new language.
        if (previous.Retranslate(SaveState.Text, UiText.Current) is { } status) SaveState.Text = status;
        Language = XmlLanguage.GetLanguage(T.Culture.IetfLanguageTag); // Selects CJK glyph variants for the interface.
        MoreButton.ToolTip = T["sheets"]; AutomationProperties.SetName(MoreButton, T["sheets"]);
        Share.ToolTip = T["share"]; AutomationProperties.SetName(Share, T["share"]);
        Tabs.Retitle();
        foreach (var editor in editors.Values.Concat(closedEditors.Values).Append(Editor).Distinct()) { AutomationProperties.SetName(editor, T["sheetExpressions"]); AutomationProperties.SetName(editor.TextArea, T["sheetExpressions"]); }
        Placeholder.Text = T["placeholder"];
        NoticeUndo.Content = T["undo"];
        if (tabList.Closed.Count > 0 && NoticeBar.Visibility == System.Windows.Visibility.Visible && NoticeUndo.Visibility == System.Windows.Visibility.Visible) ShowClosedNotice();
        UpdateCurrencyStatus();
        RefreshSettings();
        if (ready) { ClearResults(); DrawResults(); }
    }
    private static IEnumerable<(string, int)> TextSizeChoices() => FontSizes.Select(size => (size.ToString(CultureInfo.InvariantCulture), size));
    private static PreferencesDocument WithFontSize(PreferencesDocument saved, int size) => saved with { FontSize = size == DefaultFontSize ? null : size };
    private static IEnumerable<(string, int?)> DecimalPlaceChoices() => DecimalChoices.Select(places => (places?.ToString(CultureInfo.InvariantCulture) ?? T["automatic"], places));
    private static IEnumerable<(string, string?)> NumberStyleChoices() => NumberStyle.PresetIds.Select(id =>
    {
        var example = NumberStyle.FromId(id, CultureInfo.CurrentCulture).Example;
        return (id == "system" ? T.Format("systemFormat", example) : example, id == "plain" ? null : id);
    });
    private bool CommitPreference(Func<PreferencesDocument, PreferencesDocument> change)
    {
        var language = preferences.Language;
        var saved = TryStorageAction(() => preferences = store.UpdatePreferences(change), T["settingsUnavailable"]);
        ApplyDisplay(preferences);
        if (preferences.Language != language) ApplyLanguage();
        if (!saved) RefreshSettings();
        return saved;
    }
}
