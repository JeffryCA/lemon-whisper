import AppKit
import AVFoundation

extension LemonWhisperController {
    func toggleRecording() {
        debugLog("🎙️ toggleRecording invoked. isRecording=\(isRecording) canStartNewRecording=\(canStartNewRecording)")

        if isRecording {
            debugLog("🛑 Stopping recording")
            recorder.stopRecording()
            RecordingPulseHUD.shared.showPulse(isRecording: false)
            transcribeLatestRecording()
            isRecording = false
            return
        }

        guard canStartNewRecording else {
            debugLog("⛔️ toggleRecording ignored because setupState is not ready")
            return
        }

        startRecordingIfAuthorized()
    }

    func cancelRecording() {
        guard isRecording else { return }

        debugLog("🗑️ Cancelling recording")
        recorder.cancelRecording()
        RecordingPulseHUD.shared.showPulse(isRecording: false)
        isRecording = false
    }

    var canStartNewRecording: Bool {
        if case .ready = setupState {
            return true
        }
        return false
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
            RecordingPulseHUD.shared.showPulse(isRecording: true)
            isRecording = true
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

    private func transcribeLatestRecording() {
        guard let wavURL = recorder.latestWavURL else {
            debugLog("⚠️ No latest recording URL available for transcription")
            return
        }

        debugLog("📝 Starting transcription. backend=\(selectedBackend.rawValue) file=\(wavURL.lastPathComponent)")
        TranscriptionManager.shared.transcribe(
            from: wavURL,
            language: selectedLanguageCode,
            backend: selectedBackend,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessID: targetProcessID
        ) { isActive in
            if isActive {
                TranscriptionLoadingHUD.shared.show()
            } else {
                TranscriptionLoadingHUD.shared.hide()
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
