import Foundation

extension LemonWhisperController {
    func startStatusPolling() {
        statusPollingManager.start { [weak self] in
            self?.refreshRuntimeStatus()
        }
    }

    func refreshRuntimeStatus() {
        processMemoryMB = currentProcessMemoryMB(
            including: VoxtralWorkerProcessRegistry.shared.processIdentifiers()
        )
    }

    func setupHotKeys() {
        HotKeyManager.registerToggleRecordingHotKeys(
            into: &toggleHotKeyRefs,
            shortcuts: recordingShortcuts
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
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                debugLog("🔔 Cancel recording notification received on main queue")
                self.cancelRecording()
            }
        }
    }
}
