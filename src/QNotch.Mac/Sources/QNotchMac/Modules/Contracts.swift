import AppKit
import QNotchMacCore

protocol Contribution { var id: String { get }; var order: Int { get } }

struct ViewContribution: Contribution {
    let id: String
    let title: String
    let order: Int
    /// SF Symbol for tab buttons and the Settings sidebar.
    var symbol = "square.grid.2x2"
    /// Settings sidebar icon background.
    var tint = NSColor.systemGray
    let makeView: () -> NSView
}

enum SegmentSlot { case leading, trailing }

/// Collapsed status content. With a camera housing, leading content sits in the left wing and
/// trailing content in the right wing; a floating pill shows them side by side. A segment shows
/// only while its view is not hidden; call `ModuleShell.segmentsChanged()` after toggling it.
struct SegmentContribution: Contribution {
    let id: String
    let order: Int
    let slot: SegmentSlot
    let makeView: () -> NSView
}

struct SearchHit {
    let title: String
    let detail: String
    var symbol = "arrow.forward.circle"
    let run: () -> Void
}

struct SearchSource: Contribution {
    let id: String
    let order: Int
    /// Trimmed, nonempty query; inspect in-memory state only. No I/O on keystrokes.
    let find: (String) -> [SearchHit]
}

final class Registry<T: Contribution> {
    private var values: [String: T] = [:]
    var items: [T] { values.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
    func register(_ value: T) { values[value.id] = value }
    func removeAll() { values.removeAll() }
}

/// Mac-local equivalents of the five product extension concepts. No WPF or shared runtime.
final class ModuleRegistries {
    let cards = Registry<ViewContribution>()
    let tabs = Registry<ViewContribution>()
    let segments = Registry<SegmentContribution>()
    let searchSources = Registry<SearchSource>()
    let settingsSections = Registry<ViewContribution>()
    func removeAll() {
        cards.removeAll(); tabs.removeAll(); segments.removeAll()
        searchSources.removeAll(); settingsSections.removeAll()
    }
}

protocol ModuleShell: AnyObject {
    func selectTab(_ id: String)
    func openSettings()
    /// A segment became visible, hidden, or changed width.
    func segmentsChanged()
}

struct ModuleContext {
    let settings: SettingsStore
    let registries: ModuleRegistries
    weak var shell: ModuleShell?
}

protocol NotchModule: AnyObject {
    func initialize(_ context: ModuleContext)
    func setVisibility(panel: Bool, activeTab: String)
    func systemDidWake()
    func stop()
}
