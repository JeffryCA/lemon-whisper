import Foundation

extension LemonWhisperController {
    func startStatusPolling() {
        statusPollingManager.start { [weak self] in
            self?.refreshRuntimeStatus()
        }
    }

    func refreshRuntimeStatus() {
        processMemoryMB = currentProcessMemoryMB()
    }

    func setupHotKeys() {
        HotKeyManager.registerToggleRecordingHotKey(into: &toggleHotKeyRef)
    }

    func setupHotKeyObservers() {
        NotificationCenter.default.addObserver(
            forName: .toggleRecordingHotKey,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            debugLog("🔔 Hotkey notification received on main queue")
            Task { @MainActor in
                self.toggleRecording()
            }
        }
    }
}
