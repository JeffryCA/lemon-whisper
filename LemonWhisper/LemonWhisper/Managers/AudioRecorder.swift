import Foundation
import AVFoundation

/// Records microphone input straight to a 16‑kHz, 16‑bit, mono PCM WAV file.
/// Works on macOS without any AVAudioSession gymnastics.
class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    /// Latest ready‑to‑play WAV file.
    @Published var latestWavURL: URL?

    private var audioRecorder: AVAudioRecorder?
    private var isRecording = false

    /// Begin recording into `<tmp>/recording.wav`.
    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return false }

        // 16‑kHz, 16‑bit, mono, little‑endian PCM
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
        print("🎙 Recording WAV to:", url)

        MicrophoneManager.applySelectedInputDeviceIfNeeded(uniqueID: AppSettingsStore.selectedMicrophoneUniqueID)

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()

            guard audioRecorder?.record() == true else {
                print("❌ record() returned false")
                MicrophoneManager.restorePreviousInputDeviceIfNeeded()
                audioRecorder = nil
                return false
            }
            isRecording = true
            print("✅ Recording started")
            return true
        } catch {
            print("❌ Failed to start recording:", error)
            MicrophoneManager.restorePreviousInputDeviceIfNeeded()
            audioRecorder = nil
            return false
        }
    }

    /// Stop recording and publish the WAV URL.
    func stopRecording() {
        guard isRecording else {
            print("⚠️ Tried to stop but wasn’t recording")
            return
        }
        audioRecorder?.stop()
        isRecording = false
        MicrophoneManager.restorePreviousInputDeviceIfNeeded()
        print("🛑 Recording stopped")

        if let url = audioRecorder?.url,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            print("📁 WAV size: \(size) bytes")
            latestWavURL = url
        }
    }

    /// Stop recording and discard the temporary WAV file.
    func cancelRecording() {
        guard isRecording else {
            print("⚠️ Tried to cancel but wasn’t recording")
            return
        }

        let url = audioRecorder?.url
        audioRecorder?.stop()
        audioRecorder?.deleteRecording()
        audioRecorder = nil
        isRecording = false
        latestWavURL = nil
        MicrophoneManager.restorePreviousInputDeviceIfNeeded()

        if let url {
            try? FileManager.default.removeItem(at: url)
            print("🗑️ Recording cancelled:", url.lastPathComponent)
        }
    }

    // MARK: ‑‑ AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("❌ Encode error:", error)
        }
    }
}
