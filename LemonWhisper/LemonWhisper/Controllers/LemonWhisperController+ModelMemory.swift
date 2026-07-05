import Foundation

extension LemonWhisperController {
    /// The memory controller for whichever backend is currently selected.
    var memoryController: ModelMemoryController {
        switch selectedBackend {
        case .whisper:
            return WhisperMemoryController()
        case .voxtral:
            return VoxtralMemoryController()
        }
    }

    func setModelLoadingMode(_ mode: ModelLoadingMode) {
        guard mode != modelLoadingMode else { return }
        modelLoadingMode = mode
        AppSettingsStore.modelLoadingMode = mode
        debugLog("⚙️ Model loading mode set to \(mode.rawValue)")

        switch mode {
        case .fast:
            // Cancel any pending unload and load the model now, fully resident.
            cancelIdleUnloadTimer()
            warmUpCurrentBackendInBackground(weightMaterializationBudget: .infinity)
        case .lazy:
            // Start counting toward an idle unload from now.
            scheduleIdleUnloadIfNeeded()
        }
    }

    /// Loads the active backend's model off the main actor without blocking recording.
    /// Idempotent: skips the work if the model is already resident. `weightMaterializationBudget`
    /// is forwarded to the backend to decide whether to eagerly materialize weights now.
    func warmUpCurrentBackendInBackground(weightMaterializationBudget: TimeInterval?) {
        let controller = memoryController
        Task.detached {
            if await controller.isLoaded() { return }
            do {
                try await controller.warmUp(weightMaterializationBudget: weightMaterializationBudget)
            } catch {
                await MainActor.run {
                    debugLog("⚠️ Background warmup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func setModelIdleTimeout(_ timeout: ModelIdleTimeout) {
        guard timeout != modelIdleTimeout else { return }
        modelIdleTimeout = timeout
        AppSettingsStore.modelIdleTimeout = timeout
        debugLog("⚙️ Model idle timeout set to \(timeout.rawValue)")
        // Re-arm the countdown with the new value when idle in lazy mode.
        if !isRecording {
            scheduleIdleUnloadIfNeeded()
        }
    }

    /// Restarts the idle-unload countdown. No-op unless lazy mode is active.
    func scheduleIdleUnloadIfNeeded() {
        cancelIdleUnloadTimer()
        guard modelLoadingMode == .lazy else { return }

        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: modelIdleTimeout.seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.unloadCurrentBackendForIdle()
            }
        }
    }

    func cancelIdleUnloadTimer() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil
    }

    private func unloadCurrentBackendForIdle() {
        guard modelLoadingMode == .lazy, !isRecording else { return }
        let controller = memoryController
        let backend = selectedBackend
        debugLog("💤 Idle timeout reached — unloading \(backend.rawValue) model")
        Task.detached {
            await controller.unload()
        }
    }
}
