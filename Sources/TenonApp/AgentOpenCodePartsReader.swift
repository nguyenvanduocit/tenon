// @domain: agent-lens
import CryptoKit
import Foundation
import SQLite3

/// Reads one opencode session's parts from its shared SQLite database, ordered by creation
/// time. Both the live lens and a recorded-session pane share this path: opencode keeps every
/// session's parts in one database, so the session id — not a file — is what selects a
/// transcript, and the enclosing message's `role` is what tells a text part apart from a
/// question.
///
/// The database is opened read-only; opencode owns the writer and the WAL, and a reader from a
/// second process is exactly the access SQLite's journaling is designed to admit.
actor AgentOpenCodePartsReader {
    static let defaultPollInterval: Duration = .milliseconds(180)
    private static let bufferCapacity = 1_024

    private struct PartRow {
        let id: String
        let timeCreated: Int64
        let data: String
        let messageData: String
    }

    /// `initialPartLimit` bounds the initial read for a live attachment mid-session (the most
    /// recent N parts), which is the same window the JSONL tailer enforces in bytes. A nil
    /// limit reads the whole session — the recorded-session pane's entire reason to exist.
    func events(
        dbURL: URL,
        sessionID: String,
        initialPartLimit: Int? = nil,
        pollInterval: Duration = AgentOpenCodePartsReader.defaultPollInterval
    ) -> AsyncThrowingStream<AgentLensEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.bufferCapacity)) {
            continuation in
            let task = Task {
                await self.read(
                    dbURL: dbURL,
                    sessionID: sessionID,
                    initialPartLimit: initialPartLimit,
                    pollInterval: pollInterval,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func read(
        dbURL: URL,
        sessionID: String,
        initialPartLimit: Int?,
        pollInterval: Duration,
        continuation: AsyncThrowingStream<AgentLensEvent, any Error>.Continuation
    ) async {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            continuation.finish()
            return
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 5_000)

        let decoder = AgentTranscriptDecoder(provider: .opencode)
        let location = dbURL.path
        var lastTime: Int64 = -1
        var lastID = ""
        var didReportMalformed = false

        func yield(_ event: AgentLensEvent) -> Bool {
            switch continuation.yield(event) {
            case .enqueued:
                return true
            case .dropped:
                continuation.finish(throwing: AgentLensSourceError.overflow)
                return false
            case .terminated:
                return false
            @unknown default:
                continuation.finish(throwing: AgentLensSourceError.overflow)
                return false
            }
        }

        func reportMalformed() -> Bool {
            guard !didReportMalformed else { return true }
            didReportMalformed = true
            let diagnostic = AgentLensDiagnostic(
                id: "malformed-opencode-part",
                severity: .warning,
                message: "An opencode part could not be parsed and was ignored",
                evidence: AgentEvidence.terminalInference("\(location):part")
            )
            return yield(.diagnostic(diagnostic))
        }

        // A decoded row yields its events and advances the poll cursor. Returns false when the
        // stream has ended.
        func consume(_ row: PartRow) -> Bool {
            // Rows arrive in ascending (time, id) order, so the row being consumed is the
            // newest cursor position by construction.
            lastTime = row.timeCreated
            lastID = row.id
            guard let partData = row.data.data(using: .utf8),
                  let part = try? JSONSerialization.jsonObject(with: partData)
                    as? [String: Any]
            else { return reportMalformed() }
            let evidence = Self.evidence(
                location: location,
                timeCreated: row.timeCreated,
                data: partData
            )
            let events = decoder.decodeOpenCode(
                part,
                role: Self.role(in: row.messageData),
                evidence: evidence,
                byteOffset: UInt64(row.timeCreated)
            )
            for event in events where !yield(event) { return false }
            return true
        }

        // Initial window.
        let initialRows: [PartRow]
        do {
            initialRows = try Self.rows(
                database,
                sessionID: sessionID,
                limit: initialPartLimit
            )
        } catch {
            continuation.finish()
            return
        }

        if let limit = initialPartLimit,
           let total = try? Self.count(database, sessionID: sessionID),
           total > limit
        {
            let anchor = initialRows.first
            if let anchor {
                let evidence = Self.evidence(
                    location: location,
                    timeCreated: anchor.timeCreated,
                    data: anchor.data.data(using: .utf8) ?? Data()
                )
                guard yield(.earlierHistory(evidence)) else { return }
            }
        }

        for row in initialRows where !consume(row) { return }

        // Poll for parts the live session is still writing.
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
            let fresh: [PartRow]
            do {
                fresh = try Self.rows(
                    database,
                    sessionID: sessionID,
                    afterTime: lastTime,
                    afterID: lastID
                )
            } catch {
                break
            }
            for row in fresh where !consume(row) { return }
        }
        continuation.finish()
    }

    private static func role(in messageData: String) -> AgentMessageRole? {
        guard let data = messageData.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let role = message["role"] as? String
        else { return nil }
        switch role {
        case "assistant": return .assistant
        case "user": return .user
        case "system": return .system
        case "developer": return .developer
        default: return nil
        }
    }

    private static func evidence(location: String, timeCreated: Int64, data: Data) -> AgentEvidence {
        AgentEvidence(
            source: .transcript,
            authority: .reported,
            location: location,
            byteOffset: UInt64(timeCreated),
            fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            capturedAt: Date(timeIntervalSince1970: Double(timeCreated) / 1_000),
            freshness: .current
        )
    }

    // MARK: - Queries

    private static func rows(
        _ database: OpaquePointer,
        sessionID: String,
        limit: Int?
    ) throws -> [PartRow] {
        let sql = """
            SELECT p.id, p.time_created, p.data, m.data
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ?1
            ORDER BY p.time_created DESC, p.id DESC
            LIMIT ?2
            """
        var rows: [PartRow] = []
        try withStatement(database, sql: sql) { statement in
            try bind(sessionID, to: 1, in: statement)
            try bind(Int64(limit ?? -1), to: 2, in: statement)
            rows = try collect(statement, database: database)
        }
        return Array(rows.reversed())
    }

    private static func rows(
        _ database: OpaquePointer,
        sessionID: String,
        afterTime: Int64,
        afterID: String
    ) throws -> [PartRow] {
        let sql = """
            SELECT p.id, p.time_created, p.data, m.data
            FROM part p
            JOIN message m ON m.id = p.message_id
            WHERE p.session_id = ?1 AND (p.time_created, p.id) > (?2, ?3)
            ORDER BY p.time_created ASC, p.id ASC
            """
        return try withStatement(database, sql: sql) { statement in
            try bind(sessionID, to: 1, in: statement)
            try bind(afterTime, to: 2, in: statement)
            try bind(afterID, to: 3, in: statement)
            return try collect(statement, database: database)
        }
    }

    private static func count(_ database: OpaquePointer, sessionID: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM part WHERE session_id = ?1"
        return try withStatement(database, sql: sql) { statement in
            try bind(sessionID, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw AgentOpenCodePartsError.queryFailed
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private static func collect(
        _ statement: OpaquePointer,
        database: OpaquePointer
    ) throws -> [PartRow] {
        var rows: [PartRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(
                    PartRow(
                        id: try textColumn(statement, index: 0),
                        timeCreated: sqlite3_column_int64(statement, 1),
                        data: try textColumn(statement, index: 2),
                        messageData: try textColumn(statement, index: 3)
                    )
                )
            case SQLITE_DONE:
                return rows
            default:
                throw AgentOpenCodePartsError.queryFailed
            }
        }
    }

    private static func withStatement<T>(
        _ database: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw AgentOpenCodePartsError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            sqliteTransientDestructor
        ) == SQLITE_OK else {
            throw AgentOpenCodePartsError.queryFailed
        }
    }

    private static func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw AgentOpenCodePartsError.queryFailed
        }
    }

    private static func textColumn(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw AgentOpenCodePartsError.queryFailed
        }
        return String(
            cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self)
        )
    }
}

enum AgentOpenCodePartsError: Error, Sendable {
    case queryFailed
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
