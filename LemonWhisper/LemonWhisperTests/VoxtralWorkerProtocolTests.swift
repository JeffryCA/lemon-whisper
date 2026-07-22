import XCTest
@testable import LemonWhisper

final class VoxtralWorkerProtocolTests: XCTestCase {
    func testCommandRoundTripPreservesAudioPathAndLanguage() throws {
        let id = UUID()
        let command = VoxtralWorkerCommand.transcribe(VoxtralWorkerTranscriptionRequest(
            id: id,
            audioPath: "/tmp/recording one.wav",
            modelID: "mini-3b-4bit",
            language: nil
        ))
        var parser = VoxtralJSONLineParser<VoxtralWorkerCommand>()
        let messages = try parser.append(VoxtralJSONLineEncoder<VoxtralWorkerCommand>().encode(command))
        XCTAssertEqual(messages, [command])
        XCTAssertEqual(messages.first?.requestID, id)
        XCTAssertNoThrow(try parser.finish())
    }

    func testParserHandlesSplitAndMultipleFrames() throws {
        let hello = VoxtralWorkerEvent.hello(VoxtralWorkerHello(workerPID: 123))
        let requestID = UUID()
        let prepared = VoxtralWorkerEvent.prepared(VoxtralWorkerPrepared(
            requestID: requestID,
            modelID: "mini-3b-4bit"
        ))
        let encoder = VoxtralJSONLineEncoder<VoxtralWorkerEvent>()
        let bytes = try encoder.encode(hello) + encoder.encode(prepared)
        let split = bytes.count / 2
        var parser = VoxtralJSONLineParser<VoxtralWorkerEvent>()

        let first = try parser.append(bytes.prefix(split))
        let second = try parser.append(bytes.suffix(from: split))

        XCTAssertEqual(first + second, [hello, prepared])
        XCTAssertNoThrow(try parser.finish())
    }

    func testParserRejectsUnterminatedFrame() throws {
        let command = VoxtralWorkerCommand.shutdown
        var bytes = try VoxtralJSONLineEncoder<VoxtralWorkerCommand>().encode(command)
        bytes.removeLast()
        var parser = VoxtralJSONLineParser<VoxtralWorkerCommand>()
        XCTAssertTrue(try parser.append(bytes).isEmpty)
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? VoxtralJSONLineFramingError, .unterminatedFrame)
        }
    }

    func testFailureRoundTripCarriesRetryPolicy() throws {
        let failure = VoxtralWorkerEvent.failure(VoxtralWorkerFailure(
            requestID: UUID(),
            error: VoxtralWorkerError(
                code: .transcriptionFailed,
                message: "worker crashed",
                isRetryable: true
            )
        ))
        var parser = VoxtralJSONLineParser<VoxtralWorkerEvent>()
        XCTAssertEqual(
            try parser.append(VoxtralJSONLineEncoder<VoxtralWorkerEvent>().encode(failure)),
            [failure]
        )
    }
}
