import Foundation
import SwiftUI
import TenonIntentCore
@testable import TenonApp
@testable import TenonCore
import XCTest

/// T-048 slice 2: the supervised fleet, composed end to end.
///
/// Slice 1 pinned `tenon.agents.run` against a scripted bridge — the right test for the
/// function's own rules, and one that cannot see the policy path, the real provider, or a
/// real workspace. This runs all of it: a real kernel, a real `PluginHost`, the real
/// `TerminalIntentProvider`, and a real `WorkspaceStore` in which panes genuinely appear.
/// Only the terminal surface is stubbed, because a PTY is the one thing a headless run
/// cannot have.
///
/// Writing it found three defects a stubbed bridge could not see: `terminal.read` was
/// ungrantable, opening a pane *with* its command raced the wait's baseline, and the
/// `terminalWait` lane's serial mailbox made a second concurrent wait impossible. This test
/// is what fails if any of them comes back.
@MainActor
final class AgentFleetIntegrationTests: XCTestCase {
    func testOneEventHandlerFansOutTwoSupervisedAgentsAndPublishesTheAggregate() async throws {
        let fixture = try makeFixture()
        defer { fixture.materialiser.cancel() }
        let host = fixture.host
        try await fixture.runtime.start()
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        // The single trigger. Everything after it is the plugin's own composition.
        await host.emit(
            event: "workspace.selected",
            payload: .object(["workspaceId": .string(UUID().uuidString)])
        )

        let published = await eventually {
            host.statusItems.contains { $0.text.hasPrefix("fleet:") }
        }
        XCTAssertTrue(
            published,
            "no aggregate was published; status: \(host.statusItems.map(\.text))"
        )
        let text = try XCTUnwrap(
            host.statusItems.first { $0.text.hasPrefix("fleet:") }?.text
        )
        XCTAssertTrue(
            text.contains("alpha=OK-ALPHA"),
            "first agent did not complete: \(text)"
        )
        XCTAssertTrue(
            text.contains("beta=OK-BETA"),
            "second agent did not complete — concurrent supervision is broken again: \(text)"
        )

        // Two panes really appeared, and each run's command really reached its own.
        let sent = fixture.registry.allSentText()
        XCTAssertEqual(sent.count, 2, "expected one pane per agent, got \(sent)")
        XCTAssertFalse(
            sent.contains { $0.contains("alpha") && $0.contains("beta") },
            "both commands landed in one pane — the runs were not scoped separately"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
        let runtime: AppIntentRuntime
        let registry: FleetSurfaceRegistry
        let materialiser: Task<Void, Never>
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t048-fleet-\(UUID().uuidString)", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let pluginDirectory = plugins.appendingPathComponent("fleet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Self.manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try Self.mainJS.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceStore()
        let registry = FleetSurfaceRegistry()
        let pool = SurfacePool(backendName: "Fleet") { slotID, _ in
            registry.surface(for: slotID)
        }
        let userInterface = PluginUIState()
        let runtime = try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: PluginWebSurfacePool(),
            userInterface: userInterface
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )

        // Stands in for the render path, and nothing else. In the app a pane materialises
        // the moment the canvas draws it; headless, nothing draws, so a pane would never
        // gain a surface and the wait would poll forever. This is the only non-production
        // wiring here, and it does exactly what the shell does.
        let workspacePath = store.catalog.activeWorkspace?.path
            ?? FileManager.default.temporaryDirectory
        let materialiser = Task { @MainActor in
            while !Task.isCancelled {
                for workspace in store.catalog.workspaces {
                    for tab in workspace.tabs {
                        for slot in tab.slots where slot.content == .terminal {
                            _ = pool.surface(for: slot.id, workspacePath: workspacePath)
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        return Fixture(
            host: host,
            runtime: runtime,
            registry: registry,
            materialiser: materialiser
        )
    }

    /// T-074: waits until a deadline, not for a fixed number of turns.
    ///
    /// The attempt count this replaces read as eight seconds and was not: it is 1600 turns
    /// of "check, then sleep 5 ms", and how much wall time that buys depends entirely on how
    /// fast the turns run. On a busy machine the fleet needs longer than the loop lasts, and
    /// the test failed at 7.0 s against 0.95 s on a quiet one — a wait bound, not a
    /// disagreement about behaviour.
    ///
    /// The deadline is deliberately far past any real run. It is not a tolerance for slowness:
    /// a passing run returns the moment the fact appears and never spends it. Its only job is
    /// to fail a genuinely hung test instead of hanging the suite behind it.
    private func eventually(
        within timeout: Duration = .seconds(60),
        operation: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await operation()
    }

    private static let manifest = """
    {
      "id": "dev.tenon.test.fleet",
      "name": "fleet",
      "version": "1",
      "permissions": ["terminal.write", "terminal.read"],
      "intents": {
        "uses": [
          "terminal.open.v1",
          "terminal.write.v1",
          "terminal.wait.v1",
          "terminal.scrollback.read.v1"
        ],
        "provides": []
      }
    }
    """

    /// Written the way an automation author would write it: one handler, `Promise.all` over
    /// `tenon.agents.run`, one status line. If the platform did not compose, this could not
    /// be this short.
    private static let mainJS = """
    tenon.events.on("workspace.selected", async function () {
      var runs = await Promise.all([
        // 60s, not 6s. The regression this test guards is UNBOUNDED BLOCKING, not
        // slowness: when the wait lane was serial, beta's wait queued behind alpha's and
        // then snapshotted a baseline that already counted beta's own finish, so it waited
        // for a second finish that never comes — it fails at any timeout whatsoever. A
        // generous budget therefore costs the test nothing, while a tight one made it fail
        // on a loaded machine, which is precisely the machine that runs agent fleets.
        // Measured 2026-08-07: green in ~2s in isolation, red at 6s inside a full suite
        // under load average 22. A falsification criterion that is itself flaky falsifies
        // nothing.
        tenon.agents.run({ command: "echo", arguments: ["alpha"], timeoutMs: 60000 }),
        tenon.agents.run({ command: "echo", arguments: ["beta"], timeoutMs: 60000 })
      ]);
      var parts = [];
      for (var i = 0; i < runs.length; i++) {
        var run = runs[i];
        var name = i === 0 ? "alpha" : "beta";
        if (!run.ok) {
          parts.push(name + "=ERR:" + run.error.code);
          continue;
        }
        var line = (run.value.transcript || "").split("\\n").filter(function (row) {
          return row.indexOf("OK-") === 0;
        })[0] || "EMPTY";
        parts.push(name + "=" + line);
      }
      tenon.statusBar.set("fleet: " + parts.join(" "));
    });
    """
}

/// One controllable surface per pane. A run is only supervised if the host can tell the
/// panes apart, so these must never be shared.
@MainActor
private final class FleetSurfaceRegistry {
    private var bySlot: [UUID: FleetStubSurface] = [:]

    func surface(for slotID: UUID) -> FleetStubSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = FleetStubSurface()
        bySlot[slotID] = created
        return created
    }

    func allSentText() -> [String] {
        bySlot.values.map(\.sentText).filter { !$0.isEmpty }
    }
}

/// A pane that behaves like a shell which ran one command and finished: it records what it
/// was told to run, derives a transcript from it, and reports the OSC 133 finish that
/// `terminal.wait.v1 --for command-finished` watches for.
@MainActor
private final class FleetStubSurface: TerminalSurface {
    let backendName = "Fleet"
    var onTitleChange: ((String) -> Void)?
    private(set) var sentText = ""
    private(set) var commandFinishedCount = 0
    var processExited = false

    private var transcript: [String] = []

    var renderedText: String { transcript.joined(separator: "\n") }
    var scrollbackLines: [String] { transcript }

    func makeView() -> AnyView { AnyView(EmptyView()) }

    func sendText(_ text: String) {
        sentText += text
        let name = text.contains("alpha") ? "ALPHA" : "BETA"
        transcript = [
            "$ " + text.trimmingCharacters(in: .newlines),
            "OK-" + name,
        ]
        commandFinishedCount += 1
    }
}
