import AppKit

final class SettingsController: NSObject {
    private unowned let shell: ShellController
    private(set) var window: NSWindow
    private var displayPicker: NSPopUpButton?
    private var displayIDs: [UInt32?] = []
    private var issue: NSTextField?

    init(shell: ShellController) {
        self.shell = shell
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "QNotch Settings"
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshDisplays() { if window.isVisible { rebuild() } }

    private func rebuild() {
        let root = WindowBackgroundView()
        window.contentView = root
        let title = label("General", size: 20)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let picker = NSPopUpButton()
        displayPicker = picker
        picker.addItem(withTitle: "Main display")
        displayIDs = [nil]
        for (index, screen) in NSScreen.screens.enumerated() {
            picker.addItem(withTitle: "\(screen.localizedName) (\(index + 1))")
            displayIDs.append(ShellController.displayID(screen))
        }
        if let selected = shell.general.displayID, !displayIDs.contains(where: { $0 == selected }) {
            picker.addItem(withTitle: "Disconnected display")
            displayIDs.append(selected)
        }
        picker.selectItem(at: displayIDs.firstIndex(where: { $0 == shell.general.displayID }) ?? 0)
        picker.target = self
        picker.action = #selector(displayChanged)
        picker.setAccessibilityLabel("Display for QNotch")
        let motion = ActionCheckbox("Reduce motion", value: shell.general.reduceMotion) { [weak self] value in
            self?.shell.updateGeneral { $0.reduceMotion = value }
            self?.refreshIssue()
        }
        let feature = ActionCheckbox("Enable Countdown", value: shell.general.timerEnabled) { [weak self] value in
            self?.shell.updateGeneral { $0.timerEnabled = value }
            self?.rebuild()
        }
        let help = label("Hover opens without taking the keyboard. Click the pill or choose Open Panel for keyboard control. Escape or a click outside closes it.", size: 12, color: .secondaryLabelColor)
        let availability = label("Media, clipboard, scheduled jobs, and mic/camera attribution are not available in this milestone. Automatic updates are not available; this build makes no network requests.", size: 11, color: .secondaryLabelColor)
        let problem = label("", size: 11, color: .systemOrange)
        issue = problem
        var rows: [NSView] = [title, row([label("Display:"), picker]), motion,
                              label("The macOS Reduce Motion setting is always honored.", size: 11, color: .secondaryLabelColor), feature]
        for section in shell.registries.settingsSections.items {
            rows.append(label(section.title, size: 13))
            rows.append(section.makeView())
        }
        rows += [help, availability, problem]
        let stack = column(rows, spacing: 12)
        embed(stack, in: root, inset: 24)
        for view in [help, availability, problem] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.setContentSize(NSSize(width: 440, height: shell.general.timerEnabled ? 498 : 424))
        refreshIssue()
    }

    @objc private func displayChanged() {
        guard let displayPicker else { return }
        let id = displayIDs[displayPicker.indexOfSelectedItem]
        shell.updateGeneral { $0.displayID = id }
        refreshIssue()
    }

    func refreshIssue() {
        issue?.stringValue = [shell.displayMessage, shell.store.problem ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
