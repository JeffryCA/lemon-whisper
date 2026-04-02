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

    static func registerToggleRecordingHotKey(into hotKeyRef: inout EventHotKeyRef?) {
        let keyCodeGermanY: UInt32 = UInt32(kVK_ANSI_Z)
        let modifiers: UInt32 = UInt32(controlKey)
        let toggleHotKeyID = EventHotKeyID(signature: OSType(32), id: 1)
        debugLog("⌨️ Registering global hotkey Ctrl+Y with keyCode=\(keyCodeGermanY)")

        let registerStatus = RegisterEventHotKey(
            keyCodeGermanY,
            modifiers,
            toggleHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            debugLog("✅ Registered global hotkey Ctrl+Y (keyCode: \(keyCodeGermanY))")
        } else {
            debugLog("❌ Failed to register global hotkey Ctrl+Y (status: \(registerStatus))")
        }

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

        installCancelRecordingMonitorIfNeeded()
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
