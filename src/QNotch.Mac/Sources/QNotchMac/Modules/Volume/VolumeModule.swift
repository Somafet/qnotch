import AppKit
import AudioToolbox
import CoreAudio
import QNotchMacCore

/// System output volume and mute on a Home card (Windows VolumeModule). Entirely event driven:
/// CoreAudio property listeners report default-device, volume and mute changes; no timer.
final class VolumeModule: NotchModule {
    private let output = DefaultOutput()
    private let cards = NSHashTable<VolumeCardView>.weakObjects()

    func initialize(_ context: ModuleContext) {
        context.registries.cards.register(ViewContribution(id: "volume", title: "Volume", order: 25, symbol: "speaker.wave.2") { [unowned self] in
            let card = VolumeCardView(module: self)
            self.cards.add(card)
            card.update(self.output)
            return card
        })
        output.changed = { [weak self] in self?.refresh() }
        output.start()
    }

    func setVisibility(panel: Bool, activeTab: String) {}
    func systemDidWake() { output.reattach() }
    func stop() { output.stop() }

    var level: VolumeLevel? { output.level }

    func set(_ level: VolumeLevel) { Analytics.record("volume", "set_volume");
        output.set(level)
        refresh()
    }

    func toggleMute() { Analytics.record("volume", "toggle_mute");
        guard let level = output.level else { return }
        // Unmuting at 0% would stay silent; bring it back to an audible level instead.
        output.set(level.muted || level.percent > 0 ? VolumeLevel(scalar: level.scalar, muted: !level.muted) : level.setting(percent: 25))
        refresh()
    }

    private func refresh() { cards.allObjects.forEach { $0.update(output) } }
}

/// The default output device's main volume and mute, with listeners re-attached when the
/// default device changes. Listener blocks run on the main queue.
final class DefaultOutput {
    private(set) var device = AudioObjectID(kAudioObjectUnknown)
    private(set) var level: VolumeLevel?
    private(set) var name = ""
    private(set) var canSetVolume = false
    var changed: (() -> Void)?
    private var started = false
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reattach() }
    private lazy var levelListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.read() }

    private static var defaultDevice = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var deviceName = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !started else { return }
        started = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, .main, deviceListener)
        reattach()
    }

    func stop() {
        guard started else { return }
        started = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, .main, deviceListener)
        detach()
    }

    deinit { stop() }

    func reattach() {
        guard started else { return }
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, 0, nil, &size, &id) == noErr {
            device = id
        }
        if device != kAudioObjectUnknown {
            for address in [Self.volume, Self.mute] {
                var address = address
                if AudioObjectHasProperty(device, &address) { AudioObjectAddPropertyListenerBlock(device, &address, .main, levelListener) }
            }
            var cfName: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            name = AudioObjectGetPropertyData(device, &Self.deviceName, 0, nil, &size, &cfName) == noErr
                ? (cfName?.takeRetainedValue() as String?) ?? "" : ""
        }
        read()
    }

    private func detach() {
        guard device != kAudioObjectUnknown else { return }
        for address in [Self.volume, Self.mute] {
            var address = address
            if AudioObjectHasProperty(device, &address) { AudioObjectRemovePropertyListenerBlock(device, &address, .main, levelListener) }
        }
        device = AudioObjectID(kAudioObjectUnknown)
        name = ""
    }

    private func read() {
        var next: VolumeLevel?
        var settable = DarwinBoolean(false)
        if device != kAudioObjectUnknown, AudioObjectHasProperty(device, &Self.volume) {
            var scalar: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &scalar) == noErr {
                var muted: UInt32 = 0
                size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectHasProperty(device, &Self.mute) { AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted) }
                next = VolumeLevel(scalar: scalar, muted: muted != 0)
                AudioObjectIsPropertySettable(device, &Self.volume, &settable)
            }
        }
        let changedValue = next != level || settable.boolValue != canSetVolume
        level = next
        canSetVolume = settable.boolValue
        if changedValue { changed?() }
    }

    func set(_ wanted: VolumeLevel) {
        guard device != kAudioObjectUnknown, canSetVolume, let current = level else { return }
        if abs(wanted.scalar - current.scalar) > 0.0001 {
            var scalar = Float32(wanted.scalar)
            AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        }
        if wanted.muted != current.muted, AudioObjectHasProperty(device, &Self.mute) {
            var muted: UInt32 = wanted.muted ? 1 : 0
            AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        }
        level = wanted
    }
}

// MARK: - Home card

private final class VolumeCardView: NSView {
    private weak var module: VolumeModule?
    private let mute: HoverButton
    private let value = line("--", size: 26, weight: .semibold, color: Palette.textPrimary)
    private let device = line("", size: 11, color: Palette.textTertiary)
    private let slider = LevelSlider(label: "Volume")
    private let empty = line("No playback device.", size: 12, color: Palette.textSecondary)
    private var scrolled: CGFloat = 0

    init(module: VolumeModule) {
        self.module = module
        mute = HoverButton(symbol: "speaker.wave.2.fill", style: .plain, symbolSize: 15, label: "Mute") { [weak module] in module?.toggleMute() }
        super.init(frame: .zero)
        size(mute, width: 40, height: 40)
        mute.layer?.cornerRadius = 20
        mute.layer?.cornerCurve = .circular
        value.font = .rounded(26, weight: .semibold, monospacedDigits: true)
        value.setAccessibilityIdentifier("volume-level")
        slider.changed = { [weak self] value in self?.slid(value) }
        let top = row([mute, column([value, device], spacing: 0)], spacing: 12)
        let stack = column([top, slider, empty], spacing: 14)
        embed(stack, in: self, inset: 0)
        slider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        toolTip = "Scroll to change the volume"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ output: DefaultOutput) {
        guard let level = output.level else {
            mute.isHidden = true; value.isHidden = true; device.isHidden = true; slider.isHidden = true
            empty.isHidden = false
            empty.stringValue = output.device == kAudioObjectUnknown ? "No playback device." : "\(output.name.isEmpty ? "This output" : output.name) has no volume control."
            return
        }
        mute.isHidden = false; value.isHidden = false; device.isHidden = output.name.isEmpty; slider.isHidden = false
        empty.isHidden = true
        if value.stringValue != level.text { value.stringValue = level.text }
        value.textColor = level.muted ? Palette.textSecondary : Palette.textPrimary
        device.stringValue = output.name
        mute.setSymbol(level.symbol, size: 15, label: level.muted ? "Unmute" : "Mute")
        mute.tint = level.isSilent ? Palette.textSecondary : Palette.textPrimary
        if abs(slider.value - Double(level.percent)) >= 0.5 { slider.value = Double(level.percent) }
        slider.isEnabled = output.canSetVolume
        mute.isEnabled = output.canSetVolume
        slider.dimmed = level.muted
    }

    private func slid(_ percent: Double) {
        guard let module, let level = module.level else { return }
        module.set(level.setting(percent: Int(percent)))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let module, let level = module.level else { return super.scrollWheel(with: event) }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        let notches = Int(scrolled.rounded(.towardZero))
        guard notches != 0 else { return }
        scrolled -= CGFloat(notches)
        module.set(level.stepped(by: notches))
    }
}
