import AppKit
import QNotchMacCore

/// Pick a color anywhere on screen and copy its hex code (Windows ColorPickerModule).
/// `NSColorSampler` is the system loupe: no event hook, no Screen Recording permission, Esc cancels.
/// Nothing runs until a pick starts.
final class ColorPickerModule: NotchModule {
    private var context: ModuleContext!
    private var settings = ColorPickerSettings()
    private var sampler: NSColorSampler?
    private let cards = NSHashTable<ColorPickerCardView>.weakObjects()
    private(set) var lastCopied: String?

    var recent: [String] { settings.recent }
    var isPicking: Bool { sampler != nil }

    func initialize(_ context: ModuleContext) {
        self.context = context
        settings = context.settings.load("colorpicker", default: ColorPickerSettings())
        context.registries.cards.register(ViewContribution(id: "colorpicker", title: "Color picker", order: 27, symbol: "eyedropper") { [unowned self] in
            let card = ColorPickerCardView(module: self)
            self.cards.add(card)
            return card
        })
    }

    func setVisibility(panel: Bool, activeTab: String) {
        if panel, lastCopied != nil { lastCopied = nil; refresh() }
    }
    func systemDidWake() {}
    func stop() { sampler = nil }

    /// Closes the panel first, so the area under the notch can be picked too.
    func pick() {
        guard sampler == nil else { return }
        context.shell?.closePanel()
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampler = nil
                guard let color = color?.usingColorSpace(.sRGB) else { return }
                self.copy(HexColor.string(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent)))
            }
        }
    }

    func copy(_ hex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        lastCopied = hex
        settings.recent = HexColor.remember(hex, in: settings.recent)
        context.settings.save("colorpicker", settings)
        refresh()
    }

    /// Smoke snapshots only: recent swatches without touching the user's clipboard.
    func seedRecent(_ colors: [String]) {
        settings.recent = colors.reduce([]) { HexColor.remember($1, in: $0) }
        refresh()
    }

    private func refresh() { cards.allObjects.forEach { $0.update() } }
}

// MARK: - Home card

private final class ColorPickerCardView: NSView {
    private weak var module: ColorPickerModule?
    private let swatches = NSStackView()
    private let status = label("", size: 11, color: Palette.textTertiary)

    init(module: ColorPickerModule) {
        self.module = module
        super.init(frame: .zero)
        let pick = HoverButton("Pick a color", symbol: "eyedropper", style: .plain, symbolSize: 13) { [weak module] in module?.pick() }
        pick.toolTip = "Click to pick, Esc to cancel. The hex code is copied."
        pick.setAccessibilityIdentifier("colorpicker-pick")
        swatches.orientation = .horizontal
        swatches.spacing = 6
        status.preferredMaxLayoutWidth = 180
        let stack = column([pick, swatches, status], spacing: 12)
        embed(stack, in: self, inset: 0)
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update() {
        guard let module else { return }
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for hex in module.recent {
            swatches.addArrangedSubview(SwatchButton(hex: hex) { [weak module] in module?.copy(hex) })
        }
        swatches.isHidden = module.recent.isEmpty
        if let copied = module.lastCopied {
            status.stringValue = "Copied \(copied)"
            status.textColor = Palette.textSecondary
        } else {
            status.stringValue = module.recent.isEmpty ? "Picked colors show up here. Click one to copy it again." : "Click a swatch to copy it again."
            status.textColor = Palette.textTertiary
        }
    }
}

/// A 22-point color tile that copies its hex code.
private final class SwatchButton: NSButton {
    private let handler: () -> Void
    private var tracking: NSTrackingArea?

    init(hex: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        let rgb = HexColor.components(hex) ?? (0, 0, 0)
        layer?.backgroundColor = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Palette.strokeStrong.cgColor
        target = self
        self.action = #selector(invoke)
        size(self, width: 22, height: 22)
        toolTip = "Copy \(hex)"
        setAccessibilityLabel("Copy \(hex)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setLift(true) }
    override func mouseExited(with event: NSEvent) { setLift(false) }
    private func setLift(_ on: Bool) {
        guard let layer else { return }
        Motion.animate(0.14) { layer.borderColor = (on ? Palette.textPrimary : Palette.strokeStrong).cgColor }
    }
}
