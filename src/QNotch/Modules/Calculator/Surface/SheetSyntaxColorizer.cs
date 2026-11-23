using System.Text.RegularExpressions;
using Calc.Core;
using System.Windows;
using System.Windows.Media;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Rendering;

namespace Calc.Windows;

/// <summary>Display-only accents: no parsing, source replacement or document-wide work on a render.</summary>
internal sealed class SheetSyntaxColorizer(SheetEditor editor) : DocumentColorizingTransformer
{
    internal const double HeadingScale = 1.25;
    internal static readonly Regex Tags = new(@"#[\p{L}_][\p{L}\p{M}\p{N}_]*", RegexOptions.Compiled | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(20));
    private static readonly Regex Accents = new(@"(?<comment>//.*$)|(?<quoted>""(?:\\.|[^""\\])*(?:""|$))|(?<tag>#[\p{L}_][\p{L}\p{M}\p{N}_]*)|(?<reference>\bL[1-9][0-9]*\b|\bprev\b)|(?<keyword>\b(?:in|to|until|sum|total|average)\b)|(?<operator>(?<=\s)[-+*/×÷^](?=\s))",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(20));

    internal static IEnumerable<Match> AnnotationTags(string text)
    {
        var raw = TextSyntax.RawPayloadStart(text);
        return Accents.Matches(text).Cast<Match>().Where(match => match.Groups["tag"].Success && DeveloperSyntax.ColourLiteralLength(text, match.Index) == 0 && (raw < 0 || match.Index < raw));
    }

    protected override void ColorizeLine(DocumentLine line)
    {
        // Very long lines retain plain text; highlighting must never dominate editing cost.
        if (line.Length > 4096) return;
        var text = CurrentContext.Document.GetText(line);
        var trimmed = text.TrimStart();
        if (trimmed.StartsWith("# ", StringComparison.Ordinal))
        {
            ChangeLinePart(line.Offset, line.EndOffset, element =>
            {
                element.TextRunProperties.SetTypeface(new Typeface(editor.FontFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal));
                element.TextRunProperties.SetFontRenderingEmSize(editor.FontSize * HeadingScale);
            });
            // The marker stays editable source; only the title carries the heading's weight.
            if (editor.TryFindResource("TextSecondaryBrush") is Brush marker)
            {
                var start = line.Offset + text.Length - trimmed.Length;
                ChangeLinePart(start, start + 1, element => element.TextRunProperties.SetForegroundBrush(marker));
            }
            return;
        }
        try
        {
            var raw = TextSyntax.RawPayloadStart(text);
            foreach (Match match in Accents.Matches(text))
            {
                if (raw >= 0 && match.Index >= raw || match.Groups["tag"].Success && DeveloperSyntax.ColourLiteralLength(text, match.Index) > 0) continue;
                var key = match.Groups["comment"].Success || match.Groups["operator"].Success ? "TextSecondaryBrush" :
                    match.Groups["tag"].Success ? "WarningBrush" : match.Groups["quoted"].Success ? "TextPrimaryBrush" : "AccentBrush";
                if (editor.TryFindResource(key) is not Brush brush) continue;
                ChangeLinePart(line.Offset + match.Index, line.Offset + match.Index + match.Length,
                    element => element.TextRunProperties.SetForegroundBrush(brush));
            }
        }
        catch (RegexMatchTimeoutException) { /* Plain source remains editable. */ }
    }
}
