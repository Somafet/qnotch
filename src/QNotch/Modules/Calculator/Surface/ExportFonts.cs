using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using Calc.Documents.Export;

namespace Calc.Windows;

/// <summary>An installed TrueType face behind <see cref="IPdfFontFace"/>. Only faces whose embedding rights permit printable embedding are offered;
/// subsetting uses WPF's own subsetter, which keeps original glyph ids, and falls back to the whole font where the face forbids subsetting.</summary>
internal sealed class GlyphTypefaceFace : IPdfFontFace
{
    private readonly GlyphTypeface face;
    private GlyphTypefaceFace(GlyphTypeface face, string name) { this.face = face; Name = name; }
    public string Name { get; }
    public double Ascent => face.Baseline;
    public double Descent => Math.Max(0, face.Height - face.Baseline);
    public double CapHeight => face.CapsHeight;
    public bool TryGetGlyph(int codePoint, out ushort glyph) => face.CharacterToGlyphMap.TryGetValue(codePoint, out glyph);
    public double Advance(ushort glyph) => face.AdvanceWidths.TryGetValue(glyph, out var width) ? width : 0;
    public (byte[] Program, bool Subset) FontProgram(IReadOnlyCollection<ushort> glyphs)
    {
        if (!NoSubsetting(face.EmbeddingRights)) return (face.ComputeSubset(glyphs.ToArray()), true);
        using var stream = face.GetFontStream(); using var copy = new MemoryStream(); stream.CopyTo(copy);
        return (copy.ToArray(), false);
    }

    private static bool NoSubsetting(FontEmbeddingRight rights) => rights is FontEmbeddingRight.InstallableButNoSubsetting or FontEmbeddingRight.EditableButNoSubsetting or FontEmbeddingRight.PreviewAndPrintButNoSubsetting;
    private static bool Embeddable(FontEmbeddingRight rights) => rights is FontEmbeddingRight.Installable or FontEmbeddingRight.Editable or FontEmbeddingRight.PreviewAndPrint
        || NoSubsetting(rights);

    /// <summary>Null when the family is missing, is not TrueType outlines, comes from a collection whose whole-file program could not be embedded, or forbids embedding.</summary>
    internal static GlyphTypefaceFace? Find(string family, FontWeight weight)
    {
        if (!new Typeface(new FontFamily(family), FontStyles.Normal, weight, FontStretches.Normal).TryGetGlyphTypeface(out var face)) return null;
        // A family name that is not installed resolves to a substitute; accept only the face we asked for.
        if (!face.FamilyNames.Values.Any(name => name.Equals(family, StringComparison.OrdinalIgnoreCase)) && !face.Win32FamilyNames.Values.Any(name => name.Equals(family, StringComparison.OrdinalIgnoreCase))) return null;
        if (!Embeddable(face.EmbeddingRights)) return null;
        if (NoSubsetting(face.EmbeddingRights) && IsCollection(face)) return null;
        var english = CultureInfo.GetCultureInfo("en-US");
        var familyName = face.Win32FamilyNames.TryGetValue(english, out var f) ? f : family;
        var faceName = face.Win32FaceNames.TryGetValue(english, out var n) ? n : "Regular";
        return new(face, familyName + "-" + faceName);
    }
    private static bool IsCollection(GlyphTypeface face)
    {
        using var stream = face.GetFontStream(); Span<byte> tag = stackalloc byte[4];
        return stream.Read(tag) == 4 && tag.SequenceEqual("ttcf"u8);
    }
}

internal static class ExportFonts
{
    // Ordered fallbacks: symbols and maths, then scripts Segoe UI lacks. Faces are looked up only when a PDF is written.
    private static readonly string[] Fallbacks = ["Segoe UI Symbol", "Cambria Math", "Nirmala UI", "Ebrima", "Leelawadee UI", "Gadugi", "Malgun Gothic",
        "Microsoft YaHei UI", "Microsoft JhengHei UI", "Yu Gothic UI", "Segoe UI Historic", "Segoe UI Emoji"];

    /// <summary>Segoe UI for source, Semibold for results and headings, as the editor draws them. Null when Segoe UI cannot be embedded.</summary>
    internal static PdfFontSet? Create(double size)
    {
        var regular = GlyphTypefaceFace.Find("Segoe UI", FontWeights.Normal);
        if (regular is null) return null;
        var bold = GlyphTypefaceFace.Find("Segoe UI", FontWeights.SemiBold);
        var fallbacks = Fallbacks.Select(name => GlyphTypefaceFace.Find(name, FontWeights.Normal)).OfType<GlyphTypefaceFace>();
        return new([regular, .. fallbacks], bold is null ? [] : [bold], size);
    }
}
