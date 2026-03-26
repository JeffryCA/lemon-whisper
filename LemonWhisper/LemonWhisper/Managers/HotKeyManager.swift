import Carbon
import Foundation

extension Notification.Name {
    static let toggleRecordingHotKey = Notification.Name("toggleRecordingHotKey")
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
    }
}
