// @domain: intent-bus
//
// What an idempotency claim IS: its key, its fingerprint, its states, the limits it lives
// inside, the outcomes a caller can be handed, and the persistence contract behind it. Values
// and one protocol — the store that sequences them and the SQLite adapter that keeps them are
// separate files, because "what a claim is" is read far more often than "how it is stored".
import Foundation
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
