import AppKit
import SwiftUI

@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    static let shared = AppWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<ContentView>?

    private override init() {
        super.init()
    }

    func show(
        controller: LemonWhisperController,
        historyStore: TranscriptionHistoryStore,
        navigationState: AppNavigationState
    ) {
        let contentView = ContentView(
            controller: controller,
            historyStore: historyStore,
            navigationState: navigationState
        )

        if let hostingController {
            hostingController.rootView = contentView
        } else {
            let hostingController = NSHostingController(rootView: contentView)
            self.hostingController = hostingController

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Lemon Whisper"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 360)
            window.center()
            window.delegate = self

            self.window = window
        }

        guard let window else { return }

        updateWindowSize(for: navigationState.currentRoute)

        if !window.isVisible {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func updateWindowSize(for route: AppRoute?) {
        guard let window, let hostingController else { return }
        let minimumContentSize: NSSize
        let targetSize: NSSize

        switch route {
        case .manageModels:
            minimumContentSize = NSSize(width: 640, height: 420)
            targetSize = NSSize(width: 720, height: 520)
        case .transcriptions:
            minimumContentSize = NSSize(width: 720, height: 420)
            targetSize = NSSize(width: 760, height: 520)
        case .none:
            let fittedSize = fittedContentSize(
                for: hostingController,
                minimum: NSSize(width: 480, height: 0)
            )
            minimumContentSize = fittedSize
            targetSize = fittedSize
        }

        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size

        if window.contentRect(forFrameRect: window.frame).size != targetSize {
            window.setContentSize(targetSize)
        }
    }

    private func fittedContentSize(
        for hostingController: NSHostingController<ContentView>,
        minimum: NSSize
    ) -> NSSize {
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize

        return NSSize(
            width: max(minimum.width, fittingSize.width),
            height: max(minimum.height, fittingSize.height)
        )
    }
}
