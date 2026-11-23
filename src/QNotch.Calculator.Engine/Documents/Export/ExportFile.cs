using System.Text;

namespace Calc.Documents.Export;

public enum ExportFormat { PlainText, Markdown, Csv, Pdf, Png, TransparentPng }

/// <summary>Writes a finished export beside its destination and moves it into place, so a failed or cancelled write never leaves a partial file
/// under the chosen name. Text is UTF-8; CSV carries a byte-order mark because spreadsheet applications otherwise guess a legacy code page.</summary>
public static class ExportFile
{
    public const long MaxBytes = 256L * 1024 * 1024;

    public static byte[] Encode(ExportFormat format, string text) =>
        format == ExportFormat.Csv ? [.. Encoding.UTF8.Preamble, .. Encoding.UTF8.GetBytes(text)] : Encoding.UTF8.GetBytes(text);

    public static string Extension(ExportFormat format) => format switch
    {
        ExportFormat.PlainText => ".txt", ExportFormat.Markdown => ".md", ExportFormat.Csv => ".csv", ExportFormat.Pdf => ".pdf", _ => ".png"
    };

    /// <summary>A file name from the sheet name: characters Windows forbids become spaces, reserved device names gain a suffix.</summary>
    public static string SuggestedName(string title, ExportFormat format)
    {
        var invalid = Path.GetInvalidFileNameChars().Concat(['<', '>', ':', '"', '/', '\\', '|', '?', '*']).ToHashSet();
        var name = string.Join(' ', new string(title.Select(c => invalid.Contains(c) || char.IsControl(c) ? ' ' : c).ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries)).Trim('.', ' ');
        if (name.Length == 0) name = "Sheet";
        if (name.Length > 120) name = name[..120].TrimEnd('.', ' ');
        var stem = name.Split('.')[0].ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsAsciiDigit(stem[3])) name += " sheet";
        return name + Extension(format);
    }

    public static void Write(string path, byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        if (bytes.LongLength > MaxBytes) throw new ArgumentException("Export exceeds the file size limit");
        var full = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(full) ?? throw new ArgumentException("Invalid export path");
        var temporary = Path.Combine(directory, "." + Path.GetFileName(full) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, full, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
