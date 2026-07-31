import Foundation
import XCTest
@testable import TenonIntentCore

final class ProviderRegistryTests: XCTestCase {
    func testFailedStagingLeavesActiveGenerationRoutable() async throws {
        let fixture = try Fixture()
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.failStaging(
            providerID: fixture.providerID,
            generation: 2,
            diagnostic: "syntax error"
        )

        let lease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.intentID,
                trustedDefault: fixture.providerID
            )
        )
        XCTAssertEqual(lease.generation, 1)
        await lease.release()

        let snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 2 }?.lifecycle,
            .failed
        )
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 2 }?.failure,
            "syntax error"
        )
    }

    func testAtomicSwapRoutesNewCallsToNewGenerationAndDrainsOldLease() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let oldLease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)

        let newLease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )
        XCTAssertEqual(oldLease.generation, 1)
        XCTAssertEqual(newLease.generation, 2)

        var snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.lifecycle,
            .draining
        )
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.leaseCount,
            1
        )

        await oldLease.release()
        await oldLease.release()
        await newLease.release()
        await waitForShutdowns(probe, count: 1)

        snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.lifecycle,
            .retired
        )
        let shutdownReasons = await probe.shutdownReasons()
        XCTAssertEqual(shutdownReasons, [.drained])
    }

    func testResolutionOrderIsExplicitConfiguredTrustedUniqueThenAmbiguous() async throws {
        let intentID = try IntentID("file.open.v1")
        let first = try Fixture(
            intentID: intentID,
            providerID: ProviderID("dev.tenon.first")
        )
        let second = try Fixture(
            intentID: intentID,
            providerID: ProviderID("dev.tenon.second")
        )
        let registry = ProviderRegistry()

        try await registry.stage(first.candidate(generation: 1))
        try await registry.activate(providerID: first.providerID, generation: 1)
        try await registry.stage(second.candidate(generation: 1))
        try await registry.activate(providerID: second.providerID, generation: 1)

        let explicit = try await registry.resolveAndAcquire(
            .init(intentID: intentID, explicitTarget: second.providerID)
        )
        XCTAssertEqual(explicit.providerID, second.providerID)
        await explicit.release()

        try await registry.setConfiguredDefault(first.providerID, for: intentID)
        let configured = try await registry.resolveAndAcquire(
            .init(intentID: intentID, trustedDefault: second.providerID)
        )
        XCTAssertEqual(configured.providerID, first.providerID)
        await configured.release()

        try await registry.setConfiguredDefault(nil, for: intentID)
        let trusted = try await registry.resolveAndAcquire(
            .init(intentID: intentID, trustedDefault: second.providerID)
        )
        XCTAssertEqual(trusted.providerID, second.providerID)
        await trusted.release()

        do {
            _ = try await registry.resolveAndAcquire(.init(intentID: intentID))
            XCTFail("Expected ambiguity")
        } catch let error as ProviderResolutionError {
            XCTAssertEqual(
                error,
                .ambiguousProvider(
                    intentID: intentID,
                    candidates: [first.providerID, second.providerID]
                )
            )
        }
    }

    func testAutomaticSelectionRequiresContractOptIn() async throws {
        let fixture = try Fixture()
        let registry = ProviderRegistry()
        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)

        do {
            _ = try await registry.resolveAndAcquire(
                .init(intentID: fixture.intentID)
            )
            XCTFail("Expected ambiguity without auto-selection")
        } catch let error as ProviderResolutionError {
            XCTAssertEqual(
                error,
                .ambiguousProvider(
                    intentID: fixture.intentID,
                    candidates: [fixture.providerID]
                )
            )
        }

        let lease = try await registry.resolveAndAcquire(
            .init(
                intentID: fixture.intentID,
                allowsAutomaticSelection: true
            )
        )
        XCTAssertEqual(lease.providerID, fixture.providerID)
        await lease.release()
    }

    func testSelectionPinsExactGenerationAcrossReloadWhenOldGenerationStillDrains() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let keepAlive = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )
        let selection = try await registry.resolveAndHold(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)

        let pinned = try await registry.acquire(selection)
        XCTAssertEqual(pinned.generation, 1)
        await pinned.release()
        await keepAlive.release()
        await waitForShutdowns(probe, count: 1)
    }

    func testSelectionHoldKeepsGenerationAcquirableAcrossReloadWithoutLease() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let selection = try await registry.resolveAndHold(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)

        var snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.selectionCount,
            1
        )
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.lifecycle,
            .draining
        )

        let lease = try await registry.acquire(selection)
        XCTAssertEqual(lease.generation, 1)
        await lease.release()
        await waitForShutdowns(probe, count: 1)

        snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.lifecycle,
            .retired
        )
    }

    func testReleasingUnconsumedSelectionAllowsOldGenerationToRetire() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let selection = try await registry.resolveAndHold(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)
        await registry.releaseSelection(selection)
        await registry.releaseSelection(selection)
        await waitForShutdowns(probe, count: 1)
    }

    func testNewerStagingGenerationSupersedesOlderAndPreventsRollback() async throws {
        let fixture = try Fixture()
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.stage(fixture.candidate(generation: 3))
        try await registry.activate(providerID: fixture.providerID, generation: 3)

        do {
            try await registry.activate(providerID: fixture.providerID, generation: 2)
            XCTFail("Expected stale staging generation to be rejected")
        } catch let error as ProviderRegistryError {
            XCTAssertEqual(
                error,
                .generationSuperseded(
                    providerID: fixture.providerID,
                    generation: 2,
                    latest: 3
                )
            )
        }

        let lease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )
        XCTAssertEqual(lease.generation, 3)
        await lease.release()
    }

    func testRegistryRevisionRemainsMonotonicPastUInt64Boundary() async throws {
        let fixture = try Fixture()
        let boundary = ProviderRegistryRevision(UInt64.max)
        let registry = ProviderRegistry(initialRevisionForTesting: boundary)

        try await registry.stage(fixture.candidate(generation: 1))

        let snapshot = await registry.snapshot()
        XCTAssertGreaterThan(snapshot.revision, boundary)
    }

    func testOwnerMismatchCannotClaimExistingProviderIdentity() async throws {
        let fixture = try Fixture()
        let registry = ProviderRegistry()
        try await registry.stage(fixture.candidate(generation: 1))

        let attackerOwner = IntentProviderOwner.plugin(
            id: PluginID("example.attacker"),
            installationID: UUID()
        )
        let attacker = try ProviderGenerationCandidate(
            providerID: fixture.providerID,
            owner: attackerOwner,
            principal: attackerOwner.principal(sessionRevision: 2),
            generation: 2,
            bindings: [
                IntentProviderBinding(intentID: fixture.intentID) { _, _ in
                    .success(.object([:]))
                },
            ],
            policyFingerprint: try PolicyFingerprint(
                canonicalPolicy: .object(["owner": .string("attacker")])
            ),
            mailbox: IntentMailbox(limits: try IntentMailboxLimits())
        )

        do {
            try await registry.stage(attacker)
            XCTFail("Expected owner mismatch")
        } catch let error as ProviderRegistryError {
            XCTAssertEqual(error, .ownerMismatch(providerID: fixture.providerID))
        }
    }

    func testDrainDeadlineForcesRetirementAndSignalsProvider() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe, drainTimeout: .milliseconds(20))
        let registry = ProviderRegistry()

        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let oldLease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)
        try await Task.sleep(for: .milliseconds(60))

        let snapshot = await registry.snapshot()
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 1 }?.lifecycle,
            .retired
        )
        let shutdownReasons = await probe.shutdownReasons()
        XCTAssertTrue(shutdownReasons.isEmpty)
        await oldLease.release()
        await waitForShutdowns(probe, count: 1)
        let reasonsAfterRelease = await probe.shutdownReasons()
        XCTAssertEqual(reasonsAfterRelease, [.drainDeadlineExceeded])
    }

    func testDrainDeadlineSettlesLogicalCallerButWaitsForPhysicalIdle() async throws {
        let probe = Probe()
        let operationGate = RegistryGate()
        let mailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let fixture = try Fixture(probe: probe, drainTimeout: .milliseconds(20))
        let registry = ProviderRegistry()

        try await registry.stage(
            fixture.candidate(generation: 1, mailbox: mailbox)
        )
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        let oldLease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )

        let requestID = UUID()
        let job = try IntentMailboxJob(
            requestID: requestID,
            principal: IntentPrincipal(
                id: "deadline-test",
                kind: .plugin,
                sessionRevision: 1
            ),
            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
            encodedBytes: 1,
            admissionClass: .interactive
        ) {
            await operationGate.wait()
            return .success(.string("late"))
        }
        let submitted = Task {
            try await mailbox.submit(job)
        }
        await waitForRunning(mailbox, requestID: requestID)

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)

        let terminal = try await submitted.value
        XCTAssertEqual(terminal, .providerRetired(.unknown))
        await oldLease.release()
        let reasonsBeforePhysicalCompletion = await probe.shutdownReasons()
        XCTAssertTrue(reasonsBeforePhysicalCompletion.isEmpty)

        let beforePhysicalCompletion = await mailbox.snapshot()
        XCTAssertFalse(beforePhysicalCompletion.isPhysicallyIdle)
        await operationGate.open()
        await waitForShutdowns(probe, count: 1)
        let reasonsAfterPhysicalCompletion = await probe.shutdownReasons()
        XCTAssertEqual(reasonsAfterPhysicalCompletion, [.drainDeadlineExceeded])
    }

    func testUninstallReinstallCannotReuseGenerationOrDeleteSuccessor() async throws {
        let probe = Probe()
        let shutdownGate = RegistryGate()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()

        try await registry.stage(
            fixture.candidate(generation: 1, shutdownGate: shutdownGate)
        )
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        try await registry.uninstall(fixture.providerID)
        await waitForShutdowns(probe, count: 1)

        let nextGeneration = try await registry.nextGeneration(for: fixture.providerID)
        XCTAssertEqual(nextGeneration, 2)
        do {
            try await registry.stage(fixture.candidate(generation: 1))
            XCTFail("Expected monotonic generation rejection")
        } catch let error as ProviderRegistryError {
            XCTAssertEqual(
                error,
                .generationOutOfSequence(expected: 2, actual: 1)
            )
        }

        try await registry.stage(fixture.candidate(generation: 2))
        try await registry.activate(providerID: fixture.providerID, generation: 2)
        await shutdownGate.open()
        await waitForResidentGenerations(registry, count: 1)

        let lease = try await registry.resolveAndAcquire(
            .init(intentID: fixture.intentID, trustedDefault: fixture.providerID)
        )
        XCTAssertEqual(lease.generation, 2)
        await lease.release()

        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.residentGenerations, 1)
        XCTAssertEqual(
            snapshot.generations.first { $0.generation == 2 }?.lifecycle,
            .active
        )
    }

    func testCompletedRuntimeGenerationsArePrunedToBoundedHistory() async throws {
        let fixture = try Fixture()
        let registry = ProviderRegistry()

        for generation in 1 ... 70 {
            try await registry.stage(
                fixture.candidate(generation: UInt64(generation))
            )
            try await registry.activate(
                providerID: fixture.providerID,
                generation: UInt64(generation)
            )
        }
        try await registry.disable(fixture.providerID)
        await waitForResidentGenerations(registry, count: 0)

        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.residentGenerations, 0)
        XCTAssertEqual(snapshot.retiredHistoryEntries, 64)
        XCTAssertEqual(snapshot.generations.count, 64)
    }

    func testDisableRemovesProviderFromResolutionAndInvalidatesDefault() async throws {
        let probe = Probe()
        let fixture = try Fixture(probe: probe)
        let registry = ProviderRegistry()
        try await registry.stage(fixture.candidate(generation: 1))
        try await registry.activate(providerID: fixture.providerID, generation: 1)
        try await registry.setConfiguredDefault(fixture.providerID, for: fixture.intentID)

        try await registry.disable(fixture.providerID)

        do {
            _ = try await registry.resolveAndAcquire(
                .init(
                    intentID: fixture.intentID,
                    explicitTarget: fixture.providerID
                )
            )
            XCTFail("Expected unavailable provider")
        } catch let error as ProviderResolutionError {
            XCTAssertEqual(
                error,
                .providerUnavailable(
                    intentID: fixture.intentID,
                    providerID: fixture.providerID
                )
            )
        }

        let snapshot = await registry.snapshot()
        XCTAssertNil(snapshot.configuredDefaults[fixture.intentID])
        await waitForShutdowns(probe, count: 1)
        let shutdownReasons = await probe.shutdownReasons()
        XCTAssertEqual(shutdownReasons, [.disabled])
    }

    private func waitForShutdowns(
        _ probe: Probe,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await probe.shutdownReasons().count == count {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Shutdown probe never reached \(count)", file: file, line: line)
    }

    private func waitForResidentGenerations(
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
        XCTFail("Registry never reached \(count) resident generations", file: file, line: line)
    }

    private func waitForRunning(
        _ mailbox: IntentMailbox,
        requestID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 2_000 {
            if await mailbox.snapshot().runningRequestIDs.contains(requestID) {
                return
            }
            await Task.yield()
        }
        XCTFail("Mailbox never started request", file: file, line: line)
    }
}

private actor Probe {
    private var reasons: [ProviderRetirementReason] = []

    func record(_ reason: ProviderRetirementReason) {
        reasons.append(reason)
    }

    func shutdownReasons() -> [ProviderRetirementReason] {
        reasons
    }
}

private struct Fixture {
    let intentID: IntentID
    let providerID: ProviderID
    let owner: IntentProviderOwner
    let probe: Probe
    let drainTimeout: Duration

    init(
        intentID: IntentID? = nil,
        providerID: ProviderID? = nil,
        probe: Probe = Probe(),
        drainTimeout: Duration = .seconds(1)
    ) throws {
        self.intentID = try intentID ?? IntentID("terminal.run.v1")
        self.providerID = try providerID ?? ProviderID("dev.tenon.terminal")
        self.owner = .plugin(
            id: PluginID("dev.tenon.terminal"),
            installationID: UUID(uuidString: "E2BFA66E-0957-4F90-A283-B6DC8FD2887A")!
        )
        self.probe = probe
        self.drainTimeout = drainTimeout
    }

    func candidate(
        generation: UInt64,
        mailbox: IntentMailbox? = nil,
        shutdownGate: RegistryGate? = nil
    ) throws -> ProviderGenerationCandidate {
        try ProviderGenerationCandidate(
            providerID: providerID,
            owner: owner,
            principal: owner.principal(sessionRevision: generation),
            generation: generation,
            bindings: [
                IntentProviderBinding(intentID: intentID) { _, _ in
                    .success(.object(["generation": .integer(Int64(generation))]))
                },
            ],
            policyFingerprint: try PolicyFingerprint(
                canonicalPolicy: .object(["generation": .integer(Int64(generation))])
            ),
            mailbox: try mailbox ?? IntentMailbox(limits: IntentMailboxLimits()),
            drainTimeout: drainTimeout
        ) { [probe, shutdownGate] reason in
            await probe.record(reason)
            await shutdownGate?.wait()
        }
    }
}

private actor RegistryGate {
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
