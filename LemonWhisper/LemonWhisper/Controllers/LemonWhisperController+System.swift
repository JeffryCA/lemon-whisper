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

    /// Refreshes the memory readout now and once more shortly after, so mode changes and
    /// idle unloads are reflected immediately instead of waiting for the next poll tick.
    /// The follow-up catches memory that the allocator releases a beat after `unload()` returns.
    func refreshRuntimeStatusSoon() {
        refreshRuntimeStatus()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            refreshRuntimeStatus()
        }
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
