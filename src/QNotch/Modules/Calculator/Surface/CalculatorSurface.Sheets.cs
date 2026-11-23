using System.IO;
using System.Windows;
using System.Windows.Controls;
using Calc.Documents;
using QNotch.Calculator;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    /// <summary>Recently used editors, which keep their undo stacks. Sheets load lazily.</summary>
    private const int EditorCacheSize = 4;

    private void RegisterEditor(SheetEditor editor, GeneratedUuidState? generated = null)
    {
        RegisterUuidState(editor, generated); RegisterComposition(editor); RegisterDice(editor);
        editor.InlineRenameHost = PlaceRenameBox;
        editor.TextArea.PreviewMouseLeftButtonDown += (_, _) => { if (ReferenceEquals(Editor, editor)) host.TakeKeyboard(); };
        editor.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) =>
        {
            if (!ReferenceEquals(Editor, editor)) return;
            if (e.VerticalChange != 0) DiceLayer.Dismiss(); // resting dice belong to the visible sheet position
            RequestGutterLayout();
        }));
        editor.SizeChanged += (_, _) => { if (ReferenceEquals(Editor, editor)) RequestGutterLayout(); };
        editor.TextArea.TextView.VisualLinesChanged += (_, _) => { if (ReferenceEquals(Editor, editor)) RequestGutterLayout(); };
    }

    private SheetEditor CreateEditor(string source, GeneratedUuidState? generated = null)
    {
        var editor = new SheetEditor { Text = source };
        editor.SetResourceReference(ForegroundProperty, "TextPrimaryBrush");
        editor.SetResourceReference(SheetEditor.CaretBrushProperty, "TextPrimaryBrush");
        editor.FontSize = Editor.FontSize;
        System.Windows.Automation.AutomationProperties.SetName(editor, T["sheetExpressions"]);
        ApplyEditorColors(editor, SystemParameters.HighContrast);
        editor.TextChanged += EditorChanged; RegisterEditor(editor, generated);
        return editor;
    }

    /// <summary>Shows the catalog on the strip. Sheets waiting for their delete stay in the catalog but not on the strip.</summary>
    private void RefreshSheets()
    {
        tabList.Update(workspace.Sheets.Select(sheet => new SheetTab(sheet.Id, sheet.Name)), document.Id);
        if (applyingSync) ForgetVanishedCloses();
        Tabs.Show(tabList.Visible, tabList.ActiveId);
        if (!applyingSync) RequestSync(); // Catalog edits (create/rename/delete) publish too; a no-op while sync is off.
    }

    private bool TryStorageAction(Action action, string? failure = null)
    {
        failure ??= T["sheetUnavailable"];
        try { action(); return true; }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        { SaveState.Text = failure; SaveState.ToolTip = e.Message; return false; }
    }

    private bool SwitchSheet(Guid id)
    {
        if (id == document.Id) { Tabs.RevealActive(); return true; }
        if (!Save()) { RefreshSheets(); return false; }
        CaptureHistory(true);
        var success = TryStorageAction(() =>
        {
            var loaded = store.Open(id); // Validate target before committing selection or changing editor.
            var next = store.Select(id);
            ActivateSheet(next, loaded);
        });
        if (!success) RefreshSheets();
        return success;
    }

    private void ActivateSheet(WorkspaceDocument next, LoadResult loaded)
    {
        var hadFocus = IsKeyboardFocusWithin;
        if (loaded.Document.Id != document.Id) CloseOverlay(false); // An open history or rename belongs to the sheet it was opened on.
        Editor.CompleteVariableRename(false); // A rename box belongs to the sheet it was opened on.
        positions[document.Id] = (Editor.SelectionStart, Editor.SelectionLength, Editor.VerticalOffset);
        ready = false; evaluation?.Cancel(); revision++; answers = []; ClearResults();
        workspace = next; document = loaded.Document;
        compositionActive = false; evaluationDeferred = false;
        functionReceipts = loaded.FunctionReceipts ?? []; restoredReceipts = null; historyPending = false;
        if (!editors.TryGetValue(document.Id, out var editor) || editor.Text != document.Source)
        {
            if (editor is not null) uuidSessions.Remove(editor);
            editor = CreateEditor(document.Source, document.GeneratedUuids); editors[document.Id] = editor;
        }
        // A small native-editor cache preserves undo on recent sheets; source is loaded lazily.
        editorOrder.Remove(document.Id); editorOrder.Add(document.Id);
        while (editorOrder.Count > EditorCacheSize) { uuidSessions.Remove(editors[editorOrder[0]]); editors.Remove(editorOrder[0]); editorOrder.RemoveAt(0); }
        DiceLayer.Clear(); rollShowing = null;
        EditorHost.Content = null; Editor = editor; EditorHost.Content = editor;
        SetResultColumn(ResultColumn.Width.Value); UpdatePlaceholder();
        unavailable = false; Editor.IsReadOnly = false;
        Editor.UpdateLayout();
        if (positions.TryGetValue(document.Id, out var position))
        { Editor.Select(Math.Min(position.Start, Editor.Text.Length), Math.Min(position.Length, Math.Max(0, Editor.Text.Length - position.Start))); Editor.ScrollToVerticalOffset(position.Scroll); }
        dirty = false; ready = true;
        SaveState.Text = loaded.Recovered ? T["recoveredBackup"] : HistoryState;
        RefreshSheets(); if (hadFocus) Editor.Focus(); pending = Evaluate();
    }

    private void NewSheet(object sender, RoutedEventArgs e)
    {
        if (!tabList.CanCreate)
        {
            ShowNotice(tabList.Closed.Count > 0 ? T.Format("sheetLimitPending", SheetTabList.MaxSheets) : T.Format("sheetLimit", SheetTabList.MaxSheets));
            return;
        }
        if (!Save()) return;
        CaptureHistory(true);
        var created = TryStorageAction(() =>
        {
            var next = store.Create(tabList.UniqueName(number => T.Format("newSheetName", number)));
            ActivateSheet(next, store.Open(next.ActiveSheetId));
        });
        if (!created) return;
        host.TakeKeyboard();
        FocusInput();
    }

    /// <summary>F2: the variable at the editor caret or selection, otherwise the sheet.</summary>
    private void RenameAtCaret()
    {
        if (Editor.IsKeyboardFocusWithin && Editor.BeginVariableRename()) return;
        RenameSheet(document.Id);
    }

    /// <summary>Shows the variable rename box under its variable, kept inside the sheet card.</summary>
    private void PlaceRenameBox(FrameworkElement? box, Rect at)
    {
        RenameLayer.Children.Clear();
        if (box is null) return;
        box.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var origin = Editor.TranslatePoint(new Point(at.X, at.Bottom), RenameLayer);
        Canvas.SetLeft(box, Math.Max(0, Math.Min(origin.X, RenameLayer.ActualWidth - box.DesiredSize.Width)));
        Canvas.SetTop(box, Math.Max(0, Math.Min(origin.Y, RenameLayer.ActualHeight - box.DesiredSize.Height)));
        RenameLayer.Children.Add(box);
    }

    private bool RenameSheetTo(Guid id, string name) => TryStorageAction(() => { workspace = store.Rename(id, name); RefreshSheets(); });
}
