import Foundation

enum VoxtralWorkerCoordinatorError: LocalizedError, Equatable {
    case helperNotFound(String)
    case launchFailed(String)
    case incompatibleProtocol(Int)
    case timedOut(String)
    case workerExited(Int32)
    case workerFailure(VoxtralWorkerError)
    case cancelled
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .helperNotFound(let path): return "Voxtral worker was not found at \(path)."
        case .launchFailed(let message): return "Could not launch the Voxtral worker: \(message)"
        case .incompatibleProtocol(let version): return "Voxtral worker uses unsupported protocol version \(version)."
        case .timedOut(let operation): return "Voxtral worker timed out while \(operation)."
        case .workerExited(let status): return "Voxtral worker exited unexpectedly (status \(status))."
        case .workerFailure(let error): return error.message
        case .cancelled: return "Voxtral transcription was cancelled."
        case .invalidResponse: return "Voxtral worker returned an unexpected response."
        }
    }
}

/// Synchronous termination is intentionally available for application shutdown, when there is no
/// opportunity to await an actor hop before macOS tears down the parent process.
final class VoxtralWorkerProcessRegistry: @unchecked Sendable {
    static let shared = VoxtralWorkerProcessRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func insert(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock()
    }

    func processIdentifiers() -> [pid_t] {
        lock.lock()
        let identifiers = processes.values.map(\.processIdentifier)
        lock.unlock()
        return identifiers
    }

    func terminateAll() {
        lock.lock()
        let running = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}

private actor VoxtralWorkerEventChannel {
    private var buffered: [VoxtralWorkerEvent] = []
    private var waiters: [UUID: CheckedContinuation<VoxtralWorkerEvent, Error>] = [:]
    private var terminalError: Error?

    func yield(_ event: VoxtralWorkerEvent) {
        if let first = waiters.first {
            waiters.removeValue(forKey: first.key)
            first.value.resume(returning: event)
        } else if terminalError == nil {
            buffered.append(event)
        }
    }

    func finish(throwing error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }

    func next() async throws -> VoxtralWorkerEvent {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let terminalError { throw terminalError }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if !buffered.isEmpty {
                    continuation.resume(returning: buffered.removeFirst())
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class VoxtralWorkerSession: @unchecked Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let diagnostics: FileHandle
    let events = VoxtralWorkerEventChannel()
    let modelID: String
    var parser = VoxtralJSONLineParser<VoxtralWorkerEvent>()
    var isPrepared = false

    init(process: Process, input: FileHandle, output: FileHandle, diagnostics: FileHandle, modelID: String) {
        self.process = process
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        self.modelID = modelID
    }
}

/// Owns the single Voxtral process. Actor isolation serializes preparation and inference while
/// still allowing cancellation to terminate a worker during an awaited response. Successful
/// transcriptions leave the prepared worker running so the app's model-memory policy can decide
/// whether to retain it (fast mode) or terminate it after the lazy idle timeout.
actor VoxtralWorkerCoordinator {
    private var session: VoxtralWorkerSession?
    private var operationInProgress = false
    private var cancellationGeneration = 0
    private let helperURLOverride: URL?
    private let handshakeTimeout: TimeInterval
    private let preparationTimeout: TimeInterval
    private let transcriptionTimeout: TimeInterval

    init(
        helperURL: URL? = nil,
        handshakeTimeout: TimeInterval = 10,
        preparationTimeout: TimeInterval = 180,
        transcriptionTimeout: TimeInterval = 300
    ) {
        self.helperURLOverride = helperURL
        self.handshakeTimeout = handshakeTimeout
        self.preparationTimeout = preparationTimeout
        self.transcriptionTimeout = transcriptionTimeout
    }

    var isPrepared: Bool { session?.isPrepared == true && session?.process.isRunning == true }

    func prepare(modelID: String) async throws {
        await acquireOperationSlot()
        defer { operationInProgress = false }
        let generation = cancellationGeneration
        try Task.checkCancellation()
        guard generation == cancellationGeneration else { throw VoxtralWorkerCoordinatorError.cancelled }
        if let session, session.modelID == modelID, session.isPrepared, session.process.isRunning { return }
        terminateCurrentWorker()
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                _ = try await launchAndPrepare(modelID: modelID)
                guard generation == cancellationGeneration else {
                    terminateCurrentWorker()
                    throw VoxtralWorkerCoordinatorError.cancelled
                }
                return
            } catch {
                lastError = error
                terminateCurrentWorker()
                if error is CancellationError || generation != cancellationGeneration {
                    throw VoxtralWorkerCoordinatorError.cancelled
                }
                guard attempt == 0, Self.shouldRetry(error) else { throw error }
                debugLog("⚠️ Voxtral worker preparation failed; retrying once: \(error.localizedDescription)")
            }
        }
        throw lastError ?? VoxtralWorkerCoordinatorError.invalidResponse
    }

    func transcribe(audioURL: URL, modelID: String, language: String?) async throws -> String {
        await acquireOperationSlot()
        defer { operationInProgress = false }
        let generation = cancellationGeneration
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                guard generation == cancellationGeneration else { throw VoxtralWorkerCoordinatorError.cancelled }
                let active: VoxtralWorkerSession
                if let session, session.modelID == modelID, session.isPrepared, session.process.isRunning {
                    active = session
                } else {
                    terminateCurrentWorker()
                    active = try await launchAndPrepare(modelID: modelID)
                }
                let request = VoxtralWorkerTranscriptionRequest(
                    audioPath: audioURL.path, modelID: modelID, language: language
                )
                try send(.transcribe(request), to: active)
                let event = try await waitForEvent(
                    from: active, requestID: request.id,
                    timeout: transcriptionTimeout, operation: "transcribing"
                )
                switch event {
                case .result(let result): return result.text
                case .cancelled: terminateCurrentWorker(); throw VoxtralWorkerCoordinatorError.cancelled
                case .failure(let failure): throw VoxtralWorkerCoordinatorError.workerFailure(failure.error)
                default: throw VoxtralWorkerCoordinatorError.invalidResponse
                }
            } catch {
                lastError = error
                terminateCurrentWorker()
                if error is CancellationError || generation != cancellationGeneration {
                    throw VoxtralWorkerCoordinatorError.cancelled
                }
                guard attempt == 0, Self.shouldRetry(error) else { throw error }
                debugLog("⚠️ Voxtral worker failed; retrying once: \(error.localizedDescription)")
            }
        }
        throw lastError ?? VoxtralWorkerCoordinatorError.invalidResponse
    }

    func cancel() {
        cancellationGeneration &+= 1
        terminateCurrentWorker()
    }

    func shutdown() {
        if let session, session.process.isRunning { try? send(.shutdown, to: session) }
        terminateCurrentWorker()
    }

    private func acquireOperationSlot() async {
        while operationInProgress { try? await Task.sleep(nanoseconds: 25_000_000) }
        operationInProgress = true
    }

    private func launchAndPrepare(modelID: String) async throws -> VoxtralWorkerSession {
        let active = try await launch(modelID: modelID)
        let request = VoxtralWorkerPrepareRequest(modelID: modelID)
        try send(.prepare(request), to: active)
        let event = try await waitForEvent(
            from: active, requestID: request.id,
            timeout: preparationTimeout, operation: "loading the model"
        )
        switch event {
        case .prepared(let prepared) where prepared.modelID == modelID:
            active.isPrepared = true
            return active
        case .failure(let failure):
            terminateCurrentWorker()
            throw VoxtralWorkerCoordinatorError.workerFailure(failure.error)
        default:
            terminateCurrentWorker()
            throw VoxtralWorkerCoordinatorError.invalidResponse
        }
    }

    private func launch(modelID: String) async throws -> VoxtralWorkerSession {
        let helperURL = try helperURLOverride ?? Self.helperURL()
        let process = Process()
        let stdinPipe = Pipe(); let stdoutPipe = Pipe(); let stderrPipe = Pipe()
        process.executableURL = helperURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let active = VoxtralWorkerSession(
            process: process, input: stdinPipe.fileHandleForWriting,
            output: stdoutPipe.fileHandleForReading,
            diagnostics: stderrPipe.fileHandleForReading, modelID: modelID
        )
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak active] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let active else { return }
            Task { await self.consumeOutput(data, from: active) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            for line in message.split(whereSeparator: \.isNewline) { debugLog("🧠 Voxtral worker: \(line)") }
        }
        process.terminationHandler = { [weak self, weak active] process in
            guard let self, let active else { return }
            Task { await self.workerTerminated(active, status: process.terminationStatus) }
        }
        do { try process.run() } catch {
            throw VoxtralWorkerCoordinatorError.launchFailed(error.localizedDescription)
        }
        VoxtralWorkerProcessRegistry.shared.insert(process)
        session = active
        do {
            let hello = try await waitForHello(from: active)
            guard hello.protocolVersion == VoxtralWorkerProtocol.currentVersion else {
                terminateCurrentWorker()
                throw VoxtralWorkerCoordinatorError.incompatibleProtocol(hello.protocolVersion)
            }
            debugLog("🧠 Voxtral worker ready (pid \(hello.workerPID))")
            return active
        } catch {
            terminateCurrentWorker(); throw error
        }
    }

    private func waitForHello(from session: VoxtralWorkerSession) async throws -> VoxtralWorkerHello {
        while true {
            let event = try await nextEvent(from: session, timeout: handshakeTimeout, operation: "starting")
            if case .hello(let hello) = event { return hello }
        }
    }

    private func waitForEvent(
        from session: VoxtralWorkerSession, requestID: UUID,
        timeout: TimeInterval, operation: String
    ) async throws -> VoxtralWorkerEvent {
        while true {
            let event = try await nextEvent(from: session, timeout: timeout, operation: operation)
            if event.requestID == requestID { return event }
        }
    }

    private func nextEvent(
        from session: VoxtralWorkerSession, timeout: TimeInterval, operation: String
    ) async throws -> VoxtralWorkerEvent {
        try await withThrowingTaskGroup(of: VoxtralWorkerEvent.self) { group in
            group.addTask { try await session.events.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw VoxtralWorkerCoordinatorError.timedOut(operation)
            }
            guard let event = try await group.next() else { throw VoxtralWorkerCoordinatorError.invalidResponse }
            group.cancelAll()
            return event
        }
    }

    private func send(_ command: VoxtralWorkerCommand, to session: VoxtralWorkerSession) throws {
        guard session.process.isRunning else {
            throw VoxtralWorkerCoordinatorError.workerExited(session.process.terminationStatus)
        }
        try session.input.write(contentsOf: VoxtralJSONLineEncoder<VoxtralWorkerCommand>().encode(command))
    }

    private func consumeOutput(_ data: Data, from active: VoxtralWorkerSession) async {
        guard session === active else { return }
        do {
            for event in try active.parser.append(data) { await active.events.yield(event) }
        } catch {
            await active.events.finish(throwing: error)
            terminateCurrentWorker()
        }
    }

    private func workerTerminated(_ active: VoxtralWorkerSession, status: Int32) {
        VoxtralWorkerProcessRegistry.shared.remove(active.process)
        active.output.readabilityHandler = nil
        active.diagnostics.readabilityHandler = nil
        Task { await active.events.finish(throwing: VoxtralWorkerCoordinatorError.workerExited(status)) }
        if session === active { session = nil }
    }

    private func terminateCurrentWorker() {
        guard let active = session else { return }
        session = nil
        active.output.readabilityHandler = nil
        active.diagnostics.readabilityHandler = nil
        try? active.input.close()
        if active.process.isRunning { active.process.terminate() }
        // `Process.terminationStatus` raises an Objective-C exception while the process is still
        // exiting. Wake pending waiters with the known cancellation reason and leave status
        // collection/registry cleanup to the termination handler, which runs after the exit.
        Task {
            await active.events.finish(throwing: VoxtralWorkerCoordinatorError.cancelled)
        }
    }

    private static func helperURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["LEMON_VOXTRAL_WORKER_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw VoxtralWorkerCoordinatorError.helperNotFound(url.path)
            }
            return url
        }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VoxtralWorker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VoxtralWorkerCoordinatorError.helperNotFound(url.path)
        }
        return url
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        guard let coordinatorError = error as? VoxtralWorkerCoordinatorError else { return false }
        switch coordinatorError {
        case .workerExited, .timedOut, .launchFailed: return true
        case .workerFailure(let failure): return failure.isRetryable
        default: return false
        }
    }
}
