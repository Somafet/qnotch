import Foundation

enum ExportFormat { case plainText, markdown, csv, pdf, png, transparentPng }

/// Writes a finished export beside its destination and moves it into place, so a failed or cancelled write never leaves a partial file
/// under the chosen name. Text is UTF-8; CSV carries a byte-order mark because spreadsheet applications otherwise guess a legacy code page.
enum ExportFile {
    static let maxBytes: Int64 = 256 * 1024 * 1024

    static func encode(_ format: ExportFormat, _ text: String) -> [UInt8] {
        format == .csv ? [0xEF, 0xBB, 0xBF] + Array(text.utf8) : Array(text.utf8)
    }

    static func `extension`(_ format: ExportFormat) -> String {
        switch format { case .plainText: return ".txt"; case .markdown: return ".md"; case .csv: return ".csv"; case .pdf: return ".pdf"; default: return ".png" }
    }

    /// A file name from the sheet name: characters Windows forbids become spaces, reserved device names gain a suffix. The same name
    /// is suggested on both systems, so an export copied between them keeps its name.
    static func suggestedName(_ title: String, _ format: ExportFormat) -> String {
        let invalid = Set(Array("<>:\"/\\|?*".utf16) + [0])
        let mapped = String(units: title.utf16.map { invalid.contains($0) || NetChar.isControl($0) ? 0x20 : $0 })
        var name = mapped.netSplit(" ").filter { !$0.isEmpty }.joined(separator: " ").netTrim(".", " ")
        if name.isEmpty { name = "Sheet" }
        if name.netLength > 120 { name = name.netSubstring(0, 120).netTrimEnd(".", " ") }
        let stem = name.netSplit(".")[0].netUpper
        let units = Array(stem.utf16)
        if ["CON", "PRN", "AUX", "NUL"].contains(stem) ||
            units.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && NetChar.isAsciiDigit(units[3]) { name += " sheet" }
        return name + `extension`(format)
    }

    static func write(_ path: String, _ bytes: [UInt8]) throws {
        if Int64(bytes.count) > maxBytes { throw CalcError.argument("Export exceeds the file size limit") }
        let full = FolderSync.fullPath(path)
        let directory = (full as NSString).deletingLastPathComponent
        if directory.isEmpty { throw CalcError.argument("Invalid export path") }
        let temporary = (directory as NSString).appendingPathComponent("." + (full as NSString).lastPathComponent + "." + UUID.netNew().netN + ".tmp")
        defer { if NetFile.fileExists(temporary) { try? NetFile.delete(temporary) } }
        try NetFile.writeNew(temporary, bytes)
        try NetFile.move(temporary, full, overwrite: true)
    }
}
