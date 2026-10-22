import AppKit
import QNotchMacCore

/// The debug channel's commands (spec/diagnostics.md, Debug channel), run on the main thread. A
/// command acts, then answers once the UI has settled (`DebugSettle`), so a following `outline`
/// or `snapshot` sees the result. Controls are found by identifier in QNotch's visible windows and
/// driven the way input would: `performClick`, the switch's own action, the field editor's
/// `insertText`, key events through `NSApp.sendEvent`.
final class DebugCommands {
    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What a command does after acting: wait for the UI to settle, compute the result, and run
    /// `after` once the reply is written.
    struct Step {
        var settle = true
        var result: () throws -> [String: Any] = { [:] }
        var after: (() -> Void)?
    }

    private let shell: ShellController
    let dataDirectory: URL

    init(shell: ShellController, dataDirectory: URL) {
        self.shell = shell
        self.dataDirectory = dataDirectory
    }

    func handle(_ request: DebugProtocol.Request, reply: @escaping (Data, (() -> Void)?) -> Void) {
        func message(_ error: Error) -> String { (error as? Failure)?.message ?? "\(error)" }
        do {
            let step = try perform(request.command, Arguments(values: request.args))
            let finish = {
                do { reply(DebugProtocol.success(id: request.id, result: try step.result()), step.after) } catch {
                    reply(DebugProtocol.failure(id: request.id, error: message(error)), nil)
                }
            }
            if step.settle { DebugSettle.wait(shell: shell, then: finish) } else { finish() }
        } catch {
            reply(DebugProtocol.failure(id: request.id, error: message(error)), nil)
        }
    }

    // MARK: Commands

    func perform(_ command: String, _ args: Arguments) throws -> Step {
        switch command {
        case "ping":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let result: [String: Any] = ["platform": "macOS", "app_version": version, "pid": Int(ProcessInfo.processInfo.processIdentifier),
                                         "data_dir": dataDirectory.path]
            return Step(settle: false, result: { result })
        case "state":
            return Step(result: { [unowned self] in self.state() })
        case "open":
            let tab = try args.string("tab")
            try requirePanel()
            if let tab { try checkTab(tab) }
            if let tab, !shell.state.expanded { shell.selectTab(tab) }
            shell.open(keyboard: true)
            if let tab { shell.selectTab(tab) }
            return Step(result: { [unowned self] in
                guard self.shell.state.expanded else { throw Failure("the panel did not open") }
                // Opening over a notification peek switches to Notifications after the open; the asked-for tab wins.
                if let tab, self.shell.activeTab != tab { self.shell.selectTab(tab) }
                return [:]
            })
        case "close":
            shell.close()
            return Step()
        case "select-tab":
            let id = try args.required("id", for: command)
            try checkTab(id)
            if !shell.state.expanded {
                try requirePanel()
                shell.selectTab(id)
                shell.open(keyboard: true)
            } else { shell.selectTab(id) }
            return Step(result: { [unowned self] in
                if self.shell.state.expanded, self.shell.activeTab != id { self.shell.selectTab(id) }
                guard self.shell.state.expanded, self.shell.activeTab == id else { throw Failure("the panel did not show the \(id) tab") }
                return [:]
            })
        case "settings":
            if try args.bool("close") {
                shell.settings?.window.close()
                return Step()
            }
            if let section = try args.string("section") {
                let pages = SettingsController.appPages.map(\.id) + shell.registries.settingsSections.items.map { "module." + $0.id } + ["about"]
                guard let page = [section, "module." + section].first(where: pages.contains) else {
                    throw Failure("no settings section \(section); sections: " + pages.map { $0.replacingOccurrences(of: "module.", with: "") }.joined(separator: ", "))
                }
                shell.openSettings(page: page)
            } else { shell.openSettings() }
            return Step()
        case "onboarding":
            if try args.bool("close") { shell.onboarding?.skipTour() } else { shell.showOnboarding() }
            return Step()
        case "outline":
            let window = try args.string("window")
            _ = try root(window)
            return Step(result: { [unowned self] in ["text": Outline.text(for: try self.root(window))] })
        case "snapshot":
            let path = try args.required("path", for: command)
            guard path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else { throw Failure("path must be absolute and end in .png") }
            let window = try args.string("window")
            _ = try root(window)
            return Step(result: { [unowned self] in
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ShellController.snapshot(view: try self.picture(window), to: url)
                return ["path": url.path]
            })
        case "press":
            try press(try args.required("id", for: command))
            return Step()
        case "type":
            try type(try args.required("text", for: command), into: try args.string("id"))
            return Step()
        case "key":
            let name = try args.required("name", for: command)
            guard let stroke = DebugKey.stroke(name) else { throw Failure("unknown key \(name); use Escape, Return, Tab, Space, Up, Down, Left, Right, Backspace, Delete or one character") }
            guard let modifiers = DebugKey.modifiers(args.values["modifiers"]) else { throw Failure("modifiers are any of ctrl, alt, shift, cmd") }
            guard let window = keyWindow else { throw Failure("QNotch has no key window; open the panel, Settings or the tour first") }
            try send(stroke, modifiers: modifiers, to: window)
            return Step()
        case "hotkey":
            let action = try args.required("action", for: command)
            let ids = ["toggle": "toggle", "search": "search", "game-mode": "gamemode"]
            guard let id = ids[action] else { throw Failure("action must be toggle, search or game-mode") }
            guard let shortcut = shell.shortcuts.shortcut(id) else { throw Failure("no \(action) hotkey (is its feature turned on?)") }
            shortcut.action()
            return Step()
        case "game-mode":
            let raw = try args.required("mode", for: command)
            guard let mode = GameOverride(rawValue: raw) else { throw Failure("mode must be auto, on or off") }
            shell.gameMode.override = mode
            return Step()
        case "quit":
            return Step(settle: false, after: { NSApp.terminate(nil) })
        default:
            throw Failure("unknown command \(command)")
        }
    }

    private func state() -> [String: Any] {
        let primary = NSScreen.screens.first?.frame ?? .zero
        func frame(_ rect: CGRect) -> [String: Any] { DebugProtocol.frame(DebugProtocol.topLeft(rect, primary: primary)) }
        let expanded = shell.state.expanded, shown = shell.panel.isVisible
        let layout = shell.layout
        // One window draws the pill and the panel; the one not shown reports its settled frame.
        var windows: [[String: Any]] = [
            ["id": "pill", "visible": shown && !expanded, "frame": frame(expanded ? layout?.surface(expanded: false, wing: shell.wing) ?? .zero : shell.panel.frame)],
            ["id": "panel", "visible": shown && expanded, "frame": frame(expanded ? shell.panel.frame : layout?.surface(expanded: true) ?? .zero)]
        ]
        if let window = shell.settings?.window { windows.append(["id": "settings", "visible": window.isVisible, "frame": frame(window.frame)]) }
        if let window = shell.onboarding?.window { windows.append(["id": "onboarding", "visible": window.isVisible, "frame": frame(window.frame)]) }
        return [
            "panel": expanded ? "open" : "collapsed",
            "tab": shell.activeTab,
            "keyboard": shell.state.acceptsKeyboard,
            "edit_mode": shell.editing,
            "pinned": shell.general.pinned,
            "game_mode": shell.gameMode.override.rawValue,
            "modules": ModuleList.all.map { ["id": $0.id, "enabled": shell.general.isEnabled($0.id), "running": shell.module($0.id) != nil] },
            "windows": windows
        ]
    }

    private func requirePanel() throws {
        if shell.modulesDeferred { throw Failure("the first-run welcome tour is open; close it first (onboarding --close true)") }
        if shell.gameActive { throw Failure("game mode is on, so the panel cannot open") }
        if shell.layout == nil { throw Failure("no display is available") }
    }

    private func checkTab(_ id: String) throws {
        let ids = ["home"] + shell.registries.tabs.items.map(\.id)
        guard ids.contains(id) else { throw Failure("no tab \(id); tabs: " + ids.joined(separator: ", ")) }
    }

    /// The view an outline or snapshot covers; an error when that window is not shown. The pill and
    /// the panel are one window: `panel` needs it open, `pill` reads whatever the notch shows.
    private func root(_ window: String?) throws -> NSView {
        let window = window ?? "panel"
        switch window {
        case "panel", "pill":
            if window == "panel", !shell.state.expanded { throw Failure("the panel is not open") }
            guard let view = shell.panel.contentView else { throw Failure("the notch has no view") }
            return view
        case "settings":
            guard let window = shell.settings?.window, window.isVisible, let view = window.contentView else { throw Failure("Settings is not open") }
            return view
        case "onboarding":
            guard let window = shell.onboarding?.window, window.isVisible, let view = window.contentView else { throw Failure("the welcome tour is not open") }
            return view
        default:
            throw Failure("window must be panel, pill, settings or onboarding")
        }
    }

    /// What a snapshot renders. Settings renders its current page, as the smoke test's
    /// `settings-<id>.png` do: the window's sidebar and scroll materials are composited by the
    /// system and come out blank from view caching.
    private func picture(_ window: String?) throws -> NSView {
        let view = try root(window)
        guard window == "settings" else { return view }
        var pages: [NSView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               !Self.contains(document, where: { Outline.id(of: $0)?.hasPrefix("settings-nav-") == true }) { pages.append(document) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return pages.first ?? view
    }

    private static func contains(_ view: NSView, where match: (NSView) -> Bool) -> Bool {
        match(view) || view.subviews.contains { contains($0, where: match) }
    }

    // MARK: Controls

    /// QNotch's visible windows that hold controls, the key window first.
    private var windows: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return ([NSApp.keyWindow, shell.onboarding?.window, shell.settings?.window, shell.panel] as [NSWindow?]).compactMap { $0 }
            .filter { $0.isVisible && seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The key window; while QNotch is not the active app (macOS may refuse to activate it), the
    /// panel when it has the keyboard, else the tour, else Settings, when shown.
    private var keyWindow: NSWindow? {
        NSApp.keyWindow ?? (shell.state.acceptsKeyboard ? shell.panel : nil) ??
            ([shell.onboarding?.window, shell.settings?.window] as [NSWindow?]).compactMap { $0 }.first { $0.isVisible }
    }

    /// The first shown view with this identifier; hidden, transparent, zero-size and scrolled-out
    /// views do not count.
    private func find(_ id: String) throws -> NSView {
        var hidden = false
        for window in windows {
            guard let root = window.contentView else { continue }
            for view in Self.views(id, in: root) {
                if Self.isShown(view) { return view }
                hidden = true
            }
        }
        throw Failure(hidden ? "no visible control with id \(id) (it is hidden)" : "no visible control with id \(id)")
    }

    static func views(_ id: String, in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if Outline.id(of: view) == id { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    static func isShown(_ view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0, !view.visibleRect.isEmpty else { return false }
        var current: NSView? = view
        while let next = current {
            if next.alphaValue <= 0.01 { return false }
            current = next.superview
        }
        return true
    }

    private func press(_ id: String) throws {
        // The notch itself: a click opens the panel with the keyboard.
        if id == "pill" {
            try requirePanel()
            _ = shell.panel.clicked?()
            return
        }
        let view = try find(id)
        if let control = view as? NSControl, !control.isEnabled { throw Failure("the control with id \(id) is disabled") }
        switch view {
        case is NSPopUpButton:
            throw Failure("press cannot choose a pop-up item (id \(id))")
        case let toggle as NSSwitch:
            toggle.state = toggle.state == .on ? .off : .on
            toggle.sendAction(toggle.action, to: toggle.target)
        case let button as NSButton:
            button.performClick(nil)
        case let row as NSTableRowView:
            var ancestor = row.superview
            while let next = ancestor, !(next is NSTableView) { ancestor = next.superview }
            guard let table = ancestor as? NSTableView, case let index = table.row(for: row), index >= 0 else { throw Failure("the row with id \(id) is not in a table") }
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.sendAction(table.action, to: table.target)
        case is NSControl:
            throw Failure("the control with id \(id) cannot be pressed; use type or key")
        default:
            guard view.accessibilityPerformPress() else { throw Failure("the element with id \(id) cannot be pressed") }
        }
    }

    /// Focuses the field (keeping the caret when it is already being edited) and inserts the text
    /// through the field editor, so delegates see it as typing. Without a focused text field, the
    /// text goes to the key window as key presses (the notch's type-to-search).
    private func type(_ text: String, into id: String?) throws {
        var target = keyWindow
        if let id {
            let view = try find(id)
            guard let window = view.window, (view as? NSTextField)?.isEditable == true || (view as? NSTextView)?.isEditable == true else {
                throw Failure("the control with id \(id) is not an editable text field")
            }
            if let field = view as? NSControl, !field.isEnabled { throw Failure("the control with id \(id) is disabled") }
            if window === shell.panel { if !shell.state.acceptsKeyboard { shell.open(keyboard: true) } } else { window.makeKeyAndOrderFront(nil) }
            let editing = window.firstResponder === view || (view is NSTextField && (window.firstResponder as? NSTextView)?.delegate === view)
            if !editing {
                guard window.makeFirstResponder(view) else { throw Failure("the control with id \(id) did not take the keyboard") }
                if let editor = window.firstResponder as? NSTextView { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
            }
            target = window
        }
        guard let window = target else { throw Failure("nothing in QNotch has the keyboard; pass id or open the panel first") }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            editor.insertText(text, replacementRange: editor.selectedRange())
            return
        }
        for character in text {
            guard let stroke = DebugKey.stroke(String(character)) else { continue }
            try send(stroke, modifiers: [], to: window)
        }
    }

    /// A key press and release as the keyboard would deliver them: through the application when
    /// the window is key (key equivalents first), else straight to the window.
    private func send(_ stroke: DebugKey.Stroke, modifiers: Set<String>, to window: NSWindow) throws {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("ctrl") { flags.insert(.control) }
        if modifiers.contains("alt") { flags.insert(.option) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("cmd") { flags.insert(.command) }
        let plain = stroke.characters.lowercased()
        let characters = modifiers.contains("shift") ? stroke.characters.uppercased() : stroke.characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: plain, isARepeat: false, keyCode: stroke.keyCode) else {
                throw Failure("could not make the key event")
            }
            if window === NSApp.keyWindow { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
    }
}

/// The `args` object, with string, boolean and number readers that say what was wrong. Values may
/// arrive as strings (Windows' command line sends every value as one): `"true"`, `"false"`, `"1"`
/// and `"0"` read as booleans and numeric strings as numbers.
struct Arguments {
    let values: [String: Any]

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        throw DebugCommands.Failure("\(key) must be a string")
    }

    func required(_ key: String, for command: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else { throw DebugCommands.Failure("\(command) needs \(key)") }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        switch values[key] {
        case nil, is NSNull: return false
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID() || [0, 1].contains(number.doubleValue): return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: throw DebugCommands.Failure("\(key) must be true or false")
            }
        default: throw DebugCommands.Failure("\(key) must be true or false")
        }
    }

    func number(_ key: String) throws -> Double? {
        switch values[key] {
        case nil, is NSNull: return nil
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.doubleValue
        case let text as String:
            if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
            throw DebugCommands.Failure("\(key) must be a number")
        default: throw DebugCommands.Failure("\(key) must be a number")
        }
    }
}

/// When a debug command's UI has settled. Checked every 1/60 s after the command: settled once two
/// checks in a row find layout done, the notch not morphing, no visible QNotch window mid-fade and
/// no finite Core Animation animation running or waiting to start in any visible window's layer
/// tree (hidden views' layers excluded). Animations that repeat forever (the edit-mode jiggle, the
/// tour's glow) do not count. After 3 seconds it answers anyway. Work scheduled for later with a
/// timer (a hover or linger delay, a tour step's delayed moment) is not waited for.
enum DebugSettle {
    static func wait(shell: ShellController, timeout: TimeInterval = 3, then done: @escaping () -> Void) {
        let started = CACurrentMediaTime()
        var quiet = 0
        func check() {
            let windows = NSApp.windows.filter(\.isVisible)
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            quiet = busy(shell: shell, windows: windows, since: started) ? 0 : quiet + 1
            if quiet >= 2 || CACurrentMediaTime() - started > timeout {
                CATransaction.flush()
                done()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: check)
            }
        }
        DispatchQueue.main.async(execute: check)
    }

    static func busy(shell: ShellController, windows: [NSWindow], since started: CFTimeInterval) -> Bool {
        if shell.surface.isMorphing { return true }
        return windows.contains { window in
            (window.alphaValue > 0.01 && window.alphaValue < 0.99) || (window.contentView?.layer).map { animating($0, since: started) } == true
        }
    }

    /// A finite animation still running in this layer tree. One not yet committed (begin time 0)
    /// counts from when the wait started.
    static func animating(_ layer: CALayer, since started: CFTimeInterval) -> Bool {
        if let view = layer.delegate as? NSView, view.isHidden { return false }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key), let length = length(of: animation) else { continue }
            let begin = animation.beginTime > 0 ? animation.beginTime : layer.convertTime(started, from: nil)
            if now < begin + length { return true }
        }
        return layer.sublayers?.contains { animating($0, since: started) } ?? false
    }

    /// How long a finite animation runs, repeats included; nil for one that repeats forever.
    static func length(of animation: CAAnimation) -> CFTimeInterval? {
        guard animation.repeatCount != .infinity, animation.repeatDuration != .infinity else { return nil }
        let once = animation.duration * (animation.autoreverses ? 2 : 1)
        return animation.repeatDuration > 0 ? animation.repeatDuration : once * Double(max(1, animation.repeatCount))
    }
}
