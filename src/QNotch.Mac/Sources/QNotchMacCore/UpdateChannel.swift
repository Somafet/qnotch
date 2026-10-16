import Foundation

/// No updater/network activity in milestone one. A future updater must use this channel.
public enum UpdateChannel {
    public static let tagPrefix = "macos-v"
    public static let releasesURL = URL(string: "https://api.github.com/repos/Somafet/qnotch/releases")!
    public static func accepts(tag: String) -> Bool {
        tag.range(of: #"\Amacos-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?\z"#, options: .regularExpression) != nil
    }
}
