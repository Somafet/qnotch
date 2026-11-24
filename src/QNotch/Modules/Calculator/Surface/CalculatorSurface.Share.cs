using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Calc.Documents.Export;
using Microsoft.Win32;

namespace Calc.Windows;

/// <summary>One Share menu entry. <paramref name="Run"/> executes on the UI thread with the snapshot the menu was opened for.</summary>
internal sealed record ShareAction(string Header, Action<SheetExport> Run, bool Enabled = true, string? Gesture = null);

public partial class CalculatorSurface
{
    private ContextMenu? shareMenu;
    private IDisposable? shareHold;

    /// <summary>Extension point for another Share entry (for example a link copy), implemented in its own partial file.
    /// Entries added here appear after the copy entries and before Export/Print. Without an implementation the call compiles away.</summary>
    partial void AddShareActions(List<ShareAction> actions, SheetExport export);

    private async Task<SheetExport> CurrentExport()
    {
        await pending;
        var title = workspace.Sheets.FirstOrDefault(sheet => sheet.Id == document.Id)?.Name ?? "Sheet";
        return SheetExport.Create(title, Editor.Text, FreshResults(Editor.Text), resultFormat);
    }

    private async void ShowShare(object sender, RoutedEventArgs e)
    {
        if (shareMenu is not null) shareMenu.IsOpen = false;
        SheetExport export;
        try { export = await CurrentExport(); }
        catch (ArgumentException failure) { SaveState.Text = failure.Message; return; }
        var actions = new List<ShareAction>
        {
            new(T["copyResults"], CopyResults, export.HasResults),
            new(T["copyTotal"], CopyTotal, export.TotalText is not null),
            new(T["copyTable"], CopyTable, export.Lines.Any(line => line.Kind != ExportLineKind.Blank)),
            new(T["copyImage"], snapshot => CopyImage(snapshot, transparent: false)),
            new(T["copyTransparentImage"], snapshot => CopyImage(snapshot, transparent: true)),
        };
        AddShareActions(actions, export);
        var menu = new ContextMenu { PlacementTarget = Share, Placement = PlacementMode.Custom, CustomPopupPlacementCallback = BelowRightEdge };
        foreach (var action in actions) menu.Items.Add(Item(action, export));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(new(T["exportMenu"], ExportSheet), export));
        menu.Items.Add(Item(new(T["printMenu"], PrintSheet, Gesture: "Ctrl+P"), export));
        menu.Opened += (_, _) => shareHold ??= host.HoldOpen();
        menu.Closed += (_, _) => { shareHold?.Dispose(); shareHold = null; ReturnToEditor(menu, EventArgs.Empty); };
        shareMenu = menu; menu.IsOpen = true;
    }
    private static MenuItem Item(ShareAction action, SheetExport export)
    {
        var item = new MenuItem { Header = action.Header, IsEnabled = action.Enabled, InputGestureText = action.Gesture ?? "" };
        item.Click += (_, _) => action.Run(export);
        return item;
    }

    private void ShareShortcut(object sender, KeyEventArgs e)
    {
        if (compositionActive || e.Key != Key.P || Keyboard.Modifiers != ModifierKeys.Control) return;
        e.Handled = true;
        _ = PrintCurrent();
    }
    private async Task PrintCurrent()
    {
        try { PrintSheet(await CurrentExport()); }
        catch (ArgumentException failure) { SaveState.Text = failure.Message; }
    }

    private bool SetClipboard(Action write, string done)
    {
        try { write(); SaveState.Text = done; return true; }
        catch (System.Runtime.InteropServices.COMException) { SaveState.Text = T["clipboardUnavailable"]; return false; }
        catch (ArgumentException failure) { SaveState.Text = failure.Message; return false; }
    }
    private void CopyResults(SheetExport export) => SetClipboard(() => SheetClipboard.SetText(export.ResultsText()), T["resultsCopied"]);
    private void CopyTotal(SheetExport export) { if (export.TotalText is { } total) SetClipboard(() => SheetClipboard.SetText(total), T["totalCopied"]); }
    private void CopyTable(SheetExport export) => SetClipboard(() =>
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, export.TableTsv());
        data.SetData(DataFormats.Html, ClipboardHtml.Wrap(export.TableHtml()));
        SheetClipboard.SetDataObject(data);
    }, T["tableCopied"]);

    private (BitmapSource Image, int Omitted) RenderImage(SheetExport export, bool transparent)
    {
        var theme = ExportTheme.FromResources(this, Editor.FontFamily, Editor.FontSize);
        var width = Math.Clamp(ResultGrid.ActualWidth + 56, 480, 1194);
        return ExportRenderer.Image(export, theme, width, transparent);
    }
    private string Omitted(string done, int omitted) => omitted == 0 ? done : T.Format("linesOmitted", done, omitted);
    private void CopyImage(SheetExport export, bool transparent)
    {
        var (image, omitted) = RenderImage(export, transparent);
        SetClipboard(() =>
        {
            var data = new DataObject();
            // Applications that understand PNG keep the transparency; the bitmap fallback is drawn over the sheet background.
            data.SetData("PNG", new MemoryStream(ExportRenderer.Png(image)));
            data.SetImage(transparent ? ExportRenderer.Flatten(image, (System.Windows.Media.Brush)FindResource("CardBrush")) : image);
            SheetClipboard.SetDataObject(data);
        }, Omitted(T["imageCopied"], omitted));
    }

    private static (string Filter, ExportFormat Format)[] ExportChoices =>
    [
        (T["filterText"], ExportFormat.PlainText), ("Markdown (*.md)|*.md", ExportFormat.Markdown), ("CSV (*.csv)|*.csv", ExportFormat.Csv),
        ("PDF (*.pdf)|*.pdf", ExportFormat.Pdf), (T["filterPng"], ExportFormat.Png), (T["filterPngTransparent"], ExportFormat.TransparentPng)
    ];
    private void ExportSheet(SheetExport export)
    {
        var dialog = new SaveFileDialog
        {
            Title = T["exportSheet"], Filter = string.Join('|', ExportChoices.Select(choice => choice.Filter)), FilterIndex = 1,
            FileName = ExportFile.SuggestedName(export.Title, ExportFormat.PlainText)[..^4], AddExtension = true, OverwritePrompt = true
        };
        bool? chosen;
        using (host.HoldOpen()) chosen = dialog.ShowDialog();
        if (chosen != true) return;
        var format = ExportChoices[Math.Clamp(dialog.FilterIndex - 1, 0, ExportChoices.Length - 1)].Format;
        var path = dialog.FileName;
        if (!path.EndsWith(ExportFile.Extension(format), StringComparison.OrdinalIgnoreCase)) path += ExportFile.Extension(format);
        try
        {
            var done = T["exported"];
            byte[] bytes;
            switch (format)
            {
                case ExportFormat.PlainText: bytes = ExportFile.Encode(format, export.PlainText()); break;
                case ExportFormat.Markdown: bytes = ExportFile.Encode(format, export.Markdown()); break;
                case ExportFormat.Csv: bytes = ExportFile.Encode(format, export.Csv()); break;
                case ExportFormat.Pdf:
                    var pdf = ExportRenderer.Pdf(export);
                    if (pdf is null) { SaveState.Text = T["pdfFontUnavailable"]; return; }
                    bytes = pdf.Bytes;
                    if (pdf.MissingCharacters > 0) done = T.Format("exportedMissing", pdf.MissingCharacters);
                    break;
                default:
                    var (image, omitted) = RenderImage(export, format == ExportFormat.TransparentPng);
                    bytes = ExportRenderer.Png(image); done = Omitted(done, omitted); break;
            }
            ExportFile.Write(path, bytes);
            SaveState.Text = done; SaveState.ToolTip = path;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        { SaveState.Text = T["exportFailed"]; SaveState.ToolTip = failure.Message; }
    }

    private void PrintSheet(SheetExport export)
    {
        var dialog = new PrintDialog { UserPageRangeEnabled = false };
        bool? chosen;
        using (host.HoldOpen()) chosen = dialog.ShowDialog();
        if (chosen != true) return;
        try
        {
            var paginator = ExportRenderer.Paginator(export, new Size(dialog.PrintableAreaWidth, dialog.PrintableAreaHeight));
            dialog.PrintDocument(paginator, export.Title);
            SaveState.Text = T["sentToPrinter"];
        }
        catch (Exception failure) when (failure is System.Printing.PrintSystemException or ArgumentException or InvalidOperationException)
        { SaveState.Text = T["printFailed"]; SaveState.ToolTip = failure.Message; }
    }
}
