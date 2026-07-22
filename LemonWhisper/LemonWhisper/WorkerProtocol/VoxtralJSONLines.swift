import Foundation

enum VoxtralJSONLineFramingError: Error, Equatable {
    case emptyFrame
    case frameTooLarge(maximumBytes: Int)
    case unterminatedFrame
}

/// Encodes one message per line for transport over a worker pipe.
struct VoxtralJSONLineEncoder<Message: Encodable> {
    private let encoder: JSONEncoder

    init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    func encode(_ message: Message) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }
}

/// Incrementally decodes newline-delimited JSON received in arbitrary pipe chunks.
struct VoxtralJSONLineParser<Message: Decodable> {
    private var buffer = Data()
    private let decoder: JSONDecoder
    private let maximumFrameBytes: Int

    init(decoder: JSONDecoder = JSONDecoder(), maximumFrameBytes: Int = 1_048_576) {
        precondition(maximumFrameBytes > 0)
        self.decoder = decoder
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func append(_ data: Data) throws -> [Message] {
        buffer.append(data)
        var messages: [Message] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frameLength = buffer.distance(from: buffer.startIndex, to: newlineIndex)
            guard frameLength <= maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: true)
                throw VoxtralJSONLineFramingError.frameTooLarge(maximumBytes: maximumFrameBytes)
            }

            var frame = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if frame.last == 0x0D { frame.removeLast() }

            guard !frame.isEmpty else {
                throw VoxtralJSONLineFramingError.emptyFrame
            }
            messages.append(try decoder.decode(Message.self, from: frame))
        }

        guard buffer.count <= maximumFrameBytes else {
            buffer.removeAll(keepingCapacity: true)
            throw VoxtralJSONLineFramingError.frameTooLarge(maximumBytes: maximumFrameBytes)
        }
        return messages
    }

    /// Verifies that the producer closed the stream on a frame boundary.
    mutating func finish() throws {
        guard buffer.isEmpty else {
            buffer.removeAll(keepingCapacity: true)
            throw VoxtralJSONLineFramingError.unterminatedFrame
        }
    }
}
