import AppKit
import SwiftUI

/// The recording HUD's visual content. Keep window lifecycle and cursor tracking in
/// `RecordingPulseHUD`; this view exists separately so its appearance is editable in Canvas.
struct RecordingIndicatorView: View {
    let size: CGFloat

    init(size: CGFloat = 30) {
        self.size = size
    }

    var body: some View {
        HUDGlassEffectView(cornerRadius: size / 2)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

private struct HUDGlassEffectView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}

private func makeFloatingHUDPanel(size: CGSize) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
}

private func makeGlassHUDContainer(size: CGFloat) -> NSVisualEffectView {
    let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    container.material = .hudWindow
    container.blendingMode = .behindWindow
    container.state = .active
    container.wantsLayer = true
    container.layer?.cornerRadius = size / 2
    container.layer?.masksToBounds = true
    return container
}

@MainActor
private final class CursorTrackingPanelController {
    private weak var panel: NSPanel?
    private let verticalOffset: CGFloat
    private let updateInterval: TimeInterval
    private var timer: Timer?

    init(
        panel: NSPanel,
        verticalOffset: CGFloat = 18,
        updateInterval: TimeInterval = 1.0 / 30.0
    ) {
        self.panel = panel
        self.verticalOffset = verticalOffset
        self.updateInterval = updateInterval
    }

    func start() {
        stop()
        updatePosition()

        let timer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updatePosition() {
        guard let panel, let point = pointerPosition() else { return }
        let frame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: point.x - (frame.width / 2),
                y: point.y + verticalOffset
            )
        )
    }

    private func pointerPosition() -> NSPoint? {
        let point = NSEvent.mouseLocation
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}

@MainActor
final class RecordingPulseHUD {
    static let shared = RecordingPulseHUD()

    private var panel: NSPanel?
    private var cursorTracker: CursorTrackingPanelController?
    private var hideWorkItem: DispatchWorkItem?
    private let bubbleSize: CGFloat = 30

    private init() {}

    func showPulse(isRecording: Bool, persistUntilRecordingStops: Bool = false) {
        ensurePanel()
        guard let panel else { return }

        hideWorkItem?.cancel()

        cursorTracker?.start()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1
        }

        if isRecording && persistUntilRecordingStops {
            return
        }

        let hideItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.16
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    Task { @MainActor [weak self, weak panel] in
                        self?.cursorTracker?.stop()
                        panel?.orderOut(nil)
                    }
                })
            }
        }
        hideWorkItem = hideItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: hideItem)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = makeFloatingHUDPanel(size: CGSize(width: bubbleSize, height: bubbleSize))
        let indicator = NSHostingView(rootView: RecordingIndicatorView(size: bubbleSize))
        indicator.frame = NSRect(x: 0, y: 0, width: bubbleSize, height: bubbleSize)
        panel.contentView = indicator

        self.panel = panel
        self.cursorTracker = CursorTrackingPanelController(panel: panel)
    }
}

#Preview("Recording indicator") {
    ZStack {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        RecordingIndicatorView()
    }
    .frame(width: 160, height: 100)
}

@MainActor
final class TranscriptionLoadingHUD {
    static let shared = TranscriptionLoadingHUD()

    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var cursorTracker: CursorTrackingPanelController?
    private let size: CGFloat = 30

    private init() {}

    func show() {
        ensurePanel()
        guard let panel else { return }

        cursorTracker?.start()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        spinner?.startAnimation(nil)
    }

    func hide() {
        cursorTracker?.stop()
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = makeFloatingHUDPanel(size: CGSize(width: size, height: size))
        let container = makeGlassHUDContainer(size: size)

        let spinnerInset: CGFloat = 7
        let spinner = NSProgressIndicator(
            frame: NSRect(
                x: spinnerInset,
                y: spinnerInset,
                width: size - (spinnerInset * 2),
                height: size - (spinnerInset * 2)
            )
        )
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        panel.contentView = container

        self.panel = panel
        self.spinner = spinner
        self.cursorTracker = CursorTrackingPanelController(panel: panel)
    }
}
