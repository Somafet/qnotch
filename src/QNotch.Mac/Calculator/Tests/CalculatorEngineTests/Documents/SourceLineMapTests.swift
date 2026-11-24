import XCTest
@testable import CalculatorEngine

final class SourceLineMapTests: XCTestCase {
    func testEveryUtf16CoordinateMapsToItsLogicalLine() throws {
        try theory([("", 1), ("a\n", 2), ("a\r\nb\rc\nd", 4), ("😀 é 日本語\r\nשלום\n", 3)]) { (source: String, count: Int) in
            let map = try SourceLineMap(source); XCTAssertEqual(count, map.count)
            let units = Array(source.utf16)
            for i in 0..<count {
                XCTAssertEqual(i, try map.lineAt(map.start(i)))
                let end = i + 1 < count ? map.start(i + 1) : units.count
                for c in map.start(i)..<end { XCTAssertEqual(i, try map.lineAt(c)) }
                XCTAssertFalse(units[map.start(i)..<map.contentEnd(i)].contains(10))
                XCTAssertFalse(units[map.start(i)..<map.contentEnd(i)].contains(13))
            }
            XCTAssertEqual(count - 1, try map.lineAt(units.count))
        }
    }
    func testLargeSheetAndBounds() throws {
        let map = try SourceLineMap(Array(repeating: "1+1", count: 10000).joined(separator: "\r\n"))
        XCTAssertEqual(10000, map.count); XCTAssertEqual(49995, map.start(9999))
        assertThrows(.argument, try map.lineAt(-1))
        assertThrows(.argument, try SourceLineMap(String(repeating: "a", count: 200001)))
    }
}
