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
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let pasteStatus: String
    let pastePath: String?
    let pasteError: String?
    let pasteCompletedAt: Date?

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
        targetBundleIdentifier: String?,
        recordingStartedAt: Date? = nil,
        recordingStoppedAt: Date? = nil
    ) throws -> TranscriptionRecord {
        let record = TranscriptionRecord(
            id: UUID(),
            rawText: rawText,
            correctedText: correctedText,
            createdAt: Date(),
            backend: backend,
            language: language,
            targetBundleIdentifier: targetBundleIdentifier,
            recordingStartedAt: recordingStartedAt,
            recordingStoppedAt: recordingStoppedAt,
            pasteStatus: "pending",
            pastePath: nil,
            pasteError: nil,
            pasteCompletedAt: nil
        )

        let sql = """
        INSERT INTO transcriptions (
            id,
            raw_text,
            corrected_text,
            created_at,
            backend,
            language,
            target_bundle_identifier,
            recording_started_at,
            recording_stopped_at,
            paste_status,
            paste_path,
            paste_error,
            paste_completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        bindOptionalDate(record.recordingStartedAt, at: 8, in: statement)
        bindOptionalDate(record.recordingStoppedAt, at: 9, in: statement)
        try bindText(record.pasteStatus, at: 10, in: statement)
        try bindOptionalText(record.pastePath, at: 11, in: statement)
        try bindOptionalText(record.pasteError, at: 12, in: statement)
        sqlite3_bind_null(statement, 13)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
        }

        return record
    }

    func fetchLatest(limit: Int, offset: Int = 0) throws -> [TranscriptionRecord] {
        let sql = """
        SELECT
            id,
            raw_text,
            corrected_text,
            created_at,
            backend,
            language,
            target_bundle_identifier,
            recording_started_at,
            recording_stopped_at,
            paste_status,
            paste_path,
            paste_error,
            paste_completed_at
        FROM transcriptions
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?;
        """

        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))
        sqlite3_bind_int(statement, 2, Int32(offset))

        return readRecords(from: statement)
    }

    func fetchAll() throws -> [TranscriptionRecord] {
        let sql = """
        SELECT
            id,
            raw_text,
            corrected_text,
            created_at,
            backend,
            language,
            target_bundle_identifier,
            recording_started_at,
            recording_stopped_at,
            paste_status,
            paste_path,
            paste_error,
            paste_completed_at
        FROM transcriptions
        ORDER BY created_at DESC;
        """

        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        return readRecords(from: statement)
    }

    private func readRecords(from statement: OpaquePointer?) -> [TranscriptionRecord] {
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
            let recordingStartedAt = dateColumn(at: 7, in: statement)
            let recordingStoppedAt = dateColumn(at: 8, in: statement)
            let pasteStatus = stringColumn(at: 9, in: statement) ?? "unknown"
            let pastePath = stringColumn(at: 10, in: statement)
            let pasteError = stringColumn(at: 11, in: statement)
            let pasteCompletedAt = dateColumn(at: 12, in: statement)

            records.append(
                TranscriptionRecord(
                    id: id,
                    rawText: rawText,
                    correctedText: correctedText,
                    createdAt: createdAt,
                    backend: backend,
                    language: language,
                    targetBundleIdentifier: targetBundleIdentifier,
                    recordingStartedAt: recordingStartedAt,
                    recordingStoppedAt: recordingStoppedAt,
                    pasteStatus: pasteStatus,
                    pastePath: pastePath,
                    pasteError: pasteError,
                    pasteCompletedAt: pasteCompletedAt
                )
            )
        }

        return records
    }

    func updatePasteMetadata(
        id: UUID,
        pasteStatus: String,
        pastePath: String?,
        pasteError: String?,
        pasteCompletedAt: Date
    ) throws {
        let sql = """
        UPDATE transcriptions
        SET paste_status = ?, paste_path = ?, paste_error = ?, paste_completed_at = ?
        WHERE id = ?;
        """

        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(pasteStatus, at: 1, in: statement)
        try bindOptionalText(pastePath, at: 2, in: statement)
        try bindOptionalText(pasteError, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, pasteCompletedAt.timeIntervalSince1970)
        try bindText(id.uuidString, at: 5, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TranscriptionHistoryError.statementExecutionFailed(lastErrorMessage())
        }
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
            target_bundle_identifier TEXT,
            recording_started_at REAL,
            recording_stopped_at REAL,
            paste_status TEXT NOT NULL DEFAULT 'unknown',
            paste_path TEXT,
            paste_error TEXT,
            paste_completed_at REAL
        );
        """,
            on: connection
        )

        try addColumnIfNeeded(
            named: "recording_started_at",
            definition: "REAL",
            to: "transcriptions",
            on: connection
        )
        try addColumnIfNeeded(
            named: "recording_stopped_at",
            definition: "REAL",
            to: "transcriptions",
            on: connection
        )

        try addColumnIfNeeded(
            named: "paste_status",
            definition: "TEXT NOT NULL DEFAULT 'unknown'",
            to: "transcriptions",
            on: connection
        )
        try addColumnIfNeeded(
            named: "paste_path",
            definition: "TEXT",
            to: "transcriptions",
            on: connection
        )
        try addColumnIfNeeded(
            named: "paste_error",
            definition: "TEXT",
            to: "transcriptions",
            on: connection
        )
        try addColumnIfNeeded(
            named: "paste_completed_at",
            definition: "REAL",
            to: "transcriptions",
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

    private static func addColumnIfNeeded(
        named columnName: String,
        definition: String,
        to tableName: String,
        on connection: OpaquePointer?
    ) throws {
        guard !(try table(tableName, hasColumnNamed: columnName, on: connection)) else {
            return
        }

        try execute(
            "ALTER TABLE \(tableName) ADD COLUMN \(columnName) \(definition);",
            on: connection
        )
    }

    private static func table(
        _ tableName: String,
        hasColumnNamed columnName: String,
        on connection: OpaquePointer?
    ) throws -> Bool {
        guard let connection else {
            throw TranscriptionHistoryError.couldNotOpenDatabase("Missing SQLite connection")
        }

        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(tableName));"
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw TranscriptionHistoryError.statementPreparationFailed(lastErrorMessage(on: connection))
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }
            if String(cString: namePointer) == columnName {
                return true
            }
        }

        return false
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

    private func bindOptionalDate(_ value: Date?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func stringColumn(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func dateColumn(at index: Int32, in statement: OpaquePointer?) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
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
    private static let pageSize = 100

    @Published private(set) var items: [TranscriptionRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var hasMoreItems = false
    @Published private(set) var isLoadingInitialPage = false
    @Published private(set) var isLoadingMorePages = false

    private let database: TranscriptionHistoryDatabase
    private var hasLoaded = false

    init(database: TranscriptionHistoryDatabase = .shared) {
        self.database = database
    }

    func ensureLoaded() {
        guard !hasLoaded else { return }
        Task {
            await loadInitialPage()
        }
    }

    func loadInitialPage() async {
        guard !isLoadingInitialPage else { return }
        isLoadingInitialPage = true
        defer { isLoadingInitialPage = false }

        await loadPage(reset: true)
    }

    func loadMoreIfNeeded(currentItem: TranscriptionRecord? = nil) async {
        guard hasLoaded, hasMoreItems, !isLoadingInitialPage, !isLoadingMorePages else { return }
        if let currentItem, currentItem.id != items.last?.id {
            return
        }

        isLoadingMorePages = true
        defer { isLoadingMorePages = false }

        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        do {
            let offset = reset ? 0 : items.count
            let batch = try await database.fetchLatest(limit: Self.pageSize + 1, offset: offset)
            let page = Array(batch.prefix(Self.pageSize))

            if reset {
                items = page
            } else {
                items.append(contentsOf: page)
            }

            hasMoreItems = batch.count > Self.pageSize
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
        targetBundleIdentifier: String?,
        recordingStartedAt: Date? = nil,
        recordingStoppedAt: Date? = nil
    ) async -> TranscriptionRecord? {
        let sanitized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }

        do {
            let record = try await database.insert(
                rawText: sanitized,
                language: language,
                backend: backend.rawValue,
                targetBundleIdentifier: targetBundleIdentifier,
                recordingStartedAt: recordingStartedAt,
                recordingStoppedAt: recordingStoppedAt
            )
            items.insert(record, at: 0)
            lastError = nil
            hasLoaded = true
            return record
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updatePasteMetadata(
        id: UUID,
        pasteStatus: String,
        pastePath: String?,
        pasteError: String?,
        pasteCompletedAt: Date = Date()
    ) async {
        do {
            try await database.updatePasteMetadata(
                id: id,
                pasteStatus: pasteStatus,
                pastePath: pastePath,
                pasteError: pasteError,
                pasteCompletedAt: pasteCompletedAt
            )
            if let index = items.firstIndex(where: { $0.id == id }) {
                let existing = items[index]
                items[index] = TranscriptionRecord(
                    id: existing.id,
                    rawText: existing.rawText,
                    correctedText: existing.correctedText,
                    createdAt: existing.createdAt,
                    backend: existing.backend,
                    language: existing.language,
                    targetBundleIdentifier: existing.targetBundleIdentifier,
                    recordingStartedAt: existing.recordingStartedAt,
                    recordingStoppedAt: existing.recordingStoppedAt,
                    pasteStatus: pasteStatus,
                    pastePath: pastePath,
                    pasteError: pasteError,
                    pasteCompletedAt: pasteCompletedAt
                )
            }
            lastError = nil
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
                await loadInitialPage()
            }
        }
    }

    func exportAllCSV() async throws -> Data {
        let records = try await database.fetchAll()
        return Data(exportCSV(records).utf8)
    }

    func copyToClipboard(_ text: String) {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sanitized, forType: .string)
    }

    var menuHistoryFooterText: String? {
        if hasMoreItems {
            return "More in History"
        }

        let extraLoadedItems = items.count - min(items.count, 10)
        guard extraLoadedItems > 0 else { return nil }
        return "\(extraLoadedItems) more in History"
    }

    private func exportCSV(_ records: [TranscriptionRecord]) -> String {
        let header = [
            "id",
            "created_at",
            "text",
            "raw_text",
            "corrected_text",
            "backend",
            "language",
            "target_bundle_identifier",
            "recording_started_at",
            "recording_stopped_at",
            "paste_status",
            "paste_path",
            "paste_error",
            "paste_completed_at"
        ]

        let rows = records.map { record in
            [
                record.id.uuidString,
                Self.exportDateFormatter.string(from: record.createdAt),
                record.displayText,
                record.rawText,
                record.correctedText ?? "",
                record.backend,
                record.language,
                record.targetBundleIdentifier ?? "",
                record.recordingStartedAt.map { Self.exportDateFormatter.string(from: $0) } ?? "",
                record.recordingStoppedAt.map { Self.exportDateFormatter.string(from: $0) } ?? "",
                record.pasteStatus,
                record.pastePath ?? "",
                record.pasteError ?? "",
                record.pasteCompletedAt.map { Self.exportDateFormatter.string(from: $0) } ?? ""
            ]
            .map(Self.escapeCSVField)
            .joined(separator: ",")
        }

        return ([header.joined(separator: ",")] + rows).joined(separator: "\n")
    }

    private static func escapeCSVField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    fileprivate static let exportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
