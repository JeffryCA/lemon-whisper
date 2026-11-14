import AVFoundation
import Foundation

extension FileManager {
    func writeBufferToWav(_ buffer: AVAudioPCMBuffer) throws -> URL {
        let fileName = UUID().uuidString + ".wav"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)

        do {
            let audioFile = try AVAudioFile(forWriting: fileURL, settings: buffer.format.settings)
            try audioFile.write(from: buffer)
        } catch {
            try? removeItem(at: fileURL)
            throw error
        }

        return fileURL
    }

    func copyWavTail(_ url: URL, from frame: Int) throws -> URL? {
        let input = try AVAudioFile(forReading: url)
        guard frame < input.length else { return nil }
        input.framePosition = AVAudioFramePosition(frame)
        let tail = temporaryDirectory.appendingPathComponent("recording-tail-\(UUID()).wav")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadUnknown)
        }
        do {
            let output = try AVAudioFile(forWriting: tail, settings: input.fileFormat.settings)
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            return tail
        } catch {
            try? removeItem(at: tail)
            throw error
        }
    }
}
