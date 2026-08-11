import Foundation
import XCTest
@testable import TenonIntentCore

final class IntentMailboxTests: XCTestCase {
    /// A lane whose concurrency allows it runs more than one request at once.
    ///
    /// The counterexample this exists for is measured in
    /// `docs/architecture-interaction-boundaries.md`: `terminal.wait.v1` sits alone in the
    /// `terminalWait` lane, so two supervised agent runs could not both be waited on — the
    /// second wait queued behind the first, which by design does not return until its
    /// condition is met. The queue still bounds what may be *waiting*; this bounds what may
    /// be *running*, and the two are different questions.
    ///
    /// The barrier is the assertion: each job blocks until every job has started, so the
    /// test can only pass if they genuinely overlap. Serially, the first job waits for a
    /// second that cannot start, and the bounded wait reports it instead of hanging.
    func testALaneRunsConcurrentlyWhenItsConcurrencyLimitAllows() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits(maxConcurrentRequests: 2))
        let barrier = StartBarrier(expected: 2)

        let jobs = try (1 ... 2).map { index in
            try Self.job(id: UInt8(index), principal: "a") {
                await barrier.arriveAndWait()
                return .success(.null)
            }
        }
        let tasks = jobs.map { job in
            Task { try await mailbox.submit(job) }
        }

        let overlapped = await barrier.reachedFullStrength()
        let started = await barrier.arrived
        // Always unblock accepted jobs before an assertion can fail. A serial-lane
        // regression must report cleanly instead of hanging on its own barrier.
        if !overlapped { await barrier.release() }
        XCTAssertTrue(
            overlapped,
            "only \(started) of 2 requests started — the lane is still serial"
        )
        for task in tasks {
            _ = try await task.value
        }
    }

    /// The default is unchanged, and that matters more than the new capability: every other
    /// lane must keep the serial mailbox it has always had.
    func testALaneIsSerialByDefault() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let barrier = StartBarrier(expected: 2)

        let jobs = try (1 ... 2).map { index in
            try Self.job(id: UInt8(index), principal: "a") {
                await barrier.arrive()
                await barrier.waitForRelease()
                return .success(.null)
            }
        }
        let tasks = jobs.map { job in
            Task { try await mailbox.submit(job) }
        }

        await waitForRunning(mailbox)
        // Give a second request every chance to start, then require that none did.
        for _ in 0 ..< 200 { await Task.yield() }
        let arrived = await barrier.arrived
        XCTAssertEqual(
            arrived,
            1,
            "a default lane must run exactly one request at a time"
        )

        await barrier.release()
        for task in tasks {
            _ = try await task.value
        }
    }

    func testPerPrincipalFIFOWithRoundRobinFairness() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let gate = Gate()
        let log = StringLog()

        let firstJob = try Self.job(id: 1, principal: "a") {
            await log.append("a1")
            await gate.wait()
            return .success(.null)
        }
        let first = Task {
            try await mailbox.submit(firstJob)
        }
        await waitForRunning(mailbox)

        let a2Job = try Self.job(id: 2, principal: "a") {
            await log.append("a2")
            return .success(.null)
        }
        let a2 = Task {
            try await mailbox.submit(a2Job)
        }
        await waitForQueued(mailbox, count: 1)
        let b1Job = try Self.job(id: 3, principal: "b") {
            await log.append("b1")
            return .success(.null)
        }
        let b1 = Task {
            try await mailbox.submit(b1Job)
        }
        await waitForQueued(mailbox, count: 2)
        let a3Job = try Self.job(id: 4, principal: "a") {
            await log.append("a3")
            return .success(.null)
        }
        let a3 = Task {
            try await mailbox.submit(a3Job)
        }
        await waitForQueued(mailbox, count: 3)

        await gate.open()
        _ = try await [first.value, a2.value, b1.value, a3.value]

        let values = await log.values()
        XCTAssertEqual(values, ["a1", "a2", "b1", "a3"])
    }

    func testQueuedCancellationProvesHandlerDidNotStart() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let gate = Gate()
        let log = StringLog()
        let completions = CompletionLog()

        let blockerJob = try Self.job(id: 10, principal: "blocker") {
            await gate.wait()
            return .success(.null)
        }
        let blocker = Task {
            try await mailbox.submit(blockerJob)
        }
        await waitForRunning(mailbox)

        let queuedJob = try Self.job(id: 11, principal: "queued", completions: completions) {
            await log.append("started")
            return .success(.null)
        }
        let queued = Task {
            try await mailbox.submit(queuedJob)
        }
        await waitForQueued(mailbox, count: 1)
        queued.cancel()

        let terminal = try await queued.value
        XCTAssertEqual(terminal, .cancelled(.notStarted))
        let values = await log.values()
        XCTAssertTrue(values.isEmpty)

        await waitForCompletions(completions, count: 1)
        let physical = await completions.values().first
        XCTAssertEqual(physical?.started, false)
        XCTAssertEqual(physical?.providerReply, nil)

        await gate.open()
        _ = try await blocker.value
    }

    func testRunningCancellationReturnsUnknownAndLateReplyIsRecorded() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let gate = Gate()
        let completions = CompletionLog()

        let runningJob = try Self.job(id: 20, principal: "caller", completions: completions) {
            await gate.wait()
            return .success(.string("late"))
        }
        let running = Task {
            try await mailbox.submit(runningJob)
        }
        await waitForRunning(mailbox)
        running.cancel()

        let terminal = try await running.value
        XCTAssertEqual(terminal, .cancelled(.unknown))
        let completionsBeforeReply = await completions.values()
        XCTAssertTrue(completionsBeforeReply.isEmpty)

        await gate.open()
        await waitForCompletions(completions, count: 1)
        let physical = await completions.values().first
        XCTAssertEqual(physical?.terminal, .cancelled(.unknown))
        XCTAssertEqual(physical?.providerReply, .success(.string("late")))
        XCTAssertEqual(physical?.started, true)
        XCTAssertEqual(physical?.isLateReply, true)
    }

    func testDeadlineBeforeStartAndAfterStartHaveDifferentOutcomes() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let gate = Gate()

        let runningJob = try Self.job(
            id: 30,
            principal: "running",
            deadline: ContinuousClock.now.advanced(by: .milliseconds(30))
        ) {
            await gate.wait()
            return .success(.null)
        }
        let running = Task {
            try await mailbox.submit(runningJob)
        }
        await waitForRunning(mailbox)

        let queuedJob = try Self.job(
            id: 31,
            principal: "queued",
            deadline: ContinuousClock.now.advanced(by: .milliseconds(15))
        ) {
            .success(.null)
        }
        let queued = Task {
            try await mailbox.submit(queuedJob)
        }

        let queuedTerminal = try await queued.value
        let runningTerminal = try await running.value
        XCTAssertEqual(queuedTerminal, .deadlineExceeded(.notStarted))
        XCTAssertEqual(runningTerminal, .deadlineExceeded(.unknown))
        await gate.open()
    }

    func testRetirementSettlesQueuedAndRunningExactlyOnce() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let gate = Gate()
        let runningCompletions = CompletionLog()
        let queuedCompletions = CompletionLog()

        let runningJob = try Self.job(
            id: 40,
            principal: "running",
            completions: runningCompletions
        ) {
            await gate.wait()
            return .success(.string("late"))
        }
        let running = Task {
            try await mailbox.submit(runningJob)
        }
        await waitForRunning(mailbox)

        let queuedJob = try Self.job(
            id: 41,
            principal: "queued",
            completions: queuedCompletions
        ) {
            .success(.null)
        }
        let queued = Task {
            try await mailbox.submit(queuedJob)
        }
        await waitForQueued(mailbox, count: 1)

        await mailbox.retire()
        let queuedTerminal = try await queued.value
        let runningTerminal = try await running.value
        XCTAssertEqual(queuedTerminal, .providerRetired(.notStarted))
        XCTAssertEqual(runningTerminal, .providerRetired(.unknown))

        await gate.open()
        await waitForCompletions(runningCompletions, count: 1)
        await waitForCompletions(queuedCompletions, count: 1)
        let runningCompletionCount = await runningCompletions.values().count
        let queuedCompletionCount = await queuedCompletions.values().count
        XCTAssertEqual(runningCompletionCount, 1)
        XCTAssertEqual(queuedCompletionCount, 1)
    }

    func testBackgroundCannotConsumeInteractiveReserve() async throws {
        let limits = try IntentMailboxLimits(
            maxRequests: 3,
            maxEncodedBytes: 300,
            maxRequestsPerPrincipal: 3,
            maxEncodedBytesPerPrincipal: 300,
            reservedInteractiveRequests: 1,
            reservedInteractiveBytes: 100
        )
        let mailbox = IntentMailbox(limits: limits)
        let gate = Gate()

        let background1Job = try Self.job(
            id: 50,
            principal: "background-a",
            admission: .background
        ) {
            await gate.wait()
            return .success(.null)
        }
        let background1 = Task {
            try await mailbox.submit(background1Job)
        }
        await waitForRunning(mailbox)
        let background2Job = try Self.job(
            id: 51,
            principal: "background-b",
            admission: .background
        ) {
            .success(.null)
        }
        let background2 = Task {
            try await mailbox.submit(background2Job)
        }
        await waitForQueued(mailbox, count: 1)

        let rejectedBackgroundJob = try Self.job(
            id: 52,
            principal: "background-c",
            admission: .background
        ) {
            .success(.null)
        }
        do {
            _ = try await mailbox.submit(rejectedBackgroundJob)
            XCTFail("Expected reserved-capacity rejection")
        } catch let error as IntentMailboxAdmissionError {
            XCTAssertEqual(error, .overloaded(retryAfterMilliseconds: 25))
        }

        let interactiveJob = try Self.job(
            id: 53,
            principal: "interactive",
            admission: .interactive
        ) {
            .success(.null)
        }
        let interactive = Task {
            try await mailbox.submit(interactiveJob)
        }
        await waitForQueued(mailbox, count: 2)

        await gate.open()
        _ = try await [background1.value, background2.value, interactive.value]
    }

    func testPrincipalSessionRevisionsHaveIndependentMailboxQuotas() async throws {
        let mailbox = IntentMailbox(
            limits: try IntentMailboxLimits(
                maxRequests: 3,
                maxEncodedBytes: 300,
                maxRequestsPerPrincipal: 1,
                maxEncodedBytesPerPrincipal: 100,
                reservedInteractiveRequests: 0,
                reservedInteractiveBytes: 0
            )
        )
        let gate = Gate()
        let revisionOne = try Self.job(
            id: 54,
            principal: "plugin:dev.tenon.example",
            sessionRevision: 1
        ) {
            await gate.wait()
            return .success(.null)
        }
        let first = Task { try await mailbox.submit(revisionOne) }
        await waitForRunning(mailbox)

        let revisionTwo = try Self.job(
            id: 55,
            principal: "plugin:dev.tenon.example",
            sessionRevision: 2
        ) {
            .success(.null)
        }
        let second = Task { try await mailbox.submit(revisionTwo) }
        await waitForQueued(mailbox, count: 1)

        let duplicateRevisionTwo = try Self.job(
            id: 56,
            principal: "plugin:dev.tenon.example",
            sessionRevision: 2
        ) {
            .success(.null)
        }
        do {
            _ = try await mailbox.submit(duplicateRevisionTwo)
            XCTFail("Expected the exact principal revision quota to apply")
        } catch let error as IntentMailboxAdmissionError {
            XCTAssertEqual(
                error,
                .principalQuotaExceeded(retryAfterMilliseconds: 25)
            )
        }

        let snapshot = await mailbox.snapshot()
        XCTAssertEqual(snapshot.admittedByPrincipal.count, 2)
        await gate.open()
        _ = try await [first.value, second.value]
    }

    func testRetireWaitsForOperationAndPhysicalCompletionCallback() async throws {
        let mailbox = IntentMailbox(limits: try Self.limits())
        let operationGate = Gate()
        let completionGate = Gate()
        let completionStarted = BooleanProbe()
        let retirementReturned = BooleanProbe()
        let requestID = UUID()
        let job = try IntentMailboxJob(
            requestID: requestID,
            principal: Self.principal("physical-lifetime"),
            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
            encodedBytes: 1,
            admissionClass: .interactive
        ) {
            await operationGate.wait()
            return .success(.string("late"))
        } physicalCompletion: { _ in
            await completionStarted.setTrue()
            await completionGate.wait()
        }

        let submitted = Task {
            try await mailbox.submit(job)
        }
        await waitForRunning(mailbox)

        let retirement = Task {
            await mailbox.retireAndWaitUntilIdle()
            await retirementReturned.setTrue()
        }
        let terminal = try await submitted.value
        XCTAssertEqual(terminal, .providerRetired(.unknown))
        var didReturn = await retirementReturned.value()
        var snapshot = await mailbox.snapshot()
        XCTAssertFalse(didReturn)
        XCTAssertFalse(snapshot.isPhysicallyIdle)

        await operationGate.open()
        await waitForTrue(completionStarted)
        didReturn = await retirementReturned.value()
        snapshot = await mailbox.snapshot()
        XCTAssertFalse(didReturn)
        XCTAssertFalse(snapshot.isPhysicallyIdle)

        await completionGate.open()
        await retirement.value
        didReturn = await retirementReturned.value()
        snapshot = await mailbox.snapshot()
        XCTAssertTrue(didReturn)
        XCTAssertTrue(snapshot.isPhysicallyIdle)
    }

    func testCancellationUnlinksQueueNodesWithoutTombstones() async throws {
        let queuedCount = 512
        let limits = try IntentMailboxLimits(
            maxRequests: queuedCount + 2,
            maxEncodedBytes: 1024,
            maxRequestsPerPrincipal: queuedCount + 1,
            maxEncodedBytesPerPrincipal: 1024,
            reservedInteractiveRequests: 1,
            reservedInteractiveBytes: 1
        )
        let mailbox = IntentMailbox(limits: limits)
        let blockerGate = Gate()
        let started = StringLog()

        let blocker = try IntentMailboxJob(
            requestID: UUID(),
            principal: Self.principal("blocker"),
            deadline: ContinuousClock.now.advanced(by: .seconds(5)),
            encodedBytes: 0,
            admissionClass: .interactive
        ) {
            await blockerGate.wait()
            return .success(.null)
        }
        let blockerSubmission = Task {
            try await mailbox.submit(blocker)
        }
        await waitForRunning(mailbox)

        var requestIDs: [UUID] = []
        var submissions: [Task<IntentMailboxTerminal, Error>] = []
        requestIDs.reserveCapacity(queuedCount)
        submissions.reserveCapacity(queuedCount)
        for index in 0 ..< queuedCount {
            let requestID = UUID()
            let job = try IntentMailboxJob(
                requestID: requestID,
                principal: Self.principal(index.isMultiple(of: 2) ? "even" : "odd"),
                deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                encodedBytes: 0,
                admissionClass: .interactive
            ) {
                await started.append("unexpected")
                return .success(.null)
            }
            requestIDs.append(requestID)
            submissions.append(Task {
                try await mailbox.submit(job)
            })
        }
        await waitForQueued(mailbox, count: queuedCount)

        for requestID in requestIDs {
            await mailbox.cancel(requestID: requestID)
        }
        for submission in submissions {
            let terminal = try await submission.value
            XCTAssertEqual(terminal, .cancelled(.notStarted))
        }

        let afterCancellation = await mailbox.snapshot()
        XCTAssertEqual(afterCancellation.queuedRequests, 0)
        XCTAssertEqual(afterCancellation.physicalQueueNodes, 0)
        let startsAfterCancellation = await started.values()
        XCTAssertTrue(startsAfterCancellation.isEmpty)

        await waitForAdmittedRequests(mailbox, count: 1)
        let survivor = try IntentMailboxJob(
            requestID: UUID(),
            principal: Self.principal("survivor"),
            deadline: ContinuousClock.now.advanced(by: .seconds(5)),
            encodedBytes: 0,
            admissionClass: .interactive
        ) {
            await started.append("survivor")
            return .success(.null)
        }
        let survivorSubmission = Task {
            try await mailbox.submit(survivor)
        }
        await waitForQueued(mailbox, count: 1)
        await blockerGate.open()
        _ = try await blockerSubmission.value
        let survivorTerminal = try await survivorSubmission.value
        XCTAssertEqual(survivorTerminal, .reply(.success(.null)))
        let finalStarts = await started.values()
        XCTAssertEqual(finalStarts, ["survivor"])
    }

    func testExpirationUnlinksQueueNodesWithoutTombstones() async throws {
        let queuedCount = 128
        let mailbox = IntentMailbox(
            limits: try IntentMailboxLimits(
                maxRequests: queuedCount + 2,
                maxEncodedBytes: 1024,
                maxRequestsPerPrincipal: queuedCount + 1,
                maxEncodedBytesPerPrincipal: 1024,
                reservedInteractiveRequests: 1,
                reservedInteractiveBytes: 1
            )
        )
        let blockerGate = Gate()
        let blocker = try IntentMailboxJob(
            requestID: UUID(),
            principal: Self.principal("blocker"),
            deadline: ContinuousClock.now.advanced(by: .seconds(5)),
            encodedBytes: 0,
            admissionClass: .interactive
        ) {
            await blockerGate.wait()
            return .success(.null)
        }
        let blockerSubmission = Task {
            try await mailbox.submit(blocker)
        }
        await waitForRunning(mailbox)

        var submissions: [Task<IntentMailboxTerminal, Error>] = []
        submissions.reserveCapacity(queuedCount)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for index in 0 ..< queuedCount {
            let job = try IntentMailboxJob(
                requestID: UUID(),
                principal: Self.principal(index.isMultiple(of: 2) ? "even" : "odd"),
                deadline: deadline,
                encodedBytes: 0,
                admissionClass: .interactive
            ) {
                .success(.null)
            }
            submissions.append(Task {
                try await mailbox.submit(job)
            })
        }
        await waitForQueued(mailbox, count: queuedCount)

        for submission in submissions {
            let terminal = try await submission.value
            XCTAssertEqual(terminal, .deadlineExceeded(.notStarted))
        }
        let afterExpiration = await mailbox.snapshot()
        XCTAssertEqual(afterExpiration.queuedRequests, 0)
        XCTAssertEqual(afterExpiration.physicalQueueNodes, 0)

        await blockerGate.open()
        _ = try await blockerSubmission.value
    }

    private static func limits(
        maxConcurrentRequests: Int = 1
    ) throws -> IntentMailboxLimits {
        try IntentMailboxLimits(
            maxRequests: 16,
            maxEncodedBytes: 16 * 1024,
            maxRequestsPerPrincipal: 8,
            maxEncodedBytesPerPrincipal: 8 * 1024,
            reservedInteractiveRequests: 2,
            reservedInteractiveBytes: 1024,
            maxConcurrentRequests: maxConcurrentRequests
        )
    }

    private static func job(
        id: UInt8,
        principal: String,
        sessionRevision: UInt64 = 1,
        deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(2)),
        admission: IntentAdmissionClass = .interactive,
        completions: CompletionLog? = nil,
        operation: @escaping @Sendable () async -> IntentProviderReply
    ) throws -> IntentMailboxJob {
        try IntentMailboxJob(
            requestID: UUID(uuid: (id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            principal: Self.principal(principal, sessionRevision: sessionRevision),
            deadline: deadline,
            encodedBytes: 100,
            admissionClass: admission,
            operation: operation
        ) { completion in
            await completions?.append(completion)
        }
    }

    private static func principal(
        _ id: String,
        sessionRevision: UInt64 = 1
    ) -> IntentPrincipal {
        IntentPrincipal(
            id: id,
            kind: .plugin,
            sessionRevision: sessionRevision
        )
    }

    private func waitForRunning(
        _ mailbox: IntentMailbox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if await mailbox.snapshot().runningRequestIDs.isEmpty == false {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never started a request", file: file, line: line)
    }

    private func waitForQueued(
        _ mailbox: IntentMailbox,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if await mailbox.snapshot().queuedRequests == count {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never reached queued count \(count)", file: file, line: line)
    }

    private func waitForCompletions(
        _ log: CompletionLog,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if await log.values().count == count {
                return
            }
            await Task.yield()
        }
        XCTFail("Completion log never reached \(count)", file: file, line: line)
    }

    private func waitForAdmittedRequests(
        _ mailbox: IntentMailbox,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().admittedRequests == count {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never reached admitted count \(count)", file: file, line: line)
    }

    private func waitForTrue(
        _ probe: BooleanProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await probe.value() {
                return
            }
            await Task.yield()
        }
        XCTFail("Boolean probe never became true", file: file, line: line)
    }
}

/// Counts job starts and lets them block until an expected number have arrived. A test that
/// merely counted starts could pass on a serial lane that ran them one after another; making
/// each job wait for the others turns "did they overlap" into something a serial lane cannot
/// fake.
private actor StartBarrier {
    private let expected: Int
    private(set) var arrived = 0
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() {
        arrived += 1
        if arrived >= expected { release() }
    }

    func arriveAndWait() async {
        arrive()
        await waitForRelease()
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    /// Bounded so a serial lane reports a failure instead of hanging the suite — but bounded by a
    /// deadline, and suspending rather than yielding. A fixed number of `Task.yield()`s reschedules
    /// onto the same cooperative pool without ever handing it back, so on a busy machine the lane
    /// this waits for may never run and the count reports a concurrency failure that did not happen.
    func reachedFullStrength() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if arrived >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return arrived >= expected
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor StringLog {
    private var storage: [String] = []

    func append(_ value: String) {
        storage.append(value)
    }

    func values() -> [String] {
        storage
    }
}

private actor CompletionLog {
    private var storage: [IntentMailboxPhysicalCompletion] = []

    func append(_ value: IntentMailboxPhysicalCompletion) {
        storage.append(value)
    }

    func values() -> [IntentMailboxPhysicalCompletion] {
        storage
    }
}

private actor BooleanProbe {
    private var storage = false

    func setTrue() {
        storage = true
    }

    func value() -> Bool {
        storage
    }
}
