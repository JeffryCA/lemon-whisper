import Foundation

extension LemonWhisperController {
    var supportsVoxtral: Bool {
        PlatformCapabilities.supportsVoxtral
    }

    var whisperCatalog: [WhisperModelOption] {
        WhisperModelCatalog.models
    }

    var voxtralCatalog: [VoxtralModelOption] {
        get async {
            await VoxtralService.shared.availableModels()
        }
    }

    func setBackend(_ backend: TranscriptionBackend) {
        switch backend {
        case .whisper:
            selectedBackend = .whisper
            UserDefaults.standard.set(TranscriptionBackend.whisper.rawValue, forKey: selectedBackendDefaultsKey)
            Task {
                await VoxtralService.shared.unload()
            }
            ensureWhisperReady()
        case .voxtral:
            guard supportsVoxtral else {
                let message = "Voxtral is unavailable on this Mac. Choose a Whisper model instead."
                voxtralStatus = message
                setupState = .blocked(message: message)
                selectedBackend = .whisper
                return
            }
            setupState = .preparingSelectedModel
            Task { @MainActor in
                await ensureVoxtralReady()
            }
        }
    }

    func selectDownloadedWhisperModelAndActivate(_ id: String) {
        selectWhisperModel(id)
        setBackend(.whisper)
    }

    func selectDownloadedVoxtralModelAndActivate(_ id: String) {
        guard supportsVoxtral else { return }
        Task { @MainActor in
            await selectVoxtralModel(id)
            setBackend(.voxtral)
        }
    }

    func selectWhisperModel(_ id: String) {
        guard WhisperModelCatalog.option(for: id) != nil else { return }
        selectedWhisperModelID = id
        WhisperModelCatalog.setSelectedModelID(id)
        WhisperContext.clearShared()
    }

    func selectVoxtralModel(_ id: String) async {
        await VoxtralService.shared.setSelectedModel(id)
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()
    }

    func downloadWhisperModel(_ id: String) {
        guard !whisperOperationsInFlight.contains(id),
              let option = WhisperModelCatalog.option(for: id) else {
            return
        }

        if selectedBackend == .whisper && selectedWhisperModelID == id {
            setupState = .preparingSelectedModel
        }

        whisperOperationsInFlight.insert(id)
        whisperDownloadProgress[id] = 0
        whisperStatus = "Downloading \(option.title)..."

        Task { @MainActor in
            defer {
                whisperOperationsInFlight.remove(id)
                whisperDownloadProgress[id] = nil
            }

            do {
                try await WhisperModelCatalog.downloadModel(option) { progress in
                    Task { @MainActor in
                        self.whisperDownloadProgress[id] = progress
                    }
                }
                whisperStatus = "Downloaded \(option.title)"
                refreshWhisperDownloads()
                if selectedBackend == .whisper && selectedWhisperModelID == id {
                    ensureWhisperReady()
                } else if selectedWhisperModelID == id {
                    WhisperContext.clearShared()
                }
            } catch {
                whisperStatus = "Whisper download failed: \(error.localizedDescription)"
                if selectedBackend == .whisper && selectedWhisperModelID == id {
                    setupState = .blocked(message: whisperStatus ?? "Whisper download failed.")
                }
            }
        }
    }

    func removeWhisperModel(_ id: String) {
        guard !whisperOperationsInFlight.contains(id),
              let option = WhisperModelCatalog.option(for: id) else {
            return
        }

        whisperOperationsInFlight.insert(id)
        defer { whisperOperationsInFlight.remove(id) }

        do {
            try WhisperModelCatalog.removeModel(option)
            whisperStatus = "Removed \(option.title)"
            refreshWhisperDownloads()

            if selectedWhisperModelID == id {
                if let fallback = downloadedWhisperModels.first {
                    selectWhisperModel(fallback.id)
                }
                WhisperContext.clearShared()
            }

            if selectedBackend == .whisper {
                if downloadedWhisperModels.contains(where: { $0.id == selectedWhisperModelID }) {
                    ensureWhisperReady()
                } else {
                    setupState = .blocked(message: "Download a Whisper model to use Whisper.")
                }
            }
        } catch {
            whisperStatus = "Could not remove \(option.title): \(error.localizedDescription)"
        }
    }

    func downloadVoxtralModel(_ id: String) {
        guard supportsVoxtral else { return }
        guard !voxtralOperationsInFlight.contains(id) else { return }

        setupState = .preparingSelectedModel

        voxtralOperationsInFlight.insert(id)
        voxtralDownloadProgress[id] = nil
        voxtralStatus = "Downloading Voxtral model..."

        Task { @MainActor in
            defer {
                voxtralOperationsInFlight.remove(id)
                voxtralDownloadProgress[id] = nil
            }

            do {
                try await VoxtralService.shared.downloadModel(id) { progress, status in
                    Task { @MainActor in
                        self.voxtralDownloadProgress[id] = progress >= 1 ? progress : nil
                        self.voxtralStatus = status
                    }
                }
                voxtralStatus = "Voxtral model downloaded"
                await refreshVoxtralDownloads()
                if id == selectedVoxtralModelID {
                    _ = await ensureVoxtralReady()
                }
            } catch {
                voxtralStatus = "Voxtral download failed: \(error.localizedDescription)"
                if id == selectedVoxtralModelID {
                    setupState = .blocked(message: voxtralStatus ?? "Voxtral download failed.")
                }
            }
        }
    }

    func removeVoxtralModel(_ id: String) {
        guard supportsVoxtral else { return }
        guard !voxtralOperationsInFlight.contains(id) else { return }
        voxtralOperationsInFlight.insert(id)

        Task { @MainActor in
            defer { voxtralOperationsInFlight.remove(id) }

            do {
                try await VoxtralService.shared.removeModel(id)
                voxtralStatus = "Voxtral model removed"
                await refreshVoxtralDownloads()

                if selectedVoxtralModelID == id, let fallback = downloadedVoxtralModels.first {
                    await selectVoxtralModel(fallback.id)
                }

                if selectedBackend == .voxtral {
                    if downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) {
                        _ = await ensureVoxtralReady()
                    } else {
                        setupState = .blocked(message: "Download a Voxtral model to use Voxtral.")
                    }
                }
            } catch {
                voxtralStatus = "Could not remove Voxtral model: \(error.localizedDescription)"
            }
        }
    }

    func isWhisperModelDownloaded(_ id: String) -> Bool {
        downloadedWhisperModels.contains(where: { $0.id == id })
    }

    func isVoxtralModelDownloaded(_ id: String) -> Bool {
        downloadedVoxtralModels.contains(where: { $0.id == id })
    }

    func isWhisperBusy(_ id: String) -> Bool {
        whisperOperationsInFlight.contains(id)
    }

    func isVoxtralBusy(_ id: String) -> Bool {
        voxtralOperationsInFlight.contains(id)
    }

    func whisperProgress(_ id: String) -> Double? {
        whisperDownloadProgress[id]
    }

    func voxtralProgress(_ id: String) -> Double? {
        voxtralDownloadProgress[id]
    }

    var canSelectVoxtralNow: Bool {
        !isPreparingVoxtral
    }

    var hasAnyDownloadedModels: Bool {
        !downloadedWhisperModels.isEmpty || !downloadedVoxtralModels.isEmpty
    }

    var hasAnySupportedDownloadedModels: Bool {
        !downloadedWhisperModels.isEmpty || (supportsVoxtral && !downloadedVoxtralModels.isEmpty)
    }

    var showsSetupCard: Bool {
        setupState.isBlocking
    }

    var setupCardTitle: String {
        setupState.cardTitle ?? "Model not ready"
    }

    var setupCardMessage: String {
        setupState.cardMessage ?? ""
    }

    var setupCardProgress: Double? {
        switch setupState {
        case .ready, .awaitingModelSelection, .preparingSelectedModel, .blocked:
            return nil
        }
    }

    var setupCardShowsProgress: Bool {
        switch setupState {
        case .ready, .awaitingModelSelection, .blocked:
            return false
        case .preparingSelectedModel:
            return true
        }
    }

    var statusLineText: String {
        setupStatusLine ?? "Process memory: \(processMemoryMB) MB"
    }

    private var setupStatusLine: String? {
        switch setupState {
        case .ready:
            return nil
        case .awaitingModelSelection(let supportsVoxtral):
            if supportsVoxtral {
                return "Choose a local model to enable recording."
            }
            return "This Mac supports Whisper only. Choose a model to enable recording."
        case .preparingSelectedModel:
            if selectedBackend == .whisper,
               let status = whisperStatus,
               !status.isEmpty {
                return status
            }
            if let status = voxtralStatus, !status.isEmpty {
                return status
            }
            return selectedBackend == .whisper ? "Preparing Whisper..." : "Preparing Voxtral Mini 3B 4-bit..."
        case .blocked(let message):
            return message
        }
    }

    func initializeModelsAndBackend() async {
        selectedWhisperModelID = WhisperModelCatalog.selectedModelID()
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()
        debugLog("🧭 Initializing models. selectedWhisper=\(selectedWhisperModelID) selectedVoxtral=\(selectedVoxtralModelID)")

        refreshWhisperDownloads()
        await refreshVoxtralDownloads()
        debugLog("🧭 Downloaded models. whisper=\(downloadedWhisperModels.map(\.id)) voxtral=\(downloadedVoxtralModels.map(\.id))")

        if !supportsVoxtral {
            selectedBackend = .whisper
            await VoxtralService.shared.unload()
        }

        if !hasAnySupportedDownloadedModels {
            selectedBackend = supportsVoxtral && storedBackendPreference() == .voxtral ? .voxtral : .whisper
            setupState = .awaitingModelSelection(supportsVoxtral: supportsVoxtral)
            whisperStatus = nil
            voxtralStatus = nil
            debugLog("ℹ️ No supported downloaded models found. Waiting for explicit model choice")
            return
        }

        switch effectiveStoredBackendPreference() {
        case .voxtral:
            if await activateSelectedVoxtralIfAvailable() {
                return
            }
        case .whisper:
            if activateSelectedWhisperIfAvailable() {
                return
            }
        }

        setupState = .awaitingModelSelection(supportsVoxtral: supportsVoxtral)
    }

    private func refreshWhisperDownloads() {
        downloadedWhisperModels = WhisperModelCatalog.downloadedModels()

        if !downloadedWhisperModels.contains(where: { $0.id == selectedWhisperModelID }),
           let fallback = downloadedWhisperModels.first {
            selectWhisperModel(fallback.id)
        }
    }

    private func refreshVoxtralDownloads() async {
        downloadedVoxtralModels = await VoxtralService.shared.downloadedModels()
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()

        if !downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }),
           let fallback = downloadedVoxtralModels.first {
            await selectVoxtralModel(fallback.id)
        }
    }

    private func ensureWhisperReady() {
        setupState = .preparingSelectedModel
        debugLog("🧠 Preparing Whisper model")

        Task { @MainActor in
            do {
                guard let selected = WhisperModelCatalog.selectedModelIfDownloaded() else {
                    let message = "Download a Whisper model to use Whisper."
                    whisperStatus = message
                    setupState = .blocked(message: message)
                    return
                }

                _ = try await WhisperContext.createContext(path: selected.localURL.path)
                try await WhisperModelCatalog.ensureVADDownloadedIfNeeded()
                if let context = WhisperContext.getShared() {
                    await context.setVADModelPath(WhisperModelCatalog.vadLocalURL.path)
                }
                whisperStatus = "Whisper ready: \(selected.title)"
                setupState = .ready
                debugLog("✅ Whisper ready: \(selected.id)")
            } catch {
                let message = "Failed to load Whisper: \(error.localizedDescription)"
                whisperStatus = message
                setupState = .blocked(message: message)
                debugLog("❌ Whisper preparation failed: \(message)")
            }
        }
    }

    @discardableResult
    private func ensureVoxtralReady() async -> Bool {
        if isPreparingVoxtral {
            debugLog("ℹ️ Voxtral preparation already in progress")
            return selectedBackend == .voxtral
        }

        guard downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) else {
            if hasAnySupportedDownloadedModels {
                let message = "Download a Voxtral model to use Voxtral."
                voxtralStatus = message
                setupState = .blocked(message: message)
                debugLog("⛔️ Selected Voxtral model is not downloaded")
            } else {
                setupState = .awaitingModelSelection(supportsVoxtral: supportsVoxtral)
                debugLog("ℹ️ Voxtral not downloaded yet; waiting for explicit selection")
            }
            return false
        }

        if await VoxtralService.shared.isReady {
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: selectedBackendDefaultsKey)
            setupState = .ready
            debugLog("✅ Voxtral already ready. Switched backend")
            return true
        }

        isPreparingVoxtral = true
        setupState = .preparingSelectedModel
        debugLog("⏳ Preparing Voxtral in background")
        defer { isPreparingVoxtral = false }

        do {
            try await VoxtralService.shared.warmupModel()
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: selectedBackendDefaultsKey)
            setupState = .ready
            debugLog("✅ Voxtral ready. Switched backend")
            return true
        } catch {
            let message: String
            if let details = await VoxtralService.shared.latestError {
                message = "Failed to load Voxtral: \(details)"
            } else {
                message = "Failed to load Voxtral: \(error.localizedDescription)"
            }
            debugLog("❌ Voxtral preparation failed: \(message)")
            await VoxtralService.shared.unload()
            selectedBackend = .voxtral
            voxtralStatus = message
            setupState = .blocked(message: message)
            return false
        }
    }

    private func storedBackendPreference() -> TranscriptionBackend {
        guard
            let rawValue = UserDefaults.standard.string(forKey: selectedBackendDefaultsKey),
            let backend = TranscriptionBackend(rawValue: rawValue)
        else {
            return .voxtral
        }
        return backend
    }

    private func effectiveStoredBackendPreference() -> TranscriptionBackend {
        let stored = storedBackendPreference()
        if stored == .voxtral && !supportsVoxtral {
            return .whisper
        }
        return stored
    }

    private func activateSelectedWhisperIfAvailable() -> Bool {
        guard downloadedWhisperModels.contains(where: { $0.id == selectedWhisperModelID }) else {
            return false
        }

        selectedBackend = .whisper
        ensureWhisperReady()
        return true
    }

    private func activateSelectedVoxtralIfAvailable() async -> Bool {
        guard downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) else {
            return false
        }

        return await ensureVoxtralReady()
    }
}
