using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace QNotch.Modules.FileTray;

/// <summary>A parsed HTTP/1.1 request line and headers. <see cref="Path"/> is still percent-encoded; query values are decoded on read.</summary>
public sealed class HttpHead(string method, string path, string query, Dictionary<string, string> headers)
{
    public string Method { get; } = method;
    public string Path { get; } = path;
    public string Query { get; } = query;

    public string? Header(string name) => headers.GetValueOrDefault(name);

    public string? QueryValue(string name)
    {
        foreach (var pair in Query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var key = eq < 0 ? pair : pair[..eq];
            if (key != name) continue;
            return Uri.UnescapeDataString(eq < 0 ? "" : pair[(eq + 1)..]); // invalid escapes stay as they are
        }
        return null;
    }
}

public enum RangeKind { None, Satisfiable, Unsatisfiable }

/// <summary>The pure parts of the phone sharing server (parsing, names, headers), kept apart so they can be tested without sockets.</summary>
public static class PhoneShareHttp
{
    public const int MaxNameLength = 120;

    /// <summary>Request line and headers: the bytes before the blank line. Null when malformed.</summary>
    public static HttpHead? ParseHead(ReadOnlySpan<byte> head)
    {
        var lines = Encoding.Latin1.GetString(head).Split("\r\n"); // one char per byte; browsers percent-encode anything else
        var first = lines[0].Split(' ');
        if (first.Length != 3 || !first[2].StartsWith("HTTP/1.", StringComparison.Ordinal) || first[0].Length == 0) return null;
        var target = first[1];
        if (!target.StartsWith('/')) return null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var l in lines.AsSpan(1))
        {
            var i = l.IndexOf(':');
            if (i <= 0 || l[0] is ' ' or '\t') return null; // no obsolete line folding
            var name = l[..i];
            if (name.AsSpan().ContainsAny(' ', '\t')) return null;
            var value = l[(i + 1)..].Trim();
            // Repeated framing headers are a request smuggling signal: refuse them rather than guess which one counts.
            if (headers.ContainsKey(name) && name.ToLowerInvariant() is "content-length" or "transfer-encoding" or "host") return null;
            headers[name] = headers.TryGetValue(name, out var prev) ? prev + ", " + value : value;
        }
        var q = target.IndexOf('?');
        return q < 0 ? new HttpHead(first[0], target, "", headers) : new HttpHead(first[0], target[..q], target[(q + 1)..], headers);
    }

    /// <summary>
    /// A single <c>bytes=</c> range against a file of <paramref name="length"/> bytes. Anything this server does not support (several
    /// ranges, other units, malformed values) is <see cref="RangeKind.None"/>: the whole file is sent, as the standard allows.
    /// </summary>
    public static RangeKind ParseRange(string? header, long length, out long start, out long end)
    {
        start = 0;
        end = length - 1;
        if (header is null || !header.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) return RangeKind.None;
        var spec = header[6..].Trim();
        if (spec.Contains(',')) return RangeKind.None;
        var dash = spec.IndexOf('-');
        if (dash < 0) return RangeKind.None;
        string a = spec[..dash].Trim(), b = spec[(dash + 1)..].Trim();
        const NumberStyles digits = NumberStyles.None;
        if (a.Length == 0)
        {
            if (!long.TryParse(b, digits, CultureInfo.InvariantCulture, out var suffix)) return RangeKind.None;
            if (suffix == 0 || length == 0) return RangeKind.Unsatisfiable;
            start = Math.Max(0, length - suffix);
            return RangeKind.Satisfiable;
        }
        if (!long.TryParse(a, digits, CultureInfo.InvariantCulture, out var first)) return RangeKind.None;
        long last = long.MaxValue;
        if (b.Length > 0 && (!long.TryParse(b, digits, CultureInfo.InvariantCulture, out last) || last < first)) return RangeKind.None;
        if (first >= length) return RangeKind.Unsatisfiable;
        start = first;
        end = Math.Min(last, length - 1);
        return RangeKind.Satisfiable;
    }

    /// <summary>
    /// A safe file name for an upload: no folders, no characters Windows rejects or that hide the real extension (control and bidi
    /// formatting characters), no device names (CON, NUL, COM1, ...), no trailing dots or spaces, at most 120 characters with the
    /// extension kept. Falls back to "upload".
    /// </summary>
    public static string SanitizeName(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "upload";
        var leaf = raw[(raw.LastIndexOfAny(['/', '\\']) + 1)..];
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(leaf.Length);
        foreach (var c in leaf)
        {
            var cat = char.GetUnicodeCategory(c);
            if (cat is UnicodeCategory.Control or UnicodeCategory.Format) continue;
            sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
        }
        var name = Trim(sb.ToString());
        if (name.Length > MaxNameLength)
        {
            var ext = Path.GetExtension(name);
            if (ext.Length > 16) ext = "";
            var stem = name[..(MaxNameLength - ext.Length)];
            if (char.IsHighSurrogate(stem[^1])) stem = stem[..^1];
            name = Trim(stem) + ext;
        }
        if (name.Length == 0 || name.All(c => c == '.')) return "upload";
        var dot = name.IndexOf('.');
        var device = (dot < 0 ? name : name[..dot]).TrimEnd(' ').ToUpperInvariant();
        if (device is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
            || device.Length == 4 && (device.StartsWith("COM") || device.StartsWith("LPT")) && (char.IsAsciiDigit(device[3]) || device[3] is '¹' or '²' or '³'))
            name = "_" + name;
        return name;

        static string Trim(string s) => s.Trim(' ').TrimEnd('.', ' ');
    }

    /// <summary>Constant-time comparison, so response timing reveals nothing about how much of a guessed token was right.</summary>
    public static bool TokenMatches(string expected, string given)
    {
        var a = Encoding.ASCII.GetBytes(expected);
        var b = Encoding.ASCII.GetBytes(given);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }

    /// <summary>Attachment header with an ASCII fallback and the exact UTF-8 name (RFC 6266 and RFC 5987).</summary>
    public static string ContentDisposition(string name)
    {
        var ascii = new StringBuilder(name.Length);
        foreach (var c in name) ascii.Append(c is >= ' ' and < (char)127 and not '"' and not '\\' and not '%' ? c : '_');
        return $"attachment; filename=\"{ascii}\"; filename*=UTF-8''{Rfc5987(name)}";
    }

    static string Rfc5987(string s)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            if (char.IsAsciiLetterOrDigit((char)b) || "!#$&+-.^_`|~".Contains((char)b)) sb.Append((char)b);
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    public static string MimeType(string name) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".heic" => "image/heic",
        ".svg" => "image/svg+xml",
        ".pdf" => "application/pdf",
        ".txt" or ".log" or ".md" or ".csv" => "text/plain; charset=utf-8",
        ".mp4" or ".m4v" => "video/mp4",
        ".mov" => "video/quicktime",
        ".mp3" => "audio/mpeg",
        ".m4a" => "audio/mp4",
        ".wav" => "audio/wav",
        ".zip" => "application/zip",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".epub" => "application/epub+zip",
        _ => "application/octet-stream",
    };

    public static string Reason(int status) => status switch
    {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        206 => "Partial Content",
        301 => "Moved Permanently",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        410 => "Gone",
        411 => "Length Required",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        _ => "Error",
    };
}
