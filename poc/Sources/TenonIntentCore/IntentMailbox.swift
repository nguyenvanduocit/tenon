import Foundation

public enum IntentAdmissionClass: String, Sendable, Equatable, Codable {
    case interactive
    case background
}

public struct IntentMailboxLimits: Sendable, Equatable {
    public let maxRequests: Int
    public let maxEncodedBytes: Int
    public let maxRequestsPerPrincipal: Int
    public let maxEncodedBytesPerPrincipal: Int
    public let reservedInteractiveRequests: Int
    public let reservedInteractiveBytes: Int

    public init(
        maxRequests: Int = 64,
        maxEncodedBytes: Int = 4 * 1024 * 1024,
        maxRequestsPerPrincipal: Int = 16,
        maxEncodedBytesPerPrincipal: Int = 1024 * 1024,
        reservedInteractiveRequests: Int = 8,
        reservedInteractiveBytes: Int = 512 * 1024
    ) throws {
        guard maxRequests > 0,
              maxEncodedBytes > 0,
              maxRequestsPerPrincipal > 0,
              maxEncodedBytesPerPrincipal > 0,
              reservedInteractiveRequests >= 0,
              reservedInteractiveRequests < maxRequests,
              reservedInteractiveBytes >= 0,
              reservedInteractiveBytes < maxEncodedBytes
        else {
            throw IntentMailboxLimitError.invalidLimits
        }

        self.maxRequests = maxRequests
        self.maxEncodedBytes = maxEncodedBytes
        self.maxRequestsPerPrincipal = maxRequestsPerPrincipal
        self.maxEncodedBytesPerPrincipal = maxEncodedBytesPerPrincipal
        self.reservedInteractiveRequests = reservedInteractiveRequests
        self.reservedInteractiveBytes = reservedInteractiveBytes
    }
}

public enum IntentMailboxLimitError: Error, Sendable, Equatable {
    case invalidLimits
}

public enum IntentMailboxAdmissionError: Error, Sendable, Equatable {
    case duplicateRequestID(UUID)
    case requestTooLarge(limit: Int)
    case overloaded(retryAfterMilliseconds: UInt64)
    case principalQuotaExceeded(retryAfterMilliseconds: UInt64)
    case retired
}

public enum IntentMailboxTerminal: Sendable, Equatable {
    case reply(IntentProviderReply)
    case cancelled(IntentOutcome)
    case deadlineExceeded(IntentOutcome)
    case providerRetired(IntentOutcome)
}

public struct IntentMailboxPhysicalCompletion: Sendable, Equatable {
    public let requestID: UUID
    public let terminal: IntentMailboxTerminal
    public let providerReply: IntentProviderReply?
    public let started: Bool
    public let isLateReply: Bool

    public init(
        requestID: UUID,
        terminal: IntentMailboxTerminal,
        providerReply: IntentProviderReply?,
        started: Bool,
        isLateReply: Bool
    ) {
        self.requestID = requestID
        self.terminal = terminal
        self.providerReply = providerReply
        self.started = started
        self.isLateReply = isLateReply
    }
}

public struct IntentMailboxJob: Sendable {
    public typealias Operation = @Sendable () async -> IntentProviderReply
    public typealias PhysicalCompletion = @Sendable (
        IntentMailboxPhysicalCompletion
    ) async -> Void

    public let requestID: UUID
    public let principal: IntentPrincipal
    public let deadline: ContinuousClock.Instant
    public let encodedBytes: Int
    public let admissionClass: IntentAdmissionClass
    private let operation: Operation
    private let completion: PhysicalCompletion

    public init(
        requestID: UUID,
        principal: IntentPrincipal,
        deadline: ContinuousClock.Instant,
        encodedBytes: Int,
        admissionClass: IntentAdmissionClass,
        operation: @escaping Operation,
        physicalCompletion: @escaping PhysicalCompletion = { _ in }
    ) throws {
        guard !principal.id.isEmpty, encodedBytes >= 0 else {
            throw IntentMailboxJobError.invalidJob
        }
        self.requestID = requestID
        self.principal = principal
        self.deadline = deadline
        self.encodedBytes = encodedBytes
        self.admissionClass = admissionClass
        self.operation = operation
        self.completion = physicalCompletion
    }

    fileprivate func invoke() async -> IntentProviderReply {
        await operation()
    }

    fileprivate func complete(_ result: IntentMailboxPhysicalCompletion) async {
        await completion(result)
    }
}

public enum IntentMailboxJobError: Error, Sendable, Equatable {
    case invalidJob
}

public struct IntentMailboxSnapshot: Sendable, Equatable {
    public let isRetired: Bool
    public let isPhysicallyIdle: Bool
    public let queuedRequests: Int
    public let physicalQueueNodes: Int
    public let runningRequestID: UUID?
    public let admittedRequests: Int
    public let admittedEncodedBytes: Int
    public let admittedByPrincipal: [IntentPrincipal: Int]
}

public actor IntentMailbox {
    private struct Usage: Sendable {
        var requests = 0
        var bytes = 0
    }

    private struct Pending: Sendable {
        let job: IntentMailboxJob
        let continuation: CheckedContinuation<IntentMailboxTerminal, Never>
        let deadlineTask: Task<Void, Never>
        var previousRequestID: UUID?
        var nextRequestID: UUID?
    }

    private struct PrincipalQueue: Sendable {
        var headRequestID: UUID
        var tailRequestID: UUID
        var previousPrincipal: IntentPrincipal
        var nextPrincipal: IntentPrincipal
    }

    private struct Running: Sendable {
        let job: IntentMailboxJob
        var continuation: CheckedContinuation<IntentMailboxTerminal, Never>?
        var terminal: IntentMailboxTerminal?
        let deadlineTask: Task<Void, Never>
        let operationTask: Task<IntentProviderReply, Never>
    }

    private let limits: IntentMailboxLimits
    private var pendingByID: [UUID: Pending] = [:]
    private var queuesByPrincipal: [IntentPrincipal: PrincipalQueue] = [:]
    private var roundRobinHead: IntentPrincipal?
    private var completingRequestIDs: Set<UUID> = []
    private var physicalIdleWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var running: Running?
    private var usage = Usage()
    private var backgroundUsage = Usage()
    private var usageByPrincipal: [IntentPrincipal: Usage] = [:]
    private var isDraining = false
    private var isRetired = false

    public init(limits: IntentMailboxLimits) {
        self.limits = limits
    }

    public func submit(_ job: IntentMailboxJob) async throws -> IntentMailboxTerminal {
        try admit(job)

        if Task.isCancelled {
            let terminal = IntentMailboxTerminal.cancelled(.notStarted)
            schedulePhysicalCompletion(
                job: job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
            return terminal
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueAdmitted(job, continuation: continuation)
            }
        } onCancel: {
            Task { [mailbox = self, requestID = job.requestID] in
                await mailbox.cancel(requestID: requestID)
            }
        }
    }

    public func cancel(requestID: UUID) {
        if let pending = removePending(requestID: requestID) {
            pending.deadlineTask.cancel()
            let terminal = IntentMailboxTerminal.cancelled(.notStarted)
            pending.continuation.resume(returning: terminal)
            schedulePhysicalCompletion(
                job: pending.job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
            return
        }

        guard var running, running.job.requestID == requestID else { return }
        running.operationTask.cancel()
        guard let continuation = running.continuation else { return }

        let terminal = IntentMailboxTerminal.cancelled(.unknown)
        running.continuation = nil
        running.terminal = terminal
        self.running = running
        continuation.resume(returning: terminal)
    }

    public func retire() {
        guard !isRetired else { return }
        isRetired = true

        let queued = Array(pendingByID.values)
        pendingByID.removeAll(keepingCapacity: false)
        queuesByPrincipal.removeAll(keepingCapacity: false)
        roundRobinHead = nil
        for pending in queued {
            pending.deadlineTask.cancel()
            let terminal = IntentMailboxTerminal.providerRetired(.notStarted)
            pending.continuation.resume(returning: terminal)
            schedulePhysicalCompletion(
                job: pending.job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
        }

        guard var running, let continuation = running.continuation else {
            self.running?.operationTask.cancel()
            return
        }
        running.operationTask.cancel()
        let terminal = IntentMailboxTerminal.providerRetired(.unknown)
        running.continuation = nil
        running.terminal = terminal
        self.running = running
        continuation.resume(returning: terminal)
    }

    public func retireAndWaitUntilIdle() async {
        retire()
        await waitUntilPhysicallyIdle()
    }

    public func waitUntilPhysicallyIdle() async {
        guard !isPhysicallyIdle else { return }
        await withCheckedContinuation { continuation in
            physicalIdleWaiters.append(continuation)
        }
    }

    public func snapshot() -> IntentMailboxSnapshot {
        IntentMailboxSnapshot(
            isRetired: isRetired,
            isPhysicallyIdle: isPhysicallyIdle,
            queuedRequests: pendingByID.count,
            physicalQueueNodes: pendingByID.count,
            runningRequestID: running?.job.requestID,
            admittedRequests: usage.requests,
            admittedEncodedBytes: usage.bytes,
            admittedByPrincipal: usageByPrincipal.mapValues(\.requests)
        )
    }

    private func admit(_ job: IntentMailboxJob) throws {
        guard !isRetired else {
            throw IntentMailboxAdmissionError.retired
        }
        guard pendingByID[job.requestID] == nil,
              running?.job.requestID != job.requestID,
              !completingRequestIDs.contains(job.requestID)
        else {
            throw IntentMailboxAdmissionError.duplicateRequestID(job.requestID)
        }
        guard job.encodedBytes <= limits.maxEncodedBytes,
              job.encodedBytes <= limits.maxEncodedBytesPerPrincipal
        else {
            throw IntentMailboxAdmissionError.requestTooLarge(
                limit: min(limits.maxEncodedBytes, limits.maxEncodedBytesPerPrincipal)
            )
        }

        let principalUsage = usageByPrincipal[job.principal] ?? Usage()
        guard principalUsage.requests + 1 <= limits.maxRequestsPerPrincipal,
              principalUsage.bytes + job.encodedBytes <= limits.maxEncodedBytesPerPrincipal
        else {
            throw IntentMailboxAdmissionError.principalQuotaExceeded(
                retryAfterMilliseconds: 25
            )
        }

        guard usage.requests + 1 <= limits.maxRequests,
              usage.bytes + job.encodedBytes <= limits.maxEncodedBytes
        else {
            throw IntentMailboxAdmissionError.overloaded(retryAfterMilliseconds: 25)
        }

        if job.admissionClass == .background {
            guard backgroundUsage.requests + 1
                    <= limits.maxRequests - limits.reservedInteractiveRequests,
                  backgroundUsage.bytes + job.encodedBytes
                    <= limits.maxEncodedBytes - limits.reservedInteractiveBytes
            else {
                throw IntentMailboxAdmissionError.overloaded(retryAfterMilliseconds: 25)
            }
        }

        addUsage(for: job)
    }

    private func enqueueAdmitted(
        _ job: IntentMailboxJob,
        continuation: CheckedContinuation<IntentMailboxTerminal, Never>
    ) {
        if Task.isCancelled {
            let terminal = IntentMailboxTerminal.cancelled(.notStarted)
            continuation.resume(returning: terminal)
            schedulePhysicalCompletion(
                job: job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
            return
        }

        if ContinuousClock.now >= job.deadline {
            let terminal = IntentMailboxTerminal.deadlineExceeded(.notStarted)
            continuation.resume(returning: terminal)
            schedulePhysicalCompletion(
                job: job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
            return
        }

        let deadlineTask = makeDeadlineTask(requestID: job.requestID, deadline: job.deadline)
        pendingByID[job.requestID] = Pending(
            job: job,
            continuation: continuation,
            deadlineTask: deadlineTask,
            previousRequestID: nil,
            nextRequestID: nil
        )
        appendPending(job.requestID, principal: job.principal)
        startDrainingIfNeeded()
    }

    private func startDrainingIfNeeded() {
        guard !isDraining, running == nil, !pendingByID.isEmpty else { return }
        isDraining = true
        Task { [mailbox = self] in
            await mailbox.drain()
        }
    }

    private func drain() async {
        while let pending = popNextPending() {
            if ContinuousClock.now >= pending.job.deadline {
                pending.deadlineTask.cancel()
                let terminal = IntentMailboxTerminal.deadlineExceeded(.notStarted)
                pending.continuation.resume(returning: terminal)
                schedulePhysicalCompletion(
                    job: pending.job,
                    terminal: terminal,
                    reply: nil,
                    started: false,
                    isLateReply: false
                )
                continue
            }

            let operationTask = Task {
                await pending.job.invoke()
            }
            running = Running(
                job: pending.job,
                continuation: pending.continuation,
                terminal: nil,
                deadlineTask: pending.deadlineTask,
                operationTask: operationTask
            )

            let reply = await operationTask.value
            finishRunning(requestID: pending.job.requestID, reply: reply)
        }

        isDraining = false
        if running == nil, !pendingByID.isEmpty {
            startDrainingIfNeeded()
        }
    }

    private func finishRunning(requestID: UUID, reply: IntentProviderReply) {
        guard let running, running.job.requestID == requestID else { return }
        running.deadlineTask.cancel()

        let terminal: IntentMailboxTerminal
        let isLateReply: Bool
        if let continuation = running.continuation {
            terminal = .reply(reply)
            isLateReply = false
            continuation.resume(returning: terminal)
        } else {
            terminal = running.terminal ?? .cancelled(.unknown)
            isLateReply = true
        }

        self.running = nil
        schedulePhysicalCompletion(
            job: running.job,
            terminal: terminal,
            reply: reply,
            started: true,
            isLateReply: isLateReply
        )
    }

    private func expire(requestID: UUID) {
        if let pending = removePending(requestID: requestID) {
            pending.deadlineTask.cancel()
            let terminal = IntentMailboxTerminal.deadlineExceeded(.notStarted)
            pending.continuation.resume(returning: terminal)
            schedulePhysicalCompletion(
                job: pending.job,
                terminal: terminal,
                reply: nil,
                started: false,
                isLateReply: false
            )
            return
        }

        guard var running, running.job.requestID == requestID else { return }
        running.operationTask.cancel()
        guard let continuation = running.continuation else { return }
        let terminal = IntentMailboxTerminal.deadlineExceeded(.unknown)
        running.continuation = nil
        running.terminal = terminal
        self.running = running
        continuation.resume(returning: terminal)
    }

    private func popNextPending() -> Pending? {
        guard let principal = roundRobinHead,
              let queue = queuesByPrincipal[principal],
              let pending = removePending(requestID: queue.headRequestID)
        else {
            return nil
        }

        if let survivingQueue = queuesByPrincipal[principal] {
            roundRobinHead = survivingQueue.nextPrincipal
        }
        return pending
    }

    private func appendPending(_ requestID: UUID, principal: IntentPrincipal) {
        guard var pending = pendingByID[requestID] else { return }

        if var queue = queuesByPrincipal[principal] {
            let previousTailID = queue.tailRequestID
            pending.previousRequestID = previousTailID
            if var previousTail = pendingByID[previousTailID] {
                previousTail.nextRequestID = requestID
                pendingByID[previousTailID] = previousTail
            }
            queue.tailRequestID = requestID
            pendingByID[requestID] = pending
            queuesByPrincipal[principal] = queue
            return
        }

        pendingByID[requestID] = pending
        insertPrincipalQueue(principal, requestID: requestID)
    }

    private func removePending(requestID: UUID) -> Pending? {
        guard let pending = pendingByID[requestID],
              var queue = queuesByPrincipal[pending.job.principal]
        else {
            return nil
        }
        pendingByID[requestID] = nil

        if let previousRequestID = pending.previousRequestID,
           var previous = pendingByID[previousRequestID]
        {
            previous.nextRequestID = pending.nextRequestID
            pendingByID[previousRequestID] = previous
        } else if let nextRequestID = pending.nextRequestID {
            queue.headRequestID = nextRequestID
        }

        if let nextRequestID = pending.nextRequestID,
           var next = pendingByID[nextRequestID]
        {
            next.previousRequestID = pending.previousRequestID
            pendingByID[nextRequestID] = next
        } else if let previousRequestID = pending.previousRequestID {
            queue.tailRequestID = previousRequestID
        }

        if pending.previousRequestID == nil, pending.nextRequestID == nil {
            removePrincipalQueue(pending.job.principal)
        } else {
            queuesByPrincipal[pending.job.principal] = queue
        }
        return pending
    }

    private func insertPrincipalQueue(_ principal: IntentPrincipal, requestID: UUID) {
        guard let headID = roundRobinHead,
              let head = queuesByPrincipal[headID],
              var tail = queuesByPrincipal[head.previousPrincipal]
        else {
            queuesByPrincipal[principal] = PrincipalQueue(
                headRequestID: requestID,
                tailRequestID: requestID,
                previousPrincipal: principal,
                nextPrincipal: principal
            )
            roundRobinHead = principal
            return
        }

        let tailID = head.previousPrincipal
        tail.nextPrincipal = principal
        queuesByPrincipal[tailID] = tail

        var updatedHead = queuesByPrincipal[headID] ?? head
        updatedHead.previousPrincipal = principal
        queuesByPrincipal[headID] = updatedHead
        queuesByPrincipal[principal] = PrincipalQueue(
            headRequestID: requestID,
            tailRequestID: requestID,
            previousPrincipal: tailID,
            nextPrincipal: headID
        )
    }

    private func removePrincipalQueue(_ principal: IntentPrincipal) {
        guard let queue = queuesByPrincipal[principal] else { return }
        if queue.previousPrincipal == principal {
            queuesByPrincipal[principal] = nil
            roundRobinHead = nil
            return
        }

        if var previous = queuesByPrincipal[queue.previousPrincipal] {
            previous.nextPrincipal = queue.nextPrincipal
            queuesByPrincipal[queue.previousPrincipal] = previous
        }
        if var next = queuesByPrincipal[queue.nextPrincipal] {
            next.previousPrincipal = queue.previousPrincipal
            queuesByPrincipal[queue.nextPrincipal] = next
        }
        queuesByPrincipal[principal] = nil
        if roundRobinHead == principal {
            roundRobinHead = queue.nextPrincipal
        }
    }

    private func makeDeadlineTask(
        requestID: UUID,
        deadline: ContinuousClock.Instant
    ) -> Task<Void, Never> {
        Task { [mailbox = self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            await mailbox.expire(requestID: requestID)
        }
    }

    private func schedulePhysicalCompletion(
        job: IntentMailboxJob,
        terminal: IntentMailboxTerminal,
        reply: IntentProviderReply?,
        started: Bool,
        isLateReply: Bool
    ) {
        guard completingRequestIDs.insert(job.requestID).inserted else { return }
        let completion = IntentMailboxPhysicalCompletion(
            requestID: job.requestID,
            terminal: terminal,
            providerReply: reply,
            started: started,
            isLateReply: isLateReply
        )
        Task { [mailbox = self] in
            await job.complete(completion)
            await mailbox.finishPhysicalCompletion(for: job)
        }
    }

    private func finishPhysicalCompletion(for job: IntentMailboxJob) {
        guard completingRequestIDs.remove(job.requestID) != nil else { return }
        removeUsage(for: job)
        resumePhysicalIdleWaitersIfNeeded()
    }

    private func addUsage(for job: IntentMailboxJob) {
        usage.requests += 1
        usage.bytes += job.encodedBytes
        usageByPrincipal[job.principal, default: Usage()].requests += 1
        usageByPrincipal[job.principal, default: Usage()].bytes += job.encodedBytes
        if job.admissionClass == .background {
            backgroundUsage.requests += 1
            backgroundUsage.bytes += job.encodedBytes
        }
    }

    private func removeUsage(for job: IntentMailboxJob) {
        usage.requests -= 1
        usage.bytes -= job.encodedBytes

        if var principalUsage = usageByPrincipal[job.principal] {
            principalUsage.requests -= 1
            principalUsage.bytes -= job.encodedBytes
            usageByPrincipal[job.principal] =
                principalUsage.requests == 0 ? nil : principalUsage
        }

        if job.admissionClass == .background {
            backgroundUsage.requests -= 1
            backgroundUsage.bytes -= job.encodedBytes
        }
    }

    private var isPhysicallyIdle: Bool {
        pendingByID.isEmpty
            && running == nil
            && completingRequestIDs.isEmpty
            && usage.requests == 0
            && usage.bytes == 0
    }

    private func resumePhysicalIdleWaitersIfNeeded() {
        guard isPhysicallyIdle, !physicalIdleWaiters.isEmpty else { return }
        let waiters = physicalIdleWaiters
        physicalIdleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
