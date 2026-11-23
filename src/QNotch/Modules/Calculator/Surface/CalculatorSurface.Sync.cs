using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Calc.Documents;

namespace Calc.Windows;

/// <summary>Optional folder sync. Off unless a folder was chosen: then no session, watcher, timer or task exists.
/// All reconciliation lives in Calc.Documents; this host only flushes the editor first and shows the outcome.</summary>
public partial class CalculatorSurface
{
    private FolderSyncSession? syncSession;
    private bool applyingSync;
    private bool syncMessageShown;

    private void StartSync()
    {
        string? folder;
        try { folder = FolderSync.ConfiguredFolder(dataDirectory); }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        { ShowSyncMessage(T["syncUnavailable"], e.Message); return; }
        if (folder is null) return;
        EnsureSyncSession().Start();
    }
    private FolderSyncSession EnsureSyncSession() => syncSession ??= new FolderSyncSession(store, dataDirectory, Environment.MachineName,
        action => Dispatcher.BeginInvoke(DispatcherPriority.Background, action), CanApplySync, ApplySyncReport);
    private void RequestSync() { if (!applyingSync) syncSession?.Request(); }
    private void StopSync() { syncSession?.Dispose(); syncSession = null; }
    // The pass reads saved files, so pending edits are flushed first; composing text defers it.
    private bool CanApplySync() => ready && !compositionActive && Save();

    private void ApplySyncReport(SyncReport report)
    {
        if (!ready) return;
        if (report.Workspace is { } next)
        {
            applyingSync = true;
            try
            {
                foreach (var id in report.ChangedSheets)
                {
                    if (editors.Remove(id, out var cached)) { uuidSessions.Remove(cached); editorOrder.Remove(id); }
                    // A closed sheet changed elsewhere: Undo must reopen the synced text, not this editor's copy.
                    if (closedEditors.Remove(id, out var closed)) uuidSessions.Remove(closed);
                }
                workspace = next;
                if (!next.Sheets.Any(s => s.Id == document.Id))
                {
                    tabList.Update(next.Sheets.Select(s => new QNotch.Calculator.SheetTab(s.Id, s.Name)), next.ActiveSheetId);
                    TryStorageAction(() => ActivateSheet(store.Select(tabList.ActiveId), store.Open(tabList.ActiveId)));
                }
                else if (report.ChangedSheets.Contains(document.Id)) TryStorageAction(() => ActivateSheet(next, store.Open(document.Id)));
                else RefreshSheets();
            }
            finally { applyingSync = false; }
        }
        var message = report.Status switch
        {
            SyncStatus.FolderUnavailable => T["syncFolderUnavailable"],
            SyncStatus.Failed => T["syncFailed"],
            SyncStatus.Waiting => T["syncWaiting"], // The English engine detail stays in the tooltip.
            _ when report.Conflicts > 0 => report.Conflicts == 1 ? T["syncConflictOne"] : T.Format("syncConflictMany", report.Conflicts),
            _ => null,
        };
        if (message is not null) ShowSyncMessage(message, report.Problem, sticky: report.Status == SyncStatus.Synchronized);
        // Waiting/unavailable/failed clear once resolved; a conflict notice stays until the next save replaces the status.
        else if (syncMessageShown && !syncMessageSticky && !dirty) { SaveState.Text = HistoryState; SaveState.ToolTip = null; syncMessageShown = false; }
    }
    private bool syncMessageSticky;
    private void ShowSyncMessage(string text, string? detail, bool sticky = false)
    { SaveState.Text = text; SaveState.ToolTip = detail; syncMessageShown = true; syncMessageSticky = sticky; }

    private void ChooseSyncFolder()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = T["chooseSyncFolder"] };
        if (syncSession?.Folder is { } current && Directory.Exists(current)) dialog.InitialDirectory = current;
        else if (Environment.GetEnvironmentVariable("OneDrive") is { Length: > 0 } oneDrive && Directory.Exists(oneDrive)) dialog.InitialDirectory = oneDrive;
        bool? chosen;
        using (host.HoldOpen()) chosen = dialog.ShowDialog();
        if (chosen == true) SetSyncFolder(dialog.FolderName);
    }
    private bool SetSyncFolder(string? folder)
    {
        try { return Save() && TryStorageAction(() =>
        {
            if (folder is null) { StopSync(); FolderSync.SetFolder(dataDirectory, null); if (syncMessageShown) { SaveState.Text = HistoryState; syncMessageShown = false; } }
            else EnsureSyncSession().SetFolder(folder);
        }, T["syncUnavailable"]); }
        finally { RefreshSettings("sync"); }
    }
}
