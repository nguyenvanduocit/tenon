import Foundation
import os
import SQLite3
@testable import TenonIntentCore
import XCTest

final class IntentIdempotencyTests: XCTestCase {
    func testConcurrentDuplicateJoinsAndExecutesOnce() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits)
        let decisions = try await withThrowingTaskGroup(
            of: IntentIdempotencyDecision.self,
            returning: [IntentIdempotencyDecision].self
        ) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    try await store.claim(
                        key: fixture.key,
                        fingerprint: fixture.fingerprint,
                        providerID: fixture.providerID,
                        requestID: UUID(),
                        retentionMilliseconds: 10000,
                        now: fixture.now
                    )
                }
            }
            var decisions: [IntentIdempotencyDecision] = []
            for try await decision in group {
                decisions.append(decision)
            }
            return decisions
        }
        let executions = decisions.compactMap { decision -> UUID? in
            guard case let .execute(requestID, providerID) = decision else {
                return nil
            }
            XCTAssertEqual(providerID, fixture.providerID)
            return requestID
        }
        XCTAssertEqual(executions.count, 1)
        let firstRequest = try XCTUnwrap(executions.first)
        XCTAssertEqual(
            decisions.count(where: {
                $0 == .join(requestID: firstRequest, providerID: fixture.providerID)
            }),
            99
        )

        let waiter = Task {
            try await store.waitForResult(key: fixture.key, requestID: firstRequest)
        }
        let result = IntentResult.success(
            value: .object(["ok": .bool(true)]),
            requestID: firstRequest,
            providerID: fixture.providerID
        )
        try await store.settle(
            key: fixture.key,
            requestID: firstRequest,
            result: result,
            now: fixture.now.addingTimeInterval(1)
        )
        let joinedResult = try await waiter.value
        XCTAssertEqual(joinedResult, result)
    }

    func testChangedInputOrExplicitTargetConflicts() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits)
        let firstRequest = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequest,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        let changedInput = try IntentIdempotencyFingerprint(
            inputDigest: IntentValue.string("different").canonicalSHA256Digest(),
            explicitTarget: fixture.fingerprint.explicitTarget
        )
        let inputDecision = try await store.claim(
            key: fixture.key,
            fingerprint: changedInput,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        XCTAssertEqual(
            inputDecision,
            .conflict(existingRequestID: firstRequest, providerID: fixture.providerID)
        )

        let changedTarget = try IntentIdempotencyFingerprint(
            inputDigest: fixture.fingerprint.inputDigest,
            explicitTarget: ProviderID("dev.tenon.other")
        )
        let targetDecision = try await store.claim(
            key: fixture.key,
            fingerprint: changedTarget,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        XCTAssertEqual(
            targetDecision,
            .conflict(existingRequestID: firstRequest, providerID: fixture.providerID)
        )
    }

    func testNewPrincipalSessionRevisionHasIndependentIdempotencyScope() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits)
        let firstRequestID = UUID()
        let firstDecision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        XCTAssertEqual(
            firstDecision,
            .execute(requestID: firstRequestID, providerID: fixture.providerID)
        )

        let nextPrincipal = IntentPrincipal(
            id: fixture.key.principal.id,
            kind: fixture.key.principal.kind,
            sessionRevision: fixture.key.principal.sessionRevision + 1
        )
        let nextKey = try IntentIdempotencyClaimKey(
            principal: nextPrincipal,
            intentID: fixture.key.intentID,
            key: fixture.key.key
        )
        let nextRequestID = UUID()
        let nextDecision = try await store.claim(
            key: nextKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        XCTAssertEqual(
            nextDecision,
            .execute(requestID: nextRequestID, providerID: fixture.providerID)
        )
        let snapshot = try await store.snapshot()
        XCTAssertEqual(Set(snapshot.records.map(\.claimKey)), [fixture.key, nextKey])
    }

    func testTerminalResultReplaysAcrossStoreRecreation() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let requestID = UUID()

        let firstStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now
        )
        _ = try await firstStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        let result = IntentResult.success(
            value: .string("persisted"),
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await firstStore.settle(
            key: fixture.key,
            requestID: requestID,
            result: result,
            now: fixture.now.addingTimeInterval(1)
        )

        let restored = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now.addingTimeInterval(2)
        )
        let decision = try await restored.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: ProviderID("dev.tenon.new-default"),
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(decision, .replay(result))
    }

    func testInterruptedPersistedClaimRecoversAsUnknownWithoutReexecution() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let requestID = UUID()
        let firstStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now
        )
        _ = try await firstStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        try await firstStore.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(1)
        )

        let restored = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now.addingTimeInterval(2)
        )
        let decision = try await restored.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now.addingTimeInterval(2)
        )

        guard case let .replay(.failure(failure)) = decision else {
            return XCTFail("Expected recovered failure")
        }
        XCTAssertEqual(failure.meta.requestID, requestID)
        XCTAssertEqual(failure.error.outcome, .unknown)
        XCTAssertEqual(failure.error.code, .kernel(.internal))
    }

    func testExpiredTerminalClaimIsPurgedForNewAdmission() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxKeyBytes: 64,
                maxRetentionMilliseconds: 20000,
                maxTerminalResultBytes: 1024
            )
        )
        let store = try makeStore(limits: fixture.limits)

        let firstKey = try fixture.key(suffix: "first")
        let secondKey = try fixture.key(suffix: "second")
        let firstID = UUID()
        let secondID = UUID()

        _ = try await store.claim(
            key: firstKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstID,
            retentionMilliseconds: 1000,
            now: fixture.now
        )
        try await store.settle(
            key: firstKey,
            requestID: firstID,
            result: .success(
                value: .null,
                requestID: firstID,
                providerID: fixture.providerID
            ),
            now: fixture.now
        )
        _ = try await store.claim(
            key: secondKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: secondID,
            retentionMilliseconds: 10000,
            now: fixture.now.addingTimeInterval(2)
        )

        let snapshot = try await store.snapshot()
        XCTAssertNil(snapshot.records.first { $0.claimKey == firstKey })
        XCTAssertNotNil(snapshot.records.first { $0.claimKey == secondKey })
    }

    func testCancelledJoinerDoesNotCancelOriginalClaim() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits)
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        let waiter = Task {
            try await store.waitForResult(key: fixture.key, requestID: requestID)
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let result = IntentResult.success(
            value: .null,
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await store.settle(
            key: fixture.key,
            requestID: requestID,
            result: result,
            now: fixture.now.addingTimeInterval(1)
        )
        let replay = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(replay, .replay(result))
    }

    func testUnexpiredTerminalResultRemainsReplayableWhenCapacityIsFull() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxKeyBytes: 64,
                maxRetentionMilliseconds: 20000,
                maxTerminalResultBytes: 1024
            )
        )
        let store = try makeStore(limits: fixture.limits)
        let firstKey = try fixture.key(suffix: "first-retained")
        let firstID = UUID()
        let firstResult = IntentResult.success(
            value: .null,
            requestID: firstID,
            providerID: fixture.providerID
        )
        _ = try await store.claim(
            key: firstKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        try await store.settle(
            key: firstKey,
            requestID: firstID,
            result: firstResult,
            now: fixture.now.addingTimeInterval(1)
        )

        do {
            _ = try await store.claim(
                key: fixture.key(suffix: "second-rejected"),
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: UUID(),
                retentionMilliseconds: 10000,
                now: fixture.now.addingTimeInterval(2)
            )
            XCTFail("Expected capacity rejection while a retained result occupies the store")
        } catch IntentIdempotencyError.capacityExceeded {
            // Expected: retention wins over new admission.
        }

        let replay = try await store.lookup(
            key: firstKey,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(replay, .replay(firstResult))
    }

    func testClaimRejectsTerminalReservationBeyondConfiguredHardCap() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 10,
                maxEncodedBytes: 4096,
                maxKeyBytes: 64,
                maxRetentionMilliseconds: 20000,
                maxTerminalResultBytes: 1024
            )
        )
        let store = try makeStore(limits: fixture.limits)
        do {
            _ = try await store.claim(
                key: fixture.key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: UUID(),
                retentionMilliseconds: 10000,
                maximumTerminalResultBytes: 10000,
                now: fixture.now
            )
            XCTFail("Expected reservation rejection before execution")
        } catch IntentIdempotencyError.terminalResultReservationOutOfRange {
            // Expected.
        }

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.allocatedBytes, 0)
    }

    func testTwoStoresSharingPersistenceClaimAtomically() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let firstStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now
        )
        let secondStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now
        )

        async let first = firstStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        async let second = secondStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        let decisions = try await [first, second]

        XCTAssertEqual(
            decisions.count(where: {
                if case .execute = $0 { return true }
                return false
            }),
            1
        )
    }

    func testPreparingSecondLiveStoreDoesNotRecoverActiveSameProcessOwner() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let processID = UUID()
        let firstOwnerID = UUID()
        let requestID = UUID()
        let firstStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: firstOwnerID,
            now: fixture.now
        )
        _ = try await firstStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10_000,
            now: fixture.now
        )

        let secondStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: UUID(),
            now: fixture.now.addingTimeInterval(1)
        )
        let decision = try await secondStore.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            decision,
            .join(requestID: requestID, providerID: fixture.providerID)
        )
        try await firstStore.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(2)
        )
    }

    func testExistingSiblingRecoversOwnerThatDeallocatesAfterPrepare() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let processID = UUID()
        let requestID = UUID()
        var firstStore: IntentIdempotencyStore? = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: UUID(),
            now: fixture.now
        )
        _ = try await firstStore?.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10_000,
            now: fixture.now
        )
        let survivingStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: UUID(),
            now: fixture.now.addingTimeInterval(1)
        )
        let liveDecision = try await survivingStore.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            liveDecision,
            .join(requestID: requestID, providerID: fixture.providerID)
        )

        firstStore = nil
        guard case let .replay(.failure(failure))? = try await survivingStore.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(2)
        ) else {
            return XCTFail("Expected the surviving store to recover its deallocated sibling")
        }
        XCTAssertEqual(failure.error.outcome, .notStarted)
        XCTAssertEqual(failure.meta.requestID, requestID)
    }

    func testSameProcessStoreRecreationRecoversDeallocatedOwner() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let processID = UUID()
        let requestID = UUID()
        var firstStore: IntentIdempotencyStore? = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: UUID(),
            now: fixture.now
        )
        _ = try await firstStore?.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10_000,
            now: fixture.now
        )
        firstStore = nil

        let restored = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            claimOwnerID: UUID(),
            now: fixture.now.addingTimeInterval(1)
        )
        guard case let .replay(.failure(failure))? = try await restored.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(1)
        ) else {
            return XCTFail("Expected same-process orphan recovery")
        }
        XCTAssertEqual(failure.error.outcome, .notStarted)
        XCTAssertEqual(failure.meta.requestID, requestID)
    }

    func testWaiterObservesSettlementFromAnotherStore() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let executingStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now
        )
        let joiningStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            now: fixture.now
        )
        let requestID = UUID()
        _ = try await executingStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        guard case .join = try await joiningStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10000,
            now: fixture.now
        ) else {
            return XCTFail("Expected the second store to join the durable claim")
        }

        let joined = Task {
            try await joiningStore.waitForResult(
                key: fixture.key,
                requestID: requestID,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        try await executingStore.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(1)
        )
        let terminal = IntentResult.success(
            value: .string("settled-elsewhere"),
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await executingStore.settle(
            key: fixture.key,
            requestID: requestID,
            result: terminal,
            now: fixture.now.addingTimeInterval(2)
        )

        let joinedResult = try await joined.value
        XCTAssertEqual(joinedResult, terminal)
    }

    func testRecoveredClaimedRecordReportsNotStarted() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let requestID = UUID()
        let firstStore = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now
        )
        _ = try await firstStore.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        let restored = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now.addingTimeInterval(1)
        )
        guard case let .replay(.failure(failure))? = try await restored.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(1)
        ) else {
            return XCTFail("Expected recovered terminal failure")
        }
        XCTAssertEqual(failure.error.outcome, .notStarted)
    }

    func testSettlementCanonicalizesRequestAndProviderMetadata() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits)
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        try await store.settle(
            key: fixture.key,
            requestID: requestID,
            result: .success(
                value: .string("canonical"),
                requestID: UUID(),
                providerID: ProviderID("dev.tenon.wrong-provider")
            ),
            now: fixture.now.addingTimeInterval(1)
        )

        guard case let .replay(.success(success))? = try await store.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(2)
        ) else {
            return XCTFail("Expected terminal replay")
        }
        XCTAssertEqual(success.meta.requestID, requestID)
        XCTAssertEqual(success.meta.providerID, fixture.providerID)
    }

    func testWaiterAdmissionIsBoundedPerClaim() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxWaitersPerClaim: 1,
                maxTotalWaiters: 1,
                maximumJoinWaitMilliseconds: 1000
            )
        )
        let store = try makeStore(limits: fixture.limits)
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        let first = Task {
            try await store.waitForResult(key: fixture.key, requestID: requestID)
        }
        try await Task.sleep(for: .milliseconds(10))

        do {
            _ = try await store.waitForResult(
                key: fixture.key,
                requestID: requestID,
                deadline: ContinuousClock().now.advanced(by: .milliseconds(50))
            )
            XCTFail("Expected the second waiter to be rejected")
        } catch IntentIdempotencyError.waiterCapacityExceeded {
            // Expected.
        }

        let result = IntentResult.success(
            value: .null,
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await store.settle(
            key: fixture.key,
            requestID: requestID,
            result: result,
            now: fixture.now.addingTimeInterval(1)
        )
        let joined = try await first.value
        XCTAssertEqual(joined, result)
    }

    func testWaiterDeadlineReleasesAdmission() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxWaitersPerClaim: 1,
                maxTotalWaiters: 1,
                maximumJoinWaitMilliseconds: 1000
            )
        )
        let store = try makeStore(limits: fixture.limits)
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        do {
            _ = try await store.waitForResult(
                key: fixture.key,
                requestID: requestID,
                deadline: ContinuousClock().now.advanced(by: .milliseconds(10))
            )
            XCTFail("Expected waiter deadline")
        } catch IntentIdempotencyError.waiterDeadlineExceeded {
            // Expected.
        }

        let replacement = Task {
            try await store.waitForResult(key: fixture.key, requestID: requestID)
        }
        try await Task.sleep(for: .milliseconds(10))
        let result = IntentResult.success(
            value: .null,
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await store.settle(
            key: fixture.key,
            requestID: requestID,
            result: result,
            now: fixture.now.addingTimeInterval(1)
        )
        let joined = try await replacement.value
        XCTAssertEqual(joined, result)
    }

    func testSettlementLookupFailureStillCompletesRegisteredWaiters() async throws {
        let fixture = try Fixture()
        let failureSwitch = LookupFailureSwitch()
        let persistence = try FailingLookupPersistence(
            base: IntentSQLiteIdempotencyPersistence.inMemory(),
            failureSwitch: failureSwitch
        )
        let store = try makeStore(
            limits: fixture.limits,
            persistence: persistence,
            now: fixture.now
        )
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(1)
        )
        let waiter = Task {
            try await store.waitForResult(
                key: fixture.key,
                requestID: requestID,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        failureSwitch.failLookups()

        do {
            try await store.settle(
                key: fixture.key,
                requestID: requestID,
                result: .success(
                    value: .string("physically-complete"),
                    requestID: requestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(2)
            )
            XCTFail("Expected persistence failure")
        } catch IntentIdempotencyError.persistenceFailure {
            // Expected.
        }

        guard case let .failure(failure) = try await waiter.value else {
            return XCTFail("Expected one conservative terminal result")
        }
        XCTAssertEqual(failure.error.code, .kernel(.internal))
        XCTAssertEqual(failure.error.outcome, .unknown)
        XCTAssertEqual(failure.meta.requestID, requestID)
        XCTAssertEqual(failure.meta.providerID, fixture.providerID)
    }

    func testOversizedTerminalResultSettlesAsUnknownWithinReservation() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 10,
                maxEncodedBytes: 64 * 1024,
                maxTerminalResultBytes: 2048
            )
        )
        let store = try makeStore(limits: fixture.limits)
        let requestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(1)
        )

        do {
            try await store.settle(
                key: fixture.key,
                requestID: requestID,
                result: .success(
                    value: .string(String(repeating: "x", count: 2000)),
                    requestID: requestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(2)
            )
            XCTFail("Expected terminal result reservation failure")
        } catch IntentIdempotencyError.terminalResultTooLarge {
            // Expected.
        }

        guard case let .replay(.failure(failure))? = try await store.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(3)
        ) else {
            return XCTFail("Expected conservative replay")
        }
        XCTAssertEqual(failure.error.outcome, .unknown)
        let snapshot = try await store.snapshot()
        XCTAssertLessThanOrEqual(snapshot.allocatedBytes, fixture.limits.maxEncodedBytes)
    }

    func testPersistedFallbackExpiresAndAllowsFreshExecution() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxRetentionMilliseconds: 10000,
                maxTerminalResultBytes: 2048
            )
        )
        let store = try makeStore(limits: fixture.limits)
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: firstRequestID,
            now: fixture.now.addingTimeInterval(0.25)
        )

        do {
            try await store.settle(
                key: fixture.key,
                requestID: firstRequestID,
                result: .success(
                    value: .string(String(repeating: "x", count: 2000)),
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(0.5)
            )
            XCTFail("Expected the oversized result to fall back conservatively")
        } catch IntentIdempotencyError.terminalResultTooLarge {
            // The canonical fallback is persisted inside `settle`.
        }

        let nextRequestID = UUID()
        let decision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 1000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            decision,
            .execute(requestID: nextRequestID, providerID: fixture.providerID)
        )
    }

    func testVolatileFallbackReplaysThenAtomicallyReleasesAfterExpiry() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxRetentionMilliseconds: 10000,
                maxTerminalResultBytes: 2048
            )
        )
        let settlementFailures = SettlementFailureSwitch()
        let persistence = try FailingSettlementPersistence(
            base: IntentSQLiteIdempotencyPersistence.inMemory(),
            failureSwitch: settlementFailures
        )
        let store = try makeStore(
            limits: fixture.limits,
            persistence: persistence,
            now: fixture.now
        )
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: firstRequestID,
            now: fixture.now.addingTimeInterval(0.1)
        )
        let waiter = Task {
            try await store.waitForResult(
                key: fixture.key,
                requestID: firstRequestID,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        settlementFailures.failSettlements()

        do {
            try await store.settle(
                key: fixture.key,
                requestID: firstRequestID,
                result: .success(
                    value: .string("physically-complete"),
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(0.2)
            )
            XCTFail("Expected both durable settlement attempts to fail")
        } catch IntentIdempotencyError.persistenceFailure {
            // Current waiters receive one conservative terminal result.
        }

        guard case let .failure(waiterFailure) = try await waiter.value else {
            return XCTFail("Expected the registered waiter to receive the fallback")
        }
        XCTAssertEqual(waiterFailure.error.outcome, .unknown)
        let replay = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 1000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(0.5)
        )
        XCTAssertEqual(
            replay,
            .replay(
                .failure(
                    error: waiterFailure.error,
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                )
            )
        )

        let nextRequestID = UUID()
        let decision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 1000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            decision,
            .execute(requestID: nextRequestID, providerID: fixture.providerID)
        )
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.cachedEntries, 1)
        XCTAssertLessThanOrEqual(
            snapshot.cachedAllocatedBytes,
            fixture.limits.maxEncodedBytes
        )
    }

    func testExpiredVolatileFallbackLookupCanReachFreshAdmission() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1_024,
                maxRetentionMilliseconds: 10_000,
                maxTerminalResultBytes: 2_048
            )
        )
        let settlementFailures = SettlementFailureSwitch()
        let persistence = try FailingSettlementPersistence(
            base: IntentSQLiteIdempotencyPersistence.inMemory(),
            failureSwitch: settlementFailures
        )
        let store = try makeStore(
            limits: fixture.limits,
            persistence: persistence,
            now: fixture.now
        )
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: firstRequestID,
            now: fixture.now.addingTimeInterval(0.1)
        )
        settlementFailures.failSettlements()
        do {
            try await store.settle(
                key: fixture.key,
                requestID: firstRequestID,
                result: .success(
                    value: .null,
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(0.2)
            )
            XCTFail("Expected both durable settlement attempts to fail")
        } catch IntentIdempotencyError.persistenceFailure {
            // The conservative terminal result remains volatile until expiry.
        }

        let afterExpiry = fixture.now.addingTimeInterval(2)
        let lookup = try await store.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: afterExpiry
        )
        XCTAssertNil(
            lookup,
            "The dispatcher's lookup-before-claim path must admit a fenced replacement"
        )

        let nextRequestID = UUID()
        let decision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: afterExpiry
        )
        XCTAssertEqual(
            decision,
            .execute(requestID: nextRequestID, providerID: fixture.providerID)
        )
    }

    func testConformingClaimThrowLeavesNoDurableOrCachedClaim() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let store = try makeStore(
            limits: fixture.limits,
            persistence: PrecommitFailingClaimPersistence(
                base: database.connection()
            ),
            now: fixture.now
        )

        do {
            _ = try await store.claim(
                key: fixture.key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: UUID(),
                retentionMilliseconds: 1_000,
                maximumTerminalResultBytes: 512,
                now: fixture.now
            )
            XCTFail("Expected the conforming pre-commit failure")
        } catch IntentIdempotencyError.persistenceFailure {
            // Throw means the proposed row did not commit.
        }

        let observer = try database.connection()
        XCTAssertNil(
            try observer.lookup(
                key: fixture.key,
                processID: UUID(),
                activeClaimOwnerIDs: [],
                now: fixture.now
            )
        )
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.cachedEntries, 0)
        XCTAssertEqual(snapshot.cachedEncodedBytes, 0)
        XCTAssertEqual(snapshot.cachedAllocatedBytes, 0)
    }

    func testVolatileFallbackCacheStaysBoundedAcrossExpiryChurn() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxRetentionMilliseconds: 10000,
                maxTerminalResultBytes: 2048
            )
        )
        let settlementFailures = SettlementFailureSwitch()
        settlementFailures.failSettlements()
        let persistence = try FailingSettlementPersistence(
            base: IntentSQLiteIdempotencyPersistence.inMemory(),
            failureSwitch: settlementFailures
        )
        let store = try makeStore(
            limits: fixture.limits,
            persistence: persistence,
            now: fixture.now
        )

        for index in 0 ..< 200 {
            let operationTime = fixture.now.addingTimeInterval(Double(index * 2))
            let requestID = UUID()
            let decision = try await store.claim(
                key: fixture.key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: requestID,
                retentionMilliseconds: 1000,
                maximumTerminalResultBytes: 512,
                now: operationTime
            )
            XCTAssertEqual(
                decision,
                .execute(requestID: requestID, providerID: fixture.providerID)
            )
            try await store.markRunning(
                key: fixture.key,
                requestID: requestID,
                now: operationTime.addingTimeInterval(0.1)
            )
            do {
                try await store.settle(
                    key: fixture.key,
                    requestID: requestID,
                    result: .success(
                        value: .null,
                        requestID: requestID,
                        providerID: fixture.providerID
                    ),
                    now: operationTime.addingTimeInterval(0.2)
                )
                XCTFail("Expected forced settlement failure")
            } catch IntentIdempotencyError.persistenceFailure {
                // The volatile terminal owns the reserved cache slot until expiry.
            }
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.cachedEntries, 1)
        XCTAssertLessThanOrEqual(snapshot.cachedEncodedBytes, fixture.limits.maxEncodedBytes)
        XCTAssertLessThanOrEqual(
            snapshot.cachedAllocatedBytes,
            fixture.limits.maxEncodedBytes
        )
    }

    func testSettledClaimCacheDoesNotGrowAcrossExpiredKeyChurn() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEntries: 1,
                maxEncodedBytes: 64 * 1024,
                maxRetentionMilliseconds: 10000,
                maxTerminalResultBytes: 2048
            )
        )
        let store = try makeStore(limits: fixture.limits, now: fixture.now)

        for index in 0 ..< 200 {
            let operationTime = fixture.now.addingTimeInterval(Double(index * 2))
            let key = try fixture.key(suffix: "operation-\(index)")
            let requestID = UUID()
            _ = try await store.claim(
                key: key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: requestID,
                retentionMilliseconds: 1000,
                maximumTerminalResultBytes: 512,
                now: operationTime
            )
            try await store.settle(
                key: key,
                requestID: requestID,
                result: .success(
                    value: .null,
                    requestID: requestID,
                    providerID: fixture.providerID
                ),
                now: operationTime.addingTimeInterval(0.1)
            )
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.cachedEntries, 0)
        XCTAssertEqual(snapshot.cachedEncodedBytes, 0)
        XCTAssertEqual(snapshot.cachedAllocatedBytes, 0)
    }

    func testExpiredClaimedRecordCanBeReclaimed() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits, now: fixture.now)
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1_000,
            now: fixture.now
        )

        let replacementRequestID = UUID()
        let decision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: replacementRequestID,
            retentionMilliseconds: 1_000,
            now: fixture.now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            decision,
            .execute(
                requestID: replacementRequestID,
                providerID: fixture.providerID
            )
        )
    }

    func testExpiredRunningRecordCanBeReclaimed() async throws {
        let fixture = try Fixture()
        let store = try makeStore(limits: fixture.limits, now: fixture.now)
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1_000,
            now: fixture.now
        )
        try await store.markRunning(
            key: fixture.key,
            requestID: firstRequestID,
            now: fixture.now.addingTimeInterval(0.5)
        )

        let replacementRequestID = UUID()
        let decision = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: replacementRequestID,
            retentionMilliseconds: 1_000,
            now: fixture.now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            decision,
            .execute(
                requestID: replacementRequestID,
                providerID: fixture.providerID
            )
        )
    }

    func testJoiningStoreCannotTransitionOwnersClaim() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let processID = UUID()
        let owner = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            now: fixture.now
        )
        let requestID = UUID()
        _ = try await owner.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10_000,
            now: fixture.now
        )
        let joiner = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            now: fixture.now
        )
        let joined = try await joiner.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10_000,
            now: fixture.now
        )
        XCTAssertEqual(
            joined,
            .join(requestID: requestID, providerID: fixture.providerID)
        )

        do {
            try await joiner.markRunning(
                key: fixture.key,
                requestID: requestID,
                now: fixture.now.addingTimeInterval(1)
            )
            XCTFail("A joining store must not transition the owner's claim")
        } catch {
            XCTAssertEqual(
                error as? IntentIdempotencyError,
                .claimOwnershipMismatch
            )
        }

        do {
            try await joiner.settle(
                key: fixture.key,
                requestID: requestID,
                result: .success(
                    value: .string("foreign"),
                    requestID: requestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(2)
            )
            XCTFail("A joining store must not settle the owner's claim")
        } catch {
            XCTAssertEqual(
                error as? IntentIdempotencyError,
                .claimOwnershipMismatch
            )
        }

        try await owner.markRunning(
            key: fixture.key,
            requestID: requestID,
            now: fixture.now.addingTimeInterval(1)
        )
        let ownerResult = IntentResult.success(
            value: .string("owner"),
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await owner.settle(
            key: fixture.key,
            requestID: requestID,
            result: ownerResult,
            now: fixture.now.addingTimeInterval(2)
        )
        let replay = try await joiner.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: fixture.now.addingTimeInterval(3)
        )
        XCTAssertEqual(
            replay,
            .replay(ownerResult)
        )
    }

    func testReservationSmallerThanCanonicalFallbackIsRejected() async throws {
        let fixture = try Fixture(
            limits: IntentIdempotencyLimits(
                maxEncodedBytes: 64 * 1_024,
                maxTerminalResultBytes: 2_048
            )
        )
        let store = try makeStore(limits: fixture.limits, now: fixture.now)

        do {
            _ = try await store.claim(
                key: fixture.key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: UUID(),
                retentionMilliseconds: 1_000,
                maximumTerminalResultBytes: 1,
                now: fixture.now
            )
            XCTFail("An unsafe terminal reservation must be rejected")
        } catch let error as IntentIdempotencyError {
            guard case let .terminalResultReservationTooSmall(minimumBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(minimumBytes, 1)
        }
    }

    func testExpiredOwnedCacheDoesNotCommitThenRejectDifferentKey() async throws {
        let limits = try IntentIdempotencyLimits(
            maxEntries: 1,
            maxEncodedBytes: 64 * 1_024,
            maxRetentionMilliseconds: 20_000,
            maxTerminalResultBytes: 2_048
        )
        let fixture = try Fixture(limits: limits)
        let store = try makeStore(limits: limits, now: fixture.now)
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )

        let nextKey = try fixture.key(suffix: "different")
        let nextRequestID = UUID()
        let decision = try await store.claim(
            key: nextKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            decision,
            .execute(requestID: nextRequestID, providerID: fixture.providerID)
        )
    }

    func testExpiredVolatileReleaseRejectsBeforeDurableInsert() async throws {
        let limits = try IntentIdempotencyLimits(
            maxEntries: 1,
            maxEncodedBytes: 64 * 1_024,
            maxRetentionMilliseconds: 20_000,
            maxTerminalResultBytes: 2_048
        )
        let fixture = try Fixture(limits: limits)
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let failures = SettlementFailureSwitch()
        let store = try makeStore(
            limits: limits,
            persistence: FailingSettlementPersistence(
                base: database.connection(),
                failureSwitch: failures
            ),
            now: fixture.now
        )
        let firstRequestID = UUID()
        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        failures.failSettlements()
        do {
            try await store.settle(
                key: fixture.key,
                requestID: firstRequestID,
                result: .success(
                    value: .null,
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(0.25)
            )
            XCTFail("Expected the durable settlement attempts to fail")
        } catch IntentIdempotencyError.persistenceFailure {
            // The terminal result is retained only in the bounded volatile cache.
        }

        let nextKey = try fixture.key(suffix: "must-not-commit")
        do {
            _ = try await store.claim(
                key: nextKey,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: UUID(),
                retentionMilliseconds: 1_000,
                maximumTerminalResultBytes: 512,
                now: fixture.now.addingTimeInterval(2)
            )
            XCTFail("Expected local cache capacity rejection")
        } catch IntentIdempotencyError.capacityExceeded {
            // The cache reservation failed before the SQLite claim transaction.
        }
        let observer = try database.connection()
        XCTAssertNil(
            try observer.lookup(
                key: nextKey,
                processID: UUID(),
                activeClaimOwnerIDs: [],
                now: fixture.now.addingTimeInterval(2)
            )
        )
    }

    func testDurableDuplicateStillJoinsWhenVolatileReleaseFillsLocalCache() async throws {
        let limits = try IntentIdempotencyLimits(
            maxEntries: 1,
            maxEncodedBytes: 64 * 1_024,
            maxRetentionMilliseconds: 20_000,
            maxTerminalResultBytes: 2_048
        )
        let fixture = try Fixture(limits: limits)
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let failures = SettlementFailureSwitch()
        let local = try makeStore(
            limits: limits,
            persistence: FailingSettlementPersistence(
                base: database.connection(),
                failureSwitch: failures
            ),
            now: fixture.now
        )
        let firstRequestID = UUID()
        _ = try await local.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )
        failures.failSettlements()
        do {
            try await local.settle(
                key: fixture.key,
                requestID: firstRequestID,
                result: .success(
                    value: .null,
                    requestID: firstRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(0.25)
            )
            XCTFail("Expected the durable settlement attempts to fail")
        } catch IntentIdempotencyError.persistenceFailure {
            // Retained in the local volatile cache.
        }

        let durableOwner = try makeStore(
            limits: limits,
            persistence: database.connection(),
            now: fixture.now.addingTimeInterval(2)
        )
        let nextKey = try fixture.key(suffix: "durable-duplicate")
        let nextRequestID = UUID()
        _ = try await durableOwner.claim(
            key: nextKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: nextRequestID,
            retentionMilliseconds: 10_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )

        let duplicate = try await local.claim(
            key: nextKey,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            retentionMilliseconds: 10_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            duplicate,
            .join(requestID: nextRequestID, providerID: fixture.providerID)
        )
    }

    func testLateOwnerRequestMismatchReleasesItsStaleCache() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let processID = UUID()
        let owner = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            now: fixture.now
        )
        let replacer = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: processID,
            now: fixture.now
        )
        let oldRequestID = UUID()
        _ = try await owner.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: oldRequestID,
            retentionMilliseconds: 1_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now
        )

        let replacementRequestID = UUID()
        _ = try await replacer.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: replacementRequestID,
            retentionMilliseconds: 10_000,
            maximumTerminalResultBytes: 512,
            now: fixture.now.addingTimeInterval(2)
        )
        do {
            try await owner.settle(
                key: fixture.key,
                requestID: oldRequestID,
                result: .success(
                    value: .string("late-owner"),
                    requestID: oldRequestID,
                    providerID: fixture.providerID
                ),
                now: fixture.now.addingTimeInterval(3)
            )
            XCTFail("The expired owner must be fenced")
        } catch IntentIdempotencyError.requestMismatch {
            // The replacement request is now authoritative.
        }

        let ownerSnapshot = try await owner.snapshot()
        XCTAssertEqual(ownerSnapshot.cachedEntries, 0)
    }

    func testExactMinimumReservationSurvivesUpdatedAtGrowth() async throws {
        let limits = try IntentIdempotencyLimits(
            maxEntries: 4,
            maxEncodedBytes: 64 * 1_024,
            maxRetentionMilliseconds: 20_000,
            maxTerminalResultBytes: 2_048
        )
        let fixture = try Fixture(
            limits: limits,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
        let store = try makeStore(limits: limits, now: fixture.now)
        let requestID = UUID()
        let minimum: Int
        do {
            _ = try await store.claim(
                key: fixture.key,
                fingerprint: fixture.fingerprint,
                providerID: fixture.providerID,
                requestID: requestID,
                retentionMilliseconds: 10_000,
                maximumTerminalResultBytes: 1,
                now: fixture.now
            )
            return XCTFail("Expected minimum reservation discovery")
        } catch let IntentIdempotencyError.terminalResultReservationTooSmall(value) {
            minimum = value
        }

        _ = try await store.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10_000,
            maximumTerminalResultBytes: minimum,
            now: fixture.now
        )
        let fallback = IntentResult.failure(
            error: IntentError(
                code: .kernel(.internal),
                details: .object([
                    "reason": .string("idempotency-persistence-failed"),
                ]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: requestID,
            providerID: fixture.providerID
        )
        try await store.settle(
            key: fixture.key,
            requestID: requestID,
            result: fallback,
            now: Date(timeIntervalSinceReferenceDate: 0.123_456_789)
        )
        let replay = try await store.lookup(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            now: Date(timeIntervalSinceReferenceDate: 0.2)
        )
        XCTAssertEqual(replay, .replay(fallback))
    }

    func testExpiredReplacementRequiresExactObservedRequestWhenProvided() throws {
        let fixture = try Fixture()
        let persistence = try IntentSQLiteIdempotencyPersistence.inMemory()
        let owningProcessID = UUID()
        let owningClaimOwnerID = UUID()
        try persistence.prepare(
            limits: fixture.limits,
            processID: owningProcessID,
            activeClaimOwnerIDs: [owningClaimOwnerID],
            now: fixture.now
        )
        let firstRequestID = UUID()
        let firstRecord = IntentIdempotencyRecord(
            claimKey: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: firstRequestID,
            state: .running,
            terminalResult: nil,
            createdAt: fixture.now,
            updatedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(1)
        )
        guard case .inserted = try persistence.claim(
            record: firstRecord,
            maximumTerminalResultBytes: 512,
            replacingExpiredRequestID: nil,
            processID: owningProcessID,
            claimOwnerID: owningClaimOwnerID,
            limits: fixture.limits,
            now: fixture.now
        ) else {
            return XCTFail("Expected initial durable claim")
        }

        let replacement = IntentIdempotencyRecord(
            claimKey: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: UUID(),
            state: .claimed,
            terminalResult: nil,
            createdAt: fixture.now.addingTimeInterval(2),
            updatedAt: fixture.now.addingTimeInterval(2),
            expiresAt: fixture.now.addingTimeInterval(3)
        )
        let wrongRequest = try persistence.claim(
            record: replacement,
            maximumTerminalResultBytes: 512,
            replacingExpiredRequestID: UUID(),
            processID: owningProcessID,
            claimOwnerID: owningClaimOwnerID,
            limits: fixture.limits,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(wrongRequest, .existing(firstRecord))

        let replacementClaim = try persistence.claim(
            record: replacement,
            maximumTerminalResultBytes: 512,
            replacingExpiredRequestID: firstRequestID,
            processID: UUID(),
            claimOwnerID: UUID(),
            limits: fixture.limits,
            now: fixture.now.addingTimeInterval(2)
        )
        XCTAssertEqual(replacementClaim, .inserted(replacement))
        XCTAssertEqual(try persistence.snapshot().records, [replacement])
    }

    func testMalformedDurableStateIsRejectedDuringRestore() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let requestID = UUID()
        let first = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now
        )
        _ = try await first.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        let malformed = IntentIdempotencyRecord(
            claimKey: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            state: .terminal,
            terminalResult: nil,
            createdAt: fixture.now,
            updatedAt: fixture.now.addingTimeInterval(1),
            expiresAt: fixture.now.addingTimeInterval(10)
        )
        try overwritePersistedRecord(
            at: database.url,
            record: malformed,
            reservedBytes: 0
        )

        XCTAssertThrowsError(
            try makeStore(
                limits: fixture.limits,
                persistence: database.connection(),
                processID: UUID(),
                now: fixture.now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? IntentIdempotencyError,
                .malformedPersistedRecord
            )
        }
    }

    func testDurableIndexColumnsMustMatchEncodedRecordDuringRestore() async throws {
        let fixture = try Fixture()
        let database = TestSQLiteDatabase.temporary()
        defer { database.remove() }
        let requestID = UUID()
        let first = try makeStore(
            limits: fixture.limits,
            persistence: database.connection(),
            processID: UUID(),
            now: fixture.now
        )
        _ = try await first.claim(
            key: fixture.key,
            fingerprint: fixture.fingerprint,
            providerID: fixture.providerID,
            requestID: requestID,
            retentionMilliseconds: 10000,
            now: fixture.now
        )

        let snapshot = try await first.snapshot()
        let claimed = try XCTUnwrap(snapshot.records.first)
        try overwritePersistedRecord(
            at: database.url,
            record: claimed,
            indexedState: .terminal,
            reservedBytes: fixture.limits.maxTerminalResultBytes
        )

        XCTAssertThrowsError(
            try makeStore(
                limits: fixture.limits,
                persistence: database.connection(),
                processID: UUID(),
                now: fixture.now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? IntentIdempotencyError,
                .malformedPersistedRecord
            )
        }
    }
}

private final class FailingLookupPersistence: IntentIdempotencyPersistence {
    private let base: any IntentIdempotencyPersistence
    private let failureSwitch: LookupFailureSwitch

    init(
        base: any IntentIdempotencyPersistence,
        failureSwitch: LookupFailureSwitch
    ) {
        self.base = base
        self.failureSwitch = failureSwitch
    }

    func prepare(
        limits: IntentIdempotencyLimits,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws {
        try base.prepare(
            limits: limits,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func lookup(
        key: IntentIdempotencyClaimKey,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws -> IntentIdempotencyRecord? {
        if failureSwitch.shouldFailLookups() {
            throw IntentIdempotencyError.persistenceFailure
        }
        return try base.lookup(
            key: key,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func claim(
        record: IntentIdempotencyRecord,
        maximumTerminalResultBytes: Int,
        replacingExpiredRequestID: UUID?,
        processID: UUID,
        claimOwnerID: UUID,
        limits: IntentIdempotencyLimits,
        now: Date
    ) throws -> IntentIdempotencyPersistenceClaim {
        try base.claim(
            record: record,
            maximumTerminalResultBytes: maximumTerminalResultBytes,
            replacingExpiredRequestID: replacingExpiredRequestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            limits: limits,
            now: now
        )
    }

    func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try base.markRunning(
            key: key,
            requestID: requestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try base.settle(
            key: key,
            requestID: requestID,
            result: result,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func purgeExpired(now: Date) throws {
        try base.purgeExpired(now: now)
    }

    func snapshot() throws -> IntentIdempotencySnapshot {
        try base.snapshot()
    }
}

/// A conforming fault injector for the persistence protocol's claim postcondition:
/// it fails before delegating, so a thrown claim cannot have changed durable state.
private final class PrecommitFailingClaimPersistence: IntentIdempotencyPersistence {
    private let base: any IntentIdempotencyPersistence

    init(base: any IntentIdempotencyPersistence) {
        self.base = base
    }

    func prepare(
        limits: IntentIdempotencyLimits,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws {
        try base.prepare(
            limits: limits,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func lookup(
        key: IntentIdempotencyClaimKey,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws -> IntentIdempotencyRecord? {
        try base.lookup(
            key: key,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func claim(
        record: IntentIdempotencyRecord,
        maximumTerminalResultBytes: Int,
        replacingExpiredRequestID: UUID?,
        processID: UUID,
        claimOwnerID: UUID,
        limits: IntentIdempotencyLimits,
        now: Date
    ) throws -> IntentIdempotencyPersistenceClaim {
        throw IntentIdempotencyError.persistenceFailure
    }

    func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try base.markRunning(
            key: key,
            requestID: requestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try base.settle(
            key: key,
            requestID: requestID,
            result: result,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func purgeExpired(now: Date) throws {
        try base.purgeExpired(now: now)
    }

    func snapshot() throws -> IntentIdempotencySnapshot {
        try base.snapshot()
    }
}

private final class FailingSettlementPersistence: IntentIdempotencyPersistence {
    private let base: any IntentIdempotencyPersistence
    private let failureSwitch: SettlementFailureSwitch

    init(
        base: any IntentIdempotencyPersistence,
        failureSwitch: SettlementFailureSwitch
    ) {
        self.base = base
        self.failureSwitch = failureSwitch
    }

    func prepare(
        limits: IntentIdempotencyLimits,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws {
        try base.prepare(
            limits: limits,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func lookup(
        key: IntentIdempotencyClaimKey,
        processID: UUID,
        activeClaimOwnerIDs: Set<UUID>,
        now: Date
    ) throws -> IntentIdempotencyRecord? {
        try base.lookup(
            key: key,
            processID: processID,
            activeClaimOwnerIDs: activeClaimOwnerIDs,
            now: now
        )
    }

    func claim(
        record: IntentIdempotencyRecord,
        maximumTerminalResultBytes: Int,
        replacingExpiredRequestID: UUID?,
        processID: UUID,
        claimOwnerID: UUID,
        limits: IntentIdempotencyLimits,
        now: Date
    ) throws -> IntentIdempotencyPersistenceClaim {
        try base.claim(
            record: record,
            maximumTerminalResultBytes: maximumTerminalResultBytes,
            replacingExpiredRequestID: replacingExpiredRequestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            limits: limits,
            now: now
        )
    }

    func markRunning(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        try base.markRunning(
            key: key,
            requestID: requestID,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func settle(
        key: IntentIdempotencyClaimKey,
        requestID: UUID,
        result: IntentResult,
        processID: UUID,
        claimOwnerID: UUID,
        now: Date
    ) throws -> IntentIdempotencyRecord {
        if failureSwitch.shouldFailSettlements() {
            throw IntentIdempotencyError.persistenceFailure
        }
        return try base.settle(
            key: key,
            requestID: requestID,
            result: result,
            processID: processID,
            claimOwnerID: claimOwnerID,
            now: now
        )
    }

    func purgeExpired(now: Date) throws {
        try base.purgeExpired(now: now)
    }

    func snapshot() throws -> IntentIdempotencySnapshot {
        try base.snapshot()
    }
}

private final class LookupFailureSwitch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func failLookups() {
        state.withLock { $0 = true }
    }

    func shouldFailLookups() -> Bool {
        state.withLock { $0 }
    }
}

private final class SettlementFailureSwitch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func failSettlements() {
        state.withLock { $0 = true }
    }

    func shouldFailSettlements() -> Bool {
        state.withLock { $0 }
    }
}

private struct TestSQLiteDatabase {
    let url: URL

    func connection() throws -> IntentSQLiteIdempotencyPersistence {
        try IntentSQLiteIdempotencyPersistence(url: url)
    }

    static func temporary() -> TestSQLiteDatabase {
        TestSQLiteDatabase(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("tenon-idempotency-\(UUID().uuidString).sqlite")
        )
    }

    func remove() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix)
            )
        }
    }
}

private func overwritePersistedRecord(
    at url: URL,
    record: IntentIdempotencyRecord,
    indexedState: IntentIdempotencyState? = nil,
    reservedBytes: Int
) throws {
    let data = try IntentIdempotencyCoding.encoder().encode(record)
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database
    else {
        throw IntentIdempotencyError.persistenceFailure
    }
    defer { sqlite3_close_v2(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        UPDATE tenon_idempotency_claims
        SET state = ?, encoded_bytes = ?, reserved_bytes = ?, record = ?
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement
    else {
        throw IntentIdempotencyError.persistenceFailure
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(
        statement,
        1,
        (indexedState ?? record.state).rawValue,
        -1,
        transient
    ) == SQLITE_OK,
        sqlite3_bind_int64(statement, 2, Int64(data.count)) == SQLITE_OK,
        sqlite3_bind_int64(statement, 3, Int64(reservedBytes)) == SQLITE_OK,
        data.withUnsafeBytes({
            sqlite3_bind_blob(
                statement,
                4,
                $0.baseAddress,
                Int32($0.count),
                transient
            )
        }) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
    else {
        throw IntentIdempotencyError.persistenceFailure
    }
}

private func makeStore(
    limits: IntentIdempotencyLimits,
    persistence: sending (any IntentIdempotencyPersistence)? = nil,
    processID: UUID? = nil,
    claimOwnerID: UUID? = nil,
    now: Date = Date()
) throws -> IntentIdempotencyStore {
    let resolvedPersistence: any IntentIdempotencyPersistence = if let persistence {
        persistence
    } else {
        try IntentSQLiteIdempotencyPersistence.inMemory()
    }
    return try IntentIdempotencyStore(
        limits: limits,
        persistence: resolvedPersistence,
        processID: processID,
        claimOwnerID: claimOwnerID,
        now: now
    )
}

private struct Fixture {
    let key: IntentIdempotencyClaimKey
    let fingerprint: IntentIdempotencyFingerprint
    let providerID: ProviderID
    let limits: IntentIdempotencyLimits
    let now: Date

    init(
        limits: IntentIdempotencyLimits? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws {
        self.now = now
        let intentID = try IntentID("terminal.run.v1")
        key = try IntentIdempotencyClaimKey(
            principal: IntentPrincipal(
                id: "plugin:dev.tenon.git",
                kind: .plugin,
                sessionRevision: 1
            ),
            intentID: intentID,
            key: "operation-1"
        )
        fingerprint = try IntentIdempotencyFingerprint(
            inputDigest: IntentValue.object([
                "command": .string("git status"),
            ]).canonicalSHA256Digest(),
            explicitTarget: nil
        )
        providerID = try ProviderID("dev.tenon.terminal")
        self.limits = try limits ?? IntentIdempotencyLimits()
    }

    func key(suffix: String) throws -> IntentIdempotencyClaimKey {
        try IntentIdempotencyClaimKey(
            principal: key.principal,
            intentID: key.intentID,
            key: suffix
        )
    }
}
