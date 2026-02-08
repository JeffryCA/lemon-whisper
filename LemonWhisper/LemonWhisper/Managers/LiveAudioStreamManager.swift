import AVFoundation

class LiveAudioStreamManager: ObservableObject {
    static let shared = LiveAudioStreamManager()
    private let engine = AVAudioEngine()
    private let bufferQueue = DispatchQueue(label: "live.audio.buffer.queue")

    @Published var isRunning = false
    var onSegmentReady: ((AVAudioPCMBuffer) -> Void)?

    // VAD and segment parameters (mimic live.py behavior in simpler form)
    private let vadThreshold: Float = 0.01
    private let pauseThresholdSec: TimeInterval = 0.60
    private let minSegmentDurationSec: TimeInterval = 0.35
    private let maxSegmentDurationSec: Float = 10.0

    private var accumulatedBuffers: [AVAudioPCMBuffer] = []
    private var segmentStartTime: Date?
    private var lastSpeechDetectedAt: Date?
    private var isSpeechActive = false

    func start() {
        guard !isRunning else { return }

        accumulatedBuffers.removeAll()
        segmentStartTime = nil
        lastSpeechDetectedAt = nil
        isSpeechActive = false

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()

        do {
            try engine.start()
            isRunning = true
            print("🎤 Live audio engine started")
        } catch {
            print("❌ Failed to start engine: \(error)")
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if !accumulatedBuffers.isEmpty {
            flushBuffer()
        }
        isRunning = false
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = copyBuffer(buffer) else { return }
        guard let channelData = copiedBuffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        let bufferPointer = UnsafeBufferPointer(start: channelData, count: frameLength)
        let squares = bufferPointer.map { $0 * $0 }
        let sum = squares.reduce(0, +)
        let rms = sqrt(sum / Float(frameLength))

        let isSpeech = rms > vadThreshold
        let now = Date()

        if isSpeech {
            if segmentStartTime == nil {
                segmentStartTime = now
            }
            isSpeechActive = true
            lastSpeechDetectedAt = now
            accumulatedBuffers.append(copiedBuffer)

            if let start = segmentStartTime,
               now.timeIntervalSince(start) >= Double(maxSegmentDurationSec) {
                flushBuffer()
            }
            return
        }

        guard isSpeechActive,
              let start = segmentStartTime,
              let lastSpeechDetectedAt else { return }

        let speechDuration = lastSpeechDetectedAt.timeIntervalSince(start)
        let silenceDuration = now.timeIntervalSince(lastSpeechDetectedAt)
        if speechDuration >= minSegmentDurationSec && silenceDuration >= pauseThresholdSec {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !accumulatedBuffers.isEmpty else { return }

        // Snapshot and clear immediately to avoid overlap/duplication between segments.
        let buffers = accumulatedBuffers
        accumulatedBuffers.removeAll()
        segmentStartTime = nil
        lastSpeechDetectedAt = nil
        isSpeechActive = false

        bufferQueue.async {
            let format = buffers[0].format
            let totalFrameLength = buffers.reduce(0) { $0 + $1.frameLength }
            guard let resultBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrameLength) else { return }

            resultBuffer.frameLength = totalFrameLength
            var frameOffset: AVAudioFrameCount = 0
            for buf in buffers {
                let len = buf.frameLength
                for c in 0..<Int(format.channelCount) {
                    memcpy(resultBuffer.floatChannelData![c] + Int(frameOffset),
                           buf.floatChannelData![c],
                           Int(len) * MemoryLayout<Float>.size)
                }
                frameOffset += len
            }

            self.onSegmentReady?(resultBuffer)
        }
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let channels = Int(source.format.channelCount)
        let samples = Int(source.frameLength)
        for channel in 0..<channels {
            guard let src = source.floatChannelData?[channel],
                  let dst = copy.floatChannelData?[channel] else {
                continue
            }
            memcpy(dst, src, samples * MemoryLayout<Float>.size)
        }
        return copy
    }
}
