import Foundation

/// The first-run welcome tour (spec/onboarding.md): when it shows, which steps it has, and what its
/// feature switches save. The step ids are shared with Windows.
public enum Onboarding {
    public enum Step: String, CaseIterable, Equatable {
        case welcome, open, features, connect, finish
    }

    public enum AtLaunch: Equatable {
        /// A fresh install, or a tour that never ended: show it before any module is constructed.
        case show
        /// Settings from before the tour existed: record it as done without showing it.
        case markDone
        case nothing
    }

    /// `settingsExist`: general.json is present. `readable`: it decoded (an unreadable file is left
    /// untouched). `done`: its `onboardingDone`, nil when the key is missing.
    public static func atLaunch(settingsExist: Bool, readable: Bool, done: Bool?, diagnostics: Bool) -> AtLaunch {
        if diagnostics { return .nothing }
        guard settingsExist else { return .show }
        guard readable else { return .nothing }
        switch done {
        case nil: return .markDone
        case false?: return .show
        case true?: return .nothing
        }
    }

    /// The steps in order; Connect only when an enabled feature has a one-step setup.
    public static func steps(hasConnectRows: Bool) -> [Step] {
        Step.allCases.filter { $0 != .connect || hasConnectRows }
    }

    public struct Group: Equatable {
        public let title: String
        public let modules: [String]
        public init(title: String, modules: [String]) { self.title = title; self.modules = modules }
    }

    /// The Features step's groups, in order, with every module id either platform has.
    public static let groups: [Group] = [
        Group(title: "At a glance", modules: ["stats", "media", "weather", "capture", "timer", "volume"]),
        Group(title: "Get things done", modules: ["clipboard", "search", "note", "filetray", "colorpicker", "scheduled"]),
        Group(title: "For developers", modules: ["agents", "ai", "github", "notifications"])
    ]

    /// The groups with only the modules this platform has; a group left empty is dropped.
    public static func groups(available: [String]) -> [Group] {
        groups.map { Group(title: $0.title, modules: $0.modules.filter(available.contains)) }.filter { !$0.modules.isEmpty }
    }

    public static func allEnabled(_ group: Group, in settings: GeneralSettings) -> Bool {
        group.modules.allSatisfy(settings.isEnabled)
    }

    /// Turn all on / Turn all off for one group; other modules keep their choice.
    public static func setGroup(_ group: Group, enabled: Bool, in settings: inout GeneralSettings) {
        for module in group.modules { settings.setEnabled(module, enabled) }
    }
}
