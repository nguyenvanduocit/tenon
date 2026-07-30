import Foundation
import SQLite3
import os

/// One deterministic wire representation for every durable idempotency value.
///
/// Dates use the exact IEEE-754 bit pattern of `timeIntervalSinceReferenceDate` encoded
/// as sixteen hexadecimal characters. Unlike a JSON number, that representation has a
/// fixed width: advancing `updatedAt` can never consume terminal-result reservation bytes.
enum IntentIdempotencyCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                String(
                    format: "%016llx",
                    date.timeIntervalSinceReferenceDate.bitPattern
                )
            )
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            guard encoded.utf8.count == 16,
                  let bits = UInt64(encoded, radix: 16)
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "an idempotency date must be sixteen hexadecimal characters"
                )
            }
            let interval = Double(bitPattern: bits)
            guard interval.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "an idempotency date must be finite"
                )
            }
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        return decoder
    }
}

/// Process-local liveness for independently constructed stores sharing one durable database.
///
/// SQLite can identify a crashed process from its persisted process UUID, but an app may
/// rebuild its kernel without restarting the OS process. Tracking live claim-owner UUIDs
/// lets a replacement store recover rows left by a deallocated store while preserving rows
/// that another live store in the same process still owns.
private final class IntentIdempotencyOwnerLease: Sendable {
    private static let owners = OSAllocatedUnfairLock(
        initialState: [UUID: Set<UUID>]()
    )

    let processID: UUID
    let claimOwnerID: UUID

    init(processID: UUID, claimOwnerID: UUID) {
        self.processID = processID
        self.claimOwnerID = claimOwnerID
        Self.owners.withLock { owners in
            _ = owners[processID, default: []].insert(claimOwnerID)
        }
    }

    deinit {
        Self.owners.withLock { owners in
            owners[processID]?.remove(claimOwnerID)
            if owners[processID]?.isEmpty == true {
                owners.removeValue(forKey: processID)
            }
        }
    }

    var activeClaimOwnerIDs: Set<UUID> {
        Self.owners.withLock { $0[processID] ?? [] }
    }
}

public struct IntentIdempotencyClaimKey: Sendable, Equatable, Hashable, Codable {
    public let principal: IntentPrincipal
    public let intentID: IntentID
    public let key: String

    public init(principal: IntentPrincipal, intentID: IntentID, key: String) throws {
        guard !principal.id.isEmpty, !key.isEmpty else {
            throw IntentIdempotencyError.invalidKey
        }
        self.principal = principal
        self.intentID = intentID
        self.key = key
    }
}

public struct IntentIdempotencyFingerprint: Sendable, Equatable, Codable {
    public let inputDigest: IntentDigest
    public let explicitTarget: ProviderID?

    public init(inputDigest: IntentDigest, explicitTarget: ProviderID?) {
        self.inputDigest = inputDigest
        self.explicitTarget = explicitTarget
    }
}

public enum IntentIdempotencyState: String, Sendable, Equatable, Codable {
    case claimed
    case running
    case terminal
}

public struct IntentIdempotencyRecord: Sendable, Equatable, Codable {
    public let claimKey: IntentIdempotencyClaimKey
    public let fingerprint: IntentIdempotencyFingerprint
    public let providerID: ProviderID
    public let requestID: UUID
    public let state: IntentIdempotencyState
    public let terminalResult: IntentResult?
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date

    public init(
        claimKey: IntentIdempotencyClaimKey,
        fingerprint: IntentIdempotencyFingerprint,
        providerID: ProviderID,
        requestID: UUID,
        state: IntentIdempotencyState,
        terminalResult: IntentResult?,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date
    ) {
        self.claimKey = claimKey
        self.fingerprint = fingerprint
        self.providerID = providerID
        self.requestID = requestID
        self.state = state
        self.terminalResult = terminalResult
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

public struct IntentIdempotencyLimits: Sendable, Equatable {
    public static let hardMaximumTerminalResultBytes =
        IntentValueLimits.hardMaximumEncodedBytes + 4096

    public let maxEntries: Int
    public let maxEncodedBytes: Int
    public let maxKeyBytes: Int
    public let maxRetentionMilliseconds: UInt64
    public let maxTerminalResultBytes: Int
    public let maxWaitersPerClaim: Int
    public let maxTotalWaiters: Int
    public let maximumJoinWaitMilliseconds: UInt64

    public init(
        maxEntries: Int = 4096,
        maxEncodedBytes: Int = 16 * 1024 * 1024,
        maxKeyBytes: Int = 256,
        maxRetentionMilliseconds: UInt64 = 7 * 24 * 60 * 60 * 1000,
        maxTerminalResultBytes: Int = Self.hardMaximumTerminalResultBytes,
        maxWaitersPerClaim: Int = 128,
        maxTotalWaiters: Int = 4096,
        maximumJoinWaitMilliseconds: UInt64 = 30000
    ) throws {
        guard maxEntries > 0,
              maxEncodedBytes > 0,
              maxKeyBytes > 0,
              maxRetentionMilliseconds > 0,
              maxRetentionMilliseconds <= UInt64(Int64.max),
              maxTerminalResultBytes > 0,
              maxTerminalResultBytes <= Self.hardMaximumTerminalResultBytes,
              maxWaitersPerClaim > 0,
              maxTotalWaiters > 0,
              maxWaitersPerClaim <= maxTotalWaiters,
              maximumJoinWaitMilliseconds > 0,
              maximumJoinWaitMilliseconds <= UInt64(Int64.max)
        else {
            throw IntentIdempotencyError.invalidLimits
        }
        self.maxEntries = maxEntries
        self.maxEncodedBytes = maxEncodedBytes
        self.maxKeyBytes = maxKeyBytes
        self.maxRetentionMilliseconds = maxRetentionMilliseconds
        self.maxTerminalResultBytes = maxTerminalResultBytes
        self.maxWaitersPerClaim = maxWaitersPerClaim
        self.maxTotalWaiters = maxTotalWaiters
        self.maximumJoinWaitMilliseconds = maximumJoinWaitMilliseconds
    }
}

public enum IntentIdempotencyDecision: Sendable, Equatable {
    case execute(requestID: UUID, providerID: ProviderID)
    case join(requestID: UUID, providerID: ProviderID)
    case replay(IntentResult)
    case conflict(existingRequestID: UUID, providerID: ProviderID)
}

public struct IntentIdempotencySnapshot: Sendable, Equatable {
    public let records: [IntentIdempotencyRecord]
    public let encodedBytes: Int
    public let allocatedBytes: Int
    public let cachedEntries: Int
    public let cachedEncodedBytes: Int
    public let cachedAllocatedBytes: Int

    public init(
        records: [IntentIdempotencyRecord],
        encodedBytes: Int,
        allocatedBytes: Int,
        cachedEntries: Int = 0,
        cachedEncodedBytes: Int = 0,
        cachedAllocatedBytes: Int = 0
    ) {
        self.records = records
        self.encodedBytes = encodedBytes
        self.allocatedBytes = allocatedBytes
        self.cachedEntries = cachedEntries
        self.cachedEncodedBytes = cachedEncodedBytes
        self.cachedAllocatedBytes = cachedAllocatedBytes
    }
}

public enum IntentIdempotencyError: Error, Sendable, Equatable {
    case invalidKey
    case invalidLimits
    case retentionOutOfRange(maximumMilliseconds: UInt64)
    case terminalResultReservationOutOfRange(maximumBytes: Int)
    case terminalResultReservationTooSmall(minimumBytes: Int)
    case terminalResultTooLarge(maximumBytes: Int)
    case capacityExceeded
    case waiterCapacityExceeded
    case waiterDeadlineExceeded
    case claimNotFound
    case requestMismatch
    case claimOwnershipMismatch
    case alreadyTerminal
    case malformedPersistedRecord
    case persistenceConfigurationMismatch
    case persistenceFailure
}

public enum IntentIdempotencyPersistenceClaim: Sendable, Equatable {
    case inserted(IntentIdempotencyRecord)
    case existing(IntentIdempotencyRecord)
}

/// Transactional storage contract for retained idempotency claims.
///
/// Implementations must make `claim` atomic across every connection that can
/// reach the same durable store. Tenon's shipped implementation uses SQLite
/// WAL, a composite primary key, and `BEGIN IMMEDIATE`.
///
/// A throwing `claim` has a strict transaction postcondition: the proposed
/// record was not committed and is not visible to any connection. Once a
/// proposed record becomes durable, the implementation must return either
/// `.inserted` or `.existing`; it must not throw after that commit. The store
/// relies on this boundary to roll back its matching in-memory reservation
/// without creating an ownerless durable claim.
///
/// `prepare` receives the complete process-local set of live claim owners,
/// including the store being prepared. A persistence adapter may recover a
/// nonterminal row only when it belongs to another process or its owner is
/// absent from this set. This preserves concurrent live stores while allowing
/// an in-process kernel reconstruction to recover its predecessor's orphaned
/// claims.
public protocol IntentIdempotencyPersistence {
    func prepare(
        limits: IntentIdempotencyLimits,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws

    func lookup(
        key: IntentIdempotencyClaimKey,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws -> IntentIdempotencyRecord?

    func claim(
        record: IntentIdempotencyRecord,
        maximumTerminalResultBytes: Int,
        replacingExpiredRequestID: UUID?,
        processID: UUID,
        claimOwnerID: UUID,
        limits: IntentIdempotencyLimits,
        now: Date
    ) throws -> IntentIdempotencyPersistenceClaim

    func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord

    func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord

    func purgeExpired(now: Date) throws
    func snapshot() throws -> IntentIdempotencySnapshot
}

public actor IntentIdempotencyStore {
    private struct Waiter {
        let continuation: CheckedContinuation<IntentResult, any Error>
        let deadlineTask: Task<Void, Never>
    }

    private struct CachedRecord {
        let record: IntentIdempotencyRecord
        let encodedBytes: Int
        let allocatedBytes: Int
    }

    private struct ExpiredFallbackRelease: Codable {
        let key: IntentIdempotencyClaimKey
        let requestID: UUID
    }

    private struct CachedRelease {
        let release: ExpiredFallbackRelease
        let encodedBytes: Int
    }

    private struct ClaimCacheCheckpoint {
        let ownedClaim: CachedRecord?
        let expiredRelease: CachedRelease?
        let encodedBytes: Int
        let allocatedBytes: Int
    }

    private enum CacheLocation {
        case owned
        case volatile
    }

    private static let currentProcessID = UUID()

    private let limits: IntentIdempotencyLimits
    private let persistence: any IntentIdempotencyPersistence
    private let processID: UUID
    private let claimOwnerID: UUID
    private let ownerLease: IntentIdempotencyOwnerLease
    private var waiters: [IntentIdempotencyClaimKey: [UUID: Waiter]] = [:]
    private var settlementMonitors: [IntentIdempotencyClaimKey: Task<Void, Never>] = [:]
    private var totalWaiters = 0
    private var ownedClaims: [IntentIdempotencyClaimKey: CachedRecord] = [:]
    private var volatileTerminalResults: [IntentIdempotencyClaimKey: CachedRecord] = [:]
    private var expiredFallbackReleases: [IntentIdempotencyClaimKey: CachedRelease] = [:]
    private var cachedEncodedBytes = 0
    private var cachedAllocatedBytes = 0

    public init(
        limits: IntentIdempotencyLimits,
        persistence: sending any IntentIdempotencyPersistence,
        processID: UUID? = nil,
        claimOwnerID: UUID? = nil,
        now: Date = Date()
    ) throws {
        let resolvedProcessID = processID ?? Self.currentProcessID
        let resolvedClaimOwnerID = claimOwnerID ?? UUID()
        let ownerLease = IntentIdempotencyOwnerLease(
            processID: resolvedProcessID,
            claimOwnerID: resolvedClaimOwnerID
        )
        self.limits = limits
        self.persistence = persistence
        self.processID = resolvedProcessID
        self.claimOwnerID = resolvedClaimOwnerID
        self.ownerLease = ownerLease
        try persistence.prepare(
            limits: limits,
            processID: self.processID,
            activeClaimOwnerIDs: ownerLease.activeClaimOwnerIDs,
            now: now
        )
    }

    public func claim(
        key: IntentIdempotencyClaimKey,
        fingerprint: IntentIdempotencyFingerprint,
        providerID: ProviderID,
        requestID: UUID,
        retentionMilliseconds: UInt64,
        maximumTerminalResultBytes: Int? = nil,
        now: Date = Date()
    ) throws -> IntentIdempotencyDecision {
        try expireVolatileTerminals(now: now)
        expireOwnedClaims(now: now)
        guard key.key.utf8.count <= limits.maxKeyBytes else {
            throw IntentIdempotencyError.invalidKey
        }
        guard retentionMilliseconds > 0,
              retentionMilliseconds <= limits.maxRetentionMilliseconds
        else {
            throw IntentIdempotencyError.retentionOutOfRange(
                maximumMilliseconds: limits.maxRetentionMilliseconds
            )
        }

        let resultReservation = maximumTerminalResultBytes ?? limits.maxTerminalResultBytes
        guard resultReservation > 0,
              resultReservation <= limits.maxTerminalResultBytes,
              resultReservation <= IntentIdempotencyLimits.hardMaximumTerminalResultBytes
        else {
            throw IntentIdempotencyError.terminalResultReservationOutOfRange(
                maximumBytes: limits.maxTerminalResultBytes
            )
        }

        if let volatile = volatileTerminalResults[key] {
            return try decisionForVolatile(
                volatile.record,
                fingerprint: fingerprint
            )
        }
        if let durable = try durableLookup(key: key, now: now) {
            return decision(for: durable, fingerprint: fingerprint)
        }

        let retention = TimeInterval(retentionMilliseconds) / 1000
        let record = IntentIdempotencyRecord(
            claimKey: key,
            fingerprint: fingerprint,
            providerID: providerID,
            requestID: requestID,
            state: .claimed,
            terminalResult: nil,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(retention)
        )
        let minimumReservation = try Self.minimumTerminalResultReservation(
            for: record
        )
        guard resultReservation >= minimumReservation else {
            throw IntentIdempotencyError.terminalResultReservationTooSmall(
                minimumBytes: minimumReservation
            )
        }
        let cachedClaim = try makeCachedRecord(
            record,
            allocatedBytes: Self.checkedAdd(
                Self.encodedBytes(of: record),
                resultReservation
            )
        )
        let replacingExpiredRequestID =
            expiredFallbackReleases[key]?.release.requestID
        let cacheCheckpoint = try stageClaimCacheReservation(
            cachedClaim,
            key: key
        )
        do {
            let persisted = try persistence.claim(
                record: record,
                maximumTerminalResultBytes: resultReservation,
                replacingExpiredRequestID: replacingExpiredRequestID,
                processID: processID,
                claimOwnerID: claimOwnerID,
                limits: limits,
                now: now
            )
            switch persisted {
            case .inserted:
                // Cache admission was proven before the durable transaction. No throwing
                // operation may follow the commit on this path.
                return .execute(requestID: requestID, providerID: providerID)
            case let .existing(existing):
                restoreClaimCache(cacheCheckpoint, key: key)
                // A durable current record supersedes an expired volatile-release marker.
                removeExpiredFallbackRelease(key: key)
                return decision(for: existing, fingerprint: fingerprint)
            }
        } catch {
            restoreClaimCache(cacheCheckpoint, key: key)
            throw error
        }
    }

    public func lookup(
        key: IntentIdempotencyClaimKey,
        fingerprint: IntentIdempotencyFingerprint,
        now: Date = Date()
    ) throws -> IntentIdempotencyDecision? {
        try expireVolatileTerminals(now: now)
        if expiredFallbackReleases[key] != nil {
            // A volatile terminal crossed its retention boundary after both
            // durable settlement attempts failed. This marker is not a
            // retained result: it carries the exact request ID that `claim`
            // must atomically replace in persistence. Returning nil lets the
            // dispatcher's normal lookup-before-claim path perform that
            // fenced replacement.
            return nil
        }
        if let volatile = volatileTerminalResults[key] {
            return try decisionForVolatile(
                volatile.record,
                fingerprint: fingerprint
            )
        }
        guard let existing = try durableLookup(key: key, now: now) else {
            return nil
        }
        return decision(for: existing, fingerprint: fingerprint)
    }

    public func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        now: Date = Date()
    ) throws {
        try expireVolatileTerminals(now: now)
        guard volatileTerminalResults[key] == nil,
              expiredFallbackReleases[key] == nil
        else {
            throw IntentIdempotencyError.alreadyTerminal
        }
        guard let owned = ownedClaims[key]?.record else {
            throw IntentIdempotencyError.claimOwnershipMismatch
        }
        guard owned.requestID == requestID else {
            throw IntentIdempotencyError.requestMismatch
        }
        let running = try persistence.markRunning(
            key: key,
            requestID: requestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
        if let cached = ownedClaims[key] {
            let updated = try makeCachedRecord(
                running,
                allocatedBytes: cached.allocatedBytes
            )
            try replaceCachedRecord(
                at: .owned,
                key: key,
                with: updated
            )
        }
    }

    public func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        now: Date = Date()
    ) throws {
        try expireVolatileTerminals(now: now)
        guard volatileTerminalResults[key] == nil,
              expiredFallbackReleases[key] == nil
        else {
            throw IntentIdempotencyError.alreadyTerminal
        }
        guard let owned = ownedClaims[key]?.record else {
            throw IntentIdempotencyError.claimOwnershipMismatch
        }
        guard owned.requestID == requestID else {
            throw IntentIdempotencyError.requestMismatch
        }

        let existing: IntentIdempotencyRecord?
        do {
            existing = try durableLookup(key: key, now: now)
        } catch {
            guard owned.state != .terminal else {
                throw IntentIdempotencyError.alreadyTerminal
            }
            try failSettlement(
                key: key,
                existing: owned,
                underlyingError: error,
                now: now
            )
        }
        guard let existing else {
            removeCachedRecord(at: .owned, key: key)
            throw IntentIdempotencyError.claimNotFound
        }
        guard existing.requestID == requestID else {
            removeCachedRecord(at: .owned, key: key)
            throw IntentIdempotencyError.requestMismatch
        }
        guard existing.state != .terminal else {
            removeCachedRecord(at: .owned, key: key)
            throw IntentIdempotencyError.alreadyTerminal
        }

        let canonical = Self.canonicalized(result, for: existing)
        do {
            _ = try persistence.settle(
                key: key,
                requestID: requestID,
                result: canonical,
                processID: processID,
                claimOwnerID: claimOwnerID,
                now: now
            )
            removeCachedRecord(at: .owned, key: key)
            finishWaiters(key: key, result: canonical)
        } catch let error as IntentIdempotencyError
            where error == .claimNotFound
            || error == .requestMismatch
            || error == .alreadyTerminal
        {
            throw error
        } catch {
            try failSettlement(
                key: key,
                existing: existing,
                underlyingError: error,
                now: now
            )
        }
    }

    public func waitForResult(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> IntentResult {
        let now = Date()
        try expireVolatileTerminals(now: now)
        guard expiredFallbackReleases[key] == nil else {
            throw IntentIdempotencyError.claimNotFound
        }
        if let volatile = volatileTerminalResults[key] {
            guard volatile.record.requestID == requestID else {
                throw IntentIdempotencyError.requestMismatch
            }
            return try terminalResult(from: volatile.record)
        }
        guard let existing = try durableLookup(key: key, now: now) else {
            throw IntentIdempotencyError.claimNotFound
        }
        guard existing.requestID == requestID else {
            throw IntentIdempotencyError.requestMismatch
        }
        if let terminal = existing.terminalResult {
            return terminal
        }
        try Task.checkCancellation()

        let existingWaiters = waiters[key]?.count ?? 0
        guard existingWaiters < limits.maxWaitersPerClaim,
              totalWaiters < limits.maxTotalWaiters
        else {
            throw IntentIdempotencyError.waiterCapacityExceeded
        }

        let clock = ContinuousClock()
        let maximumDeadline = clock.now.advanced(
            by: .milliseconds(Int64(limits.maximumJoinWaitMilliseconds))
        )
        let effectiveDeadline = deadline.map { min($0, maximumDeadline) } ?? maximumDeadline
        guard effectiveDeadline > clock.now else {
            throw IntentIdempotencyError.waiterDeadlineExceeded
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { @concurrent [store = self] in
                    do {
                        try await ContinuousClock().sleep(until: effectiveDeadline)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await store.expireWaiter(key: key, waiterID: waiterID)
                }
                waiters[key, default: [:]][waiterID] = Waiter(
                    continuation: continuation,
                    deadlineTask: deadlineTask
                )
                totalWaiters += 1
                startSettlementMonitorIfNeeded(
                    key: key,
                    requestID: requestID
                )
            }
        } onCancel: {
            Task { @concurrent [store = self] in
                await store.cancelWaiter(key: key, waiterID: waiterID)
            }
        }
    }

    public func purgeExpired(now: Date = Date()) throws {
        try expireVolatileTerminals(now: now)
        expireOwnedClaims(now: now)
        try persistence.purgeExpired(now: now)
    }

    public func snapshot() throws -> IntentIdempotencySnapshot {
        let now = Date()
        try expireVolatileTerminals(now: now)
        expireOwnedClaims(now: now)
        let persisted = try persistence.snapshot()
        return IntentIdempotencySnapshot(
            records: persisted.records,
            encodedBytes: persisted.encodedBytes,
            allocatedBytes: persisted.allocatedBytes,
            cachedEntries: ownedClaims.count
                + volatileTerminalResults.count
                + expiredFallbackReleases.count,
            cachedEncodedBytes: cachedEncodedBytes,
            cachedAllocatedBytes: cachedAllocatedBytes
        )
    }

    private func decision(
        for existing: IntentIdempotencyRecord,
        fingerprint: IntentIdempotencyFingerprint
    ) -> IntentIdempotencyDecision {
        guard existing.fingerprint == fingerprint else {
            return .conflict(
                existingRequestID: existing.requestID,
                providerID: existing.providerID
            )
        }
        if let result = existing.terminalResult {
            return .replay(result)
        }
        return .join(
            requestID: existing.requestID,
            providerID: existing.providerID
        )
    }

    private func durableLookup(
        key: IntentIdempotencyClaimKey,
        now: Date
    ) throws -> IntentIdempotencyRecord? {
        try persistence.lookup(
            key: key,
            processID: processID,
            activeClaimOwnerIDs: ownerLease.activeClaimOwnerIDs,
            now: now
        )
    }

    private func decisionForVolatile(
        _ record: IntentIdempotencyRecord,
        fingerprint: IntentIdempotencyFingerprint
    ) throws -> IntentIdempotencyDecision {
        guard record.fingerprint == fingerprint else {
            return .conflict(
                existingRequestID: record.requestID,
                providerID: record.providerID
            )
        }
        return try .replay(terminalResult(from: record))
    }

    private func failSettlement(
        key: IntentIdempotencyClaimKey,
        existing: IntentIdempotencyRecord,
        underlyingError: any Error,
        now: Date
    ) throws -> Never {
        let fallback = Self.persistenceFailureResult(for: existing)

        // A small canonical fallback often remains persistable when the
        // original failure was an oversized terminal result. A real I/O
        // failure may reject this second write too; current waiters still
        // complete exactly once and restart recovery remains conservative.
        if let terminal = try? persistence.settle(
            key: key,
            requestID: existing.requestID,
            result: fallback,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        ) {
            removeCachedRecord(at: .owned, key: key)
            removeCachedRecord(at: .volatile, key: key)
            removeExpiredFallbackRelease(key: key)
            _ = terminal
        } else {
            let terminal = IntentIdempotencyRecord(
                claimKey: existing.claimKey,
                fingerprint: existing.fingerprint,
                providerID: existing.providerID,
                requestID: existing.requestID,
                state: .terminal,
                terminalResult: fallback,
                createdAt: existing.createdAt,
                updatedAt: max(now, existing.updatedAt),
                expiresAt: existing.expiresAt
            )
            removeExpiredFallbackRelease(key: key)
            if terminal.expiresAt > now {
                guard let ownedAllocation = ownedClaims[key]?.allocatedBytes else {
                    finishWaiters(key: key, result: fallback)
                    throw IntentIdempotencyError.claimOwnershipMismatch
                }
                let cached = try makeCachedRecord(
                   terminal,
                   allocatedBytes: ownedAllocation
                )
                try moveOwnedClaimToVolatile(key: key, terminal: cached)
            } else {
                removeCachedRecord(at: .owned, key: key)
            }
        }
        finishWaiters(key: key, result: fallback)

        if let idempotencyError = underlyingError as? IntentIdempotencyError {
            throw idempotencyError
        }
        throw IntentIdempotencyError.persistenceFailure
    }

    private func terminalResult(
        from record: IntentIdempotencyRecord
    ) throws -> IntentResult {
        guard record.state == .terminal, let result = record.terminalResult else {
            throw IntentIdempotencyError.malformedPersistedRecord
        }
        return result
    }

    private func makeCachedRecord(
        _ record: IntentIdempotencyRecord,
        allocatedBytes: Int
    ) throws -> CachedRecord {
        let encodedBytes = try Self.encodedBytes(of: record)
        guard encodedBytes <= allocatedBytes,
              allocatedBytes <= limits.maxEncodedBytes
        else {
            throw IntentIdempotencyError.capacityExceeded
        }
        return CachedRecord(
            record: record,
            encodedBytes: encodedBytes,
            allocatedBytes: allocatedBytes
        )
    }

    private func replaceCachedRecord(
        at location: CacheLocation,
        key: IntentIdempotencyClaimKey,
        with record: CachedRecord
    ) throws {
        let replaced = switch location {
        case .owned:
            ownedClaims[key]
        case .volatile:
            volatileTerminalResults[key]
        }
        let entryDelta = replaced == nil ? 1 : 0
        let encodedWithoutReplaced = cachedEncodedBytes - (replaced?.encodedBytes ?? 0)
        let allocatedWithoutReplaced =
            cachedAllocatedBytes - (replaced?.allocatedBytes ?? 0)
        let projectedEncoded = try Self.checkedAdd(
            encodedWithoutReplaced,
            record.encodedBytes
        )
        let projectedAllocated = try Self.checkedAdd(
            allocatedWithoutReplaced,
            record.allocatedBytes
        )
        guard ownedClaims.count + volatileTerminalResults.count + entryDelta
            + expiredFallbackReleases.count
            <= limits.maxEntries,
            projectedEncoded <= limits.maxEncodedBytes,
            projectedAllocated <= limits.maxEncodedBytes
        else {
            throw IntentIdempotencyError.capacityExceeded
        }

        switch location {
        case .owned:
            ownedClaims[key] = record
        case .volatile:
            volatileTerminalResults[key] = record
        }
        cachedEncodedBytes = projectedEncoded
        cachedAllocatedBytes = projectedAllocated
    }

    private func moveOwnedClaimToVolatile(
        key: IntentIdempotencyClaimKey,
        terminal: CachedRecord
    ) throws {
        guard let owned = ownedClaims[key],
              volatileTerminalResults[key] == nil,
              terminal.allocatedBytes <= owned.allocatedBytes
        else {
            throw IntentIdempotencyError.capacityExceeded
        }

        let projectedEncoded = try Self.checkedAdd(
            cachedEncodedBytes - owned.encodedBytes,
            terminal.encodedBytes
        )
        let projectedAllocated = try Self.checkedAdd(
            cachedAllocatedBytes - owned.allocatedBytes,
            terminal.allocatedBytes
        )
        guard projectedEncoded <= limits.maxEncodedBytes,
              projectedAllocated <= limits.maxEncodedBytes
        else {
            throw IntentIdempotencyError.capacityExceeded
        }

        ownedClaims[key] = nil
        volatileTerminalResults[key] = terminal
        cachedEncodedBytes = projectedEncoded
        cachedAllocatedBytes = projectedAllocated
    }

    private func removeCachedRecord(
        at location: CacheLocation,
        key: IntentIdempotencyClaimKey
    ) {
        let removed = switch location {
        case .owned:
            ownedClaims.removeValue(forKey: key)
        case .volatile:
            volatileTerminalResults.removeValue(forKey: key)
        }
        guard let removed else { return }
        cachedEncodedBytes -= removed.encodedBytes
        cachedAllocatedBytes -= removed.allocatedBytes
    }

    /// Reserves the exact local cache slot before asking persistence to commit a claim.
    ///
    /// The persistence API is synchronous, so actor state cannot interleave between this
    /// reservation and either commit or rollback. This closes the split-brain state where
    /// SQLite contained an executing claim while `claim()` reported local capacity failure.
    private func stageClaimCacheReservation(
        _ claim: CachedRecord,
        key: IntentIdempotencyClaimKey
    ) throws -> ClaimCacheCheckpoint {
        let checkpoint = ClaimCacheCheckpoint(
            ownedClaim: ownedClaims[key],
            expiredRelease: expiredFallbackReleases[key],
            encodedBytes: cachedEncodedBytes,
            allocatedBytes: cachedAllocatedBytes
        )
        removeExpiredFallbackRelease(key: key)
        do {
            try replaceCachedRecord(at: .owned, key: key, with: claim)
            return checkpoint
        } catch {
            restoreClaimCache(checkpoint, key: key)
            throw error
        }
    }

    private func restoreClaimCache(
        _ checkpoint: ClaimCacheCheckpoint,
        key: IntentIdempotencyClaimKey
    ) {
        ownedClaims[key] = checkpoint.ownedClaim
        expiredFallbackReleases[key] = checkpoint.expiredRelease
        cachedEncodedBytes = checkpoint.encodedBytes
        cachedAllocatedBytes = checkpoint.allocatedBytes
    }

    private func expireOwnedClaims(now: Date) {
        let expiredKeys = ownedClaims.compactMap { key, claim in
            claim.record.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            removeCachedRecord(at: .owned, key: key)
        }
    }

    private func expireVolatileTerminals(now: Date) throws {
        let expiredKeys = volatileTerminalResults.compactMap { key, terminal in
            terminal.record.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            guard let terminal = volatileTerminalResults[key] else { continue }
            let release = ExpiredFallbackRelease(
                key: key,
                requestID: terminal.record.requestID
            )
            let encodedBytes = try Self.encodedBytes(of: release)
            removeCachedRecord(at: .volatile, key: key)
            try replaceExpiredFallbackRelease(
                CachedRelease(release: release, encodedBytes: encodedBytes),
                key: key
            )
        }
    }

    private func replaceExpiredFallbackRelease(
        _ release: CachedRelease,
        key: IntentIdempotencyClaimKey
    ) throws {
        let replaced = expiredFallbackReleases[key]
        let entryDelta = replaced == nil ? 1 : 0
        let encodedWithoutReplaced = cachedEncodedBytes - (replaced?.encodedBytes ?? 0)
        let projectedBytes = try Self.checkedAdd(
            encodedWithoutReplaced,
            release.encodedBytes
        )
        guard ownedClaims.count
            + volatileTerminalResults.count
            + expiredFallbackReleases.count
            + entryDelta
            <= limits.maxEntries,
            projectedBytes <= limits.maxEncodedBytes
        else {
            throw IntentIdempotencyError.capacityExceeded
        }
        expiredFallbackReleases[key] = release
        cachedEncodedBytes = projectedBytes
        cachedAllocatedBytes =
            cachedAllocatedBytes - (replaced?.encodedBytes ?? 0) + release.encodedBytes
    }

    private func removeExpiredFallbackRelease(key: IntentIdempotencyClaimKey) {
        guard let removed = expiredFallbackReleases.removeValue(forKey: key) else {
            return
        }
        cachedEncodedBytes -= removed.encodedBytes
        cachedAllocatedBytes -= removed.encodedBytes
    }

    private static func encodedBytes(of record: IntentIdempotencyRecord) throws -> Int {
        try IntentIdempotencyCoding.encoder().encode(record).count
    }

    private static func minimumTerminalResultReservation(
        for record: IntentIdempotencyRecord
    ) throws -> Int {
        let fallback = persistenceFailureResult(for: record)
        let terminal = IntentIdempotencyRecord(
            claimKey: record.claimKey,
            fingerprint: record.fingerprint,
            providerID: record.providerID,
            requestID: record.requestID,
            state: .terminal,
            terminalResult: fallback,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            expiresAt: record.expiresAt
        )
        let encoder = IntentIdempotencyCoding.encoder()
        let fallbackBytes = try encoder.encode(fallback).count
        let claimBytes = try encoder.encode(record).count
        let terminalBytes = try encoder.encode(terminal).count
        return max(fallbackBytes, max(0, terminalBytes - claimBytes))
    }

    private static func encodedBytes(of release: ExpiredFallbackRelease) throws -> Int {
        try IntentIdempotencyCoding.encoder().encode(release).count
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw IntentIdempotencyError.capacityExceeded
        }
        return sum
    }

    private func cancelWaiter(key: IntentIdempotencyClaimKey, waiterID: UUID) {
        guard let waiter = removeWaiter(key: key, waiterID: waiterID) else { return }
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(key: IntentIdempotencyClaimKey, waiterID: UUID) {
        guard let waiter = removeWaiter(key: key, waiterID: waiterID) else { return }
        waiter.continuation.resume(throwing: IntentIdempotencyError.waiterDeadlineExceeded)
    }

    private func removeWaiter(
        key: IntentIdempotencyClaimKey,
        waiterID: UUID
    ) -> Waiter? {
        guard let waiter = waiters[key]?.removeValue(forKey: waiterID) else {
            return nil
        }
        totalWaiters -= 1
        if waiters[key]?.isEmpty == true {
            waiters[key] = nil
            settlementMonitors.removeValue(forKey: key)?.cancel()
        }
        return waiter
    }

    private func finishWaiters(key: IntentIdempotencyClaimKey, result: IntentResult) {
        settlementMonitors.removeValue(forKey: key)?.cancel()
        let waiting = waiters.removeValue(forKey: key)?.values ?? [:].values
        totalWaiters -= waiting.count
        for waiter in waiting {
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(returning: result)
        }
    }

    private func startSettlementMonitorIfNeeded(
        key: IntentIdempotencyClaimKey,
        requestID: UUID
    ) {
        guard settlementMonitors[key] == nil else { return }
        settlementMonitors[key] = Task { @concurrent [store = self] in
            var backoffMilliseconds: Int64 = 10
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(
                        for: .milliseconds(backoffMilliseconds)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard await store.refreshSettlement(
                    key: key,
                    requestID: requestID
                ) else {
                    return
                }
                backoffMilliseconds = min(backoffMilliseconds * 2, 250)
            }
        }
    }

    private func refreshSettlement(
        key: IntentIdempotencyClaimKey,
        requestID: UUID
    ) -> Bool {
        guard waiters[key]?.isEmpty == false else {
            settlementMonitors[key] = nil
            return false
        }
        do {
            guard let record = try durableLookup(key: key, now: Date()) else {
                return true
            }
            guard record.requestID == requestID else {
                return true
            }
            guard let terminal = record.terminalResult else {
                return true
            }
            finishWaiters(key: key, result: terminal)
            return false
        } catch {
            // Durable reads can fail transiently while another connection is
            // committing. The hard waiter deadline remains the final bound.
            return true
        }
    }

    private static func canonicalized(
        _ result: IntentResult,
        for record: IntentIdempotencyRecord
    ) -> IntentResult {
        switch result {
        case let .success(success):
            .success(
                value: success.value,
                requestID: record.requestID,
                providerID: record.providerID
            )
        case let .failure(failure):
            .failure(
                error: failure.error,
                requestID: record.requestID,
                providerID: record.providerID
            )
        }
    }

    private static func persistenceFailureResult(
        for record: IntentIdempotencyRecord
    ) -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.internal),
                details: .object([
                    "reason": .string("idempotency-persistence-failed"),
                ]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: record.state == .claimed ? .notStarted : .unknown
            ),
            requestID: record.requestID,
            providerID: record.providerID
        )
    }
}

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
