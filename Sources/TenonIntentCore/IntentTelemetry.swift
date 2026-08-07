// @domain: intent-bus
import Foundation

public struct IntentProgressNotification: Sendable, Equatable {
    public let requestID: UUID
    public let progress: IntentProgress

    public init(requestID: UUID, progress: IntentProgress) {
        self.requestID = requestID
        self.progress = progress
    }
}

public struct IntentTelemetryRecord: Sendable, Equatable {
    public let requestID: UUID
    public let traceID: UUID
    public let parentRequestID: UUID?
    public let intentID: IntentID
    public let caller: IntentPrincipal
    public let createdAt: ContinuousClock.Instant
    public var validatedAt: ContinuousClock.Instant?
    public var authorizedAt: ContinuousClock.Instant?
    public var queuedAt: ContinuousClock.Instant?
    public var startedAt: ContinuousClock.Instant?
    public var settledAt: ContinuousClock.Instant?
    public var physicallyCompletedAt: ContinuousClock.Instant?
    public var providerID: ProviderID?
    public var generation: UInt64?
    public var policyRevision: PolicyRevision?
    public var inputBytes: Int
    public var outputBytes: Int?
    public var terminalCode: String?
    public var outcome: IntentOutcome?
    public var progressNotificationCount: Int
    public var admissionRejected: Bool
    public var lateReply: Bool
    public var confirmationDisposition: IntentConfirmationDisposition?

    public init(envelope: IntentEnvelope, inputBytes: Int) {
        requestID = envelope.requestID
        traceID = envelope.traceID
        parentRequestID = envelope.parentRequestID
        intentID = envelope.name
        caller = envelope.caller
        createdAt = ContinuousClock.now
        self.inputBytes = inputBytes
        validatedAt = nil
        authorizedAt = nil
        queuedAt = nil
        startedAt = nil
        settledAt = nil
        physicallyCompletedAt = nil
        providerID = nil
        generation = nil
        policyRevision = nil
        outputBytes = nil
        terminalCode = nil
        outcome = nil
        progressNotificationCount = 0
        admissionRejected = false
        lateReply = false
        confirmationDisposition = nil
    }

    public var queueWait: Duration? {
        guard let queuedAt, let startedAt else { return nil }
        return queuedAt.duration(to: startedAt)
    }

    public var handlerDuration: Duration? {
        guard let startedAt, let physicallyCompletedAt else { return nil }
        return startedAt.duration(to: physicallyCompletedAt)
    }

    public var totalDuration: Duration? {
        guard let settledAt else { return nil }
        return createdAt.duration(to: settledAt)
    }
}

public struct IntentTelemetrySnapshot: Sendable, Equatable {
    public let inFlight: [IntentTelemetryRecord]
    public let completed: [IntentTelemetryRecord]
}

public enum IntentTelemetryError: Error, Sendable, Equatable {
    case invalidCapacity
}

public actor IntentTelemetry {
    private let completedCapacity: Int
    private var inFlight: [UUID: IntentTelemetryRecord] = [:]
    private var completedSlots: [IntentTelemetryRecord?]
    private var completedCount = 0
    private var nextCompletedIndex = 0

    public init(completedCapacity: Int = 2_000) throws {
        guard completedCapacity > 0 else {
            throw IntentTelemetryError.invalidCapacity
        }
        self.completedCapacity = completedCapacity
        self.completedSlots = Array(repeating: nil, count: completedCapacity)
    }

    public func begin(_ envelope: IntentEnvelope, inputBytes: Int) {
        guard inFlight[envelope.requestID] == nil else { return }
        inFlight[envelope.requestID] = IntentTelemetryRecord(
            envelope: envelope,
            inputBytes: inputBytes
        )
    }

    public func markValidated(requestID: UUID) {
        update(requestID) { record in
            record.validatedAt = record.validatedAt ?? ContinuousClock.now
        }
    }

    public func markAuthorized(requestID: UUID, policyRevision: PolicyRevision) {
        update(requestID) { record in
            record.authorizedAt = record.authorizedAt ?? ContinuousClock.now
            record.policyRevision = policyRevision
        }
    }

    public func markQueued(
        requestID: UUID,
        providerID: ProviderID,
        generation: UInt64
    ) {
        update(requestID) { record in
            record.providerID = providerID
            record.generation = generation
            record.queuedAt = record.queuedAt ?? ContinuousClock.now
        }
    }

    public func markStarted(requestID: UUID) {
        update(requestID) { record in
            record.startedAt = record.startedAt ?? ContinuousClock.now
        }
    }

    public func markProgress(requestID: UUID) {
        update(requestID) { record in
            record.progressNotificationCount += 1
        }
    }

    public func markAdmissionRejected(requestID: UUID) {
        update(requestID) { record in
            record.admissionRejected = true
        }
    }

    public func markConfirmation(
        requestID: UUID,
        disposition: IntentConfirmationDisposition
    ) {
        update(requestID) { record in
            record.confirmationDisposition = disposition
        }
    }

    public func markSettled(
        requestID: UUID,
        result: IntentResult,
        outputBytes: Int?
    ) {
        update(requestID) { record in
            guard record.settledAt == nil else { return }
            record.settledAt = ContinuousClock.now
            record.outputBytes = outputBytes
            switch result {
            case .success:
                record.terminalCode = "ok"
                record.outcome = nil
            case let .failure(failure):
                record.terminalCode = failure.error.code.rawValue
                record.outcome = failure.error.outcome
            }
        }
        finalizeIfComplete(requestID)
    }

    public func markPhysicallyCompleted(
        requestID: UUID,
        completion: IntentMailboxPhysicalCompletion?
    ) {
        update(requestID) { record in
            record.physicallyCompletedAt = record.physicallyCompletedAt ?? ContinuousClock.now
            if completion?.isLateReply == true {
                record.lateReply = true
            }
        }
        finalizeIfComplete(requestID)
    }

    public func snapshot() -> IntentTelemetrySnapshot {
        let oldestIndex = completedCount == completedCapacity
            ? nextCompletedIndex
            : 0
        let completed = (0 ..< completedCount).compactMap { offset in
            completedSlots[(oldestIndex + offset) % completedCapacity]
        }
        return IntentTelemetrySnapshot(
            inFlight: inFlight.values.sorted { $0.createdAt < $1.createdAt },
            completed: completed
        )
    }

    private func update(
        _ requestID: UUID,
        mutation: (inout IntentTelemetryRecord) -> Void
    ) {
        guard var record = inFlight[requestID] else { return }
        mutation(&record)
        inFlight[requestID] = record
    }

    private func finalizeIfComplete(_ requestID: UUID) {
        guard let record = inFlight[requestID],
              record.settledAt != nil,
              record.physicallyCompletedAt != nil
        else {
            return
        }
        inFlight[requestID] = nil
        completedSlots[nextCompletedIndex] = record
        nextCompletedIndex = (nextCompletedIndex + 1) % completedCapacity
        completedCount = min(completedCount + 1, completedCapacity)
    }
}

public actor IntentProgressReporter {
    public typealias Sink = @Sendable (IntentProgressNotification) async -> Void

    private let requestID: UUID
    private let minimumInterval: Duration
    private let sink: Sink
    private var lastAcceptedCompleted: Double = -.infinity
    private var lastEmittedAt: ContinuousClock.Instant?
    private var pending: IntentProgress?
    private var flushTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        requestID: UUID,
        minimumInterval: Duration = .milliseconds(50),
        sink: @escaping Sink
    ) {
        self.requestID = requestID
        self.minimumInterval = max(.zero, minimumInterval)
        self.sink = sink
    }

    public func report(_ progress: IntentProgress) async {
        guard !isClosed, progress.completed > lastAcceptedCompleted else { return }
        lastAcceptedCompleted = progress.completed

        let now = ContinuousClock.now
        if let lastEmittedAt,
           lastEmittedAt.duration(to: now) < minimumInterval
        {
            pending = progress
            scheduleFlush(from: now, lastEmittedAt: lastEmittedAt)
            return
        }
        pending = nil
        self.lastEmittedAt = now
        await sink(IntentProgressNotification(requestID: requestID, progress: progress))
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        pending = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func scheduleFlush(
        from now: ContinuousClock.Instant,
        lastEmittedAt: ContinuousClock.Instant
    ) {
        guard flushTask == nil else { return }
        let elapsed = lastEmittedAt.duration(to: now)
        let delay = max(.zero, minimumInterval - elapsed)
        flushTask = Task { [reporter = self] in
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            await reporter.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !isClosed, let pending else { return }
        self.pending = nil
        lastEmittedAt = ContinuousClock.now
        await sink(IntentProgressNotification(requestID: requestID, progress: pending))
    }
}
