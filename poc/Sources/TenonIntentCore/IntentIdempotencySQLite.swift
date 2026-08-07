// @domain: intent-bus
//
// The durable half: one SQLite connection behind one lock, implementing the persistence
// contract the store depends on. It knows nothing about ordering or waiting.
import Foundation
import SQLite3
import os

public final class IntentSQLiteIdempotencyPersistence: IntentIdempotencyPersistence {
    /// `NSLock` is the macOS 14-compatible boundary around one SQLite
    /// connection. Every read/write of `database` occurs under this lock.
    /// The persistence object intentionally remains non-`Sendable`: its
    /// connection may only be consumed through one `IntentIdempotencyStore`
    /// actor. The lock also serializes legacy/threaded callers at runtime.
    private final class LockedConnection {
        private let lock = NSLock()
        var database: OpaquePointer?

        init(database: OpaquePointer) {
            self.database = database
        }

        func withLock<T>(_ body: (inout OpaquePointer?) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&database)
        }
    }

    private struct StoredRow {
        let record: IntentIdempotencyRecord
        let processID: UUID
        let claimOwnerID: UUID
        let encodedBytes: Int
        let reservedBytes: Int
    }

    private let connection: LockedConnection

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    public static func inMemory() throws -> IntentSQLiteIdempotencyPersistence {
        try IntentSQLiteIdempotencyPersistence(path: ":memory:")
    }

    private init(path: String) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw IntentIdempotencyError.persistenceFailure
        }

        do {
            try Self.execute(database, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(database, sql: "PRAGMA synchronous=FULL")
            try Self.execute(database, sql: "PRAGMA foreign_keys=ON")
            guard sqlite3_busy_timeout(database, 5000) == SQLITE_OK else {
                throw IntentIdempotencyError.persistenceFailure
            }
            try Self.createSchema(database)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
        connection = LockedConnection(database: database)
    }

    deinit {
        connection.withLock { database in
            if let openDatabase = database {
                sqlite3_close_v2(openDatabase)
                database = nil
            }
        }
    }

    public func prepare(
        limits: IntentIdempotencyLimits,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws {
        try withDatabase { database in
            try Self.transaction(database) {
                try Self.configureLimits(database, limits: limits)
                try Self.rebuildUsage(database)

                for row in try Self.allRows(database) {
                    try Self.validate(row: row, limits: limits)
                    if row.record.expiresAt <= now {
                        try Self.delete(database, key: row.record.claimKey)
                        continue
                    }
                    guard row.record.state != .terminal else {
                        continue
                    }
                    let ownerIsLiveInThisProcess =
                        row.processID == processID
                        && activeClaimOwnerIDs.contains(row.claimOwnerID)
                    guard !ownerIsLiveInThisProcess else {
                        continue
                    }

                    let recovered = Self.recoveredRecord(row.record, now: now)
                    try Self.update(
                        database,
                        row: StoredRow(
                            record: recovered,
                            processID: processID,
                            claimOwnerID: row.claimOwnerID,
                            encodedBytes: Self.encode(recovered).count,
                            reservedBytes: 0
                        )
                    )
                }
                let usage = try Self.usage(database)
                guard usage.entries <= limits.maxEntries,
                      usage.allocatedBytes <= limits.maxEncodedBytes
                else {
                    throw IntentIdempotencyError.capacityExceeded
                }
            }
        }
    }

    public func lookup(
        key: IntentIdempotencyClaimKey,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws -> IntentIdempotencyRecord? {
        try withDatabase { database in
            try Self.transaction(database) {
                guard let row = try Self.row(database, key: key) else {
                    return nil
                }
                let limits = try Self.configuredLimits(database)
                try Self.validate(row: row, limits: limits)
                if row.record.expiresAt <= now {
                    try Self.delete(database, key: key)
                    return nil
                }
                let ownerIsLiveInThisProcess =
                    row.processID == processID
                    && activeClaimOwnerIDs.contains(row.claimOwnerID)
                if row.record.state != .terminal, !ownerIsLiveInThisProcess {
                    let recovered = Self.recoveredRecord(row.record, now: now)
                    try Self.update(
                        database,
                        row: StoredRow(
                            record: recovered,
                            processID: processID,
                            claimOwnerID: row.claimOwnerID,
                            encodedBytes: Self.encode(recovered).count,
                            reservedBytes: 0
                        )
                    )
                    return recovered
                }
                return row.record
            }
        }
    }

    public func claim(
        record: IntentIdempotencyRecord,
        maximumTerminalResultBytes: Int,
        replacingExpiredRequestID: UUID?,
        processID: UUID,
        claimOwnerID: UUID,
        limits: IntentIdempotencyLimits,
        now: Date
    ) throws -> IntentIdempotencyPersistenceClaim {
        try withDatabase { database in
            try Self.transaction(database) {
                try Self.requireConfiguredLimits(database, limits: limits)
                if let existing = try Self.row(database, key: record.claimKey) {
                    try Self.validate(row: existing, limits: limits)
                    guard existing.record.expiresAt <= now else {
                        return .existing(existing.record)
                    }
                    if let replacingExpiredRequestID,
                       existing.record.requestID != replacingExpiredRequestID
                    {
                        return .existing(existing.record)
                    }
                    try Self.delete(database, key: existing.record.claimKey)
                }
                try Self.purgeExpired(database, now: now)

                let encoded = try Self.encode(record)
                let allocation = try Self.checkedAdd(
                    encoded.count,
                    maximumTerminalResultBytes
                )
                let usage = try Self.usage(database)
                guard usage.entries < limits.maxEntries,
                      usage.allocatedBytes <= limits.maxEncodedBytes,
                      allocation <= limits.maxEncodedBytes - usage.allocatedBytes
                else {
                    throw IntentIdempotencyError.capacityExceeded
                }

                try Self.insert(
                    database,
                    row: StoredRow(
                        record: record,
                        processID: processID,
                        claimOwnerID: claimOwnerID,
                        encodedBytes: encoded.count,
                        reservedBytes: maximumTerminalResultBytes
                    ),
                    encoded: encoded
                )
                return .inserted(record)
            }
        }
    }

    public func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try withDatabase { database in
            try Self.transaction(database) {
                guard let existing = try Self.row(database, key: key) else {
                    throw IntentIdempotencyError.claimNotFound
                }
                let limits = try Self.configuredLimits(database)
                try Self.validate(row: existing, limits: limits)
                if existing.record.expiresAt <= now {
                    try Self.delete(database, key: key)
                    throw IntentIdempotencyError.claimNotFound
                }
                guard existing.record.requestID == requestID else {
                    throw IntentIdempotencyError.requestMismatch
                }
                guard existing.processID == processID,
                      existing.claimOwnerID == claimOwnerID
                else {
                    throw IntentIdempotencyError.claimOwnershipMismatch
                }
                guard existing.record.state != .terminal else {
                    throw IntentIdempotencyError.alreadyTerminal
                }
                guard existing.record.state != .running else {
                    return existing.record
                }

                let transitionTime = max(now, existing.record.updatedAt)
                let running = IntentIdempotencyRecord(
                    claimKey: existing.record.claimKey,
                    fingerprint: existing.record.fingerprint,
                    providerID: existing.record.providerID,
                    requestID: existing.record.requestID,
                    state: .running,
                    terminalResult: nil,
                    createdAt: existing.record.createdAt,
                    updatedAt: transitionTime,
                    expiresAt: existing.record.expiresAt
                )
                let encoded = try Self.encode(running)
                guard encoded.count <= existing.encodedBytes + existing.reservedBytes else {
                    throw IntentIdempotencyError.capacityExceeded
                }
                try Self.update(
                    database,
                    row: StoredRow(
                        record: running,
                        processID: existing.processID,
                        claimOwnerID: existing.claimOwnerID,
                        encodedBytes: encoded.count,
                        reservedBytes: existing.reservedBytes
                    ),
                    encoded: encoded
                )
                return running
            }
        }
    }

    public func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try withDatabase { database in
            try Self.transaction(database) {
                guard let existing = try Self.row(database, key: key) else {
                    throw IntentIdempotencyError.claimNotFound
                }
                let limits = try Self.configuredLimits(database)
                try Self.validate(row: existing, limits: limits)
                if existing.record.expiresAt <= now {
                    try Self.delete(database, key: key)
                    throw IntentIdempotencyError.claimNotFound
                }
                guard existing.record.requestID == requestID else {
                    throw IntentIdempotencyError.requestMismatch
                }
                guard existing.processID == processID,
                      existing.claimOwnerID == claimOwnerID
                else {
                    throw IntentIdempotencyError.claimOwnershipMismatch
                }
                guard existing.record.state != .terminal else {
                    throw IntentIdempotencyError.alreadyTerminal
                }

                let resultBytes = try Self.encode(result).count
                guard resultBytes <= existing.reservedBytes else {
                    throw IntentIdempotencyError.terminalResultTooLarge(
                        maximumBytes: existing.reservedBytes
                    )
                }
                let transitionTime = max(now, existing.record.updatedAt)
                let terminal = IntentIdempotencyRecord(
                    claimKey: existing.record.claimKey,
                    fingerprint: existing.record.fingerprint,
                    providerID: existing.record.providerID,
                    requestID: existing.record.requestID,
                    state: .terminal,
                    terminalResult: result,
                    createdAt: existing.record.createdAt,
                    updatedAt: transitionTime,
                    expiresAt: existing.record.expiresAt
                )
                let encoded = try Self.encode(terminal)
                guard encoded.count <= existing.encodedBytes + existing.reservedBytes else {
                    throw IntentIdempotencyError.terminalResultTooLarge(
                        maximumBytes: existing.reservedBytes
                    )
                }
                try Self.update(
                    database,
                    row: StoredRow(
                        record: terminal,
                        processID: existing.processID,
                        claimOwnerID: existing.claimOwnerID,
                        encodedBytes: encoded.count,
                        reservedBytes: 0
                    ),
                    encoded: encoded
                )
                return terminal
            }
        }
    }

    public func purgeExpired(now: Date) throws {
        try withDatabase { database in
            try Self.transaction(database) {
                try Self.purgeExpired(database, now: now)
            }
        }
    }

    public func snapshot() throws -> IntentIdempotencySnapshot {
        try withDatabase { database in
            let rows = try Self.allRows(database)
            let records = rows.map(\.record).sorted {
                if $0.claimKey.principal.id != $1.claimKey.principal.id {
                    return $0.claimKey.principal.id < $1.claimKey.principal.id
                }
                if $0.claimKey.principal.kind != $1.claimKey.principal.kind {
                    return $0.claimKey.principal.kind.rawValue
                        < $1.claimKey.principal.kind.rawValue
                }
                if $0.claimKey.principal.audience != $1.claimKey.principal.audience {
                    return $0.claimKey.principal.audience.rawValue
                        < $1.claimKey.principal.audience.rawValue
                }
                if $0.claimKey.principal.sessionRevision
                    != $1.claimKey.principal.sessionRevision
                {
                    return $0.claimKey.principal.sessionRevision
                        < $1.claimKey.principal.sessionRevision
                }
                if $0.claimKey.intentID != $1.claimKey.intentID {
                    return $0.claimKey.intentID.rawValue < $1.claimKey.intentID.rawValue
                }
                return $0.claimKey.key < $1.claimKey.key
            }
            let usage = try Self.usage(database)
            return IntentIdempotencySnapshot(
                records: records,
                encodedBytes: rows.reduce(0) { $0 + $1.encodedBytes },
                allocatedBytes: usage.allocatedBytes
            )
        }
    }

    private func withDatabase<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try connection.withLock { database in
            guard let database else {
                throw IntentIdempotencyError.persistenceFailure
            }
            return try body(database)
        }
    }

    private static func createSchema(_ database: OpaquePointer) throws {
        try execute(
            database,
            sql: """
            CREATE TABLE IF NOT EXISTS tenon_idempotency_config (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                max_entries INTEGER NOT NULL,
                max_encoded_bytes INTEGER NOT NULL,
                max_key_bytes INTEGER NOT NULL,
                max_retention_ms INTEGER NOT NULL,
                max_terminal_result_bytes INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tenon_idempotency_usage (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                entry_count INTEGER NOT NULL,
                allocated_bytes INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO tenon_idempotency_usage(
                singleton, entry_count, allocated_bytes
            ) VALUES (1, 0, 0);
            CREATE TABLE IF NOT EXISTS tenon_idempotency_claims (
                principal_id TEXT NOT NULL,
                principal_kind TEXT NOT NULL,
                principal_audience TEXT NOT NULL,
                principal_session_revision TEXT NOT NULL,
                intent_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                request_id TEXT NOT NULL,
                state TEXT NOT NULL,
                process_id TEXT NOT NULL,
                claim_owner_id TEXT NOT NULL,
                expires_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                encoded_bytes INTEGER NOT NULL CHECK (encoded_bytes >= 0),
                reserved_bytes INTEGER NOT NULL CHECK (reserved_bytes >= 0),
                record BLOB NOT NULL,
                PRIMARY KEY (
                    principal_id,
                    principal_kind,
                    principal_audience,
                    principal_session_revision,
                    intent_id,
                    idempotency_key
                )
            );
            CREATE INDEX IF NOT EXISTS tenon_idempotency_expiry
                ON tenon_idempotency_claims(expires_at);
            CREATE TRIGGER IF NOT EXISTS tenon_idempotency_usage_insert
            AFTER INSERT ON tenon_idempotency_claims
            BEGIN
                UPDATE tenon_idempotency_usage
                SET entry_count = entry_count + 1,
                    allocated_bytes = allocated_bytes
                        + NEW.encoded_bytes + NEW.reserved_bytes
                WHERE singleton = 1;
            END;
            CREATE TRIGGER IF NOT EXISTS tenon_idempotency_usage_update
            AFTER UPDATE OF encoded_bytes, reserved_bytes ON tenon_idempotency_claims
            BEGIN
                UPDATE tenon_idempotency_usage
                SET allocated_bytes = allocated_bytes
                        - OLD.encoded_bytes - OLD.reserved_bytes
                        + NEW.encoded_bytes + NEW.reserved_bytes
                WHERE singleton = 1;
            END;
            CREATE TRIGGER IF NOT EXISTS tenon_idempotency_usage_delete
            AFTER DELETE ON tenon_idempotency_claims
            BEGIN
                UPDATE tenon_idempotency_usage
                SET entry_count = entry_count - 1,
                    allocated_bytes = allocated_bytes
                        - OLD.encoded_bytes - OLD.reserved_bytes
                WHERE singleton = 1;
            END;
            """
        )
    }

    private static func configureLimits(
        _ database: OpaquePointer,
        limits: IntentIdempotencyLimits
    ) throws {
        if let configured = try optionalConfiguredLimits(database) {
            guard storageConfigurationMatches(configured, limits) else {
                throw IntentIdempotencyError.persistenceConfigurationMismatch
            }
            return
        }
        try withStatement(
            database,
            sql: """
            INSERT INTO tenon_idempotency_config(
                singleton,
                max_entries,
                max_encoded_bytes,
                max_key_bytes,
                max_retention_ms,
                max_terminal_result_bytes
            ) VALUES (1, ?, ?, ?, ?, ?)
            """
        ) { statement in
            try bind(Int64(limits.maxEntries), to: 1, in: statement)
            try bind(Int64(limits.maxEncodedBytes), to: 2, in: statement)
            try bind(Int64(limits.maxKeyBytes), to: 3, in: statement)
            try bind(Int64(limits.maxRetentionMilliseconds), to: 4, in: statement)
            try bind(Int64(limits.maxTerminalResultBytes), to: 5, in: statement)
            try requireDone(statement, database: database)
        }
    }

    private static func requireConfiguredLimits(
        _ database: OpaquePointer,
        limits: IntentIdempotencyLimits
    ) throws {
        guard try storageConfigurationMatches(
            configuredLimits(database),
            limits
        ) else {
            throw IntentIdempotencyError.persistenceConfigurationMismatch
        }
    }

    private static func configuredLimits(
        _ database: OpaquePointer
    ) throws -> IntentIdempotencyLimits {
        guard let limits = try optionalConfiguredLimits(database) else {
            throw IntentIdempotencyError.persistenceFailure
        }
        return limits
    }

    private static func optionalConfiguredLimits(
        _ database: OpaquePointer
    ) throws -> IntentIdempotencyLimits? {
        try withStatement(
            database,
            sql: """
            SELECT
                max_entries,
                max_encoded_bytes,
                max_key_bytes,
                max_retention_ms,
                max_terminal_result_bytes
            FROM tenon_idempotency_config
            WHERE singleton = 1
            """
        ) { statement in
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return nil
            }
            guard step == SQLITE_ROW else {
                throw sqliteError(database)
            }
            return try IntentIdempotencyLimits(
                maxEntries: intColumn(statement, index: 0),
                maxEncodedBytes: intColumn(statement, index: 1),
                maxKeyBytes: intColumn(statement, index: 2),
                maxRetentionMilliseconds: uint64Column(statement, index: 3),
                maxTerminalResultBytes: intColumn(statement, index: 4)
            )
        }
    }

    private static func rebuildUsage(_ database: OpaquePointer) throws {
        try execute(
            database,
            sql: """
            UPDATE tenon_idempotency_usage
            SET entry_count = (
                    SELECT COUNT(*) FROM tenon_idempotency_claims
                ),
                allocated_bytes = COALESCE((
                    SELECT SUM(encoded_bytes + reserved_bytes)
                    FROM tenon_idempotency_claims
                ), 0)
            WHERE singleton = 1
            """
        )
    }

    private static func usage(
        _ database: OpaquePointer
    ) throws -> (entries: Int, allocatedBytes: Int) {
        try withStatement(
            database,
            sql: """
            SELECT entry_count, allocated_bytes
            FROM tenon_idempotency_usage
            WHERE singleton = 1
            """
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(database)
            }
            return try (
                intColumn(statement, index: 0),
                intColumn(statement, index: 1)
            )
        }
    }

    private static func row(
        _ database: OpaquePointer,
        key: IntentIdempotencyClaimKey
    ) throws -> StoredRow? {
        try withStatement(
            database,
            sql: """
            SELECT
                record,
                process_id,
                claim_owner_id,
                encoded_bytes,
                reserved_bytes,
                principal_id,
                principal_kind,
                principal_audience,
                principal_session_revision,
                intent_id,
                idempotency_key,
                request_id,
                state,
                expires_at,
                updated_at
            FROM tenon_idempotency_claims
            WHERE principal_id = ?
                AND principal_kind = ?
                AND principal_audience = ?
                AND principal_session_revision = ?
                AND intent_id = ?
                AND idempotency_key = ?
            """
        ) { statement in
            try bind(key.principal.id, to: 1, in: statement)
            try bind(key.principal.kind.rawValue, to: 2, in: statement)
            try bind(key.principal.audience.rawValue, to: 3, in: statement)
            try bind(String(key.principal.sessionRevision), to: 4, in: statement)
            try bind(key.intentID.rawValue, to: 5, in: statement)
            try bind(key.key, to: 6, in: statement)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return nil
            }
            guard step == SQLITE_ROW else {
                throw sqliteError(database)
            }
            return try storedRow(statement)
        }
    }

    private static func allRows(_ database: OpaquePointer) throws -> [StoredRow] {
        try withStatement(
            database,
            sql: """
            SELECT
                record,
                process_id,
                claim_owner_id,
                encoded_bytes,
                reserved_bytes,
                principal_id,
                principal_kind,
                principal_audience,
                principal_session_revision,
                intent_id,
                idempotency_key,
                request_id,
                state,
                expires_at,
                updated_at
            FROM tenon_idempotency_claims
            """
        ) { statement in
            var rows: [StoredRow] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    try rows.append(storedRow(statement))
                case SQLITE_DONE:
                    return rows
                default:
                    throw sqliteError(database)
                }
            }
        }
    }

    private static func storedRow(_ statement: OpaquePointer) throws -> StoredRow {
        let data = try dataColumn(statement, index: 0)
        let record: IntentIdempotencyRecord
        do {
            record = try IntentIdempotencyCoding.decoder().decode(
                IntentIdempotencyRecord.self,
                from: data
            )
        } catch {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        guard let processID = try UUID(uuidString: textColumn(statement, index: 1)),
              let claimOwnerID = try UUID(uuidString: textColumn(statement, index: 2))
        else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        let indexedPrincipalID = try textColumn(statement, index: 5)
        let indexedPrincipalKind = try textColumn(statement, index: 6)
        let indexedPrincipalAudience = try textColumn(statement, index: 7)
        let indexedPrincipalRevision = try textColumn(statement, index: 8)
        let indexedIntentID = try textColumn(statement, index: 9)
        let indexedKey = try textColumn(statement, index: 10)
        let indexedRequestID = try textColumn(statement, index: 11)
        let indexedState = try textColumn(statement, index: 12)
        let indexedExpiresAt = try doubleColumn(statement, index: 13)
        let indexedUpdatedAt = try doubleColumn(statement, index: 14)
        guard indexedPrincipalID == record.claimKey.principal.id,
              indexedPrincipalKind == record.claimKey.principal.kind.rawValue,
              indexedPrincipalAudience == record.claimKey.principal.audience.rawValue,
              indexedPrincipalRevision == String(record.claimKey.principal.sessionRevision),
              indexedIntentID == record.claimKey.intentID.rawValue,
              indexedKey == record.claimKey.key,
              indexedRequestID == record.requestID.uuidString,
              indexedState == record.state.rawValue,
              indexedExpiresAt == record.expiresAt.timeIntervalSince1970,
              indexedUpdatedAt == record.updatedAt.timeIntervalSince1970
        else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return try StoredRow(
            record: record,
            processID: processID,
            claimOwnerID: claimOwnerID,
            encodedBytes: intColumn(statement, index: 3),
            reservedBytes: intColumn(statement, index: 4)
        )
    }

    private static func insert(
        _ database: OpaquePointer,
        row: StoredRow,
        encoded: Data? = nil
    ) throws {
        let data = try encoded ?? encode(row.record)
        try withStatement(
            database,
            sql: """
            INSERT INTO tenon_idempotency_claims(
                principal_id,
                principal_kind,
                principal_audience,
                principal_session_revision,
                intent_id,
                idempotency_key,
                request_id,
                state,
                process_id,
                claim_owner_id,
                expires_at,
                updated_at,
                encoded_bytes,
                reserved_bytes,
                record
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            try bind(row.record.claimKey.principal.id, to: 1, in: statement)
            try bind(row.record.claimKey.principal.kind.rawValue, to: 2, in: statement)
            try bind(row.record.claimKey.principal.audience.rawValue, to: 3, in: statement)
            try bind(
                String(row.record.claimKey.principal.sessionRevision),
                to: 4,
                in: statement
            )
            try bind(row.record.claimKey.intentID.rawValue, to: 5, in: statement)
            try bind(row.record.claimKey.key, to: 6, in: statement)
            try bind(row.record.requestID.uuidString, to: 7, in: statement)
            try bind(row.record.state.rawValue, to: 8, in: statement)
            try bind(row.processID.uuidString, to: 9, in: statement)
            try bind(row.claimOwnerID.uuidString, to: 10, in: statement)
            try bind(row.record.expiresAt.timeIntervalSince1970, to: 11, in: statement)
            try bind(row.record.updatedAt.timeIntervalSince1970, to: 12, in: statement)
            try bind(Int64(row.encodedBytes), to: 13, in: statement)
            try bind(Int64(row.reservedBytes), to: 14, in: statement)
            try bind(data, to: 15, in: statement)
            try requireDone(statement, database: database)
        }
    }

    private static func update(
        _ database: OpaquePointer,
        row: StoredRow,
        encoded: Data? = nil
    ) throws {
        let data = try encoded ?? encode(row.record)
        try withStatement(
            database,
            sql: """
            UPDATE tenon_idempotency_claims
            SET request_id = ?,
                state = ?,
                process_id = ?,
                claim_owner_id = ?,
                expires_at = ?,
                updated_at = ?,
                encoded_bytes = ?,
                reserved_bytes = ?,
                record = ?
            WHERE principal_id = ?
                AND principal_kind = ?
                AND principal_audience = ?
                AND principal_session_revision = ?
                AND intent_id = ?
                AND idempotency_key = ?
            """
        ) { statement in
            try bind(row.record.requestID.uuidString, to: 1, in: statement)
            try bind(row.record.state.rawValue, to: 2, in: statement)
            try bind(row.processID.uuidString, to: 3, in: statement)
            try bind(row.claimOwnerID.uuidString, to: 4, in: statement)
            try bind(row.record.expiresAt.timeIntervalSince1970, to: 5, in: statement)
            try bind(row.record.updatedAt.timeIntervalSince1970, to: 6, in: statement)
            try bind(Int64(row.encodedBytes), to: 7, in: statement)
            try bind(Int64(row.reservedBytes), to: 8, in: statement)
            try bind(data, to: 9, in: statement)
            try bind(row.record.claimKey.principal.id, to: 10, in: statement)
            try bind(row.record.claimKey.principal.kind.rawValue, to: 11, in: statement)
            try bind(row.record.claimKey.principal.audience.rawValue, to: 12, in: statement)
            try bind(
                String(row.record.claimKey.principal.sessionRevision),
                to: 13,
                in: statement
            )
            try bind(row.record.claimKey.intentID.rawValue, to: 14, in: statement)
            try bind(row.record.claimKey.key, to: 15, in: statement)
            try requireDone(statement, database: database)
            guard sqlite3_changes(database) == 1 else {
                throw IntentIdempotencyError.claimNotFound
            }
        }
    }

    private static func delete(
        _ database: OpaquePointer,
        key: IntentIdempotencyClaimKey
    ) throws {
        try withStatement(
            database,
            sql: """
            DELETE FROM tenon_idempotency_claims
            WHERE principal_id = ?
                AND principal_kind = ?
                AND principal_audience = ?
                AND principal_session_revision = ?
                AND intent_id = ?
                AND idempotency_key = ?
            """
        ) { statement in
            try bind(key.principal.id, to: 1, in: statement)
            try bind(key.principal.kind.rawValue, to: 2, in: statement)
            try bind(key.principal.audience.rawValue, to: 3, in: statement)
            try bind(String(key.principal.sessionRevision), to: 4, in: statement)
            try bind(key.intentID.rawValue, to: 5, in: statement)
            try bind(key.key, to: 6, in: statement)
            try requireDone(statement, database: database)
        }
    }

    private static func purgeExpired(
        _ database: OpaquePointer,
        now: Date
    ) throws {
        try withStatement(
            database,
            sql: """
            DELETE FROM tenon_idempotency_claims
            WHERE expires_at <= ?
            """
        ) { statement in
            try bind(now.timeIntervalSince1970, to: 1, in: statement)
            try requireDone(statement, database: database)
        }
    }

    private static func validate(
        row: StoredRow,
        limits: IntentIdempotencyLimits
    ) throws {
        let record = row.record
        let actualEncodedBytes = try encode(record).count
        let digest = record.fingerprint.inputDigest.hex
        let allocation = try checkedAdd(row.encodedBytes, row.reservedBytes)
        guard !record.claimKey.principal.id.isEmpty,
              !record.claimKey.key.isEmpty,
              record.claimKey.key.utf8.count <= limits.maxKeyBytes,
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              }),
              record.createdAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite,
              record.expiresAt.timeIntervalSince1970.isFinite,
              record.createdAt <= record.updatedAt,
              record.createdAt < record.expiresAt,
              record.expiresAt.timeIntervalSince(record.createdAt)
              <= TimeInterval(limits.maxRetentionMilliseconds) / 1000,
              row.encodedBytes == actualEncodedBytes,
              row.encodedBytes >= 0,
              row.reservedBytes >= 0,
              allocation <= limits.maxEncodedBytes
        else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }

        switch record.state {
        case .claimed, .running:
            guard record.terminalResult == nil,
                  row.reservedBytes > 0,
                  row.reservedBytes <= limits.maxTerminalResultBytes
            else {
                throw IntentIdempotencyError.malformedPersistedRecord
            }
        case .terminal:
            guard let result = record.terminalResult,
                  row.reservedBytes == 0,
                  try encode(result).count <= limits.maxTerminalResultBytes,
                  resultMetadataMatches(result, record: record)
            else {
                throw IntentIdempotencyError.malformedPersistedRecord
            }
        }
    }

    private static func storageConfigurationMatches(
        _ lhs: IntentIdempotencyLimits,
        _ rhs: IntentIdempotencyLimits
    ) -> Bool {
        lhs.maxEntries == rhs.maxEntries
            && lhs.maxEncodedBytes == rhs.maxEncodedBytes
            && lhs.maxKeyBytes == rhs.maxKeyBytes
            && lhs.maxRetentionMilliseconds == rhs.maxRetentionMilliseconds
            && lhs.maxTerminalResultBytes == rhs.maxTerminalResultBytes
    }

    private static func resultMetadataMatches(
        _ result: IntentResult,
        record: IntentIdempotencyRecord
    ) -> Bool {
        switch result {
        case let .success(success):
            success.meta.requestID == record.requestID
                && success.meta.providerID == record.providerID
        case let .failure(failure):
            failure.meta.requestID == record.requestID
                && failure.meta.providerID == record.providerID
        }
    }

    private static func recoveredRecord(
        _ record: IntentIdempotencyRecord,
        now: Date
    ) -> IntentIdempotencyRecord {
        let outcome: IntentOutcome = record.state == .claimed ? .notStarted : .unknown
        let result = IntentResult.failure(
            error: IntentError(
                code: .kernel(.internal),
                details: .object([
                    "reason": .string("interrupted-before-settlement"),
                ]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: outcome
            ),
            requestID: record.requestID,
            providerID: record.providerID
        )
        return IntentIdempotencyRecord(
            claimKey: record.claimKey,
            fingerprint: record.fingerprint,
            providerID: record.providerID,
            requestID: record.requestID,
            state: .terminal,
            terminalResult: result,
            createdAt: record.createdAt,
            updatedAt: max(now, record.updatedAt),
            expiresAt: record.expiresAt
        )
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw IntentIdempotencyError.capacityExceeded
        }
        return sum
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try IntentIdempotencyCoding.encoder().encode(value)
        } catch {
            throw IntentIdempotencyError.persistenceFailure
        }
    }

    private static func transaction<T>(
        _ database: OpaquePointer,
        _ body: () throws -> T
    ) throws -> T {
        try execute(database, sql: "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute(database, sql: "COMMIT")
            return value
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message {
            sqlite3_free(message)
        }
        guard result == SQLITE_OK else {
            throw sqliteError(database)
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
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func requireDone(
        _ statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(database)
        }
    }

    private static func bind(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            sqliteTransientDestructor
        ) == SQLITE_OK else {
            throw IntentIdempotencyError.persistenceFailure
        }
    }

    private static func bind(
        _ value: Int64,
        to index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw IntentIdempotencyError.persistenceFailure
        }
    }

    private static func bind(
        _ value: Double,
        to index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw IntentIdempotencyError.persistenceFailure
        }
    }

    private static func bind(
        _ value: Data,
        to index: Int32,
        in statement: OpaquePointer
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransientDestructor
            )
        }
        guard result == SQLITE_OK else {
            throw IntentIdempotencyError.persistenceFailure
        }
    }

    private static func intColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) throws -> Int {
        let value = sqlite3_column_int64(statement, index)
        guard let converted = Int(exactly: value), converted >= 0 else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return converted
    }

    private static func uint64Column(
        _ statement: OpaquePointer,
        index: Int32
    ) throws -> UInt64 {
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return UInt64(value)
    }

    private static func doubleColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) throws -> Double {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        let value = sqlite3_column_double(statement, index)
        guard value.isFinite else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return value
    }

    private static func textColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return String(
            cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self)
        )
    }

    private static func dataColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return Data(bytes: bytes, count: count)
    }

    private static func sqliteError(_ database: OpaquePointer) -> Error {
        _ = sqlite3_errmsg(database)
        return IntentIdempotencyError.persistenceFailure
    }
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
