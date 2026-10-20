import AppKit

/// The shared diagnostic modes and options (spec/diagnostics.md): `--snapshot`, `--smoke-test` or
/// `--measure <dir>`, `--data-dir`, `--only` and `--appearance`.
struct DiagnosticOptions {
    enum Appearance: String { case light, dark }
    enum Mode: String, CaseIterable { case snapshot = "--snapshot", smoke = "--smoke-test", measure = "--measure" }

    var mode: Mode?
    /// The mode's output directory: its value, else `--output` (the older spelling).
    var output: String?
    /// `--data-dir`, else `QNOTCH_MAC_DATA_DIR`.
    var dataDirectory: String?
    /// `--only` patterns; empty renders every view.
    var only: [String] = []
    var appearance: Appearance?
    /// Bad usage, for the caller to report and exit 2.
    var problem: String?

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name) else { return nil }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { problem = "\(name) needs a value"; return nil }
            return arguments[index + 1]
        }
        mode = Mode.allCases.first { arguments.contains($0.rawValue) }
        if let mode, let index = arguments.firstIndex(of: mode.rawValue) {
            output = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") ? arguments[index + 1] : value("--output")
            if output == nil, problem == nil { problem = "\(mode.rawValue) needs an output directory" }
        }
        dataDirectory = value("--data-dir") ?? environment["QNOTCH_MAC_DATA_DIR"]
        only = value("--only").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        if let raw = value("--appearance") {
            appearance = Appearance(rawValue: raw)
            if appearance == nil { problem = "--appearance takes light or dark" }
        }
    }

    /// Whether the view with this file name (with or without `.png`) is rendered under `--only`.
    func includes(_ name: String) -> Bool {
        let base = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
        return only.isEmpty || only.contains { Self.matches(base, pattern: $0) }
    }

    /// Whole-name match where `*` stands for any run of characters.
    static func matches(_ name: String, pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return name == pattern }
        var rest = Substring(name)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let found = rest.range(of: part) else { return false }
            rest = rest[found.upperBound...]
        }
        return rest.hasSuffix(parts[parts.count - 1])
    }

    var nsAppearance: NSAppearance? {
        appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
    }
}
