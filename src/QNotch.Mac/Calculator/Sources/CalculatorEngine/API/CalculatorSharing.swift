import Foundation

// Share links, imports and exports for the Mac app (C# ShareLink, SheetImport, SheetExport and SheetLayout), over the same
// engine code Windows uses, so a link, an export or an imported sheet reads the same on both systems.

/// Frozen browser links to a sheet (C# ShareLink). The whole sheet travels in the link's fragment, which browsers never send to a
/// server; the viewer is the static page the app writes into its data folder, or the address `share.json` names.
public enum CalculatorShareLink {
    /// Builds the link for what the sheet shows. `evaluation` must belong to `source` (pass nil while it is still being evaluated: the
    /// link then holds the text without answers). `explain` gives a line's explanation text; nil uses the engine's plain steps.
    public static func create(store: CalculatorDocumentStore, title: String, source: String, evaluation: CalculatorEvaluation?, dark: Bool,
                              today: Date = Date(), explain: ((Int) -> String?)? = nil) throws -> String {
        try CalculatorDocumentError.wrap {
            let installed = URL(fileURLWithPath: try CalculatorAssets.writeShareViewer(store.directory.path))
            let viewer = try ShareViewerAddress.resolve(store.directory.path, installed)
            if viewer.isFileURL, !FileManager.default.fileExists(atPath: viewer.path) { throw DocumentError.shareLink("Share viewer missing") }
            let results = evaluation?.raw.results ?? []
            let matching = results.count == (try SourceLineMap(source)).count ? results : []
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day], from: today)
            let date = DateOnly(parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
            let snapshot = try ShareLink.capture(title, source, matching, dark, date: date) { answer in
                explain?(answer.line) ?? ShareLink.defaultExplanation(answer)
            }
            return try ShareLink.create(viewer, snapshot)
        }
    }

    /// True for a link that opens only on this Mac (the viewer is a local file).
    public static func isLocal(_ link: String) -> Bool { link.lowercased().hasPrefix("file:") }

    /// The sheet a link holds: title, lines and their shown results, for checks.
    public static func decode(_ link: String) throws -> (title: String, lines: [(source: String, result: String?)]) {
        try CalculatorDocumentError.wrap {
            let snapshot = try ShareLink.decode(link)
            return (snapshot.title, snapshot.lines.map { ($0.source, $0.result) })
        }
    }
}

/// One imported file, ready to become a sheet.
public struct CalculatorImportedSheet: Sendable {
    public struct Notice: Hashable, Sendable {
        /// One-based line; 0 is the whole file.
        public let line: Int
        public let message: String
    }
    public let name: String
    public let source: String
    public let notices: [Notice]
}

/// Numi (.numi), Soulver (.slvr) and plain text (.txt) files read into new sheets (C# SheetImport). Files are only read; nothing in them runs.
public enum CalculatorImport {
    public static let extensions = ["numi", "slvr", "txt"]
    public static let maxFiles = SheetImport.maxFiles

    public static func isSupported(_ url: URL) -> Bool { SheetImport.isSupported(url.path) }

    /// Reads and translates one file. Safe off the main thread. Throws with a message for a rejected file (nothing was created).
    public static func read(_ url: URL, cancel: CalculatorCancellation? = nil) throws -> CalculatorImportedSheet {
        try CalculatorDocumentError.wrap {
            let sheet = try SheetImport.readFile(url.path, cancel?.token ?? .none)
            return CalculatorImportedSheet(name: sheet.name, source: sheet.source, notices: sheet.notices.map { .init(line: $0.line, message: $0.message) })
        }
    }

    /// A valid sheet name from `name` that no sheet in `existing` uses (ignoring case).
    public static func uniqueName(_ name: String, existing: [String]) -> String { SheetImport.uniqueName(name, existing) }
}

/// A file format an export writes.
public enum CalculatorExportFormat: CaseIterable, Sendable {
    case plainText, markdown, csv, pdf, png, transparentPng
    var engine: ExportFormat {
        switch self {
        case .plainText: .plainText
        case .markdown: .markdown
        case .csv: .csv
        case .pdf: .pdf
        case .png: .png
        case .transparentPng: .transparentPng
        }
    }
    /// ".txt", ".md", ".csv", ".pdf" or ".png".
    public var fileExtension: String { ExportFile.extension(engine) }
    /// A file name from the sheet name that both systems accept.
    public func suggestedName(_ title: String) -> String { ExportFile.suggestedName(title, engine) }
}

/// What a sheet shows, frozen for copying, exporting, printing and images (C# SheetExport): every format reads the same rows.
public final class CalculatorExport {
    let export: SheetExport

    /// Builds the snapshot. `evaluation` must belong to `source`; without one the export holds the text alone.
    public init(title: String, source: String, evaluation: CalculatorEvaluation?) throws {
        export = try CalculatorDocumentError.wrap {
            let raw = evaluation?.raw ?? .empty
            return try SheetExport.create(title, source, raw.results, raw.format)
        }
    }

    public var title: String { export.title }
    /// True when any line has a result.
    public var hasResults: Bool { export.hasResults }
    /// True when any line is not blank.
    public var hasContent: Bool { export.lines.contains { $0.kind != .blank } }
    /// The sheet's own total (its last sum or average line), as copied.
    public var totalText: String? { export.totalText }

    /// Results only, one row per line.
    public func resultsText() throws -> String { try CalculatorDocumentError.wrap { try export.resultsText() } }
    /// Tab-separated rows of source and result, for spreadsheets.
    public func tableText() throws -> String { try CalculatorDocumentError.wrap { try export.tableTsv() } }
    /// The same table as an HTML fragment (the pasteboard's public.html).
    public func tableHTML() throws -> String { try CalculatorDocumentError.wrap { try export.tableHtml() } }
    /// The Windows "HTML Format" clipboard payload around the table.
    public func windowsClipboardHTML() throws -> String { try CalculatorDocumentError.wrap { ClipboardHtml.wrap(try export.tableHtml()) } }

    /// The bytes of a text format (UTF-8; CSV with a byte-order mark).
    public func text(_ format: CalculatorExportFormat) throws -> Data {
        try CalculatorDocumentError.wrap {
            let text: String
            switch format {
            case .plainText: text = try export.plainText()
            case .markdown: text = try export.markdown()
            case .csv: text = try export.csv()
            default: throw CalcError.argument("Not a text export")
            }
            return Data(ExportFile.encode(format.engine, text))
        }
    }

    /// Places the rows on pages (or one continuous page when `pageHeight` is infinite): source left, results right-aligned in one
    /// column, worksheet cells on column stops, figures under their line. `measure` gives a text's width in the renderer's font.
    public func layout(width: Double, pageHeight: Double, margin: Double, lineHeight: Double, figureHeight: Double = 120, maxHeight: Double = 12_000,
                       measure: @escaping (String, CalculatorExportLayout.Style) -> Double) throws -> CalculatorExportLayout {
        try CalculatorDocumentError.wrap {
            var options = LayoutOptions(width, pageHeight, margin, lineHeight)
            options.figureHeight = figureHeight
            options.maxHeight = maxHeight
            let layout = try SheetLayoutComposer.compose(export, options) { text, style in measure(text, CalculatorExportLayout.Style(style)) }
            return CalculatorExportLayout(layout)
        }
    }

    /// Writes beside the destination and moves it into place, so a failed write never leaves a partial file under the chosen name.
    public static func write(_ data: Data, to url: URL) throws {
        try CalculatorDocumentError.wrap { try ExportFile.write(url.path, [UInt8](data)) }
    }
}

/// An export placed on pages, in the renderer's units.
public struct CalculatorExportLayout {
    public enum Style: Sendable {
        case source, heading, result, total, error
        init(_ style: LayoutStyle) {
            switch style {
            case .source: self = .source
            case .heading: self = .heading
            case .result: self = .result
            case .total: self = .total
            case .error: self = .error
            }
        }
        /// Headings, results and totals are drawn bold (C# PdfFontSet.IsBold).
        public var isBold: Bool { self == .heading || self == .result || self == .total }
    }
    public struct Run: Sendable {
        public let x: Double, top: Double
        public let text: String
        public let style: Style
        /// One-based source line.
        public let line: Int
    }
    public struct Figure: Sendable {
        public let x: Double, top: Double, width: Double, height: Double
        public let line: Int
        public let figure: CalculatorFigure?
    }
    public struct Page: Sendable {
        public let number: Int
        public let runs: [Run]
        public let figures: [Figure]
        public let height: Double
    }
    public let pages: [Page]
    public let width: Double
    /// Lines a continuous layout left out past its maximum height.
    public let omittedLines: Int
    /// Headings are drawn this much larger (C# PdfFontSet.HeadingScale).
    public static let headingScale = 1.25

    init(_ layout: SheetLayout) {
        pages = layout.pages.map { page in
            Page(number: page.number, runs: page.runs.map { Run(x: $0.x, top: $0.top, text: $0.text, style: Style($0.style), line: $0.line) },
                 figures: page.figures.map { Figure(x: $0.x, top: $0.top, width: $0.width, height: $0.height, line: $0.line, figure: CalculatorFigure($0.value)) },
                 height: page.height)
        }
        width = layout.width
        omittedLines = layout.omittedLines
    }
}

/// The calculator's interface strings in its nine languages (the Windows catalog, UiStrings.json), and its help and notices files.
public enum CalculatorInterfaceText {
    public struct Language: Hashable, Sendable { public let code: String; public let name: String }
    private struct Catalog { let languages: [Language]; let strings: [String: [String: String]] }
    private static let catalog: Catalog = {
        guard let bytes = try? CalculatorAssets.uiStrings, let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let languages = root["languages"] as? [[String: String]], let strings = root["strings"] as? [String: [String: String]] else {
            return Catalog(languages: [Language(code: "en", name: "English")], strings: [:])
        }
        return Catalog(languages: languages.compactMap { item in item["code"].map { Language(code: $0, name: item["name"] ?? $0) } }, strings: strings)
    }()

    /// English first.
    public static var languages: [Language] { catalog.languages }
    public static var keys: [String] { Array(catalog.strings.keys) }

    /// A catalog string in a language, or nil for an unknown key. Placeholders are .NET's `{0}`, `{1}`….
    public static func string(_ key: String, language: String) -> String? {
        guard let texts = catalog.strings[key] else { return nil }
        return texts[language] ?? texts["en"]
    }

    /// An explicit choice wins; otherwise the first supported language in the system's preferred list; otherwise English (Windows UiText.Resolve).
    public static func resolve(_ preference: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        let codes = languages.map(\.code)
        if let preference, codes.contains(preference) { return preference }
        for identifier in preferred {
            var parts = identifier.split(separator: "-").map(String.init)
            while !parts.isEmpty {
                let name = parts.joined(separator: "-")
                if let match = codes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return match }
                if ["zh-CN", "zh-SG", "zh-Hans-CN", "zh-Hans-SG"].contains(name) { return "zh-Hans" }
                parts.removeLast()
            }
        }
        return "en"
    }
}
