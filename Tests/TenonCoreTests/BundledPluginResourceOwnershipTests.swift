import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// The resources a compiled `bundled-swift` generation owns, and what settles them.
///
/// A bundled program owns its event pump, bounded mailbox, provider bindings, and any typed
/// timers or filesystem watches it starts. Resource callbacks enter the same pump as events and
/// view callbacks, while generation retirement and view-instance closure cancel their owned
/// resources without consulting plugin code.
final class BundledPluginResourceOwnershipTests: XCTestCase {
    private static var pluginsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")
    }

    // The clock's only "timer" is the manifest automation schedule the host fires back as
    // `automation.fired`. The subscription table is static program shape, so it still
    // answers `handles` after stop — liveness belongs to the mailbox, and a retired
    // generation's mailbox refuses the tick.
    func testAutomationTickCannotReachARetiredClockGeneration() async throws {
        let directory = Self.pluginsRoot.appendingPathComponent("clock")
        let manifest = try PluginLoader.loadManifest(at: directory)
        XCTAssertFalse(manifest.automation?.schedules.isEmpty ?? true)
        let runtime = try await BundledPluginRuntime.factory.make(
            PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                )
            )
        )

        let started = try await runtime.start()
        XCTAssertEqual(started.snapshot.statusBarText?.hasPrefix("🕐"), true)
        XCTAssertTrue(
            runtime.acceptEvent(event: "automation.fired", payload: .object([:]))
        )

        let report = await runtime.shutdown(timeout: 2)
        XCTAssertEqual(report.executorResult, .stopped)
        let handlesTick = await runtime.handles(event: "automation.fired")
        XCTAssertTrue(handlesTick)
        XCTAssertFalse(
            runtime.acceptEvent(event: "automation.fired", payload: .object([:]))
        )
    }

    func testACooperativePumpMeetsTheShutdownDeadlineAndLaterEventsStayUnconsumed() async throws {
        let counter = InvocationCounter()
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: ["poke"],
                providedIntents: [],
                activate: { _ in .empty },
                receiveEvent: { _, _, _ in
                    await counter.increment()
                    return nil
                },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            )
        )

        _ = try await runtime.start()
        XCTAssertTrue(runtime.acceptEvent(event: "poke", payload: .object([:])))
        try await counter.waitUntil(count: 1)

        let report = await runtime.shutdown(timeout: 2)
        XCTAssertEqual(report.executorResult, .stopped)
        XCTAssertNil(report.stalledPhase)
        XCTAssertFalse(runtime.acceptEvent(event: "poke", payload: .object([:])))
        try await Task.sleep(for: .milliseconds(20))
        let consumed = await counter.count
        XCTAssertEqual(consumed, 1)
    }

    // The stalled report is the deadline keeping its promise; what this adds is the other
    // half of `PRT-G-003`: when the overdue handler finally returns, its contribution is
    // discarded — no revision, no status text, no snapshot leaves the stopped generation.
    func testAHandlerStillRunningAtShutdownCannotMutateAfterStop() async throws {
        let gate = ResourceGate()
        let log = SnapshotLog()
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: ["poke"],
                providedIntents: [],
                activate: { _ in .empty },
                receiveEvent: { _, _, _ in
                    await gate.wait()
                    return BundledPluginContribution(statusBarText: "late")
                },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            ),
            onStateChange: { snapshot in await log.record(snapshot) }
        )

        _ = try await runtime.start()
        XCTAssertTrue(runtime.acceptEvent(event: "poke", payload: .object([:])))
        try await gate.waitUntilEntered()

        let report = await runtime.shutdown(timeout: 0.05)
        XCTAssertEqual(report.stalledPhase, .callbackPump)
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.phase, .stopped)

        await gate.release()
        try await gate.waitUntilReleased()
        try await Task.sleep(for: .milliseconds(100))

        let final = await runtime.snapshot()
        XCTAssertEqual(final.revision, stopped.revision)
        XCTAssertEqual(final.phase, .stopped)
        XCTAssertNil(final.statusBarText)
        let recorded = await log.all()
        XCTAssertEqual(recorded.map(\.phase), [.stopped])
        XCTAssertFalse(recorded.contains { $0.statusBarText == "late" })
    }

    func testABindingInvokedAfterShutdownIsRefusedWithoutRunningTheProgram() async throws {
        let pingID = try IntentID("dev.example.native-res.ping.v1")
        let counter = InvocationCounter()
        let runtime = try makeRuntime(
            program: Self.pingProgram(pingID: pingID, counter: counter),
            provides: [pingID]
        )

        let started = try await runtime.start()
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == pingID }
        )
        let live = try await binding.invoke(
            envelope: Self.makeEnvelope(intentID: pingID),
            context: Self.makeContext()
        )
        XCTAssertEqual(live, .success(.object([:])))

        _ = await runtime.shutdown(timeout: 2)
        do {
            _ = try await binding.invoke(
                envelope: Self.makeEnvelope(intentID: pingID),
                context: Self.makeContext()
            )
            XCTFail("a stopped generation accepted a provider call")
        } catch {
            XCTAssertEqual(
                error as? PluginRuntimeError,
                .runtimeStopped
            )
        }
        let invocations = await counter.count
        XCTAssertEqual(invocations, 1)
    }

    func testARepeatingTimerOwnedByAViewDiesWhenThatViewCloses() async throws {
        let counter = InvocationCounter()
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: ["start-timer"],
                providedIntents: [],
                activate: { _ in
                    BundledPluginContribution(
                        views: [
                            PluginViewInfo(
                                viewID: "board",
                                instanceID: nil,
                                instanced: true,
                                title: "Board",
                                items: [],
                                body: nil
                            ),
                        ]
                    )
                },
                receiveEvent: { _, _, context in
                    _ = try await context.timers.every(
                        10,
                        ownedBy: "pane-a"
                    ) {
                        await counter.increment()
                    }
                    return nil
                },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            )
        )

        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: "pane-a")
        XCTAssertTrue(
            runtime.acceptEvent(event: "start-timer", payload: .object([:]))
        )
        try await counter.waitUntil(count: 1)
        try await runtime.closeViewInstance(viewID: "board", instanceID: "pane-a")
        let atClose = await counter.count

        try await Task.sleep(for: .milliseconds(80))
        let afterClose = await counter.count
        XCTAssertEqual(
            afterClose,
            atClose,
            "a timer owned by a closed view instance fired again"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testAWatchWithoutFilesystemPermissionIsRefusedAndRecorded() async throws {
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: ["start-watch"],
                providedIntents: [],
                activate: { _ in .empty },
                receiveEvent: { _, _, context in
                    let first = await context.fs.watch("~/project") { _ in }
                    let second = await context.fs.watch("~/project") { _ in }
                    await context.publishContribution(
                        BundledPluginContribution(
                            statusBarText: (first == nil && second == nil)
                                ? "watch-denied"
                                : "watch-started"
                        )
                    )
                    return nil
                },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            )
        )

        _ = try await runtime.start()
        XCTAssertTrue(
            runtime.acceptEvent(event: "start-watch", payload: .object([:]))
        )
        let deadline = ContinuousClock.now + .seconds(2)
        var snapshot = await runtime.snapshot()
        while snapshot.statusBarText != "watch-denied", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            snapshot = await runtime.snapshot()
        }
        XCTAssertEqual(snapshot.statusBarText, "watch-denied")
        XCTAssertEqual(
            snapshot.permissionViolations,
            ["tenon.fs.watch requires permission filesystem.read"]
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testIntentHandlerPushesASeparatedContributionThroughThePump() async throws {
        let intentID = try IntentID("dev.example.native-res.render.v1")
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: [],
                providedIntents: [intentID],
                activate: { _ in .empty },
                receiveEvent: { _, _, _ in nil },
                invokeIntent: { _, _, context in
                    await context.publishContribution(
                        BundledPluginContribution(
                            statusBarText: "intent-pushed",
                            viewRegistrations: [
                                BundledPluginViewRegistration(
                                    viewID: "panel",
                                    title: "Panel",
                                    instanced: false
                                ),
                            ],
                            viewBodies: [
                                BundledPluginViewBody(
                                    viewID: "panel",
                                    instanceID: nil,
                                    body: .text(
                                        "from intent",
                                        style: .body,
                                        weight: .regular,
                                        color: .default
                                    )
                                ),
                            ]
                        )
                    )
                    return .success(.object([:]))
                }
            ),
            provides: [intentID]
        )

        let started = try await runtime.start()
        let binding = try XCTUnwrap(started.bindings.first)
        let reply = try await binding.invoke(
            envelope: Self.makeEnvelope(intentID: intentID),
            context: Self.makeContext()
        )
        XCTAssertEqual(reply, .success(.object([:])))

        let deadline = ContinuousClock.now + .seconds(2)
        var snapshot = await runtime.snapshot()
        while snapshot.statusBarText != "intent-pushed", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            snapshot = await runtime.snapshot()
        }
        XCTAssertEqual(snapshot.statusBarText, "intent-pushed")
        XCTAssertEqual(snapshot.views.map(\.viewID), ["panel"])
        XCTAssertEqual(
            snapshot.views.first?.body,
            .text(
                "from intent",
                style: .body,
                weight: .regular,
                color: .default
            )
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testABindingOutlivingItsRuntimeActorFailsAsProviderRetired() async throws {
        let pingID = try IntentID("dev.example.native-res.ping.v1")
        let counter = InvocationCounter()
        var runtime: BundledPluginRuntimeActor? = try makeRuntime(
            program: Self.pingProgram(pingID: pingID, counter: counter),
            provides: [pingID]
        )

        let started = try await XCTUnwrap(runtime).start()
        let binding = try XCTUnwrap(
            started.bindings.first { $0.intentID == pingID }
        )
        _ = await runtime?.shutdown(timeout: 2)
        runtime = nil

        let reply = try await binding.invoke(
            envelope: Self.makeEnvelope(intentID: pingID),
            context: Self.makeContext()
        )
        XCTAssertEqual(
            reply,
            .failure(IntentProviderFailure(code: .kernel(.providerRetired)))
        )
        let invocations = await counter.count
        XCTAssertEqual(invocations, 0)
    }

    // There is no view-owned resource to cancel here — the compiled runtime registers no
    // timers, watchers, or streams against a view instance, so open/close carry only the
    // phase gate. This pins the gate: after stop, the remaining host-facing mutation
    // surfaces (view instance lifecycle, event delivery) are refused, not ignored.
    func testViewLifecycleAndEventDeliveryAreRefusedAfterStop() async throws {
        let runtime = try makeRuntime(
            program: BundledPluginProgram(
                id: "dev.example.native-res",
                subscribedEvents: [],
                providedIntents: [],
                activate: { _ in .empty },
                receiveEvent: { _, _, _ in nil },
                invokeIntent: { envelope, _ in
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            )
        )

        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: "one")
        try await runtime.closeViewInstance(viewID: "board", instanceID: "one")

        _ = await runtime.shutdown(timeout: 2)
        let attempts: [@Sendable () async throws -> Void] = [
            { try await runtime.openViewInstance(viewID: "board", instanceID: "two") },
            { try await runtime.closeViewInstance(viewID: "board", instanceID: "one") },
            { try await runtime.deliverEvent(event: "tick", payload: .object([:])) },
        ]
        for attempt in attempts {
            do {
                try await attempt()
                XCTFail("a stopped generation accepted a mutation")
            } catch {
                XCTAssertEqual(error as? PluginRuntimeError, .runtimeStopped)
            }
        }
    }

    private func makeRuntime(
        program: BundledPluginProgram,
        provides: [IntentID] = [],
        permissions: [String] = [],
        watcherStart: @escaping @Sendable (PathWatcher) -> Bool = { _ in false },
        onStateChange: @escaping PluginRuntimeConfiguration.StateChange = { _ in }
    ) throws -> BundledPluginRuntimeActor {
        BundledPluginRuntimeActor(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginManifest(
                    id: program.id,
                    name: "native-res",
                    version: "1.0.0",
                    runtime: .bundledSwift,
                    permissions: permissions,
                    intents: PluginIntentManifest(
                        provides: provides.map { PluginIntentProvision(name: $0) }
                    )
                ),
                directory: FileManager.default.temporaryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailableResult() },
                    list: { .array([]) }
                ),
                onStateChange: onStateChange
            ),
            program: program,
            watcherStart: watcherStart
        )
    }

    private static func pingProgram(
        pingID: IntentID,
        counter: InvocationCounter
    ) -> BundledPluginProgram {
        BundledPluginProgram(
            id: "dev.example.native-res",
            subscribedEvents: [],
            providedIntents: [pingID],
            activate: { _ in .empty },
            receiveEvent: { _, _, _ in nil },
            invokeIntent: { _, _ in
                await counter.increment()
                return .success(.object([:]))
            }
        )
    }

    private static func makeEnvelope(intentID: IntentID) -> IntentEnvelope {
        IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: .object([:]),
            caller: IntentPrincipal(
                id: "tests",
                kind: .user,
                sessionRevision: 1
            ),
            scope: InvocationScope(),
            deadline: .now.advanced(by: .seconds(5)),
            target: nil,
            idempotencyKey: nil
        )
    }

    private static func makeContext() -> IntentProviderContext {
        IntentProviderContext(
            requestID: UUID(),
            nestedSend: { _ in Self.unavailableResult() }
        )
    }

    private static func unavailableResult() -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.providerUnavailable),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: nil
        )
    }
}

private actor InvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    func waitUntil(count target: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while count < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard count >= target else {
            throw BundledResourceTestError.timedOut
        }
    }
}

private actor SnapshotLog {
    private var snapshots: [PluginRuntimeSnapshot] = []

    func record(_ snapshot: PluginRuntimeSnapshot) {
        snapshots.append(snapshot)
    }

    func all() -> [PluginRuntimeSnapshot] {
        snapshots
    }
}

private actor ResourceGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        released = true
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard entered else { throw BundledResourceTestError.timedOut }
    }

    func waitUntilReleased() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !released, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard released else { throw BundledResourceTestError.timedOut }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private enum BundledResourceTestError: Error {
    case timedOut
}
