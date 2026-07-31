import Foundation
import SwiftUI
import TenonIntentCore
@testable import TenonApp
@testable import TenonCore
import XCTest

/// T-048 slice 2, and the defect that slice found.
///
/// Slice 1 asserted `tenon.agents.run` against a stubbed intent bridge — the right test for
/// the function's own logic, and one that cannot see the policy path at all. Running the
/// same composition against the real kernel, a real `PluginHost` and the real
/// `TerminalIntentProvider` refused every terminal read with `missing-capability`:
/// `terminal.read` was a declared, validated, documented permission that
/// `PluginHost.capabilityGrants` deliberately filtered out, so the capability the three
/// read contracts name could never be granted to anybody.
///
/// The exclusion was correct once. `terminal.read` began life gating delivery of
/// `terminal.*` EVENTs, with no capability behind it. It stopped being correct when the
/// read intents bound it as their capability, and nothing noticed — because no test ran a
/// plugin's terminal read through the policy path. This is that test.
@MainActor
final class TerminalReadCapabilityTests: XCTestCase {
    /// A plugin that declares the permission and declares the use can actually read a
    /// pane. Everything here is production wiring except the terminal surface itself.
    func testAPluginDeclaringTerminalReadCanActuallyReadAPane() async throws {
        let fixture = try makeFixture()
        let host = fixture.host
        try await fixture.runtime.start()
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        // Give the plugin a pane with something in it, materialised the way the canvas
        // would materialise it.
        let paneID = try XCTUnwrap(fixture.store.catalog.activeSlotID)
        let surface = fixture.registry.surface(for: paneID)
        _ = fixture.pool.surface(
            for: paneID,
            workspacePath: FileManager.default.temporaryDirectory
        )
        surface.setTranscript(["$ echo hello", "OK-HELLO"])

        await host.emit(
            event: "workspace.selected",
            payload: .object(["paneId": .string(paneID.uuidString)])
        )

        let published = await eventually(attempts: 400) {
            host.statusItems.contains { $0.text.hasPrefix("read:") }
        }
        XCTAssertTrue(
            published,
            "the plugin never reported a read; status: \(host.statusItems.map(\.text))"
        )
        let text = try XCTUnwrap(
            host.statusItems.first { $0.text.hasPrefix("read:") }?.text
        )
        XCTAssertFalse(
            text.contains("denied"),
            "policy refused a plugin that declared both the permission and the use: \(text)"
        )
        XCTAssertTrue(
            text.contains("OK-HELLO"),
            "the read succeeded but returned the wrong pane's contents: \(text)"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
        let runtime: AppIntentRuntime
        let store: WorkspaceStore
        let pool: SurfacePool
        let registry: StubSurfaceRegistry
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t048-\(UUID().uuidString)", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let pluginDirectory = plugins.appendingPathComponent("reader", isDirectory: true)
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
        let registry = StubSurfaceRegistry()
        let pool = SurfacePool(backendName: "Stub") { slotID, _ in
            registry.surface(for: slotID)
        }
        let runtime = try AppIntentRuntime(
            stateRoot: stateRoot,
            workspaceStore: store,
            terminalSurfaces: pool,
            webSurfaces: PluginWebSurfacePool(),
            userInterface: PluginUIState()
        )
        let host = try PluginHost(
            pluginsRoot: plugins,
            stateRoot: stateRoot,
            kernel: runtime.kernel,
            authorization: .bundledInventory
        )
        return Fixture(
            host: host,
            runtime: runtime,
            store: store,
            pool: pool,
            registry: registry
        )
    }

    private func eventually(
        attempts: Int,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await operation()
    }

    private static let manifest = """
    {
      "id": "dev.tenon.test.reader",
      "name": "reader",
      "version": "1",
      "permissions": ["terminal.read"],
      "intents": {
        "uses": ["terminal.scrollback.read.v1"],
        "provides": []
      }
    }
    """

    private static let mainJS = """
    tenon.events.on("workspace.selected", async function (payload) {
      var result = await tenon.intents.send(
        "terminal.scrollback.read.v1",
        { maxLines: 50 },
        { scope: { paneID: payload.paneId } }
      );
      if (!result.ok) {
        tenon.statusBar.set("read: denied " + result.error.code);
        return;
      }
      tenon.statusBar.set("read: " + (result.value.text || "EMPTY"));
    });
    """
}

@MainActor
private final class StubSurfaceRegistry {
    private var bySlot: [UUID: StubReadSurface] = [:]

    func surface(for slotID: UUID) -> StubReadSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = StubReadSurface()
        bySlot[slotID] = created
        return created
    }
}

/// A pane whose contents the test decides. A PTY is the one thing a headless run cannot
/// have; everything else in this file is the production path.
@MainActor
private final class StubReadSurface: TerminalSurface {
    let backendName = "Stub"
    var onTitleChange: ((String) -> Void)?
    private(set) var commandFinishedCount = 0
    var processExited = false

    private var transcript: [String] = []

    var renderedText: String { transcript.joined(separator: "\n") }
    var scrollbackLines: [String] { transcript }

    func makeView() -> AnyView { AnyView(EmptyView()) }

    func sendText(_ text: String) {
        commandFinishedCount += 1
    }

    func setTranscript(_ lines: [String]) {
        transcript = lines
    }
}
