import AppKit
import Carbon.HIToolbox
import QNotchMacCore

/// Rebindable global shortcuts (Windows `ctx.Shortcuts`). Carbon `RegisterEventHotKey` needs no
/// Accessibility or Input Monitoring permission and costs nothing until the key is pressed.
/// Changed gestures are saved in hotkeys.json; a failed registration means another app owns the key.
final class ShortcutRegistry {
    final class Shortcut {
        let id: String
        let title: String
        let hint: String
        let defaultCombo: KeyCombo?
        let order: Int
        let action: () -> Void
        let owner: String?
        fileprivate(set) var enabled: Bool
        /// The effective gesture, nil when the user turned it off.
        fileprivate(set) var combo: KeyCombo?
        /// Another app registered the same key.
        fileprivate(set) var taken = false
        /// Another QNotch shortcut with a lower order already uses the key.
        fileprivate(set) var usedBy: String?
        fileprivate var reference: EventHotKeyRef?
        fileprivate var number: UInt32 = 0

        fileprivate init(id: String, title: String, hint: String, defaultCombo: KeyCombo?, order: Int, enabled: Bool, owner: String?, action: @escaping () -> Void) {
            self.id = id; self.title = title; self.hint = hint; self.defaultCombo = defaultCombo
            self.order = order; self.enabled = enabled; self.owner = owner; self.action = action
        }
        var isRegistered: Bool { reference != nil }
    }

    private static let signature: OSType = 0x514E_4348 // 'QNCH'
    private let store: SettingsStore
    private var settings: ShortcutSettings
    private var shortcuts: [String: Shortcut] = [:]
    private var handler: EventHandlerRef?
    private var nextNumber: UInt32 = 1
    private var suspended = false
    var changed: (() -> Void)?
    /// The module whose `initialize` is running; its shortcuts are removed with it.
    var owner: String?

    init(store: SettingsStore) {
        self.store = store
        settings = store.load("hotkeys", default: ShortcutSettings())
    }

    deinit {
        shortcuts.values.forEach(unregister)
        if let handler { RemoveEventHandler(handler) }
    }

    var items: [Shortcut] { shortcuts.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
    func shortcut(_ id: String) -> Shortcut? { shortcuts[id] }

    /// Declare once per id in `initialize`. `gesture` uses the saved text form, e.g. "ctrl+opt+n".
    @discardableResult
    func add(_ id: String, title: String, hint: String, gesture: String, order: Int, enabled: Bool = true, action: @escaping () -> Void) -> Shortcut {
        if let old = shortcuts[id] { unregister(old) }
        let shortcut = Shortcut(id: id, title: title, hint: hint, defaultCombo: KeyCombo(gesture), order: order, enabled: enabled, owner: owner, action: action)
        nextNumber += 1
        shortcut.number = nextNumber
        shortcut.combo = saved(for: shortcut)
        shortcuts[id] = shortcut
        apply()
        return shortcut
    }

    /// Leave the key to other apps while the shortcut has nothing to do.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let shortcut = shortcuts[id], shortcut.enabled != enabled else { return }
        shortcut.enabled = enabled
        apply()
    }

    /// Removes shortcuts not owned by the shell (a module was turned off).
    func remove(where predicate: (Shortcut) -> Bool) {
        for shortcut in shortcuts.values where predicate(shortcut) {
            unregister(shortcut)
            shortcuts[shortcut.id] = nil
        }
        apply()
    }

    /// `nil` turns the shortcut off.
    func set(_ id: String, _ combo: KeyCombo?) { Analytics.setting("hotkey");
        guard let shortcut = shortcuts[id] else { return }
        settings.keys[id] = combo == shortcut.defaultCombo ? nil : (combo?.text ?? "")
        store.save("hotkeys", settings)
        shortcut.combo = combo
        apply()
    }

    func reset(_ id: String) {
        guard let shortcut = shortcuts[id] else { return }
        set(id, shortcut.defaultCombo)
    }

    /// Releases every key while the Settings recorder listens, so the gesture reaches it.
    func suspend(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        apply()
    }

    private func saved(for shortcut: Shortcut) -> KeyCombo? {
        guard let text = settings.keys[shortcut.id] else { return shortcut.defaultCombo }
        return KeyCombo(text)
    }

    /// Re-registers every key: the first shortcut (by order) with a gesture keeps it.
    private func apply() {
        shortcuts.values.forEach(unregister)
        var owners: [KeyCombo: String] = [:]
        for shortcut in items {
            shortcut.taken = false
            shortcut.usedBy = nil
            guard let combo = shortcut.combo else { continue }
            if let owner = owners[combo] { shortcut.usedBy = owner; continue }
            owners[combo] = shortcut.title
            guard shortcut.enabled, !suspended else { continue }
            installHandler()
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: shortcut.number),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr { shortcut.reference = reference } else { shortcut.taken = true }
        }
        changed?()
    }

    private func unregister(_ shortcut: Shortcut) {
        if let reference = shortcut.reference { UnregisterEventHotKey(reference) }
        shortcut.reference = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == ShortcutRegistry.signature else { return OSStatus(eventNotHandledErr) }
            let registry = Unmanaged<ShortcutRegistry>.fromOpaque(context).takeUnretainedValue()
            registry.fire(key.id)
            return noErr
        }, 1, &spec, context, &handler)
    }

    private func fire(_ number: UInt32) {
        guard let shortcut = shortcuts.values.first(where: { $0.number == number }), shortcut.enabled, !suspended else { return }
        Analytics.withSurface("hotkey") { Analytics.withSurface("hotkey") { shortcut.action() } }
    }
}

extension KeyCombo {
    /// The gesture of a key press (its key and ⌃⌥⇧⌘), whether or not it is allowed globally.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}

/// Settings control that records a shortcut: click, then press the keys. Esc cancels,
/// Delete turns the shortcut off. Global shortcuts need ⌃, ⌥ or ⌘.
final class ShortcutRecorder: NSButton {
    private let registry: ShortcutRegistry
    private let id: String
    private var recording = false { didSet { registry.suspend(recording); refresh() } }
    var isRecording: Bool { recording }
    var finished: (() -> Void)?

    init(registry: ShortcutRegistry, id: String) {
        self.registry = registry
        self.id = id
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(begin)
        widthAnchor.constraint(equalToConstant: 128).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    /// Starts listening (a click, or the welcome tour's Change).
    @objc func begin() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            finish()
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            registry.set(id, nil)
            finish()
        default:
            guard let combo = KeyCombo(event: event), combo.isAllowedGlobally else {
                NSSound.beep()
                return
            }
            registry.set(id, combo)
            finish()
        }
    }

    private func finish() {
        recording = false
        window?.makeFirstResponder(nil)
        finished?()
    }

    private func refresh() {
        let shortcut = registry.shortcut(id)
        title = recording ? "Type shortcut…" : shortcut?.combo?.display ?? "Off"
        setAccessibilityLabel("\(shortcut?.title ?? "Shortcut"): \(title)")
        toolTip = recording ? "Press the keys. Esc cancels, Delete turns it off." : "Click to change"
    }
}
