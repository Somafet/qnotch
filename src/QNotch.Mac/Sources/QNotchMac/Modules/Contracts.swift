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
    /// Home cards only: default width. Two-column cards also provide a Small layout.
    var span = 1
    let makeView: () -> NSView

    var supportedCardSizes: [HomeCardSize] { HomeCardSize.supported(defaultSpan: span) }
}

/// Module-owned adaptation of a cached Home view; resizing never restarts a provider or session.
protocol HomeCardSizing: AnyObject {
    func setHomeCardSize(_ size: HomeCardSize)
}

/// Optional actions supplied by enabled modules to the menu-bar menu.
struct MenuActionContribution: Contribution {
    let id: String
    let order: Int
    let title: () -> String
    let isOn: () -> Bool
    let run: () -> Void
}

enum SegmentSlot { case leading, trailing }

/// Collapsed status content. With a camera housing, leading content sits in the left wing and
/// trailing content in the right wing; a floating pill shows them side by side. A segment shows
/// only while its view is not hidden; call `ModuleShell.segmentsChanged()` after toggling it.
/// Destinations are declared by the contribution, never inferred from module names or wings.
enum SegmentDestination {
    case tab(String)
    case card(String, emphasis: String?, allowsHiddenDetail: Bool)
}

/// Optional card-local emphasis. Nil clears it when this opening/navigation ends.
protocol SegmentDetailContent: AnyObject {
    @discardableResult func emphasize(_ detail: String?) -> Bool
}

struct SegmentContribution: Contribution {
    let id: String
    let order: Int
    let slot: SegmentSlot
    var destination: SegmentDestination? = nil
    var destinationLabel: String? = nil
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
    private var values: [String: (owner: String?, value: T)] = [:]
    /// The module whose `initialize` is running; its registrations are removed with it.
    var owner: String?
    var items: [T] { values.values.map(\.value).sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
    func register(_ value: T) { values[value.id] = (owner, value) }
    func removeAll() { values.removeAll() }
    func removeAll(owner: String) { values = values.filter { $0.value.owner != owner } }
    func ids(owner: String) -> [String] { values.filter { $0.value.owner == owner }.map(\.key) }
    func owner(of id: String) -> String? { values[id]?.owner }
}

/// Mac-local equivalents of the five product extension concepts. No WPF or shared runtime.
final class ModuleRegistries {
    let cards = Registry<ViewContribution>()
    let tabs = Registry<ViewContribution>()
    let segments = Registry<SegmentContribution>()
    let searchSources = Registry<SearchSource>()
    let settingsSections = Registry<ViewContribution>()
    let menuActions = Registry<MenuActionContribution>()
    /// Set by the shell around each module's `initialize`.
    var owner: String? {
        didSet {
            cards.owner = owner; tabs.owner = owner; segments.owner = owner
            searchSources.owner = owner; settingsSections.owner = owner; menuActions.owner = owner
        }
    }
    func removeAll(owner: String) {
        cards.removeAll(owner: owner); tabs.removeAll(owner: owner); segments.removeAll(owner: owner)
        searchSources.removeAll(owner: owner); settingsSections.removeAll(owner: owner); menuActions.removeAll(owner: owner)
    }
    func removeAll() {
        cards.removeAll(); tabs.removeAll(); segments.removeAll()
        searchSources.removeAll(); settingsSections.removeAll(); menuActions.removeAll()
    }
}

/// A shown peek; `end()` removes it early (e.g. the agent was answered).
final class PeekHandle {
    fileprivate(set) var ended = false
    private let finish: (PeekHandle) -> Void
    init(finish: @escaping (PeekHandle) -> Void) { self.finish = finish }
    func end() {
        guard !ended else { return }
        ended = true
        finish(self)
    }
}

protocol ModuleShell: AnyObject {
    /// Replaces the collapsed status with one line for a moment ("api: Needs you"): `symbol` and
    /// `leading` in the left wing, `trailing` in the right (side by side in a floating pill).
    /// A newer peek replaces the shown one; `seconds` nil keeps it until `end()`. Nothing shows
    /// while the panel is open. For something the user must notice now, never routine updates.
    @discardableResult
    func peek(symbol: String, tint: NSColor, leading: String, trailing: String, seconds: TimeInterval?) -> PeekHandle?
    func selectTab(_ id: String)
    /// Opens Search with the keyboard when its feature is enabled.
    func summonSearch()
    func openSettings()
    /// Opens Settings on a module's section (its `settingsSections` id).
    func openSettings(section: String)
    /// Opens the panel on `tab` without taking the keyboard. If the pointer is elsewhere it closes
    /// again after `linger` seconds. For something the user must see now, never routine updates.
    @discardableResult func tryOpenPanel(tab: String, linger: TimeInterval) -> Bool
    /// While the returned token is alive the panel never auto-closes (pointer leave, outside clicks,
    /// focus loss). Hold one around drags, share pickers, menus and file dialogs.
    func holdOpen() -> AnyObject
    /// Files dropped on the notch. `entered` runs once when a file drag reaches it; the shell opens
    /// the panel itself. Only one module receives drops.
    func acceptFileDrops(entered: @escaping () -> Void, dropped: @escaping ([URL]) -> Void)
    /// Collapses the panel (e.g. before picking from the screen under it) and gives the keyboard
    /// back to the app that had it.
    func closePanel()
    /// Collapses the panel because another app or window takes over now (a session's terminal,
    /// a launched app): no focus is handed back, and hover does not reopen it under the pointer.
    func dismissPanel()
    /// A contributed action changed title or state.
    func actionsChanged()
    /// A segment became visible, hidden, or changed width.
    func segmentsChanged()
}

struct ModuleContext {
    let settings: SettingsStore
    let registries: ModuleRegistries
    weak var shell: ModuleShell?
    /// Every sound a module plays: add it in `initialize`, then `play(id)`.
    let sounds: SoundRegistry
    /// Every lasting global hotkey a module owns.
    let shortcuts: ShortcutRegistry
    /// Shared microphone and camera watcher; observe it, and remove yourself in `stop`.
    let capture: CaptureWatch

    init(settings: SettingsStore, registries: ModuleRegistries, shell: ModuleShell?,
         sounds: SoundRegistry? = nil, shortcuts: ShortcutRegistry? = nil, capture: CaptureWatch? = nil) {
        self.settings = settings
        self.registries = registries
        self.shell = shell
        self.sounds = sounds ?? SoundRegistry(store: settings)
        self.shortcuts = shortcuts ?? ShortcutRegistry(store: settings)
        self.capture = capture ?? CaptureWatch()
    }
}

protocol NotchModule: AnyObject {
    func initialize(_ context: ModuleContext)
    /// `panel` is true only while an owned Home card or tab is on screen. Presentation changes
    /// update this without stopping the module; collapsed status has its own visibility rules.
    func setVisibility(panel: Bool, activeTab: String)
    func systemDidWake()
    func stop()
}

/// Tab content that restores its own input focus when explicitly opened with the keyboard.
protocol PanelKeyboardContent: AnyObject { func focusKeyboard() }
