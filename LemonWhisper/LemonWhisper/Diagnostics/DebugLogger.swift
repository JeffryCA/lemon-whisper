import Foundation

func lemonWhisperLogFileURL() -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }

    let directory = appSupport.appendingPathComponent("LemonWhisper", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug.log")
    } catch {
        print("Failed to create log directory: \(error.localizedDescription)")
        return nil
    }
}

func debugLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "[\(formatter.string(from: Date()))] \(message)\n"

    print(message)

    guard let url = lemonWhisperLogFileURL() else { return }

    guard let data = line.data(using: .utf8) else { return }

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
