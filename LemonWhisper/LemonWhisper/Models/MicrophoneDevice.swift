import Foundation

/// A selectable audio input device, identified by its stable CoreAudio/AVCaptureDevice unique ID.
struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
}
