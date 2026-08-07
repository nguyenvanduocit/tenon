// @domain: intent-bus
//
// The actor that sequences claims: who owns an in-flight request, who waits on it, what a late
// duplicate is handed, and when a record expires. Ordering lives here and nowhere else.
import Foundation
import os

/// The owner of an in-flight claim, held by the store that sequences it.
final class IntentIdempotencyOwnerLease: Sendable {
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
