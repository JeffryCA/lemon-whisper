import Foundation
import AVFoundation

/// Records microphone input straight to a 16‑kHz, 16‑bit, mono PCM WAV file.
/// Works on macOS without any AVAudioSession gymnastics.
class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    private static let temporaryRecordingPrefix = "recording-"
    private static let staleRecordingAge: TimeInterval = 24 * 60 * 60

    /// Latest ready‑to‑play WAV file.
    @Published var latestWavURL: URL?

    private var audioRecorder: AVAudioRecorder?
    private var isRecording = false

    override init() {
        super.init()
        Self.removeStaleTemporaryRecordings()
    }

    /// Begin recording into a unique temporary WAV so a later recording cannot overwrite audio
    /// that is still being transcribed.
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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.temporaryRecordingPrefix)\(UUID().uuidString).wav")
        print("🎙 Recording WAV to:", url)
        latestWavURL = nil

        MicrophoneManager.applySelectedInputDeviceIfNeeded(uniqueID: AppSettingsStore.selectedMicrophoneUniqueID)

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()

            guard audioRecorder?.record() == true else {
                print("❌ record() returned false")
                MicrophoneManager.restorePreviousInputDeviceIfNeeded()
                audioRecorder = nil
                try? FileManager.default.removeItem(at: url)
                return false
            }
            isRecording = true
            print("✅ Recording started")
            return true
        } catch {
            print("❌ Failed to start recording:", error)
            MicrophoneManager.restorePreviousInputDeviceIfNeeded()
            audioRecorder = nil
            try? FileManager.default.removeItem(at: url)
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

    /// Removes exactly the completed recording handed to a transcription task.
    func deleteTemporaryRecording(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            if latestWavURL == url { latestWavURL = nil }
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            if latestWavURL == url { latestWavURL = nil }
        } catch {
            debugLog("⚠️ Could not remove temporary recording \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func removeStaleTemporaryRecordings() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleRecordingAge)
        for url in urls where url.lastPathComponent.hasPrefix(temporaryRecordingPrefix) && url.pathExtension == "wav" {
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modifiedAt.map({ $0 < cutoff }) ?? true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: ‑‑ AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("❌ Encode error:", error)
        }
    }
}
