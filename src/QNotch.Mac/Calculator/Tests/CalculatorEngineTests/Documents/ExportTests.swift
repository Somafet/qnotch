import XCTest
@testable import CalculatorEngine

final class ExportTests: XCTestCase {
    private static let groceries = "# Groceries\nmilk = 3.50\nbread = 2.25\nsum\n\nnote: buy later\n2/3\n1/0"
    private static func export(_ source: String, _ title: String = "Groceries") throws -> SheetExport {
        try SheetExport.create(title, source, try SheetEvaluator.evaluate(source))
    }

    /// An RFC 4180 reader written for this test (C# uses VisualBasic's TextFieldParser): quoted fields, doubled quotes, CRLF rows.
    private static func parseCsv(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text), i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r\n" || c == "\n" { row.append(field); field = ""; rows.append(row); row = [] }
            else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        chars = []
        return rows
    }

    func testSnapshotClassifiesLinesAndFindsTheSheetTotal() throws {
        let export = try ExportTests.export(ExportTests.groceries)
        XCTAssertEqual([.heading, .result, .result, .result, .blank, .error, .result, .error], export.lines.map(\.kind))
        XCTAssertEqual([false, false, false, true, false, false, false, false], export.lines.map(\.isTotal))
        XCTAssertEqual("5.75", export.totalText) // 3.50 + 2.25
        XCTAssertEqual(Array(1...8), export.lines.map(\.number))
    }

    func testResultsReadAsTheSheetShowsThemWithNumberStyleAndDefaultCurrency() throws {
        let retrieved = DateTimeOffset(2026, 10, 30, 17, 0, 0)
        let latest = try CurrencyRateSnapshot(provider: "Test daily rates", baseCurrency: "EUR", asOf: DateOnly.parseISO("2026-10-30")!,
                                              retrievedAt: Instant(unixTicks: retrieved.utcTicks - Ticks.unixEpoch),
                                              rates: [("EUR", try Rational(1, 1)), ("USD", try Rational(2, 1)), ("HUF", try Rational(400, 1))])
        var context = EvaluationContext(today: DateOnly.parseISO("2026-10-31"), currencyRates: try CurrencyRateBook(latest, []))
        context.displayCurrency = "HUF"
        let source = "6400 usd\n1234567\n6400 usd in usd"
        let format = ResultFormat(nil, try NumberStyle.fromId("comma", .invariant))
        let export = try SheetExport.create("t", source, try SheetEvaluator.evaluate(source, context: context), format)
        XCTAssertEqual(["1,280,000 HUF", "1,234,567", "6,400 USD"], export.lines.map(\.result))
        XCTAssertEqual("1280000 HUF", export.lines[0].value) // click-copy text of the shown amount
        // Without a format the canonical display remains, as before.
        XCTAssertEqual("1234567", try SheetExport.create("t", source, try SheetEvaluator.evaluate(source, context: context)).lines[1].result)
    }

    func testAggregateFlagMarksOnlySumAndAverageLines() throws {
        let results = try SheetEvaluator.evaluate("1\n2\nsum\naverage\nsum([1,2])\nx = 4")
        XCTAssertEqual([false, false, true, true, false, false], results.map(\.isAggregate))
        XCTAssertNil(try SheetExport.create("", "1\n2", try SheetEvaluator.evaluate("1\n2")).totalText)
        // The last declared total wins when a sheet has several blocks.
        XCTAssertEqual("10", try ExportTests.export("1\n2\nsum\n\n4\n6\nsum").totalText)
    }

    func testResultsTextKeepsLineCorrespondenceAndCompleteValues() throws {
        XCTAssertEqual("\r\n3.5\r\n2.25\r\n5.75\r\n\r\n\r\n2/3", try ExportTests.export(ExportTests.groceries).resultsText())
        // A named constant shows compact notation; copy keeps every digit.
        let constant = try ExportTests.export("c")
        XCTAssertEqual(constant.lines[0].value, try constant.resultsText())
        XCTAssertNotEqual(constant.lines[0].result, constant.lines[0].value)
    }

    func testPlainTextRightAlignsResultsInOneColumn() throws {
        // Source column is the widest calculated source (12) plus a two-space gap; results right-align to the widest result (16).
        func row(_ source: String, _ result: String) -> String { source + String(repeating: " ", count: 14 + 16 - source.count - result.count) + result }
        let expected = ["# Groceries", row("milk = 3.50", "3.5"), row("bread = 2.25", "2.25"), row("sum", "5.75"), "",
                        row("2/3", "2/3"), row("1/0", "Division by zero"), ""].joined(separator: "\r\n")
        XCTAssertEqual(expected, try ExportTests.export("# Groceries\nmilk = 3.50\nbread = 2.25\nsum\n\n2/3\n1/0").plainText())
        // A source longer than the column cap pushes only its own result, by the minimum gap.
        let longSource = String(repeating: "1", count: 60) + " + 1"
        XCTAssertTrue(try ExportTests.export(longSource).plainText().hasSuffix(longSource + "  " + ExportTests.export(longSource).lines[0].result + "\r\n"))
    }

    func testDisplayWidthCountsWideAndCombiningCharacters() {
        XCTAssertEqual(4, SheetExport.displayWidth("日本"))
        XCTAssertEqual(1, SheetExport.displayWidth("e\u{301}")) // C# source: "e" + U+0301
        XCTAssertEqual(2, SheetExport.displayWidth("😀"))
        XCTAssertEqual(3, SheetExport.displayWidth("abc"))
    }

    func testMarkdownKeepsHeadingsTablesAndEscapesMarkup() throws {
        let source = "# Costs | 2026\nrent = 1200\nfee_total = 3*4\nsum\n\n// reminder *later*\n\nName\tQ1\nA|B\t5"
        let markdown = try ExportTests.export(source).markdown()
        XCTAssertEqual(["# Costs \\| 2026", "",
                        "| | |", "| --- | ---: |", "| rent = 1200 | 1200 |", "| fee\\_total = 3\\*4 | 12 |", "| sum | **1212** |", "",
                        "// reminder \\*later\\*", "",
                        "| Name | Q1 |", "| --- | --- |", "| A\\|B | 5 |", ""].joined(separator: "\r\n"), markdown)
    }

    func testCsvRoundTripsThroughAnIndependentParserAndGuardsFormulas() throws {
        let source = "label = \"a, \"\"quoted\"\" b\"\n=1+1\n-5 + 2\n-3\n@x\n2/3\n\nplain words"
        let export = try ExportTests.export(source)
        let csv = try export.csv()
        let rows = ExportTests.parseCsv(csv)
        XCTAssertEqual(["Line", "Source", "Result", "Value", "Error"], rows[0])
        XCTAssertEqual(export.lines.filter { $0.kind != .blank }.count + 1, rows.count)
        XCTAssertEqual(source.netSplit("\n")[0], rows[1][1])
        XCTAssertEqual("'=1+1", rows[2][1])
        XCTAssertEqual("'-5 + 2", rows[3][1])
        XCTAssertEqual("-3", rows[4][1]) // a plain signed number stays numeric
        XCTAssertEqual("-3", rows[4][2])
        XCTAssertEqual("'@x", rows[5][1])
        XCTAssertEqual(["6", "2/3", "2/3", "2/3", ""], rows[6])
        XCTAssertEqual("8", rows[7][0])
        for row in rows { XCTAssertEqual(5, row.count) }
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testTableRowsKeepWorksheetCellsAndResults() throws {
        let export = try ExportTests.export("Name\tQ1\tQ2\nA\t1\t2\n\nx = 2 + 3")
        XCTAssertEqual([["Name", "Q1", "Q2", export.lines[0].result], ["A", "1", "2"], ["x = 2 + 3", "5"]], export.tableRows())
        XCTAssertEqual("Name\tQ1\tQ2\t" + export.lines[0].result + "\r\nA\t1\t2\r\nx = 2 + 3\t5", try export.tableTsv())
        XCTAssertEqual("<table><tr><td>a &lt;b&gt; &amp; c</td><td>1</td></tr></table>", try ExportTests.export("a <b> & c\t1").tableHtml())
    }

    func testClipboardHtmlOffsetsAreUtf8BytePositions() {
        let fragment = "<table><tr><td>€ 5 · 日本 😀</td></tr></table>"
        let payload = ClipboardHtml.wrap(fragment)
        let bytes = Array(payload.utf8)
        func offset(_ key: String) -> Int {
            let at = payload.range(of: key + ":")!.upperBound
            return Int(payload[at...].prefix(10))!
        }
        XCTAssertEqual(fragment, String(decoding: bytes[offset("StartFragment")..<offset("EndFragment")], as: UTF8.self))
        XCTAssertTrue(String(decoding: bytes[offset("StartHTML")..<(offset("StartHTML") + 6)], as: UTF8.self).hasPrefix("<html>"))
        XCTAssertEqual(bytes.count, offset("EndHTML"))
    }

    func testExportsAreBounded() throws {
        assertThrows(.argument, try SheetExport.create("x", String(repeating: "1", count: SheetStore.maxCharacters + 1), []))
        assertThrows(.argument, try SheetExport.create("x", String(repeating: "1\n", count: SheetEvaluator.maxLines), []))
        // A full-size sheet still exports within the output limit.
        let full = String(repeating: "123456789 + 1\n", count: 9_999)
        let export = try ExportTests.export(full)
        XCTAssertTrue(try export.plainText().netLength < SheetExport.maxOutputCharacters)
        XCTAssertEqual(9_999 + 1, try export.csv().netSplit("\r\n").count - 1)
    }

    func testMismatchedOrMissingResultsExportSourceOnly() throws {
        let export = try SheetExport.create("t", "1+1\n2+2", [LineResult(5, nil, "stale")])
        for line in export.lines { XCTAssertEqual(.text, line.kind) }
        XCTAssertEqual("1+1\r\n2+2\r\n", try export.plainText())
    }

    func testExportFileReplacesAtomicallyAndSuggestsSafeNames() throws {
        let directory = TestFiles.temporary("calc-export-"); try NetFile.createDirectory(directory)
        defer { TestFiles.delete(directory) }
        let path = TestFiles.path(directory, "out.csv")
        try TestFiles.writeText(path, "old")
        try ExportFile.write(path, ExportFile.encode(.csv, "a,b\r\n"))
        XCTAssertEqual([0xEF, 0xBB, 0xBF, UInt8(ascii: "a")], Array(try TestFiles.readBytes(path).prefix(4)))
        XCTAssertEqual(1, TestFiles.files(directory).count)
        XCTAssertEqual("Plan 2026 Q1.md", ExportFile.suggestedName("Plan: 2026/Q1", .markdown))
        XCTAssertEqual("con sheet.pdf", ExportFile.suggestedName("con", .pdf))
        XCTAssertEqual("Sheet.txt", ExportFile.suggestedName("  ?? ", .plainText))
        XCTAssertEqual("a.png", ExportFile.suggestedName("a", .transparentPng))
    }
}
