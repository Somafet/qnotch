import XCTest
import zlib
@testable import CalculatorEngine

final class ExportLayoutTests: XCTestCase {
    // Fixed-advance oracle: every text element is 6 units wide, so positions can be computed by hand.
    private static func mono(_ text: String, _ style: LayoutStyle) -> Double { Double(text.count * 6) }
    private static func export(_ source: String) throws -> SheetExport { try SheetExport.create("t", source, try SheetEvaluator.evaluate(source)) }

    func testResultsRightAlignToTheContentEdge() throws {
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export("# Head\n12 + 30\n1/0"), LayoutOptions(400, 600, 20, 16), ExportLayoutTests.mono)
        XCTAssertEqual(1, layout.pages.count)
        let page = layout.pages[0]
        let result = page.runs.first { $0.text == "42" }!
        XCTAssertEqual(400 - 20 - 2 * 6, result.x)
        XCTAssertEqual(.result, result.style)
        XCTAssertEqual(20 + 16, result.top)
        XCTAssertEqual(.heading, page.runs.first { $0.text == "# Head" }!.style)
        let errors = page.runs.filter { $0.style == .error }
        XCTAssertEqual(1, errors.count)
        XCTAssertEqual(400 - 20, errors[0].x + ExportLayoutTests.mono(errors[0].text, errors[0].style))
        XCTAssertEqual(20 + 32, errors[0].top)
    }

    func testLongSourcesWrapInsideTheSourceColumnWithoutSplittingTextElements() throws {
        let words = Array(repeating: "abcd", count: 30).joined(separator: " ") + " + 1"
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export(words), LayoutOptions(300, 2000, 10, 16), ExportLayoutTests.mono)
        let sources = layout.pages[0].runs.filter { $0.style == .source }
        let resultColumn = layout.pages[0].runs.filter { $0.style != .source }.map { ExportLayoutTests.mono($0.text, $0.style) }.max()!
        XCTAssertTrue(sources.count > 1)
        for run in sources { XCTAssertTrue(ExportLayoutTests.mono(run.text, run.style) <= 280 - min(280 * 0.45, resultColumn) - 24) }
        XCTAssertEqual(words.replacingOccurrences(of: " ", with: ""), sources.map { $0.text.replacingOccurrences(of: " ", with: "") }.joined())
        let wrapped = SheetLayoutComposer.wrap("a😀😀😀\u{E9}\u{E9}\u{E9}", 12, .source, ExportLayoutTests.mono)
        XCTAssertEqual(["a😀", "😀😀", "\u{E9}\u{E9}", "\u{E9}"], wrapped)
        XCTAssertEqual(["  ab", "cd"], SheetLayoutComposer.wrap("  ab cd", 24, .source, ExportLayoutTests.mono))
    }

    func testPaginationKeepsLinesTogetherAndBoundsPages() throws {
        let source = (1...100).map { "\($0) + 1" }.joined(separator: "\n")
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export(source), LayoutOptions(300, 200, 20, 16), ExportLayoutTests.mono)
        let perPage = Int((200 - 40) / 16)
        XCTAssertEqual(Int((100.0 / Double(perPage)).rounded(.up)), layout.pages.count)
        for page in layout.pages { for run in page.runs { XCTAssertTrue(run.top >= 20 && run.top + 16 <= 180) } }
        XCTAssertEqual(100, layout.pages.reduce(0) { $0 + $1.runs.filter { $0.style == .source }.count })
        XCTAssertEqual(Array(1...layout.pages.count), layout.pages.map(\.number))
        var limited = LayoutOptions(300, 200, 20, 16); limited.maxPages = 3
        assertThrows(.argument, try SheetLayoutComposer.compose(try ExportLayoutTests.export(source), limited, ExportLayoutTests.mono))
    }

    func testContinuousLayoutStopsAtItsHeightAndCountsOmittedLines() throws {
        let source = (1...50).map(String.init).joined(separator: "\n")
        var options = LayoutOptions(300, .infinity, 20, 16); options.maxHeight = 20 + 16 * 10 + 20
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export(source), options, ExportLayoutTests.mono)
        XCTAssertEqual(1, layout.pages.count)
        let page = layout.pages[0]
        XCTAssertEqual(10, page.runs.filter { $0.style == .source }.count)
        XCTAssertEqual(40, layout.omittedLines)
        XCTAssertEqual(20 + 16 * 10 + 20, page.height)
    }

    func testFiguresSitUnderTheirLineAndWorksheetCellsShareStops() throws {
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export("plot x^2 from -2 to 2\nName\tQ1\nLonger name\t5"), LayoutOptions(500, 1000, 20, 16), ExportLayoutTests.mono)
        let page = layout.pages[0]
        XCTAssertEqual(1, page.figures.count)
        guard let figure = page.figures.first else { return }
        XCTAssertEqual([20.0, 20.0 + 16, 460.0, 120.0], [figure.x, figure.top, figure.width, figure.height])
        XCTAssertEqual(.plot, figure.value.kind)
        let q1 = page.runs.first { $0.text == "Q1" }!, five = page.runs.first { $0.text == "5" }!
        XCTAssertEqual(20 + ExportLayoutTests.mono("Longer name", .source) + 24, q1.x)
        XCTAssertEqual(q1.x, five.x)
        XCTAssertEqual(20 + 16 + 130, q1.top)
    }

    func testInvalidGeometryIsRefused() throws {
        assertThrows(.argument, try SheetLayoutComposer.compose(try ExportLayoutTests.export("1"), LayoutOptions(50, 600, 20, 16), ExportLayoutTests.mono))
        assertThrows(.argument, try SheetLayoutComposer.compose(try ExportLayoutTests.export("1"), LayoutOptions(400, 40, 20, 16), ExportLayoutTests.mono))
        assertThrows(.argument, try SheetLayoutComposer.compose(try ExportLayoutTests.export("1"), LayoutOptions(400, 600, 20, 0), ExportLayoutTests.mono))
    }

    /// A face that maps ASCII to glyph = code point and a fixed advance; its "program" is marker bytes, so structure can be checked without a font parser.
    private final class FakeFace: PdfFontFace {
        let name: String; let maps: (Int) -> Bool; let fixedAdvance: Double
        var ascent: Double { 0.8 }; var descent: Double { 0.2 }; var capHeight: Double { 0.7 }
        var requests: [[UInt16]] = []
        init(_ name: String, _ maps: @escaping (Int) -> Bool, _ advance: Double = 0.5) { self.name = name; self.maps = maps; fixedAdvance = advance }
        func tryGetGlyph(_ codePoint: Int) -> UInt16? { maps(codePoint) && codePoint & 0xFFFF != 0 ? UInt16(codePoint & 0xFFFF) : nil }
        func advance(_ glyph: UInt16) -> Double { fixedAdvance }
        func fontProgram(_ glyphs: [UInt16]) -> (program: [UInt8], subset: Bool) { requests.append(glyphs); return (Array(("FAKE-" + name).utf8), true) }
    }

    private static func pdf(_ source: String) throws -> (result: PdfResult, text: String, latin: FakeFace, symbol: FakeFace) {
        let latin = FakeFace("Latin Sans", { (0x20..<0x7F).contains($0) }), symbol = FakeFace("Symbols", { $0 == 0x2248 || $0 == 0x20AC })
        let fonts = try PdfFontSet([latin, symbol], [], 10)
        let layout = try SheetLayoutComposer.compose(try export(source), LayoutOptions(595, 842, 50, 16), fonts.measure)
        let result = try PdfSheetWriter.write(layout, fonts, .paper, "Test ✓ sheet")
        return (result, latin1(result.bytes), latin, symbol)
    }
    private static func latin1(_ bytes: [UInt8]) -> String { String(bytes.map { Character(Unicode.Scalar($0)) }) }
    private static func latin1Bytes(_ text: Substring) -> [UInt8] { text.unicodeScalars.map { UInt8($0.value) } }
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        try! NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testPdfCrossReferenceOffsetsPointAtTheirObjects() throws {
        let (result, text, _, _) = try ExportLayoutTests.pdf("# Budget\nrent = 1200 EUR\npi\n日本")
        let scalars = Array(text.unicodeScalars)
        func slice(_ from: Int) -> String { String(String.UnicodeScalarView(scalars[from...])) }
        XCTAssertTrue(text.hasPrefix("%PDF-1.7\n"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
        let trailer = ExportLayoutTests.matches("startxref\\n(\\d+)\\n%%EOF\\n$", text)[0]
        let startxref = Int((text as NSString).substring(with: trailer.range(at: 1)))!
        XCTAssertTrue(slice(startxref).hasPrefix("xref\n0 "))
        let tail = slice(startxref)
        let header = ExportLayoutTests.matches("^xref\\n0 (\\d+)\\n", tail)[0]
        let count = Int((tail as NSString).substring(with: header.range(at: 1)))!
        let entries = Array((tail as NSString).substring(from: header.range.length).components(separatedBy: "\r\n").prefix(count))
        XCTAssertEqual("0000000000 65535 f", entries[0])
        for id in 1..<count {
            XCTAssertEqual(1, ExportLayoutTests.matches("^\\d{10} 00000 n$", entries[id]).count, entries[id])
            let offset = Int(entries[id].prefix(10))!
            XCTAssertTrue(slice(offset).hasPrefix("\(id) 0 obj\n"))
        }
        XCTAssertTrue(text.contains("/Size \(count)"))
        XCTAssertEqual(1, result.pages)
        // 日本 is in neither face: two visible characters are counted, drawn as glyph 0.
        XCTAssertEqual(2, result.missingCharacters)
        // Title survives as UTF-16BE with a BOM.
        XCTAssertTrue(text.contains(PdfWriter.textString("Test ✓ sheet")))
        XCTAssertTrue(text.contains("<FEFF0054006500730074002027130020"))
    }

    func testPdfDrawsGlyphCodesWithFallbackFacesAndMapsThemBackToUnicode() throws {
        let (_, text, latin, symbol) = try ExportLayoutTests.pdf("€ 5 ≈ 5")
        let streams = ExportLayoutTests.streams(text)
        let content = streams.first { $0.contains("BT\n") }!
        // ASCII from the primary face, € and ≈ from the fallback face, each segment positioned with its own Tm.
        XCTAssertTrue(content.contains("/F1 10 Tf")); XCTAssertTrue(content.contains("/F2 10 Tf"))
        XCTAssertTrue(content.contains("<20AC> Tj"))
        XCTAssertTrue(content.contains("<002000350020> Tj"))
        // The fallback segment starts where the primary face's advances end: x = margin + 1 glyph * 0.5 em * 10.
        XCTAssertTrue(content.contains("1 0 0 1 55 "))
        XCTAssertTrue(content.contains("<2248> Tj"))
        let maps = streams.filter { $0.contains("beginbfchar") }
        XCTAssertEqual(2, maps.count)
        XCTAssertTrue(maps.contains { $0.contains("<20AC> <20AC>") && $0.contains("<2248> <2248>") })
        XCTAssertTrue(maps.contains { $0.contains("<0035> <0035>") })
        // Each embedded program was requested once with exactly the glyphs drawn, plus the missing glyph.
        XCTAssertEqual(1, symbol.requests.count); XCTAssertEqual([0, 0x20AC, 0x2248], symbol.requests.first?.sorted())
        XCTAssertEqual(1, latin.requests.count); XCTAssertTrue(latin.requests.first?.contains(0) == true)
        XCTAssertTrue(streams.joined().contains("FAKE-Latin Sans"))
        XCTAssertFalse(ExportLayoutTests.matches("/BaseFont /[A-Z]{6}\\+LatinSans ", text).isEmpty)
        XCTAssertTrue(text.contains("/Encoding /Identity-H"))
        XCTAssertTrue(text.contains("/CIDToGIDMap /Identity"))
    }

    func testPdfOutputIsDeterministic() throws {
        XCTAssertEqual(try ExportLayoutTests.pdf("a = 1\nb = a * 2").result.bytes, try ExportLayoutTests.pdf("a = 1\nb = a * 2").result.bytes)
    }

    func testPdfEmbedsFigureImagesAndRefusesMalformedOnes() throws {
        let face = FakeFace("Latin", { (0x20..<0x7F).contains($0) })
        let fonts = try PdfFontSet([face], [], 10)
        let layout = try SheetLayoutComposer.compose(try ExportLayoutTests.export("plot x from 0 to 1"), LayoutOptions(595, 842, 50, 16), fonts.measure)
        let pdf = ExportLayoutTests.latin1(try PdfSheetWriter.write(layout, fonts, .paper, "t", figures: { _ in PdfImage(pixelWidth: 2, pixelHeight: 1, rgb: [255, 0, 0, 0, 0, 255]) }).bytes)
        XCTAssertTrue(pdf.contains("/Subtype /Image /Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8"))
        XCTAssertTrue(pdf.contains("/XObject << /Im1 "))
        XCTAssertTrue(ExportLayoutTests.streams(pdf).contains { $0.contains("cm /Im1 Do Q") })
        assertThrows(.argument, try PdfSheetWriter.write(layout, fonts, .paper, "t", figures: { _ in PdfImage(pixelWidth: 2, pixelHeight: 2, rgb: [1, 2, 3]) }))
        assertThrows(.argument, try PdfSheetWriter.write(try SheetLayoutComposer.compose(try ExportLayoutTests.export("1"), LayoutOptions(595, .infinity, 50, 16), fonts.measure), fonts, .paper, "t"))
    }

    // Decompresses every Flate stream using each dictionary's declared /Length (an independent zlib inflate, as C# uses ZLibStream).
    private static func streams(_ pdf: String) -> [String] {
        var result: [String] = []
        let scalars = Array(pdf.unicodeScalars)
        for match in matches("/Filter /FlateDecode /Length (\\d+) >>\\nstream\\n", pdf) {
            let length = Int((pdf as NSString).substring(with: match.range(at: 1)))!
            let start = match.range.location + match.range.length // Latin-1 text: one UTF-16 unit per byte.
            XCTAssertEqual("\nendstream", String(String.UnicodeScalarView(scalars[(start + length)..<(start + length + 10)])))
            var compressed = scalars[start..<(start + length)].map { UInt8($0.value) }
            var output = [UInt8](repeating: 0, count: 1 << 22)
            var size = uLongf(output.count)
            XCTAssertEqual(Z_OK, uncompress(&output, &size, &compressed, uLong(compressed.count)))
            result.append(latin1(Array(output[..<Int(size)])))
        }
        return result
    }
}
