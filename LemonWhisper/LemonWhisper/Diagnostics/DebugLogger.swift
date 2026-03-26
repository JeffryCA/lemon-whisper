import Foundation

private enum DebugLogger {
    static let queue = DispatchQueue(label: "com.jca.LemonWhisper.debugLog")
    static let logFileName = "debug.log"
    static let rotatedLogFileName = "debug.previous.log"
    static let maxLogSizeBytes = 512 * 1024

    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func lemonWhisperLogDirectoryURL() -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }

    let directory = appSupport.appendingPathComponent("LemonWhisper", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    } catch {
        print("Failed to create log directory: \(error.localizedDescription)")
        return nil
    }
}

func lemonWhisperLogFileURL() -> URL? {
    lemonWhisperLogDirectoryURL()?.appendingPathComponent(DebugLogger.logFileName)
}

private func lemonWhisperRotatedLogFileURL() -> URL? {
    lemonWhisperLogDirectoryURL()?.appendingPathComponent(DebugLogger.rotatedLogFileName)
}

private func rotateDebugLogIfNeeded(at url: URL) {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber,
        size.intValue >= DebugLogger.maxLogSizeBytes
    else {
        return
    }

    guard let rotatedURL = lemonWhisperRotatedLogFileURL() else { return }

    do {
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            try FileManager.default.removeItem(at: rotatedURL)
        }
        try FileManager.default.moveItem(at: url, to: rotatedURL)
    } catch {
        print("Failed to rotate debug log: \(error.localizedDescription)")
    }
}

private func appendLogData(_ data: Data, to url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("Failed to append to debug log: \(error.localizedDescription)")
        }
    } else {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to create debug log: \(error.localizedDescription)")
        }
    }
}

func debugLog(_ message: String) {
    print(message)
    let line = "[\(DebugLogger.formatter.string(from: Date()))] \(message)\n"

    DebugLogger.queue.sync {
        guard let url = lemonWhisperLogFileURL() else { return }
        rotateDebugLogIfNeeded(at: url)
        guard let data = line.data(using: .utf8) else { return }
        appendLogData(data, to: url)
    }
}
