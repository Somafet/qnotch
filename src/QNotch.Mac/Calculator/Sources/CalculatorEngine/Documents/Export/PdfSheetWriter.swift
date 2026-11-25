import Foundation

/// A TrueType face the renderer can embed. Metrics are fractions of the em. The program is either a subset that keeps original glyph ids
/// or, when subsetting is not permitted, the complete font.
protocol PdfFontFace: AnyObject {
    var name: String { get }
    var ascent: Double { get }
    var descent: Double { get }
    var capHeight: Double { get }
    /// C# `TryGetGlyph(codePoint, out glyph)`: the glyph id, or nil when the face does not map the code point.
    func tryGetGlyph(_ codePoint: Int) -> UInt16?
    func advance(_ glyph: UInt16) -> Double
    func fontProgram(_ glyphs: [UInt16]) throws -> (program: [UInt8], subset: Bool)
}

struct PdfColors {
    let source: String, result: String, error: String, heading: String
    static let paper = PdfColors(source: "#2B2D2A", result: "#06717D", error: "#696C67", heading: "#2B2D2A")
}
struct PdfImage { let pixelWidth: Int, pixelHeight: Int, rgb: [UInt8] }
struct PdfResult { let bytes: [UInt8], pages: Int, missingCharacters: Int }

/// Primary faces with ordered fallbacks. Each code point uses the first face that maps it, so measurement and drawing agree.
/// There is no shaping: complex scripts that need contextual forms or reordering are drawn with their nominal glyphs.
/// Code points no face maps are drawn as the primary face's missing-glyph box and counted.
final class PdfFontSet {
    let size: Double
    private let regularFaces: [PdfFontFace]
    private let boldFaces: [PdfFontFace]
    var primary: PdfFontFace { regularFaces[0] }
    /// Headings are drawn larger, as in the editor.
    var headingScale = 1.25

    init(_ regular: [PdfFontFace], _ bold: [PdfFontFace], _ size: Double) throws {
        guard size > 0 && size < 200 else { throw CalcError.argument("Specified argument was out of the range of valid values. (Parameter 'size')") }
        guard !regular.isEmpty else { throw CalcError.argument("A regular face is required") }
        self.size = size; regularFaces = regular
        boldFaces = bold + regular.dropFirst(bold.isEmpty ? 0 : 1)
    }
    static func isBold(_ style: LayoutStyle) -> Bool { style == .heading || style == .result || style == .total }
    func sizeOf(_ style: LayoutStyle) -> Double { style == .heading ? size * headingScale : size }
    func measure(_ text: String, _ style: LayoutStyle) -> Double { glyphs(text, PdfFontSet.isBold(style)).reduce(0) { $0 + $1.advance } * sizeOf(style) }

    struct Glyph { let face: PdfFontFace, id: UInt16, advance: Double, text: String, missing: Bool }
    func glyphs(_ text: String, _ bold: Bool) -> [Glyph] {
        let faces = bold ? boldFaces : regularFaces
        var result: [Glyph] = []
        for rune in text.unicodeScalars {
            let value = rune == "\t" ? 0x20 : Int(rune.value)
            if value < 0x20 || (0x7F..<0xA0).contains(value) { continue }
            if let (face, id) = faces.lazy.compactMap({ face in face.tryGetGlyph(value).flatMap { $0 != 0 ? (face, $0) : nil } }).first {
                result.append(Glyph(face: face, id: id, advance: face.advance(id), text: String(rune), missing: false)); continue
            }
            // Joiners, selectors and other format characters have no visible form; only visible characters count as missing.
            let category = rune.properties.generalCategory
            if category == .format || category == .nonspacingMark || (0xFE00...0xFE0F).contains(value) { continue }
            result.append(Glyph(face: faces[0], id: 0, advance: faces[0].advance(0), text: String(rune), missing: true))
        }
        return result
    }
}

/// Writes a laid-out sheet as PDF: Type0/CIDFontType2 fonts with Identity-H glyph codes, embedded TrueType programs, a ToUnicode map
/// so copied and searched text recovers the source characters, and figures as Flate-compressed RGB images. The output is not a tagged PDF.
enum PdfSheetWriter {
    private final class UsedFace {
        let face: PdfFontFace, resource: String
        var glyphs: [UInt16: (advance: Double, text: String)] = [:]
        init(_ face: PdfFontFace, _ resource: String) { self.face = face; self.resource = resource }
    }

    static func write(_ layout: SheetLayout, _ fonts: PdfFontSet, _ colors: PdfColors, _ title: String, figures: ((LayoutFigure) -> PdfImage?)? = nil) throws -> PdfResult {
        if layout.options.continuous { throw CalcError.argument("PDF needs a paged layout") }
        let pdf = PdfWriter()
        let catalog = pdf.reserve(), pagesId = pdf.reserve(), resources = pdf.reserve()
        var faces: [UsedFace] = []
        var images: [(resource: String, id: Int)] = []
        var pageIds: [Int] = [], missing = 0
        let primary = fonts.primary, lineHeight = layout.options.lineHeight
        func baseline(_ size: Double) -> Double { (lineHeight - (primary.ascent + primary.descent) * size) / 2 + primary.ascent * size }
        let height = layout.options.pageHeight
        for page in layout.pages {
            var content = ""
            for figure in page.figures {
                guard let image = figures?(figure) else { continue }
                if image.pixelWidth <= 0 || image.pixelHeight <= 0 || image.rgb.count != image.pixelWidth * image.pixelHeight * 3 { throw CalcError.argument("Invalid figure image") }
                let resource = "Im" + String(images.count + 1)
                images.append((resource, try pdf.addStream("/Type /XObject /Subtype /Image /Width \(image.pixelWidth) /Height \(image.pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8", image.rgb)))
                content += "q " + PdfWriter.number(figure.width) + " 0 0 " + PdfWriter.number(figure.height) + " " + PdfWriter.number(figure.x) + " " +
                    PdfWriter.number(height - figure.top - figure.height) + " cm /" + resource + " Do Q\n"
            }
            content += "BT\n"
            for run in page.runs {
                switch run.style {
                case .result, .total: content += try color(colors.result)
                case .error: content += try color(colors.error)
                case .heading: content += try color(colors.heading)
                case .source: content += try color(colors.source)
                }
                let size = fonts.sizeOf(run.style)
                var x = run.x
                let y = height - run.top - baseline(size)
                var current: UsedFace?, hex = ""
                func flush() {
                    guard let current, !hex.isEmpty else { return }
                    content += "/" + current.resource + " " + PdfWriter.number(size) + " Tf 1 0 0 1 " + PdfWriter.number(x) + " " + PdfWriter.number(y) + " Tm <" + hex + "> Tj\n"
                    hex = ""
                }
                var segmentX = x
                for glyph in fonts.glyphs(run.text, PdfFontSet.isBold(run.style)) {
                    if glyph.missing { missing += 1 }
                    let used: UsedFace
                    if let known = faces.first(where: { $0.face === glyph.face }) { used = known }
                    else { used = UsedFace(glyph.face, "F" + String(faces.count + 1)); faces.append(used) }
                    if used.glyphs[glyph.id] == nil { used.glyphs[glyph.id] = (glyph.advance, glyph.missing ? "\u{FFFD}" : glyph.text) }
                    if current !== used { flush(); x = segmentX; current = used }
                    hex += String(format: "%04X", Int(glyph.id))
                    segmentX += glyph.advance * size
                }
                flush()
            }
            content += "ET\n"
            let contents = try pdf.addStream("", Array(content.utf8))
            pageIds.append(pdf.add("<< /Type /Page /Parent \(PdfWriter.ref(pagesId)) /MediaBox [0 0 \(PdfWriter.number(layout.width)) \(PdfWriter.number(height))] /Resources \(PdfWriter.ref(resources)) /Contents \(PdfWriter.ref(contents)) >>"))
        }
        var fontEntries = ""
        for used in faces {
            let face = used.face
            if used.glyphs[0] == nil { used.glyphs[0] = (face.advance(0), "\u{FFFD}") }
            let ids = used.glyphs.keys.sorted()
            let (program, subset) = try face.fontProgram(ids)
            let name = (subset ? tag(face.name, ids) + "+" : "") + postScriptName(face.name)
            let file = try pdf.addStream("/Length1 " + String(program.count), program)
            let descriptor = pdf.add("<< /Type /FontDescriptor /FontName /\(name) /Flags 32 /FontBBox [-1000 \(PdfWriter.number(-face.descent * 1000)) 2000 \(PdfWriter.number(face.ascent * 1000))] /ItalicAngle 0 " +
                "/Ascent \(PdfWriter.number(face.ascent * 1000)) /Descent \(PdfWriter.number(-face.descent * 1000)) /CapHeight \(PdfWriter.number(face.capHeight * 1000)) /StemV 80 /FontFile2 \(PdfWriter.ref(file)) >>")
            let widths = ids.map { String($0) + " [" + PdfWriter.number(used.glyphs[$0]!.advance * 1000) + "] " }.joined()
            let cid = pdf.add("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /\(name) /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " +
                "/FontDescriptor \(PdfWriter.ref(descriptor)) /DW 1000 /W [\(widths)] /CIDToGIDMap /Identity >>")
            let unicode = try pdf.addStream("", Array(toUnicode(ids.map { ($0, used.glyphs[$0]!.text) }).utf8))
            let font = pdf.add("<< /Type /Font /Subtype /Type0 /BaseFont /\(name) /Encoding /Identity-H /DescendantFonts [\(PdfWriter.ref(cid))] /ToUnicode \(PdfWriter.ref(unicode)) >>")
            fontEntries += "/" + used.resource + " " + PdfWriter.ref(font) + " "
        }
        let imageEntries: [String] = images.map { image in "/" + image.resource + " " + PdfWriter.ref(image.id) + " " }
        let xobjects = images.isEmpty ? "" : " /XObject << " + imageEntries.joined() + ">>"
        pdf.set(resources, "<< /ProcSet [/PDF /Text /ImageC] /Font << \(fontEntries)>>\(xobjects) >>")
        pdf.set(pagesId, "<< /Type /Pages /Kids [\(pageIds.map(PdfWriter.ref).joined(separator: " "))] /Count \(pageIds.count) >>")
        pdf.set(catalog, "<< /Type /Catalog /Pages \(PdfWriter.ref(pagesId)) /ViewerPreferences << /DisplayDocTitle true >> >>")
        let info = pdf.add("<< /Title \(PdfWriter.textString(title)) /Producer \(PdfWriter.textString("QNotch")) >>")
        return PdfResult(bytes: try pdf.finish(catalog, info), pages: pageIds.count, missingCharacters: missing)
    }

    private static func color(_ hex: String) throws -> String {
        let c = hex.netTrimStart("#")
        guard c.netLength == 6, c.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 | 0x20 >= 97 && $0 | 0x20 <= 102) }), let rgb = Int(c, radix: 16) else {
            throw CalcError.argument("Colours are #RRGGBB")
        }
        return PdfWriter.number(Double((rgb >> 16) & 255) / 255) + " " + PdfWriter.number(Double((rgb >> 8) & 255) / 255) + " " + PdfWriter.number(Double(rgb & 255) / 255) + " rg\n"
    }

    static func toUnicode(_ glyphs: [(id: UInt16, text: String)]) -> String {
        var map = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" +
            "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        let mapped = glyphs.filter { $0.id != 0 }
        for start in stride(from: 0, to: mapped.count, by: 100) {
            let chunk = mapped[start..<min(start + 100, mapped.count)]
            map += String(chunk.count) + " beginbfchar\n"
            for (id, text) in chunk { map += "<" + String(format: "%04X", Int(id)) + "> <" + text.utf16.map { String(format: "%04X", Int($0)) }.joined() + ">\n" }
            map += "endbfchar\n"
        }
        return map + "endcmap\nCMapName currentdict /CMapResource defineresource pop\nend\nend\n"
    }

    private static func postScriptName(_ name: String) -> String {
        let clean = name.utf16.filter { $0 > 0x20 && $0 < 0x7F && !Array("()<>[]{}/%#".utf16).contains($0) }
        return clean.isEmpty ? "Font" : String(units: clean.prefix(63))
    }
    // A subset tag is six capital letters; derive it from the glyph set so identical exports are byte-identical.
    private static func tag(_ name: String, _ glyphs: [UInt16]) -> String {
        var hash: UInt32 = 2_166_136_261
        for c in name.utf16 { hash = (hash ^ UInt32(c)) &* 16_777_619 }
        for g in glyphs { hash = (hash ^ UInt32(g)) &* 16_777_619 }
        var tag = ""
        for _ in 0..<6 { tag.unicodeScalars.append(Unicode.Scalar(UInt8(65 + hash % 26))); hash /= 26 }
        return tag
    }
}
