import AppKit
import QNotchMacCore

extension NotificationsModule {
    /// The command for this build, e.g. /Applications/QNotch.app/Contents/MacOS/QNotch notify.
    static var commandPath: String { Bundle.main.executablePath ?? "QNotch" }

    func makeSettings() -> NSView {
        let width = SettingsController.contentWidth
        let toastTitles = NotificationSettings.toastChoices.map { $0 == 0 ? "Off" : "\($0) seconds" }
        let toast = ActionPopUp("Show a toast for", items: toastTitles, selected: NotificationSettings.toastChoices.firstIndex(of: settings.toastSeconds) ?? 2) { [weak self] index in
            self?.set { $0.toastSeconds = NotificationSettings.toastChoices[index] }
        }
        let sound = ActionSwitch("Play a sound", value: settings.sound) { [weak self] value in self?.set { $0.sound = value } }
        let errors = ActionSwitch("Open the panel on errors", value: settings.openOnError) { [weak self] value in self?.set { $0.openOnError = value } }
        let quiet = ActionSwitch("Quiet during calls", value: settings.quietDuringCalls) { [weak self] value in self?.set { $0.quietDuringCalls = value } }
        let keep = ActionPopUp("Keep history for", items: NotificationSettings.retentionChoices.map { $0 == 1 ? "1 day" : "\($0) days" },
                               selected: NotificationSettings.retentionChoices.firstIndex(of: settings.retentionDays) ?? 2) { [weak self] index in
            self?.set { $0.retentionDays = NotificationSettings.retentionChoices[index] }
        }
        let test = button("Send Test") { [weak self] in self?.sendTest() }
        var quietDetail = "While an app uses the microphone: no toasts (except notifications waiting for an answer) and no automatic panel. History and the unread count still update."
        if !quietStatus.isEmpty { quietDetail += " " + quietStatus }
        let behavior = settingsGroup([
            settingsRow("Show a toast for", detail: "Beside the notch. Notifications waiting for an answer stay until answered.", control: toast, width: width),
            settingsRow("Play a sound", detail: "Pick the sound in Settings, Sounds.", control: sound, width: width),
            settingsRow("Open the panel on errors", detail: "An error-level notification opens the panel without taking the keyboard.", control: errors, width: width),
            settingsRow("Quiet during calls", detail: quietDetail, control: quiet, width: width),
            settingsRow("Keep history for", detail: "At most 500 notifications.", control: keep, width: width),
            settingsRow("Try it", control: test, width: width)
        ], width: width)

        let command = "\(Self.commandPath) notify \"Build done\""
        let copyCommand = button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\"\(Self.commandPath)\" notify", forType: .string)
        }
        let commandLabel = label(command, size: 11, color: .secondaryLabelColor)
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.isSelectable = true
        commandLabel.preferredMaxLayoutWidth = width - 120
        let cli = settingsGroup([
            settingsRow("Command", detail: "Run with --help for every option. It talks to QNotch through a socket only you can open.", control: copyCommand, width: width),
            wrap(commandLabel, width: width),
            settingsRow("Socket", detail: "\(socketStatus). \(socketPath)", width: width)
        ], header: "Command line", width: width)

        let http = ActionSwitch("Accept HTTP requests", value: settings.httpEnabled) { [weak self] value in self?.set { $0.httpEnabled = value } }
        let port = NSTextField(string: "\(settings.httpPort)")
        port.alignment = .right
        port.widthAnchor.constraint(equalToConstant: 70).isActive = true
        port.setAccessibilityLabel("Port")
        let portAction = ClosureTarget { [weak self, weak port] in
            guard let self, let port else { return }
            guard let value = Int(port.stringValue), (1024...65535).contains(value) else { port.stringValue = "\(self.settings.httpPort)"; NSSound.beep(); return }
            self.set { $0.httpPort = value }
        }
        port.target = portAction
        port.action = #selector(ClosureTarget.run)
        objc_setAssociatedObject(port, "action", portAction, .OBJC_ASSOCIATION_RETAIN)
        let tokenPreview = line("••••••", size: 12, color: .secondaryLabelColor)
        let show = button("Show") { [weak self, weak tokenPreview] in
            guard let self else { return }
            tokenPreview?.stringValue = String(self.currentToken().prefix(6)) + "…"
        }
        let copyToken = button("Copy") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.currentToken(), forType: .string)
        }
        let renew = button("New Token") { [weak self] in
            self?.renewToken()
            tokenPreview.stringValue = "••••••"
        }
        let example = label("curl -H \"Authorization: Bearer $TOKEN\" -d '{\"title\":\"Hi\"}' http://127.0.0.1:\(settings.httpPort)/notify", size: 11, color: .secondaryLabelColor)
        example.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        example.isSelectable = true
        example.preferredMaxLayoutWidth = width - 30
        let local = settingsGroup([
            settingsRow("Accept HTTP requests", detail: "On 127.0.0.1 only. Requests from web pages (with an Origin header) are refused. \(httpStatus).", control: http, width: width),
            settingsRow("Port", detail: "1024–65535. Press Return to apply.", control: port, width: width),
            settingsRow("Token", detail: "Kept in your Keychain.", control: row([tokenPreview, show, copyToken, renew], spacing: 4), width: width),
            wrap(example, width: width)
        ], header: "Local HTTP", width: width)

        let apps = Array(Set(items.map(\.app) + settings.mutedApps)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let appRows: [NSView] = apps.isEmpty ? [settingsRow("No senders yet", detail: "Apps that post notifications appear here.", width: width)] : apps.map { app in
            let toggle = ActionSwitch(app, value: !settings.isMuted(app)) { [weak self] value in
                self?.set { settings in
                    settings.mutedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
                    if !value { settings.mutedApps.append(app) }
                }
            }
            return settingsRow(app, control: toggle, width: width)
        }
        let mute = settingsGroup(appRows, header: "Apps", footer: "A muted app still goes into the history, but never toasts, counts as unread or opens the panel.", width: width)
        return column([behavior, cli, local, mute], spacing: 22)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let target = ClosureTarget(action)
        let button = NSButton(title: title, target: target, action: #selector(ClosureTarget.run))
        button.bezelStyle = .rounded
        button.controlSize = .small
        objc_setAssociatedObject(button, "action", target, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private func wrap(_ view: NSView, width: CGFloat) -> NSView {
        let container = NSView()
        embed(view, in: container, inset: NSEdgeInsets(top: 4, left: 14, bottom: 10, right: 14), fill: true)
        return container
    }
}
