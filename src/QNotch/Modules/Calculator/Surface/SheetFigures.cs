using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.TextFormatting;
using Calc.Core;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace Calc.Windows;

/// <summary>Empty inline space: the only change a figure or a table makes to source layout. The document never holds it.</summary>
internal sealed class InlineSpace(double width, double height, double baseline, LineBreakCondition breaks, TextRunProperties properties) : TextEmbeddedObject
{
    public override CharacterBufferReference CharacterBufferReference => default;
    public override int Length => 1;
    public override TextRunProperties Properties => properties;
    public override LineBreakCondition BreakBefore => breaks;
    public override LineBreakCondition BreakAfter => breaks;
    public override bool HasFixedSize => true;
    public override TextEmbeddedObjectMetrics Format(double remainingParagraphWidth) => new(width, height, baseline);
    public override Rect ComputeBoundingBox(bool rightToLeft, bool sideways) => new(0, 0, width, height);
    public override void Draw(DrawingContext drawingContext, Point origin, bool rightToLeft, bool sideways) { }
}

/// <summary>Reserves room under a line and keeps a retained figure there. The source row grows downward instead of gaining a visual row,
/// so caret stops, Up/Down, Home/End and hit-testing stay on the source text and the document is never touched.</summary>
internal sealed class SheetFigures : VisualLineElementGenerator
{
    internal const double FigureHeight = 120, FigureGap = 10;
    private readonly SheetEditor editor;
    private readonly Canvas layer = new() { IsHitTestVisible = false };
    private readonly UIElement? selection;
    private Dictionary<DocumentLine, SheetValue> figures = [];
    private readonly Dictionary<DocumentLine, FigureView> views = [];
    private sealed class Spacer(double height) : VisualLineElement(1, 0)
    {
        public override TextRun CreateTextRun(int startVisualColumn, ITextRunConstructionContext context) => new InlineSpace(0, height, 0, LineBreakCondition.BreakRestrained, TextRunProperties);
        public override int GetNextCaretPosition(int visualColumn, LogicalDirection direction, CaretPositioningMode mode) => -1;
        // Otherwise AvalonEdit adds a line-end stop after this element, one dead keypress at the same document offset.
        public override bool HandlesLineBorders => true;
    }
    internal SheetFigures(SheetEditor owner)
    {
        editor = owner; var view = owner.TextArea.TextView;
        view.ElementGenerators.Add(this);
        view.InsertLayer(layer, KnownLayer.Selection, LayerInsertionPosition.Above);
        selection = view.Layers.Cast<UIElement>().FirstOrDefault(element => element.GetType().Name == "SelectionLayer");
        view.VisualLinesChanged += (_, _) => Arrange();
        view.ScrollOffsetChanged += (_, _) => Arrange();
    }
    internal IReadOnlyCollection<FigureView> Visible => views.Values;
    internal static bool Holds(VisualLine line) => line.Elements.OfType<Spacer>().Any();
    internal void Update(IReadOnlyList<LineResult> answers)
    {
        var document = editor.Document; var view = editor.TextArea.TextView; var next = new Dictionary<DocumentLine, SheetValue>();
        if (answers.Count == document.LineCount)
            for (var i = 0; i < answers.Count; i++)
                if (answers[i].Value is { Kind: SheetValueKind.Plot or SheetValueKind.Chart } value) next[document.GetLineByNumber(i + 1)] = value;
        var changed = figures.Keys.Where(line => !next.ContainsKey(line)).Concat(next.Keys.Where(line => !figures.ContainsKey(line))).ToArray();
        figures = next;
        foreach (var line in changed) if (!line.IsDeleted) view.Redraw(line);
        Arrange();
    }
    public override int GetFirstInterestedOffset(int startOffset)
    {
        var line = CurrentContext.VisualLine.FirstDocumentLine;
        return figures.ContainsKey(line) && startOffset <= line.EndOffset ? line.EndOffset : -1;
    }
    public override VisualLineElement ConstructElement(int offset)
    {
        var view = CurrentContext.TextView;
        return new Spacer(view.DefaultLineHeight - view.DefaultBaseline + FigureHeight + FigureGap);
    }
    // Scrolling only moves retained elements; a figure redraws when its value, size or theme changes.
    private void Arrange()
    {
        var view = editor.TextArea.TextView;
        // ScrollToEnd reports an infinite offset until layout clamps it; the visual-line update that follows arranges.
        if (figures.Count == 0 && views.Count == 0 || !view.VisualLinesValid || !double.IsFinite(view.VerticalOffset)) return;
        var shown = new HashSet<DocumentLine>(); var width = Math.Max(0, view.ActualWidth - 2);
        var bands = new GeometryGroup();
        foreach (var line in view.VisualLines)
        {
            if (!figures.TryGetValue(line.FirstDocumentLine, out var value) || !Holds(line)) continue;
            shown.Add(line.FirstDocumentLine);
            if (!views.TryGetValue(line.FirstDocumentLine, out var figure))
            { figure = new FigureView { Height = FigureHeight }; views[line.FirstDocumentLine] = figure; layer.Children.Add(figure); }
            figure.Width = width; figure.Show(value);
            var top = line.VisualTop + line.Height - FigureHeight - FigureGap - view.VerticalOffset;
            Canvas.SetTop(figure, top);
            // One extra pixel, so the row's fractional bottom edge cannot leave an antialiased selection line.
            bands.Children.Add(new RectangleGeometry(new Rect(0, top, view.ActualWidth, FigureHeight + FigureGap + 1)));
        }
        foreach (var line in views.Keys.Where(line => !shown.Contains(line)).ToArray())
        { layer.Children.Remove(views[line]); views.Remove(line); }
        // Selection rectangles span the whole grown row. Keep them on the source text.
        if (selection is not null)
            selection.Clip = bands.Children.Count == 0 ? null : new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(0, 0, view.ActualWidth, view.ActualHeight)), bands);
    }
}
