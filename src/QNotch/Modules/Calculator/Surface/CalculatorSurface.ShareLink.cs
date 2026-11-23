using System.Windows;
using Calc.Documents;
using Calc.Documents.Export;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    /// <summary>Adds the browser link entry to the Share menu. The link is built only when the entry is chosen.</summary>
    partial void AddShareActions(List<ShareAction> actions, SheetExport export) =>
        actions.Add(new(T["copyShareLink"], _ => CopyShareLink(this, new()), Gesture: "Ctrl+Shift+L"));

    /// <summary>Copies a frozen browser link for the active sheet. Only runs when invoked: nothing is uploaded, fetched or watched.</summary>
    private async void CopyShareLink(object sender, RoutedEventArgs e)
    {
        if (compositionActive) { SaveState.Text = T["finishTextInput"]; return; }
        if (unavailable) return;
        await pending;
        string link;
        try { link = CreateShareLink(); }
        catch (ShareLinkException failure) { SaveState.Text = failure.Message; return; }
        catch (Exception failure) when (failure is System.IO.IOException or UnauthorizedAccessException)
        { SaveState.Text = T["shareSettingsUnavailable"]; SaveState.ToolTip = failure.Message; return; }
        // A file:// link opens only on a machine with the viewer at the same path; say so instead of implying a portable link.
        try { SheetClipboard.SetText(link); SaveState.Text = link.StartsWith("file:", StringComparison.OrdinalIgnoreCase) ? T["localLinkCopied"] : T["linkCopied"]; }
        catch (System.Runtime.InteropServices.COMException) { SaveState.Text = T["clipboardUnavailable"]; }
    }

    internal string CreateShareLink()
    {
        var viewer = ShareViewerAddress.Resolve(dataDirectory, new Uri(CalculatorAssets.WriteShareViewer(dataDirectory)));
        if (viewer.IsFile && !System.IO.File.Exists(viewer.LocalPath)) throw new ShareLinkException(T["shareViewerMissing"]);
        var name = workspace.Sheets.FirstOrDefault(sheet => sheet.Id == document.Id)?.Name ?? "Sheet";
        var source = Editor.Text;
        // Results belong to the text they were computed for; a sheet mid-evaluation shares its source without stale answers.
        var results = answers.Count == new SourceLineMap(source).Count ? answers : [];
        var snapshot = ShareLink.Capture(name, source, results, QNotch.Theme.ThemeManager.IsDark, DateOnly.FromDateTime(DateTime.Now), Explain);
        return ShareLink.Create(viewer, snapshot);
    }
}
