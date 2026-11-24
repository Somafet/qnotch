import XCTest
@testable import CalculatorEngine

final class TotalMemberTests: XCTestCase {
    private func members(_ source: String) throws -> [Int] {
        try SheetEvaluationSession().evaluateWithFunctions(source, .empty, [], .none, context: EvaluationContext()).totalMembers
    }
    func testMembersSpanBlocksAndMatchWhatAnUntaggedSumReadsInEachBlock() throws {
        let sheet = "# A\n1\n2\nsum\n\n# B\nx = 3\nbad +\n// comment\nf(n) = n*2\nsum #t\naverage"
        XCTAssertEqual(try members(sheet), [1, 2, 6, 7])
        XCTAssertEqual(try SheetEvaluator.evaluate(sheet)[3].dependencies, [1, 2])
    }
    func testPresentationAndHolidayDeclarationsAreNotMembers() throws {
        XCTAssertEqual(try members("holidays = [24 dec]\n5\nplot sin(x) from 0 to 1"), [1])
    }
}
