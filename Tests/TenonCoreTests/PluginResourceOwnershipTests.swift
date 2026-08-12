import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// T-140: a resource that names its owner dies with that owner.
///
/// Closing a workspace closes every pane it had, and closing a pane closes the view instances on
/// it — so this is the layer where "closing a workspace kills what it owned" is actually decided
/// for plugin-held resources. The rule under test is deliberately narrow: the host keeps the
/// promise whether or not the plugin remembers to, and keeps its hands off resources that never
/// claimed an owner.
final class PluginResourceOwnershipTests: XCTestCase {
    /// The case the feature exists for. This plugin registers no `onClose` at all — the shipped
    /// kanban plugin does, by hand, and `testClosingThePaneReleasesItsWatcherAndTimer` pins that
    /// it works. A plugin author who forgets leaks a repeating timer for the life of the app.
    func testAForgetfulPluginsTimerStillDiesWithItsPane() async throws {
        let runtime = try makeRuntime(
            source: """
            var ticks = 0;
            tenon.views.register("board", { title: "Board", instanced: true });
            tenon.views.onOpen("board", function (instanceID) {
              tenon.timers.every(10, function () {
                ticks += 1;
                tenon.statusBar.set("ticks:" + ticks);
              }, { ownedBy: instanceID });
            });
            """
        )
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: "pane-a")

        let started = await eventually {
            await runtime.snapshot().statusBarText?.hasPrefix("ticks:") == true
        }
        XCTAssertTrue(started, "the timer must be running before its death means anything")

        try await runtime.closeViewInstance(viewID: "board", instanceID: "pane-a")
        let atClose = await runtime.snapshot().statusBarText

        try await Task.sleep(for: .milliseconds(120))
        let afterClose = await runtime.snapshot().statusBarText
        XCTAssertEqual(
            afterClose,
            atClose,
            "a timer owned by a closed pane fired again — the host did not retire it"
        )
        _ = await runtime.shutdown()
    }

    /// The other half, and the one that makes this safe to ship: a resource that claims no owner
    /// keeps exactly the lifetime it had before `ownedBy` existed. Every plugin written until now
    /// is in this case, so getting it wrong would silently break all of them.
    func testAResourceThatClaimsNoOwnerSurvivesAPaneClosing() async throws {
        let runtime = try makeRuntime(
            source: """
            var ticks = 0;
            tenon.views.register("board", { title: "Board", instanced: true });
            tenon.timers.every(10, function () {
              ticks += 1;
              tenon.statusBar.set("ticks:" + ticks);
            });
            tenon.views.onOpen("board", function () {});
            """
        )
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: "pane-a")
        _ = await eventually {
            await runtime.snapshot().statusBarText?.hasPrefix("ticks:") == true
        }

        try await runtime.closeViewInstance(viewID: "board", instanceID: "pane-a")
        let atClose = await runtime.snapshot().statusBarText

        let keptGoing = await eventually {
            await runtime.snapshot().statusBarText != atClose
        }
        XCTAssertTrue(
            keptGoing,
            "an unowned timer belongs to the plugin generation and a pane closing is not its death"
        )
        _ = await runtime.shutdown()
    }

    /// One pane closing must not reach into another's work. This is the bug the naive version of
    /// this feature ships: sweeping by plugin instead of by owner kills the panes still open.
    func testClosingOnePaneLeavesAnotherPanesTimerRunning() async throws {
        let runtime = try makeRuntime(
            source: """
            var ticks = {};
            tenon.views.register("board", { title: "Board", instanced: true });
            tenon.views.onOpen("board", function (instanceID) {
              ticks[instanceID] = 0;
              tenon.timers.every(10, function () {
                ticks[instanceID] += 1;
                tenon.statusBar.set(instanceID + ":" + ticks[instanceID]);
              }, { ownedBy: instanceID });
            });
            """
        )
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "board", instanceID: "pane-a")
        try await runtime.openViewInstance(viewID: "board", instanceID: "pane-b")
        _ = await eventually {
            await runtime.snapshot().statusBarText?.hasPrefix("pane-b:") == true
        }

        try await runtime.closeViewInstance(viewID: "board", instanceID: "pane-a")

        let bStillTicking = await eventually {
            await runtime.snapshot().statusBarText?.hasPrefix("pane-b:") == true
        }
        XCTAssertTrue(bStillTicking, "pane-b's timer is not pane-a's to cancel")
        _ = await runtime.shutdown()
    }

    // MARK: - Fixture

    private func makeRuntime(source: String) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = try PluginManifest(
            id: "dev.tenon.ownership-tests",
            name: "ownership-tests",
            version: "1",
            permissions: []
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: manifest,
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                )
            )
        )
    }

    private static func unavailable() -> IntentResult {
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

    private func eventually(
        within: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
