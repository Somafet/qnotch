import Foundation
import QNotchMacCore

// Pure Taildrop rules: LocalAPI JSON parsing, names, escaping and the module's published state.
// No I/O here, so every rule is covered by XCTest.

/// `BackendState` from the LocalAPI `status` answer.
enum TaildropBackend: Equatable {
    case running, stopped, needsLogin, needsMachineAuth, starting
    /// Any other state Tailscale reports (`InUseOtherUser`, future states), shown verbatim.
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "Running": self = .running
        case "Stopped": self = .stopped
        case "NeedsLogin": self = .needsLogin
        case "NeedsMachineAuth": self = .needsMachineAuth
        case "Starting", "NoState", "": self = .starting
        default: self = .other(raw)
        }
    }
}

/// Why Taildrop can or cannot be used right now. Each unavailable case has explicit text and one
/// action (open the Tailscale app, or its download page); nothing is shown as zero devices.
enum TaildropAvailability: Equatable {
    case checking
    case notInstalled
    case notRunning
    /// The Mac App Store edition keeps its local API inside its sandbox; see TaildropClient.
    case appStoreEdition
    /// The local API's same-user key exists but this account cannot read it.
    case noAccess
    case disconnected
    case needsLogin
    case needsApproval
    case starting
    case other(String)
    case ready

    init(_ backend: TaildropBackend) {
        switch backend {
        case .running: self = .ready
        case .stopped: self = .disconnected
        case .needsLogin: self = .needsLogin
        case .needsMachineAuth: self = .needsApproval
        case .starting: self = .starting
        case .other(let raw): self = .other(raw)
        }
    }

    enum Action: Equatable { case openApp, download }

    struct Notice: Equatable {
        let symbol: String
        let title: String
        let detail: String
        let action: Action?
        var actionTitle: String? {
            switch action {
            case .openApp?: return "Open Tailscale"
            case .download?: return "Get Tailscale"
            case nil: return nil
            }
        }
    }

    /// The explanation shown instead of the device grid; nil when the grid can show.
    func notice(hasTargets: Bool) -> Notice? {
        switch self {
        case .checking:
            return Notice(symbol: "antenna.radiowaves.left.and.right", title: "Looking for Tailscale…", detail: "Checking the Tailscale service on this Mac.", action: nil)
        case .notInstalled:
            return Notice(symbol: "network.slash", title: "Tailscale is not installed", detail: "Taildrop sends files between your devices on Tailscale.", action: .download)
        case .notRunning:
            return Notice(symbol: "network.slash", title: "Tailscale is not running", detail: "Open Tailscale to send files to your devices.", action: .openApp)
        case .appStoreEdition:
            return Notice(symbol: "lock.shield", title: "This Tailscale edition can't be reached", detail: "The App Store edition keeps its connection private. The standalone app from tailscale.com works with QNotch.", action: .download)
        case .noAccess:
            return Notice(symbol: "lock.shield", title: "No access to Tailscale", detail: "This Mac account can't read Tailscale's local key. An administrator account can.", action: .openApp)
        case .disconnected:
            return Notice(symbol: "bolt.horizontal.circle", title: "Tailscale is disconnected", detail: "Connect in Tailscale to send files to your devices.", action: .openApp)
        case .needsLogin:
            return Notice(symbol: "person.crop.circle.badge.questionmark", title: "Sign in to Tailscale", detail: "Taildrop needs a signed-in Tailscale account.", action: .openApp)
        case .needsApproval:
            return Notice(symbol: "person.crop.circle.badge.clock", title: "Waiting for approval", detail: "An admin of your tailnet needs to approve this Mac.", action: .openApp)
        case .starting:
            return Notice(symbol: "hourglass", title: "Tailscale is starting…", detail: "Devices show up once it is connected.", action: nil)
        case .other(let raw):
            return Notice(symbol: "exclamationmark.triangle", title: "Tailscale is not ready", detail: "Tailscale reports \(raw).", action: .openApp)
        case .ready:
            return hasTargets ? nil : Notice(symbol: "laptopcomputer.and.iphone", title: "No devices can receive files",
                                             detail: "Taildrop sends to your own devices on this tailnet.", action: .openApp)
        }
    }

    /// One line for the Home card.
    var shortText: String {
        switch self {
        case .checking: return "Looking for Tailscale…"
        case .notInstalled: return "Tailscale is not installed"
        case .notRunning: return "Tailscale is not running"
        case .appStoreEdition: return "This Tailscale edition can't be reached"
        case .noAccess: return "No access to Tailscale"
        case .disconnected: return "Tailscale is disconnected"
        case .needsLogin: return "Sign in to Tailscale"
        case .needsApproval: return "Waiting for approval"
        case .starting: return "Tailscale is starting…"
        case .other: return "Tailscale is not ready"
        case .ready: return "No devices can receive files"
        }
    }
}

/// A device Taildrop can send to (one entry of `file-targets`).
struct TaildropTarget: Equatable {
    let id: String
    let name: String
    /// Hostinfo.OS as Tailscale reports it ("macOS", "iOS", "android", "windows", "linux").
    let os: String
    let online: Bool

    var osLabel: String {
        switch os.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "android": return "Android"
        case "windows": return "Windows"
        case "linux": return "Linux"
        case "freebsd": return "FreeBSD"
        case "": return "Device"
        default: return os
        }
    }

    var symbol: String {
        switch os.lowercased() {
        case "macos": return "laptopcomputer"
        case "ios": return "ipad.and.iphone"
        case "android": return "smartphone"
        case "windows": return "pc"
        case "linux", "freebsd": return "server.rack"
        default: return "desktopcomputer"
        }
    }
}

/// A file waiting in the Taildrop inbox (`files/`).
struct TaildropWaitingFile: Equatable {
    let name: String
    let size: Int64
}

enum TaildropJSON {
    private struct FileTarget: Decodable {
        let node: Node?
        enum CodingKeys: String, CodingKey { case node = "Node" }
        struct Node: Decodable {
            let stableID: String?, name: String?, computedName: String?, online: Bool?, hostinfo: Hostinfo?
            enum CodingKeys: String, CodingKey {
                case stableID = "StableID", name = "Name", computedName = "ComputedName", online = "Online", hostinfo = "Hostinfo"
            }
        }
        struct Hostinfo: Decodable {
            let os: String?
            enum CodingKeys: String, CodingKey { case os = "OS" }
        }
    }
    private struct Status: Decodable {
        let backendState: String?
        enum CodingKeys: String, CodingKey { case backendState = "BackendState" }
    }
    private struct Waiting: Decodable {
        let name: String?, size: Int64?
        enum CodingKeys: String, CodingKey { case name = "Name", size = "Size" }
    }

    /// `file-targets`: online first, then by name. Entries without a StableID are skipped. `null` is empty.
    static func targets(from data: Data) throws -> [TaildropTarget] {
        let list = try JSONDecoder().decode([FileTarget]?.self, from: data) ?? []
        let targets: [TaildropTarget] = list.compactMap { entry in
            guard let node = entry.node, let id = node.stableID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
            return TaildropTarget(id: id, name: displayName(computed: node.computedName, dnsName: node.name, fallback: id),
                                  os: node.hostinfo?.os ?? "", online: node.online ?? true)
        }
        return sorted(targets)
    }

    static func sorted(_ targets: [TaildropTarget]) -> [TaildropTarget] {
        targets.sorted { a, b in
            if a.online != b.online { return a.online }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    /// ComputedName when Tailscale has one, else the first label of the MagicDNS name.
    static func displayName(computed: String?, dnsName: String?, fallback: String) -> String {
        if let computed = computed?.trimmingCharacters(in: .whitespaces), !computed.isEmpty { return computed }
        if let label = dnsName?.split(separator: ".", omittingEmptySubsequences: true).first, !label.isEmpty { return String(label) }
        return fallback
    }

    static func backend(from data: Data) throws -> TaildropBackend {
        TaildropBackend(try JSONDecoder().decode(Status.self, from: data).backendState ?? "")
    }

    /// `files/`: `null` when empty. Names that could leave the Downloads folder are dropped.
    static func waiting(from data: Data) throws -> [TaildropWaitingFile] {
        (try JSONDecoder().decode([Waiting]?.self, from: data) ?? []).compactMap { file in
            guard let name = file.name, TaildropNames.isSafeInboxName(name) else { return nil }
            return TaildropWaitingFile(name: name, size: max(0, file.size ?? 0))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum TaildropNames {
    /// A name from the inbox that is safe to create in Downloads: one path component, no `..`,
    /// no separators or control characters, at most 255 bytes.
    static func isSafeInboxName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", !name.contains(".."),
              name.trimmingCharacters(in: .whitespaces) == name else { return false }
        return !name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || "/\\:".unicodeScalars.contains(scalar)
        }
    }

    /// Percent-encodes one URL path segment: only unreserved characters stay literal.
    static func pathEscape(_ segment: String) -> String {
        var out = ""
        for byte in segment.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// A name that does not exist yet: "name.ext", then "name (2).ext", "name (3).ext"…
    static func freeName(_ name: String, taken: (String) -> Bool) -> String {
        FileTrayList.uniqueName(name, taken: taken)
    }
}

/// A send in progress, as the views show it.
struct TaildropTransfer: Equatable {
    let deviceID: String
    let deviceName: String
    var fileName: String
    var index: Int
    let count: Int
    /// 0…1 over all files' bytes.
    var fraction: Double

    var percent: Int { Int((min(1, max(0, fraction)) * 100).rounded(.down)) }
    var text: String {
        count > 1 ? "Sending \(fileName) to \(deviceName) · \(index) of \(count)" : "Sending \(fileName) to \(deviceName)"
    }
    var tileText: String { "Sending · \(percent)%" }
}

/// The footer line after a send or save.
struct TaildropResult: Equatable {
    let text: String
    let success: Bool
    /// A saved file; the footer offers Show.
    var reveal: URL?

    static func sent(_ count: Int, firstName: String, to device: String, skippedFolders: Int) -> TaildropResult {
        let what = count == 1 ? firstName : "\(count) files"
        return TaildropResult(text: "Sent \(what) to \(device)" + skippedSuffix(skippedFolders), success: true)
    }

    static func failed(_ name: String, to device: String, sent: Int, count: Int, reason: String) -> TaildropResult {
        let prefix = sent > 0 ? "Sent \(sent) of \(count). " : ""
        return TaildropResult(text: "\(prefix)Couldn't send \(name) to \(device): \(reason)", success: false)
    }

    static func skippedSuffix(_ folders: Int) -> String {
        folders == 0 ? "" : folders == 1 ? " · Skipped a folder" : " · Skipped \(folders) folders"
    }

    static let foldersOnly = TaildropResult(text: "Taildrop sends files only. Folders were skipped.", success: false)
}

/// Everything a refresh publishes. The module applies it only when it changed, so an unchanged
/// 10-second refresh never reloads a view.
struct TaildropState: Equatable {
    var availability = TaildropAvailability.checking
    var targets: [TaildropTarget] = []
    var waiting: [TaildropWaitingFile] = []
    /// The last refresh failed; the previous list is kept.
    var message: String?

    /// Sets `new` when it differs; returns whether anything changed.
    @discardableResult
    mutating func update(to new: TaildropState) -> Bool {
        guard new != self else { return false }
        self = new
        return true
    }

    var onlineTargets: [TaildropTarget] { targets.filter(\.online) }

    var waitingText: String? {
        switch waiting.count {
        case 0: return nil
        case 1: return "\(waiting[0].name) is waiting in Taildrop"
        default: return "\(waiting.count) files are waiting in Taildrop"
        }
    }

    /// Demo data for `--snapshot` and `--smoke-test`: generic devices, never a real tailnet.
    static let demo = TaildropState(
        availability: .ready,
        targets: TaildropJSON.sorted([
            TaildropTarget(id: "demo-pixel", name: "pixel-8", os: "android", online: true),
            TaildropTarget(id: "demo-laptop", name: "work-laptop", os: "windows", online: true),
            TaildropTarget(id: "demo-ipad", name: "ipad-air", os: "iOS", online: true),
            TaildropTarget(id: "demo-nas", name: "home-nas", os: "linux", online: false)
        ]),
        waiting: [TaildropWaitingFile(name: "holiday-photos.zip", size: 48_200_000)])
}
