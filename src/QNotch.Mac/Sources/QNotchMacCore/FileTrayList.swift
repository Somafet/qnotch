import Foundation

/// The file tray's list rules (Windows FileTrayState): references, newest first, no duplicates,
/// at most 60 items. Nothing here touches the files themselves.
public enum FileTrayList {
    public static let limit = 60

    /// Adds `paths` (in the given order) to the front, moving existing ones up.
    public static func adding(_ paths: [String], to list: [String]) -> [String] {
        var result = list
        for path in paths.reversed() {
            result.removeAll { $0 == path }
            result.insert(path, at: 0)
        }
        return Array(result.prefix(limit))
    }

    /// "name.ext", "name (2).ext", … the first name not in `taken` (export never overwrites).
    public static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    public static func countText(_ count: Int, missing: Int) -> String {
        let files = count == 1 ? "1 file" : "\(count) files"
        return missing > 0 ? "\(files) · \(missing) missing" : files
    }
}
