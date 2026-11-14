import Foundation

/// Keep individual inference requests bounded; the output allowance applies per chunk.
enum TranscriptionAudioPolicy {
    static let maximumChunkSeconds = 60.0
    static let maximumOutputTokens = 4096

    /// Prefer a quiet 100 ms boundary in the last five seconds. Every input sample is
    /// retained exactly once, including short final chunks. Short dictations are unchanged.
    static func chunkFrameCount(samples: [Float], sampleRate: Double, hasMoreAudio: Bool) -> Int {
        guard hasMoreAudio, sampleRate > 0 else { return samples.count }
        let window = max(1, Int(sampleRate * 0.1))
        let start = max(window, samples.count - Int(sampleRate * 5))
        guard start + window <= samples.count else { return samples.count }
        var bestEnd = samples.count
        var bestEnergy = Double.infinity
        for offset in stride(from: start, through: samples.count - window, by: window) {
            let energy = samples[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) }
            if energy < bestEnergy {
                bestEnergy = energy
                bestEnd = offset + window / 2
            }
        }
        return bestEnd
    }
}
