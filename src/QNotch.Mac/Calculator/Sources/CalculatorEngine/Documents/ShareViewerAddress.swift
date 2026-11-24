import Foundation

/// Where share links point. Calc has no hosted viewer: the default is the static viewer installed with the app (file://).
/// Someone who hosts the same static files may set `share.json` in the data directory: `{"viewerUrl":"…"}` with the https address of
/// that copy. The file is read only when a link is created; nothing watches it and nothing is fetched.
enum ShareViewerAddress {
    static let fileName = "share.json"
    static let maxFileBytes = 4_096
    static let maxUrlCharacters = 2_048

    /// Accepts https, file, or http to a loopback host (local testing). Rejects credentials and existing fragments.
    static func validate(_ viewer: URL) throws -> URL {
        guard let scheme = viewer.scheme?.lowercased(), !scheme.isEmpty else { throw DocumentError.shareLink("Share viewer address must be absolute") }
        let allowed = scheme == "https" || scheme == "file" || scheme == "http" && isLoopback(viewer)
        if !allowed { throw DocumentError.shareLink("Share viewer address must use https or file") }
        if viewer.user != nil || viewer.password != nil { throw DocumentError.shareLink("Share viewer address must not contain credentials") }
        if viewer.fragment != nil { throw DocumentError.shareLink("Share viewer address must not contain a fragment") }
        if viewer.absoluteString.netLength > maxUrlCharacters { throw DocumentError.shareLink("Share viewer address is too long") }
        return viewer
    }

    /// `Uri.IsLoopback`: localhost, 127.0.0.0/8 or ::1.
    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The configured viewer, or `installed` when no setting exists. An invalid setting is an error, not a silent fallback.
    static func resolve(_ dataDirectory: String, _ installed: URL) throws -> URL {
        let path = (dataDirectory as NSString).appendingPathComponent(fileName)
        if !NetFile.fileExists(path) { return try validate(installed) }
        if NetFile.info(path).length > Int64(maxFileBytes) { throw DocumentError.shareLink("share.json is too large") }
        var viewerUrl: String?
        do {
            // JsonSerializer with camelCase names: {"viewerUrl": "…"}; a JSON null is no setting.
            if let settings = try NetJSON.parseObject(try NetFile.readAll(path)) { viewerUrl = try settings.string("viewerUrl") }
        } catch let e where e.isJsonError { throw DocumentError.shareLink("share.json is invalid") }
        guard let text = viewerUrl, !text.isEmpty else { return try validate(installed) }
        guard let configured = URL(string: text), configured.scheme != nil else { throw DocumentError.shareLink("Share viewer address must be absolute") }
        return try validate(configured)
    }

    /// The viewer installed with the app.
    static func installed(_ applicationDirectory: String) -> URL {
        URL(fileURLWithPath: ((applicationDirectory as NSString).appendingPathComponent("ShareViewer") as NSString).appendingPathComponent("index.html"))
    }
}
