import Foundation

/// GitHub's OAuth device flow (spec/onboarding.md, "GitHub device flow"): the two requests and
/// what their answers mean. No I/O here; the sign-in view sends the requests and keeps the timer.
public enum GithubDeviceFlow {
    public static let codeURL = URL(string: "https://github.com/login/device/code")!
    public static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    public static let scope = "read:user"
    public static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    public static let expiredMessage = "The code expired."
    public static let deniedMessage = "Sign-in was cancelled on GitHub."

    /// What GitHub answered to step 1.
    public struct Code: Equatable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURL: URL
        public let expiresIn: TimeInterval
        public let interval: TimeInterval
        public init(deviceCode: String, userCode: String, verificationURL: URL, expiresIn: TimeInterval, interval: TimeInterval) {
            self.deviceCode = deviceCode; self.userCode = userCode; self.verificationURL = verificationURL
            self.expiresIn = expiresIn; self.interval = interval
        }
    }

    /// One answer while polling for the token.
    public enum Poll: Equatable {
        case pending
        /// Wait longer: GitHub's new interval when it sends one.
        case slowDown(interval: TimeInterval?)
        case token(String)
        case expired
        case denied
        case failed(String)
    }

    public static func codeRequest(clientID: String) -> URLRequest {
        post(codeURL, [("client_id", clientID), ("scope", scope)])
    }

    public static func tokenRequest(clientID: String, deviceCode: String) -> URLRequest {
        post(tokenURL, [("client_id", clientID), ("device_code", deviceCode), ("grant_type", grantType)])
    }

    private static func post(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("QNotch", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(form(fields).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded`, escaping everything but RFC 3986 unreserved characters.
    public static func form(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    private static func object(_ body: Data?) -> [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func failure(_ root: [String: Any], _ error: String) -> String {
        if let description = root["error_description"] as? String, !description.isEmpty { return String(description.prefix(200)) }
        return "GitHub refused the sign-in (\(String(error.prefix(60))))."
    }

    /// Step 1's answer, or the error to show.
    public static func parseCode(status: Int?, body: Data?, transportFailed: Bool) throws -> Code {
        if transportFailed { throw GithubError.message("No connection to GitHub.", offline: true) }
        let root = object(body)
        if let root, let error = root["error"] as? String { throw GithubError.message(failure(root, error), offline: false) }
        guard (200..<300).contains(status ?? 0) else { throw GithubError.message("GitHub returned \(status ?? 0).", offline: false) }
        guard let root, let device = root["device_code"] as? String, !device.isEmpty,
              let user = root["user_code"] as? String, !user.isEmpty, user.count <= 32,
              let link = root["verification_uri"] as? String, let url = URL(string: link), url.scheme == "https",
              let expires = seconds(root["expires_in"]) else {
            throw GithubError.message("GitHub sent an unexpected response.", offline: false)
        }
        // GitHub sends 5 seconds; never poll faster than that.
        let interval = max(5, seconds(root["interval"]) ?? 5)
        return Code(deviceCode: device, userCode: user, verificationURL: url, expiresIn: expires, interval: interval)
    }

    /// One poll's answer. GitHub reports pending, slow_down and the rest with status 200.
    public static func parsePoll(status: Int?, body: Data?, transportFailed: Bool) -> Poll {
        if transportFailed { return .failed("No connection to GitHub.") }
        guard let root = object(body) else {
            return .failed((200..<300).contains(status ?? 0) ? "GitHub sent an unexpected response." : "GitHub returned \(status ?? 0).")
        }
        if let token = root["access_token"] as? String, !token.isEmpty { return .token(token) }
        guard let error = root["error"] as? String else {
            return .failed((200..<300).contains(status ?? 0) ? "GitHub sent an unexpected response." : "GitHub returned \(status ?? 0).")
        }
        switch error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(interval: seconds(root["interval"]))
        case "expired_token": return .expired
        case "access_denied": return .denied
        default: return .failed(failure(root, error))
        }
    }

    /// The wait before the next poll: slow_down adds 5 seconds, or uses GitHub's longer interval.
    public static func nextInterval(after poll: Poll, current: TimeInterval) -> TimeInterval {
        guard case .slowDown(let given) = poll else { return current }
        return max(current + 5, given ?? 0)
    }
}
