import Compression
import XCTest
@testable import CalculatorEngine

final class ShareLinkTests: XCTestCase {
    private let directory = TestFiles.temporary("Calc-tests")
    private static let viewer = URL(string: "https://viewer.example.test/calc/index.html")!
    override func tearDown() { TestFiles.delete(directory) }

    private static func fixture() throws -> JSONNode { try JSONNode.parse(try Fixtures.data("share-links-v1.json")) }
    private static func point(_ x: Int, _ y: Int) -> ShareFigure.Point { ShareFigure.Point(x, y) }

    // Built by hand to match the fixture's hand-written canonical text; independent of evaluator formatting.
    private static func golden(_ name: String) -> ShareSnapshot {
        switch name {
        case "starter":
            return ShareSnapshot(title: "Budget", theme: .light, date: DateOnly.parseISO("2026-11-01"), lines: [
                ShareLine("price = 120", "120"), ShareLine("discount = 15%", "15%"), ShareLine("price * discount", "18", explanation: "multiply(120, 15%) = 18\nUses L1, L2"),
                ShareLine(""), ShareLine("# total"), ShareLine("1/0", "Division by zero", error: true),
            ])
        case "unicode":
            return ShareSnapshot(title: "Ünïcode ✓ 😀", theme: .dark, date: nil, lines: [ShareLine("café = 3 € 😀 中文", "3"), ShareLine("\t indented  "),
                                                                                       ShareLine("quote \" backslash \\ end", "\"q\"")])
        case "figures":
            var bar = ShareFigure(.bar, "Bar chart of 2 values, from Food 300 EUR to Rent 1200 EUR")
            bar.total = "1500 EUR"; bar.items = [ShareChartItem(label: "Rent", magnitude: 1200, display: "1200 EUR"), ShareChartItem(label: "Food", magnitude: 300, display: "300 EUR")]
            var pie = ShareFigure(.pie, "Pie chart of 2 values, from 1 1 to 2 3")
            pie.total = "4"; pie.items = [ShareChartItem(label: "1", magnitude: 1, display: "1"), ShareChartItem(label: "2", magnitude: 3, display: "3")]
            var trend = ShareFigure(.trend, "Trend chart of 3 values, from 2 -2 to 1 1.5")
            trend.items = [ShareChartItem(label: "1", magnitude: 1.5, display: "1.5"), ShareChartItem(label: "2", magnitude: -2, display: "-2"),
                           ShareChartItem(label: "3", magnitude: 0.25, display: "0.25")]
            var plot = ShareFigure(.plot, "Plot of 1/x for x from -2 to 2, y shown from [-10, 10]")
            plot.frame = ["-2", "2", "-10", "10"]; plot.points = [point(0, 1843), point(2047, -4096), point(2049, 8192), point(4096, 2253)]; plot.segments = [0, 2]
            return ShareSnapshot(title: "Figures", theme: .light, date: nil, lines: [
                ShareLine("Rent 1200 EUR", "1200 EUR"), ShareLine("Food 300 EUR", "300 EUR"),
                ShareLine("bar chart", "1500 EUR", explanation: "Bar chart of 2 values, total 1500 EUR", figure: bar),
                ShareLine("pie chart of [1, 3]", "4", figure: pie),
                ShareLine("trend chart of [1.5, -2, 0.25]", "3 points", figure: trend),
                ShareLine("plot 1/x from -2 to 2", "plot", explanation: "Formula: 1/x", figure: plot),
            ])
        case "hostile":
            return ShareSnapshot(title: "<b>x</b>", theme: .light, date: nil, lines: [
                ShareLine("<script>alert(1)</script>"), ShareLine("<img src=x onerror=alert(1)> = 2", "<i>2</i>", explanation: "</div><script>alert(2)</script>"),
                ShareLine("# javascript:alert(1) and https://example.test/a?b=1&c=<2>. done"), ShareLine("# data:text/html,<script>x</script> https://user:pw@example.test/"),
            ])
        default: fatalError(name)
        }
    }
    private static func canonical(_ snapshot: ShareSnapshot) throws -> String { String(decoding: try ShareLink.serialize(snapshot), as: UTF8.self) }
    private static func cases() throws -> [JSONNode] { try fixture().property("cases").arrayItems() }

    func testSerializationMatchesHandWrittenCanonicalPayload() throws {
        let cases = try ShareLinkTests.cases()
        for item in cases {
            let name = try item.property("name").string()
            XCTAssertEqual(try item.property("payload").string(), try ShareLinkTests.canonical(ShareLinkTests.golden(name)), name)
            XCTAssertEqual(try ShareLink.serialize(ShareLinkTests.golden(name)), try ShareLink.serialize(ShareLinkTests.golden(name)))
            CaseCounter.record(file: #filePath)
        }
    }

    func testDecodesFragmentsCompressedByNodeAndByDotnet() throws {
        for item in try ShareLinkTests.cases() {
            let name = try item.property("name").string()
            let payload = try item.property("payload").string()
            XCTAssertEqual(payload, try ShareLinkTests.canonical(ShareLink.decode(try item.property("node").string())), name)
            let recorded = try item.property("dotnet").string()
            XCTAssertFalse(recorded.isEmpty, "Record .NET fragments with the C# test RecordsDotnetFragmentsOnRequest")
            XCTAssertEqual(payload, try ShareLinkTests.canonical(ShareLink.decode(recorded)), name)
            XCTAssertEqual(payload, try ShareLinkTests.canonical(ShareLink.decode("#" + ShareLink.encodeFragment(ShareLinkTests.golden(name)))), name)
            CaseCounter.record(file: #filePath)
        }
    }

    /// C# records its own (.NET-compressed) fragments into the fixture when CALC_WRITE_SHARE_FIXTURES=1. The Mac has no .NET
    /// compressor, so with the variable set this test only reports that the fixture must be recorded from Windows or dotnet.
    func testRecordsDotnetFragmentsOnRequest() throws {
        if ProcessInfo.processInfo.environment["CALC_WRITE_SHARE_FIXTURES"] != "1" { return }
        throw XCTSkip("The .NET fragments are recorded by the C# ShareLinkTests (dotnet test)")
    }

    func testRejectsHostileFragmentsWithTheBrowserDecodersMessage() throws {
        for item in try ShareLinkTests.fixture().property("invalid").arrayItems() {
            let name = try item.property("name").string(), fragment = try item.property("fragment").string(), error = try item.property("error").string()
            let failure = assertThrows(.shareLink, try ShareLink.decode(fragment), name)
            XCTAssertEqual(error, failure?.netMessage, name)
            CaseCounter.record(file: #filePath)
        }
    }

    func testRejectsOversizedFragmentsBeforeDecoding() throws {
        XCTAssertEqual("Link too large", assertThrows(.shareLink, try ShareLink.decode("c1." + String(repeating: "A", count: ShareLink.maxFragmentCharacters - 2)))?.netMessage)
        XCTAssertEqual("Unsupported link version", assertThrows(.shareLink, try ShareLink.decode("c1" + String(repeating: "A", count: 10)))?.netMessage)
    }

    func testCapturesTheSheetAsComputedFromRealEvaluation() throws {
        let source = "price = 120\r\ndiscount = 15%\nprice * discount\n\n# note\n1/0\n\nRent 1200\nFood 300\nbar chart\nplot 1/x from -2 to 2"
        let results = try SheetEvaluator.evaluate(source)
        let snapshot = try ShareLink.capture("  ", source, results, true, date: DateOnly.parseISO("2026-11-01"))
        XCTAssertEqual("Sheet", snapshot.title)
        XCTAssertEqual(.dark, snapshot.theme)
        XCTAssertEqual(try SourceLineMap(source).count, snapshot.lines.count)
        XCTAssertEqual("price = 120", snapshot.lines[0].source)
        for i in results.indices { XCTAssertEqual(results[i].display.isEmpty ? nil : results[i].display, snapshot.lines[i].result) }
        XCTAssertEqual(results[2].display, snapshot.lines[2].result)
        XCTAssertNotNil(snapshot.lines[2].explanation)
        XCTAssertTrue(snapshot.lines[2].explanation?.contains("L1") == true)
        XCTAssertNil(snapshot.lines[3].result)
        XCTAssertTrue(snapshot.lines[5].error)
        XCTAssertNil(snapshot.lines[5].explanation)
        XCTAssertTrue(results[9].error == nil && results[10].error == nil, (results[10].error ?? "") + " / " + (results[9].error ?? ""))
        let chart = try XCTUnwrap(snapshot.lines[9].figure)
        XCTAssertEqual(.bar, chart.kind)
        XCTAssertEqual(try results[9].value!.chart.items.map(\.magnitude), chart.items.map(\.magnitude))
        let plot = try XCTUnwrap(snapshot.lines[10].figure)
        XCTAssertEqual(.plot, plot.kind)
        let sampled = try results[10].value!.plot
        XCTAssertEqual(sampled.x.count, plot.points.count)
        for point in plot.points { XCTAssertTrue((0...ShareLink.plotGrid).contains(point.x)) }
        XCTAssertTrue(plot.segments.count >= 2, "1/x has a pole, so the plot keeps separate segments")
        let decoded = try ShareLink.decode(try ShareLink.create(ShareLinkTests.viewer, snapshot))
        XCTAssertEqual(try ShareLink.serialize(snapshot), try ShareLink.serialize(decoded))
    }

    func testSnapshotIsFrozenAndHostExplanationsAreUsed() throws {
        let results = try SheetEvaluator.evaluate("a = 2\na * 3")
        let snapshot = try ShareLink.capture("S", "a = 2\na * 3", results, false, explain: { "host: " + $0.display })
        let first = try ShareLink.serialize(snapshot)
        XCTAssertEqual("host: 6", snapshot.lines[1].explanation)
        XCTAssertEqual("a\nb\nc", try ShareLink.capture("S", "1", SheetEvaluator.evaluate("1"), false, explain: { _ in "a\r\nb\rc\r\n" }).lines[0].explanation)
        // Re-evaluating or editing the sheet later does not change an already captured snapshot.
        _ = try SheetEvaluator.evaluate("a = 5\na * 3")
        XCTAssertEqual(first, try ShareLink.serialize(snapshot))
        XCTAssertEqual(first, try ShareLink.serialize(ShareLink.capture("S", "a = 2\na * 3", results, false, explain: { "host: " + $0.display })))
    }

    func testResultsForMissingLinesAndMismatchedListsAreIgnored() throws {
        let snapshot = try ShareLink.capture("S", "1\n2", [LineResult(5, nil, "x"), LineResult(-1, nil, "y")], false)
        for line in snapshot.lines { XCTAssertNil(line.result) }
    }

    /// C# builds "a\uD800b 😀" with a lone surrogate. A Swift string cannot hold one: decoding the same UTF-16 already yields U+FFFD,
    /// which is what the C# snapshot contains.
    func testUnpairedSurrogatesBecomeReplacementCharactersAndLongTextIsBounded() throws {
        let source = String(decoding: [0x61, 0xD800, 0x62, 0x20, 0xD83D, 0xDE00] as [UInt16], as: UTF16.self)
        let snapshot = try ShareLink.capture(String(repeating: "t", count: 200), source, SheetEvaluator.evaluate(source), false,
                                             explain: { _ in String(repeating: "e", count: ShareLink.maxExplanation + 50) })
        XCTAssertEqual("a\u{FFFD}b 😀", snapshot.lines[0].source)
        XCTAssertEqual(ShareLink.maxTitle, snapshot.title.netLength)
        XCTAssertTrue(snapshot.title.hasSuffix("…"))
        XCTAssertEqual("a\u{FFFD}b 😀", try ShareLink.decode(ShareLink.encodeFragment(snapshot)).lines[0].source)
        let explained = try ShareLink.capture("S", "1+1", SheetEvaluator.evaluate("1+1"), false, explain: { _ in String(repeating: "e", count: ShareLink.maxExplanation + 50) })
        XCTAssertEqual(ShareLink.maxExplanation, explained.lines[0].explanation!.netLength)
        XCTAssertTrue(explained.lines[0].explanation!.hasSuffix("…"))
    }

    func testRefusesSheetsBeyondTheLinkLimitInsteadOfTruncating() throws {
        var random = NetRandom(7)
        let text = (0..<2000).map { _ in "# " + Data((0..<48).map { _ in UInt8(random.next(256)) }).base64EncodedString() }.joined(separator: "\n")
        let snapshot = try ShareLink.capture("S", text, [], false)
        XCTAssertEqual("Sheet too large to share as a link", assertThrows(.shareLink, try ShareLink.encodeFragment(snapshot))?.netMessage)
        assertThrows(.shareLink, try ShareLink.capture("S", String(repeating: "1", count: SheetStore.maxCharacters + 1), [], false))
    }

    func testLinksCarryTheSheetOnlyInTheFragment() throws {
        let link = try ShareLink.create(URL(string: "https://viewer.example.test/c/?lang=en")!, ShareLinkTests.golden("starter"))
        let hash = link.firstIndex(of: "#")!
        XCTAssertEqual("https://viewer.example.test/c/?lang=en", String(link[..<hash]))
        let fragment = String(link[hash...])
        XCTAssertTrue(fragment.hasPrefix("#c1."))
        XCTAssertFalse(link.contains("price"))
        // Raw DEFLATE: inflating the fragment bytes with a plain raw-deflate decoder gives the canonical JSON.
        var data = String(fragment.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        data += String(repeating: "=", count: (4 - data.count % 4) % 4)
        let compressed = [UInt8](Data(base64Encoded: data)!)
        var inflated = [UInt8](repeating: 0, count: 1 << 20)
        let count = compression_decode_buffer(&inflated, inflated.count, compressed, compressed.count, nil, COMPRESSION_ZLIB)
        XCTAssertEqual(try ShareLinkTests.canonical(ShareLinkTests.golden("starter")), String(decoding: inflated[..<count], as: UTF8.self))
    }

    func testViewerAddressesAreRestricted() throws {
        try theory([("https://viewer.example.test/index.html", true), ("file:///C:/Program%20Files/Calc/ShareViewer/index.html", true),
                    ("http://localhost:8080/index.html", true), ("http://127.0.0.1/index.html", true), ("http://viewer.example.test/index.html", false),
                    ("javascript:alert(1)", false), ("data:text/html,x", false), ("https://user:pw@viewer.example.test/", false),
                    ("https://viewer.example.test/#old", false)]) { (address: String, allowed: Bool) in
            let uri = URL(string: address)!
            if allowed { XCTAssertEqual(uri, try ShareViewerAddress.validate(uri), address) }
            else { assertThrows(.shareLink, try ShareViewerAddress.validate(uri), address) }
        }
    }

    func testInstalledViewerIsTheDefaultAndShareJsonOverridesIt() throws {
        try NetFile.createDirectory(directory)
        let installed = ShareViewerAddress.installed(TestFiles.path(directory, "app #1"))
        XCTAssertTrue(installed.isFileURL)
        XCTAssertNil(installed.fragment)
        XCTAssertTrue(installed.path.hasSuffix("/ShareViewer/index.html"))
        XCTAssertEqual(installed, try ShareViewerAddress.resolve(directory, installed))
        let settings = TestFiles.path(directory, ShareViewerAddress.fileName)
        try TestFiles.writeText(settings, "{\"viewerUrl\":\"https://viewer.example.test/calc/\"}")
        XCTAssertEqual("https://viewer.example.test/calc/", try ShareViewerAddress.resolve(directory, installed).absoluteString)
        try TestFiles.writeText(settings, "{\"viewerUrl\":\"\"}")
        XCTAssertEqual(installed, try ShareViewerAddress.resolve(directory, installed))
        try TestFiles.writeText(settings, "{\"viewerUrl\":\"http://viewer.example.test/\"}")
        assertThrows(.shareLink, try ShareViewerAddress.resolve(directory, installed))
        try TestFiles.writeText(settings, "{bad")
        assertThrows(.shareLink, try ShareViewerAddress.resolve(directory, installed))
        try TestFiles.writeText(settings, "{\"viewerUrl\":\"" + String(repeating: "a", count: ShareViewerAddress.maxFileBytes) + "\"}")
        assertThrows(.shareLink, try ShareViewerAddress.resolve(directory, installed))
    }
}
