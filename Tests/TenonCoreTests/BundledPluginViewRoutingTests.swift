import Foundation
@testable import TenonBundledPlugins
@testable import TenonCore
import TenonIntentCore
import XCTest

/// The routing coverage T-156's migration guard demanded before any view-publishing port:
/// a compiled plugin's select/submit/open/close reach its program through the same bounded
/// callback pump events use, and open instances appear in the snapshot the host reconciles.
final class BundledPluginViewRoutingTests: XCTestCase {
    func testSelectAnswersHandlerPresenceAndRunsTheHandlerOnThePump() async throws {
        let recorder = CallbackRecorder()
        let program = Self.makeProgram(
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    select: { select, _ in
                        await recorder.record(
                            "select:\(select.itemID):"
                                + "\(select.instanceID ?? "-"):"
                                + Self.describe(select.value)
                        )
                        return BundledPluginContribution(
                            statusBarText: "selected \(select.itemID)",
                            views: [Self.boardRegistration]
                        )
                    }
                ),
                "submit-only": BundledPluginViewCallbacks(
                    submit: { _, _ in nil }
                ),
            ]
        )
        let (runtime, snapshots) = try await Self.startedRuntime(program: program)

        let handled = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: "A",
            itemID: "card-1",
            value: .string("payload")
        )
        XCTAssertTrue(handled, "a registered select handler must report handled")
        let unknownView = try await runtime.invokeViewSelect(
            viewID: "elsewhere",
            instanceID: nil,
            itemID: "card-1",
            value: nil
        )
        XCTAssertFalse(unknownView, "a view without callbacks must report unhandled")
        let submitOnly = try await runtime.invokeViewSelect(
            viewID: "submit-only",
            instanceID: nil,
            itemID: "card-1",
            value: nil
        )
        XCTAssertFalse(
            submitOnly,
            "handler presence is per callback, not per view: a submit-only view "
                + "must report select unhandled"
        )

        try await recorder.wait(for: ["select:card-1:A:payload"])
        let updated = try await snapshots.snapshot(
            where: { $0.statusBarText == "selected card-1" }
        )
        XCTAssertEqual(updated.phase, .active)
        _ = await runtime.shutdown(timeout: 2)
    }

    func testSubmitDeliversTextToTheRegisteredHandler() async throws {
        let recorder = CallbackRecorder()
        let program = Self.makeProgram(
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    submit: { submit, _ in
                        await recorder.record("submit:\(submit.itemID):\(submit.text)")
                        return nil
                    }
                ),
            ]
        )
        let (runtime, _) = try await Self.startedRuntime(program: program)

        let handled = try await runtime.invokeViewSubmit(
            viewID: "board",
            instanceID: nil,
            itemID: "new-card",
            text: "write the tests first"
        )
        XCTAssertTrue(handled)
        let unhandled = try await runtime.invokeViewSubmit(
            viewID: "board-with-no-submit",
            instanceID: nil,
            itemID: "new-card",
            text: ""
        )
        XCTAssertFalse(unhandled)

        try await recorder.wait(for: ["submit:new-card:write the tests first"])
        _ = await runtime.shutdown(timeout: 2)
    }

    func testOpenAndCloseTrackInstancesIdempotentlyAndReachTheProgram() async throws {
        let recorder = CallbackRecorder()
        let program = Self.makeProgram(
            activate: {
                _ in BundledPluginContribution(
                    views: [Self.boardRegistration, Self.plainRegistration]
                )
            },
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    open: { instanceID, _ in
                        await recorder.record("open:\(instanceID)")
                        return nil
                    },
                    close: { instanceID, _ in
                        await recorder.record("close:\(instanceID)")
                        return nil
                    }
                ),
            ]
        )
        let (runtime, _) = try await Self.startedRuntime(program: program)

        try await runtime.openViewInstance(viewID: "board", instanceID: "A")
        try await runtime.openViewInstance(viewID: "board", instanceID: "A")
        var snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.openViewInstances,
            [PluginViewInstanceKey(viewID: "board", instanceID: "A")],
            "a reopened instance must not be tracked twice"
        )

        try await runtime.openViewInstance(viewID: "plain", instanceID: "B")
        snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.openViewInstances,
            [PluginViewInstanceKey(viewID: "board", instanceID: "A")],
            "a view that is not instanced must not track instances"
        )

        try await runtime.closeViewInstance(viewID: "board", instanceID: "A")
        try await runtime.closeViewInstance(viewID: "board", instanceID: "A")
        snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.openViewInstances, [])

        try await recorder.wait(for: ["open:A", "close:A"])
        _ = await runtime.shutdown(timeout: 2)
    }

    func testCloseDropsTheClosedInstancesPublishedViewBody() async throws {
        let program = Self.makeProgram(
            activate: { _ in
                BundledPluginContribution(views: [Self.boardRegistration])
            },
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    open: { instanceID, _ in
                        BundledPluginContribution(
                            views: [
                                Self.boardRegistration,
                                PluginViewInfo(
                                    viewID: "board",
                                    instanceID: instanceID,
                                    instanced: true,
                                    title: "Board \(instanceID)",
                                    items: [],
                                    body: nil
                                ),
                            ]
                        )
                    }
                ),
            ]
        )
        let (runtime, snapshots) = try await Self.startedRuntime(program: program)

        try await runtime.openViewInstance(viewID: "board", instanceID: "A")
        let published = try await snapshots.snapshot(
            where: { snapshot in
                snapshot.views.contains { $0.viewID == "board" && $0.instanceID == "A" }
            }
        )
        XCTAssertEqual(published.openViewInstances.count, 1)

        try await runtime.closeViewInstance(viewID: "board", instanceID: "A")
        let pruned = try await snapshots.snapshot(
            where: { snapshot in
                snapshot.openViewInstances.isEmpty
                    && !snapshot.views.contains { $0.instanceID == "A" }
            }
        )
        XCTAssertTrue(
            pruned.views.contains { $0.viewID == "board" && $0.instanceID == nil },
            "closing one instance prunes that instance's body, never the registration"
        )
        _ = await runtime.shutdown(timeout: 2)
    }

    func testViewCallbacksShareOneOrderedPumpWithEvents() async throws {
        let recorder = CallbackRecorder()
        let program = Self.makeProgram(
            subscribedEvents: ["tick"],
            receiveEvent: { _, payload, _ in
                await recorder.record("event:\(Self.describe(payload))")
                return nil
            },
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    select: { select, _ in
                        await recorder.record("select:\(select.itemID)")
                        return nil
                    }
                ),
            ]
        )
        let (runtime, _) = try await Self.startedRuntime(program: program)

        XCTAssertTrue(runtime.acceptEvent(event: "tick", payload: .string("1")))
        _ = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: nil,
            itemID: "card",
            value: nil
        )
        XCTAssertTrue(runtime.acceptEvent(event: "tick", payload: .string("2")))

        try await recorder.wait(for: ["event:1", "select:card", "event:2"])
        _ = await runtime.shutdown(timeout: 2)
    }

    func testThrowingViewCallbackFailsTheGenerationNotTheHost() async throws {
        let program = Self.makeProgram(
            viewCallbacks: [
                "board": BundledPluginViewCallbacks(
                    select: { _, _ in
                        throw PluginRuntimeError.javascriptException("boom")
                    }
                ),
            ]
        )
        let (runtime, snapshots) = try await Self.startedRuntime(program: program)

        let handled = try await runtime.invokeViewSelect(
            viewID: "board",
            instanceID: nil,
            itemID: "card",
            value: nil
        )
        XCTAssertTrue(handled, "presence is answered before the handler runs")
        let failed = try await snapshots.snapshot(where: { $0.phase == .failed })
        XCTAssertEqual(failed.statusBarText, nil)
        _ = await runtime.shutdown(timeout: 2)
    }

    // MARK: - Fixtures

    private static let boardRegistration = PluginViewInfo(
        viewID: "board",
        instanceID: nil,
        instanced: true,
        title: "Board",
        items: [],
        body: nil
    )

    private static let plainRegistration = PluginViewInfo(
        viewID: "plain",
        instanceID: nil,
        instanced: false,
        title: "Plain",
        items: [],
        body: nil
    )

    private static func makeProgram(
        subscribedEvents: Set<String> = [],
        activate: @escaping BundledPluginProgram.Activate = { _ in .empty },
        receiveEvent: @escaping BundledPluginProgram.ReceiveEvent = { _, _, _ in nil },
        viewCallbacks: [String: BundledPluginViewCallbacks]
    ) -> BundledPluginProgram {
        BundledPluginProgram(
            id: "dev.example.view-routing",
            subscribedEvents: subscribedEvents,
            providedIntents: [],
            viewCallbacks: viewCallbacks,
            activate: activate,
            receiveEvent: receiveEvent,
            invokeIntent: { envelope, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
    }

    private static func startedRuntime(
        program: BundledPluginProgram
    ) async throws -> (BundledPluginRuntimeActor, SnapshotRecorder) {
        let manifest = try PluginManifest(
            id: program.id,
            name: "view-routing",
            version: "1.0.0",
            runtime: .bundledSwift
        )
        let snapshots = SnapshotRecorder()
        let runtime = BundledPluginRuntimeActor(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: FileManager.default.temporaryDirectory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in
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
                    },
                    list: { .array([]) }
                ),
                onStateChange: { snapshot in
                    await snapshots.record(snapshot)
                }
            ),
            program: program
        )
        _ = try await runtime.start()
        return (runtime, snapshots)
    }

    private static func describe(_ value: IntentValue?) -> String {
        guard let value else { return "nil" }
        if case let .string(text) = value { return text }
        return "\(value)"
    }
}

private actor CallbackRecorder {
    private var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }

    func wait(for expected: [String]) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if entries == expected { return }
            if entries.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(entries, expected)
    }
}

private actor SnapshotRecorder {
    private var snapshots: [PluginRuntimeSnapshot] = []

    func record(_ snapshot: PluginRuntimeSnapshot) {
        snapshots.append(snapshot)
    }

    func snapshot(
        where predicate: @Sendable (PluginRuntimeSnapshot) -> Bool
    ) async throws -> PluginRuntimeSnapshot {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let match = snapshots.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ViewRoutingTestError.timedOut
    }
}

private enum ViewRoutingTestError: Error {
    case timedOut
}
