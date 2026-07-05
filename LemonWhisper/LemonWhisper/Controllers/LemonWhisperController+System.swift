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
        HotKeyManager.registerToggleRecordingHotKey(
            into: &toggleHotKeyRef,
            keyCode: recordingShortcut.keyCode,
            modifiers: recordingShortcut.carbonModifiers
        )
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

        NotificationCenter.default.addObserver(
            forName: .cancelRecordingHotKey,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            debugLog("🔔 Cancel recording notification received on main queue")
            Task { @MainActor in
                self.cancelRecording()
            }
        }
    }
}
