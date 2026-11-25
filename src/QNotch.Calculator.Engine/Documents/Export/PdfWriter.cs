using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace Calc.Documents.Export;

/// <summary>Minimal PDF 1.7 object writer: numbered objects, Flate streams, a classic cross-reference table and trailer.
/// It knows nothing about sheets; <see cref="PdfSheetWriter"/> builds the document on top of it.</summary>
public sealed class PdfWriter
{
    private readonly List<byte[]?> objects = [];

    public int Reserve() { objects.Add(null); return objects.Count; }
    public int Add(string body) { var id = Reserve(); Set(id, body); return id; }
    public void Set(int id, string body) => objects[id - 1] = Encoding.ASCII.GetBytes(body);
    public int AddStream(string dictionary, byte[] data, bool compress = true)
    {
        var id = Reserve(); SetStream(id, dictionary, data, compress); return id;
    }
    public void SetStream(int id, string dictionary, byte[] data, bool compress = true)
    {
        var payload = compress ? Deflate(data) : data;
        var head = Encoding.ASCII.GetBytes("<< " + dictionary + (compress ? " /Filter /FlateDecode" : "") + " /Length " + payload.Length.ToString(CultureInfo.InvariantCulture) + " >>\nstream\n");
        var tail = Encoding.ASCII.GetBytes("\nendstream");
        var body = new byte[head.Length + payload.Length + tail.Length];
        head.CopyTo(body, 0); payload.CopyTo(body, head.Length); tail.CopyTo(body, head.Length + payload.Length);
        objects[id - 1] = body;
    }

    public byte[] Finish(int catalog, int? info)
    {
        using var output = new MemoryStream();
        void Write(string text) { var bytes = Encoding.ASCII.GetBytes(text); output.Write(bytes); }
        Write("%PDF-1.7\n"); output.Write([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
        var offsets = new long[objects.Count];
        for (var i = 0; i < objects.Count; i++)
        {
            var body = objects[i] ?? throw new InvalidOperationException($"PDF object {i + 1} was reserved but never written");
            offsets[i] = output.Position;
            Write((i + 1).ToString(CultureInfo.InvariantCulture) + " 0 obj\n"); output.Write(body); Write("\nendobj\n");
        }
        var xref = output.Position;
        Write("xref\n0 " + (objects.Count + 1).ToString(CultureInfo.InvariantCulture) + "\n0000000000 65535 f\r\n");
        foreach (var offset in offsets) Write(offset.ToString("D10", CultureInfo.InvariantCulture) + " 00000 n\r\n");
        Write("trailer\n<< /Size " + (objects.Count + 1).ToString(CultureInfo.InvariantCulture) + " /Root " + Ref(catalog) + (info is { } i2 ? " /Info " + Ref(i2) : "") + " >>\nstartxref\n" + xref.ToString(CultureInfo.InvariantCulture) + "\n%%EOF\n");
        return output.ToArray();
    }

    public static string Ref(int id) => id.ToString(CultureInfo.InvariantCulture) + " 0 R";
    public static string Number(double value) => Math.Round(value, 3).ToString("0.###", CultureInfo.InvariantCulture);
    /// <summary>Text string as UTF-16BE with a byte-order mark, which represents any Unicode text.</summary>
    public static string TextString(string text)
    {
        var hex = new StringBuilder("<FEFF");
        foreach (var unit in text) hex.Append(((int)unit).ToString("X4", CultureInfo.InvariantCulture));
        return hex.Append('>').ToString();
    }
    public static byte[] Deflate(byte[] data)
    {
        using var output = new MemoryStream();
        using (var zlib = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(data);
        return output.ToArray();
    }
}
