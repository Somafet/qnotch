using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Calc.Core;
using Calc.Documents;
using ICSharpCode.AvalonEdit.Document;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private bool historyPending;
    private bool historyFailed;
    private IReadOnlyList<FunctionReceipt>? restoredReceipts;
    private static DateTimeOffset HistoryNow => TimeProvider.System.GetUtcNow();
    private string HistoryState => historyFailed ? T["historyNotSaved"] : "";
    // Undo and redo run mid-update, so they only move the receipts; the next save writes them with the source as one transaction.
    private sealed class ReceiptUndo(CalculatorSurface owner, IReadOnlyList<FunctionReceipt> before, IReadOnlyList<FunctionReceipt> after) : IUndoableOperation
    {
        public void Undo() => owner.AdoptReceipts(before);
        public void Redo() => owner.AdoptReceipts(after);
    }
    private void AdoptReceipts(IReadOnlyList<FunctionReceipt> receipts) { functionReceipts = receipts; restoredReceipts = receipts; }
    private void CaptureHistory(bool force)
    {
        if (force && !historyPending) return;
        try
        {
            if (store.CaptureVersion(document.Id, HistoryNow, force)) historyPending = false;
            historyFailed = false;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException)
        { historyFailed = true; SaveState.Text = HistoryState; SaveState.ToolTip = e.Message; }
    }
    private void ShowHistory(object sender, RoutedEventArgs e)
    {
        if (LoadHistory() is not { } history) return;
        ShowHistoryOverlay(history);
    }
    private VersionHistory? LoadHistory()
    {
        if (unavailable || !Save()) return null;
        VersionHistory? history = null;
        if (!TryStorageAction(() => history = store.LoadVersions(document.Id), T["historyUnavailable"])) return null;
        if (history!.Skipped > 0) SaveState.Text = history.Skipped == 1 ? T["skippedOne"] : T.Format("skippedMany", history.Skipped);
        return history;
    }
    private static string VersionLabel(SheetVersion version) => version.CapturedAt.ToLocalTime().ToString("G", CultureInfo.CurrentCulture);
    /// <summary>Saved versions beside a preview. Restoring takes a second, explicit press.</summary>
    private void ShowHistoryOverlay(VersionHistory history)
    {
        var body = new StackPanel();
        body.Children.Add(OverlayTitle(T["versionHistory"]));
        if (history.Versions.Count == 0)
        {
            var close = new Button { Content = T["close"] };
            close.Click += (_, _) => CloseOverlay();
            body.Children.Add(new TextBlock { Text = T["noVersions"] });
            body.Children.Add(OverlayButtons(close));
            ShowOverlay(body, close, width: 320);
            return;
        }
        var list = new ListBox { ItemsSource = history.Versions.Select(VersionLabel).ToArray(), Width = 176, Height = 214, FontSize = 12,
            BorderThickness = new Thickness(0), Background = Brushes.Transparent, Margin = new Thickness(0, 0, 12, 0) };
        var preview = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 214, FontSize = 12, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            BorderThickness = new Thickness(0), Background = Brushes.Transparent };
        var restore = AccentButton(T["restore"]);
        var cancel = new Button { Content = T["close"] };
        var confirm = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0), Visibility = Visibility.Collapsed };
        confirm.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
        AutomationProperties.SetName(list, T["versions"]);
        AutomationProperties.SetAutomationId(list, "calculator-history-list");
        AutomationProperties.SetName(preview, T["versionPreview"]);
        AutomationProperties.SetAutomationId(preview, "calculator-history-preview");
        AutomationProperties.SetName(restore, T["restoreVersion"]);
        AutomationProperties.SetAutomationId(restore, "calculator-history-restore");
        var armed = -1;
        var shownSheet = document.Id;
        list.SelectionChanged += (_, _) =>
        {
            armed = -1; confirm.Visibility = Visibility.Collapsed;
            restore.IsEnabled = list.SelectedIndex >= 0;
            if (list.SelectedIndex >= 0) preview.Text = history.Versions[list.SelectedIndex].Sheet.Source;
            preview.ScrollToHome();
        };
        restore.Click += (_, _) =>
        {
            if (list.SelectedIndex < 0) return;
            if (document.Id != shownSheet) { CloseOverlay(); return; } // Sync moved to another sheet: this history is not its history.
            var version = history.Versions[list.SelectedIndex];
            if (armed != list.SelectedIndex)
            {
                armed = list.SelectedIndex;
                confirm.Text = T.Format("restorePrompt", VersionLabel(version));
                confirm.Visibility = Visibility.Visible;
                return;
            }
            CloseOverlay();
            RestoreSheetVersion(version);
        };
        cancel.Click += (_, _) => CloseOverlay();
        list.SelectedIndex = 0;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new());
        Grid.SetColumn(preview, 1);
        grid.Children.Add(list); grid.Children.Add(preview);
        body.Children.Add(grid);
        body.Children.Add(confirm);
        body.Children.Add(OverlayButtons(cancel, restore));
        ShowOverlay(body, list, width: 620);
    }
    /// <summary>The store commits first, so a failure leaves the editor as it was. The text then replaces the editor through its undo stack.</summary>
    private bool RestoreSheetVersion(SheetVersion version)
    {
        if (unavailable || !Save()) return false;
        var before = functionReceipts;
        LoadResult? restored = null;
        if (!TryStorageAction(() => restored = store.RestoreVersion(document.Id, version.Hash, HistoryNow), T["restoreFailed"]))
        {
            // A partial journal replay can still roll forward. The next save reasserts what the editor shows.
            restoredReceipts = before; dirty = true;
            return false;
        }
        document = restored!.Document; functionReceipts = restored.FunctionReceipts!;
        uuidSessions[Editor].Restore(document.Source, document.GeneratedUuids, new ReceiptUndo(this, before, functionReceipts));
        Editor.Select(0, 0); Editor.ScrollToHome();
        dirty = false; historyPending = true; saveTimer.Stop();
        SaveState.Text = ""; pending = Evaluate();
        RequestSync(); // The restored text is saved like an edit, so it reaches the sync folder like one.
        return true;
    }
}
