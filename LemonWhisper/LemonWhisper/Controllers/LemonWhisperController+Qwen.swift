import Foundation

extension LemonWhisperController {
    var qwenModel: LocalModelItem {
        LocalModelItem(
            engine: .qwen, baseID: QwenModelCatalog.modelID, title: QwenModelCatalog.title,
            downloadSizeLabel: "~1.6 GB", expectedPeakMemoryLabel: "Not measured",
            description: "Local multilingual transcription. Apple Silicon required."
        )
    }

    func selectQwenAndActivate() {
        guard supportsVoxtral, !qwenIsBusy, !isPreparingVoxtral, !isRecording,
              activeTranscriptionCounts.values.allSatisfy({ $0 == 0 }) else { return }
        selectedBackend = .qwen
        UserDefaults.standard.set(TranscriptionBackend.qwen.rawValue, forKey: selectedBackendDefaultsKey)
        guard qwenDownloaded else {
            setupState = .blocked(message: "Download the Qwen3-ASR model to use it.")
            return
        }
        setupState = .ready
        qwenStatus = "Qwen3-ASR ready"
        let previousWarmup = modelWarmupTask
        modelWarmupTask?.cancel()
        modelWarmupTask = nil
        modelWarmupBackend = nil
        cancelScheduledModelUnload(for: .qwen)
        Task {
            await VoxtralService.shared.cancelCurrentWorker()
            await previousWarmup?.value
            await WhisperContext.getShared()?.releaseResources()
            WhisperContext.clearShared()
        }
        if modelLoadingMode == .fast {
            warmUpCurrentBackendInBackground(weightMaterializationBudget: .infinity)
        }
    }

    func downloadQwenModel() {
        guard supportsVoxtral, !qwenIsBusy else { return }
        qwenIsBusy = true
        qwenDownloadProgress = 0
        qwenStatus = "Downloading Qwen3-ASR…"
        Task { @MainActor in
            defer { qwenIsBusy = false; qwenDownloadProgress = nil }
            do {
                try await QwenService.shared.download { progress in
                    Task { @MainActor in self.qwenDownloadProgress = progress }
                }
                qwenDownloaded = QwenModelCatalog.isDownloaded
                qwenStatus = "Qwen3-ASR downloaded. Select it in Model to try it."
                if selectedBackend == .qwen { setupState = .ready }
            } catch {
                qwenStatus = error.localizedDescription
                if selectedBackend == .qwen { setupState = .blocked(message: error.localizedDescription) }
            }
        }
    }

    func removeQwenModel() {
        guard !qwenIsBusy, !isRecording,
              activeTranscriptionCounts[.qwen, default: 0] == 0 else { return }
        qwenIsBusy = true
        Task { @MainActor in
            defer { qwenIsBusy = false }
            cancelScheduledModelUnload(for: .qwen)
            await modelWarmupTask?.value
            do {
                try await QwenService.shared.removeModel()
                qwenDownloaded = false
                qwenStatus = "Qwen3-ASR removed."
                if selectedBackend == .qwen {
                    setupState = .blocked(message: "Download the Qwen3-ASR model to use it.")
                }
            } catch { qwenStatus = error.localizedDescription }
        }
    }
}
