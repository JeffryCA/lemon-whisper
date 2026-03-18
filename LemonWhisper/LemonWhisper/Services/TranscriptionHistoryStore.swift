import Foundation
import AppKit
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TranscriptionRecord: Identifiable, Hashable {
    let id: UUID
    let rawText: String
    let correctedText: String?
    let createdAt: Date
    let backend: String
    let language: String
    let targetBundleIdentifier: String?

    var displayText: String {
        if let correctedText {
            let sanitized = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty {
                return sanitized
            }
        }
        return rawText
    }

    var timestampLabel: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var backendLabel: String {
        backend.capitalized
    }

    var languageLabel: String {
        language == "auto" ? "Auto" : language.uppercased()
    }

    var menuTitle: String {
        "\(timestampLabel)  \(excerpt(maxLength: 72))"
    }

    func excerpt(maxLength: Int) -> String {
        let normalized = displayText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > maxLength else {
            return normalized
        }

        return String(normalized.prefix(maxLength - 3)) + "..."
    }
}

enum TranscriptionHistoryError: LocalizedError {
    case couldNotOpenDatabase(String)
    case statementPreparationFailed(String)
    case statementExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenDatabase(let message):
            return "Could not open transcription history database: \(message)"
        case .statementPreparationFailed(let message):
            return "Could not prepare transcription history query: \(message)"
        case .statementExecutionFailed(let message):
            return "Could not update transcription history: \(message)"
        }
    }
}

actor TranscriptionHistoryDatabase {
    static let shared: TranscriptionHistoryDatabase = {
        do {
            return try TranscriptionHistoryDatabase()
        } catch {
            fatalError("Unable to initialize transcription history database: \(error.localizedDescription)")
        }
    }()

    private var connection: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = try Self.defaultDatabaseURL()
        }
        self.connection = try Self.openDatabase(at: self.databaseURL)
        try Self.migrateIfNeeded(on: self.connection)
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    func insert(
        rawText: String,
        correctedText: String? = nil,
        language: String,
        backend: String,
        targetBundleIdentifier: String?
    ) throws -> TranscriptionRecord {
        let record = TranscriptionRecord(
            id: UUID(),
            rawText: rawText,
            correctedText: correctedText,
            createdAt: Date(),
            backend: backend,
            language: language,
            targetBundleIdentifier: targetBundleIdentifier
        )

        let sql = """
        INSERT INTO transcriptions (
            id,
            raw_text,
            corrected_text,
            created_at,
            backend,
            language,
            target_bundle_identifier
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(record.id.uuidString, at: 1, in: statement)
        try bindText(record.rawText, at: 2, in: statement)
        try bindOptionalText(record.correctedText, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, record.createdAt.timeIntervalSince1970)
        try bindText(record.backend, at: 5, in: statement)
        try bindText(record.language, at: 6, in: statement)
        try bindOptionalText(record.targetBundleIdentifier, at: 7, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
        }

        return record
    }

    func fetchLatest(limit: Int = 100) throws -> [TranscriptionRecord] {
        let sql = """
        SELECT
            id,
            raw_text,
            corrected_text,
            created_at,
            backend,
            language,
            target_bundle_identifier
        FROM transcriptions
        ORDER BY created_at DESC
        LIMIT ?;
        """

        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var records: [TranscriptionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = stringColumn(at: 0, in: statement).flatMap(UUID.init(uuidString:)),
                let rawText = stringColumn(at: 1, in: statement),
                let backend = stringColumn(at: 4, in: statement),
                let language = stringColumn(at: 5, in: statement)
            else {
                continue
            }

            let correctedText = stringColumn(at: 2, in: statement)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let targetBundleIdentifier = stringColumn(at: 6, in: statement)

            records.append(
                TranscriptionRecord(
                    id: id,
                    rawText: rawText,
                    correctedText: correctedText,
                    createdAt: createdAt,
                    backend: backend,
                    language: language,
                    targetBundleIdentifier: targetBundleIdentifier
                )
            )
        }

        return records
    }

    func delete(id: UUID) throws {
        let statement = try prepareStatement("DELETE FROM transcriptions WHERE id = ?;")
        defer { sqlite3_finalize(statement) }

        try bindText(id.uuidString, at: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directoryURL = appSupportURL.appendingPathComponent("LemonWhisper", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("Transcriptions.sqlite")
    }

    private static func openDatabase(at databaseURL: URL) throws -> OpaquePointer? {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(connection)
            throw TranscriptionHistoryError.couldNotOpenDatabase(message)
        }

        return connection
    }

    private static func migrateIfNeeded(on connection: OpaquePointer?) throws {
        try execute(
            """
        PRAGMA journal_mode = WAL;
        """,
            on: connection
        )

        try execute(
            """
        CREATE TABLE IF NOT EXISTS transcriptions (
            id TEXT PRIMARY KEY NOT NULL,
            raw_text TEXT NOT NULL,
            corrected_text TEXT,
            created_at REAL NOT NULL,
            backend TEXT NOT NULL,
            language TEXT NOT NULL,
            target_bundle_identifier TEXT
        );
        """,
            on: connection
        )

        try execute(
            """
        CREATE INDEX IF NOT EXISTS idx_transcriptions_created_at
        ON transcriptions(created_at DESC);
        """,
            on: connection
        )
    }

    private static func execute(_ sql: String, on connection: OpaquePointer?) throws {
        guard let connection else {
            throw TranscriptionHistoryError.couldNotOpenDatabase("Missing SQLite connection")
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage(on: connection)
            sqlite3_free(errorMessage)
            throw TranscriptionHistoryError.statementExecutionFailed(message)
        }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        guard let connection else {
            throw TranscriptionHistoryError.couldNotOpenDatabase("Missing SQLite connection")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw TranscriptionHistoryError.statementPreparationFailed(lastErrorMessage())
        }

        return statement
    }

    private func bindText(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard result == SQLITE_OK else {
            throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
        }
    }

    private func bindOptionalText(_ value: String?, at index: Int32, in statement: OpaquePointer?) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
            }
            return
        }

        try bindText(value, at: index, in: statement)
    }

    private func stringColumn(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private static func lastErrorMessage(on connection: OpaquePointer?) -> String {
        guard let connection, let pointer = sqlite3_errmsg(connection) else {
            return "Unknown SQLite error"
        }
        return String(cString: pointer)
    }

    private func lastErrorMessage() -> String {
        Self.lastErrorMessage(on: connection)
    }
}

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    static let shared = TranscriptionHistoryStore()

    @Published private(set) var items: [TranscriptionRecord] = []
    @Published private(set) var lastError: String?

    private let database: TranscriptionHistoryDatabase
    private var hasLoaded = false

    init(database: TranscriptionHistoryDatabase = .shared) {
        self.database = database
    }

    func ensureLoaded() {
        guard !hasLoaded else { return }
        Task {
            await loadRecent()
        }
    }

    func loadRecent(limit: Int = 100) async {
        do {
            items = try await database.fetchLatest(limit: limit)
            lastError = nil
            hasLoaded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func record(
        rawText: String,
        language: String,
        backend: TranscriptionBackend,
        targetBundleIdentifier: String?
    ) async {
        let sanitized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        do {
            let record = try await database.insert(
                rawText: sanitized,
                language: language,
                backend: backend.rawValue,
                targetBundleIdentifier: targetBundleIdentifier
            )
            items.insert(record, at: 0)
            if items.count > 200 {
                items.removeSubrange(200...)
            }
            lastError = nil
            hasLoaded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copyToClipboard(_ record: TranscriptionRecord) {
        copyToClipboard(record.displayText)
    }

    func delete(_ record: TranscriptionRecord) {
        items.removeAll { $0.id == record.id }

        Task { @MainActor in
            do {
                try await database.delete(id: record.id)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                await loadRecent()
            }
        }
    }

    func copyToClipboard(_ text: String) {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sanitized, forType: .string)
    }
}
