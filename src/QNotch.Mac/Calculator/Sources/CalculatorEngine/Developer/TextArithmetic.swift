import Foundation
import CryptoKit

/// Byte codecs and digests over exact UTF-8 text (C# TextArithmetic).
final class TextArithmetic {
    static let maximumBytes = 65536
    static let convention = "Exact UTF-8 text; no BOM, case folding or Unicode normalization; codecs transform text only"
    /// System.Convert.FromBase64String's own message, which reaches the line for malformed padding.
    static let invalidBase64Message = "The input is not a valid Base-64 string as it contains a non-base 64 character, more than two padding characters, or an illegal character among the padding characters."
    static func isFunction(_ name: String) -> Bool { ["text", "base64", "decodebase64", "urlencode", "urldecode", "md5", "sha1", "sha256"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 1 { throw CalcError.format("\(name) expects 1 argument") } }
    private let budget: ExecutionBudget
    private let token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func charge(_ length: Int) throws { var i = 0; while i <= length { try budget.step(token); i += 64 } }
    private static func require(_ value: SheetValue) throws -> String {
        guard case .text(let text) = value else { throw CalcError.arithmetic("Expected text; use a quoted text argument or text(\"…\")") }
        return text.value
    }
    func literal(_ value: String) throws -> SheetValue { try charge(value.netLength); return .text(try TextValue(value)) }

    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, evidence: TextTransformEvidence) {
        try TextArithmetic.validateArity(name, args.count); let input = try TextArithmetic.require(args[0]); try charge(input.netLength)
        if input.utf8.count > TextArithmetic.maximumBytes { throw CalcError.arithmetic("Text operation exceeds 65536 UTF-8 bytes") }
        let bytes = Array(input.utf8); try charge(bytes.count); let key = name.netLower
        let output: String
        switch key {
        case "text": output = input
        case "base64":
            if (bytes.count + 2) / 3 * 4 > TextValue.maximumLength { throw CalcError.arithmetic("Encoded text exceeds output limit") }
            output = Data(bytes).base64EncodedString()
        case "decodebase64": output = try TextArithmetic.decodeBase64(input)
        case "urlencode": output = try encodeUrl(bytes)
        case "urldecode": output = try decodeUrl(input)
        case "md5": output = TextArithmetic.hex(Insecure.MD5.hash(data: Data(bytes)))
        case "sha1": output = TextArithmetic.hex(Insecure.SHA1.hash(data: Data(bytes)))
        case "sha256": output = TextArithmetic.hex(SHA256.hash(data: Data(bytes)))
        default: throw CalcError.format("Unknown text function")
        }
        try TextValue.validate(output); try charge(output.netLength)
        let preview = TextArithmetic.hex(bytes.prefix(32)) + (bytes.count > 32 ? "…" : "")
        return (.text(try TextValue(output)), TextTransformEvidence(operation: name, input: input, output: output, inputUtf8Bytes: bytes.count,
                                                                    outputUtf8Bytes: output.utf8.count, inputBytePreview: preview, inputPreview: try args[0].display))
    }
    /// Convert.ToHexStringLower.
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    /// Encoding.UTF8 with throwOnInvalidBytes: strict decoding; overlong forms, surrogates and truncated sequences fail.
    static func decodeUtf8(_ bytes: [UInt8]) throws -> String {
        var scalars = String.UnicodeScalarView(); var iterator = bytes.makeIterator(); var decoder = UTF8()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: throw CalcError.format("Decoded bytes are not valid UTF-8 text")
            }
        }
        return String(scalars)
    }
    private static func decodeBase64(_ input: String) throws -> String {
        let u = input.units
        if u.count % 4 != 0 || u.contains(where: { !NetChar.isAsciiLetterOrDigit($0) && $0 != 0x2B && $0 != 0x2F && $0 != 0x3D }) {
            throw CalcError.format("Expected canonical padded standard Base64 without whitespace")
        }
        let bytes = try fromBase64(u)
        if Data(bytes).base64EncodedString() != input { throw CalcError.format("Noncanonical Base64 padding or pad bits") }
        return try decodeUtf8(bytes)
    }
    /// Convert.FromBase64String for whitespace-free input of whole quanta: padding only at the end, at most two
    /// characters; nonzero pad bits are accepted (the canonical check above rejects them).
    private static func fromBase64(_ u: [UInt16]) throws -> [UInt8] {
        func value(_ c: UInt16) -> Int? {
            switch c {
            case 65...90: return Int(c) - 65
            case 97...122: return Int(c) - 97 + 26
            case 48...57: return Int(c) - 48 + 52
            case 0x2B: return 62
            case 0x2F: return 63
            default: return nil
            }
        }
        var padding = 0; var end = u.count
        while end > 0 && u[end - 1] == 0x3D { padding += 1; end -= 1 }
        if padding > 2 || u[..<end].contains(0x3D) { throw CalcError.format(invalidBase64Message) }
        var bytes: [UInt8] = []; var buffer = 0; var bits = 0
        for c in u[..<end] {
            buffer = buffer << 6 | value(c)!; bits += 6
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
        }
        return bytes
    }
    private func encodeUrl(_ bytes: [UInt8]) throws -> String {
        func unreserved(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x7E }
        let length = bytes.reduce(0) { $0 + (unreserved($1) ? 1 : 3) }
        if length > TextValue.maximumLength { throw CalcError.arithmetic("Encoded text exceeds output limit") }
        let hex = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []; result.reserveCapacity(length)
        for (i, b) in bytes.enumerated() {
            if i & 63 == 0 { try budget.step(token) }
            if unreserved(b) { result.append(b) } else { result.append(0x25); result.append(hex[Int(b / 16)]); result.append(hex[Int(b % 16)]) }
        }
        return String(decoding: result, as: UTF8.self)
    }
    private func decodeUrl(_ text: String) throws -> String {
        let u = text.units
        var bytes: [UInt8] = []; var work = 0; var i = 0
        func digit(_ c: UInt16) -> Int { c <= 0x39 ? Int(c) - 48 : Int(NetChar.upper(c)) - 65 + 10 }
        while i < u.count {
            if work & 63 == 0 { try budget.step(token) }
            work += 1
            if u[i] == 0x25 {
                if i + 2 >= u.count || !NetChar.isAsciiHexDigit(u[i + 1]) || !NetChar.isAsciiHexDigit(u[i + 2]) { throw CalcError.format("Invalid URL percent escape") }
                bytes.append(UInt8(16 * digit(u[i + 1]) + digit(u[i + 2]))); i += 3
            } else {
                // Text values hold only paired surrogates, so a high surrogate starts a two-unit scalar.
                let length = NetChar.isHighSurrogate(u[i]) ? 2 : 1
                bytes.append(contentsOf: Array(u[i..<(i + length)].string.utf8)); i += length
            }
            if bytes.count > TextArithmetic.maximumBytes { throw CalcError.arithmetic("Decoded bytes exceed text operation limit") }
        }
        return try TextArithmetic.decodeUtf8(bytes)
    }
}
