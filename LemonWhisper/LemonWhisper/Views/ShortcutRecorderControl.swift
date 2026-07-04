import SwiftUI
import AppKit

/// A button that, when clicked, captures the next key combo the user presses and turns it into
/// a `RecordingShortcut`. Requires at least one modifier key; Escape cancels the capture.
struct ShortcutRecorderControl: View {
    @Binding var shortcut: RecordingShortcut

    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(isCapturing ? "Press a key combo…" : shortcut.displayString) {
            beginCapture()
        }
        .buttonStyle(NeutralActionButtonStyle())
        .onDisappear { endCapture() }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        defer { endCapture() }

        guard event.keyCode != 53 else { return } // Escape cancels without changing the shortcut

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let character = event.charactersIgnoringModifiers?.lowercased().first else {
            return
        }

        shortcut = RecordingShortcut(
            keyCode: UInt32(event.keyCode),
            character: String(character),
            usesCommand: flags.contains(.command),
            usesShift: flags.contains(.shift),
            usesOption: flags.contains(.option),
            usesControl: flags.contains(.control)
        )
    }

    private func endCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCapturing = false
    }
}
