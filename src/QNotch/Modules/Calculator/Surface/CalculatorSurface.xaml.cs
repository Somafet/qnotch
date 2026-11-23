using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Calc.Core;
using Calc.Documents;
using QNotch.Modules.Calculator;

namespace Calc.Windows;

/// <summary>
/// Calc's main window as a panel tab: the same partial files, hosted in a control. Everything here runs on the UI thread. While hidden it
/// holds no timers and does no work, apart from a short undo window after a sheet was closed.
/// </summary>
public partial class CalculatorSurface : UserControl
{
    private readonly CalculatorModule host;
    private readonly WorkspaceStore store;
    private WorkspaceDocument workspace;
    private SheetDocument document;
    private readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private CancellationTokenSource? evaluation;
    private IReadOnlyList<LineResult> answers = [];
    private bool ready;
    private bool dirty;
    private bool closedDown;
    private long revision;
    private Task pending = Task.CompletedTask;
    private readonly SheetEvaluationSession evaluationSession = new();
    private FunctionLibrary functions = FunctionLibrary.Empty;
    private IReadOnlyList<FunctionReceipt> functionReceipts = [];
    private readonly string dataDirectory;
    private readonly Dictionary<Guid, SheetEditor> editors = [];
    private readonly List<Guid> editorOrder = [];
    private readonly Dictionary<Guid, (int Start, int Length, double Scroll)> positions = [];
    private bool unavailable;
    private bool startupStarted;

    internal CalculatorSurface(CalculatorModule host, CalculatorSession session)
    {
        this.host = host;
        dataDirectory = session.DataDirectory;
        store = session.Store;
        workspace = session.Workspace;
        preferences = session.Preferences;
        functions = session.Functions;
        var sheet = session.Sheet;
        document = sheet?.Document ?? new(1, workspace.ActiveSheetId, "", workspace.Dark);
        functionReceipts = sheet?.FunctionReceipts ?? [];
        InitializeComponent();
        ApplyAppearance(); ApplyPreferences(); Editor.Text = document.Source;
        Placeholder.FontFamily = Editor.FontFamily;
        SetResultColumn(ResultColumn.Width.Value); UpdatePlaceholder();
        unavailable = sheet is null; Editor.IsReadOnly = unavailable;
        if (unavailable) { SaveState.Text = T["sheetUnavailable"]; SaveState.ToolTip = session.OpenFailure; }
        else if (session.Recovered) SaveState.Text = T["recoveredBackup"];
        ready = true;
        IsVisibleChanged += (_, _) =>
        {
            DateVisibilityChanged();
            if (!IsVisible) CloseOverlay(false); // Its hold would keep the panel open on other tabs.
        };
        editors[document.Id] = Editor; editorOrder.Add(document.Id);
        InitializeTabs();
        RefreshSheets(); RegisterEditor(Editor, document.GeneratedUuids); RegisterDiceDismissal();
        saveTimer.Tick += (_, _) => Save();
        PreviewKeyDown += OverlayKeys;
        PreviewKeyDown += ShareShortcut;
        StartSync(); // Folder sync: nothing starts unless a folder was chosen.
        PreviewKeyDown += SheetKeys;
        Loaded += async (_, _) =>
        {
            if (startupStarted) return;
            startupStarted = true;
            await Evaluate();
        };
        SetResourceReference(ThemeProbeProperty, "TextPrimaryBrush");
        SystemParameters.StaticPropertyChanged += SystemAppearanceChanged;
        host.FunctionsChanged(functions);
    }

    private void SheetKeys(object sender, KeyEventArgs e)
    {
        if (compositionActive || overlayClose is not null || Editor.RenamingVariable) return;
        var modifiers = Keyboard.Modifiers;
        if (e.Key == Key.N && modifiers == ModifierKeys.Control) { NewSheet(this, new()); e.Handled = true; }
        else if (e.Key == Key.O && modifiers == ModifierKeys.Control) { ImportSheets(this, new()); e.Handled = true; }
        else if (e.Key == Key.W && modifiers == ModifierKeys.Control) { CloseSheet(document.Id); e.Handled = true; }
        else if (e.Key == Key.Tab && modifiers == ModifierKeys.Control) { CycleSheet(1); e.Handled = true; }
        else if (e.Key == Key.Tab && modifiers == (ModifierKeys.Control | ModifierKeys.Shift)) { CycleSheet(-1); e.Handled = true; }
        else if (e.Key == Key.F2) { RenameAtCaret(); e.Handled = true; }
        else if (e.Key == Key.F1 && modifiers == ModifierKeys.None)
        {
            // A focused result answers F1 itself, with its explanation.
            if (Keyboard.FocusedElement is DependencyObject focused && Results.IsAncestorOf(focused)) return;
            ShowHelp(); e.Handled = true;
        }
        else if (e.Key == Key.L && modifiers == (ModifierKeys.Control | ModifierKeys.Shift)) { CopyShareLink(this, new()); e.Handled = true; }
    }

    /// <summary>Focus for a keyboard summon: an open overlay keeps it, otherwise the editor.</summary>
    internal void FocusInput()
    {
        if (overlayFocus is { } target) { target.Focus(); Keyboard.Focus(target); return; }
        Editor.Focus();
        Keyboard.Focus(Editor.TextArea);
    }

    /// <summary>Panel closed or module going away: pending text is written. Waiting closes keep their own deadline.</summary>
    internal void Flush()
    {
        if (closedDown || compositionActive) return;
        Save();
        CaptureHistory(false);
    }

    /// <summary>The app is quitting. Saves, turns waiting closes into real deletes and lets go of the store.</summary>
    internal void Shutdown()
    {
        if (closedDown) return;
        compositionActive = false;
        Save(); CaptureHistory(true);
        CommitClosedSheets(everything: true);
        closedDown = true; ready = false;
        StopSync(); StopDateSchedule(); StopCurrencySchedule(cancelAll: true); currencyHttpClient?.Dispose();
        evaluation?.Cancel(); saveTimer.Stop(); closeTimer?.Stop(); noticeTimer?.Stop();
        SystemParameters.StaticPropertyChanged -= SystemAppearanceChanged;
        store.Dispose();
    }

    private void EditorChanged(object? sender, EventArgs e)
    {
        if (!ready || !ReferenceEquals(sender, Editor)) return;
        dirty = true; UpdatePlaceholder(); DiceLayer.Dismiss();
        usesCurrentDate = false; usesCurrentInstant = false; usesLocalTimeZone = false; requiresSecondRefresh = false; StopDateSchedule();
        usesCurrencyRates = false; currencyRequests = []; StopCurrencySchedule(true); UpdateCurrencyStatus();
        answers = []; ClearResults();
        if (compositionActive) { evaluationDeferred = true; saveTimer.Stop(); return; }
        evaluationDeferred = false;
        saveTimer.Stop(); saveTimer.Start();
        pending = !Editor.Document.UndoStack.AcceptChanges ? Dispatcher.InvokeAsync(Evaluate, DispatcherPriority.Background).Task.Unwrap() : Evaluate();
    }

    private async Task Evaluate()
    {
        if (closedDown) return;
        evaluation?.Cancel();
        var cancellation = new CancellationTokenSource(); evaluation = cancellation;
        var current = ++revision; var source = Editor.Text;
        var library = functions; var receipts = functionReceipts;
        var snapshot = ReadTemporalSnapshot(); var context = new EvaluationContext(snapshot.Date, snapshot.Instant, LocalZone: snapshot.LocalZone, WorkdayRegion: WorkdayRegion, CurrencyRates: currencyRates)
            { PayrollRegion = SystemPayrollRegion(), DisplayCurrency = preferences.DefaultCurrency };
        try
        {
            context = context with { Uuids = ReadUuidContext(source) };
            var evaluated = await Task.Run(() => evaluationSession.EvaluateWithFunctions(source, library, receipts, cancellation.Token, context));
            if (current != revision) return;
            if (evaluated.UuidRequests.Count > 0)
            {
                var owner = uuidSessions[Editor].Session;
                owner.Supply(evaluated.UuidRequests, context.Uuids!);
                dirty = true; saveTimer.Stop(); saveTimer.Start();
                context = context with { Uuids = owner.Context };
                evaluated = await Task.Run(() => evaluationSession.EvaluateWithFunctions(source, library, receipts, cancellation.Token, context));
                if (evaluated.UuidRequests.Count > 0) throw new ArgumentException("UUID binding discovery did not settle");
            }
            if (evaluated.UsesCurrencyRates && !currencyCacheLoaded)
            {
                await EnsureCurrencyCache(cancellation.Token); context = context with { CurrencyRates = currencyRates };
                evaluated = await Task.Run(() => evaluationSession.EvaluateWithFunctions(source, library, receipts, cancellation.Token, context));
            }
            var values = evaluated.Results;
            if (current != revision) return;
            answers = values; Editor.ShowWorksheet(values);
            AdoptCurrencyEvaluation(evaluated);
            usesCurrentDate = evaluated.UsesCurrentDate; usesCurrentInstant = evaluated.UsesCurrentInstant;
            usesLocalTimeZone = evaluated.UsesLocalTimeZone; requiresSecondRefresh = evaluated.RequiresSecondRefresh;
            evaluatedLocalZoneVersion = snapshot.LocalZone.Version;
            evaluatedDate = snapshot.Date; evaluatedInstant = snapshot.Instant; RefreshDateSchedule();
            Editor.UpdateLayout();
            DrawResults();
            ShowRoll();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is ArgumentException or ArithmeticException)
        {
            if (current == revision)
            {
                answers = []; Editor.ShowWorksheet([]); DrawResults(); SaveState.Text = e.Message;
                QNotch.Core.Log.Warn("Calculator: sheet not calculated", e);
            }
        }
        finally { if (ReferenceEquals(evaluation, cancellation)) evaluation = null; cancellation.Dispose(); }
    }

    private bool Save()
    {
        if (compositionActive) { saveTimer.Stop(); SaveState.Text = T["finishTextInput"]; return false; }
        saveTimer.Stop(); if (!dirty) return true;
        try
        {
            var generated = uuidSessions[Editor].Session.Snapshot;
            var next = document with { Source = Editor.Text, Version = generated is null ? 1 : 2, GeneratedUuids = generated };
            var library = store.LoadFunctions(); var receipts = restoredReceipts ?? store.LoadFunctionReceipts(document.Id);
            var update = FunctionUpdate.Prepare(next.Source, library, receipts);
            CaptureHistory(false); // Keeps what this save is about to replace.
            if (update.HasChanges || restoredReceipts is not null) store.SaveWithFunctions(next, update); else store.Save(next);
            var refresh = functions.Fingerprint != update.Library.Fingerprint || !functionReceipts.SequenceEqual(update.Receipts);
            document = next; functions = update.Library; functionReceipts = update.Receipts;
            restoredReceipts = null; historyPending = true;
            dirty = false; SaveState.Text = HistoryState; RequestSync();
            host.FunctionsChanged(functions);
            if (refresh) pending = Evaluate();
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException or ArgumentException or FormatException or ArithmeticException)
        { SaveState.Text = T["saveFailed"]; SaveState.ToolTip = e.Message; return false; }
    }

    private void SystemAppearanceChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast) && !Dispatcher.HasShutdownStarted)
            Dispatcher.InvokeAsync(() => ApplyAppearance());
    }
}
