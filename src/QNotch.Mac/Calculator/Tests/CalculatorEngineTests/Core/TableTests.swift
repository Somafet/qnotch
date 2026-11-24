import XCTest
@testable import CalculatorEngine

// C# `Assert.Same(paste, TableSyntax.TryNormalizePaste(paste))` checks that the very same string instance comes back.
// Swift strings are values without identity, so these ports compare code units instead (`ordinalEquals`).
final class TableTests: XCTestCase {
    private let sales = "Region\tQ1\tQ2\tNotes\nNorth\t10\t40\tgood\nSouth\t20\t\tlate\nEast\t60\t90\t-\nWest\tn/a\t20\t"
    private func last(_ source: String) throws -> LineResult { try SheetEvaluator.evaluate(source).last! }
    private func table(_ source: String) throws -> TableValue {
        guard let result = try SheetEvaluator.evaluate(source).first(where: { $0.value?.kind == .table }) else { throw AssertionFailure(description: "\(source): no table") }
        return try result.value!.table
    }
    private func assertSame(_ expected: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(expected.ordinalEquals(actual), "\(expected.debugDescription) became \(actual.debugDescription)", file: file, line: line)
    }

    func testFirstLineShowsTheShapeAndOtherLinesStayQuiet() throws {
        let results = try SheetEvaluator.evaluate("a\tb\n1\t2\n3\t4")
        XCTAssertEqual("2×2 table", results[0].display)
        for line in results.dropFirst() { XCTAssertEqual("", line.display); XCTAssertNil(line.error) }
    }
    func testOneDataRowUnderAHeaderIsATable() throws { XCTAssertEqual("1×2 table", try SheetEvaluator.evaluate("a\tb\n1\t2")[0].display) }
    func testHeaderIsDetectedFromNonNumericFirstRowCells() throws {
        try theory([("a\tb\n1\t2\n3\t4", true, 2), ("1\tb\n1\t2", true, 1), ("1\t2\n3\t4", false, 2), ("10%\t$5\n3\t4", false, 2), ("1\t\t3\n4\t5\t6", false, 2)]) { source, header, rows in
            let table = try table(source)
            XCTAssertEqual(header, table.header != nil, source); XCTAssertEqual(rows, table.rowCount, source)
        }
    }
    func testColumnStatisticsSkipTextCells() throws {
        try theory([("sum", "90"), ("avg", "30"), ("average", "30"), ("mean", "30"), ("min", "10"), ("max", "60"), ("count", "3"), ("median", "20")]) { function, display in
            XCTAssertEqual(display, try last(sales + "\n\n" + function + "(column(table1, \"Q1\"))").display, function)
        }
    }
    func testBlankCellsAreSkippedByPosition() throws {
        try theory([("sum", "150"), ("avg", "50"), ("min", "20"), ("max", "90"), ("count", "3"), ("median", "40")]) { function, display in
            XCTAssertEqual(display, try last(sales + "\n\n" + function + "(column(table1, 3))").display, function)
        }
    }
    func testRowStatisticsSkipLabels() throws {
        try theory([("sum", "150"), ("avg", "75"), ("min", "60"), ("max", "90"), ("count", "2"), ("median", "75")]) { function, display in
            XCTAssertEqual(display, try last(sales + "\n\n" + function + "(row(table1, 3))").display, function)
        }
    }
    func testSelectionsAreOrdinaryLists() throws {
        try theory([("column(table1, \"q1\")", "[10, 20, 60]"), ("row(table1, 1)", "[10, 40]")]) { call, display in
            let result = try last(sales + "\n\n" + call)
            XCTAssertEqual(.list, result.value!.kind, call); XCTAssertEqual(display, result.display, call)
        }
    }
    func testListFormOfCountAndMedianStillWork() throws {
        XCTAssertEqual("3", try last("count([1, 2, 3])").display)
        XCTAssertEqual("2", try last("median([1, 2, 3])").display)
        XCTAssertEqual("6", try last("sum([1, 2, 3])").display)
    }
    func testExplanationCountsSkippedCells() throws {
        XCTAssertTrue(try last(sales + "\n\ncolumn(table1, \"Q1\")").explanation.last!.assumption!.contains("1 text or blank cells skipped"))
    }
    func testCellsCoverPercentagesMoneyAndUnits() throws {
        let table = try table("rate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g")
        XCTAssertEqual("35%", try last("t:\nrate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g\n\nsum(column(t, 1))").display)
        XCTAssertEqual(.money, table[0, 1].value!.kind)
        XCTAssertEqual("2.5 kg", try last("t:\nrate\tcost\tweight\n10%\t$5\t2 kg\n25%\t$7.50\t500 g\n\nsum(column(t, 3))").display)
    }
    func testCommonSpreadsheetFormatsAreNumbers() throws {
        try theory([("1,234.50", "1234.5"), ("$1,200", "$1200"), ("-5", "-5"), ("1k", "1000")]) { cell, value in
            let display = try table("a\tb\n" + cell + "\t1")[0, 0].value!.display.netReplace(",", "")
            XCTAssertTrue(display.contains(value.netTrimStart("$")), "\(cell): \(display)")
        }
    }
    func testOtherCellsAreText() throws {
        try theory(["Q1", "1,5", "1.234,56", "(5)", "2 + 3", "2026-01-15", "10:30", "1.2.3.4", "x = 5", "sum(1, 2)"]) { cell in
            XCTAssertNil(try table("a\tb\n" + cell + "\t1")[0, 0].value, cell)
        }
    }
    func testTableLinesNeverProduceCellErrors() throws {
        for line in try SheetEvaluator.evaluate("a\tb\n)(\t1/0\n1 +\t[\n\"open\t5") { XCTAssertNil(line.error) }
    }
    func testTableLinesStayOutOfBlockAggregates() throws {
        XCTAssertEqual("3", try last("1\na\tb\n5\t6\n2\nsum").display)
        XCTAssertEqual("1.5", try last("1\na\tb\n5\t6\n2\naverage").display)
        XCTAssertEqual([1, 2], try last("1\na\tb\n5\t6\n2\nbar chart").value!.chart.items.map(\.magnitude))
    }
    func testNameLineNamesTheTableAndShowsNothing() throws {
        let results = try SheetEvaluator.evaluate("sales:\na\tb\n1\t2\n\nsum(column(sales, \"b\"))")
        XCTAssertEqual("", results[0].display); XCTAssertNil(results[0].error)
        XCTAssertEqual("1×2 table", results[1].display)
        XCTAssertEqual("2", results.last!.display)
    }
    func testUnnamedTablesNumberInSourceOrder() throws {
        let source = "a\tb\n1\t2\n\nnamed:\na\tb\n3\t4\n\na\tb\n5\t6\n\nsum(column(table1, 2))\nsum(column(table2, 2))"
        let results = try SheetEvaluator.evaluate(source)
        XCTAssertEqual("2", results[results.count - 2].display); XCTAssertEqual("6", results.last!.display)
    }
    func testUserVariableKeepsItsName() throws {
        XCTAssertEqual("8", try SheetEvaluator.evaluate("a\tb\n1\t2\n\ntable1 = 7\ntable1 + 1").last!.display)
    }
    func testInvalidNameLineIsLeftAloneAndTheTableIsAutoNamed() throws {
        XCTAssertEqual("2", try last("Totals (EUR):\na\tb\n1\t2\n\nsum(column(table1, 2))").display)
    }
    func testOtherTabbedTextIsNotATable() throws {
        try theory(["a\tb\n1\t2\t3", "a\tb\nplain\nc\td", "a\tb", "\tx = 1\n\ty = 2", "x = 1\t\ny = 2\t", "# heading\tone\n# heading\ttwo"]) { source in
            XCTAssertFalse(try SheetEvaluator.evaluate(source).contains { $0.value?.kind == .table }, source)
        }
    }
    func testIndentedLinesKeepEvaluating() throws { XCTAssertEqual("3", try last("\tx = 1\n\ty = 2\n\tx + y").display) }
    func testBadSelectionsAreExplicitErrors() throws {
        try theory([
            ("column(table1, \"Q9\")", "Unknown column"), ("column(table1, 0)", "from 1 to 4"), ("column(table1, 5)", "from 1 to 4"), ("column(table1, 1.5)", "whole number"),
            ("row(table1, 5)", "from 1 to 4"), ("column(table1, \"Region\")", "no numeric cells"), ("column(5, 1)", "expects a table"),
        ]) { call, message in
            let error = try last(sales + "\n\n" + call).error
            XCTAssertTrue(error?.contains(message) == true, "\(call): \(error ?? "nil")")
        }
    }
    func testHeaderAmbiguityIsExplicit() throws {
        try theory([("a\ta\n1\t2\n\ncolumn(table1, \"A\")", "More than one column"), ("1\t2\n3\t4\n\ncolumn(table1, \"A\")", "no header")]) { source, message in
            let error = try last(source).error
            XCTAssertTrue(error?.contains(message) == true, "\(source): \(error ?? "nil")")
        }
    }
    func testWholeTableArithmeticIsAnError() throws {
        try theory(["table1 + 1", "sum(table1)", "-table1"]) { line in XCTAssertNotNil(try last("a\tb\n1\t2\n\n" + line).error, line) }
    }
    func testLimitsReportOnceOnTheFirstLine() throws {
        let wide = (1...65).map(String.init).joined(separator: "\t")
        let results = try SheetEvaluator.evaluate(wide + "\n" + wide)
        XCTAssertTrue(results[0].error?.contains("64 columns") == true); XCTAssertNil(results[1].error)
        let tall = "a\tb\n" + Array(repeating: "1\t2", count: 1025).joined(separator: "\n")
        XCTAssertTrue(try SheetEvaluator.evaluate(tall)[0].error?.contains("1024 rows") == true)
        XCTAssertEqual("1024×2 table", try SheetEvaluator.evaluate("a\tb\n" + Array(repeating: "1\t2", count: 1024).joined(separator: "\n"))[0].display)
    }
    func testCellEditUpdatesDependentsAndOnlyThose() throws {
        let session = SheetEvaluationSession()
        let before = "t:\na\tb\n1\t2\n3\t4\n\nx = sum(column(t, 2))\ny = 5\nz = y + 1"
        XCTAssertEqual("6", try session.evaluate(before)[5].display)
        let results = try session.evaluate(before.netReplace("3\t4", "3\t40"))
        XCTAssertEqual("42", results[5].display); XCTAssertEqual("6", results[7].display)
        // The table and x evaluate; y, z, and the quiet lines are reused.
        XCTAssertEqual(2, session.lastStatistics.evaluatedLines)
        XCTAssertEqual(2, session.lastStatistics.reusedResults)
        XCTAssertEqual(1, session.lastStatistics.parsedLines)
    }
    func testReformattingACellLeavesDependentsReusable() throws {
        let session = SheetEvaluationSession()
        let first = try session.evaluate("a\tb\n1\t2\n\nx = sum(column(table1, 2))")
        let second = try session.evaluate("a\tb\n1\t2.0\n\nx = sum(column(table1, 2))")
        XCTAssertIdentical(first[3], second[3])
        XCTAssertEqual(first[0].value, second[0].value)
    }
    func testDroppingATableRowRebindsTheName() throws {
        let session = SheetEvaluationSession()
        let line = "x = sum(column(table1, 2))"
        XCTAssertEqual("6", try session.evaluate("a\tb\n1\t2\n3\t4\n\n" + line).last!.display)
        XCTAssertEqual("2", try session.evaluate("a\tb\n1\t2\nplain\n\n" + line).last!.display)
    }
    func testChartsReadTableColumnsWithLabels() throws {
        let chart = try last(sales + "\n\nbar chart of column(table1, \"Q1\")").value!.chart
        XCTAssertEqual(["North", "South", "East"], chart.items.map(\.label))
        let row = try last(sales + "\n\npie chart of row(table1, 3)").value!.chart
        XCTAssertEqual(["Q1", "Q2"], row.items.map(\.label))
    }
    func testTablesPassThroughSavedFunctions() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "firstTotal", parameters: ["t"], body: "sum(column(t, 2))")])
        XCTAssertEqual(FunctionLibrary.latestCatalogVersion, library.minimumCatalogVersion)
        XCTAssertEqual("6", try SheetEvaluationSession().evaluateWithFunctions("a\tb\n1\t2\n3\t4\n\nfirstTotal(table1)", library, []).results.last!.display)
    }
    func testTableCellsAreNotFunctionDefinitions() throws {
        let update = try FunctionUpdate.prepare("f(x) = 1\t2\nf(y) = 3\t4", .empty, [])
        XCTAssertTrue(update.library.definitions.isEmpty)
    }
    func testCopyTextIsCompact() throws {
        XCTAssertEqual("4×4 table: Region, Q1, Q2, Notes", try last(sales).value == nil ? try SheetEvaluator.evaluate(sales)[0].value!.copyText : "")
    }
    func testRfc4180AndSemicolonTextBecomesTsv() throws {
        try theory([
            ("a,b\n1,2\n", "a\tb\n1\t2\n"), ("a,b\r\n1,2\r\n3,4", "a\tb\n1\t2\n3\t4"), ("a;b;c\n1;2;3", "a\tb\tc\n1\t2\t3"), ("name,note\n\"Smith, J\",1", "name\tnote\nSmith, J\t1"),
            ("name,note\n\"said \"\"hi\"\"\",1", "name\tnote\nsaid \"hi\"\t1"), ("name,note\n\"two\nlines\",1", "name\tnote\ntwo lines\t1"), ("a, b\n1, 2", "a\tb\n1\t2"),
            ("a;b\n1,5;2,5", "a\tb\n1,5\t2,5"), ("a,b,\n1,2,", "a\tb\t\n1\t2\t"),
        ]) { paste, expected in
            let actual = try TableSyntax.tryNormalizePaste(paste)
            XCTAssertTrue(expected.ordinalEquals(actual), "\(paste.debugDescription) became \(actual.debugDescription)")
        }
    }
    func testEverythingElseIsLeftUntouched() throws {
        try theory([
            "", "a,b,c", "a,b,c\n", "a,b\n1,2,3", "a,b\n\n1,2", "a\tb\n1\t2", "a,\"b\n1,2", "a,b\"c\n1,2", "\"a\"b,c\n1,2", "sum(1, 2)\nmax(3, 4)", "[1, 2]\n[3, 4]",
            "a = 1, 2\nb = 3, 4", "Hello, world\nGoodbye, moon", "one\ntwo", ",a\n1,2",
        ]) { paste in assertSame(paste, try TableSyntax.tryNormalizePaste(paste)) }
    }
    func testWideOrTallPastesStayText() throws {
        let wide = (1...65).map(String.init).joined(separator: ","); let text = wide + "\n" + wide
        assertSame(text, try TableSyntax.tryNormalizePaste(text))
        let tall = "a,b\n" + Array(repeating: "1,2", count: 1025).joined(separator: "\n")
        assertSame(tall, try TableSyntax.tryNormalizePaste(tall))
    }
    func testNormalizedPasteEvaluatesAsATable() throws {
        let source = try TableSyntax.tryNormalizePaste("item,cost\n\"Rent, flat\",\"$1,200.50\"\nFood,$300\n")
        let results = try SheetEvaluator.evaluate(source + "\nsum(column(table1, \"cost\"))")
        XCTAssertEqual("2×2 table", results[0].display)
        XCTAssertTrue(results.last!.display.netReplace(",", "").contains("1500.5"), results.last!.display)
    }
    func testTabAlignedLabelAmountLinesStayOrdinaryLines() throws {
        let results = try SheetEvaluator.evaluate("rent\t1200\nfood\t400\nsum")
        XCTAssertFalse(results.contains { $0.value?.kind == .table })
        XCTAssertEqual("1600", results.last!.display)
        // A name line still makes the same lines a table; its first row is then the header, as for any table.
        XCTAssertEqual("1×2 table", try SheetEvaluator.evaluate("budget:\nrent\t1200\nfood\t400")[1].display)
        XCTAssertEqual("1600", try last("budget:\nitem\tcost\nrent\t1200\nfood\t400\n\nsum(column(budget, 2))").display)
        XCTAssertEqual("1×2 table", try SheetEvaluator.evaluate("item\tcost\nrent\t1200")[0].display)
    }
    func testFormattedNumberColumnsAreNotCsv() throws {
        try theory(["1,200\r\n3,400\r\n", "$1,200\n$3,400\n", "3,5\n4,25", "Milk, 2 l\nEggs, 12"]) { paste in assertSame(paste, try TableSyntax.tryNormalizePaste(paste)) }
    }
}
