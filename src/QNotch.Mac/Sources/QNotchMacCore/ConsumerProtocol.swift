import Foundation

public struct ConsumerRequest: Codable {
    public var schema_version = 1
    public let command: String
    public var details = false
    public var provider: String?
    public var account: String?
    public init(command: String, details: Bool = false, provider: String? = nil, account: String? = nil) {
        self.command = command; self.details = details; self.provider = provider; self.account = account
    }
    private enum CodingKeys: String, CodingKey { case schema_version, command, details, provider, account }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try c.decode(Int.self, forKey: .schema_version)
        command = try c.decode(String.self, forKey: .command)
        details = try c.decodeIfPresent(Bool.self, forKey: .details) ?? false
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
    public func validate() throws {
        guard schema_version == 1 else { throw ConsumerFailure("unsupported_version") }
        guard ["usage", "agents"].contains(command), provider == nil || ["claude", "codex"].contains(provider!),
              account == nil || (1...128).contains(account!.utf8.count), command == "usage" || (provider == nil && account == nil) else {
            throw ConsumerFailure("invalid_arguments")
        }
    }
    public static func parse(_ args: [String]) throws -> (ConsumerRequest, String?) {
        guard let command = args.first else { throw ConsumerFailure("invalid_arguments") }
        var result = ConsumerRequest(command: command), directory: String?, seen = Set<String>(), i = 1
        while i < args.count {
            let flag = args[i]; i += 1
            guard seen.insert(flag).inserted else { throw ConsumerFailure("invalid_arguments") }
            switch flag {
            case "--json": break
            case "--details": result.details = true
            case "--provider", "--account", "--data-dir":
                guard i < args.count, !args[i].hasPrefix("--") else { throw ConsumerFailure("invalid_arguments") }
                let value = args[i]; i += 1
                if flag == "--provider" { result.provider = value }
                else if flag == "--account" { result.account = value }
                else { directory = value }
            default: throw ConsumerFailure("invalid_arguments")
            }
        }
        try result.validate()
        return (result, directory)
    }
}

public struct ConsumerFailure: Error {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var data: Data { ConsumerJSON.encode(["schema_version": 1, "error": ["code": code, "message": "Consumer query failed: \(code)."]]) }
}

public enum ConsumerJSON {
    public static let null = NSNull()
    public static func encode(_ object: [String: Any]) -> Data {
        // Projections contain only JSON values; fail closed on nonfinite/provider-invalid values.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? ConsumerFailure("internal_error").fallback
    }
    public static func instant(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from: $0) } ?? null as Any }
    public static func text(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }).prefix(256))
    }
}
private extension ConsumerFailure { var fallback: Data { Data("{\"schema_version\":1,\"error\":{\"code\":\"internal_error\",\"message\":\"Invalid snapshot.\"}}".utf8) } }
