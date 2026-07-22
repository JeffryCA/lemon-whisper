import AppKit
import SwiftUI

/// Glassy popup listing the most recent transcriptions, shown near the cursor when
/// Option is held for 2s. Clicking a row copies it to the clipboard and dismisses;
/// clicking anywhere else dismisses without copying.
@MainActor
final class QuickPickHUD {
    static let shared = QuickPickHUD()

    private var panel: NSPanel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private let rowHeight: CGFloat = 40
    private let width: CGFloat = 320
    private let maxRows = 10
    private let cornerRadius: CGFloat = 14

    private init() {}

    func show() {
        let records = Array(TranscriptionHistoryStore.shared.items.prefix(maxRows))
        guard !records.isEmpty else { return }

        hide(animated: false)

        let size = CGSize(width: width, height: rowHeight * CGFloat(records.count))
        let panel = makePanel(size: size)
        panel.contentView = makeContentView(records: records, size: size)
        position(panel, size: size)

        self.panel = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        installClickAwayMonitorsIfNeeded()
    }

    func hide(animated: Bool = true) {
        removeClickAwayMonitors()
        guard let panel else { return }
        self.panel = nil

        guard animated else {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func makeContentView(records: [TranscriptionRecord], size: CGSize) -> NSView {
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        let rootView = QuickPickListView(records: records, rowHeight: rowHeight) { [weak self] record in
            TranscriptionHistoryStore.shared.copyToClipboard(record)
            self?.hide()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        return container
    }

    private func position(_ panel: NSPanel, size: CGSize) {
        let mouseLocation = NSEvent.mouseLocation
        var origin = NSPoint(x: mouseLocation.x + 12, y: mouseLocation.y - size.height - 12)

        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        }

        panel.setFrameOrigin(origin)
    }

    private func installClickAwayMonitorsIfNeeded() {
        guard globalClickMonitor == nil, localClickMonitor == nil else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            self.hide()
            return event
        }
    }

    private func removeClickAwayMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }
}

private struct QuickPickListView: View {
    let records: [TranscriptionRecord]
    let rowHeight: CGFloat
    let onSelect: (TranscriptionRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                QuickPickRow(record: record, onSelect: { onSelect(record) })
                    .frame(height: rowHeight)

                if index < records.count - 1 {
                    Divider()
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

private struct QuickPickRow: View {
    let record: TranscriptionRecord
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text(record.excerpt(maxLength: 46))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(record.timestampLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
