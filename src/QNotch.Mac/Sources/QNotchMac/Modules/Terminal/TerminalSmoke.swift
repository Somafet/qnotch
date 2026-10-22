import AppKit

/// Exercises only the demo sink: diagnostics must never execute shell commands.
enum TerminalSmoke {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = "terminal: " + description }
    }
    static func check(_ run: SnapshotRun) throws {
        let shell = run.shell
        guard Runtime.diagnostics, let module = shell.module(TerminalModule.self), module.session == nil else {
            throw Failure("Diagnostics started a real shell or did not register Terminal")
        }
        shell.selectTab("terminal")
        shell.toggleFromKeyboard()
        guard shell.state.acceptsKeyboard, let input = shell.panel.firstResponder as? TerminalCanvas else {
            throw Failure("Toggle hotkey did not focus the Terminal input")
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: shell.panel.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) { shell.panel.sendEvent(event) }
        }
        key(0, "a")
        key(8, "c", .control)
        key(123, "\u{F702}")
        key(53, "\u{1B}")
        guard module.demoInput == Data("a\u{3}\u{1B}[D\u{1B}".utf8), shell.activeTab == "terminal", shell.state.expanded else {
            throw Failure("Typing, Ctrl-C, arrows or Escape escaped the terminal input path")
        }
        run.write("terminal-screen", input)
        let text = module.screen.plainText
        shell.toggleFromKeyboard()
        shell.toggleFromKeyboard()
        guard shell.panel.firstResponder === input, shell.module(TerminalModule.self) === module, module.screen.plainText == text else {
            throw Failure("Reopening lost the terminal session or keyboard focus")
        }
        key(3, "f", .command)
        guard shell.activeTab == "search" else { throw Failure("Command-F did not route to Search") }
        shell.selectTab("home")
        guard shell.panel.firstResponder !== input else { throw Failure("Terminal kept the keyboard on Home") }
        shell.selectTab("terminal")
        guard shell.panel.firstResponder === input else { throw Failure("Selecting Terminal did not restore focus") }
        shell.close(restoreFocus: false)
        shell.updateGeneral { $0.setEnabled("terminal", false) }
        guard shell.module(TerminalModule.self) == nil, !shell.registries.tabs.items.contains(where: { $0.id == "terminal" }) else {
            throw Failure("Disabling left a running module or tab")
        }
        shell.selectTab("home")
        run.pass("terminal-input-lifecycle")
    }
}
