import XCTest
@testable import LemonWhisper

final class TranscriptionAudioPolicyTests: XCTestCase {
    func testShortAndFinalChunksAreKeptWhole() {
        for count in [0, 1, 350, 59_999] {
            let samples = Array(repeating: Float(0.2), count: count)
            XCTAssertEqual(TranscriptionAudioPolicy.chunkFrameCount(
                samples: samples, sampleRate: 1000, hasMoreAudio: false
            ), count)
        }
    }

    func testQuietBoundaryIsPreferredWithoutLosingOrRepeatingSamples() {
        let rate = 1000.0
        var samples = Array(repeating: Float(0.2), count: 133_350)
        for start in [57_000, 114_000] {
            samples.replaceSubrange(start..<(start + 200), with: repeatElement(Float(0), count: 200))
        }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            let end = min(start + Int(rate * TranscriptionAudioPolicy.maximumChunkSeconds), samples.count)
            let count = TranscriptionAudioPolicy.chunkFrameCount(
                samples: Array(samples[start..<end]), sampleRate: rate, hasMoreAudio: end < samples.count
            )
            XCTAssertGreaterThan(count, 0)
            ranges.append(start..<(start + count))
            start += count
        }
        XCTAssertTrue((57_000..<57_200).contains(ranges[0].upperBound))
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        XCTAssertEqual(ranges.flatMap { Array($0) }, Array(samples.indices))
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 60_000 })
        XCTAssertGreaterThan(TranscriptionAudioPolicy.maximumOutputTokens, 500)
    }

    func testAllSpeechStillMakesBoundedForwardProgress() {
        let count = TranscriptionAudioPolicy.chunkFrameCount(
            samples: Array(repeating: 1, count: 960_000), sampleRate: 16_000, hasMoreAudio: true
        )
        XCTAssertGreaterThanOrEqual(count, 55 * 16_000)
        XCTAssertLessThanOrEqual(count, 60 * 16_000)
    }
}
