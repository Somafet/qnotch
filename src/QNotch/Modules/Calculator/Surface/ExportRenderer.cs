using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Calc.Documents.Export;

namespace Calc.Windows;

/// <summary>Colours and type for one rendering. Images take the sheet's current theme; paper uses the light palette.</summary>
internal sealed record ExportTheme(Brush Background, Brush Source, Brush Result, Brush Error, Brush Accent, Brush Divider, FontFamily Family, double FontSize, double LineHeight)
{
    internal static ExportTheme FromResources(FrameworkElement owner, FontFamily family, double size)
    {
        Brush Find(string key) => owner.TryFindResource(key) as Brush ?? Brushes.Black;
        return new(Find("CardBrush"), Find("TextPrimaryBrush"), Find("AccentBrush"), Find("TextSecondaryBrush"), Find("WarningBrush"), Find("StrokeBrush"),
            family, size, Math.Ceiling(size * (family.LineSpacing > 0 ? family.LineSpacing : 1.4)));
    }
    internal static ExportTheme Paper(double size, double lineHeight)
    {
        static Brush Hex(string hex) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); brush.Freeze(); return brush; }
        var colors = PdfColors.Paper;
        return new(Brushes.White, Hex(colors.Source), Hex(colors.Result), Hex(colors.Error), Hex("#8B621B"), Hex("#E2E2E2"), new FontFamily("Segoe UI"), size, lineHeight);
    }
}

/// <summary>Draws a <see cref="SheetLayout"/> with WPF: PNG images, printed pages and figure bitmaps for PDF. All work happens on demand on the UI thread;
/// nothing is retained after the export.</summary>
internal static class ExportRenderer
{
    internal const double HeadingScale = 1.25;
    /// <summary>Pixel budget for one image (about 96 MB of BGRA); large sheets render at a lower scale before rows are omitted.</summary>
    internal const double MaxImagePixels = 24_000_000;
    internal const double MaxImageHeight = 12_000;

    private static Typeface Face(ExportTheme theme, LayoutStyle style) => new(theme.Family, FontStyles.Normal,
        style is LayoutStyle.Result or LayoutStyle.Total or LayoutStyle.Heading ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal);
    private static double Size(ExportTheme theme, LayoutStyle style) => style == LayoutStyle.Heading ? theme.FontSize * HeadingScale : theme.FontSize;
    private static Brush Ink(ExportTheme theme, LayoutStyle style) => style switch
    { LayoutStyle.Result or LayoutStyle.Total => theme.Result, LayoutStyle.Error => theme.Error, _ => theme.Source };
    private static FormattedText Text(string text, LayoutStyle style, ExportTheme theme, double pixelsPerDip)
    {
        var formatted = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, Face(theme, style), Size(theme, style), Ink(theme, style), pixelsPerDip);
        if (style is LayoutStyle.Result or LayoutStyle.Total) formatted.SetNumberSubstitution(new NumberSubstitution());
        return formatted;
    }

    internal static Func<string, LayoutStyle, double> Measurer(ExportTheme theme)
    {
        var cache = new Dictionary<(string, LayoutStyle), double>();
        return (text, style) =>
        {
            if (cache.TryGetValue((text, style), out var width)) return width;
            width = Text(text, style, theme, 1).WidthIncludingTrailingWhitespace;
            if (cache.Count > 4096) cache.Clear();
            return cache[(text, style)] = width;
        };
    }

    internal static void DrawPage(DrawingContext context, SheetLayout layout, LayoutPage page, ExportTheme theme, bool background, Func<LayoutFigure, ImageSource?> figure)
    {
        if (background) context.DrawRectangle(theme.Background, null, new Rect(0, 0, layout.Width, page.Height));
        foreach (var item in page.Figures) if (figure(item) is { } image) context.DrawImage(image, new Rect(item.X, item.Top, item.Width, item.Height));
        foreach (var run in page.Runs)
        {
            var text = Text(run.Text, run.Style, theme, 1);
            context.DrawText(text, new Point(run.X, run.Top + (layout.Options.LineHeight - text.Height) / 2));
        }
    }

    /// <summary>One continuous image of the sheet. Width follows the sheet; the result is frozen and owns no visual tree.</summary>
    internal static (BitmapSource Image, int OmittedLines) Image(SheetExport export, ExportTheme theme, double width, bool transparent)
    {
        var options = new LayoutOptions(width, double.PositiveInfinity, 28, theme.LineHeight) { MaxHeight = MaxImageHeight, FigureHeight = SheetFigures.FigureHeight, FigureGap = SheetFigures.FigureGap };
        var layout = SheetLayoutComposer.Compose(export, options, Measurer(theme));
        var page = layout.Pages[0];
        var scale = Math.Min(2, Math.Sqrt(MaxImagePixels / (width * page.Height)));
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.PushTransform(new ScaleTransform(scale, scale));
            DrawPage(context, layout, page, theme, !transparent, item => Figure(item, theme, scale, opaque: false));
        }
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width * scale), (int)Math.Ceiling(page.Height * scale), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze();
        return (bitmap, layout.OmittedLines);
    }

    internal static byte[] Png(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var output = new MemoryStream(); encoder.Save(output); return output.ToArray();
    }

    /// <summary>Applications that read only device-independent bitmaps ignore alpha; give them the image over the sheet background.</summary>
    internal static BitmapSource Flatten(BitmapSource image, Brush background)
    {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            var rect = new Rect(0, 0, image.PixelWidth, image.PixelHeight);
            context.DrawRectangle(background, null, rect); context.DrawImage(image, rect);
        }
        var flat = new RenderTargetBitmap(image.PixelWidth, image.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        flat.Render(visual); flat.Freeze(); return flat;
    }

    /// <summary>A plot or chart drawn by the same element the sheet uses, at <paramref name="scale"/> pixels per layout unit.</summary>
    internal static BitmapSource? Figure(LayoutFigure figure, ExportTheme theme, double scale, bool opaque)
    {
        var view = new FigureView { Width = figure.Width, Height = figure.Height, Ink = theme.Result, Accent = theme.Accent, Muted = theme.Error, Rule = theme.Divider };
        view.Show(figure.Value);
        view.Measure(new Size(figure.Width, figure.Height)); view.Arrange(new Rect(0, 0, figure.Width, figure.Height));
        var pixelWidth = (int)Math.Ceiling(figure.Width * scale); var pixelHeight = (int)Math.Ceiling(figure.Height * scale);
        if (pixelWidth is < 1 or > 8192 || pixelHeight is < 1 or > 8192) return null;
        var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        if (opaque)
        {
            var paper = new DrawingVisual();
            using (var context = paper.RenderOpen()) context.DrawRectangle(theme.Background, null, new Rect(0, 0, figure.Width, figure.Height));
            bitmap.Render(paper);
        }
        bitmap.Render(view); bitmap.Freeze();
        return bitmap;
    }

    /// <summary>RGB samples of a figure over white paper, for PDF image objects.</summary>
    internal static PdfImage? PdfFigure(LayoutFigure figure, ExportTheme paper, double pixelsPerPoint)
    {
        if (Figure(figure, paper, pixelsPerPoint, opaque: true) is not { } bitmap) return null;
        var stride = bitmap.PixelWidth * 4; var bgra = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(bgra, stride, 0);
        var rgb = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 3];
        for (int i = 0, j = 0; i < bgra.Length; i += 4, j += 3) { rgb[j] = bgra[i + 2]; rgb[j + 1] = bgra[i + 1]; rgb[j + 2] = bgra[i]; }
        return new(bitmap.PixelWidth, bitmap.PixelHeight, rgb);
    }

    /// <summary>PDF on A4, or US Letter where that is the regional paper size. Layout uses the embedded fonts' own advances.</summary>
    internal static PdfResult? Pdf(SheetExport export)
    {
        const double size = 10.5, lineHeight = 16, margin = 54, pixelsPerPoint = 2.5;
        var fonts = ExportFonts.Create(size);
        if (fonts is null) return null;
        var letter = RegionInfo.CurrentRegion.TwoLetterISORegionName is "US" or "CA" or "MX" or "PH" or "CL" or "CO" or "VE" or "GT" or "CR" or "PR";
        var (pageWidth, pageHeight) = letter ? (612d, 792d) : (595.276, 841.89);
        var layout = SheetLayoutComposer.Compose(export, new(pageWidth, pageHeight, margin, lineHeight) { FigureHeight = 96, FigureGap = 8, ColumnGap = 18 }, fonts.Measure);
        var paper = ExportTheme.Paper(size, lineHeight);
        return PdfSheetWriter.Write(layout, fonts, PdfColors.Paper, export.Title, figure => PdfFigure(figure, paper, pixelsPerPoint));
    }

    /// <summary>Pages for the Windows print path, laid out for the printer's printable area in device-independent units.</summary>
    internal static DocumentPaginator Paginator(SheetExport export, Size page)
    {
        var theme = ExportTheme.Paper(14, 22);
        var layout = SheetLayoutComposer.Compose(export, new(page.Width, page.Height, 48, theme.LineHeight) { FigureHeight = 128, FigureGap = 10, ColumnGap = 24 }, Measurer(theme));
        return new LayoutPaginator(layout, theme);
    }

    private sealed class LayoutPaginator(SheetLayout layout, ExportTheme theme) : DocumentPaginator
    {
        public override bool IsPageCountValid => true;
        public override int PageCount => layout.Pages.Count;
        public override Size PageSize { get => new(layout.Width, layout.Options.PageHeight); set { } }
        public override IDocumentPaginatorSource? Source => null;
        public override DocumentPage GetPage(int pageNumber)
        {
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen()) DrawPage(context, layout, layout.Pages[pageNumber], theme, false, item => Figure(item, theme, 3, opaque: false));
            var size = PageSize;
            return new DocumentPage(visual, size, new Rect(size), new Rect(size));
        }
    }
}
