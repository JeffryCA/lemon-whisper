import AVFoundation
import Foundation

/// Owns the WAV writer and the bounded microphone buffer shared with the preview loop.
final class StreamingAudioCapture: @unchecked Sendable {
    static let previewSegmentSeconds = 24

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let sampleRate: Double
    private let windowFrames: Int
    private var output: AVAudioFile?
    private var samples: [Float] = []
    private var totalFrames = 0
    private var writeError: Error?

    init(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw CocoaError(.fileWriteUnknown)
        }

        sampleRate = format.sampleRate
        windowFrames = Int(format.sampleRate * Double(Self.previewSegmentSeconds + 8))
        output = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let output, writeError == nil, let channel = buffer.floatChannelData?[0] else { return }
            do {
                try output.write(from: buffer)
                let count = Int(buffer.frameLength)
                let overflow = max(0, samples.count + count - windowFrames)
                samples.removeFirst(min(overflow, samples.count))
                let retained = min(count, windowFrames)
                samples.append(contentsOf: UnsafeBufferPointer(start: channel + (count - retained), count: retained))
                totalFrames += count
            } catch {
                writeError = error
            }
        }
    }

    var frameCount: Int { lock.withLock { totalFrames } }

    func snapshot(from frame: Int, after lastUpdate: Int) throws
        -> (endFrame: Int, isCompleteSegment: Bool, buffer: AVAudioPCMBuffer)? {
        let snapshot = try lock.withLock { () -> (Int, Bool, [Float])? in
            if let writeError { throw writeError }
            let segmentEnd = frame + Int(sampleRate * Double(Self.previewSegmentSeconds))
            let end = min(segmentEnd, totalFrames)
            guard output != nil, end > lastUpdate,
                  end == segmentEnd || end - lastUpdate >= Int(sampleRate * 1.25) else { return nil }
            let offset = totalFrames - samples.count
            guard frame >= offset else { throw CocoaError(.fileReadUnknown) }
            return (end, end == segmentEnd, Array(samples[(frame - offset)..<(end - offset)]))
        }
        guard let snapshot else { return nil }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(snapshot.2.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        snapshot.2.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { channel.update(from: address, count: source.count) }
        }
        return (snapshot.0, snapshot.1, buffer)
    }

    func stop() -> Bool {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return lock.withLock {
            output = nil
            samples.removeAll()
            if let writeError { debugLog("Live capture did not finish cleanly: \(writeError.localizedDescription)") }
            return totalFrames > 0
        }
    }
}
