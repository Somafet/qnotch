import Foundation

/// Now playing from the Music and Spotify apps (the public, documented paths on macOS). Their
/// distributed notifications carry track and state; Apple Events add controls and position.
public struct NowPlaying: Equatable {
    public enum Source: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        public var name: String { self == .music ? "Music" : "Spotify" }
        public var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    }

    public var source: Source
    public var title: String
    public var artist: String
    public var album: String
    public var playing: Bool
    /// Seconds; nil for streams without a length.
    public var duration: Double?
    /// Position at `positionAt`; interpolated while playing.
    public var position: Double?
    public var positionAt: Date
    public var trackID: String

    public init(source: Source, title: String, artist: String, album: String, playing: Bool, duration: Double?, position: Double?, positionAt: Date, trackID: String) {
        self.source = source; self.title = title; self.artist = artist; self.album = album; self.playing = playing
        self.duration = duration; self.position = position; self.positionAt = positionAt; self.trackID = trackID
    }

    /// Nil when the player stopped (no session).
    public static func from(notification info: [AnyHashable: Any], source: Source, now: Date = Date()) -> NowPlaying? {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String, !title.isEmpty else { return nil }
        let milliseconds = (info[source == .music ? "Total Time" : "Duration"] as? NSNumber)?.doubleValue
        let id = (info["Track ID"] as? String) ?? (info["PersistentID"] as? NSNumber)?.stringValue ?? (info["Persistent ID"] as? NSNumber)?.stringValue ?? "\(title)|\(info["Artist"] ?? "")"
        return NowPlaying(source: source, title: title, artist: (info["Artist"] as? String) ?? (info["Album Artist"] as? String) ?? "",
                          album: info["Album"] as? String ?? "", playing: state == "Playing",
                          duration: milliseconds.flatMap { $0 > 0 ? $0 / 1000 : nil },
                          position: (info["Playback Position"] as? NSNumber)?.doubleValue, positionAt: now, trackID: id)
    }

    public func position(at now: Date) -> Double? {
        guard let position else { return nil }
        let value = playing ? position + now.timeIntervalSince(positionAt) : position
        return duration.map { min($0, max(0, value)) } ?? max(0, value)
    }

    public var subtitle: String { artist.isEmpty ? source.name : artist }

    public static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}
