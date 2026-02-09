import Foundation
import AVFoundation

extension FileManager {
    func writeBufferToWav(_ buffer: AVAudioPCMBuffer) throws -> URL {
        let fileName = UUID().uuidString + ".wav"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: buffer.format.settings)
        try audioFile.write(from: buffer)

        return fileURL
    }
}