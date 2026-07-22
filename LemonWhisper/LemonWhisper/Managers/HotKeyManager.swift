import Carbon
import Foundation
import AppKit

extension Notification.Name {
    static let toggleRecordingHotKey = Notification.Name("toggleRecordingHotKey")
    static let cancelRecordingHotKey = Notification.Name("cancelRecordingHotKey")
}

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    debugLog("⌨️ Global hotkey event received")
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .toggleRecordingHotKey, object: nil)
    }
    return noErr
}

enum HotKeyManager {
    private static var globalFlagsMonitor: Any?
    private static var localFlagsMonitor: Any?
    private static var lastControlTapDate: Date?
    private static let doubleTapThreshold: TimeInterval = 0.35
    private static var handlerInstalled = false

    static func registerToggleRecordingHotKeys(
        into hotKeyRefs: inout [EventHotKeyRef],
        shortcuts: [RecordingShortcut]
    ) {
        installEventHandlerOnce()
        unregisterToggleRecordingHotKeys(&hotKeyRefs)

        for (index, shortcut) in shortcuts.enumerated() {
            let toggleHotKeyID = EventHotKeyID(signature: OSType(32), id: UInt32(index + 1))
            var hotKeyRef: EventHotKeyRef?
            debugLog("⌨️ Registering global hotkey with keyCode=\(shortcut.keyCode) modifiers=\(shortcut.carbonModifiers)")

            let registerStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                toggleHotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            if registerStatus == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
                debugLog("✅ Registered global hotkey \(shortcut.displayString)")
            } else {
                debugLog("❌ Failed to register global hotkey \(shortcut.displayString) (status: \(registerStatus))")
            }
        }

        installCancelRecordingMonitorIfNeeded()
    }

    static func updateToggleRecordingHotKeys(
        into hotKeyRefs: inout [EventHotKeyRef],
        shortcuts: [RecordingShortcut]
    ) {
        registerToggleRecordingHotKeys(into: &hotKeyRefs, shortcuts: shortcuts)
    }

    private static func unregisterToggleRecordingHotKeys(_ hotKeyRefs: inout [EventHotKeyRef]) {
        for existingRef in hotKeyRefs {
            UnregisterEventHotKey(existingRef)
        }
        hotKeyRefs.removeAll()
    }

    private static func installEventHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))],
            nil,
            nil
        )

        if installStatus == noErr {
            debugLog("✅ Installed global hotkey event handler")
        } else {
            debugLog("❌ Failed to install hotkey handler (status: \(installStatus))")
        }
    }

    private static func installCancelRecordingMonitorIfNeeded() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    private static func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == 59 || event.keyCode == 62 else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .control else { return }

        let now = Date()
        if let lastControlTapDate, now.timeIntervalSince(lastControlTapDate) <= doubleTapThreshold {
            self.lastControlTapDate = nil
            debugLog("⌨️ Double-control detected")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cancelRecordingHotKey, object: nil)
            }
            return
        }

        lastControlTapDate = now
    }
}
