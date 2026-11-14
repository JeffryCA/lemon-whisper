import AppKit
import SwiftUI

/// The glass bubble shared by the recording and transcription states.
struct RecordingIndicatorView: View {
    let size: CGFloat

    init(size: CGFloat = 30) {
        self.size = size
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .frame(width: size, height: size)
                .glassEffect(.clear, in: .circle)
                .overlay { rimHighlight }
        } else {
            HUDGlassEffectView(cornerRadius: size / 2)
                .frame(width: size, height: size)
                .overlay { rimHighlight }
        }
    }

    private var rimHighlight: some View {
        Circle().strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.65), location: 0),
                    .init(color: .white.opacity(0.14), location: 0.35),
                    .init(color: .white.opacity(0.14), location: 0.65),
                    .init(color: .white.opacity(0.45), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 0.75
        )
        .overlay {
            Circle()
                .inset(by: 0.75)
                .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
        }
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
final class RecordingHUD {
    static let shared = RecordingHUD()

    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var cursorTracker: CursorTrackingPanelController?
    private var pulseTask: Task<Void, Never>?
    private var isPulseVisible = false
    private var isTranscribing = false
    private let bubbleSize: CGFloat = 30
    private let glassPadding: CGFloat = 4

    private init() {}

    func showPulse(persistUntilRecordingStops: Bool = false) {
        pulseTask?.cancel()
        pulseTask = nil
        isPulseVisible = true
        updateVisibility()

        guard !persistUntilRecordingStops else { return }
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let self else { return }
            pulseTask = nil
            isPulseVisible = false
            updateVisibility()
        }
    }

    func showTranscriptionLoading() {
        pulseTask?.cancel()
        pulseTask = nil
        isPulseVisible = false
        isTranscribing = true
        updateVisibility()
        spinner?.startAnimation(nil)
    }

    func hideTranscriptionLoading() {
        isTranscribing = false
        spinner?.stopAnimation(nil)
        updateVisibility()
    }

    private func updateVisibility() {
        guard isPulseVisible || isTranscribing else {
            cursorTracker?.stop()
            panel?.orderOut(nil)
            return
        }

        ensurePanel()
        guard let panel, !panel.isVisible else { return }
        cursorTracker?.start()
        panel.orderFrontRegardless()
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let side = bubbleSize + 2 * glassPadding
        let size = CGSize(width: side, height: side)
        let panel = makeFloatingHUDPanel(size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let indicator = NSHostingView(
            rootView: RecordingIndicatorView(size: bubbleSize).padding(glassPadding)
        )
        indicator.frame = container.bounds
        container.addSubview(indicator)

        let spinnerSize: CGFloat = 16
        let spinnerInset = (side - spinnerSize) / 2
        let spinner = NSProgressIndicator(
            frame: NSRect(x: spinnerInset, y: spinnerInset, width: spinnerSize, height: spinnerSize)
        )
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        container.addSubview(spinner)

        panel.contentView = container
        self.panel = panel
        self.spinner = spinner
        self.cursorTracker = CursorTrackingPanelController(panel: panel, verticalOffset: 18 - glassPadding)
    }
}

#Preview("Recording indicator") {
    ZStack {
        LinearGradient(
            colors: [.indigo, .mint, .orange],
            startPoint: .leading,
            endPoint: .trailing
        )

        HStack(spacing: 0) {
            ForEach(0..<12) { index in
                Rectangle()
                    .fill(index.isMultiple(of: 2) ? Color.black.opacity(0.55) : .clear)
                    .frame(width: 20)
            }
        }

        HStack(spacing: 28) {
            RecordingIndicatorView()
            RecordingIndicatorView(size: 76)
        }
    }
    .frame(width: 240, height: 120)
}
