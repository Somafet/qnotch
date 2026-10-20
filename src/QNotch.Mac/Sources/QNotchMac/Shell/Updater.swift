import AppKit
import QNotchMacCore
import Security
import Sparkle

/// Sparkle updates from the Mac appcast (`UpdateChannel.feedURL`). Only a Developer ID signed copy
/// constructs one: development builds, diagnostic runs and isolated data folders make no update
/// requests. Sparkle checks the feed's and each archive's EdDSA signature (Info.plist
/// `SUPublicEDKey`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`) and that the new
/// app is signed by the same team before replacing this one.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private let beta: () -> Bool
    var updater: SPUUpdater { controller.updater }

    static func makeIfAvailable(isolated: Bool, beta: @escaping () -> Bool) -> Updater? {
        guard !isolated, !Runtime.diagnostics, signingTeam != nil else { return nil }
        return Updater(beta: beta)
    }

    private init(beta: @escaping () -> Bool) {
        self.beta = beta
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// The Developer ID team that signed this copy; nil for ad hoc and unsigned development builds.
    static var signingTeam: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    var canCheck: Bool { updater.canCheckForUpdates }

    /// Sparkle's own setting. Setting it stores SUEnableAutomaticChecks in the app's defaults, which
    /// also records that the choice was made, so Sparkle does not ask on the second launch.
    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { UpdateChannel.feedURL.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { UpdateChannel.channels(beta: beta()) }

    // MARK: SPUStandardUserDriverDelegate

    /// QNotch is a menu-bar app with no Dock icon: a scheduled check that finds an update shows
    /// Sparkle's window without taking focus from the app in use.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
