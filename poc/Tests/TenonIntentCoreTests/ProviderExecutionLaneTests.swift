import XCTest
@testable import TenonIntentCore

final class ProviderExecutionLaneTests: XCTestCase {
    func testCandidateRejectsIncompleteDuplicateAndUnexpectedLaneCoverage() throws {
        let fixture = try LaneFixture()
        let firstMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let secondMailbox = IntentMailbox(limits: try IntentMailboxLimits())

        XCTAssertThrowsError(
            try fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderGenerationError,
                .missingExecutionLaneIntent(fixture.secondIntent)
            )
        }

        XCTAssertThrowsError(
            try fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                    try ProviderExecutionLane(
                        intentIDs: [
                            fixture.firstIntent,
                            fixture.secondIntent,
                        ],
                        mailbox: secondMailbox
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderGenerationError,
                .duplicateExecutionLaneIntent(fixture.firstIntent)
            )
        }

        let unknownIntent = try IntentID("dev.tenon.test.unknown.v1")
        XCTAssertThrowsError(
            try fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [
                            fixture.firstIntent,
                            fixture.secondIntent,
                            unknownIntent,
                        ],
                        mailbox: firstMailbox
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderGenerationError,
                .unexpectedExecutionLaneIntent(unknownIntent)
            )
        }

        XCTAssertThrowsError(
            try fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                    try ProviderExecutionLane(
                        intentIDs: [fixture.secondIntent],
                        mailbox: firstMailbox
                    ),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderGenerationError,
                .reusedExecutionMailbox
            )
        }
    }

    func testBlockedLaneDoesNotDelayAnIndependentLane() async throws {
        let fixture = try LaneFixture()
        let firstMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let secondMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let registry = ProviderRegistry()
        let blocker = LaneGate()

        try await registry.stage(
            fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                    try ProviderExecutionLane(
                        intentIDs: [fixture.secondIntent],
                        mailbox: secondMailbox
                    ),
                ]
            )
        )
        try await registry.activate(
            providerID: fixture.providerID,
            generation: 1
        )

        let firstLease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.firstIntent,
                trustedDefault: fixture.providerID
            )
        )
        let secondLease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.secondIntent,
                trustedDefault: fixture.providerID
            )
        )
        XCTAssertTrue(firstLease.mailbox === firstMailbox)
        XCTAssertTrue(secondLease.mailbox === secondMailbox)

        let firstRequestID = UUID()
        let firstJob = try Self.job(requestID: firstRequestID) {
            await blocker.wait()
            return .success(.string("first"))
        }
        let firstTask = Task {
            try await firstMailbox.submit(firstJob)
        }
        await waitForRunning(firstMailbox, requestID: firstRequestID)

        let secondResult = await mailboxResultWithin(.milliseconds(250)) {
            try? await secondLease.mailbox.submit(
                try Self.job {
                    .success(.string("second"))
                }
            )
        }
        XCTAssertEqual(
            secondResult,
            .reply(.success(.string("second")))
        )

        await blocker.open()
        let firstResult = try await firstTask.value
        XCTAssertEqual(
            firstResult,
            .reply(.success(.string("first")))
        )
        await firstLease.release()
        await secondLease.release()
    }

    func testOneLanePreservesFIFOAcrossItsContracts() async throws {
        let fixture = try LaneFixture()
        let mailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let registry = ProviderRegistry()
        let blocker = LaneGate()
        let secondProbe = LaneProbe()

        try await registry.stage(
            fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [
                            fixture.firstIntent,
                            fixture.secondIntent,
                        ],
                        mailbox: mailbox
                    ),
                ]
            )
        )
        try await registry.activate(
            providerID: fixture.providerID,
            generation: 1
        )
        let firstLease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.firstIntent,
                trustedDefault: fixture.providerID
            )
        )
        let secondLease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.secondIntent,
                trustedDefault: fixture.providerID
            )
        )
        XCTAssertTrue(firstLease.mailbox === secondLease.mailbox)

        let firstRequestID = UUID()
        let firstJob = try Self.job(requestID: firstRequestID) {
            await blocker.wait()
            return .success(.string("first"))
        }
        let firstTask = Task {
            try await mailbox.submit(firstJob)
        }
        await waitForRunning(mailbox, requestID: firstRequestID)

        let secondJob = try Self.job {
            await secondProbe.record()
            return .success(.string("second"))
        }
        let secondTask = Task {
            try await mailbox.submit(secondJob)
        }
        await waitForQueued(mailbox, count: 1)
        let countWhileBlocked = await secondProbe.count()
        XCTAssertEqual(countWhileBlocked, 0)

        await blocker.open()
        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        let finalCount = await secondProbe.count()
        XCTAssertEqual(firstResult, .reply(.success(.string("first"))))
        XCTAssertEqual(secondResult, .reply(.success(.string("second"))))
        XCTAssertEqual(finalCount, 1)
        await firstLease.release()
        await secondLease.release()
    }

    func testGlobalAdmissionSpansLanesAndCancellationReleasesAfterPhysicalCompletion()
        async throws
    {
        let fixture = try LaneFixture()
        let firstMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let secondMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let blocker = LaneGate()
        let secondProbe = LaneProbe()
        let catalog = ContractCatalog()
        let policy = PolicyEngine()
        let registry = ProviderRegistry()
        let firstCaller = IntentPrincipal(
            id: "plugin:lane-tests:first",
            kind: .plugin,
            sessionRevision: 1
        )
        let secondCaller = IntentPrincipal(
            id: "plugin:lane-tests:second",
            kind: .plugin,
            sessionRevision: 1
        )
        let intentIDs = [fixture.firstIntent, fixture.secondIntent]

        for intentID in intentIDs {
            _ = try await catalog.register(
                IntentContractDeclaration(
                    name: intentID,
                    contractClass: .sealed,
                    owner: .core,
                    inputSchema: objectSchema(properties: [:]),
                    outputSchema: objectSchema(properties: [:]),
                    audiences: [.plugin],
                    effects: .pessimistic,
                    title: intentID.rawValue,
                    description: nil,
                    deprecated: false,
                    domainErrors: []
                )
            )
        }
        try await policy.replaceDeclaredUses(
            Set(intentIDs),
            for: firstCaller
        )
        try await policy.replaceDeclaredUses(
            Set(intentIDs),
            for: secondCaller
        )
        try await registry.stage(
            fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                    try ProviderExecutionLane(
                        intentIDs: [fixture.secondIntent],
                        mailbox: secondMailbox
                    ),
                ],
                firstOperation: { _, _ in
                    await blocker.wait()
                    return .success(.object([:]))
                },
                secondOperation: { _, _ in
                    await secondProbe.record()
                    return .success(.object([:]))
                }
            )
        )
        try await registry.activate(
            providerID: fixture.providerID,
            generation: 1
        )

        let dispatcher = IntentDispatcher(
            catalog: catalog,
            policy: policy,
            registry: registry,
            idempotency: try IntentIdempotencyStore(
                limits: IntentIdempotencyLimits(),
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            ),
            telemetry: try IntentTelemetry(),
            limits: try IntentDispatcherLimits(
                maxInFlightRequests: 1,
                maxInFlightEncodedBytes: 1_024,
                maxInFlightPerPrincipal: 1,
                reservedInteractiveRequests: 0,
                reservedInteractiveBytes: 0
            ),
            confirmationAuthorizer: IntentConfirmationAuthorizer { _ in .allowOnce }
        )
        for intentID in intentIDs {
            try await dispatcher.registerRule(
                IntentDispatchRule(
                    intentID: intentID,
                    capabilityBindings: [],
                    exposure: IntentExposure(
                        discoverableBy: [.plugin],
                        invocableBy: [.plugin]
                    ),
                    trustedDefault: fixture.providerID,
                    allowsAutomaticSelection: false,
                    providerConsent: .never,
                    admissionClass: .interactive
                )
            )
        }

        let firstTask = Task {
            await dispatcher.send(
                IntentDispatchRequest(
                    intentID: fixture.firstIntent,
                    input: .object([:]),
                    caller: firstCaller
                )
            )
        }
        await waitForRunningRequest(firstMailbox)
        let runningSnapshot = await dispatcher.snapshot()
        XCTAssertEqual(runningSnapshot.inFlightRequests, 1)

        let blockedAcrossLane = await dispatcher.send(
            IntentDispatchRequest(
                intentID: fixture.secondIntent,
                input: .object([:]),
                caller: secondCaller
            )
        )
        assertKernelFailure(blockedAcrossLane, code: .overloaded)
        let blockedInvocationCount = await secondProbe.count()
        XCTAssertEqual(blockedInvocationCount, 0)

        firstTask.cancel()
        let cancelled = await firstTask.value
        assertKernelFailure(
            cancelled,
            code: .cancelled,
            outcome: .unknown
        )
        let cancelledSnapshot = await dispatcher.snapshot()
        let cancelledMailboxSnapshot = await firstMailbox.snapshot()
        XCTAssertEqual(cancelledSnapshot.inFlightRequests, 1)
        XCTAssertEqual(cancelledSnapshot.inFlightByPrincipal[firstCaller], 1)
        XCTAssertFalse(cancelledMailboxSnapshot.isPhysicallyIdle)

        let blockedAfterLogicalCancellation = await dispatcher.send(
            IntentDispatchRequest(
                intentID: fixture.secondIntent,
                input: .object([:]),
                caller: secondCaller
            )
        )
        assertKernelFailure(
            blockedAfterLogicalCancellation,
            code: .overloaded
        )

        await blocker.open()
        await waitForInFlightRequests(dispatcher, count: 0)
        let releasedSnapshot = await dispatcher.snapshot()
        XCTAssertNil(releasedSnapshot.inFlightByPrincipal[firstCaller])

        let admittedAfterPhysicalCompletion = await dispatcher.send(
            IntentDispatchRequest(
                intentID: fixture.secondIntent,
                input: .object([:]),
                caller: secondCaller
            )
        )
        guard case .success = admittedAfterPhysicalCompletion else {
            return XCTFail(
                "Expected second lane admission after physical completion"
            )
        }
        let finalInvocationCount = await secondProbe.count()
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testRetirementClosesEveryLaneAndWaitsForPhysicalCompletion() async throws {
        let fixture = try LaneFixture()
        let firstMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let secondMailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let registry = ProviderRegistry()
        let blocker = LaneGate()

        try await registry.stage(
            fixture.candidate(
                lanes: [
                    try ProviderExecutionLane(
                        intentIDs: [fixture.firstIntent],
                        mailbox: firstMailbox
                    ),
                    try ProviderExecutionLane(
                        intentIDs: [fixture.secondIntent],
                        mailbox: secondMailbox
                    ),
                ]
            )
        )
        try await registry.activate(
            providerID: fixture.providerID,
            generation: 1
        )
        let lease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.firstIntent,
                trustedDefault: fixture.providerID
            )
        )

        let requestID = UUID()
        let blockingJob = try Self.job(requestID: requestID) {
            await blocker.wait()
            return .success(.string("late"))
        }
        let submitted = Task {
            try await firstMailbox.submit(blockingJob)
        }
        await waitForRunning(firstMailbox, requestID: requestID)

        try await registry.disable(fixture.providerID)
        let retiredResult = try await submitted.value
        XCTAssertEqual(
            retiredResult,
            .providerRetired(.unknown)
        )
        await lease.release()
        await waitForRetired(secondMailbox)

        let beforeCompletion = await registry.snapshot()
        let firstBeforeCompletion = await firstMailbox.snapshot()
        let secondBeforeCompletion = await secondMailbox.snapshot()
        XCTAssertEqual(beforeCompletion.residentGenerations, 1)
        XCTAssertFalse(firstBeforeCompletion.isPhysicallyIdle)
        XCTAssertTrue(secondBeforeCompletion.isPhysicallyIdle)

        await blocker.open()
        await waitForResidentGenerations(registry, count: 0)
    }
}

private extension ProviderExecutionLaneTests {
    static func job(
        requestID: UUID = UUID(),
        operation: @escaping IntentMailboxJob.Operation
    ) throws -> IntentMailboxJob {
        try IntentMailboxJob(
            requestID: requestID,
            principal: IntentPrincipal(
                id: "plugin:lane-tests",
                kind: .plugin,
                sessionRevision: 1
            ),
            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
            encodedBytes: 1,
            admissionClass: .background,
            operation: operation
        )
    }

    func mailboxResultWithin(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> IntentMailboxTerminal?
    ) async -> IntentMailboxTerminal? {
        await withTaskGroup(of: IntentMailboxTerminal?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func waitForRunning(
        _ mailbox: IntentMailbox,
        requestID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await mailbox.snapshot().runningRequestIDs.contains(requestID) {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Mailbox never started request", file: file, line: line)
    }

    func waitForRunningRequest(
        _ mailbox: IntentMailbox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await mailbox.snapshot().runningRequestIDs.isEmpty == false {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Mailbox never started a request", file: file, line: line)
    }

    func waitForInFlightRequests(
        _ dispatcher: IntentDispatcher,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await dispatcher.snapshot().inFlightRequests == count {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail(
            "Dispatcher never reached \(count) in-flight requests",
            file: file,
            line: line
        )
    }

    func assertKernelFailure(
        _ result: IntentResult,
        code: IntentKernelErrorCode,
        outcome: IntentOutcome? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(failure) = result else {
            return XCTFail(
                "Expected kernel failure, got \(result)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            failure.error.code,
            .kernel(code),
            file: file,
            line: line
        )
        if let outcome {
            XCTAssertEqual(
                failure.error.outcome,
                outcome,
                file: file,
                line: line
            )
        }
    }

    func waitForRetired(
        _ mailbox: IntentMailbox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().isRetired {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never retired", file: file, line: line)
    }

    func waitForQueued(
        _ mailbox: IntentMailbox,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().queuedRequests == count {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Mailbox never reached \(count) queued requests",
            file: file,
            line: line
        )
    }

    func waitForResidentGenerations(
        _ registry: ProviderRegistry,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await registry.snapshot().residentGenerations == count {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(
            "Registry never reached \(count) resident generations",
            file: file,
            line: line
        )
    }
}

private struct LaneFixture {
    let firstIntent: IntentID
    let secondIntent: IntentID
    let providerID: ProviderID
    let owner: IntentProviderOwner

    init() throws {
        firstIntent = try IntentID("dev.tenon.test.first.v1")
        secondIntent = try IntentID("dev.tenon.test.second.v1")
        providerID = try ProviderID("dev.tenon.test.provider")
        owner = .plugin(
            id: PluginID("dev.tenon.test.provider"),
            installationID: UUID()
        )
    }

    func candidate(
        lanes: [ProviderExecutionLane],
        firstOperation: @escaping IntentProviderBinding.Operation = {
            _, _ in .success(.string("first"))
        },
        secondOperation: @escaping IntentProviderBinding.Operation = {
            _, _ in .success(.string("second"))
        }
    ) throws -> ProviderGenerationCandidate {
        try ProviderGenerationCandidate(
            providerID: providerID,
            owner: owner,
            principal: owner.principal(sessionRevision: 1),
            generation: 1,
            bindings: [
                IntentProviderBinding(
                    intentID: firstIntent,
                    operation: firstOperation
                ),
                IntentProviderBinding(
                    intentID: secondIntent,
                    operation: secondOperation
                ),
            ],
            policyFingerprint: try PolicyFingerprint(
                canonicalPolicy: .object(["fixture": .string("lanes")])
            ),
            executionLanes: lanes
        )
    }
}

private actor LaneGate {
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
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor LaneProbe {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}
