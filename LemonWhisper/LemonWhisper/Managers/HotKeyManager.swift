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
    private static var lastCancelTap: (modifier: NSEvent.ModifierFlags, timestamp: TimeInterval)?
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
        let modifier: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case kVK_Control, kVK_RightControl:
            modifier = .control
        case kVK_Option, kVK_RightOption:
            modifier = .option
        default:
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == modifier else { return }

        if let lastCancelTap, lastCancelTap.modifier == modifier,
           event.timestamp - lastCancelTap.timestamp <= doubleTapThreshold {
            self.lastCancelTap = nil
            let name = modifier == .control ? "control" : "option"
            debugLog("⌨️ Double-\(name) detected")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cancelRecordingHotKey, object: nil)
            }
            return
        }

        lastCancelTap = (modifier, event.timestamp)
    }
}
