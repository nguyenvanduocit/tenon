import Foundation
@testable import TenonIntentCore
import XCTest

/// `.policy` lets the user approve one wave, remember one caller/contract pair, or trust
/// one caller for every policy-confirmed contract. `.always` keeps asking and remembers
/// nothing, which is what makes it a different mode.
final class CallerConsentTests: XCTestCase {
    func testConfirmationDecisionInventoryIsClosed() {
        XCTAssertEqual(
            IntentConfirmationDecision.allCases,
            [.allowOnce, .alwaysAllow, .alwaysAllowForCaller, .denied]
        )
    }

    func testStandingConsentSkipsTheConfirmationAuthorizer() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        try await fixture.policy.grantStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )

        let result = await fixture.send(value: 1)

        XCTAssertEqual(try unwrapSuccess(result), .object(["echo": .integer(1)]))
        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 0)
        // Standing consent records `.approved`, not `.notRequired`: the user did approve
        // this, just earlier. `.notRequired` stays reserved for `.never` contracts, so the
        // audit trail keeps "consented once" distinct from "never needed consent".
        await waitForTelemetryCompletion(fixture.telemetry)
        let telemetry = await fixture.telemetry.snapshot()
        XCTAssertEqual(
            telemetry.completed.first?.confirmationDisposition,
            .approved
        )
    }

    func testAlwaysAllowIsRememberedSoTheUserIsAskedOnce() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )

        _ = await fixture.send(value: 1)
        _ = await fixture.send(value: 2)
        let result = await fixture.send(value: 3)

        XCTAssertEqual(try unwrapSuccess(result), .object(["echo": .integer(3)]))
        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 1)
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasConsent)
    }

    func testAllowOnceApprovesOnlyTheCurrentWave() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .allowOnce)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )

        let first = await fixture.send(value: 1)
        let second = await fixture.send(value: 2)

        XCTAssertEqual(try unwrapSuccess(first), .object(["echo": .integer(1)]))
        XCTAssertEqual(try unwrapSuccess(second), .object(["echo": .integer(2)]))
        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 2)
        let hasContractConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        let hasCallerWideConsent = await fixture.policy.hasStandingConsent(
            for: fixture.caller
        )
        XCTAssertFalse(hasContractConsent)
        XCTAssertFalse(hasCallerWideConsent)
    }

    func testAlwaysAllowForCallerCoversEveryPolicyContractForThatCaller() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllowForCaller
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )

        _ = await fixture.send(value: 1)
        let result = await fixture.send(value: 2)

        XCTAssertEqual(try unwrapSuccess(result), .object(["echo": .integer(2)]))
        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 1)
        let hasCallerWideConsent = await fixture.policy.hasStandingConsent(
            for: fixture.caller
        )
        XCTAssertTrue(hasCallerWideConsent)
        let hasConsentForAnotherContract = await fixture.policy.hasStandingConsent(
            contract: try IntentID("test.another.v1"),
            caller: fixture.caller
        )
        XCTAssertTrue(hasConsentForAnotherContract)
        let otherCaller = IntentPrincipal(
            id: "plugin:dev.tenon.test:other",
            kind: fixture.caller.kind,
            sessionRevision: 1
        )
        let otherCallerHasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: otherCaller
        )
        XCTAssertFalse(otherCallerHasConsent)
    }

    func testCallerWideConsentDoesNotBypassCapabilities() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllowForCaller
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        _ = await fixture.send(value: 1)

        try await fixture.policy.replaceGrants([], for: fixture.caller)
        let denied = await fixture.send(value: 2)

        let failure = try unwrapFailure(denied)
        XCTAssertEqual(failure.error.code, .kernel(.denied))
        let providerInvocationCount = await fixture.provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 1)
        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testConcurrentPolicyApprovalsShareOnePromptAndPersistOneGrant() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let sends = (1 ... 8).map { value in
            Task {
                await fixture.send(value: Int64(value))
            }
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        await allowConcurrentWorkToReachConsentBoundary()
        let promptCount = await confirmation.requestCount()
        XCTAssertEqual(promptCount, 1, "one caller/contract opens one consent wave")
        await confirmation.releasePendingRequests()

        for send in sends {
            _ = try unwrapSuccess(await send.value)
        }
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasConsent)
    }

    func testCancellingConsentWaveCreatorKeepsFlightForRemainingWaiter() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let creatorResult = ConsentResultProbe()
        let remainingResult = ConsentResultProbe()
        let creator = Task {
            let result = await fixture.send(value: 1)
            await creatorResult.record(result)
            return result
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        let remaining = Task {
            let result = await fixture.send(value: 2)
            await remainingResult.record(result)
            return result
        }
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 2
        )

        creator.cancel()

        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )
        let creatorSettledBeforePromptRelease = await waitForConsentResult(
            creatorResult
        )
        XCTAssertTrue(creatorSettledBeforePromptRelease)
        let promptCount = await confirmation.requestCount()
        XCTAssertEqual(promptCount, 1)

        await confirmation.releasePendingRequests()
        let creatorFailure = try unwrapFailure(await creator.value)
        XCTAssertEqual(creatorFailure.error.code, .kernel(.cancelled))
        let remainingValue = try unwrapSuccess(await remaining.value)
        XCTAssertEqual(
            remainingValue,
            .object(["echo": .integer(2)])
        )
        let invokedValues = await fixture.provider.invokedValues()
        XCTAssertEqual(invokedValues, [2])
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasConsent)
    }

    func testCancellingSoleConsentWaiterSettlesBeforeDecisionWithoutGrant() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let resultProbe = ConsentResultProbe()
        let send = Task {
            let result = await fixture.send(value: 1)
            await resultProbe.record(result)
            return result
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )
        send.cancel()

        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 0
        )
        let settledBeforePromptRelease = await waitForConsentResult(resultProbe)
        XCTAssertTrue(settledBeforePromptRelease)
        let failure = try unwrapFailure(await send.value)
        XCTAssertEqual(failure.error.code, .kernel(.cancelled))
        let hasConsentBeforeRelease = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsentBeforeRelease)
        let providerInvocationCount = await fixture.provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 0)

        await confirmation.releasePendingRequests()
        await allowConcurrentWorkToReachConsentBoundary()
        let hasConsentAfterStaleDecision = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsentAfterStaleDecision)
    }

    /// T-050. A confirmation nobody answers must not hold the request open forever.
    ///
    /// The caller states a deadline — the CLI's `--timeout`, an agent's own bound — and the
    /// dispatcher already refuses past it. What was missing is that the consent wait itself
    /// never returned, so the refusal was a post-hoc check on something that never came back.
    ///
    /// The assertion is deliberately *not* about elapsed time: it is that the request settles
    /// while the prompt is still unanswered. That is the rule, and it cannot go flaky under
    /// load the way a stopwatch can.
    func testUnansweredConfirmationExpiresAtTheCallersDeadline() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let resultProbe = ConsentResultProbe()
        let send = Task {
            let result = await fixture.send(
                value: 1,
                timeout: .milliseconds(200)
            )
            await resultProbe.record(result)
            return result
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )

        // Nobody answers. The waiter must leave on its own.
        await waitForConsentWaitersOverTime(
            fixture.dispatcher,
            key: consentKey,
            count: 0
        )
        let settledBeforePromptRelease = await waitForConsentResultOverTime(
            resultProbe
        )
        XCTAssertTrue(
            settledBeforePromptRelease,
            "an unanswered confirmation must settle the request without an answer"
        )
        // Never await a task that may not be settled: this suite is shared, and a test that
        // hangs takes every other agent's evidence with it instead of just failing.
        guard settledBeforePromptRelease else {
            send.cancel()
            return
        }
        let failure = try unwrapFailure(await send.value)
        XCTAssertEqual(failure.error.code, .kernel(.deadlineExceeded))

        // Expiry is not consent, and it is not a decision either.
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsent)
        let providerInvocationCount = await fixture.provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 0)
    }

    /// One caller's deadline is that caller's alone. A prompt shared by several waiters must
    /// survive the first of them giving up — otherwise a short-deadline agent could snatch the
    /// dialog out from under the human who was reading it.
    func testExpiringWaiterKeepsThePromptForRemainingWaiter() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let impatientResult = ConsentResultProbe()
        let impatient = Task {
            let result = await fixture.send(
                value: 1,
                timeout: .milliseconds(200)
            )
            await impatientResult.record(result)
            return result
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        let remaining = Task { await fixture.send(value: 2) }
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 2
        )

        await waitForConsentWaitersOverTime(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )
        let impatientSettled = await waitForConsentResultOverTime(
            impatientResult
        )
        XCTAssertTrue(impatientSettled)
        let promptCount = await confirmation.requestCount()
        XCTAssertEqual(promptCount, 1, "the prompt must still be standing")
        guard impatientSettled else {
            impatient.cancel()
            remaining.cancel()
            await confirmation.releasePendingRequests()
            return
        }

        await confirmation.releasePendingRequests()
        let impatientFailure = try unwrapFailure(await impatient.value)
        XCTAssertEqual(impatientFailure.error.code, .kernel(.deadlineExceeded))
        let remainingValue = try unwrapSuccess(await remaining.value)
        XCTAssertEqual(remainingValue, .object(["echo": .integer(2)]))
        let invokedValues = await fixture.provider.invokedValues()
        XCTAssertEqual(
            invokedValues,
            [2],
            "only the waiter that was still there may run"
        )
    }

    func testCancellingLastWaiterAfterApprovalCannotCommitStandingConsent() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let persistenceGate = ConsentPersistenceGate()
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation,
            persistenceGate: persistenceGate
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let resultProbe = ConsentResultProbe()
        let send = Task {
            let result = await fixture.send(value: 1)
            await resultProbe.record(result)
            return result
        }

        await persistenceGate.waitUntilEntered()
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )
        send.cancel()

        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 0
        )
        let settledBeforePersistenceRelease = await waitForConsentResult(
            resultProbe
        )
        XCTAssertTrue(settledBeforePersistenceRelease)
        let failure = try unwrapFailure(await send.value)
        XCTAssertEqual(failure.error.code, .kernel(.cancelled))
        let hasConsentBeforePersistenceRelease =
            await fixture.policy.hasStandingConsent(
                contract: fixture.intentID,
                caller: fixture.caller
            )
        XCTAssertFalse(hasConsentBeforePersistenceRelease)

        await persistenceGate.open()
        await persistenceGate.waitUntilCompleted()

        let hasConsentAfterStalePersistenceAttempt =
            await fixture.policy.hasStandingConsent(
                contract: fixture.intentID,
                caller: fixture.caller
            )
        XCTAssertFalse(hasConsentAfterStalePersistenceAttempt)
        let providerInvocationCount = await fixture.provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 0)

        let retry = await fixture.send(value: 2)

        XCTAssertEqual(
            try unwrapSuccess(retry),
            .object(["echo": .integer(2)])
        )
        let promptCount = await confirmation.requestCount()
        XCTAssertEqual(promptCount, 2, "the cancelled wave cannot authorize its retry")
        let hasRetryConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasRetryConsent)
    }

    func testCancelledStaleConsentFlightCannotConsumeLaterRetryWave() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .alwaysAllow,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let consentKey = CallerConsentKey(
            caller: fixture.caller,
            contract: fixture.intentID
        )
        let cancelledResult = ConsentResultProbe()
        let cancelledSend = Task {
            let result = await fixture.send(value: 1)
            await cancelledResult.record(result)
            return result
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )
        cancelledSend.cancel()
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 0
        )
        let cancelledSettledBeforePromptRelease = await waitForConsentResult(
            cancelledResult
        )
        XCTAssertTrue(cancelledSettledBeforePromptRelease)

        let retryResult = ConsentResultProbe()
        let retry = Task {
            let result = await fixture.send(value: 2)
            await retryResult.record(result)
            return result
        }
        await waitForConfirmationRequests(confirmation, atLeast: 2)
        await waitForConsentWaiters(
            fixture.dispatcher,
            key: consentKey,
            count: 1
        )

        await confirmation.releaseNextPendingRequest()
        await allowConcurrentWorkToReachConsentBoundary()
        let retrySettledFromStaleDecision = await retryResult.hasResult()
        XCTAssertFalse(retrySettledFromStaleDecision)
        let retryWaiterCount = await fixture.dispatcher
            .callerConsentWaiterCount(for: consentKey)
        XCTAssertEqual(retryWaiterCount, 1)
        let hasConsentAfterStaleDecision = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsentAfterStaleDecision)

        await confirmation.releaseNextPendingRequest()
        let retryValue = try unwrapSuccess(await retry.value)
        XCTAssertEqual(
            retryValue,
            .object(["echo": .integer(2)])
        )
        let cancelledFailure = try unwrapFailure(await cancelledSend.value)
        XCTAssertEqual(cancelledFailure.error.code, .kernel(.cancelled))
        let promptCount = await confirmation.requestCount()
        XCTAssertEqual(promptCount, 2)
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasConsent)
    }

    func testPolicyDenialIsNotRememberedSoADeniedPluginCanRecover() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .denied)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )

        _ = await fixture.send(value: 1)
        _ = await fixture.send(value: 2)

        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 2)
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsent)
    }

    func testConcurrentPolicyDenialsAreWaveLocalAndALaterCallRetries() async throws {
        let confirmation = ConsentConfirmationProbe(
            decision: .denied,
            suspendsRequests: true
        )
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let deniedSends = (1 ... 8).map { value in
            Task {
                await fixture.send(value: Int64(value))
            }
        }

        await waitForConfirmationRequests(confirmation, atLeast: 1)
        await allowConcurrentWorkToReachConsentBoundary()
        let firstWavePromptCount = await confirmation.requestCount()
        XCTAssertEqual(firstWavePromptCount, 1)
        await confirmation.releasePendingRequests()
        for send in deniedSends {
            let failure = try unwrapFailure(await send.value)
            XCTAssertEqual(failure.error.code, .kernel(.denied))
        }
        let hasDeniedConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasDeniedConsent)

        await confirmation.setDecision(.alwaysAllow)
        let retry = Task {
            await fixture.send(value: 9)
        }
        await waitForConfirmationRequests(
            confirmation,
            atLeast: firstWavePromptCount + 1
        )
        let retryPromptCount = await confirmation.requestCount()
        XCTAssertEqual(retryPromptCount, 2, "a later call starts a fresh wave")
        await confirmation.releasePendingRequests()

        let retryResult = await retry.value
        XCTAssertEqual(
            try unwrapSuccess(retryResult),
            .object(["echo": .integer(9)])
        )
        let hasRecoveredConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertTrue(hasRecoveredConsent)
    }

    func testAlwaysAsksEveryTimeAndRecordsNothing() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let fixture = try await ConsentFixture.make(
            confirmation: .always,
            authorizer: confirmation
        )

        _ = await fixture.send(value: 1)
        _ = await fixture.send(value: 2)

        let requestCount = await confirmation.requestCount()
        XCTAssertEqual(requestCount, 2)
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsent)
    }

    /// Withdrawal — the user disabling or uninstalling — takes the consent with it.
    func testWithdrawingACallerRevokesItsStandingConsent() async throws {
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: ConsentConfirmationProbe(decision: .alwaysAllow)
        )
        try await fixture.policy.grantStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        try await fixture.policy.grantStandingConsent(for: fixture.caller)

        try await fixture.policy.revokeStandingConsents(for: fixture.caller)

        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsent)
        let hasCallerWideConsent = await fixture.policy.hasStandingConsent(
            for: fixture.caller
        )
        XCTAssertFalse(hasCallerWideConsent)
    }

    /// Consent is installation-scoped: a replacement generation can observe a grant made by
    /// the old generation, and retiring that exact old principal must not revoke it.
    func testRetiringThePreviousGenerationKeepsTheLiveOnesConsent() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation
        )
        let retired = fixture.caller
        let live = IntentPrincipal(
            id: retired.id,
            kind: retired.kind,
            sessionRevision: retired.sessionRevision + 1
        )
        try await fixture.policy.grantStandingConsent(
            contract: fixture.intentID,
            caller: retired
        )
        let hasConsentBeforeRetirement = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: live
        )
        XCTAssertTrue(hasConsentBeforeRetirement)

        try await fixture.policy.removePrincipal(retired)

        let hasConsentAfterRetirement = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: live
        )
        XCTAssertTrue(
            hasConsentAfterRetirement,
            "generation turnover is not withdrawal"
        )
    }

    func testConsentPersistenceFailureIsFailClosedBeforeProviderStart() async throws {
        let confirmation = ConsentConfirmationProbe(decision: .alwaysAllow)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: confirmation,
            initialPolicyRevision: UInt64.max - 3
        )

        let result = await fixture.send(value: 1)

        let failure = try unwrapFailure(result)
        XCTAssertEqual(failure.error.code, .kernel(.internal))
        XCTAssertEqual(
            failure.error.details,
            .object(["reason": .string("caller-consent-persistence-failed")])
        )
        let providerInvocationCount = await fixture.provider.invocationCount()
        XCTAssertEqual(providerInvocationCount, 0)
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )
        XCTAssertFalse(hasConsent)
        let telemetry = await fixture.telemetry.snapshot()
        XCTAssertEqual(
            telemetry.completed.first?.confirmationDisposition,
            .approved
        )
    }

    func testRevokingConsentAfterEnqueuePreventsQueuedProviderStart() async throws {
        let gate = ConsentGate()
        let provider = ConsentProviderProbe(blockedValue: 1, gate: gate)
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: ConsentConfirmationProbe(decision: .alwaysAllow),
            provider: provider
        )
        try await fixture.policy.grantStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )

        let running = Task {
            await fixture.send(value: 1)
        }
        await waitForProviderInvocations(provider, atLeast: 1)
        let queued = Task {
            await fixture.send(value: 2)
        }
        await waitForQueuedRequests(fixture.mailbox, count: 1)

        try await fixture.policy.revokeStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )

        await waitForQueuedRequests(fixture.mailbox, count: 0)
        await gate.open()
        _ = await running.value
        _ = await queued.value
        await fixture.mailbox.waitUntilPhysicallyIdle()
        let invokedValues = await provider.invokedValues()
        XCTAssertEqual(invokedValues, [1], "revoked queued work must never reach provider code")
    }

    /// Consent for one contract must not silently cover another.
    func testConsentIsScopedToItsContract() async throws {
        let fixture = try await ConsentFixture.make(
            confirmation: .policy,
            authorizer: ConsentConfirmationProbe(decision: .alwaysAllow)
        )
        try await fixture.policy.grantStandingConsent(
            contract: fixture.intentID,
            caller: fixture.caller
        )

        let other = try IntentID("test.other.v1")
        let hasConsent = await fixture.policy.hasStandingConsent(
            contract: other,
            caller: fixture.caller
        )

        XCTAssertFalse(hasConsent)
    }

    private func unwrapSuccess(_ result: IntentResult) throws -> IntentValue {
        guard case let .success(success) = result else {
            throw ConsentTestError.unexpectedResult
        }
        return success.value
    }

    private func unwrapFailure(_ result: IntentResult) throws -> IntentFailure {
        guard case let .failure(failure) = result else {
            throw ConsentTestError.unexpectedResult
        }
        return failure
    }

    private func waitForConfirmationRequests(
        _ probe: ConsentConfirmationProbe,
        atLeast expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Wait on a deadline, and suspend rather than yield. `Task.yield()` reschedules onto the
        // same cooperative pool, so a fixed number of yields is a hope about scheduling, not a
        // bound: when the machine is busy the eight sends never reach the consent boundary and
        // the spin reports a failure the code did not commit. Sleeping hands the pool back.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await probe.requestCount() >= expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "confirmation authorizer never received \(expected) request(s)",
            file: file,
            line: line
        )
    }

    private func allowConcurrentWorkToReachConsentBoundary() async {
        for _ in 0 ..< 2_000 {
            await Task.yield()
        }
    }

    /// Like `waitForConsentWaiters`, but it lets the clock run.
    ///
    /// The yield-based waiters are right for cancellation, which is immediate — no wall-clock
    /// time has to pass for a cancelled waiter to leave. An *expiring* waiter is the opposite:
    /// it leaves only once its deadline is actually reached, and a spin of `Task.yield()` can
    /// burn all its iterations inside a single millisecond and report a failure that never
    /// happened. So this one sleeps.
    private func waitForConsentWaitersOverTime(
        _ dispatcher: IntentDispatcher,
        key: CallerConsentKey,
        count: Int,
        within limit: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let step = Duration.milliseconds(10)
        let attempts = max(1, Int(limit / step))
        for _ in 0 ..< attempts {
            if await dispatcher.callerConsentWaiterCount(for: key) == count {
                return
            }
            try? await Task.sleep(for: step)
        }
        XCTFail(
            "consent flight never reached \(count) waiter(s) within \(limit)",
            file: file,
            line: line
        )
    }

    private func waitForConsentResultOverTime(
        _ probe: ConsentResultProbe,
        within limit: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let step = Duration.milliseconds(10)
        let attempts = max(1, Int(limit / step))
        for _ in 0 ..< attempts {
            if await probe.hasResult() {
                return true
            }
            try? await Task.sleep(for: step)
        }
        XCTFail(
            "consent dispatch did not settle within \(limit)",
            file: file,
            line: line
        )
        return false
    }

    private func waitForConsentWaiters(
        _ dispatcher: IntentDispatcher,
        key: CallerConsentKey,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await dispatcher.callerConsentWaiterCount(for: key) == count {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "consent flight never reached \(count) waiter(s)",
            file: file,
            line: line
        )
    }

    private func waitForConsentResult(
        _ probe: ConsentResultProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0 ..< 2_000 {
            if await probe.hasResult() {
                return true
            }
            await Task.yield()
        }
        XCTFail(
            "consent dispatch did not settle before prompt release",
            file: file,
            line: line
        )
        return false
    }

    private func waitForProviderInvocations(
        _ provider: ConsentProviderProbe,
        atLeast expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await provider.invocationCount() >= expected {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "provider never reached \(expected) invocation(s)",
            file: file,
            line: line
        )
    }

    private func waitForQueuedRequests(
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
            "mailbox never reached \(count) queued request(s)",
            file: file,
            line: line
        )
    }

    private func waitForTelemetryCompletion(
        _ telemetry: IntentTelemetry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if !(await telemetry.snapshot().completed.isEmpty) {
                return
            }
            await Task.yield()
        }
        XCTFail("telemetry never recorded completion", file: file, line: line)
    }
}

private enum ConsentTestError: Error {
    case unexpectedResult
}

private actor ConsentConfirmationProbe {
    private struct PendingRequest {
        let decision: IntentConfirmationDecision
        let continuation: CheckedContinuation<IntentConfirmationDecision, Never>
    }

    private var decision: IntentConfirmationDecision
    private let suspendsRequests: Bool
    private var requests: [IntentConfirmationRequest] = []
    private var pendingRequests: [PendingRequest] = []

    init(
        decision: IntentConfirmationDecision,
        suspendsRequests: Bool = false
    ) {
        self.decision = decision
        self.suspendsRequests = suspendsRequests
    }

    func authorize(
        _ request: IntentConfirmationRequest
    ) async -> IntentConfirmationDecision {
        requests.append(request)
        guard suspendsRequests else {
            return decision
        }
        let decision = decision
        return await withCheckedContinuation { continuation in
            pendingRequests.append(
                PendingRequest(
                    decision: decision,
                    continuation: continuation
                )
            )
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func setDecision(_ decision: IntentConfirmationDecision) {
        self.decision = decision
    }

    func releasePendingRequests() {
        let pending = pendingRequests
        pendingRequests.removeAll(keepingCapacity: true)
        for request in pending {
            request.continuation.resume(returning: request.decision)
        }
    }

    func releaseNextPendingRequest() {
        precondition(!pendingRequests.isEmpty)
        let request = pendingRequests.removeFirst()
        request.continuation.resume(returning: request.decision)
    }
}

private actor ConsentResultProbe {
    private var result: IntentResult?

    func record(_ result: IntentResult) {
        self.result = result
    }

    func hasResult() -> Bool {
        result != nil
    }
}

private actor ConsentPersistenceGate {
    private var isOpen = false
    private var entryCount = 0
    private var completionCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func perform(
        _ operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        entryCount += 1
        resumeAll(&entryWaiters)
        if !isOpen {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        do {
            let result = try await operation()
            markCompleted()
            return result
        } catch {
            markCompleted()
            throw error
        }
    }

    func waitUntilEntered() async {
        guard entryCount == 0 else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitUntilCompleted() async {
        guard completionCount == 0 else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        resumeAll(&releaseWaiters)
    }

    private func markCompleted() {
        completionCount += 1
        resumeAll(&completionWaiters)
    }

    private func resumeAll(
        _ continuations: inout [CheckedContinuation<Void, Never>]
    ) {
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ConsentGate {
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

private actor ConsentProviderProbe {
    private let blockedValue: Int64?
    private let gate: ConsentGate?
    private var values: [Int64] = []

    init(
        blockedValue: Int64? = nil,
        gate: ConsentGate? = nil
    ) {
        self.blockedValue = blockedValue
        self.gate = gate
    }

    func invoke(_ envelope: IntentEnvelope) async -> IntentProviderReply {
        guard case let .object(fields) = envelope.input,
              case let .integer(value)? = fields["value"]
        else {
            return .success(.object(["echo": .integer(0)]))
        }
        values.append(value)
        if value == blockedValue, let gate {
            await gate.wait()
        }
        return .success(.object(["echo": .integer(value)]))
    }

    func invocationCount() -> Int {
        values.count
    }

    func invokedValues() -> [Int64] {
        values
    }
}

private struct ConsentFixture: Sendable {
    let intentID: IntentID
    let caller: IntentPrincipal
    let policy: PolicyEngine
    let mailbox: IntentMailbox
    let provider: ConsentProviderProbe
    let telemetry: IntentTelemetry
    let dispatcher: IntentDispatcher

    static func make(
        confirmation: IntentConfirmation,
        authorizer probe: ConsentConfirmationProbe,
        initialPolicyRevision: UInt64 = 0,
        provider: ConsentProviderProbe = ConsentProviderProbe(),
        persistenceGate: ConsentPersistenceGate? = nil
    ) async throws -> ConsentFixture {
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
                effects: try IntentEffects(
                    kind: .write,
                    idempotency: .none,
                    retentionMilliseconds: nil,
                    confirmation: confirmation,
                    external: false
                ),
                title: "Echo",
                description: nil,
                deprecated: false,
                domainErrors: []
            )
        )

        let policy = PolicyEngine(
            initialRevisionForTesting: initialPolicyRevision
        )
        try await policy.replaceDeclaredUses([intentID], for: caller)
        try await policy.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none
                    )
                )
            ],
            for: caller
        )

        let registry = ProviderRegistry()
        let mailbox = IntentMailbox(limits: try IntentMailboxLimits())
        try await registry.stage(
            try ProviderGenerationCandidate(
                providerID: providerID,
                owner: .core,
                principal: IntentProviderOwner.core.principal(sessionRevision: 1),
                generation: 1,
                bindings: [
                    IntentProviderBinding(intentID: intentID) { envelope, _ in
                        await provider.invoke(envelope)
                    }
                ],
                policyFingerprint: try PolicyFingerprint(
                    canonicalPolicy: .object([
                        "provider": .string(providerID.rawValue)
                    ])
                ),
                mailbox: mailbox
            )
        )
        try await registry.activate(providerID: providerID, generation: 1)

        let telemetry = try IntentTelemetry()
        let dispatcher = IntentDispatcher(
            catalog: catalog,
            policy: policy,
            registry: registry,
            idempotency: try IntentIdempotencyStore(
                limits: IntentIdempotencyLimits(),
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            ),
            telemetry: telemetry,
            limits: try IntentDispatcherLimits(),
            confirmationAuthorizer: IntentConfirmationAuthorizer { request in
                await probe.authorize(request)
            },
            callerConsentPersistence: { target, fence in
                let persist: @Sendable () async throws -> Bool = {
                    try await policy.grantStandingConsent(
                        for: target,
                        guardedBy: fence
                    )
                }
                guard let persistenceGate else {
                    return try await persist()
                }
                return try await persistenceGate.perform(persist)
            }
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

        return ConsentFixture(
            intentID: intentID,
            caller: caller,
            policy: policy,
            mailbox: mailbox,
            provider: provider,
            telemetry: telemetry,
            dispatcher: dispatcher
        )
    }

    func send(
        value: Int64,
        timeout: Duration? = nil
    ) async -> IntentResult {
        await dispatcher.send(
            IntentDispatchRequest(
                intentID: intentID,
                input: .object(["value": .integer(value)]),
                caller: caller,
                requestedTimeout: timeout
            )
        )
    }
}
