using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace Calc.Windows;

/// <summary>Draws a chip behind visible tags. Source, caret and selection stay plain text.</summary>
internal sealed class SheetTagRenderer(SheetEditor editor) : IBackgroundRenderer
{
    public KnownLayer Layer => KnownLayer.Background;

    public void Draw(TextView view, DrawingContext context)
    {
        if (!view.VisualLinesValid || editor.TryFindResource("WarningBrush") is not SolidColorBrush tag) return;
        var fill = new SolidColorBrush(Color.FromArgb(0x24, tag.Color.R, tag.Color.G, tag.Color.B));
        var height = editor.FontSize * 1.4;
        try
        {
            foreach (var line in view.VisualLines.Select(visual => visual.FirstDocumentLine).Distinct())
            {
                if (line.Length > 4096) continue;
                foreach (Match match in SheetSyntaxColorizer.AnnotationTags(view.Document.GetText(line)))
                    foreach (var rect in BackgroundGeometryBuilder.GetRectsForSegment(view, new TextSegment { StartOffset = line.Offset + match.Index, Length = match.Length }))
                        context.DrawRoundedRectangle(fill, null, new Rect(Math.Round(rect.X) - 3, Math.Round(rect.Y + (rect.Height - height) / 2), Math.Round(rect.Width) + 6, height), 6, 6);
            }
        }
        catch (RegexMatchTimeoutException) { /* Plain tag text remains readable. */ }
    }
}
