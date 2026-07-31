import Foundation
import SwiftUI
import TenonIntentCore
@testable import TenonApp
@testable import TenonCore
import XCTest

/// T-048: the shipped fleet-review example, loaded as a real plugin and actually run.
///
/// An example nobody executes rots — T-043 found four such files that had not compiled for
/// months. So `examples/fleet-review` is loaded here from disk, by the real `PluginHost`,
/// behind the real kernel and the real `TerminalIntentProvider`, and its palette command is
/// invoked for real. Only the terminal surface is stubbed, so no agent CLI has to exist.
@MainActor
final class FleetReviewExampleTests: XCTestCase {
    private static var exampleRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples")
    }

    /// Three reviewers, three panes, one verdict — the story the example claims to tell.
    func testThePaletteCommandRunsEveryReviewerInItsOwnPaneAndAggregates() async throws {
        let fixture = try makeFixture()
        defer { fixture.materialiser.cancel() }
        let host = fixture.host
        try await fixture.runtime.start()
        try await host.loadAll()
        addTeardownBlock { await host.shutdown() }

        let pluginID = PluginID("dev.tenon.examples.fleet-review")
        let intentID = try IntentID("dev.tenon.examples.fleet-review.run.v1")
        let result = await fixture.runtime.send(
            intentID,
            as: AppIntentRuntime.palettePrincipal,
            target: try ProviderID(pluginID.rawValue),
            userGestureID: UUID()
        )
        guard case .success = result else {
            return XCTFail("the palette command failed: \(result)")
        }

        let published = await eventually(attempts: 1600) {
            host.statusItems.contains {
                $0.text.hasPrefix("review:") && $0.text.contains("tests=")
            }
        }
        XCTAssertTrue(
            published,
            "no verdict was published; status: \(host.statusItems.map(\.text))"
        )
        let verdict = try XCTUnwrap(
            host.statusItems.first { $0.text.hasPrefix("review:") }?.text
        )
        for reviewer in ["correctness", "security", "tests"] {
            XCTAssertTrue(
                verdict.contains("\(reviewer)="),
                "\(reviewer) is missing from the verdict: \(verdict)"
            )
        }
        XCTAssertFalse(
            verdict.contains("did not finish"),
            "a reviewer failed: \(verdict)"
        )

        // One pane per reviewer, each carrying its own prompt — the fan-out is real, not
        // three runs sharing a terminal.
        let sent = fixture.registry.allSentText()
        XCTAssertEqual(sent.count, 3, "expected one pane per reviewer, got \(sent.count)")
        for reviewer in ["correctness", "security", "test coverage"] {
            XCTAssertTrue(
                sent.contains { $0.contains(reviewer) },
                "no pane received the \(reviewer) prompt"
            )
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let host: PluginHost
        let runtime: AppIntentRuntime
        let registry: ReviewSurfaceRegistry
        let materialiser: Task<Void, Never>
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-fleet-review-\(UUID().uuidString)", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: plugins,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // The real example directory, copied verbatim — if it stops loading, this fails.
        try FileManager.default.copyItem(
            at: Self.exampleRoot.appendingPathComponent("fleet-review", isDirectory: true),
            to: plugins.appendingPathComponent("fleet-review", isDirectory: true)
        )

        let store = WorkspaceStore()
        let registry = ReviewSurfaceRegistry()
        let pool = SurfacePool(backendName: "Review") { slotID, _ in
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

        // Stands in for the render path: headless, nothing draws, so a pane would never
        // gain a surface. See `AgentFleetIntegrationTests` for the same note.
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

    private func eventually(
        attempts: Int,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await operation()
    }
}

@MainActor
private final class ReviewSurfaceRegistry {
    private var bySlot: [UUID: ReviewStubSurface] = [:]

    func surface(for slotID: UUID) -> ReviewStubSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = ReviewStubSurface()
        bySlot[slotID] = created
        return created
    }

    func allSentText() -> [String] {
        bySlot.values.map(\.sentText).filter { !$0.isEmpty }
    }
}

/// A pane that answers like a `-p` run: it echoes the command, prints one conclusion line,
/// and reports the OSC 133 finish the supervised loop waits for.
@MainActor
private final class ReviewStubSurface: TerminalSurface {
    let backendName = "Review"
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
        let verdict: String
        if text.contains("correctness") {
            verdict = "no correctness issues found"
        } else if text.contains("security") {
            verdict = "no security issues found"
        } else {
            verdict = "coverage looks adequate"
        }
        transcript = [
            "$ " + text.trimmingCharacters(in: .newlines),
            verdict,
        ]
        commandFinishedCount += 1
    }
}
