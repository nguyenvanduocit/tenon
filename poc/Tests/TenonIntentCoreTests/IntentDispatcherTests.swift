import Foundation
@testable import TenonIntentCore
import XCTest

final class IntentDispatcherTests: XCTestCase {
    func testInvalidInputIsRejectedBeforeProviderExecutionWithExactSchemaPath() async throws {
        let probe = DispatcherProbe()
        let fixture = try await DispatcherFixture.make { envelope, _ in
            await probe.recordInvocation()
            return .success(Self.validOutput(for: envelope))
        }

        let result = await fixture.send(input: .object(["value": .string("wrong")]))

        let failure = try unwrapFailure(result)
        XCTAssertEqual(failure.error.code, .kernel(.invalidInput))
        XCTAssertEqual(
            failure.error.details,
            .object([
                "issues": .array([
                    .object([
                        "location": .string("input"),
                        "path": .string("/value"),
                        "schemaPath": .string("/properties/value/type"),
                        "keyword": .string("type"),
                    ])
                ])
            ])
        )
        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testInvalidProviderOutputIsRejectedAtTheCommonBoundary() async throws {
        let fixture = try await DispatcherFixture.make { _, _ in
            .success(.object(["echo": .string("wrong")]))
        }

        let result = await fixture.send(value: 7)

        let failure = try unwrapFailure(result)
        XCTAssertEqual(failure.error.code, .kernel(.invalidOutput))
        XCTAssertEqual(failure.error.outcome, .unknown)
        XCTAssertEqual(failure.meta.providerID, fixture.providerID)
    }

    func testPolicyConfirmationDenialPreventsProviderExecution() async throws {
        let confirmation = DispatcherConfirmationProbe(decision: .denied)
        let invocation = DispatcherProbe()
        let fixture = try await DispatcherFixture.make(
            confirmationAuthorizer: IntentConfirmationAuthorizer { request in
                await confirmation.authorize(request)
            }
        ) { _, _ in
            await invocation.recordInvocation()
            return .success(.object(["echo": .integer(1)]))
        }

        let result = await fixture.send(value: 1)

        let failure = try unwrapFailure(result)
        XCTAssertEqual(failure.error.code, .kernel(.denied))
        XCTAssertEqual(
            failure.error.details,
            .object(["reason": .string("confirmation-denied")])
        )
        XCTAssertEqual(failure.error.outcome, .notStarted)
        let invocationCount = await invocation.invocationCount()
        let confirmationCount = await confirmation.requestCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(confirmationCount, 1)
        let registry = await fixture.registry.snapshot()
        XCTAssertEqual(registry.generations.first?.selectionCount, 0)
        let telemetry = await fixture.telemetry.snapshot()
        XCTAssertEqual(
            telemetry.completed.first {
                $0.requestID == failure.meta.requestID
            }?.confirmationDisposition,
            .denied
        )
    }

    func testAlwaysConfirmationApprovalReceivesAuthoritativeRequest() async throws {
        let confirmation = DispatcherConfirmationProbe(decision: .approved)
        let fixture = try await DispatcherFixture.make(
            effects: try confirmationEffects(.always),
            confirmationAuthorizer: IntentConfirmationAuthorizer { request in
                await confirmation.authorize(request)
            }
        ) { envelope, _ in
            .success(Self.validOutput(for: envelope))
        }

        let result = await fixture.send(value: 7)

        XCTAssertEqual(
            try unwrapSuccess(result).value,
            .object(["echo": .integer(7)])
        )
        let recordedRequest = await confirmation.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.envelope.caller, fixture.caller)
        XCTAssertEqual(request.envelope.name, fixture.intentID)
        XCTAssertEqual(request.envelope.input, .object(["value": .integer(7)]))
        XCTAssertEqual(request.contract.effects.confirmation, .always)
        XCTAssertEqual(request.providerID, fixture.providerID)
    }

    func testNeverConfirmationBypassesDenyingAuthorizer() async throws {
        let confirmation = DispatcherConfirmationProbe(decision: .denied)
        let fixture = try await DispatcherFixture.make(
            effects: try confirmationEffects(.never),
            confirmationAuthorizer: IntentConfirmationAuthorizer { request in
                await confirmation.authorize(request)
            }
        ) { envelope, _ in
            .success(Self.validOutput(for: envelope))
        }

        let result = await fixture.send(value: 9)

        XCTAssertEqual(
            try unwrapSuccess(result).value,
            .object(["echo": .integer(9)])
        )
        let confirmationCount = await confirmation.requestCount()
        XCTAssertEqual(confirmationCount, 0)
    }

    func testKeyedReplayDoesNotRequestConfirmationOrExecuteAgain() async throws {
        let confirmation = DispatcherConfirmationProbe(decision: .approved)
        let invocation = DispatcherProbe()
        let fixture = try await DispatcherFixture.make(
            effects: try keyedEffects(confirmation: .always),
            confirmationAuthorizer: IntentConfirmationAuthorizer { request in
                await confirmation.authorize(request)
            }
        ) { envelope, _ in
            await invocation.recordInvocation()
            return .success(Self.validOutput(for: envelope))
        }

        let first = await fixture.send(value: 11, idempotencyKey: "confirmed-once")
        let replay = await fixture.send(value: 11, idempotencyKey: "confirmed-once")

        XCTAssertEqual(first, replay)
        let confirmationCount = await confirmation.requestCount()
        let invocationCount = await invocation.invocationCount()
        XCTAssertEqual(confirmationCount, 1)
        XCTAssertEqual(invocationCount, 1)
    }

    func testRepeatedInvalidProviderResultsQuarantineExactGeneration() async throws {
        let fixture = try await DispatcherFixture.make { _, _ in
            .success(.object(["echo": .string("wrong")]))
        }

        for value in 1 ... 3 {
            let result = await fixture.send(value: Int64(value))
            XCTAssertEqual(
                try unwrapFailure(result).error.code,
                .kernel(.invalidOutput)
            )
        }

        let unavailable = try unwrapFailure(await fixture.send(value: 4))
        XCTAssertEqual(unavailable.error.code, .kernel(.noProvider))
        let snapshot = await fixture.registry.snapshot()
        XCTAssertEqual(snapshot.generations.first?.isHealthy, false)
    }

    func testValidProviderResultResetsInvalidResultQuarantineCounter() async throws {
        let sequence = DispatcherValiditySequence([false, true, false, false])
        let fixture = try await DispatcherFixture.make { envelope, _ in
            if await sequence.next() {
                return .success(Self.validOutput(for: envelope))
            }
            return .success(.object(["echo": .string("wrong")]))
        }

        for value in 1 ... 4 {
            _ = await fixture.send(value: Int64(value))
        }

        let snapshot = await fixture.registry.snapshot()
        XCTAssertEqual(snapshot.generations.first?.isHealthy, true)
    }

    func testConcurrentKeyedCallsExecuteOnceAndJoinTheSameTerminalResult() async throws {
        let gate = DispatcherGate()
        let probe = DispatcherProbe()
        let fixture = try await DispatcherFixture.make(
            effects: try keyedEffects()
        ) { envelope, _ in
            await probe.recordInvocation()
            await gate.wait()
            return .success(Self.validOutput(for: envelope))
        }

        let first = Task {
            await fixture.send(value: 11, idempotencyKey: "same-operation")
        }
        await waitForInvocationCount(probe, expected: 1)
        let second = Task {
            await fixture.send(value: 11, idempotencyKey: "same-operation")
        }
        await Task.yield()
        await gate.open()

        let results = await [first.value, second.value]
        XCTAssertEqual(results[0], results[1])
        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(try unwrapSuccess(results[0]).value, .object(["echo": .integer(11)]))
    }

    func testRetainedKeyWithChangedInputConflictsWithoutSecondExecution() async throws {
        let probe = DispatcherProbe()
        let fixture = try await DispatcherFixture.make(
            effects: try keyedEffects()
        ) { envelope, _ in
            await probe.recordInvocation()
            return .success(Self.validOutput(for: envelope))
        }

        _ = await fixture.send(value: 1, idempotencyKey: "stable-key")
        let changed = await fixture.send(value: 2, idempotencyKey: "stable-key")

        let failure = try unwrapFailure(changed)
        XCTAssertEqual(failure.error.code, .kernel(.idempotencyConflict))
        XCTAssertEqual(failure.error.outcome, .notStarted)
        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testNestedCallUsesProviderAuthorityRatherThanOriginalCallerGrant() async throws {
        let nestedResult = DispatcherResultProbe()
        let fixture = try await DispatcherFixture.make { envelope, context in
            await nestedResult.record(
                await context.send(
                    IntentProviderSendRequest(
                        intentID: envelope.name,
                        input: envelope.input
                    )
                )
            )
            return .success(Self.validOutput(for: envelope))
        }

        _ = await fixture.send(value: 3)

        let failure = try unwrapFailure(await nestedResult.value())
        XCTAssertEqual(failure.error.code, .kernel(.denied))
        XCTAssertEqual(
            failure.error.details,
            .object(["reason": .string("missing-capability")])
        )
    }

    func testNestedSelfCallWithProviderGrantFailsCycleBeforeDeadlock() async throws {
        let nestedResult = DispatcherResultProbe()
        let fixture = try await DispatcherFixture.make { envelope, context in
            await nestedResult.record(
                await context.send(
                    IntentProviderSendRequest(
                        intentID: envelope.name,
                        input: envelope.input
                    )
                )
            )
            return .success(Self.validOutput(for: envelope))
        }
        try await fixture.policy.replaceGrants(
            [fixture.unrestrictedGrant],
            for: IntentProviderOwner.core.principal(sessionRevision: 1)
        )

        let outer = await fixture.send(value: 5)

        XCTAssertEqual(try unwrapSuccess(outer).value, .object(["echo": .integer(5)]))
        let nestedFailure = try unwrapFailure(await nestedResult.value())
        XCTAssertEqual(nestedFailure.error.code, .kernel(.cycleDetected))
        XCTAssertEqual(nestedFailure.error.outcome, .notStarted)
    }

    func testDiscoveryIsPrincipalScopedCachedAndTracksProviderAvailability() async throws {
        let fixture = try await DispatcherFixture.make { envelope, _ in
            .success(Self.validOutput(for: envelope))
        }

        let first = await fixture.dispatcher.discover(for: fixture.caller)
        let cached = await fixture.dispatcher.discover(for: fixture.caller)
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first.items.map(\.name), [fixture.intentID])
        XCTAssertEqual(first.items.first?.activeProviders, [fixture.providerID])
        XCTAssertEqual(first.items.first?.isAvailable, true)

        let nextGeneration = IntentPrincipal(
            id: fixture.caller.id,
            kind: fixture.caller.kind,
            sessionRevision: fixture.caller.sessionRevision + 1
        )
        let hidden = await fixture.dispatcher.discover(for: nextGeneration)
        XCTAssertTrue(hidden.items.isEmpty)
        XCTAssertNotEqual(hidden.revision, first.revision)
        XCTAssertEqual(hidden.revision.principal, nextGeneration)

        try await fixture.registry.disable(fixture.providerID)
        let callable = await fixture.dispatcher.discover(for: fixture.caller)
        XCTAssertTrue(callable.items.isEmpty)
        XCTAssertNotEqual(callable.revision.providers, first.revision.providers)

        let catalog = await fixture.dispatcher.discover(
            for: fixture.caller,
            projection: .catalog
        )
        XCTAssertEqual(catalog.items.map(\.name), [fixture.intentID])
        XCTAssertEqual(catalog.items.first?.activeProviders, [])
        XCTAssertEqual(catalog.items.first?.isAvailable, false)
        XCTAssertEqual(catalog.revision.projection, .catalog)
        XCTAssertNotEqual(catalog.revision, callable.revision)
    }

    func testGrantRevocationCancelsQueuedAndRunningCallsAtPolicyFence() async throws {
        let gate = DispatcherGate()
        let probe = DispatcherProbe()
        let fixture = try await DispatcherFixture.make { envelope, _ in
            await probe.recordInvocation()
            await gate.wait()
            return .success(Self.validOutput(for: envelope))
        }

        let running = Task { await fixture.send(value: 21) }
        await waitForInvocationCount(probe, expected: 1)
        let queued = Task { await fixture.send(value: 22) }
        await waitForQueuedRequest(fixture.mailbox)

        try await fixture.policy.replaceGrants([], for: fixture.caller)

        let runningFailure = try unwrapFailure(await running.value)
        let queuedFailure = try unwrapFailure(await queued.value)
        XCTAssertEqual(runningFailure.error.code, .kernel(.cancelled))
        XCTAssertEqual(runningFailure.error.outcome, .unknown)
        XCTAssertEqual(queuedFailure.error.code, .kernel(.cancelled))
        XCTAssertEqual(queuedFailure.error.outcome, .notStarted)
        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 1)

        await gate.open()
        await waitForMailboxIdle(fixture.mailbox)
    }

    func testDispatcherReportsEnvelopeDeadlineInsteadOfProviderCancellation()
        async throws
    {
        let fixture = try await DispatcherFixture.make { envelope, _ in
            try? await Task.sleep(for: .seconds(5))
            return .success(Self.validOutput(for: envelope))
        }

        let result = await fixture.send(
            value: 23,
            requestedTimeout: .milliseconds(25)
        )

        let failure = try unwrapFailure(result)
        XCTAssertEqual(failure.error.code, .kernel(.deadlineExceeded))
        XCTAssertEqual(failure.error.outcome, .unknown)
        await waitForMailboxIdle(fixture.mailbox)
    }

    private static func validOutput(for envelope: IntentEnvelope) -> IntentValue {
        guard case let .object(input) = envelope.input,
              let value = input["value"]
        else {
            return .object(["echo": .integer(-1)])
        }
        return .object(["echo": value])
    }

    private func unwrapFailure(
        _ result: IntentResult?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IntentFailure {
        let result = try XCTUnwrap(result, file: file, line: line)
        guard case let .failure(failure) = result else {
            XCTFail("Expected failure, got \(result)", file: file, line: line)
            throw DispatcherTestError.unexpectedResult
        }
        return failure
    }

    private func unwrapSuccess(
        _ result: IntentResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IntentSuccess {
        guard case let .success(success) = result else {
            XCTFail("Expected success, got \(result)", file: file, line: line)
            throw DispatcherTestError.unexpectedResult
        }
        return success
    }

    private func waitForInvocationCount(
        _ probe: DispatcherProbe,
        expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await probe.invocationCount() == expected {
                return
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Provider never reached \(expected) invocation(s)", file: file, line: line)
    }

    private func waitForQueuedRequest(
        _ mailbox: IntentMailbox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().queuedRequests == 1 {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never queued the request", file: file, line: line)
    }

    private func waitForMailboxIdle(
        _ mailbox: IntentMailbox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().isPhysicallyIdle {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never became physically idle", file: file, line: line)
    }
}

private struct DispatcherFixture: Sendable {
    let intentID: IntentID
    let providerID: ProviderID
    let caller: IntentPrincipal
    let capability: CapabilityID
    let policy: PolicyEngine
    let registry: ProviderRegistry
    let mailbox: IntentMailbox
    let telemetry: IntentTelemetry
    let dispatcher: IntentDispatcher

    var unrestrictedGrant: CapabilityGrant {
        CapabilityGrant(
            capability: capability,
            scope: CapabilityGrantScope(
                workspaces: .any,
                panes: .any,
                filesystem: .none
            )
        )
    }

    static func make(
        effects: IntentEffects = .pessimistic,
        confirmationAuthorizer: IntentConfirmationAuthorizer =
            IntentConfirmationAuthorizer { _ in .approved },
        operation: @escaping IntentProviderBinding.Operation
    ) async throws -> DispatcherFixture {
        let intentID = try IntentID("test.echo.v1")
        let providerID = try ProviderID("dev.tenon.test-provider")
        let capability = try CapabilityID("test.invoke")
        let caller = IntentPrincipal(
            id: "plugin:dev.tenon.test:fixture",
            kind: .plugin,
            sessionRevision: 1
        )
        let catalog = ContractCatalog()
        _ = try await catalog.register(
            IntentContractDeclaration(
                name: intentID,
                contractClass: .sealed,
                owner: .core,
                inputSchema: objectSchema(
                    properties: [
                        "value": .object(["type": .string("integer")])
                    ],
                    required: ["value"]
                ),
                outputSchema: objectSchema(
                    properties: [
                        "echo": .object(["type": .string("integer")])
                    ],
                    required: ["echo"]
                ),
                audiences: [.core, .plugin],
                effects: effects,
                title: "Echo",
                description: nil,
                deprecated: false,
                domainErrors: []
            )
        )

        let policy = PolicyEngine()
        try await policy.replaceDeclaredUses([intentID], for: caller)
        let grant = CapabilityGrant(
            capability: capability,
            scope: CapabilityGrantScope(
                workspaces: .any,
                panes: .any,
                filesystem: .none
            )
        )
        try await policy.replaceGrants([grant], for: caller)

        let registry = ProviderRegistry()
        let mailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let candidate = try ProviderGenerationCandidate(
            providerID: providerID,
            owner: .core,
            principal: IntentProviderOwner.core.principal(sessionRevision: 1),
            generation: 1,
            bindings: [
                IntentProviderBinding(
                    intentID: intentID,
                    operation: operation
                )
            ],
            policyFingerprint: try PolicyFingerprint(
                canonicalPolicy: .object(["provider": .string(providerID.rawValue)])
            ),
            mailbox: mailbox
        )
        try await registry.stage(candidate)
        try await registry.activate(providerID: providerID, generation: 1)

        let idempotency = try IntentIdempotencyStore(
            limits: IntentIdempotencyLimits(),
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let telemetry = try IntentTelemetry()
        let dispatcher = IntentDispatcher(
            catalog: catalog,
            policy: policy,
            registry: registry,
            idempotency: idempotency,
            telemetry: telemetry,
            limits: try IntentDispatcherLimits(),
            confirmationAuthorizer: confirmationAuthorizer
        )
        try await dispatcher.registerRule(
            IntentDispatchRule(
                intentID: intentID,
                capabilityBindings: [
                    IntentCapabilityBinding(capability: capability)
                ],
                exposure: IntentExposure(
                    discoverableBy: [.core, .plugin],
                    invocableBy: [.core, .plugin]
                ),
                trustedDefault: providerID,
                allowsAutomaticSelection: false,
                providerConsent: .never,
                admissionClass: .interactive
            )
        )

        return DispatcherFixture(
            intentID: intentID,
            providerID: providerID,
            caller: caller,
            capability: capability,
            policy: policy,
            registry: registry,
            mailbox: mailbox,
            telemetry: telemetry,
            dispatcher: dispatcher
        )
    }

    func send(
        value: Int64,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil
    ) async -> IntentResult {
        await send(
            input: .object(["value": .integer(value)]),
            idempotencyKey: idempotencyKey,
            requestedTimeout: requestedTimeout
        )
    }

    func send(
        input: IntentValue,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil
    ) async -> IntentResult {
        await dispatcher.send(
            IntentDispatchRequest(
                intentID: intentID,
                input: input,
                caller: caller,
                idempotencyKey: idempotencyKey,
                requestedTimeout: requestedTimeout
            )
        )
    }
}

private actor DispatcherProbe {
    private var count = 0

    func recordInvocation() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

private actor DispatcherResultProbe {
    private var result: IntentResult?

    func record(_ result: IntentResult) {
        self.result = result
    }

    func value() -> IntentResult? {
        result
    }
}

private actor DispatcherValiditySequence {
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        values.isEmpty ? true : values.removeFirst()
    }
}

private actor DispatcherConfirmationProbe {
    private let decision: IntentConfirmationDecision
    private var requests: [IntentConfirmationRequest] = []

    init(decision: IntentConfirmationDecision) {
        self.decision = decision
    }

    func authorize(
        _ request: IntentConfirmationRequest
    ) -> IntentConfirmationDecision {
        requests.append(request)
        return decision
    }

    func requestCount() -> Int {
        requests.count
    }

    func firstRequest() -> IntentConfirmationRequest? {
        requests.first
    }
}

private actor DispatcherGate {
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

private func keyedEffects(
    confirmation: IntentConfirmation = .never
) throws -> IntentEffects {
    try IntentEffects(
        kind: .write,
        idempotency: .keyed,
        retentionMilliseconds: 60_000,
        confirmation: confirmation,
        external: false
    )
}

private func confirmationEffects(
    _ confirmation: IntentConfirmation
) throws -> IntentEffects {
    try IntentEffects(
        kind: .write,
        idempotency: .none,
        retentionMilliseconds: nil,
        confirmation: confirmation,
        external: false
    )
}

private enum DispatcherTestError: Error {
    case unexpectedResult
}
