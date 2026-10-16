import Foundation

/// Which capture devices are in use, and by which apps where macOS says so (Windows CaptureWatch).
public struct CaptureState: Equatable {
    public var microphone = false
    /// Apps running microphone input, when CoreAudio attributes it (macOS 14.2 or newer).
    public var microphoneApps: [String] = []
    public var camera = false
    public init(microphone: Bool = false, microphoneApps: [String] = [], camera: Bool = false) {
        self.microphone = microphone
        self.microphoneApps = microphoneApps
        self.camera = camera
    }

    public var active: Bool { microphone || camera }

    /// "Microphone: Zoom, Safari. Camera in use." Camera use has no public per-app attribution.
    public var summary: String {
        var parts: [String] = []
        if microphone {
            let apps = Array(NSOrderedSet(array: microphoneApps).array as! [String]).sorted()
            parts.append(apps.isEmpty ? "Microphone in use." : "Microphone: \(apps.joined(separator: ", ")).")
        }
        if camera { parts.append("Camera in use.") }
        return parts.joined(separator: " ")
    }
}
