import AppKit
import AVFoundation

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
        recorder.stopRecording()
        RecordingPulseHUD.shared.showPulse(isRecording: false)
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
        recorder.cancelRecording()
        RecordingPulseHUD.shared.showPulse(isRecording: false)
        isRecording = false
        recordingStartedAt = nil
        recordingBackend = nil
        if backend == .voxtral {
            if modelWarmupBackend == backend {
                modelWarmupTask?.cancel()
                modelWarmupTask = nil
                modelWarmupBackend = nil
            }
            Task { @MainActor [weak self] in
                await VoxtralService.shared.cancelCurrentWorker()
                guard let self, self.modelLoadingMode == .fast, self.selectedBackend == .voxtral else {
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
            capturePasteTargetApp()
            guard recorder.startRecording() else {
                debugLog("❌ Recording failed to start")
                return
            }
            recordingStartedAt = Date()
            recordingBackend = selectedBackend
            RecordingPulseHUD.shared.showPulse(
                isRecording: true,
                persistUntilRecordingStops: recordingIndicatorEnabled
            )
            isRecording = true
            onRecordingDidStart()
            debugLog("✅ Recording started")
        case .notDetermined:
            permissionManager.requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    if granted {
                        debugLog("✅ Microphone permission granted")
                        self.capturePasteTargetApp()
                        guard self.recorder.startRecording() else {
                            debugLog("❌ Recording failed to start after microphone permission prompt")
                            return
                        }
                        self.recordingStartedAt = Date()
                        self.recordingBackend = self.selectedBackend
                        RecordingPulseHUD.shared.showPulse(
                            isRecording: true,
                            persistUntilRecordingStops: self.recordingIndicatorEnabled
                        )
                        self.isRecording = true
                        self.onRecordingDidStart()
                        debugLog("✅ Recording started after microphone permission prompt")
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

    private func transcribeLatestRecording(
        recordingStoppedAt: Date,
        backend: TranscriptionBackend
    ) {
        guard let wavURL = recorder.latestWavURL else {
            debugLog("⚠️ No latest recording URL available for transcription")
            unloadBackendIfUnused(backend)
            return
        }

        let startedAt = recordingStartedAt
        recordingStartedAt = nil

        if let startedAt {
            lastRecordingDuration = recordingStoppedAt.timeIntervalSince(startedAt)
        }

        let language = selectedLanguageCode
        let targetBundleIdentifier = self.targetBundleIdentifier
        let targetProcessID = self.targetProcessID
        debugLog("📝 Starting transcription. backend=\(backend.rawValue) file=\(wavURL.lastPathComponent)")
        activeTranscriptionCounts[backend, default: 0] += 1
        TranscriptionLoadingHUD.shared.show()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await waitForCurrentModelWarmup(backend: backend)
            TranscriptionManager.shared.transcribe(
                from: wavURL,
                language: language,
                backend: backend,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessID: targetProcessID,
                recordingStartedAt: startedAt,
                recordingStoppedAt: recordingStoppedAt
            ) { [weak self] isActive in
                guard let self else { return }
                if !isActive {
                    self.recorder.deleteTemporaryRecording(at: wavURL)
                    self.activeTranscriptionCounts[backend] = max(
                        0,
                        self.activeTranscriptionCounts[backend, default: 1] - 1
                    )
                    if self.activeTranscriptionCounts.values.allSatisfy({ $0 == 0 }) {
                        TranscriptionLoadingHUD.shared.hide()
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
