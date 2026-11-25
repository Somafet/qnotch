import Foundation

/// Files Calc shipped beside its executable. They travel as package resources (Resources/Assets and Resources/THIRD-PARTY-NOTICES.txt)
/// and are written under the calculator data folder the first time something needs a real path (a browser opening help or a share link).
/// Help, interface strings and the share viewer are byte copies of the Windows engine's assets; the notices file lists what the Mac
/// engine ships.
enum CalculatorAssets {
    static let viewerFiles = ["index.html", "viewer.css", "viewer.js", "codec.js"]

    /// A bundled asset by its path under Resources, e.g. "Assets/Help.html".
    static func bytes(_ resource: String) throws -> [UInt8] {
        let folder = ("Resources/" + resource as NSString).deletingLastPathComponent
        guard let url = Bundle.module.url(forResource: (resource as NSString).lastPathComponent, withExtension: nil, subdirectory: folder) else {
            throw DocumentError.fileNotFound("Missing resource " + resource)
        }
        return try NetFile.readAll(url.path)
    }

    /// The interface strings (C#'s Calc.UiStrings resource), read by the host's UI.
    static var uiStrings: [UInt8] { get throws { try bytes("Assets/UiStrings.json") } }

    /// Writes a file only when its content differs, through a temp file, so an open browser tab never reads a half-written one.
    static func writeIfChanged(_ path: String, _ content: [UInt8]) throws {
        try NetFile.createDirectory((path as NSString).deletingLastPathComponent)
        let info = NetFile.info(path)
        if info.exists && !info.isDirectory && info.length == Int64(content.count) { if try NetFile.readAll(path) == content { return } }
        let temp = path + ".tmp"
        try NetFile.writeAll(temp, content)
        try NetFile.move(temp, path, overwrite: true)
    }

    /// The static share viewer folder's index.html, written out on demand.
    static func writeShareViewer(_ dataDirectory: String) throws -> String {
        let folder = (dataDirectory as NSString).appendingPathComponent("ShareViewer")
        for file in viewerFiles { try writeIfChanged((folder as NSString).appendingPathComponent(file), try bytes("Assets/ShareViewer/" + file)) }
        return (folder as NSString).appendingPathComponent("index.html")
    }

    static func writeHelp(_ dataDirectory: String) throws -> String {
        let path = (dataDirectory as NSString).appendingPathComponent("Help.html")
        try writeIfChanged(path, try bytes("Assets/Help.html"))
        return path
    }

    static func writeNotices(_ dataDirectory: String) throws -> String {
        let path = (dataDirectory as NSString).appendingPathComponent("THIRD-PARTY-NOTICES.txt")
        try writeIfChanged(path, try bytes("THIRD-PARTY-NOTICES.txt"))
        return path
    }
}
