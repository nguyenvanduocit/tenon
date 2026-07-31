import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-046 end to end: real `PluginHost`, real JavaScriptCore runtimes, real fixture JS.
/// The rules pinned here: the snapshot carries declared schedules, a firing reaches
/// ONLY the owning plugin, and a reload that changes a schedule reports through the
/// lifecycle channel the scheduler reconciles on.
@MainActor
final class AutomationEventDeliveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    func testSnapshotCarriesDeclaredSchedules() async throws {
        let fixture = try await makeFixture()

        let automated = try XCTUnwrap(
            fixture.host.plugins.first(where: { $0.id == "dev.test.auto-a" })
        )
        XCTAssertEqual(
            automated.automationSchedules,
            [try AutomationScheduleSpec(id: "tick", cadence: .every(60))]
        )
        let bystander = try XCTUnwrap(
            fixture.host.plugins.first(where: { $0.id == "dev.test.auto-b" })
        )
        XCTAssertEqual(bystander.automationSchedules, [])
    }

    func testFiringReachesOnlyTheOwningPlugin() async throws {
        let fixture = try await makeFixture()
        let host = fixture.host

        let bothWaiting = await eventually {
            statusText(host, "dev.test.auto-a") == "a-waiting"
                && statusText(host, "dev.test.auto-b") == "b:"
        }
        XCTAssertTrue(bothWaiting, "fixture plugins never reached their idle state")

        let scheduler = AutomationScheduler(calendar: .current)
        scheduler.reconcile(host.plugins, now: t0)
        let firings = scheduler.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(
            firings.map(\.pluginID),
            ["dev.test.auto-a"],
            "only the plugin that declared a schedule may fire"
        )

        for firing in firings {
            await host.automationFired(firing)
        }

        let fired = await eventually {
            statusText(host, "dev.test.auto-a")
                == "a-fired tick late=false trigger=scheduled"
        }
        XCTAssertTrue(
            fired,
            "the owning plugin's JS never observed automation.fired; status: "
                + (statusText(host, "dev.test.auto-a") ?? "nil")
        )
        // Absence needs a barrier: a probe emitted AFTER the firing rides the same
        // ordered per-runtime path, so once B reports the probe, a broadcast-delivered
        // firing would already be in its log ahead of it.
        await host.emit(event: "test.probe", payload: .object([:]))
        let probed = await eventually {
            statusText(host, "dev.test.auto-b")?.hasSuffix("probed") == true
        }
        XCTAssertTrue(probed, "the probe event never reached the bystander")
        XCTAssertEqual(
            statusText(host, "dev.test.auto-b"),
            "b:probed",
            "a bystander subscribed to automation.fired must never receive another plugin's firing"
        )
    }

    func testReloadThatChangesAScheduleReportsThroughTheLifecycleChannel() async throws {
        let fixture = try await makeFixture()
        let host = fixture.host

        var reported: [[PluginSnapshot]] = []
        host.onPluginLifecycleChanged = { reported.append($0) }

        try manifestJSON(every: "2m").write(
            to: fixture.autoADirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try await host.reload(directoryNamed: "auto-a")

        let latest = try XCTUnwrap(
            reported.last?.first(where: { $0.id == "dev.test.auto-a" }),
            "a reload that changes a schedule must report through onPluginLifecycleChanged"
        )
        XCTAssertEqual(
            latest.automationSchedules,
            [try AutomationScheduleSpec(id: "tick", cadence: .every(120))]
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
        let autoADirectory: URL
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-automation-\(UUID().uuidString)",
                isDirectory: true
            )
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
        let autoA = pluginsRoot.appendingPathComponent("auto-a", isDirectory: true)
        let autoB = pluginsRoot.appendingPathComponent("auto-b", isDirectory: true)
        try FileManager.default.createDirectory(
            at: autoA,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: autoB,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        try manifestJSON(every: "1m").write(
            to: autoA.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        tenon.statusBar.set("a-waiting");
        tenon.events.on("automation.fired", function (e) {
          tenon.statusBar.set(
            "a-fired " + e.scheduleId + " late=" + e.late + " trigger=" + e.trigger
          );
        });
        """.write(
            to: autoA.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        try """
        {
          "id": "dev.test.auto-b",
          "name": "auto-b",
          "version": "1",
          "intents": { "uses": [], "provides": [] }
        }
        """.write(
            to: autoB.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        var log = [];
        function render() { tenon.statusBar.set("b:" + log.join(",")); }
        render();
        tenon.events.on("automation.fired", function () {
          log.push("fired");
          render();
        });
        tenon.events.on("test.probe", function () {
          log.push("probed");
          render();
        });
        """.write(
            to: autoB.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: pluginsRoot,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory,
            invocationScopeProvider: { InvocationScope() }
        )
        try await host.loadAll()
        addTeardownBlock {
            await host.shutdown()
        }
        return Fixture(host: host, autoADirectory: autoA)
    }

    private func manifestJSON(every: String) -> String {
        """
        {
          "id": "dev.test.auto-a",
          "name": "auto-a",
          "version": "1",
          "intents": { "uses": [], "provides": [] },
          "automation": { "schedules": [ { "id": "tick", "every": "\(every)" } ] }
        }
        """
    }

    private func statusText(_ host: PluginHost, _ id: PluginID) -> String? {
        host.statusItems.first(where: { $0.pluginID == id })?.text
    }

    private func eventually(
        attempts: Int = 400,
        operation: @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
