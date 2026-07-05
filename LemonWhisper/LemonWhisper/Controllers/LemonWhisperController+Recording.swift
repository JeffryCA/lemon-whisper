import AppKit
import AVFoundation

extension LemonWhisperController {
    func toggleRecording() {
        debugLog("🎙️ toggleRecording invoked. isRecording=\(isRecording) canStartNewRecording=\(canStartNewRecording)")

        if isRecording {
            let stoppedAt = Date()
            debugLog("🛑 Stopping recording")
            recorder.stopRecording()
            RecordingPulseHUD.shared.showPulse(isRecording: false)
            transcribeLatestRecording(recordingStoppedAt: stoppedAt)
            isRecording = false
            return
        }

        guard canStartNewRecording else {
            debugLog("⛔️ toggleRecording ignored because setupState is not ready")
            return
        }

        recordingStartedAt = Date()
        startRecordingIfAuthorized()
    }

    /// Fallback recording length used to budget eager materialization before we've measured a
    /// real recording (e.g. the first lazy-mode recording after launch).
    static let assumedTypicalRecordingDuration: TimeInterval = 3

    /// Called the moment recording begins. Keeps the model out of an idle unload and, in lazy
    /// mode, starts loading it in parallel so it is ready by the time recording stops.
    private func onRecordingDidStart() {
        cancelIdleUnloadTimer()
        if modelLoadingMode == .lazy {
            // Load the pipeline in parallel with recording. The backend materializes weights now
            // only if a prior measurement shows that pass fits within a typical recording;
            // otherwise it defers to the transcription so it can never block it.
            let budget = lastRecordingDuration ?? Self.assumedTypicalRecordingDuration
            warmUpCurrentBackendInBackground(weightMaterializationBudget: budget)
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        debugLog("🗑️ Cancelling recording")
        recorder.cancelRecording()
        RecordingPulseHUD.shared.showPulse(isRecording: false)
        isRecording = false
        recordingStartedAt = nil
        // No transcription will fire to re-arm it, so restart the idle countdown here —
        // otherwise a model loaded by this recording's parallel warmup never unloads.
        scheduleIdleUnloadIfNeeded()
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
            // Show the indicator before the recorder's device setup (which can take a few ms,
            // e.g. switching input device) so the hotkey feels instant. Hide it if start fails.
            RecordingPulseHUD.shared.showPulse(isRecording: true)
            guard recorder.startRecording() else {
                RecordingPulseHUD.shared.showPulse(isRecording: false)
                debugLog("❌ Recording failed to start")
                return
            }
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
                        RecordingPulseHUD.shared.showPulse(isRecording: true)
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

    private func transcribeLatestRecording(recordingStoppedAt: Date) {
        guard let wavURL = recorder.latestWavURL else {
            debugLog("⚠️ No latest recording URL available for transcription")
            return
        }

        let startedAt = recordingStartedAt
        recordingStartedAt = nil

        if let startedAt {
            lastRecordingDuration = recordingStoppedAt.timeIntervalSince(startedAt)
        }

        debugLog("📝 Starting transcription. backend=\(selectedBackend.rawValue) file=\(wavURL.lastPathComponent)")
        TranscriptionManager.shared.transcribe(
            from: wavURL,
            language: selectedLanguageCode,
            backend: selectedBackend,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessID: targetProcessID,
            recordingStartedAt: startedAt,
            recordingStoppedAt: recordingStoppedAt
        ) { [weak self] isActive in
            if isActive {
                TranscriptionLoadingHUD.shared.show()
                self?.cancelIdleUnloadTimer()
            } else {
                TranscriptionLoadingHUD.shared.hide()
                self?.scheduleIdleUnloadIfNeeded()
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
