import Foundation

/// Logical source lines in UTF-16 coordinates. Wrapping does not create source lines. "\r\n", "\r" and "\n" each end a line.
final class SourceLineMap {
    private let starts: [Int]
    let source: String
    /// The source's UTF-16 code units, for callers that slice by these coordinates.
    let units: [UInt16]
    var count: Int { starts.count }

    init(_ source: String) throws {
        let units = Array(source.utf16)
        if units.count > SheetStore.maxCharacters { throw CalcError.argument("Source exceeds document limit") }
        self.source = source; self.units = units
        var positions = [0]
        var i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count && units[i + 1] == 10 { i += 1 }
                positions.append(i + 1)
            } else if units[i] == 10 { positions.append(i + 1) }
            i += 1
        }
        starts = positions
    }
    func start(_ line: Int) -> Int { starts[line] }
    func contentEnd(_ line: Int) -> Int {
        var end = line + 1 < count ? starts[line + 1] : units.count
        while end > starts[line] && (units[end - 1] == 13 || units[end - 1] == 10) { end -= 1 }
        return end
    }
    /// The text of a line without its line break.
    func text(_ line: Int) -> String { String(units: units[start(line)..<contentEnd(line)]) }
    func lineAt(_ character: Int) throws -> Int {
        if character < 0 || character > units.count {
            throw CalcError.argument("Specified argument was out of the range of valid values. (Parameter 'character')")
        }
        // Array.BinarySearch: the exact start, or the line whose start precedes the character.
        var low = 0, high = starts.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] == character { return middle }
            if starts[middle] < character { low = middle + 1 } else { high = middle - 1 }
        }
        return low - 1
    }
}
