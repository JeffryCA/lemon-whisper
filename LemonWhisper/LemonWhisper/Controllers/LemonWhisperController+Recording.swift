import AppKit
import AVFoundation

struct LiveDictationProgress {
    private(set) var audioStartFrame = 0
    private(set) var restartedAt: Date?
    private(set) var history: [LiveDictationHistorySegment] = []

    @discardableResult
    mutating func fieldEdited(
        transcript: LiveDictationInsertion.Transcript?, at frame: Int, time: Date, recordingStartedAt: Date?
    ) -> Bool {
        guard let transcript else { return false }
        history.append(.init(transcript: transcript, startedAt: restartedAt ?? recordingStartedAt, stoppedAt: time))
        audioStartFrame = frame
        restartedAt = time
        return true
    }
}

extension LemonWhisperController {
    func toggleRecording() {
        debugLog("🎙️ toggleRecording invoked. isRecording=\(isRecording) canStartNewRecording=\(canStartNewRecording)")

        if isRecording {
            requestRecordingStop()
            return
        }

        guard canStartNewRecording else {
            debugLog("⛔️ toggleRecording ignored because setupState is not ready")
            return
        }

        startRecordingIfAuthorized()
    }

    /// AVAudioRecorder can produce only a header when it is stopped immediately. A small floor
    /// still feels instant while ensuring quick shortcut taps contain usable audio.
    static let minimumRecordingDuration: TimeInterval = 0.35

    private func requestRecordingStop() {
        guard scheduledRecordingStop == nil else { return }

        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, Self.minimumRecordingDuration - elapsed)
        guard delay > 0 else {
            finishRecordingAndTranscribe()
            return
        }

        debugLog("⏱️ Delaying very short recording stop by \(Int(delay * 1000)) ms")
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishRecordingAndTranscribe()
            }
        }
        scheduledRecordingStop = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishRecordingAndTranscribe() {
        guard isRecording else { return }
        scheduledRecordingStop = nil

        let stoppedAt = Date()
        let backend = recordingBackend ?? selectedBackend
        debugLog("🛑 Stopping recording")
        if liveWriteTask == nil {
            _ = resetLiveSegmentIfEdited()
        }
        stopLivePreview()
        recorder.stopRecording()
        isRecording = false
        recordingBackend = nil
        transcribeLatestRecording(recordingStoppedAt: stoppedAt, backend: backend)
    }

    /// Fallback recording length used to budget eager materialization before we've measured a
    /// real recording (e.g. the first lazy-mode recording after launch).
    static let assumedTypicalRecordingDuration: TimeInterval = 3

    /// Called the moment recording begins. Starts loading the model in parallel so it is ready
    /// by the time recording stops.
    private func onRecordingDidStart() {
        let backend = recordingBackend ?? selectedBackend
        cancelScheduledModelUnload(for: backend)
        guard modelLoadingMode == .lazy else { return }

        // Load the pipeline in parallel with recording. The backend materializes weights now
        // only if a prior measurement shows that pass fits within a typical recording;
        // otherwise it defers to the transcription so it can never block it.
        let budget = lastRecordingDuration ?? Self.assumedTypicalRecordingDuration
        warmUpCurrentBackendInBackground(weightMaterializationBudget: budget)
    }

    func cancelRecording() {
        guard isRecording else { return }

        debugLog("🗑️ Cancelling recording")
        scheduledRecordingStop?.cancel()
        scheduledRecordingStop = nil
        let backend = recordingBackend ?? selectedBackend
        stopLivePreview()
        let insertion = liveInsertion
        let pendingWrite = liveWriteTask
        liveInsertion = nil
        liveWriteTask = nil
        liveProgress = LiveDictationProgress()
        if let insertion {
            Task {
                _ = await pendingWrite?.value
                await insertion.discardLive()
            }
        }
        recorder.cancelRecording()
        RecordingHUD.shared.showPulse()
        isRecording = false
        recordingStartedAt = nil
        recordingBackend = nil
        recordingLanguage = nil
        recordingDictionary = .init()
        recordingContext = nil
        if (backend == .voxtral || backend == .qwen), activeTranscriptionCounts[backend, default: 0] == 0 {
            if modelWarmupBackend == backend {
                modelWarmupTask?.cancel()
                modelWarmupTask = nil
                modelWarmupBackend = nil
            }
            Task { @MainActor [weak self] in
                if backend == .qwen { await QwenService.shared.cancel() }
                else { await VoxtralService.shared.cancelCurrentWorker() }
                guard let self, self.modelLoadingMode == .fast, self.selectedBackend == backend else {
                    return
                }
                self.warmUpCurrentBackendInBackground(weightMaterializationBudget: .infinity)
            }
        }
        unloadBackendIfUnused(backend)
    }

    var canStartNewRecording: Bool {
        // Optimistic once a model is on disk (it may still be loading), but never while there is
        // no usable model — downloading, bootstrapping, or a failed/blocked setup.
        hasUsableSelectedModel && !setupState.blocksRecording
    }

    var recordingButtonTitle: String {
        if isRecording {
            return "Stop Recording"
        }
        return setupState.idleButtonTitle
    }

    func startRecordingIfAuthorized() {
        let status = permissionManager.microphoneAuthorizationStatus()
        debugLog("🎤 startRecordingIfAuthorized status=\(status.rawValue)")

        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            permissionManager.requestMicrophoneAccess { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        debugLog("❌ Microphone permission denied")
                    }
                }
            }
        case .denied, .restricted:
            debugLog("❌ Microphone permission denied")
        @unknown default:
            debugLog("⚠️ Unknown microphone permission status")
        }
    }

    private func beginRecording() {
        guard !isRecording, canStartNewRecording else { return }
        capturePasteTargetApp()

        let backend = selectedBackend
        let wantsPreview = backend.supportsLivePreview && AppSettingsStore.livePreviewEnabled
            && activeTranscriptionCounts[backend, default: 0] == 0
        let insertion = wantsPreview ? TranscriptionManager.shared.beginLiveDictation(processID: targetProcessID) : nil
        if wantsPreview && insertion == nil {
            debugLog("Live dictation unavailable for the focused field. Using final paste.")
        }
        let dictionary: TranscriptionDictionary
        do {
            dictionary = try TranscriptionDictionary.load()
        } catch {
            debugLog("Could not read transcription dictionary: \(error.localizedDescription)")
            dictionary = .init()
        }
        let context = backend.supportsVocabularyHints && AppSettingsStore.vocabularyHintsEnabled
            ? dictionary.context(additional: AppSettingsStore.transcriptionContext) : nil

        guard recorder.startRecording(livePreview: insertion != nil) else {
            debugLog("❌ Recording failed to start")
            return
        }
        recordingStartedAt = Date()
        liveProgress = LiveDictationProgress()
        recordingBackend = backend
        recordingLanguage = selectedLanguageCode
        recordingDictionary = dictionary
        recordingContext = context
        RecordingHUD.shared.showPulse(persistUntilRecordingStops: recordingIndicatorEnabled)
        isRecording = true
        onRecordingDidStart()

        if let insertion, recorder.isCapturingLivePreview {
            liveInsertion = insertion
            startLivePreview(language: selectedLanguageCode, dictionary: dictionary, context: context)
        }
    }

    private func stopLivePreview() {
        livePreviewID = nil
    }

    @discardableResult
    private func resetLiveSegmentIfEdited() -> Bool {
        guard let insertion = liveInsertion,
              insertion.fieldChange == .edited,
              let next = insertion.nextSegment() else { return false }
        liveInsertion = next
        if liveProgress.fieldEdited(
            transcript: insertion.transcript, at: recorder.liveFrameCount,
            time: Date(), recordingStartedAt: recordingStartedAt
        ) {
            debugLog("Live dictation started a new audio segment after a manual edit.")
        }
        return true
    }

    private func startLivePreview(
        language: String, dictionary: TranscriptionDictionary, context: String?
    ) {
        let id = UUID()
        livePreviewID = id
        // Observe edits even when an inference request is still running.
        Task { @MainActor [weak self] in
            while self?.livePreviewID == id {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, livePreviewID == id else { return }
                if liveWriteTask == nil { resetLiveSegmentIfEdited() }
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var activeInsertion: LiveDictationInsertion?
            var lastFrame = 0
            var segmentStart = 0
            var completedOriginal: [String] = []
            var completedCorrected: [String] = []
            while livePreviewID == id {
                try? await Task.sleep(for: .milliseconds(200))
                guard livePreviewID == id else { return }
                _ = resetLiveSegmentIfEdited()
                guard let insertion = liveInsertion, insertion.fieldChange == .unchanged else { continue }
                if activeInsertion !== insertion {
                    activeInsertion = insertion
                    segmentStart = liveProgress.audioStartFrame
                    lastFrame = segmentStart
                    completedOriginal.removeAll()
                    completedCorrected.removeAll()
                }
                guard await QwenService.shared.isReady, livePreviewID == id else { continue }
                do {
                    guard let snapshot = try recorder.previewSnapshot(from: segmentStart, after: lastFrame) else { continue }
                    let peak = snapshot.buffer.floatChannelData.map {
                        UnsafeBufferPointer(start: $0[0], count: Int(snapshot.buffer.frameLength))
                            .reduce(Float(0)) { max($0, abs($1)) }
                    } ?? 0
                    guard peak >= 0.003 else {
                        lastFrame = snapshot.endFrame
                        if snapshot.isCompleteSegment { segmentStart = lastFrame }
                        continue
                    }
                    let url = try FileManager.default.writeBufferToWav(snapshot.buffer)
                    defer { try? FileManager.default.removeItem(at: url) }
                    // Re-decode the current audio segment so later speech can revise earlier words.
                    let text = try await QwenService.shared.transcribe(
                        audioURL: url, language: language, context: context, onPartial: { _ in }
                    )
                    guard livePreviewID == id else { return }
                    guard !resetLiveSegmentIfEdited(), liveInsertion === insertion,
                          insertion.fieldChange == .unchanged else { continue }
                    lastFrame = snapshot.endFrame
                    let trimmed = TranscriptionDictionary.removingVocabularyEcho(from: text, context: context)
                    guard !trimmed.isEmpty else {
                        if snapshot.isCompleteSegment { segmentStart = lastFrame }
                        continue
                    }
                    let corrected = dictionary.applyingCorrections(to: trimmed)
                    if snapshot.isCompleteSegment {
                        completedOriginal.append(trimmed)
                        completedCorrected.append(corrected)
                        segmentStart = lastFrame
                    }
                    let original = snapshot.isCompleteSegment ? completedOriginal : completedOriginal + [trimmed]
                    let revision = snapshot.isCompleteSegment ? completedCorrected : completedCorrected + [corrected]
                    let write = Task {
                        let displayed = TranscriptionDictionary.removingSingleWordPeriod(from: revision.joined(separator: " "))
                        return await insertion.update(displayed, original: original.joined(separator: " "))
                    }
                    liveWriteTask = write
                    let didWrite = await write.value
                    guard livePreviewID == id else { return }
                    liveWriteTask = nil
                    guard didWrite else {
                        debugLog("Live dictation paused because the field did not apply the edit.")
                        if resetLiveSegmentIfEdited() { continue }
                        if insertion.fieldChange == .caretMoved { continue }
                        stopLivePreview()
                        return
                    }
                } catch {
                    if livePreviewID == id {
                        debugLog("Live dictation stopped: \(error.localizedDescription)")
                        stopLivePreview()
                    }
                    return
                }
            }
        }
    }

    private func transcribeLatestRecording(
        recordingStoppedAt: Date,
        backend: TranscriptionBackend
    ) {
        let startedAt = liveProgress.restartedAt ?? recordingStartedAt
        let audioStartFrame = liveProgress.audioStartFrame
        let language = recordingLanguage ?? selectedLanguageCode
        let dictionary = recordingDictionary
        let context = recordingContext
        let insertion = liveInsertion
        let pendingWrite = liveWriteTask
        let historySegments = liveProgress.history
        let targetBundleIdentifier = self.targetBundleIdentifier
        let targetProcessID = self.targetProcessID
        liveInsertion = nil
        liveWriteTask = nil
        liveProgress = LiveDictationProgress()
        recordingStartedAt = nil
        recordingLanguage = nil
        recordingDictionary = .init()
        recordingContext = nil

        guard let wavURL = recorder.latestWavURL else {
            Task {
                _ = await pendingWrite?.value
                await TranscriptionHistoryStore.shared.recordLiveSegments(
                    historySegments, language: language, backend: backend, targetBundleIdentifier: targetBundleIdentifier
                )
                await insertion?.discardLive()
            }
            RecordingHUD.shared.showPulse()
            debugLog("⚠️ No latest recording URL available for transcription")
            unloadBackendIfUnused(backend)
            return
        }

        if let startedAt {
            lastRecordingDuration = recordingStoppedAt.timeIntervalSince(startedAt)
        }

        debugLog("📝 Starting transcription. backend=\(backend.rawValue) file=\(wavURL.lastPathComponent)")
        activeTranscriptionCounts[backend, default: 0] += 1
        RecordingHUD.shared.showTranscriptionLoading()

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await pendingWrite?.value
            await waitForCurrentModelWarmup(backend: backend)
            TranscriptionManager.shared.transcribe(
                from: wavURL,
                language: language,
                backend: backend,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessID: targetProcessID,
                recordingStartedAt: startedAt,
                recordingStoppedAt: recordingStoppedAt,
                dictionary: dictionary,
                context: context,
                liveInsertion: insertion,
                audioStartFrame: audioStartFrame,
                liveHistorySegments: historySegments
            ) { [weak self] isActive in
                guard let self else { return }
                if !isActive {
                    self.recorder.deleteTemporaryRecording(at: wavURL)
                    self.activeTranscriptionCounts[backend] = max(
                        0,
                        self.activeTranscriptionCounts[backend, default: 1] - 1
                    )
                    if self.activeTranscriptionCounts.values.allSatisfy({ $0 == 0 }) {
                        RecordingHUD.shared.hideTranscriptionLoading()
                    }
                    self.unloadBackendIfUnused(backend)
                }
            }
        }
    }

    private func capturePasteTargetApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier = frontmost?.bundleIdentifier
        let frontmostProcessID = frontmost?.processIdentifier

        if frontmostBundleIdentifier == ownBundleIdentifier || frontmostProcessID == getpid() {
            targetBundleIdentifier = nil
            targetProcessID = nil
            print("🎯 Ignoring Lemon Whisper as paste target; will use the frontmost app later")
            return
        }

        targetBundleIdentifier = frontmostBundleIdentifier
        targetProcessID = frontmostProcessID

        if let appName = frontmost?.localizedName, let pid = targetProcessID {
            print("🎯 Paste target captured: \(appName) (pid: \(pid))")
        } else {
            print("⚠️ Could not capture frontmost app for paste target")
        }
    }
}
