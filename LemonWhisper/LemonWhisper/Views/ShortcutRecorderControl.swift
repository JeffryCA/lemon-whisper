import SwiftUI
import AppKit

/// Records, adds, and removes global recording shortcuts. Requires at least one modifier key;
/// Escape cancels the active capture.
struct ShortcutRecorderControl: View {
    @Binding var shortcuts: [RecordingShortcut]

    @State private var capturingIndex: Int?
    @State private var validationMessage: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                HStack(spacing: 6) {
                    Button(capturingIndex == index ? "Press a key combo…" : shortcut.displayString) {
                        beginCapture(at: index)
                    }
                    .buttonStyle(NeutralActionButtonStyle())

                    if shortcuts.count > 1 {
                        Button {
                            removeShortcut(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove shortcut")
                    }
                }
            }

            Button {
                beginCapture(at: shortcuts.count)
            } label: {
                Label(
                    capturingIndex == shortcuts.count ? "Press a key combo…" : "Add shortcut",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

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

    private func beginCapture(at index: Int) {
        endCapture()
        capturingIndex = index
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

        let shortcut = RecordingShortcut(
            keyCode: UInt32(event.keyCode),
            character: String(character),
            usesCommand: flags.contains(.command),
            usesShift: flags.contains(.shift),
            usesOption: flags.contains(.option),
            usesControl: flags.contains(.control)
        )

        guard let capturingIndex else { return }
        guard !shortcuts.enumerated().contains(where: { index, existing in
            existing.conflicts(with: shortcut) && index != capturingIndex
        }) else {
            validationMessage = "That shortcut is already configured."
            return
        }

        if capturingIndex < shortcuts.count {
            shortcuts[capturingIndex] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        validationMessage = nil
        endCapture()
    }

    private func removeShortcut(at index: Int) {
        guard shortcuts.indices.contains(index), shortcuts.count > 1 else { return }
        if capturingIndex == index {
            endCapture()
        }
        shortcuts.remove(at: index)
    }

    private func endCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        capturingIndex = nil
    }
}
