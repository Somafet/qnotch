using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;
using Calc.Documents;
using QNotch.Calculator;

namespace Calc.Windows;

/// <summary>
/// The sheet tabs, and closing with a way back. A closed sheet leaves the strip at once but stays in the store until its undo window ends,
/// so a crash in that window loses nothing. Only a real delete touches the catalog, at the deadline or on quit.
/// </summary>
public partial class CalculatorSurface
{
    private readonly SheetTabList tabList = new();
    /// <summary>Closed sheets' editors, kept so Undo brings back their caret, scroll and undo stack.</summary>
    private readonly Dictionary<Guid, SheetEditor> closedEditors = [];
    private DispatcherTimer? closeTimer;
    private DispatcherTimer? noticeTimer;

    private void InitializeTabs()
    {
        Tabs.Selected += id => SwitchSheet(id);
        Tabs.CloseRequested += id => CloseSheet(id);
        Tabs.NewRequested += () => NewSheet(this, new());
        Tabs.AllRequested += ShowAllSheets;
        Tabs.RenameRequested += RenameSheet;
        Tabs.MenuRequested += ShowTabMenu;
        NoticeUndo.Content = T["undo"];
    }

    private void CycleSheet(int direction)
    {
        var tabs = tabList.Visible;
        if (tabs.Count < 2) return;
        var index = 0;
        for (var i = 0; i < tabs.Count; i++) if (tabs[i].Id == document.Id) { index = i; break; }
        SwitchSheet(tabs[(index + direction + tabs.Count) % tabs.Count].Id);
    }

    // ---------- closing ----------

    /// <summary>Closes a tab, undoably. Any tab other than the active one closes without touching the sheet in front.</summary>
    internal bool CloseSheet(Guid id)
    {
        if (overlayClose is not null) return false;
        switch (tabList.CanClose(id))
        {
            case CloseVerdict.LastSheet: return CloseLastSheet(id);
            case CloseVerdict.Unknown: return false;
        }
        if (id == document.Id)
        {
            if (compositionActive) { SaveState.Text = T["finishTextInput"]; return false; }
            if (!Save()) return false; // An unsaved sheet is never closed. Any other tab was saved when it was left.
            CaptureHistory(true);
            if (!CloseActive(id)) return false;
            Tabs.Show(tabList.Visible, tabList.ActiveId);
            Tabs.RevealActive();
        }
        else
        {
            if (tabList.Close(id, DateTimeOffset.UtcNow) is null) return false;
            KeepClosedEditor(id);
            Tabs.ShowKeepingPlace(tabList.Visible, tabList.ActiveId);
        }
        ArmCloseTimer();
        ShowClosedNotice();
        return true;
    }

    /// <summary>The last sheet and the empty one that replaced it, while the close can still be undone.</summary>
    private (Guid Closed, Guid Fresh)? replacedLastSheet;

    /// <summary>Closing the only sheet opens an empty one in its place, the same as closing the last tab in a browser. Undo brings the
    /// closed sheet back in front and drops the empty one if nothing was typed into it.</summary>
    private bool CloseLastSheet(Guid id)
    {
        if (id != document.Id) return false;
        if (!tabList.CanCreate) { ShowNotice(T.Format("sheetLimitPending", SheetTabList.MaxSheets)); return false; }
        if (compositionActive) { SaveState.Text = T["finishTextInput"]; return false; }
        if (!Save()) return false;
        CaptureHistory(true);
        var fresh = Guid.Empty;
        if (!TryStorageAction(() =>
        {
            var next = store.Create(tabList.UniqueName(number => T.Format("newSheetName", number)));
            fresh = next.ActiveSheetId;
            ActivateSheet(next, store.Open(fresh));
        })) return false;
        if (tabList.Close(id, DateTimeOffset.UtcNow, wasActive: true) is null) return false;
        KeepClosedEditor(id);
        replacedLastSheet = (id, fresh);
        Tabs.Show(tabList.Visible, tabList.ActiveId);
        ArmCloseTimer();
        ShowClosedNotice();
        return true;
    }

    /// <summary>Moves to the nearest sheet that can load, then hides this one. A sheet whose file fails is passed over rather than
    /// stopping the close; when none can load the sheet stays open.</summary>
    private bool CloseActive(Guid id)
    {
        foreach (var neighbor in tabList.NeighborsOf(id).ToArray())
        {
            LoadResult loaded;
            try { loaded = store.Open(neighbor); }
            catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException) { continue; }
            if (tabList.Close(id, DateTimeOffset.UtcNow, neighbor) is null) return false;
            KeepClosedEditor(id); // Before the switch, so the editor cache cannot drop this sheet's undo stack.
            if (TryStorageAction(() => ActivateSheet(store.Select(neighbor), loaded))) return true;
            RestoreClosedEditor(id);
            tabList.Undo(DateTimeOffset.UtcNow);
            return false;
        }
        SaveState.Text = T["sheetUnavailable"];
        return false;
    }

    private void RestoreClosedEditor(Guid id)
    {
        if (!closedEditors.Remove(id, out var editor)) return;
        editors[id] = editor;
        editorOrder.Insert(0, id);
        while (editorOrder.Count > EditorCacheSize)
        {
            // The least recent editor goes, never the one showing.
            var drop = editorOrder.First(other => other != document.Id);
            uuidSessions.Remove(editors[drop]); editors.Remove(drop); editorOrder.Remove(drop);
        }
    }

    /// <summary>A catalog change (folder sync) can remove a sheet that was waiting for its delete: nothing is left to undo.</summary>
    private void ForgetVanishedCloses()
    {
        foreach (var id in closedEditors.Keys.Where(id => !tabList.IsClosed(id)).ToArray())
        {
            closedEditors.Remove(id, out var editor);
            if (editor is not null) uuidSessions.Remove(editor);
            positions.Remove(id);
        }
        if (tabList.Closed.Count > 0) return;
        closeTimer?.Stop();
        if (NoticeUndo.Visibility == Visibility.Visible) HideNotice();
    }

    private void KeepClosedEditor(Guid id)
    {
        if (!editors.Remove(id, out var editor)) return;
        editorOrder.Remove(id);
        closedEditors[id] = editor;
    }

    private void ArmCloseTimer()
    {
        if (tabList.DueAt is not { } due) { closeTimer?.Stop(); return; }
        closeTimer ??= CreateCloseTimer();
        closeTimer.Stop();
        var wait = due - DateTimeOffset.UtcNow;
        closeTimer.Interval = wait > TimeSpan.Zero ? wait : TimeSpan.FromMilliseconds(1);
        closeTimer.Start();
    }

    private DispatcherTimer CreateCloseTimer()
    {
        var timer = new DispatcherTimer(DispatcherPriority.Background);
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            CommitClosedSheets(everything: false);
        };
        return timer;
    }

    /// <summary>Turns waiting closes into real deletes: all of them when quitting, otherwise those whose window has ended.</summary>
    private void CommitClosedSheets(bool everything)
    {
        var due = everything ? tabList.TakeAll() : tabList.TakeExpired(DateTimeOffset.UtcNow);
        if (due.Count == 0) { if (!everything) ArmCloseTimer(); return; }
        foreach (var sheet in due)
        {
            if (replacedLastSheet?.Closed == sheet.Id) replacedLastSheet = null;
            closedEditors.Remove(sheet.Id, out var editor);
            if (editor is not null) uuidSessions.Remove(editor);
            positions.Remove(sheet.Id);
        }
        // One catalog write for the group. If it fails the sheets stay in the catalog and show again on the refresh below. Nothing is lost.
        TryStorageAction(() => workspace = store.DeleteMany(due.Select(sheet => sheet.Id).ToArray()));
        if (closedDown || everything) return;
        HideNotice();
        RefreshSheets();
    }

    private void UndoClose(object sender, RoutedEventArgs e) => UndoClose();

    /// <summary>Brings back the most recently closed sheet. If it was in front when closed it comes back in front.</summary>
    internal bool UndoClose()
    {
        if (tabList.Undo(DateTimeOffset.UtcNow) is not { } sheet) return false;
        RestoreClosedEditor(sheet.Id);
        ArmCloseTimer();
        if (tabList.Closed.Count > 0) ShowClosedNotice(); else HideNotice();
        // The empty sheet that stood in for the last one goes again, unless the user started using it.
        var unused = replacedLastSheet is { } replaced && replaced.Closed == sheet.Id && replaced.Fresh == document.Id && Editor.Text.Length == 0 ? replaced.Fresh : (Guid?)null;
        if (replacedLastSheet?.Closed == sheet.Id) replacedLastSheet = null;
        if (sheet.WasActive && SwitchSheet(sheet.Id) && unused is { } fresh) DropUnusedSheet(fresh);
        tabList.SetActive(document.Id);
        Tabs.Show(tabList.Visible, tabList.ActiveId);
        Tabs.Reveal(sheet.Id);
        return true;
    }

    private void DropUnusedSheet(Guid id)
    {
        if (!TryStorageAction(() => workspace = store.DeleteMany([id]))) return;
        if (editors.Remove(id, out var editor)) { uuidSessions.Remove(editor); editorOrder.Remove(id); }
        positions.Remove(id);
        RefreshSheets();
    }

    // ---------- the note at the bottom of the card ----------

    private void ShowClosedNotice()
    {
        if (tabList.LastClosed is not { } last) return;
        noticeTimer?.Stop();
        var others = tabList.Closed.Count - 1;
        NoticeText.Text = others == 0 ? T.Format("closedSheet", last.Name) : T.Format("closedSheets", last.Name, others);
        NoticeText.ToolTip = last.Name;
        NoticeUndo.Content = T["undo"];
        NoticeUndo.Visibility = Visibility.Visible;
        NoticeBar.Visibility = Visibility.Visible;
    }

    /// <summary>A short note. While a close can still be undone, its bar comes back when the note ends.</summary>
    private void ShowNotice(string text)
    {
        NoticeText.Text = text;
        NoticeText.ToolTip = null;
        NoticeUndo.Visibility = Visibility.Collapsed;
        NoticeBar.Visibility = Visibility.Visible;
        noticeTimer ??= CreateNoticeTimer();
        noticeTimer.Stop();
        noticeTimer.Start();
    }

    private DispatcherTimer CreateNoticeTimer()
    {
        var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(2.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (tabList.Closed.Count > 0) ShowClosedNotice(); else HideNotice();
        };
        return timer;
    }

    private void HideNotice()
    {
        noticeTimer?.Stop();
        NoticeBar.Visibility = Visibility.Collapsed;
    }

    // ---------- menus ----------

    private ContextMenu HeldMenu()
    {
        IDisposable? hold = null;
        var menu = new ContextMenu();
        menu.Opened += (_, _) => hold ??= host.HoldOpen();
        menu.Closed += (_, _) => { hold?.Dispose(); hold = null; ReturnToEditor(menu, EventArgs.Empty); };
        return menu;
    }

    private static MenuItem MenuEntry(string header, Action click, string? gesture = null, bool enabled = true)
    {
        var item = new MenuItem { Header = header, InputGestureText = gesture ?? "", IsEnabled = enabled };
        item.Click += (_, _) => click();
        return item;
    }

    private void ShowTabMenu(Guid id, UIElement target)
    {
        var menu = HeldMenu();
        menu.PlacementTarget = target;
        menu.Placement = PlacementMode.Bottom;
        menu.Items.Add(MenuEntry(T["renameMenu"], () => RenameSheet(id), "F2"));
        menu.Items.Add(MenuEntry(T["historyMenu"], () => { if (SwitchSheet(id)) ShowHistory(this, new()); }));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuEntry(T["closeSheet"], () => CloseSheet(id), "Ctrl+W", tabList.CanClose(id) != CloseVerdict.Unknown));
        menu.IsOpen = true;
    }

    private void ShowSheetMenu(object sender, RoutedEventArgs e)
    {
        var menu = HeldMenu();
        menu.PlacementTarget = MoreButton;
        menu.Placement = PlacementMode.Custom;
        menu.CustomPopupPlacementCallback = BelowRightEdge;
        menu.Items.Add(MenuEntry(T["newSheet"], () => NewSheet(this, new()), "Ctrl+N", tabList.CanCreate));
        menu.Items.Add(MenuEntry(T["importMenu"], () => ImportSheets(this, new()), "Ctrl+O"));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuEntry(T["renameMenu"], () => RenameSheet(document.Id), "F2"));
        menu.Items.Add(MenuEntry(T["historyMenu"], () => ShowHistory(this, new())));
        menu.Items.Add(MenuEntry(T["closeSheet"], () => CloseSheet(document.Id), "Ctrl+W", tabList.CanClose(document.Id) != CloseVerdict.Unknown));
        menu.Items.Add(new Separator());
        menu.Items.Add(MenuEntry(T["help"], ShowHelp, "F1"));
        menu.Items.Add(MenuEntry(T["settings"], () => host.OpenSettings()));
        menu.IsOpen = true;
    }

    private void ReturnToEditor(object? sender, EventArgs e)
    {
        if (overlayClose is null && IsKeyboardFocusWithin) Editor.Focus();
    }
}
