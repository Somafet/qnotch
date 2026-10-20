import Foundation
import Security

/// Secrets live in the login Keychain (generic passwords), never in files. Diagnostic runs with an
/// isolated data folder use an in-memory store so they never touch the user's Keychain.
enum Keychain {
    static var inMemory: [String: String]?

    static func read(_ service: String, account: String = "QNotch") -> String? {
        if let inMemory { return inMemory[service + "/" + account] }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, service: String, account: String = "QNotch") -> Bool {
        if inMemory != nil { inMemory?[service + "/" + account] = value; return true }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = service
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ service: String, account: String = "QNotch") {
        if inMemory != nil { inMemory?[service + "/" + account] = nil; return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }

    /// 24 random bytes as hex (Windows NotifyToken).
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Process-wide facts modules may consult.
enum Runtime {
    /// `--snapshot`, `--smoke-test` or `--measure`: no network requests, no Keychain, no sounds, demo
    /// data where a module needs some.
    static var diagnostics = false
    /// A diagnostic run's own data root (no `--data-dir` given), deleted when the process exits.
    static var temporaryRoot: URL?

    /// At exit: deletes `temporaryRoot` once this process is gone, so a module's last background
    /// write (the notification history) cannot recreate it afterwards.
    static func removeTemporaryRoot() {
        guard let root = temporaryRoot else { return }
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; rm -rf "$2""#, "qnotch-cleanup", String(getpid()), root.path]
        cleanup.standardInput = FileHandle.nullDevice
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        if (try? cleanup.run()) == nil { try? FileManager.default.removeItem(at: root) }
    }
}
