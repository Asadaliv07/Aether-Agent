import Foundation
import SQLite3

/// Typed error representation for SQLite persistence operations.
public enum DatabaseError: LocalizedError, Equatable {
    case connectionFailed(String)
    case executionFailed(code: Int32, message: String)
    case migrationFailed(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg):
            return "Database connection failed: \(msg)"
        case .executionFailed(let code, let msg):
            return "SQLite error (\(code)): \(msg)"
        case .migrationFailed(let msg):
            return "Database migration failed: \(msg)"
        case .notFound:
            return "Requested database record was not found."
        }
    }
}

private final class SQLiteHandleBox: @unchecked Sendable {
    var handle: OpaquePointer?

    init(_ handle: OpaquePointer?) {
        self.handle = handle
    }

    func close() {
        if let h = handle {
            sqlite3_close_v2(h)
            handle = nil
        }
    }

    deinit {
        if let h = handle {
            sqlite3_close_v2(h)
        }
    }
}

/// Actor-isolated, thread-safe SQLite database managing conversations and messages.
///
/// Features WAL journal mode, explicit migrations, parameterized SQL queries,
/// cascading foreign-key deletions, and interrupted generation recovery.
public actor ConversationDatabase {
    private let handleBox: SQLiteHandleBox
    public let databaseURL: URL?

    private var db: OpaquePointer? {
        handleBox.handle
    }

    /// Resolves the default sandbox Application Support SQLite database path.
    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let aetherDir = appSupport.appendingPathComponent("Aether", isDirectory: true)
        return aetherDir.appendingPathComponent("aether.sqlite")
    }

    /// Initializes and opens the database at the specified URL (or default sandbox location).
    /// Pass `nil` for in-memory database (`":memory:"`), useful for testing.
    public init(fileURL: URL? = nil, inMemory: Bool = false) throws {
        let handle: OpaquePointer
        if inMemory {
            self.databaseURL = nil
            handle = try Self.openDatabase(at: ":memory:")
        } else {
            let targetURL = fileURL ?? Self.defaultDatabaseURL()
            self.databaseURL = targetURL
            let dirURL = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            handle = try Self.openDatabase(at: targetURL.path)
        }
        self.handleBox = SQLiteHandleBox(handle)
        try Self.configureAndMigrate(handle: handle)
    }

    private static func openDatabase(at path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let msg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "Unable to allocate SQLite handle"
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.connectionFailed(msg)
        }
        return handle
    }

    private func executeRaw(sql: String) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database handle is closed.") }
        try Self.executeRaw(db: db, sql: sql)
    }

    private static func executeRaw(db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if status != SQLITE_OK {
            let message = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.executionFailed(code: status, message: message)
        }
    }

    private static func configureAndMigrate(handle: OpaquePointer) throws {
        // Enforce WAL mode, foreign keys, and safe synchronization
        try executeRaw(db: handle, sql: "PRAGMA journal_mode = WAL;")
        try executeRaw(db: handle, sql: "PRAGMA foreign_keys = ON;")
        try executeRaw(db: handle, sql: "PRAGMA synchronous = NORMAL;")

        // Migration tracking table
        try executeRaw(db: handle, sql: """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            );
        """)

        let currentVersion = try getCurrentSchemaVersion(handle: handle)
        if currentVersion < 1 {
            try applyMigrationV1(handle: handle)
        }
        if currentVersion < 2 {
            try applyMigrationV2(handle: handle)
        }
        if currentVersion < 3 {
            try applyMigrationV3(handle: handle)
        }
        if currentVersion < 4 {
            try applyMigrationV4(handle: handle)
        }
        if currentVersion < 5 {
            try applyMigrationV5(handle: handle)
        }
        if currentVersion < 6 {
            try applyMigrationV6(handle: handle)
        }

        // Settle any dangling 'streaming' messages from previous crashed/interrupted runs
        try executeRaw(db: handle, sql: "UPDATE messages SET status = 'interrupted' WHERE status = 'streaming';")
        // Settle any dangling 'downloading' downloads from previous crashed/interrupted runs
        try executeRaw(db: handle, sql: "UPDATE model_downloads SET status = 'paused' WHERE status = 'downloading';")
    }

    private static func getCurrentSchemaVersion(handle: OpaquePointer) throws -> Int {
        let sql = "SELECT MAX(version) FROM schema_migrations;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                return Int(sqlite3_column_int(stmt, 0))
            }
        }
        return 0
    }

    private static func applyMigrationV1(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: """
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    model_name TEXT
                );
            """)

            try executeRaw(db: handle, sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    token_count INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
                );
            """)

            try executeRaw(db: handle, sql: """
                CREATE INDEX IF NOT EXISTS idx_messages_conversation_id
                ON messages(conversation_id, created_at);
            """)

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (1, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    private static func applyMigrationV2(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: """
                CREATE TABLE IF NOT EXISTS models (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    file_path TEXT NOT NULL UNIQUE,
                    file_size INTEGER NOT NULL,
                    architecture TEXT NOT NULL,
                    quantization TEXT NOT NULL,
                    context_length INTEGER NOT NULL,
                    parameter_count INTEGER,
                    created_at REAL NOT NULL,
                    last_used_at REAL,
                    bookmark_data BLOB
                );
            """)

            try executeRaw(db: handle, sql: """
                CREATE INDEX IF NOT EXISTS idx_models_file_path
                ON models(file_path);
            """)

            try executeRaw(db: handle, sql: """
                CREATE INDEX IF NOT EXISTS idx_models_last_used
                ON models(last_used_at);
            """)

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (2, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    private static func applyMigrationV3(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: "ALTER TABLE conversations ADD COLUMN system_prompt TEXT;")
            try executeRaw(db: handle, sql: "ALTER TABLE conversations ADD COLUMN temperature REAL;")
            try executeRaw(db: handle, sql: "ALTER TABLE conversations ADD COLUMN max_tokens INTEGER;")

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (3, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    private static func applyMigrationV4(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: "ALTER TABLE conversations ADD COLUMN stop_sequences TEXT;")

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (4, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    private static func applyMigrationV5(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    conversation_id UNINDEXED,
                    message_id UNINDEXED,
                    role UNINDEXED,
                    content,
                    tokenize = 'porter unicode61 remove_diacritics 2'
                );
            """)

            try executeRaw(db: handle, sql: """
                INSERT INTO messages_fts (conversation_id, message_id, role, content)
                SELECT conversation_id, id, role, content FROM messages;
            """)

            try executeRaw(db: handle, sql: """
                CREATE TRIGGER IF NOT EXISTS trg_messages_fts_insert
                AFTER INSERT ON messages
                BEGIN
                    INSERT INTO messages_fts (conversation_id, message_id, role, content)
                    VALUES (new.conversation_id, new.id, new.role, new.content);
                END;
            """)

            try executeRaw(db: handle, sql: """
                CREATE TRIGGER IF NOT EXISTS trg_messages_fts_update
                AFTER UPDATE OF content ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                    INSERT INTO messages_fts (conversation_id, message_id, role, content)
                    VALUES (new.conversation_id, new.id, new.role, new.content);
                END;
            """)

            try executeRaw(db: handle, sql: """
                CREATE TRIGGER IF NOT EXISTS trg_messages_fts_delete
                AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END;
            """)

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (5, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }

    private static func applyMigrationV6(handle: OpaquePointer) throws {
        try executeRaw(db: handle, sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try executeRaw(db: handle, sql: """
                CREATE TABLE IF NOT EXISTS model_downloads (
                    id TEXT PRIMARY KEY NOT NULL,
                    repo_id TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    remote_url TEXT NOT NULL,
                    destination_path TEXT NOT NULL,
                    total_bytes INTEGER NOT NULL,
                    downloaded_bytes INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    resume_data BLOB
                );
            """)

            try executeRaw(db: handle, sql: """
                CREATE INDEX IF NOT EXISTS idx_model_downloads_status
                ON model_downloads(status);
            """)

            try executeRaw(db: handle, sql: """
                CREATE INDEX IF NOT EXISTS idx_model_downloads_repo_file
                ON model_downloads(repo_id, filename);
            """)

            let now = Date().timeIntervalSince1970
            try executeRaw(db: handle, sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (6, \(now));")
            try executeRaw(db: handle, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: handle, sql: "ROLLBACK;")
            throw DatabaseError.migrationFailed(error.localizedDescription)
        }
    }


    private static func encodeStopSequences(_ stops: [String]?) -> String? {
        guard let stops, !stops.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(stops),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func decodeStopSequences(_ text: String?) -> [String]? {
        guard let text, !text.isEmpty else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - Conversation Operations

    public func createConversation(
        title: String,
        modelName: String? = nil,
        systemPrompt: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int32? = nil,
        stopSequences: [String]? = nil
    ) throws -> ConversationRecord {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let id = UUID()
        let now = Date()
        let sql = """
            INSERT INTO conversations (id, title, created_at, updated_at, model_name, system_prompt, temperature, max_tokens, stop_sequences)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
        if let modelName {
            sqlite3_bind_text(stmt, 5, modelName, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let systemPrompt {
            sqlite3_bind_text(stmt, 6, systemPrompt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let temperature {
            sqlite3_bind_double(stmt, 7, Double(temperature))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let maxTokens {
            sqlite3_bind_int(stmt, 8, maxTokens)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let stopJson = Self.encodeStopSequences(stopSequences) {
            sqlite3_bind_text(stmt, 9, stopJson, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }

        return ConversationRecord(
            id: id,
            title: title,
            createdAt: now,
            updatedAt: now,
            modelName: modelName,
            systemPrompt: systemPrompt,
            temperature: temperature,
            maxTokens: maxTokens,
            stopSequences: (stopSequences?.isEmpty ?? true) ? nil : stopSequences
        )
    }

    public func fetchConversations() throws -> [ConversationRecord] {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, title, created_at, updated_at, model_name, system_prompt, temperature, max_tokens, stop_sequences
            FROM conversations
            ORDER BY updated_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [ConversationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let modelName: String?
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                modelName = String(cString: sqlite3_column_text(stmt, 4))
            } else {
                modelName = nil
            }
            let systemPrompt: String?
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                systemPrompt = String(cString: sqlite3_column_text(stmt, 5))
            } else {
                systemPrompt = nil
            }
            let temperature: Float?
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                temperature = Float(sqlite3_column_double(stmt, 6))
            } else {
                temperature = nil
            }
            let maxTokens: Int32?
            if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
                maxTokens = sqlite3_column_int(stmt, 7)
            } else {
                maxTokens = nil
            }
            let stopSequences: [String]?
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                let stopJson = String(cString: sqlite3_column_text(stmt, 8))
                stopSequences = Self.decodeStopSequences(stopJson)
            } else {
                stopSequences = nil
            }

            if let id = UUID(uuidString: idStr) {
                results.append(ConversationRecord(
                    id: id,
                    title: title,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    modelName: modelName,
                    systemPrompt: systemPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    stopSequences: stopSequences
                ))
            }
        }
        return results
    }

    public func fetchConversation(id: UUID) throws -> ConversationRecord? {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, title, created_at, updated_at, model_name, system_prompt, temperature, max_tokens, stop_sequences
            FROM conversations
            WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let modelName: String?
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                modelName = String(cString: sqlite3_column_text(stmt, 4))
            } else {
                modelName = nil
            }
            let systemPrompt: String?
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                systemPrompt = String(cString: sqlite3_column_text(stmt, 5))
            } else {
                systemPrompt = nil
            }
            let temperature: Float?
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                temperature = Float(sqlite3_column_double(stmt, 6))
            } else {
                temperature = nil
            }
            let maxTokens: Int32?
            if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
                maxTokens = sqlite3_column_int(stmt, 7)
            } else {
                maxTokens = nil
            }
            let stopSequences: [String]?
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
                let stopJson = String(cString: sqlite3_column_text(stmt, 8))
                stopSequences = Self.decodeStopSequences(stopJson)
            } else {
                stopSequences = nil
            }

            if let uuid = UUID(uuidString: idStr) {
                return ConversationRecord(
                    id: uuid,
                    title: title,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    modelName: modelName,
                    systemPrompt: systemPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    stopSequences: stopSequences
                )
            }
        }
        return nil
    }

    public func updateConversationSettings(
        id: UUID,
        systemPrompt: String?,
        temperature: Float?,
        maxTokens: Int32?,
        stopSequences: [String]? = nil
    ) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let now = Date().timeIntervalSince1970
        let sql = "UPDATE conversations SET system_prompt = ?, temperature = ?, max_tokens = ?, stop_sequences = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if let systemPrompt {
            sqlite3_bind_text(stmt, 1, systemPrompt, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        if let temperature {
            sqlite3_bind_double(stmt, 2, Double(temperature))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let maxTokens {
            sqlite3_bind_int(stmt, 3, maxTokens)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let stopJson = Self.encodeStopSequences(stopSequences) {
            sqlite3_bind_text(stmt, 4, stopJson, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, now)
        sqlite3_bind_text(stmt, 6, id.uuidString, -1, SQLITE_TRANSIENT)

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func updateConversationTitle(id: UUID, title: String) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let now = Date().timeIntervalSince1970
        let sql = "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, SQLITE_TRANSIENT)

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func touchConversation(id: UUID) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let now = Date().timeIntervalSince1970
        let sql = "UPDATE conversations SET updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    public func updateConversationModel(id: UUID, modelName: String?) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let now = Date().timeIntervalSince1970
        let sql = "UPDATE conversations SET model_name = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        if let modelName {
            sqlite3_bind_text(stmt, 1, modelName, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, SQLITE_TRANSIENT)

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func deleteConversation(id: UUID) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "DELETE FROM conversations WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Model Operations

    @discardableResult
    public func insertModel(_ model: ModelRecord) throws -> ModelRecord {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }

        // Check for duplicates by path
        if let existing = try fetchModel(byPath: model.filePath) {
            throw ModelLibraryError.duplicateModel(path: existing.filePath)
        }

        let sql = """
            INSERT INTO models (
                id, name, file_path, file_size, architecture, quantization,
                context_length, parameter_count, created_at, last_used_at, bookmark_data
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, model.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, model.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, model.filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, model.fileSize)
        sqlite3_bind_text(stmt, 5, model.architecture, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, model.quantization, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(model.contextLength))

        if let params = model.parameterCount {
            sqlite3_bind_int64(stmt, 8, params)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        sqlite3_bind_double(stmt, 9, model.createdAt.timeIntervalSince1970)

        if let lastUsed = model.lastUsedAt {
            sqlite3_bind_double(stmt, 10, lastUsed.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        if let bookmark = model.bookmarkData {
            _ = bookmark.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 11, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 11)
        }

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }

        return model
    }

    public func fetchModels() throws -> [ModelRecord] {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, name, file_path, file_size, architecture, quantization,
                   context_length, parameter_count, created_at, last_used_at, bookmark_data
            FROM models
            ORDER BY (last_used_at IS NULL), last_used_at DESC, created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var models: [ModelRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = parseModelRecord(from: stmt) {
                models.append(record)
            }
        }
        return models
    }

    public func fetchModel(id: UUID) throws -> ModelRecord? {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, name, file_path, file_size, architecture, quantization,
                   context_length, parameter_count, created_at, last_used_at, bookmark_data
            FROM models WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseModelRecord(from: stmt)
        }
        return nil
    }

    public func fetchModel(byPath path: String) throws -> ModelRecord? {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, name, file_path, file_size, architecture, quantization,
                   context_length, parameter_count, created_at, last_used_at, bookmark_data
            FROM models WHERE file_path = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseModelRecord(from: stmt)
        }
        return nil
    }

    public func updateModelLastUsed(id: UUID, date: Date = Date()) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "UPDATE models SET last_used_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func updateModelBookmark(id: UUID, bookmarkData: Data) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "UPDATE models SET bookmark_data = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bookmarkData.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 1, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func updateModelLocation(id: UUID, filePath: String, fileSize: Int64, bookmarkData: Data?) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "UPDATE models SET file_path = ?, file_size = ?, bookmark_data = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, fileSize)
        if let bookmarkData {
            bookmarkData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 3, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, id.uuidString, -1, SQLITE_TRANSIENT)

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func deleteModel(id: UUID) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "DELETE FROM models WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func parseModelRecord(from stmt: OpaquePointer?) -> ModelRecord? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let filePath = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) else {
            return nil
        }
        let fileSize = sqlite3_column_int64(stmt, 3)
        let architecture = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "unknown"
        let quantization = sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "unknown"
        let contextLength = Int(sqlite3_column_int(stmt, 6))

        let paramCount: Int64?
        if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
            paramCount = sqlite3_column_int64(stmt, 7)
        } else {
            paramCount = nil
        }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))

        let lastUsedAt: Date?
        if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
            lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        } else {
            lastUsedAt = nil
        }

        let bookmarkData: Data?
        if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
            let blobBytes = sqlite3_column_blob(stmt, 10)
            let blobSize = sqlite3_column_bytes(stmt, 10)
            if let blobBytes, blobSize > 0 {
                bookmarkData = Data(bytes: blobBytes, count: Int(blobSize))
            } else {
                bookmarkData = nil
            }
        } else {
            bookmarkData = nil
        }

        return ModelRecord(
            id: id,
            name: name,
            filePath: filePath,
            fileSize: fileSize,
            architecture: architecture,
            quantization: quantization,
            contextLength: contextLength,
            parameterCount: paramCount,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            bookmarkData: bookmarkData,
            isMissing: false,
            compatibilityStatus: .compatible
        )
    }

    // MARK: - Message Operations

    public func insertMessage(_ message: MessageRecord) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            INSERT INTO messages (id, conversation_id, role, content, created_at, status, token_count)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, message.conversationId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, message.role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, message.content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, message.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, message.status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(message.tokenCount))

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }

        try touchConversation(id: message.conversationId)
    }

    public func updateMessageContentAndStatus(id: UUID, content: String, status: MessageStatus, tokenCount: Int) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "UPDATE messages SET content = ?, status = ?, token_count = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(tokenCount))
        sqlite3_bind_text(stmt, 4, id.uuidString, -1, SQLITE_TRANSIENT)

        let res = sqlite3_step(stmt)
        guard res == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: res, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func fetchMessages(for conversationId: UUID) throws -> [MessageRecord] {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, conversation_id, role, content, created_at, status, token_count
            FROM messages
            WHERE conversation_id = ?
            ORDER BY created_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, conversationId.uuidString, -1, SQLITE_TRANSIENT)

        var messages: [MessageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let convStr = String(cString: sqlite3_column_text(stmt, 1))
            let roleStr = String(cString: sqlite3_column_text(stmt, 2))
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let statusStr = String(cString: sqlite3_column_text(stmt, 5))
            let tokenCount = Int(sqlite3_column_int(stmt, 6))

            guard let id = UUID(uuidString: idStr),
                  let convId = UUID(uuidString: convStr),
                  let role = MessageRole(rawValue: roleStr),
                  let status = MessageStatus(rawValue: statusStr) else {
                continue
            }

            messages.append(MessageRecord(
                id: id,
                conversationId: convId,
                role: role,
                content: content,
                createdAt: createdAt,
                status: status,
                tokenCount: tokenCount
            ))
        }
        return messages
    }

    /// Automatically settles any dangling 'streaming' messages from a prior abnormal termination as 'interrupted'.
    @discardableResult
    public func recoverInterruptedGenerations() throws -> Int {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "UPDATE messages SET status = 'interrupted' WHERE status = 'streaming';"
        try executeRaw(sql: sql)
        return Int(sqlite3_changes(db))
    }

    // MARK: - Full-Text Search (FTS5)

    /// Sanitizes user input into a safe FTS5 query with prefix matching.
    /// Returns `nil` if the input contains no valid alphanumeric search terms.
    public static func sanitizeFTSQuery(_ raw: String) -> String? {
        let tokens = raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Performs full-text search across messages with BM25 relevance ranking and snippet extraction.
    ///
    /// - Parameters:
    ///   - query: Raw search query text from the user.
    ///   - limit: Maximum number of ranked results to return (default: 50).
    /// - Returns: Ranked search results mapping messages to parent conversations with delimited snippets.
    public func searchMessages(query: String, limit: Int = 50) throws -> [SearchResultRecord] {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        guard let sanitized = Self.sanitizeFTSQuery(query) else {
            return []
        }

        let sql = """
            SELECT
                f.message_id,
                f.conversation_id,
                c.title,
                f.role,
                snippet(messages_fts, 3, '[[MARK]]', '[[/MARK]]', '...', 16),
                bm25(messages_fts),
                m.created_at
            FROM messages_fts f
            JOIN conversations c ON c.id = f.conversation_id
            JOIN messages m ON m.id = f.message_id
            WHERE messages_fts MATCH ?
            ORDER BY bm25(messages_fts) ASC, m.created_at DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sanitized, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))

        var results: [SearchResultRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let msgIdStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let msgId = UUID(uuidString: msgIdStr),
                  let convIdStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let convId = UUID(uuidString: convIdStr),
                  let title = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let roleStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let role = MessageRole(rawValue: roleStr),
                  let snippet = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) else {
                continue
            }
            let rank = sqlite3_column_double(stmt, 5)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

            results.append(SearchResultRecord(
                id: msgId,
                conversationId: convId,
                conversationTitle: title,
                role: role,
                snippet: snippet,
                rank: rank,
                createdAt: createdAt
            ))
        }
        return results
    }

    // MARK: - Download Operations

    public func insertDownload(_ download: ModelDownloadRecord) throws -> ModelDownloadRecord {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            INSERT INTO model_downloads (
                id, repo_id, filename, remote_url, destination_path,
                total_bytes, downloaded_bytes, status, error_message,
                created_at, updated_at, resume_data
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, download.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, download.repoId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, download.filename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, download.remoteURL, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, download.destinationPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, download.totalBytes)
        sqlite3_bind_int64(stmt, 7, download.downloadedBytes)
        sqlite3_bind_text(stmt, 8, download.status.rawValue, -1, SQLITE_TRANSIENT)

        if let errMsg = download.errorMessage {
            sqlite3_bind_text(stmt, 9, errMsg, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        sqlite3_bind_double(stmt, 10, download.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 11, download.updatedAt.timeIntervalSince1970)

        if let resumeData = download.resumeData {
            _ = resumeData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 12, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 12)
        }

        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: status, message: String(cString: sqlite3_errmsg(db)))
        }

        return download
    }

    public func updateDownloadProgress(
        id: UUID,
        downloadedBytes: Int64,
        totalBytes: Int64,
        status: DownloadStatus,
        errorMessage: String? = nil,
        resumeData: Data? = nil
    ) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let now = Date().timeIntervalSince1970
        let sql = """
            UPDATE model_downloads
            SET downloaded_bytes = ?, total_bytes = ?, status = ?,
                error_message = ?, updated_at = ?, resume_data = ?
            WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, downloadedBytes)
        sqlite3_bind_int64(stmt, 2, totalBytes)
        sqlite3_bind_text(stmt, 3, status.rawValue, -1, SQLITE_TRANSIENT)

        if let errorMessage {
            sqlite3_bind_text(stmt, 4, errorMessage, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_bind_double(stmt, 5, now)

        if let resumeData {
            _ = resumeData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 6, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        sqlite3_bind_text(stmt, 7, id.uuidString, -1, SQLITE_TRANSIENT)

        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: stepResult, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func fetchDownloads() throws -> [ModelDownloadRecord] {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, repo_id, filename, remote_url, destination_path,
                   total_bytes, downloaded_bytes, status, error_message,
                   created_at, updated_at, resume_data
            FROM model_downloads
            ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var downloads: [ModelDownloadRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = parseDownloadRecord(from: stmt) {
                downloads.append(record)
            }
        }
        return downloads
    }

    public func fetchDownload(id: UUID) throws -> ModelDownloadRecord? {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, repo_id, filename, remote_url, destination_path,
                   total_bytes, downloaded_bytes, status, error_message,
                   created_at, updated_at, resume_data
            FROM model_downloads
            WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseDownloadRecord(from: stmt)
        }
        return nil
    }

    public func fetchDownload(repoId: String, filename: String) throws -> ModelDownloadRecord? {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = """
            SELECT id, repo_id, filename, remote_url, destination_path,
                   total_bytes, downloaded_bytes, status, error_message,
                   created_at, updated_at, resume_data
            FROM model_downloads
            WHERE repo_id = ? AND filename = ?
            ORDER BY created_at DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, repoId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseDownloadRecord(from: stmt)
        }
        return nil
    }

    public func deleteDownload(id: UUID) throws {
        guard let db else { throw DatabaseError.connectionFailed("Database is closed.") }
        let sql = "DELETE FROM model_downloads WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            throw DatabaseError.executionFailed(code: stepResult, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func parseDownloadRecord(from stmt: OpaquePointer?) -> ModelDownloadRecord? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let repoId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let filename = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let remoteURL = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let destinationPath = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
              let statusStr = sqlite3_column_text(stmt, 7).map({ String(cString: $0) }) else {
            return nil
        }
        let totalBytes = sqlite3_column_int64(stmt, 5)
        let downloadedBytes = sqlite3_column_int64(stmt, 6)
        let status = DownloadStatus(rawValue: statusStr) ?? .failed

        let errorMessage: String?
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL,
           let errCStr = sqlite3_column_text(stmt, 8) {
            errorMessage = String(cString: errCStr)
        } else {
            errorMessage = nil
        }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        let resumeData: Data?
        if sqlite3_column_type(stmt, 11) != SQLITE_NULL,
           let blobBytes = sqlite3_column_blob(stmt, 11) {
            let blobSize = sqlite3_column_bytes(stmt, 11)
            resumeData = Data(bytes: blobBytes, count: Int(blobSize))
        } else {
            resumeData = nil
        }

        return ModelDownloadRecord(
            id: id,
            repoId: repoId,
            filename: filename,
            remoteURL: remoteURL,
            destinationPath: destinationPath,
            totalBytes: totalBytes,
            downloadedBytes: downloadedBytes,
            status: status,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            resumeData: resumeData
        )
    }

    public func close() {
        handleBox.close()
    }
}

// Marker for SQLITE_TRANSIENT in Swift
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

