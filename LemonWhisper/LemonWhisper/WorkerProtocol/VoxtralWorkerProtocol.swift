import Foundation

/// The wire protocol spoken between LemonWhisper and its disposable Voxtral worker.
enum VoxtralWorkerProtocol {
    static let currentVersion = 1
}

/// Commands sent from LemonWhisper to the Voxtral worker over stdin.
enum VoxtralWorkerCommand: Codable, Equatable, Sendable {
    case prepare(VoxtralWorkerPrepareRequest)
    case transcribe(VoxtralWorkerTranscriptionRequest)
    case cancel(VoxtralWorkerCancellationRequest)
    case shutdown

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum MessageType: String, Codable { case prepare, transcribe, cancel, shutdown }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .prepare:
            self = .prepare(try container.decode(VoxtralWorkerPrepareRequest.self, forKey: .payload))
        case .transcribe:
            self = .transcribe(try container.decode(VoxtralWorkerTranscriptionRequest.self, forKey: .payload))
        case .cancel:
            self = .cancel(try container.decode(VoxtralWorkerCancellationRequest.self, forKey: .payload))
        case .shutdown:
            self = .shutdown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prepare(let request):
            try container.encode(MessageType.prepare, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .transcribe(let request):
            try container.encode(MessageType.transcribe, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .cancel(let request):
            try container.encode(MessageType.cancel, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .shutdown:
            try container.encode(MessageType.shutdown, forKey: .type)
        }
    }

    /// The request this command is correlated with, if it has one.
    var requestID: UUID? {
        switch self {
        case .prepare(let request): request.id
        case .transcribe(let request): request.id
        case .cancel(let request): request.id
        case .shutdown: nil
        }
    }
}

struct VoxtralWorkerPrepareRequest: Codable, Equatable, Sendable {
    let id: UUID
    let modelID: String

    init(id: UUID = UUID(), modelID: String) {
        self.id = id
        self.modelID = modelID
    }
}

struct VoxtralWorkerTranscriptionRequest: Codable, Equatable, Sendable {
    let id: UUID
    let audioPath: String
    let modelID: String
    let language: String?

    init(id: UUID = UUID(), audioPath: String, modelID: String, language: String?) {
        self.id = id
        self.audioPath = audioPath
        self.modelID = modelID
        self.language = language
    }
}

struct VoxtralWorkerCancellationRequest: Codable, Equatable, Sendable {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }
}

/// Events sent from the Voxtral worker to LemonWhisper over stdout.
enum VoxtralWorkerEvent: Codable, Equatable, Sendable {
    case hello(VoxtralWorkerHello)
    case prepared(VoxtralWorkerPrepared)
    case result(VoxtralWorkerResult)
    case cancelled(VoxtralWorkerCancelled)
    case failure(VoxtralWorkerFailure)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum MessageType: String, Codable { case hello, prepared, result, cancelled, failure }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .hello:
            self = .hello(try container.decode(VoxtralWorkerHello.self, forKey: .payload))
        case .prepared:
            self = .prepared(try container.decode(VoxtralWorkerPrepared.self, forKey: .payload))
        case .result:
            self = .result(try container.decode(VoxtralWorkerResult.self, forKey: .payload))
        case .cancelled:
            self = .cancelled(try container.decode(VoxtralWorkerCancelled.self, forKey: .payload))
        case .failure:
            self = .failure(try container.decode(VoxtralWorkerFailure.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(hello, forKey: .payload)
        case .prepared(let prepared):
            try container.encode(MessageType.prepared, forKey: .type)
            try container.encode(prepared, forKey: .payload)
        case .result(let result):
            try container.encode(MessageType.result, forKey: .type)
            try container.encode(result, forKey: .payload)
        case .cancelled(let cancelled):
            try container.encode(MessageType.cancelled, forKey: .type)
            try container.encode(cancelled, forKey: .payload)
        case .failure(let failure):
            try container.encode(MessageType.failure, forKey: .type)
            try container.encode(failure, forKey: .payload)
        }
    }

    /// The request this event is correlated with, if it has one.
    var requestID: UUID? {
        switch self {
        case .hello: nil
        case .prepared(let prepared): prepared.requestID
        case .result(let result): result.requestID
        case .cancelled(let cancelled): cancelled.requestID
        case .failure(let failure): failure.requestID
        }
    }
}

struct VoxtralWorkerHello: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let workerPID: Int32

    init(protocolVersion: Int = VoxtralWorkerProtocol.currentVersion, workerPID: Int32) {
        self.protocolVersion = protocolVersion
        self.workerPID = workerPID
    }
}

struct VoxtralWorkerPrepared: Codable, Equatable, Sendable {
    let requestID: UUID
    let modelID: String
}

struct VoxtralWorkerResult: Codable, Equatable, Sendable {
    let requestID: UUID
    let text: String
}

struct VoxtralWorkerCancelled: Codable, Equatable, Sendable {
    let requestID: UUID
}

struct VoxtralWorkerFailure: Codable, Equatable, Sendable {
    let requestID: UUID?
    let error: VoxtralWorkerError
}

struct VoxtralWorkerError: Codable, Error, Equatable, Sendable {
    enum Code: String, Codable, Equatable, Sendable {
        case incompatibleProtocol
        case invalidCommand
        case invalidRequest
        case modelLoadFailed
        case transcriptionFailed
        case cancelled
        case internalError
    }

    let code: Code
    let message: String
    let isRetryable: Bool
}
