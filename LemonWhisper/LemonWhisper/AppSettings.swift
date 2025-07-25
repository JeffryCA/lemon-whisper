
import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    @Published var transcriptionMode: TranscriptionMode = .base
    @Published var language: String = "auto"
}

enum TranscriptionMode: String, CaseIterable {
    case base = "Base Transcription"
    case live = "Live Transcription"
}
