import Foundation

extension LemonWhisperController {
    func memoryController(for backend: TranscriptionBackend) -> ModelMemoryController {
        switch backend {
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
            cancelAllScheduledModelUnloads()
            warmUpCurrentBackendInBackground(weightMaterializationBudget: .infinity)
        case .lazy:
            unloadBackendIfUnused(selectedBackend)
        }
    }

    func setModelIdleTimeout(_ timeout: ModelIdleTimeout) {
        guard timeout != modelIdleTimeout else { return }
        modelIdleTimeout = timeout
        AppSettingsStore.modelIdleTimeout = timeout
        debugLog("⚙️ Model idle timeout set to \(timeout.rawValue)")

        if modelLoadingMode == .lazy {
            cancelAllScheduledModelUnloads()
            unloadBackendIfUnused(selectedBackend)
        }
    }

    /// Loads the active backend's model off the main actor without blocking recording.
    /// Transcription waits for this same task if a short recording ends before warmup does,
    /// avoiding a second concurrent model load.
    func warmUpCurrentBackendInBackground(weightMaterializationBudget: TimeInterval?) {
        let backend = recordingBackend ?? selectedBackend
        cancelScheduledModelUnload(for: backend)
        guard modelWarmupTask == nil else { return }

        let controller = memoryController(for: backend)
        let pendingUnload = modelUnloadTasks.removeValue(forKey: backend)
        modelWarmupBackend = backend
        modelWarmupTask = Task {
            // If a previous use just finished, let its unload complete before loading again.
            // This prevents an immediate new recording from racing an in-flight unload.
            await pendingUnload?.value
            if await controller.isLoaded() { return }
            do {
                try await controller.warmUp(weightMaterializationBudget: weightMaterializationBudget)
            } catch {
                debugLog("⚠️ Background warmup failed: \(error.localizedDescription)")
            }
        }
    }

    func waitForCurrentModelWarmup(backend: TranscriptionBackend) async {
        guard modelWarmupBackend == backend, let task = modelWarmupTask else { return }
        await task.value
        modelWarmupTask = nil
        modelWarmupBackend = nil
    }

    private func unloadBackendNow(_ backend: TranscriptionBackend) {
        let warmupTask = modelWarmupBackend == backend ? modelWarmupTask : nil
        if modelWarmupBackend == backend {
            modelWarmupTask = nil
            modelWarmupBackend = nil
        }

        let controller = memoryController(for: backend)
        debugLog("🧹 Unloading \(backend.rawValue) model after use")
        modelUnloadTasks[backend] = Task {
            await warmupTask?.value
            await controller.unload()
        }
    }

    func unloadBackendIfUnused(_ backend: TranscriptionBackend) {
        guard modelLoadingMode == .lazy,
              recordingBackend != backend,
              activeTranscriptionCounts[backend, default: 0] == 0 else {
            return
        }

        cancelScheduledModelUnload(for: backend)
        debugLog("⏳ Scheduling \(backend.rawValue) model unload in \(Int(modelIdleTimeout.seconds)) seconds")
        modelIdleUnloadTimers[backend] = Timer.scheduledTimer(
            withTimeInterval: modelIdleTimeout.seconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelIdleUnloadTimers[backend] = nil
                guard self.modelLoadingMode == .lazy,
                      self.recordingBackend != backend,
                      self.activeTranscriptionCounts[backend, default: 0] == 0 else {
                    return
                }
                self.unloadBackendNow(backend)
            }
        }
    }

    func cancelScheduledModelUnload(for backend: TranscriptionBackend) {
        modelIdleUnloadTimers.removeValue(forKey: backend)?.invalidate()
    }

    private func cancelAllScheduledModelUnloads() {
        for timer in modelIdleUnloadTimers.values {
            timer.invalidate()
        }
        modelIdleUnloadTimers.removeAll()
    }
}
