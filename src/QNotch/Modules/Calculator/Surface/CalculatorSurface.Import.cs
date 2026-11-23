using System.IO;
using System.Text;
using System.Windows;
using Calc.Documents;

namespace Calc.Windows;

/// <summary>X04: import .numi, .slvr and .txt files through the open dialog (Ctrl+O, sheet menu) or a file drop anywhere on the window.
/// Each accepted file becomes a new sheet; parsing and reporting live in Calc.Documents. No watcher or background work persists.</summary>
public partial class CalculatorSurface
{
    internal sealed record ImportOutcome(int Created, string Report);
    private bool importing;

    internal static string[] DroppedFiles(IDataObject data) =>
        data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files ? files : [];

    /// <summary>Files dropped on the notch's Calculator tile: each supported one becomes a new sheet.</summary>
    internal async void ImportDropped(string[] files)
    {
        var supported = files.Where(SheetImport.IsSupported).ToArray();
        if (supported.Length > 0) await ImportAndReport(supported);
    }

    private async void ImportSheets(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = T["importTitle"], Multiselect = true, CheckFileExists = true,
            Filter = T["importFilter"]
        };
        bool? chosen;
        using (host.HoldOpen()) chosen = dialog.ShowDialog();
        if (chosen == true) await ImportAndReport(dialog.FileNames);
    }
    private async Task ImportAndReport(IReadOnlyList<string> files)
    {
        var outcome = await ImportFiles(files);
        if (outcome.Report.Length > 0) ShowReport(T["importTitle"], outcome.Report);
    }

    /// <summary>Reads and parses off the UI thread, then creates one sheet per accepted file and opens the last. A rejected file
    /// creates nothing; the source files are only ever read. Returns a report of every rejection and note (empty when clean).</summary>
    internal async Task<ImportOutcome> ImportFiles(IReadOnlyList<string> files)
    {
        if (importing || files.Count == 0) return new(0, "");
        if (!Save()) return new(0, T["importStopped"]);
        importing = true; var status = SaveState.Text; SaveState.Text = T["importing"];
        try
        {
            var batch = files.Take(SheetImport.MaxFiles).ToArray();
            var parsed = await Task.Run(() => batch.Select(path =>
            {
                try { return (Path: path, Sheet: SheetImport.ReadFile(path), Error: (string?)null); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or NotSupportedException or ArgumentException or System.Security.SecurityException)
                { return (Path: path, Sheet: (ImportedSheet?)null, Error: e.Message); }
            }).ToArray());
            if (!Save()) return new(0, T["importStopped"]); // Typing during the parse must reach disk before another sheet replaces the editor.
            CaptureHistory(true);
            var report = new StringBuilder(); var created = 0; Guid? last = null; var lines = 0;
            void Add(string text) { if (lines++ < 40) report.AppendLine(text); }
            foreach (var (path, sheet, error) in parsed)
            {
                var file = Path.GetFileName(path);
                if (sheet is null) { Add(T.Format("notImported", file, error ?? "")); continue; }
                try
                {
                    var name = SheetImport.UniqueName(sheet.Name, workspace.Sheets.Select(s => s.Name)); // Sheets waiting for their delete still hold their names.
                    workspace = store.Create(name, sheet.Source); last = workspace.ActiveSheetId; created++;
                    if (sheet.Notices.Count > 0) Add(T.Format("importedAs", file, name));
                    foreach (var notice in sheet.Notices) Add(notice.Line > 0 ? T.Format("importLine", notice.Line, notice.Message) : "  " + notice.Message);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
                { Add(T.Format("notImported", file, e.Message)); }
            }
            if (files.Count > batch.Length) Add(T.Format("moreFilesNotImported", files.Count - batch.Length, SheetImport.MaxFiles));
            if (lines > 40) report.AppendLine(T.Format("moreNotes", lines - 40));
            if (last is { } id && !TryStorageAction(() => ActivateSheet(workspace, store.Open(id))))
            {
                // The new sheets exist; keep the editor and the catalog's selection consistent with the sheet still shown.
                TryStorageAction(() => { workspace = store.Select(document.Id); RefreshSheets(); });
            }
            else if (last is null) { RefreshSheets(); SaveState.Text = status; }
            if (created > 0) SaveState.Text = created == 1 ? T["importedOne"] : T.Format("importedMany", created);
            return new(created, report.ToString().TrimEnd());
        }
        finally { importing = false; }
    }
}
