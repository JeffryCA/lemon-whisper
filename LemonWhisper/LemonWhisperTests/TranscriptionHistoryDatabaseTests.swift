import Foundation
import Testing
@testable import LemonWhisper

struct TranscriptionHistoryDatabaseTests {

    @Test func savesAndLoadsRecentTranscriptions() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let database = try TranscriptionHistoryDatabase(
            databaseURL: tempDirectory.appendingPathComponent("Transcriptions.sqlite")
        )

        let first = try await database.insert(
            rawText: "first transcription",
            language: "en",
            backend: "whisper",
            targetBundleIdentifier: "com.apple.TextEdit"
        )

        let second = try await database.insert(
            rawText: "second transcription",
            language: "es",
            backend: "voxtral",
            targetBundleIdentifier: nil
        )

        let records = try await database.fetchLatest(limit: 10)

        #expect(records.count == 2)
        #expect(records[0].id == second.id)
        #expect(records[0].rawText == "second transcription")
        #expect(records[0].language == "es")
        #expect(records[1].id == first.id)
        #expect(records[1].targetBundleIdentifier == "com.apple.TextEdit")
    }

    @Test func deletesTranscriptions() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let database = try TranscriptionHistoryDatabase(
            databaseURL: tempDirectory.appendingPathComponent("Transcriptions.sqlite")
        )

        let record = try await database.insert(
            rawText: "delete me",
            language: "en",
            backend: "voxtral",
            targetBundleIdentifier: nil
        )

        try await database.delete(id: record.id)

        let records = try await database.fetchLatest(limit: 10)
        #expect(records.isEmpty)
    }
}
