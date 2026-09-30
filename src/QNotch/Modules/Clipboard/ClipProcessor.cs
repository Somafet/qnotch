using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;

namespace QNotch.Modules.Clipboard;

/// <summary>Turns raw clipboard content into entries. Runs on the thread pool: classification and image conversion never touch the UI thread.</summary>
internal static class ClipProcessor
{
    public const int MaxImageBytes = 4 << 20;
    const int ThumbWidth = 220;

    static readonly HashSet<string> Keywords = new(StringComparer.Ordinal)
    {
        "function", "def", "class", "import", "using", "namespace", "public", "private", "protected", "static", "const", "let", "var",
        "return", "package", "fn", "struct", "interface", "enum", "export", "async", "await", "#include", "#define", "SELECT", "INSERT",
        "CREATE", "<?php",
    };
    static readonly HashSet<string> Control = new(StringComparer.Ordinal) { "if", "for", "while", "switch", "catch", "foreach" };

    // ---------- text ----------

    public static ClipEntry? FromText(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) return null;
        var kind = Classify(t);
        string preview, meta;
        switch (kind)
        {
            case ClipKind.Link:
                preview = Cut(t, 150);
                meta = "Link" + (Uri.TryCreate(t.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + t : t, UriKind.Absolute, out var u) && u.Host.Length > 0 ? " · " + u.Host : "");
                break;
            case ClipKind.Code:
                var lines = t.Split('\n');
                preview = string.Join('\n', lines.Select(l => l.Trim()).Where(l => l.Length > 1 || !"{}();".Contains(l)).Take(2).Select(l => Cut(l, 80)));
                meta = $"Code · {lines.Length} {(lines.Length == 1 ? "line" : "lines")}";
                break;
            default:
                preview = Cut(Collapse(t), 150);
                meta = $"Text · {t.Length:N0} chars";
                break;
        }
        return new ClipEntry { Kind = kind, Key = text, Text = text, Preview = preview, Line = Cut(preview.Replace('\n', ' '), 60), Meta = meta };
    }

    static string Cut(string s, int max) => s.Length <= max ? s : s[..max].TrimEnd() + "…";

    static string Collapse(string t) =>
        string.Join(' ', (t.Length > 400 ? t[..400] : t).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    public static ClipKind Classify(string t)
    {
        if (t.Length < 2048 && t.IndexOfAny([' ', '\n', '\t', '\r']) < 0 && IsUrl(t)) return ClipKind.Link;
        if (t.Length >= 2 && ((t[0] == '{' && t[^1] == '}') || (t[0] == '[' && t[^1] == ']')) && t.Contains("\":")) return ClipKind.Code;
        if (t.Length > 6 && t[0] == '<' && t[^1] == '>' && (t.Contains("</") || t.Contains("/>"))) return ClipKind.Code;

        int score = 0, indent = 0, lines = 0;
        foreach (var raw in (t.Length > 2000 ? t[..2000] : t).Split('\n'))
        {
            var l = raw.TrimEnd();
            if (l.Length == 0) continue;
            lines++;
            if (l.StartsWith("  ") || l[0] == '\t') indent++;
            var tl = l.Trim();
            if (tl[^1] is ';' or '{' or '}') score++;
            if (tl.StartsWith("//") || tl.StartsWith("/*") || tl.StartsWith("*/") || tl.StartsWith("#!")) score++;
            if (tl.Contains("=>") || tl.Contains("->") || tl.Contains("==") || tl.Contains("!=") || tl.Contains("();") || tl.Contains("){")) score++;
            int i = 0;
            while (i < tl.Length && (char.IsLetterOrDigit(tl[i]) || tl[i] is '#' or '_' or '<' or '?')) i++;
            var word = tl[..i];
            if (Keywords.Contains(word) || (Control.Contains(word) && tl.Length > i && tl.AsSpan(i).TrimStart().StartsWith("("))) score += 2;
        }
        score += indent / 2;
        return score >= 3 && score >= lines / 2 ? ClipKind.Code : ClipKind.Text;
    }

    static bool IsUrl(string t) =>
        t.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || t.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
        || t.StartsWith("www.", StringComparison.OrdinalIgnoreCase) && t.Contains('.', StringComparison.Ordinal) && t.Length > 6
        || t.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase) || t.StartsWith("file://", StringComparison.OrdinalIgnoreCase);

    // ---------- images ----------

    /// <summary>DIB bytes (CF_DIB) to an image entry, or null when the PNG would exceed the 4 MB cap.</summary>
    public static ClipEntry? FromDib(byte[] dib)
    {
        var src = DibSource(dib) ?? DecodedBmp(dib);
        if (src is null) return null;
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(src));
        using var ms = new MemoryStream();
        enc.Save(ms);
        if (ms.Length > MaxImageBytes) return null;
        var png = ms.ToArray();

        var thumb = new BitmapImage();
        thumb.BeginInit();
        thumb.StreamSource = new MemoryStream(png);
        thumb.DecodePixelWidth = Math.Min(ThumbWidth, src.PixelWidth);
        thumb.CacheOption = BitmapCacheOption.OnLoad;
        thumb.EndInit();
        thumb.Freeze();

        var key = Convert.ToHexString(SHA256.HashData(dib.AsSpan(0, Math.Min(dib.Length, 1 << 20))))[..16] + dib.Length;
        return new ClipEntry
        {
            Kind = ClipKind.Image, Key = key, Png = png, Thumb = thumb, Preview = "Image", Line = $"Image · {src.PixelWidth} x {src.PixelHeight}",
            Meta = $"Image · {src.PixelWidth} x {src.PixelHeight} · {Size(png.Length)}",
        };
    }

    static string Size(long b) => b >= 1 << 20 ? $"{b / 1048576.0:0.0} MB" : $"{Math.Max(1, b / 1024)} KB";

    /// <summary>Common case (plain 24 or 32 bit, no palette): pixels straight from the DIB, no BMP copy and no decoder pass.</summary>
    static unsafe BitmapSource? DibSource(byte[] dib)
    {
        if (dib.Length < 52) return null;
        int hdr = BinaryPrimitives.ReadInt32LittleEndian(dib), w = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(4)), h = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(8));
        int bits = BinaryPrimitives.ReadInt16LittleEndian(dib.AsSpan(14)), comp = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(16)), used = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(32));
        if (hdr != 40 || w <= 0 || h == 0 || used != 0 || bits is not (24 or 32)) return null;
        int offset = 40;
        if (comp == 3) // BI_BITFIELDS: only the standard BGR masks
        {
            if (bits != 32 || BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(40)) != 0xFF0000 || BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(44)) != 0xFF00
                || BinaryPrimitives.ReadUInt32LittleEndian(dib.AsSpan(48)) != 0xFF) return null;
            offset = 52;
        }
        else if (comp != 0) return null;
        int rows = Math.Abs(h), stride = (w * bits / 8 + 3) & ~3;
        if ((long)stride * rows > dib.Length - offset) return null;
        BitmapSource src;
        fixed (byte* p = &dib[offset])
            src = BitmapSource.Create(w, rows, 96, 96, bits == 32 ? PixelFormats.Bgr32 : PixelFormats.Bgr24, null, (nint)p, stride * rows, stride);
        return h > 0 ? new TransformedBitmap(src, new ScaleTransform(1, -1)) : src;
    }

    /// <summary>Fallback for palettes, bit fields and other layouts: wrap the DIB in a BMP file header and let WIC decode it.</summary>
    static BitmapSource? DecodedBmp(byte[] dib)
    {
        var bmp = BmpFile(dib);
        if (bmp is null) return null;
        var frame = BitmapDecoder.Create(new MemoryStream(bmp), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        return frame.Format == PixelFormats.Bgr32 ? frame : new FormatConvertedBitmap(frame, PixelFormats.Bgr32, null, 0);
    }

    static byte[]? BmpFile(byte[] dib)
    {
        int hdr = BinaryPrimitives.ReadInt32LittleEndian(dib);
        if (hdr < 40 || hdr > dib.Length) return null;
        int bits = BinaryPrimitives.ReadInt16LittleEndian(dib.AsSpan(14));
        int compression = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(16));
        int used = BinaryPrimitives.ReadInt32LittleEndian(dib.AsSpan(32));
        int offset = 14 + hdr + (compression == 3 && hdr == 40 ? 12 : 0) + (used > 0 ? used * 4 : bits <= 8 ? (1 << bits) * 4 : 0);
        var bmp = new byte[14 + dib.Length];
        bmp[0] = (byte)'B'; bmp[1] = (byte)'M';
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(2), bmp.Length);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(10), offset);
        dib.CopyTo(bmp, 14);
        return bmp;
    }

    /// <summary>Decodes stored PNG bytes into a bottom-up 32 bit DIB for CF_DIB.</summary>
    public static byte[] PngToDib(byte[] png)
    {
        var frame = BitmapDecoder.Create(new MemoryStream(png), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
        var src = new FormatConvertedBitmap(frame, PixelFormats.Bgr32, null, 0);
        int w = src.PixelWidth, h = src.PixelHeight, stride = w * 4;
        var px = new byte[stride * h];
        src.CopyPixels(px, stride, 0);
        var dib = new byte[40 + px.Length];
        BinaryPrimitives.WriteInt32LittleEndian(dib, 40);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(4), w);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(8), h);
        BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(12), 1);
        BinaryPrimitives.WriteInt16LittleEndian(dib.AsSpan(14), 32);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(20), px.Length);
        for (int y = 0; y < h; y++) Buffer.BlockCopy(px, y * stride, dib, 40 + (h - 1 - y) * stride, stride);
        return dib;
    }
}
