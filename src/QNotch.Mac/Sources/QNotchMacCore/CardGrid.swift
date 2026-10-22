import Foundation

/// Mac Home sizes keep the same row height; Small always occupies exactly one column.
public enum HomeCardSize: Int, CaseIterable {
    case small = 1, medium = 2
    public var title: String { self == .small ? "Small" : "Medium" }

    public static func supported(defaultSpan: Int) -> [HomeCardSize] {
        defaultSpan == 2 ? [.small, .medium] : [.small]
    }

    public static func resolve(saved: Int?, defaultSpan: Int) -> HomeCardSize {
        let sizes = supported(defaultSpan: defaultSpan)
        return saved.flatMap(HomeCardSize.init(rawValue:)).flatMap { sizes.contains($0) ? $0 : nil }
            ?? (defaultSpan == 2 ? .medium : .small)
    }
}

/// Home grid placement (Windows HomeView: three columns, cards one or two columns wide).
/// Dense packing: each card takes the first free slot, in reading order, where it fits, so a
/// one-column card can fill the hole a two-column card left at the end of a row.
public enum CardGrid {
    public struct Slot: Equatable {
        public let row: Int
        public let column: Int
        public let span: Int
        public init(row: Int, column: Int, span: Int) { self.row = row; self.column = column; self.span = span }
    }

    public static func place(spans: [Int], columns: Int = 3) -> [Slot] {
        precondition(columns > 0)
        var taken: [[Bool]] = []
        var slots: [Slot] = []
        for raw in spans {
            let span = min(max(1, raw), columns)
            var row = 0
            search: while true {
                if row == taken.count { taken.append(Array(repeating: false, count: columns)) }
                for column in 0...(columns - span) where (column..<column + span).allSatisfy({ !taken[row][$0] }) {
                    (column..<column + span).forEach { taken[row][$0] = true }
                    slots.append(Slot(row: row, column: column, span: span))
                    break search
                }
                row += 1
            }
        }
        return slots
    }

    public static func rows(_ slots: [Slot]) -> Int { (slots.map(\.row).max() ?? -1) + 1 }
}
