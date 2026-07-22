import Darwin
import XCTest
@testable import LemonWhisper

final class VoxtralWorkerCoordinatorTests: XCTestCase {
    func testPreparationCrashIsRetriedExactlyOnce() async throws {
        let counter = temporaryURL("launch-count")
        let script = try makeScript("""
        count=$(/bin/cat '\(counter.path)' 2>/dev/null || printf 0)
        /bin/echo $((count + 1)) > '\(counter.path)'
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":101}}'
        exit 9
        """)
        defer { remove([script, counter]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 1, transcriptionTimeout: 1
        )

        do {
            try await coordinator.prepare(modelID: "mini-3b-4bit")
            XCTFail("Expected worker crash")
        } catch {
            XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        }
    }

    func testPreparationTimeoutIsRetriedExactlyOnce() async throws {
        let counter = temporaryURL("timeout-count")
        let script = try makeScript("""
        count=$(/bin/cat '\(counter.path)' 2>/dev/null || printf 0)
        /bin/echo $((count + 1)) > '\(counter.path)'
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":102}}'
        IFS= read -r command
        /bin/sleep 5
        """)
        defer { remove([script, counter]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 0.1, transcriptionTimeout: 1
        )

        do {
            try await coordinator.prepare(modelID: "mini-3b-4bit")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        }
    }

    func testCancellationTerminatesWorkerDuringPreparation() async throws {
        let pidFile = temporaryURL("pid")
        let script = try makeScript("""
        /bin/echo $$ > '\(pidFile.path)'
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":103}}'
        IFS= read -r command
        /bin/sleep 5
        """)
        defer { remove([script, pidFile]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 5, transcriptionTimeout: 1
        )
        let preparation = Task { try await coordinator.prepare(modelID: "mini-3b-4bit") }
        let pid = try await waitForPID(in: pidFile)

        await coordinator.cancel()
        _ = try? await preparation.value
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    func testCancellationDoesNotReadTerminationStatusBeforeDelayedExit() async throws {
        let pidFile = temporaryURL("delayed-exit-pid")
        let counter = temporaryURL("delayed-exit-count")
        let script = try makeScript("""
        count=$(/bin/cat '\(counter.path)' 2>/dev/null || printf 0)
        /bin/echo $((count + 1)) > '\(counter.path)'
        /bin/echo $$ > '\(pidFile.path)'
        trap '/bin/sleep 0.5; exit 0' TERM
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":105}}'
        IFS= read -r command
        while :; do /bin/sleep 0.05; done
        """)
        defer { remove([script, pidFile, counter]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 5, transcriptionTimeout: 1
        )
        let preparation = Task { try await coordinator.prepare(modelID: "mini-3b-4bit") }
        let pid = try await waitForPID(in: pidFile)

        await coordinator.cancel()
        _ = try? await preparation.value

        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            try String(contentsOf: counter, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
        await coordinator.shutdown()
    }

    func testConcurrentPreparationUsesOnlyOneWorker() async throws {
        let counter = temporaryURL("single-count")
        let script = try makeScript(successScript(counter: counter, includeResult: false))
        defer { remove([script, counter]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 1, transcriptionTimeout: 1
        )

        async let first: Void = coordinator.prepare(modelID: "mini-3b-4bit")
        async let second: Void = coordinator.prepare(modelID: "mini-3b-4bit")
        _ = try await (first, second)

        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        await coordinator.shutdown()
    }

    func testSuccessfulWorkerIsReusedUntilShutdown() async throws {
        let counter = temporaryURL("result-count")
        let pidFile = temporaryURL("result-pid")
        let script = try makeScript(reusableSuccessScript(counter: counter, pidFile: pidFile))
        let audio = temporaryURL("audio.wav")
        try Data([0]).write(to: audio)
        defer { remove([script, counter, pidFile, audio]) }
        let coordinator = VoxtralWorkerCoordinator(
            helperURL: script, handshakeTimeout: 1, preparationTimeout: 1, transcriptionTimeout: 1
        )

        let first = try await coordinator.transcribe(
            audioURL: audio, modelID: "mini-3b-4bit", language: nil
        )
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(first, "hello from worker")
        XCTAssertEqual(kill(pid, 0), 0, "Worker should remain alive during the idle window")

        let second = try await coordinator.transcribe(
            audioURL: audio, modelID: "mini-3b-4bit", language: "en"
        )
        XCTAssertEqual(second, "hello from worker")
        XCTAssertEqual(
            try String(contentsOf: counter, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1",
            "Consecutive transcriptions should reuse the prepared worker"
        )

        await coordinator.shutdown()
        let didExit = await waitUntilProcessExits(pid)
        XCTAssertTrue(didExit)
    }

    private func reusableSuccessScript(counter: URL, pidFile: URL) -> String {
        """
        count=$(/bin/cat '\(counter.path)' 2>/dev/null || printf 0)
        /bin/echo $((count + 1)) > '\(counter.path)'
        /bin/echo $$ > '\(pidFile.path)'
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":106}}'
        IFS= read -r prepare
        prepare_id=$(printf '%s' "$prepare" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '%s\\n' "{\\"type\\":\\"prepared\\",\\"payload\\":{\\"requestID\\":\\"$prepare_id\\",\\"modelID\\":\\"mini-3b-4bit\\"}}"
        while IFS= read -r command; do
            case "$command" in
                *'"type":"transcribe"'*)
                    request_id=$(printf '%s' "$command" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
                    printf '%s\\n' "{\\"type\\":\\"result\\",\\"payload\\":{\\"requestID\\":\\"$request_id\\",\\"text\\":\\"hello from worker\\"}}"
                    ;;
                *'"type":"shutdown"'*) exit 0 ;;
            esac
        done
        """
    }

    private func successScript(counter: URL, pidFile: URL? = nil, includeResult: Bool) -> String {
        let pidLine = pidFile.map { "/bin/echo $$ > '\($0.path)'" } ?? ":"
        let resultLines = includeResult ? """
        IFS= read -r transcribe
        transcribe_id=$(printf '%s' "$transcribe" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"payload\\":{\\"requestID\\":\\"$transcribe_id\\",\\"text\\":\\"hello from worker\\"}}"
        """ : "IFS= read -r shutdown"
        return """
        count=$(/bin/cat '\(counter.path)' 2>/dev/null || printf 0)
        /bin/echo $((count + 1)) > '\(counter.path)'
        \(pidLine)
        printf '%s\\n' '{"type":"hello","payload":{"protocolVersion":1,"workerPID":104}}'
        IFS= read -r prepare
        prepare_id=$(printf '%s' "$prepare" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '%s\\n' "{\\"type\\":\\"prepared\\",\\"payload\\":{\\"requestID\\":\\"$prepare_id\\",\\"modelID\\":\\"mini-3b-4bit\\"}}"
        \(resultLines)
        """
    }

    private func makeScript(_ body: String) throws -> URL {
        let url = temporaryURL("worker.sh")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func temporaryURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lemon-worker-test-\(UUID().uuidString)-\(suffix)")
    }

    private func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func waitForPID(in url: URL) async throws -> Int32 {
        for _ in 0..<100 {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func waitUntilProcessExits(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
