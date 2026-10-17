import AppKit
import QNotchMacCore

/// A glyph beside the notch while an app uses the microphone or camera (Windows CaptureModule).
/// It only listens: see `CaptureWatch`. macOS also shows its own orange and green dots.
final class CaptureModule: NotchModule {
    private var context: ModuleContext!
    private let segments = NSHashTable<CaptureSegmentView>.weakObjects()
    private(set) var state = CaptureState()

    func initialize(_ context: ModuleContext) {
        self.context = context
        context.registries.segments.register(SegmentContribution(id: "capture", order: 3, slot: .trailing) { [weak self] in
            let view = CaptureSegmentView()
            self?.segments.add(view)
            view.update(self?.state ?? CaptureState())
            return view
        })
        context.capture.observe(self) { [weak self] state in self?.apply(state) }
    }

    func setVisibility(panel: Bool, activeTab: String) {}
    func systemDidWake() {}
    func stop() { context?.capture.remove(self) }

    /// Also used by the smoke test to render the segment without a real call.
    func apply(_ next: CaptureState) {
        state = next
        segments.allObjects.forEach { $0.update(next) }
        context.shell?.segmentsChanged()
    }
}

private final class CaptureSegmentView: NSStackView {
    private let mic = symbol("mic.fill", size: 11, weight: .semibold, color: .systemOrange)
    private let camera = symbol("video.fill", size: 11, weight: .semibold, color: .systemGreen)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        detachesHiddenViews = true
        [mic, camera].forEach(addArrangedSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        identifier = NSUserInterfaceItemIdentifier("capture-segment")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: CaptureState) {
        mic.isHidden = !state.microphone
        camera.isHidden = !state.camera
        isHidden = !state.active
        toolTip = state.summary
        setAccessibilityLabel(state.summary)
    }
}
