using System.Globalization;
using System.Text;

namespace Calc.Documents.Export;

/// <summary>A TrueType face the renderer can embed. Metrics are fractions of the em. The program is either a subset that keeps original glyph ids
/// or, when subsetting is not permitted, the complete font.</summary>
public interface IPdfFontFace
{
    string Name { get; }
    double Ascent { get; }
    double Descent { get; }
    double CapHeight { get; }
    bool TryGetGlyph(int codePoint, out ushort glyph);
    double Advance(ushort glyph);
    (byte[] Program, bool Subset) FontProgram(IReadOnlyCollection<ushort> glyphs);
}

public sealed record PdfColors(string Source, string Result, string Error, string Heading)
{
    public static PdfColors Paper { get; } = new("#2B2D2A", "#06717D", "#696C67", "#2B2D2A");
}
public sealed record PdfImage(int PixelWidth, int PixelHeight, byte[] Rgb);
public sealed record PdfResult(byte[] Bytes, int Pages, int MissingCharacters);

/// <summary>Primary faces with ordered fallbacks. Each code point uses the first face that maps it, so measurement and drawing agree.
/// There is no shaping: complex scripts that need contextual forms or reordering are drawn with their nominal glyphs.
/// Code points no face maps are drawn as the primary face's missing-glyph box and counted.</summary>
public sealed class PdfFontSet(IReadOnlyList<IPdfFontFace> regular, IReadOnlyList<IPdfFontFace> bold, double size)
{
    public double Size { get; } = size > 0 && size < 200 ? size : throw new ArgumentOutOfRangeException(nameof(size));
    private readonly IReadOnlyList<IPdfFontFace> regularFaces = regular.Count > 0 ? regular : throw new ArgumentException("A regular face is required");
    private readonly IReadOnlyList<IPdfFontFace> boldFaces = [.. bold, .. regular.Skip(bold.Count > 0 ? 1 : 0)];
    public IPdfFontFace Primary => regularFaces[0];

    /// <summary>Headings are drawn larger, as in the editor.</summary>
    public double HeadingScale { get; init; } = 1.25;
    public static bool IsBold(LayoutStyle style) => style is LayoutStyle.Heading or LayoutStyle.Result or LayoutStyle.Total;
    public double SizeOf(LayoutStyle style) => style == LayoutStyle.Heading ? Size * HeadingScale : Size;
    public double Measure(string text, LayoutStyle style) => Glyphs(text, IsBold(style)).Sum(g => g.Advance) * SizeOf(style);

    internal readonly record struct Glyph(IPdfFontFace Face, ushort Id, double Advance, string Text, bool Missing);
    internal IEnumerable<Glyph> Glyphs(string text, bool bold)
    {
        var faces = bold ? boldFaces : regularFaces;
        foreach (var rune in text.EnumerateRunes())
        {
            var value = rune.Value == '\t' ? ' ' : rune.Value;
            if (value < 0x20 || value is >= 0x7F and < 0xA0) continue;
            IPdfFontFace? found = null; ushort id = 0;
            foreach (var face in faces) if (face.TryGetGlyph(value, out id) && id != 0) { found = face; break; }
            if (found is not null) { yield return new(found, id, found.Advance(id), rune.ToString(), false); continue; }
            // Joiners, selectors and other format characters have no visible form; only visible characters count as missing.
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Format or UnicodeCategory.NonSpacingMark || value is >= 0xFE00 and <= 0xFE0F) continue;
            yield return new(faces[0], 0, faces[0].Advance(0), rune.ToString(), true);
        }
    }
}

/// <summary>Writes a laid-out sheet as PDF: Type0/CIDFontType2 fonts with Identity-H glyph codes, embedded TrueType programs, a ToUnicode map
/// so copied and searched text recovers the source characters, and figures as Flate-compressed RGB images. The output is not a tagged PDF.</summary>
public static class PdfSheetWriter
{
    public static PdfResult Write(SheetLayout layout, PdfFontSet fonts, PdfColors colors, string title, Func<LayoutFigure, PdfImage?>? figures = null)
    {
        ArgumentNullException.ThrowIfNull(layout); ArgumentNullException.ThrowIfNull(fonts); ArgumentNullException.ThrowIfNull(colors);
        if (layout.Options.Continuous) throw new ArgumentException("PDF needs a paged layout");
        var pdf = new PdfWriter();
        var catalog = pdf.Reserve(); var pagesId = pdf.Reserve(); var resources = pdf.Reserve();
        var faces = new Dictionary<IPdfFontFace, (string Resource, SortedDictionary<ushort, (double Advance, string Text)> Glyphs)>(ReferenceEqualityComparer.Instance);
        var images = new List<(string Resource, int Id)>();
        var pageIds = new List<int>(); var missing = 0;
        var primary = fonts.Primary; var lineHeight = layout.Options.LineHeight;
        double Baseline(double size) => (lineHeight - (primary.Ascent + primary.Descent) * size) / 2 + primary.Ascent * size;
        var height = layout.Options.PageHeight;
        foreach (var page in layout.Pages)
        {
            var content = new StringBuilder();
            foreach (var figure in page.Figures)
            {
                if (figures?.Invoke(figure) is not { } image) continue;
                if (image.PixelWidth <= 0 || image.PixelHeight <= 0 || image.Rgb.Length != image.PixelWidth * image.PixelHeight * 3) throw new ArgumentException("Invalid figure image");
                var resource = "Im" + (images.Count + 1).ToString(CultureInfo.InvariantCulture);
                images.Add((resource, pdf.AddStream($"/Type /XObject /Subtype /Image /Width {image.PixelWidth} /Height {image.PixelHeight} /ColorSpace /DeviceRGB /BitsPerComponent 8", image.Rgb)));
                content.Append("q ").Append(PdfWriter.Number(figure.Width)).Append(" 0 0 ").Append(PdfWriter.Number(figure.Height)).Append(' ')
                    .Append(PdfWriter.Number(figure.X)).Append(' ').Append(PdfWriter.Number(height - figure.Top - figure.Height)).Append(" cm /").Append(resource).Append(" Do Q\n");
            }
            content.Append("BT\n");
            foreach (var run in page.Runs)
            {
                content.Append(Color(run.Style switch { LayoutStyle.Result or LayoutStyle.Total => colors.Result, LayoutStyle.Error => colors.Error, LayoutStyle.Heading => colors.Heading, _ => colors.Source }));
                var size = fonts.SizeOf(run.Style);
                var x = run.X; var y = height - run.Top - Baseline(size);
                IPdfFontFace? current = null; var hex = new StringBuilder();
                void Flush()
                {
                    if (current is null || hex.Length == 0) return;
                    content.Append('/').Append(faces[current].Resource).Append(' ').Append(PdfWriter.Number(size)).Append(" Tf 1 0 0 1 ")
                        .Append(PdfWriter.Number(x)).Append(' ').Append(PdfWriter.Number(y)).Append(" Tm <").Append(hex).Append("> Tj\n");
                    hex.Clear();
                }
                var segmentX = x;
                foreach (var glyph in fonts.Glyphs(run.Text, PdfFontSet.IsBold(run.Style)))
                {
                    if (glyph.Missing) missing++;
                    if (!faces.TryGetValue(glyph.Face, out var used))
                        faces[glyph.Face] = used = ("F" + (faces.Count + 1).ToString(CultureInfo.InvariantCulture), new());
                    if (!used.Glyphs.ContainsKey(glyph.Id)) used.Glyphs[glyph.Id] = (glyph.Advance, glyph.Missing ? "\uFFFD" : glyph.Text);
                    if (!ReferenceEquals(current, glyph.Face)) { Flush(); x = segmentX; current = glyph.Face; }
                    hex.Append(glyph.Id.ToString("X4", CultureInfo.InvariantCulture));
                    segmentX += glyph.Advance * size;
                }
                Flush();
            }
            content.Append("ET\n");
            var contents = pdf.AddStream("", Encoding.ASCII.GetBytes(content.ToString()));
            pageIds.Add(pdf.Add($"<< /Type /Page /Parent {PdfWriter.Ref(pagesId)} /MediaBox [0 0 {PdfWriter.Number(layout.Width)} {PdfWriter.Number(height)}] /Resources {PdfWriter.Ref(resources)} /Contents {PdfWriter.Ref(contents)} >>"));
        }
        var fontEntries = new StringBuilder();
        foreach (var (face, (resource, glyphs)) in faces)
        {
            if (!glyphs.ContainsKey(0)) glyphs[0] = (face.Advance(0), "\uFFFD");
            var (program, subset) = face.FontProgram(glyphs.Keys.ToArray());
            var name = (subset ? Tag(face.Name, glyphs.Keys) + "+" : "") + PostScriptName(face.Name);
            var file = pdf.AddStream("/Length1 " + program.Length.ToString(CultureInfo.InvariantCulture), program);
            var descriptor = pdf.Add($"<< /Type /FontDescriptor /FontName /{name} /Flags 32 /FontBBox [-1000 {PdfWriter.Number(-face.Descent * 1000)} 2000 {PdfWriter.Number(face.Ascent * 1000)}] /ItalicAngle 0 " +
                $"/Ascent {PdfWriter.Number(face.Ascent * 1000)} /Descent {PdfWriter.Number(-face.Descent * 1000)} /CapHeight {PdfWriter.Number(face.CapHeight * 1000)} /StemV 80 /FontFile2 {PdfWriter.Ref(file)} >>");
            var widths = new StringBuilder();
            foreach (var (id, (advance, _)) in glyphs) widths.Append(id.ToString(CultureInfo.InvariantCulture)).Append(" [").Append(PdfWriter.Number(advance * 1000)).Append("] ");
            var cid = pdf.Add($"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{name} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " +
                $"/FontDescriptor {PdfWriter.Ref(descriptor)} /DW 1000 /W [{widths}] /CIDToGIDMap /Identity >>");
            var unicode = pdf.AddStream("", Encoding.ASCII.GetBytes(ToUnicode(glyphs)));
            var font = pdf.Add($"<< /Type /Font /Subtype /Type0 /BaseFont /{name} /Encoding /Identity-H /DescendantFonts [{PdfWriter.Ref(cid)}] /ToUnicode {PdfWriter.Ref(unicode)} >>");
            fontEntries.Append('/').Append(resource).Append(' ').Append(PdfWriter.Ref(font)).Append(' ');
        }
        var xobjects = images.Count == 0 ? "" : " /XObject << " + string.Concat(images.Select(image => "/" + image.Resource + " " + PdfWriter.Ref(image.Id) + " ")) + ">>";
        pdf.Set(resources, $"<< /ProcSet [/PDF /Text /ImageC] /Font << {fontEntries}>>{xobjects} >>");
        pdf.Set(pagesId, $"<< /Type /Pages /Kids [{string.Join(' ', pageIds.Select(PdfWriter.Ref))}] /Count {pageIds.Count} >>");
        pdf.Set(catalog, $"<< /Type /Catalog /Pages {PdfWriter.Ref(pagesId)} /ViewerPreferences << /DisplayDocTitle true >> >>");
        var info = pdf.Add($"<< /Title {PdfWriter.TextString(title)} /Producer {PdfWriter.TextString("Calc")} >>");
        return new(pdf.Finish(catalog, info), pageIds.Count, missing);
    }

    private static string Color(string hex)
    {
        var c = hex.TrimStart('#');
        if (c.Length != 6 || !int.TryParse(c, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb)) throw new ArgumentException("Colours are #RRGGBB");
        return PdfWriter.Number(((rgb >> 16) & 255) / 255d) + " " + PdfWriter.Number(((rgb >> 8) & 255) / 255d) + " " + PdfWriter.Number((rgb & 255) / 255d) + " rg\n";
    }

    internal static string ToUnicode(SortedDictionary<ushort, (double Advance, string Text)> glyphs)
    {
        var map = new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" +
            "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        foreach (var chunk in glyphs.Where(g => g.Key != 0).Chunk(100))
        {
            map.Append(chunk.Length.ToString(CultureInfo.InvariantCulture)).Append(" beginbfchar\n");
            foreach (var (id, (_, text)) in chunk)
            {
                map.Append('<').Append(id.ToString("X4", CultureInfo.InvariantCulture)).Append("> <");
                foreach (var unit in text) map.Append(((int)unit).ToString("X4", CultureInfo.InvariantCulture));
                map.Append(">\n");
            }
            map.Append("endbfchar\n");
        }
        return map.Append("endcmap\nCMapName currentdict /CMapResource defineresource pop\nend\nend\n").ToString();
    }

    private static string PostScriptName(string name)
    {
        var clean = new string(name.Where(c => c is > ' ' and < '\x7F' && "()<>[]{}/%#".IndexOf(c) < 0).ToArray());
        return clean.Length == 0 ? "Font" : clean.Length > 63 ? clean[..63] : clean;
    }
    // A subset tag is six capital letters; derive it from the glyph set so identical exports are byte-identical.
    private static string Tag(string name, IEnumerable<ushort> glyphs)
    {
        var hash = 2166136261u;
        foreach (var c in name) hash = (hash ^ c) * 16777619u;
        foreach (var g in glyphs) hash = (hash ^ g) * 16777619u;
        var tag = new char[6];
        for (var i = 0; i < 6; i++) { tag[i] = (char)('A' + hash % 26); hash /= 26; }
        return new string(tag);
    }
}
