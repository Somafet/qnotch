using System.Windows;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace Calc.Windows;

/// <summary>Calc's native WPF source editor, with viewport geometry in UTF-16 source coordinates.</summary>
public sealed partial class SheetEditor : TextEditor
{
    private TextDocument? watchedDocument;
    internal TableColumns Columns { get; }
    internal SheetFigures Figures { get; }
    /// <summary>Presentation of one evaluation; the document is never changed.</summary>
    internal void ShowWorksheet(IReadOnlyList<Calc.Core.LineResult> answers) { Figures.Update(answers); Columns.Update(answers); }
    static SheetEditor()
    {
        DocumentProperty.OverrideMetadata(typeof(SheetEditor), new FrameworkPropertyMetadata(null, null, (_, value) =>
        {
            if (value is TextDocument document && document.TextLength > MaximumCharacters)
                throw new ArgumentException("Sheet exceeds document limit");
            return value;
        }));
    }
    public const int MaximumCharacters = 200_000;
    /// <summary>The engine evaluates and saves at most this many lines; an edit past it is refused like one past the character limit.</summary>
    public const int MaximumLines = Calc.Core.SheetEvaluator.MaxLines;
    /// <summary>Line breaks in <paramref name="text"/>, counted as the document counts them (CRLF, CR or LF).</summary>
    internal static int Breaks(string text)
    {
        var breaks = 0;
        for (var i = 0; i < text.Length; i++)
            if (text[i] == '\r') { breaks++; if (i + 1 < text.Length && text[i + 1] == '\n') i++; }
            else if (text[i] == '\n') breaks++;
        return breaks;
    }
    private bool FitsLines(int removedBreaks, string inserted) => Document.LineCount - removedBreaks + Breaks(inserted) <= MaximumLines;
    public static readonly DependencyProperty CaretBrushProperty = DependencyProperty.Register(nameof(CaretBrush), typeof(Brush), typeof(SheetEditor),
        new PropertyMetadata(Brushes.Black, (sender, e) => ((SheetEditor)sender).TextArea.Caret.CaretBrush = (Brush)e.NewValue));
    public Brush CaretBrush { get => (Brush)GetValue(CaretBrushProperty); set => SetValue(CaretBrushProperty, value); }
    public int CaretIndex => CaretOffset;
    public int VisibleRowCount => TextArea.TextView.VisualLinesValid ? TextArea.TextView.VisualLines.Sum(l => l.TextLines.Count) : 0;
    public bool HasWrappedVisibleLines => TextArea.TextView.VisualLinesValid && TextArea.TextView.VisualLines.Any(l => l.TextLines.Count > 1);
    public new string Text
    {
        get => base.Text;
        set { if (value.Length > MaximumCharacters) throw new ArgumentException("Sheet exceeds document limit"); base.Text = value; }
    }
    public SheetEditor() : base(new SheetTextArea())
    {
        // A composite family supplies breathing room without inserting source blank lines.
        // The baseline splits that room above and below, so selections center on their text.
        var family = new FontFamily { LineSpacing = 1.6, Baseline = 1.2 };
        family.FamilyMaps.Add(new FontFamilyMap { Target = "Segoe UI Variable Text, Segoe UI" });
        FontFamily = family; FontSize = 15;
        BorderThickness = new Thickness(0); Background = Brushes.Transparent;
        VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Disabled;
        TextArea.SelectionBorder = null; TextArea.SelectionCornerRadius = 4;
        TextArea.TextView.LineTransformers.Add(new SheetSyntaxColorizer(this));
        TextArea.TextView.BackgroundRenderers.Add(new SheetTagRenderer(this));
        Figures = new SheetFigures(this); Columns = new TableColumns(this);
        WordWrap = true; ShowLineNumbers = false;
        Options.EnableHyperlinks = false; Options.EnableEmailHyperlinks = false;
        Options.AllowScrollBelowDocument = false;
        Options.ConvertTabsToSpaces = false;
        Options.CutCopyWholeLine = false;
        TextArea.IndentationStrategy = null;
        TextArea.AllowDrop = false;
        Options.EnableRectangularSelection = false;
        WatchDocument();
        DocumentChanged += (_, _) => WatchDocument();
        TextArea.TextEntering += (_, e) =>
        {
            var length = e.Text is "\n" or "\r" or "\r\n" ? TextUtilities.GetNewLineFromDocument(Document, TextArea.Caret.Line).Length : e.Text.Length;
            if (Document.TextLength - SelectionLength + length > MaximumCharacters || !FitsLines(Breaks(SelectedText), e.Text)) e.Handled = true;
        };
        // A sheet is plain text: Tab replaces the selection instead of indenting every selected line.
        CommandManager.AddPreviewExecutedHandler(TextArea, (_, e) =>
        {
            if (e.Command != EditingCommands.TabForward) return;
            TextArea.PerformTextInput("\t");
            e.Handled = true;
        });
        DataObject.AddPastingHandler(TextArea, CheckPaste);
        System.Windows.Automation.AutomationProperties.SetAutomationId(TextArea, "calculator-sheet");
        System.Windows.Automation.AutomationProperties.SetName(TextArea, UiText.Current["sheetExpressions"]);
        RegisterLineCopy();
        RegisterDiceKeys();
    }
    private void CheckPaste(object sender, DataObjectPastingEventArgs e)
    {
        try
        {
            var data = e.DataObject;
            var text = data.GetData(e.FormatToApply) as string ?? data.GetData(DataFormats.UnicodeText) as string ?? data.GetData(DataFormats.Text) as string;
            // Newline normalization can at most halve UTF-16 length (CRLF to LF).
            if (text is null || text.Length > MaximumCharacters * 2) { e.CancelCommand(); return; }
            text = TextUtilities.NormalizeNewLines(Calc.Core.TableSyntax.TryNormalizePaste(text), TextUtilities.GetNewLineFromDocument(Document, TextArea.Caret.Line));
            if (Document.TextLength - SelectionLength + text.Length > MaximumCharacters || !FitsLines(Breaks(SelectedText), text)) { e.CancelCommand(); return; }
            // Discard code-editor rectangular/whole-line metadata before AvalonEdit applies the paste.
            e.DataObject = new DataObject(DataFormats.UnicodeText, text);
            e.FormatToApply = DataFormats.UnicodeText;
        }
        catch (System.Runtime.InteropServices.COMException) { e.CancelCommand(); }
    }
    private void WatchDocument()
    {
        if (watchedDocument is not null) watchedDocument.Changing -= ValidateMutation;
        watchedDocument = Document;
        if (watchedDocument is null) return;
        watchedDocument.UndoStack.SizeLimit = 100;
        watchedDocument.Changing += ValidateMutation;
    }
    private void ValidateMutation(object? sender, DocumentChangeEventArgs change)
    {
        if (watchedDocument is not null && (long)watchedDocument.TextLength - change.RemovalLength + change.InsertionLength > MaximumCharacters)
            throw new ArgumentException("Sheet exceeds document limit");
        if (watchedDocument is not null && change.InsertionLength > 0 && watchedDocument.LineCount - Breaks(change.RemovedText.Text) + Breaks(change.InsertedText.Text) > MaximumLines)
            throw new ArgumentException("Sheet exceeds 10,000 lines");
    }
    public Rect GetRectFromCharacterIndex(int offset)
    {
        if (offset < 0 || offset > Document.TextLength) return Rect.Empty;
        var view = TextArea.TextView;
        view.EnsureVisualLines();
        var location = Document.GetLocation(offset);
        if (view.GetVisualLine(location.Line) is not { } line) return Rect.Empty;
        var position = new TextViewPosition(location);
        var top = view.GetVisualPosition(position, VisualYPosition.LineTop) - view.ScrollOffset;
        // A figure's room hangs below its source text, so a one-row line ends where the text does.
        var bottom = view.GetVisualPosition(position, line.TextLines.Count == 1 && SheetFigures.Holds(line) ? VisualYPosition.TextBottom : VisualYPosition.LineBottom) - view.ScrollOffset;
        var origin = view.TranslatePoint(top, this);
        return new Rect(origin.X, origin.Y, 1, Math.Max(1, bottom.Y - top.Y));
    }
    public int GetCharacterIndexFromPoint(Point point, bool snapToText)
    {
        var view = TextArea.TextView;
        view.EnsureVisualLines();
        var local = TranslatePoint(point, view);
        local.X = Math.Clamp(local.X, 0, Math.Max(0, view.ActualWidth - 1));
        local.Y = Math.Clamp(local.Y, 0, Math.Max(0, view.ActualHeight - 1));
        var position = view.GetPosition(local + view.ScrollOffset);
        if (position is null) return snapToText ? Document.TextLength : -1;
        return Document.GetOffset(position.Value.Location);
    }
    public void ScrollToSourceOffset(int offset) => ScrollToLine(Document.GetLineByOffset(offset).LineNumber);
}
