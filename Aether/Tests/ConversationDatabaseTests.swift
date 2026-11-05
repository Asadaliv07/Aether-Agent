import XCTest
import SQLite3
@testable import Aether

final class ConversationDatabaseTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDirectoryURL = tempDir
    }

    override func tearDown() async throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func createTestDatabase() throws -> (ConversationDatabase, URL) {
        let dbURL = tempDirectoryURL.appendingPathComponent("test_\(UUID().uuidString).sqlite")
        let db = try ConversationDatabase(fileURL: dbURL)
        return (db, dbURL)
    }

    // MARK: - Schema & Migration Tests

    func testDatabaseInitializationAndSchemaCreation() async throws {
        let (db, dbURL) = try createTestDatabase()
        defer { Task { await db.close() } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        // Ensure we can fetch conversations from an empty database without error
        let convs = try await db.fetchConversations()
        XCTAssertTrue(convs.isEmpty)
    }

    func testInMemoryDatabaseInitialization() async throws {
        let db = try ConversationDatabase(inMemory: true)
        defer { Task { await db.close() } }

        let convs = try await db.fetchConversations()
        XCTAssertTrue(convs.isEmpty)
    }

    // MARK: - Conversation CRUD Tests

    func testCreateAndFetchConversations() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let created1 = try await db.createConversation(title: "First Conversation", modelName: "Qwen-7B")
        XCTAssertEqual(created1.title, "First Conversation")
        XCTAssertEqual(created1.modelName, "Qwen-7B")

        let created2 = try await db.createConversation(title: "Second Conversation", modelName: nil)
        XCTAssertEqual(created2.title, "Second Conversation")
        XCTAssertNil(created2.modelName)

        let fetched = try await db.fetchConversations()
        XCTAssertEqual(fetched.count, 2)
        // Ordered by updated_at DESC: created2 should be first
        XCTAssertEqual(fetched[0].id, created2.id)
        XCTAssertEqual(fetched[1].id, created1.id)

        // Fetch single conversation by ID
        let single = try await db.fetchConversation(id: created1.id)
        XCTAssertNotNil(single)
        XCTAssertEqual(single?.id, created1.id)
        XCTAssertEqual(single?.title, "First Conversation")
        XCTAssertEqual(single?.modelName, "Qwen-7B")
    }

    func testUpdateConversationTitleAndTouch() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let created = try await db.createConversation(title: "Original Title")
        try await db.updateConversationTitle(id: created.id, title: "Renamed Title")

        let fetched = try await db.fetchConversation(id: created.id)
        XCTAssertEqual(fetched?.title, "Renamed Title")
        XCTAssertGreaterThanOrEqual(fetched!.updatedAt, created.updatedAt)
    }

    func testDeleteConversationCascadeMessages() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "To Be Deleted")

        // Add user and assistant messages
        let userMsg = MessageRecord(
            conversationId: conv.id,
            role: .user,
            content: "Hello",
            status: .completed
        )
        let assistantMsg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Hi there!",
            status: .completed
        )
        try await db.insertMessage(userMsg)
        try await db.insertMessage(assistantMsg)

        var msgs = try await db.fetchMessages(for: conv.id)
        XCTAssertEqual(msgs.count, 2)

        // Delete conversation
        try await db.deleteConversation(id: conv.id)

        let convAfter = try await db.fetchConversation(id: conv.id)
        XCTAssertNil(convAfter)

        // Cascade delete check: messages should be removed
        msgs = try await db.fetchMessages(for: conv.id)
        XCTAssertTrue(msgs.isEmpty)
    }

    // MARK: - Message Operations & Ordering

    func testInsertAndFetchMessagesChronologicalOrder() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Chat Flow")

        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1005)
        let t2 = Date(timeIntervalSince1970: 1010)

        let msg1 = MessageRecord(conversationId: conv.id, role: .user, content: "Prompt 1", createdAt: t0, status: .completed)
        let msg2 = MessageRecord(conversationId: conv.id, role: .assistant, content: "Answer 1", createdAt: t1, status: .completed, tokenCount: 42)
        let msg3 = MessageRecord(conversationId: conv.id, role: .user, content: "Prompt 2", createdAt: t2, status: .completed)

        try await db.insertMessage(msg2)
        try await db.insertMessage(msg1)
        try await db.insertMessage(msg3)

        let messages = try await db.fetchMessages(for: conv.id)
        XCTAssertEqual(messages.count, 3)
        // Verify chronological ascending ordering
        XCTAssertEqual(messages[0].id, msg1.id)
        XCTAssertEqual(messages[1].id, msg2.id)
        XCTAssertEqual(messages[2].id, msg3.id)
        XCTAssertEqual(messages[1].tokenCount, 42)
    }

    func testUpdateMessageContentAndStatus() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Streaming Message Test")
        let assistantMsg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Par",
            status: .streaming
        )
        try await db.insertMessage(assistantMsg)

        // Incremental streaming updates
        try await db.updateMessageContentAndStatus(
            id: assistantMsg.id,
            content: "Partial response",
            status: .streaming,
            tokenCount: 2
        )

        var msgs = try await db.fetchMessages(for: conv.id)
        XCTAssertEqual(msgs.first?.content, "Partial response")
        XCTAssertEqual(msgs.first?.status, .streaming)
        XCTAssertEqual(msgs.first?.tokenCount, 2)

        // Complete generation
        try await db.updateMessageContentAndStatus(
            id: assistantMsg.id,
            content: "Partial response and conclusion.",
            status: .completed,
            tokenCount: 6
        )

        msgs = try await db.fetchMessages(for: conv.id)
        XCTAssertEqual(msgs.first?.content, "Partial response and conclusion.")
        XCTAssertEqual(msgs.first?.status, .completed)
        XCTAssertEqual(msgs.first?.tokenCount, 6)
    }

    // MARK: - Interrupted Recovery Tests

    func testRecoverInterruptedGenerations() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Recovery Test")

        // 1 completed, 2 streaming (dangling) messages
        let completed = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Done answer",
            status: .completed
        )
        let streaming1 = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Unfinished stream 1",
            status: .streaming
        )
        let streaming2 = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Unfinished stream 2",
            status: .streaming
        )

        try await db.insertMessage(completed)
        try await db.insertMessage(streaming1)
        try await db.insertMessage(streaming2)

        // Simulate crash / restart recovery
        let recoveredCount = try await db.recoverInterruptedGenerations()
        XCTAssertEqual(recoveredCount, 2)

        let msgs = try await db.fetchMessages(for: conv.id)
        let mDone = msgs.first(where: { $0.id == completed.id })
        let mStream1 = msgs.first(where: { $0.id == streaming1.id })
        let mStream2 = msgs.first(where: { $0.id == streaming2.id })

        XCTAssertEqual(mDone?.status, .completed)
        XCTAssertEqual(mStream1?.status, .interrupted)
        XCTAssertEqual(mStream2?.status, .interrupted)
    }

    // MARK: - Foreign Key Constraint Enforcement

    func testForeignKeyConstraintRejectsOrphanMessages() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let nonExistentConvId = UUID()
        let orphanMessage = MessageRecord(
            conversationId: nonExistentConvId,
            role: .user,
            content: "Orphan message",
            status: .completed
        )

        do {
            try await db.insertMessage(orphanMessage)
            XCTFail("Inserting message with non-existent conversationId should violate foreign key constraint.")
        } catch let DatabaseError.executionFailed(code, _) {
            // SQLite SQLITE_CONSTRAINT error code is 19
            XCTAssertEqual(code, 19)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Stress & Durability Tests (Phase 3.5.1 Validation)

    func testPersistenceStress_RapidCRUD500Iterations() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let startTime = CFAbsoluteTimeGetCurrent()
        var createdIds: [UUID] = []

        for i in 1...500 {
            let conv = try await db.createConversation(title: "Stress Conv \(i)", modelName: "Qwen-7B")
            createdIds.append(conv.id)

            let userMsg = MessageRecord(
                conversationId: conv.id,
                role: .user,
                content: "Prompt payload for iteration \(i)",
                status: .completed
            )
            try await db.insertMessage(userMsg)

            let assistantMsg = MessageRecord(
                conversationId: conv.id,
                role: .assistant,
                content: "In-flight token...",
                status: .streaming
            )
            try await db.insertMessage(assistantMsg)

            try await db.updateMessageContentAndStatus(
                id: assistantMsg.id,
                content: "Final verified response payload for iteration \(i)",
                status: .completed,
                tokenCount: 16
            )

            // Verify integrity periodically
            if i % 50 == 0 {
                let msgs = try await db.fetchMessages(for: conv.id)
                XCTAssertEqual(msgs.count, 2)
                XCTAssertEqual(msgs[0].content, "Prompt payload for iteration \(i)")
                XCTAssertEqual(msgs[1].status, .completed)
            }

            // Periodic deletion to test cascade deletion under load
            if i % 100 == 0 {
                try await db.deleteConversation(id: conv.id)
                let afterDeleteMsgs = try await db.fetchMessages(for: conv.id)
                XCTAssertTrue(afterDeleteMsgs.isEmpty)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[STRESS] Completed 500 rapid CRUD iterations in \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 30.0, "500 rapid CRUD iterations must complete within budget")
    }

    func testPersistenceStress_ModeratelyLargeConversation() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Large Thread 100 Turns")
        let totalMessages = 100

        for i in 0..<totalMessages {
            let role: MessageRole = (i % 2 == 0) ? .user : .assistant
            let msg = MessageRecord(
                conversationId: conv.id,
                role: role,
                content: "Message index \(i) in extended conversation history",
                createdAt: Date(timeIntervalSince1970: 1700000000 + Double(i * 10)),
                status: .completed,
                tokenCount: role == .assistant ? 25 : 0
            )
            try await db.insertMessage(msg)
        }

        let fetched = try await db.fetchMessages(for: conv.id)
        XCTAssertEqual(fetched.count, totalMessages)

        // Verify strictly monotonic chronological order
        for i in 1..<fetched.count {
            XCTAssertGreaterThanOrEqual(fetched[i].createdAt, fetched[i - 1].createdAt)
            XCTAssertEqual(fetched[i].content, "Message index \(i) in extended conversation history")
        }
    }

    func testWALModeAndReopeningDatabase() async throws {
        let (db1, dbURL) = try createTestDatabase()
        let conv = try await db1.createConversation(title: "Pre-Close Conversation")
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .user,
            content: "Survives closure",
            status: .completed
        )
        try await db1.insertMessage(msg)
        await db1.close()

        // Reopen new database connection on same file
        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let conversations = try await db2.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, conv.id)
        XCTAssertEqual(conversations.first?.title, "Pre-Close Conversation")

        let messages = try await db2.fetchMessages(for: conv.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Survives closure")
    }

    func testDatabaseRecoveryIdempotence() async throws {
        let (db1, dbURL) = try createTestDatabase()
        let conv = try await db1.createConversation(title: "Recovery Idempotence")

        let m1 = MessageRecord(conversationId: conv.id, role: .assistant, content: "Stream 1", status: .streaming)
        let m2 = MessageRecord(conversationId: conv.id, role: .assistant, content: "Stream 2", status: .streaming)
        let mDone = MessageRecord(conversationId: conv.id, role: .assistant, content: "Already completed", status: .completed)

        try await db1.insertMessage(m1)
        try await db1.insertMessage(m2)
        try await db1.insertMessage(mDone)
        await db1.close()

        // Reopening automatically triggers recovery
        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let msgs = try await db2.fetchMessages(for: conv.id)
        let rec1 = msgs.first(where: { $0.id == m1.id })
        let rec2 = msgs.first(where: { $0.id == m2.id })
        let recDone = msgs.first(where: { $0.id == mDone.id })

        XCTAssertEqual(rec1?.status, .interrupted)
        XCTAssertEqual(rec2?.status, .interrupted)
        XCTAssertEqual(recDone?.status, .completed)

        // Second explicit recovery should recover 0 records (idempotent)
        let secondRecover = try await db2.recoverInterruptedGenerations()
        XCTAssertEqual(secondRecover, 0)
    }

    func testForeignKeyEnforcedOnReopenedConnection() async throws {
        let (db1, dbURL) = try createTestDatabase()
        _ = try await db1.createConversation(title: "Initial Conv")
        await db1.close()

        // Reopen database connection
        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let nonExistentConvId = UUID()
        let orphanMessage = MessageRecord(
            conversationId: nonExistentConvId,
            role: .user,
            content: "Orphan on reopened DB",
            status: .completed
        )

        do {
            try await db2.insertMessage(orphanMessage)
            XCTFail("Inserting message with non-existent conversationId must fail on reopened connection")
        } catch let DatabaseError.executionFailed(code, _) {
            XCTAssertEqual(code, 19, "Must return SQLITE_CONSTRAINT (19)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Phase 3.7 Migration v3 & Settings Tests

    func testMigrationV3ColumnsAndDefaultNilValues() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Settings Test")
        XCTAssertNil(conv.systemPrompt)
        XCTAssertNil(conv.temperature)
        XCTAssertNil(conv.maxTokens)

        // Update settings
        try await db.updateConversationSettings(
            id: conv.id,
            systemPrompt: "You are an expert coder.",
            temperature: 0.2,
            maxTokens: 1024
        )

        let fetched = try await db.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.systemPrompt, "You are an expert coder.")
        XCTAssertEqual(fetched?.temperature, 0.2)
        XCTAssertEqual(fetched?.maxTokens, 1024)
    }

    func testConversationSettingsIsolation() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let convA = try await db.createConversation(title: "Conv A")
        let convB = try await db.createConversation(title: "Conv B")

        try await db.updateConversationSettings(
            id: convA.id,
            systemPrompt: "Prompt A",
            temperature: 0.1,
            maxTokens: 512
        )

        try await db.updateConversationSettings(
            id: convB.id,
            systemPrompt: "Prompt B",
            temperature: 1.5,
            maxTokens: 4096
        )

        let fetchedA = try await db.fetchConversation(id: convA.id)
        let fetchedB = try await db.fetchConversation(id: convB.id)

        XCTAssertEqual(fetchedA?.systemPrompt, "Prompt A")
        XCTAssertEqual(fetchedA?.temperature, 0.1)
        XCTAssertEqual(fetchedA?.maxTokens, 512)

        XCTAssertEqual(fetchedB?.systemPrompt, "Prompt B")
        XCTAssertEqual(fetchedB?.temperature, 1.5)
        XCTAssertEqual(fetchedB?.maxTokens, 4096)
    }

    func testReopenDatabasePreservesV3Settings() async throws {
        let (db1, dbURL) = try createTestDatabase()
        let conv = try await db1.createConversation(title: "Reopen Settings")
        try await db1.updateConversationSettings(
            id: conv.id,
            systemPrompt: "Persist across reopen",
            temperature: 0.85,
            maxTokens: 3000
        )
        await db1.close()

        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let fetched = try await db2.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.systemPrompt, "Persist across reopen")
        XCTAssertEqual(fetched?.temperature, 0.85)
        XCTAssertEqual(fetched?.maxTokens, 3000)
    }

    // MARK: - Phase 3.7.2 Migration v4 & Stop Sequences Tests

    func testMigrationV3ToV4PreservesExistingDataAndAddsStopSequences() async throws {
        // 1. Manually initialize a v3 database
        let v3DbURL = tempDirectoryURL.appendingPathComponent("v3_test.sqlite")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(v3DbURL.path, &handle, flags, nil), SQLITE_OK)

        let v3SQL = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                model_name TEXT,
                system_prompt TEXT,
                temperature REAL,
                max_tokens INTEGER
            );
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
            INSERT INTO schema_migrations (version, applied_at) VALUES (1, 1000.0);
            INSERT INTO schema_migrations (version, applied_at) VALUES (2, 2000.0);
            INSERT INTO schema_migrations (version, applied_at) VALUES (3, 3000.0);
            INSERT INTO conversations (id, title, created_at, updated_at, model_name, system_prompt, temperature, max_tokens)
            VALUES ('C4444444-4444-4444-4444-444444444444', 'V3 Legacy Chat', 3000.0, 3000.0, 'LegacyModel', 'Old Prompt', 0.5, 512);
            INSERT INTO messages (id, conversation_id, role, content, created_at, status, token_count)
            VALUES ('D4444444-4444-4444-4444-444444444444', 'C4444444-4444-4444-4444-444444444444', 'user', 'Hello v3', 3001.0, 'completed', 3);
        """
        XCTAssertEqual(sqlite3_exec(handle, v3SQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        // 2. Open via ConversationDatabase which applies Migration v4
        let db = try ConversationDatabase(fileURL: v3DbURL)
        defer { Task { await db.close() } }

        // Verify conversation and message survived untouched
        let convs = try await db.fetchConversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.title, "V3 Legacy Chat")
        XCTAssertEqual(convs.first?.systemPrompt, "Old Prompt")
        XCTAssertEqual(convs.first?.temperature, 0.5)
        XCTAssertEqual(convs.first?.maxTokens, 512)
        XCTAssertNil(convs.first?.stopSequences)

        let messages = try await db.fetchMessages(for: UUID(uuidString: "C4444444-4444-4444-4444-444444444444")!)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hello v3")
    }

    func testStopSequencesPersistenceAndJSONRoundtrip() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let stops = ["###", "</s>", "<|im_end|>"]
        let conv = try await db.createConversation(
            title: "Stop Seq Chat",
            stopSequences: stops
        )
        XCTAssertEqual(conv.stopSequences, stops)

        let fetched = try await db.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.stopSequences, stops)

        // Update with new stop sequences
        let updatedStops = ["END", "STOP"]
        try await db.updateConversationSettings(
            id: conv.id,
            systemPrompt: "New prompt",
            temperature: 0.7,
            maxTokens: 2048,
            stopSequences: updatedStops
        )

        let fetchedUpdated = try await db.fetchConversation(id: conv.id)
        XCTAssertEqual(fetchedUpdated?.stopSequences, updatedStops)
    }

    func testStopSequencesEmptyArrayAndNullHandling() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Empty Stops Chat", stopSequences: [])
        XCTAssertNil(conv.stopSequences)

        let fetched = try await db.fetchConversation(id: conv.id)
        XCTAssertNil(fetched?.stopSequences)

        // Update with nil
        try await db.updateConversationSettings(
            id: conv.id,
            systemPrompt: nil,
            temperature: nil,
            maxTokens: nil,
            stopSequences: nil
        )

        let fetchedNil = try await db.fetchConversation(id: conv.id)
        XCTAssertNil(fetchedNil?.stopSequences)
    }

    func testMalformedJSONHandlingGracefulFallback() async throws {
        let (db, dbURL) = try createTestDatabase()
        let conv = try await db.createConversation(title: "Corrupt JSON Chat")
        await db.close()

        // Inject corrupt JSON directly into sqlite column
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &handle, flags, nil), SQLITE_OK)
        let corruptSQL = "UPDATE conversations SET stop_sequences = '{\"corrupt\": invalid[' WHERE id = '\(conv.id.uuidString)';"
        XCTAssertEqual(sqlite3_exec(handle, corruptSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        // Reopen database and fetch: should gracefully fallback to empty array without crashing
        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let fetched = try await db2.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.stopSequences, [])
    }

    func testStopSequencesConversationIsolation() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let convA = try await db.createConversation(title: "Conv A", stopSequences: ["A_STOP"])
        let convB = try await db.createConversation(title: "Conv B", stopSequences: ["B_STOP1", "B_STOP2"])

        let fetchedA = try await db.fetchConversation(id: convA.id)
        let fetchedB = try await db.fetchConversation(id: convB.id)

        XCTAssertEqual(fetchedA?.stopSequences, ["A_STOP"])
        XCTAssertEqual(fetchedB?.stopSequences, ["B_STOP1", "B_STOP2"])
    }

    func testReopenDatabasePreservesV4StopSequences() async throws {
        let (db1, dbURL) = try createTestDatabase()
        let stops = ["\nUser:", "###"]
        let conv = try await db1.createConversation(title: "Reopen Stops", stopSequences: stops)
        await db1.close()

        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let fetched = try await db2.fetchConversation(id: conv.id)
        XCTAssertEqual(fetched?.stopSequences, stops)
    }

    // MARK: - Phase 3.8 Migration v5 & Full-Text Search Tests

    func testMigrationV4ToV5BackfillsExistingMessagesAndPreservesAllData() async throws {
        // 1. Manually initialize a v4 database with conversations and messages
        let v4DbURL = tempDirectoryURL.appendingPathComponent("v4_test.sqlite")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(v4DbURL.path, &handle, flags, nil), SQLITE_OK)

        let v4SQL = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                model_name TEXT,
                system_prompt TEXT,
                temperature REAL,
                max_tokens INTEGER,
                stop_sequences TEXT
            );
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
            INSERT INTO schema_migrations (version, applied_at) VALUES (1, 1000.0);
            INSERT INTO schema_migrations (version, applied_at) VALUES (2, 2000.0);
            INSERT INTO schema_migrations (version, applied_at) VALUES (3, 3000.0);
            INSERT INTO schema_migrations (version, applied_at) VALUES (4, 4000.0);
            INSERT INTO conversations (id, title, created_at, updated_at, model_name, system_prompt, temperature, max_tokens, stop_sequences)
            VALUES ('C5555555-5555-5555-5555-555555555555', 'V4 Pre-Search Chat', 4000.0, 4000.0, 'Qwen-7B', 'System Instruction', 0.7, 2048, '["###"]');
            INSERT INTO messages (id, conversation_id, role, content, created_at, status, token_count)
            VALUES ('D5555555-5555-5555-5555-555555555551', 'C5555555-5555-5555-5555-555555555555', 'user', 'What are the architectural benefits of unified memory in Apple Silicon?', 4001.0, 'completed', 12);
            INSERT INTO messages (id, conversation_id, role, content, created_at, status, token_count)
            VALUES ('D5555555-5555-5555-5555-555555555552', 'C5555555-5555-5555-5555-555555555555', 'assistant', 'Unified memory eliminates PCIe bandwidth bottlenecks and enables zero-copy tensor operations between CPU and Metal GPU.', 4002.0, 'completed', 20);
        """
        XCTAssertEqual(sqlite3_exec(handle, v4SQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        // 2. Open via ConversationDatabase which applies Migration v5
        let db = try ConversationDatabase(fileURL: v4DbURL)
        defer { Task { await db.close() } }

        // Verify conversation and message survived untouched
        let convs = try await db.fetchConversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.title, "V4 Pre-Search Chat")
        XCTAssertEqual(convs.first?.stopSequences, ["###"])

        let messages = try await db.fetchMessages(for: UUID(uuidString: "C5555555-5555-5555-5555-555555555555")!)
        XCTAssertEqual(messages.count, 2)

        // 3. Verify backfill into search index
        let results = try await db.searchMessages(query: "unified memory")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.conversationId == UUID(uuidString: "C5555555-5555-5555-5555-555555555555") })
        XCTAssertEqual(results.first?.conversationTitle, "V4 Pre-Search Chat")
        XCTAssertTrue(results.contains { $0.role == .user })
        XCTAssertTrue(results.contains { $0.role == .assistant })

        // Check snippet highlighting
        let assistantMatch = results.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistantMatch)
        XCTAssertTrue(assistantMatch?.snippet.contains("[[MARK]]") == true)
        XCTAssertTrue(assistantMatch?.snippet.contains("[[/MARK]]") == true)
    }

    func testRealtimeSynchronization_InsertUpdateDelete() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Realtime Sync Test")

        // 1. Insert message -> searchable immediately
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .user,
            content: "Quantum computing utilizes qubits for superposition.",
            status: .completed
        )
        try await db.insertMessage(msg)

        var searchQubit = try await db.searchMessages(query: "qubits")
        XCTAssertEqual(searchQubit.count, 1)
        XCTAssertEqual(searchQubit.first?.id, msg.id)

        // 2. Update message content -> old term gone, new term searchable
        try await db.updateMessageContentAndStatus(
            id: msg.id,
            content: "Classical computing utilizes transistors for binary states.",
            status: .completed,
            tokenCount: 8
        )

        searchQubit = try await db.searchMessages(query: "qubits")
        XCTAssertEqual(searchQubit.count, 0, "Old term must not match after update")

        let searchTransistors = try await db.searchMessages(query: "transistors")
        XCTAssertEqual(searchTransistors.count, 1)
        XCTAssertEqual(searchTransistors.first?.id, msg.id)
    }

    func testRealtimeSynchronization_Streaming16TokenUpdates() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Streaming Sync Test")
        let assistantMsg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "",
            status: .streaming
        )
        try await db.insertMessage(assistantMsg)

        // Simulate 3 streaming batch updates (e.g. at token 16, 32, and final)
        try await db.updateMessageContentAndStatus(
            id: assistantMsg.id,
            content: "The foundational core of astrophysics revolves around gravitation.",
            status: .streaming,
            tokenCount: 16
        )

        var searchRes = try await db.searchMessages(query: "astrophysics")
        XCTAssertEqual(searchRes.count, 1)
        XCTAssertEqual(searchRes.first?.id, assistantMsg.id)

        // Streaming update 2: appends more content
        try await db.updateMessageContentAndStatus(
            id: assistantMsg.id,
            content: "The foundational core of astrophysics revolves around gravitation and thermonuclear fusion.",
            status: .streaming,
            tokenCount: 32
        )

        let searchFusion = try await db.searchMessages(query: "thermonuclear")
        XCTAssertEqual(searchFusion.count, 1)
        XCTAssertEqual(searchFusion.first?.id, assistantMsg.id)

        // Final completion update
        try await db.updateMessageContentAndStatus(
            id: assistantMsg.id,
            content: "The foundational core of astrophysics revolves around gravitation and thermonuclear fusion in stars.",
            status: .completed,
            tokenCount: 35
        )

        let searchStars = try await db.searchMessages(query: "stars")
        XCTAssertEqual(searchStars.count, 1)
        XCTAssertEqual(searchStars.first?.id, assistantMsg.id)
    }

    func testRealtimeSynchronization_CascadeDeleteConversations() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Cascade Search Test")
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Ephemeral knowledge about exoplanets in the Andromeda galaxy.",
            status: .completed
        )
        try await db.insertMessage(msg)

        let beforeDelete = try await db.searchMessages(query: "exoplanets")
        XCTAssertEqual(beforeDelete.count, 1)

        // Delete conversation (triggers cascade delete on messages and syncs messages_fts)
        try await db.deleteConversation(id: conv.id)

        let afterDelete = try await db.searchMessages(query: "exoplanets")
        XCTAssertEqual(afterDelete.count, 0, "Deleted conversation messages must not appear in search results")
    }

    func testSearchAcrossMultipleConversations() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv1 = try await db.createConversation(title: "Swift 6 Concurrency")
        let conv2 = try await db.createConversation(title: "Rust Ownership")

        let msg1 = MessageRecord(
            conversationId: conv1.id,
            role: .user,
            content: "How does strict concurrency prevent data races at compile time?",
            status: .completed
        )
        let msg2 = MessageRecord(
            conversationId: conv2.id,
            role: .assistant,
            content: "The compiler eliminates data races using sendable and borrow checking.",
            status: .completed
        )

        try await db.insertMessage(msg1)
        try await db.insertMessage(msg2)

        let results = try await db.searchMessages(query: "data races")
        XCTAssertEqual(results.count, 2)

        let convIds = Set(results.map { $0.conversationId })
        XCTAssertTrue(convIds.contains(conv1.id))
        XCTAssertTrue(convIds.contains(conv2.id))

        let titles = Set(results.map { $0.conversationTitle })
        XCTAssertTrue(titles.contains("Swift 6 Concurrency"))
        XCTAssertTrue(titles.contains("Rust Ownership"))
    }

    func testSearchRankingBM25AndSnippets() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Ranking Test")

        // msgLow has 1 occurrence of "compiler"
        let msgLow = MessageRecord(
            conversationId: conv.id,
            role: .user,
            content: "The software was built using a modern compiler toolchain.",
            status: .completed
        )
        // msgHigh has 4 occurrences of "compiler"
        let msgHigh = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "The compiler optimizes code. A compiler backend generates instructions. The compiler pipeline is fast. The compiler validates syntax.",
            status: .completed
        )

        try await db.insertMessage(msgLow)
        try await db.insertMessage(msgHigh)

        let results = try await db.searchMessages(query: "compiler")
        XCTAssertEqual(results.count, 2)

        // BM25 negative score: more negative score indicates higher term frequency/relevance
        XCTAssertEqual(results[0].id, msgHigh.id, "Higher term frequency message must rank first")
        XCTAssertEqual(results[1].id, msgLow.id)
        XCTAssertLessThan(results[0].rank, results[1].rank)

        // Verify snippet delimiters
        XCTAssertTrue(results[0].snippet.contains("[[MARK]]compiler[[/MARK]]"))
    }

    func testSearchSanitizationAndAdversarialQueries() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Sanitization Test")
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Antigravity agents do not panic or fail near SQLite.",
            status: .completed
        )
        try await db.insertMessage(msg)

        // 1. Empty query
        let empty1 = try await db.searchMessages(query: "")
        XCTAssertEqual(empty1, [])
        let empty2 = try await db.searchMessages(query: "   \t\n")
        XCTAssertEqual(empty2, [])

        // 2. Punctuation only
        let punct = try await db.searchMessages(query: "???!!!@@@###$$$%%%^^^&&&***()")
        XCTAssertEqual(punct, [])

        // 3. Unclosed quotes and FTS operators (must not throw syntax error)
        let unclosed = try await db.searchMessages(query: "\"Antigravity")
        XCTAssertEqual(unclosed.count, 1)

        let booleanOps = try await db.searchMessages(query: "Antigravity OR NOT NEAR")
        XCTAssertEqual(booleanOps.count, 1, "FTS boolean keywords must be safely sanitized as regular terms without syntax error")

        let booleanNonMatch = try await db.searchMessages(query: "OR NOT NEAR nonexistent")
        XCTAssertEqual(booleanNonMatch.count, 0, "Non-matching query with FTS keywords must execute safely")

        // 4. SQL injection attempts
        let sqli1 = try await db.searchMessages(query: "Robert'); DROP TABLE conversations;--")
        XCTAssertEqual(sqli1.count, 0)
        let convsAfter = try await db.fetchConversations()
        XCTAssertEqual(convsAfter.count, 1, "Conversations table must survive injection attempts")

        let sqli2 = try await db.searchMessages(query: "' OR '1'='1")
        XCTAssertEqual(sqli2.count, 0)

        // 5. Special FTS chars
        let special = try await db.searchMessages(query: "SQLite* ^ :")
        XCTAssertEqual(special.count, 1)
    }

    func testSearchStemmingAndDiacritics() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Linguistics Test")
        let msg1 = MessageRecord(
            conversationId: conv.id,
            role: .user,
            content: "We stopped at the gemütliche café for lunch.",
            status: .completed
        )
        let msg2 = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "The athletes were running steadily during the marathon.",
            status: .completed
        )
        try await db.insertMessage(msg1)
        try await db.insertMessage(msg2)

        // Diacritics matching: 'cafe' matches 'café'
        let cafeRes = try await db.searchMessages(query: "cafe")
        XCTAssertEqual(cafeRes.count, 1)
        XCTAssertEqual(cafeRes.first?.id, msg1.id)

        // Diacritics matching: 'gemutliche' matches 'gemütliche'
        let gemutRes = try await db.searchMessages(query: "gemutliche")
        XCTAssertEqual(gemutRes.count, 1)
        XCTAssertEqual(gemutRes.first?.id, msg1.id)

        // Stemming matching: 'run' matches 'running'
        let runRes = try await db.searchMessages(query: "run")
        XCTAssertEqual(runRes.count, 1)
        XCTAssertEqual(runRes.first?.id, msg2.id)
    }

    func testSearchConcurrencyAndActorIsolation() async throws {
        let (db, _) = try createTestDatabase()
        defer { Task { await db.close() } }

        let conv = try await db.createConversation(title: "Concurrent Search")
        for i in 1...20 {
            let msg = MessageRecord(
                conversationId: conv.id,
                role: (i % 2 == 0) ? .assistant : .user,
                content: "Concurrent indexed message payload \(i) testing actor safety",
                status: .completed
            )
            try await db.insertMessage(msg)
        }

        // Launch 20 concurrent search requests simultaneously
        await withTaskGroup(of: [SearchResultRecord].self) { group in
            for i in 1...20 {
                group.addTask {
                    return (try? await db.searchMessages(query: "payload \(i)")) ?? []
                }
            }

            var totalFound = 0
            for await res in group {
                if !res.isEmpty {
                    totalFound += 1
                }
            }
            XCTAssertEqual(totalFound, 20, "All concurrent searches must complete with actor isolation")
        }
    }

    func testReopenDatabasePreservesSearchIndex() async throws {
        let (db1, dbURL) = try createTestDatabase()
        let conv = try await db1.createConversation(title: "Pre-Close Search")
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Persistent indexed knowledge survives application restarts and database close.",
            status: .completed
        )
        try await db1.insertMessage(msg)
        await db1.close()

        // Reopen database connection on same file
        let db2 = try ConversationDatabase(fileURL: dbURL)
        defer { Task { await db2.close() } }

        let results = try await db2.searchMessages(query: "restarts")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, msg.id)
        XCTAssertEqual(results.first?.conversationTitle, "Pre-Close Search")
    }
}


