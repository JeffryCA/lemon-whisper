import SwiftUI
import AppKit

/// A button that, when clicked, captures the next key combo the user presses and turns it into
/// a `RecordingShortcut`. Requires at least one modifier key; Escape cancels the capture.
struct ShortcutRecorderControl: View {
    @Binding var shortcut: RecordingShortcut

    @State private var isCapturing = false
    @State private var validationMessage: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(isCapturing ? "Press a key combo…" : shortcut.displayString) {
                beginCapture()
            }
            .buttonStyle(NeutralActionButtonStyle())

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { endCapture() }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        validationMessage = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode != 53 else {
            validationMessage = nil
            endCapture()
            return
        } // Escape cancels without changing the shortcut

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let character = event.charactersIgnoringModifiers?.lowercased().first else {
            validationMessage = "Use Command, Control, or Option with a key."
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
        validationMessage = nil
        endCapture()
    }

    private func endCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCapturing = false
    }
}
