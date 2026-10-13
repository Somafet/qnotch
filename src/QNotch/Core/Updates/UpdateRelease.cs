using System.Text.Json;

namespace QNotch.Core.Updates;

/// <summary>Only stable releases and the exact assets built by our release workflow are eligible.</summary>
internal sealed record UpdateRelease(Version Version, string Tag, Uri Download, long Size, string Sha256, bool IsZip)
{
    public const string Repository = "https://github.com/Somafet/qnotch";
    public const long MaxDownloadSize = 256 * 1024 * 1024;
    public static string DisplayVersion(Version version) => version.ToString(version.Revision > 0 ? 4 : 3);

    public static Version? ParseVersion(string? text)
    {
        text = text?.Trim().TrimStart('v', 'V').Split('+')[0];
        return Version.TryParse(text, out var v) && v.Major >= 0
            ? new Version(v.Major, v.Minor, Math.Max(0, v.Build), Math.Max(0, v.Revision)) : null;
    }

    public static UpdateRelease? Read(string json, Version installed, bool selfContained)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        var version = ParseVersion(tag);
        if (version is null || version <= installed) return null;
        var name = selfContained ? "QNotch-self-contained.zip" : "QNotch.exe";
        foreach (var asset in root.GetProperty("assets").EnumerateArray())
        {
            if (asset.GetProperty("name").GetString() != name || asset.GetProperty("state").GetString() != "uploaded") continue;
            var expected = $"{Repository}/releases/download/{Uri.EscapeDataString(tag)}/{name}";
            if (!Uri.TryCreate(asset.GetProperty("browser_download_url").GetString(), UriKind.Absolute, out var url)
                || !string.Equals(url.AbsoluteUri, expected, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The release download is not from the QNotch repository.");
            var size = asset.GetProperty("size").GetInt64();
            var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() : null;
            if (size is <= 0 or > MaxDownloadSize || digest is null || !digest.StartsWith("sha256:", StringComparison.Ordinal)
                || digest.Length != 71 || !digest.AsSpan(7).ToString().All(Uri.IsHexDigit))
                throw new InvalidDataException("This release has no valid download size or SHA-256 checksum.");
            return new(version, tag, url, size, digest[7..], selfContained);
        }
        throw new InvalidDataException("This release does not have a download for your QNotch installation yet.");
    }
}
