import Foundation

/// "#RRGGBB" text for picked colors (Windows ColorPickerModule) and the recent-colors list.
public enum HexColor {
    public static let recentLimit = 6

    /// sRGB components in 0...1.
    public static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Normalizes "#abc", "aabbcc" or "#AABBCC" to "#AABBCC"; nil for anything else.
    public static func normalize(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    public static func components(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalize(text), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Moves `color` to the front, without duplicates, capped at `recentLimit`. Invalid saved values are dropped.
    public static func remember(_ color: String, in recent: [String]) -> [String] {
        guard let color = normalize(color) else { return recent.compactMap(normalize) }
        var seen: Set<String> = [color]
        let rest = recent.compactMap(normalize).filter { seen.insert($0).inserted }
        return Array(([color] + rest).prefix(recentLimit))
    }
}

public struct ColorPickerSettings: Codable, Equatable {
    public var recent: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case recent }
    public init(from decoder: Decoder) throws {
        recent = try decoder.container(keyedBy: CodingKeys.self).value(.recent, [String]()).compactMap(HexColor.normalize)
    }
}
