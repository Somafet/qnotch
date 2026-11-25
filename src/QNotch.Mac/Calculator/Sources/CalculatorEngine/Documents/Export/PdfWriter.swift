import Foundation
import zlib

/// Minimal PDF 1.7 object writer: numbered objects, Flate streams, a classic cross-reference table and trailer.
/// It knows nothing about sheets; `PdfSheetWriter` builds the document on top of it.
final class PdfWriter {
    private var objects: [[UInt8]?] = []

    func reserve() -> Int { objects.append(nil); return objects.count }
    func add(_ body: String) -> Int { let id = reserve(); set(id, body); return id }
    func set(_ id: Int, _ body: String) { objects[id - 1] = Array(body.utf8) }
    func addStream(_ dictionary: String, _ data: [UInt8], compress: Bool = true) throws -> Int {
        let id = reserve(); try setStream(id, dictionary, data, compress: compress); return id
    }
    func setStream(_ id: Int, _ dictionary: String, _ data: [UInt8], compress: Bool = true) throws {
        let payload = compress ? try PdfWriter.deflate(data) : data
        let head = Array(("<< " + dictionary + (compress ? " /Filter /FlateDecode" : "") + " /Length " + String(payload.count) + " >>\nstream\n").utf8)
        objects[id - 1] = head + payload + Array("\nendstream".utf8)
    }

    func finish(_ catalog: Int, _ info: Int?) throws -> [UInt8] {
        var output: [UInt8] = []
        func write(_ text: String) { output.append(contentsOf: text.utf8) }
        write("%PDF-1.7\n"); output.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            guard let body else { throw CalcError.invalidOperation("PDF object \(i + 1) was reserved but never written") }
            offsets.append(output.count)
            write(String(i + 1) + " 0 obj\n"); output.append(contentsOf: body); write("\nendobj\n")
        }
        let xref = output.count
        write("xref\n0 " + String(objects.count + 1) + "\n0000000000 65535 f\r\n")
        for offset in offsets { write(pad(offset, 10) + " 00000 n\r\n") }
        write("trailer\n<< /Size " + String(objects.count + 1) + " /Root " + PdfWriter.ref(catalog) + (info.map { " /Info " + PdfWriter.ref($0) } ?? "") +
              " >>\nstartxref\n" + String(xref) + "\n%%EOF\n")
        return output
    }

    static func ref(_ id: Int) -> String { String(id) + " 0 R" }
    /// `Math.Round(value, 3).ToString("0.###", InvariantCulture)`.
    static func number(_ value: Double) -> String { NetFormat.double(NetMath.round(value, 3), "0.###") }
    /// Text string as UTF-16BE with a byte-order mark, which represents any Unicode text.
    static func textString(_ text: String) -> String {
        "<FEFF" + text.utf16.map { String(format: "%04X", Int($0)) }.joined() + ">"
    }
    /// zlib-wrapped DEFLATE (FlateDecode), at zlib's default level (.NET's CompressionLevel.Optimal). The bytes need not match .NET's.
    static func deflate(_ data: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CalcError.invalidOperation("Compression unavailable")
        }
        defer { deflateEnd(&stream) }
        var input = data
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(data.count))) + 16)
        let status = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer -> Int32 in
                stream.next_in = inBuffer.baseAddress; stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress; stream.avail_out = uInt(outBuffer.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw CalcError.invalidOperation("Compression failed") }
        return Array(output[..<Int(stream.total_out)])
    }
}
