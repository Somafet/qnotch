import AppKit
import QNotchMacCore
import Darwin

struct DevicesSettings: Codable {
    var id = UUID().uuidString.lowercased()
    var enabled = false
    var port = 45874
    var peers: [DevicePeer] = []
}

final class DevicesModule: NotchModule {
    private var context: ModuleContext!
    private var settings = DevicesSettings()
    private var node: DeviceNode?
    private var status = "Local sharing is off."
    private var invitation = ""
    private var received: [(String, URL)] = []
    private var operation: Task<Void, Never>?
    private let views = NSHashTable<DevicesSettingsView>.weakObjects()
    private var stopped = false
    func initialize(_ context: ModuleContext) {
        self.context = context
        if !Runtime.diagnostics { settings = context.settings.load("devices", default: DevicesSettings()) }
        context.registries.settingsSections.register(ViewContribution(id: "devices", title: "Devices", order: 35, symbol: "laptopcomputer.and.iphone", tint: .systemBlue) { [weak self] in
            guard let self else { return NSView() }
            let view = DevicesSettingsView(module: self); self.views.add(view); return view
        })
        if !Runtime.diagnostics, settings.enabled { Task { @MainActor [weak self] in await self?.start() } }
    }
    func setVisibility(panel: Bool, activeTab: String) {}
    func systemDidWake() {}
    func stop() { stopped = true; operation?.cancel(); node?.stop(); node = nil }
    private func save() { if !Runtime.diagnostics { context.settings.save("devices", settings) } }
    private func update(_ text: String) { status = text; refresh() }
    private func refresh() { for view in views.allObjects { view.reload() } }
    private func credentials<T>(_ action: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in DispatchQueue.global(qos: .utility).async { continuation.resume(returning: action()) } }
    }
    @MainActor private func start() async {
        guard !Runtime.diagnostics, !stopped, node == nil else { return }
        let inbox = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QNotch/Devices", isDirectory: true)
        let fresh = DeviceNode(id: settings.id, name: String((Host.current().localizedName ?? "Mac").prefix(80)), inbox: inbox)
        node = fresh
        for peer in settings.peers {
            let value = await credentials { Keychain.read("QNotch/Devices/" + peer.id) }
            guard node === fresh, !stopped else { fresh.stop(); return }
            if let value, let key = Data(base64Encoded: value) { fresh.restore(peer, key: key) }
        }
        fresh.approve = { peer in
            let alert = NSAlert(); alert.messageText = "Add \(peer.name)?"
            alert.informativeText = "\(peer.host) can send text and files to your QNotch inbox. Only approve a device you are pairing now."
            alert.addButton(withTitle: "Add Device"); alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        fresh.persist = { [weak self, weak fresh] peer, key in
            guard let self, let fresh, self.node === fresh, !self.stopped else { return false }
            let saved = await self.credentials { Keychain.write(key.base64EncodedString(), service: "QNotch/Devices/" + peer.id) }
            guard saved, self.node === fresh, !self.stopped else { return false }
            self.settings.peers.removeAll { $0.id == peer.id }; self.settings.peers.append(peer)
            return self.context.settings.save("devices", self.settings)
        }
        fresh.changed = { [weak self] in self?.invitation = ""; self?.refresh() }
        fresh.received = { [weak self] name, path, _ in
            guard let self else { return }
            self.received.insert((name, path), at: 0); self.received = Array(self.received.prefix(20))
            self.update("Received from \(name). Saved to Downloads/QNotch/Devices.")
        }
        do {
            try await fresh.start(port: settings.port)
            guard node === fresh, !stopped else { fresh.stop(); return }
            settings.enabled = true; save(); update("Ready. Add a device or send to a paired device.")
        } catch {
            guard node === fresh else { return }
            fresh.stop(); node = nil; settings.enabled = false; save()
            update("Could not start sharing. Check the port and local-network permission, then try again.")
        }
    }
    @MainActor fileprivate func enable(_ on: Bool) {
        guard !Runtime.diagnostics else { return }
        if on { Task { await start() } }
        else { operation?.cancel(); node?.stop(); node = nil; invitation = ""; settings.enabled = false; save(); update("Local sharing is off.") }
    }
    @MainActor fileprivate func run(success: String, _ work: @escaping (DeviceNode) async throws -> Void) {
        guard let node, operation == nil, !Runtime.diagnostics else { return }
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            self.update("Connecting...")
            do { try await work(node); self.update(success) }
            catch { self.update(Task.isCancelled ? "Transfer cancelled." : "Could not connect or transfer. Check both devices, the invitation, local-network permission and firewall.") }
            self.operation = nil; self.refresh()
        }
        refresh()
    }
    fileprivate static func addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var cursor = first, values: [String] = []
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if DeviceWire.localAddress(value), !value.hasPrefix("127."), !values.contains(value) { values.append(value) }
            }
        }
        return values.isEmpty ? ["127.0.0.1"] : values
    }

    final class DevicesSettingsView: NSView {
        private weak var module: DevicesModule?
        private let status = label("")
        private let invite = NSTextField()
        private let code = NSTextField()
        private let text = NSTextField()
        private let peers = NSPopUpButton()
        private let addresses = NSPopUpButton()
        private let port = NSTextField()
        private let received = column([])
        private var buttons: [NSButton] = []
        init(module: DevicesModule) {
            self.module = module
            super.init(frame: .zero)
            let width = SettingsController.contentWidth
            let enabled = ActionSwitch("Local sharing", value: module.settings.enabled) { [weak module] on in Task { @MainActor in module?.enable(on) } }
            addresses.addItems(withTitles: Runtime.diagnostics ? ["192.168.1.10"] : DevicesModule.addresses())
            addresses.setAccessibilityLabel("This device's address")
            port.stringValue = String(module.settings.port); port.setAccessibilityLabel("Listening port"); size(port, width: 72)
            let applyPort = actionButton("Apply") { [weak self] in
                guard let self, let module = self.module, module.node == nil, let value = Int(self.port.stringValue), (1...65535).contains(value) else { return }
                module.settings.port = value; module.save()
            }
            invite.isEditable = false; invite.isSelectable = true; invite.setAccessibilityLabel("Invitation to this device")
            code.placeholderString = "Paste an invitation from another device"; code.setAccessibilityLabel("Invitation from another device")
            text.placeholderString = "Text to send"; text.setAccessibilityLabel("Text to send")
            peers.setAccessibilityLabel("Paired devices")
            let create = actionButton("Create Invitation") { [weak self] in
                guard let self, let module = self.module else { return }
                do { module.invitation = try module.node?.invite(host: self.addresses.titleOfSelectedItem ?? "").code ?? ""
                    module.update("Invitation lasts five minutes. Send it privately, then approve the device here.")
                } catch { module.update("Enable sharing and choose a reachable local IPv4 address.") }
            }
            let add = actionButton("Add Device") { [weak self] in
                guard let self, let module = self.module else { return }
                let value = self.code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); self.code.stringValue = ""
                Task { @MainActor in module.run(success: "Device paired.") { try await $0.pair(value) } }
            }
            let check = actionButton("Check Connection") { [weak self] in
                guard let self, let module = self.module, let peer = self.selected else { return }
                Task { @MainActor in module.run(success: "Device is reachable.") { try await $0.send(peer.id) } }
            }
            let remove = actionButton("Remove Device") { [weak self] in
                guard let self, let module = self.module, let peer = self.selected, !Runtime.diagnostics else { return }
                module.node?.remove(peer.id); module.settings.peers.removeAll { $0.id == peer.id }; module.save(); module.refresh()
                Task { await module.credentials { Keychain.delete("QNotch/Devices/" + peer.id) } }
            }
            let permission = actionButton("Toggle Receiving") { [weak self] in
                guard let self, let module = self.module, let peer = self.selected else { return }
                module.node?.setReceive(peer.id, !peer.receive)
                if let index = module.settings.peers.firstIndex(where: { $0.id == peer.id }) { module.settings.peers[index].receive = !peer.receive }
                module.save(); module.refresh()
            }
            let sendText = actionButton("Send Text") { [weak self] in
                guard let self, let module = self.module, let peer = self.selected else { return }
                let value = self.text.stringValue
                Task { @MainActor in module.run(success: "Text sent.") { try await $0.send(peer.id, text: value) } }
            }
            let sendFile = actionButton("Send File") { [weak self] in
                guard let self, let module = self.module, let peer = self.selected else { return }
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                Task { @MainActor in module.run(success: "File sent.") { node in try await node.send(peer.id, file: url) { [weak module] percent in module?.update("Sending \(percent)%") } } }
            }
            let cancel = actionButton("Cancel") { [weak module] in module?.operation?.cancel() }
            buttons = [create, add, check, remove, permission, sendText, sendFile]
            let list = column([
                settingsGroup([
                    settingsRow("Local sharing", detail: "Encrypted text and files between paired Macs and Windows PCs. Both devices must enable sharing.", control: enabled, width: width),
                    settingsRow("Listening port", detail: "Change while sharing is off. Allow private-network traffic in your firewall.", control: row([port, applyPort]), width: width),
                    settingsRow("This device's address", detail: "Choose the adapter reachable from the other computer.", control: addresses, width: width),
                    settingsRow("Add another device", detail: "Create an invitation and paste it into Settings, Devices on the other computer.", control: create, width: width)
                ], width: width),
                invite, code, add, status,
                settingsGroup([settingsRow("Paired devices", control: peers, width: width)], width: width),
                row([check, remove, permission]), text, row([sendText, sendFile, cancel]),
                label("Received items are saved to Downloads/QNotch/Devices. Nothing opens or copies to the clipboard automatically.", size: 11, color: .secondaryLabelColor), received
            ])
            for field in [invite, code, text] { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
            status.preferredMaxLayoutWidth = width
            embed(list, in: self, inset: 0, fill: true); reload()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private var selected: DevicePeer? {
            guard let module else { return nil }
            let list = module.node?.devices ?? module.settings.peers
            return list.indices.contains(peers.indexOfSelectedItem) ? list[peers.indexOfSelectedItem] : nil
        }
        func reload() {
            guard let module else { return }
            let selectedID = selected?.id
            status.stringValue = module.status; invite.stringValue = module.invitation
            let list = module.node?.devices ?? module.settings.peers
            peers.removeAllItems(); peers.addItems(withTitles: list.map { $0.name + ($0.receive ? " (receiving on)" : " (receiving off)") })
            if let index = list.firstIndex(where: { $0.id == selectedID }) { peers.selectItem(at: index) }
            let ready = (module.node?.port ?? 0) > 0 && module.operation == nil && !Runtime.diagnostics
            for (index, button) in buttons.enumerated() { button.isEnabled = ready && (index < 2 || selected != nil) }
            port.isEnabled = module.node == nil
            received.arrangedSubviews.forEach { received.removeArrangedSubview($0); $0.removeFromSuperview() }
            for (name, path) in module.received {
                let show = actionButton("Show in Folder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                received.addArrangedSubview(row([label(name + ": " + path.lastPathComponent, size: 11), show]))
            }
        }
    }
}
