import Foundation

/// System.Text.Json's string output with the default encoder (JsonSerializer.Serialize(string)).
enum NetJSONText {
    /// Escapes like JavaScriptEncoder.Default: only printable Basic Latin passes, minus HTML-sensitive characters.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 2)
        for c in text.utf16 {
            switch c {
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x22, 0x26, 0x27, 0x2B, 0x3C, 0x3E, 0x60: out += "\\u" + hex4(c)
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(c)))
            default: out += "\\u" + hex4(c)
            }
        }
        return out
    }
    static func quote(_ text: String) -> String { "\"" + escape(text) + "\"" }
    private static func hex4(_ c: UInt16) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(c >> 12)], digits[Int(c >> 8 & 15)], digits[Int(c >> 4 & 15)], digits[Int(c & 15)]])
    }
}
