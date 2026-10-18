import Foundation

/// The Mac update channel. Never GitHub's global `/releases/latest`, which belongs to Windows.
public enum UpdateChannel {
    public static let tagPrefix = "macos-v"
    /// Sparkle appcast kept on the `macos-appcast` branch by the `macos-v*` release workflow.
    /// The feed and every update in it are EdDSA signed, so the host is not trusted.
    public static let feedURL = URL(string: "https://raw.githubusercontent.com/Somafet/qnotch/macos-appcast/appcast.xml")!
    /// Prerelease tags (`-alpha.N`, `-beta.N`, `-rc.N`) are published to this Sparkle channel.
    public static let betaChannel = "beta"

    public static func accepts(tag: String) -> Bool {
        tag.range(of: #"\Amacos-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?\z"#, options: .regularExpression) != nil
    }

    /// Sparkle channels offered besides the default (stable) one.
    public static func channels(beta: Bool) -> Set<String> { beta ? [betaChannel] : [] }
}
