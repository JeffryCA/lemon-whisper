import AVFoundation
import ApplicationServices

final class PermissionManager {
    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func logMicrophonePermissionState() {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            debugLog("✅ Microphone permission granted")
        case .notDetermined:
            debugLog("ℹ️ Microphone permission not determined yet")
        case .denied, .restricted:
            debugLog("❌ Microphone permission denied")
        @unknown default:
            debugLog("⚠️ Unknown microphone permission status")
        }
    }

    func requestAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        debugLog("♿️ Accessibility trusted=\(trusted)")
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            debugLog("♿️ Requested Accessibility permission prompt")
        }
    }

    func requestMicrophonePermissionIfNeeded() {
        switch microphoneAuthorizationStatus() {
        case .notDetermined:
            requestMicrophoneAccess { granted in
                if granted {
                    debugLog("✅ Microphone permission granted (proactive)")
                } else {
                    debugLog("❌ Microphone permission denied (proactive)")
                }
            }
        case .authorized:
            debugLog("✅ Microphone already authorized")
        case .denied, .restricted:
            debugLog("❌ Microphone already denied or restricted")
        @unknown default:
            debugLog("⚠️ Unknown proactive microphone permission status")
        }
    }
}
