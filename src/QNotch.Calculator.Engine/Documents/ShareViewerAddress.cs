using System.Text.Json;

namespace Calc.Documents;

/// <summary>Where share links point. Calc has no hosted viewer: the default is the static viewer installed beside the app (file://).
/// Someone who hosts the same static files may set <c>share.json</c> in the data directory: <c>{"viewerUrl":"…"}</c> with the https address of that copy.
/// The file is read only when a link is created; nothing watches it and nothing is fetched.</summary>
public static class ShareViewerAddress
{
    public const string FileName = "share.json";
    public const int MaxFileBytes = 4_096;
    public const int MaxUrlCharacters = 2_048;
    private sealed record Settings(string? ViewerUrl);

    /// <summary>Accepts https, file, or http to a loopback host (local testing). Rejects credentials and existing fragments.</summary>
    public static Uri Validate(Uri viewer)
    {
        ArgumentNullException.ThrowIfNull(viewer);
        if (!viewer.IsAbsoluteUri) throw new ShareLinkException("Share viewer address must be absolute");
        var allowed = viewer.Scheme == Uri.UriSchemeHttps || viewer.Scheme == Uri.UriSchemeFile ||
            viewer.Scheme == Uri.UriSchemeHttp && viewer.IsLoopback;
        if (!allowed) throw new ShareLinkException("Share viewer address must use https or file");
        if (viewer.UserInfo.Length > 0) throw new ShareLinkException("Share viewer address must not contain credentials");
        if (viewer.Fragment.Length > 0) throw new ShareLinkException("Share viewer address must not contain a fragment");
        if (viewer.AbsoluteUri.Length > MaxUrlCharacters) throw new ShareLinkException("Share viewer address is too long");
        return viewer;
    }

    /// <summary>The configured viewer, or <paramref name="installed"/> when no setting exists. An invalid setting is an error, not a silent fallback.</summary>
    public static Uri Resolve(string dataDirectory, Uri installed)
    {
        var path = Path.Combine(dataDirectory, FileName);
        if (!File.Exists(path)) return Validate(installed);
        var info = new FileInfo(path);
        if (info.Length > MaxFileBytes) throw new ShareLinkException("share.json is too large");
        Settings? settings;
        try { settings = JsonSerializer.Deserialize<Settings>(File.ReadAllBytes(path), new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }); }
        catch (JsonException) { throw new ShareLinkException("share.json is invalid"); }
        if (settings?.ViewerUrl is not { Length: > 0 } text) return Validate(installed);
        if (!Uri.TryCreate(text, UriKind.Absolute, out var configured)) throw new ShareLinkException("Share viewer address must be absolute");
        return Validate(configured);
    }

    /// <summary>The viewer copied beside the executable at build/publish time.</summary>
    public static Uri Installed(string applicationDirectory) => new(Path.Combine(applicationDirectory, "ShareViewer", "index.html"));
}
