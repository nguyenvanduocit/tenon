import Foundation
import XCTest

final class PaneRenameArchitectureFitnessTests: XCTestCase {
    func testPaneRenameKeepsOneTypedMutationAndOneIDOnlyEvent() throws {
        let model = try source("TenonCore/Workspace.swift")
        let store = try source("TenonCore/WorkspaceStore.swift")
        let intents = try source("TenonCore/CoreIntentName.swift")

        XCTAssertTrue(model.contains("public mutating func renameSlot("))
        XCTAssertTrue(store.contains("apply { $0.renameSlot(id, to: typed) }"))
        XCTAssertTrue(store.contains("\"workspace.slot-identity-changed\""))
        XCTAssertFalse(
            store.contains("\"title\": .string"),
            "the public fact may identify the changed pane but must not publish its title"
        )
        XCTAssertFalse(
            intents.contains("workspace.pane.rename"),
            "host pane chrome is DIRECT and must not mint a public rename intent"
        )
    }

    func testAIRenameOwnsBoundedProcessCancellationAtCatalogLifetime() throws {
        let generator = try source("TenonApp/CompanionPaneTitleGenerator.swift")
        let structured = try source("TenonApp/CompanionStructuredOutputRunner.swift")
        let runner = try source("TenonApp/CompanionProcessRunner.swift")
        let boundedProcess = try source("TenonCore/BoundedProcessRunner.swift")
        let processIntent = try source("TenonCore/ProcessIntentProvider.swift")
        let coordinator = try source("TenonApp/PaneRenameCoordinator.swift")
        let composition = try source("TenonApp/TenonApp.swift")
        let preferences = try source("TenonCore/CompanionProfile.swift")
        let settings = try source("TenonApp/SettingsView.swift")
        let law = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "docs/architecture-interaction-boundaries.md"
            ),
            encoding: .utf8
        )

        for token in [
            "\"-p\"",
            "\"--output-format\", \"json\"",
            "\"--json-schema\"",
            "\"--tools\", \"\"",
            "\"--json\"",
            "\"--output-schema\"",
            "item.completed",
            "agent_message",
        ] {
            XCTAssertTrue(structured.contains(token), "missing Companion invariant: \(token)")
        }
        XCTAssertTrue(runner.contains("static let timeoutSeconds = 60"))
        XCTAssertTrue(runner.contains("BoundedProcessRunner.run"))
        XCTAssertFalse(runner.contains("Process()"))
        XCTAssertFalse(runner.contains("waitUntilExit"))
        XCTAssertTrue(boundedProcess.contains("F_SETNOSIGPIPE"))
        XCTAssertTrue(boundedProcess.contains("POSIX_SPAWN_SETPGROUP"))
        XCTAssertTrue(boundedProcess.contains("SIGKILL"))
        XCTAssertTrue(processIntent.contains("BoundedProcessRunner.run"))
        XCTAssertTrue(generator.contains("structuredOutput.run"))
        XCTAssertFalse(
            generator.contains("switch profile.agent"),
            "pane-title tasks must not own provider selection or CLI response grammar"
        )
        XCTAssertTrue(structured.contains("let profile = await profile()"))
        XCTAssertTrue(structured.contains("AgentExecutableLocator.scanLive()"))
        XCTAssertFalse(structured.contains("AgentLaunchDetector.scanLive()"))
        XCTAssertTrue(preferences.contains("agent: AgentCLI = .claude"))
        XCTAssertTrue(preferences.contains("defaultModel(for agent: AgentCLI)"))
        XCTAssertTrue(settings.contains("case companion"))
        XCTAssertTrue(settings.contains("CompanionSettingsDetail(prefs: prefs)"))
        XCTAssertTrue(settings.contains("AgentExecutableLocator.scanLive()"))
        XCTAssertTrue(coordinator.contains("func retainOnly(_ liveSlotIDs: Set<UUID>)"))
        XCTAssertTrue(composition.contains("paneRenamer?.retainOnly(Set(snapshot.allSlotIDs))"))
        XCTAssertTrue(law.contains("pane-title synthesis: one host-private task"))
    }

    /// Renaming is pane state, and pane state is reported by the pane. Nothing about a rename
    /// may be presented over the shell — not the generation, not its failure, not the field
    /// the name is typed into.
    func testRenamingIsReportedByThePaneAndNeverPresentedOverTheShell() throws {
        let coordinator = try source("TenonApp/PaneRenameCoordinator.swift")
        let card = try source("TenonApp/Canvas/SpatialSlotCardView.swift")
        let stage = try source("TenonApp/WorkspaceStageView.swift")
        let shell = try source("TenonApp/ContentView.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: packageRoot
                    .appendingPathComponent("Sources/TenonApp/PaneRenameOverlay.swift").path
            ),
            "the rename modal was replaced, not kept beside its replacement"
        )
        for source in [shell, stage, card, coordinator] {
            XCTAssertFalse(source.contains("PaneRenameOverlay"))
        }
        // State per pane, not one presentation for the window: two panes can name themselves
        // at once and neither can steal the other's.
        XCTAssertTrue(coordinator.contains("private(set) var phases: [UUID: PaneRenamePhase]"))
        XCTAssertFalse(coordinator.contains("var presentation"))
        // The stage reads the phases in a SwiftUI body — the only place a read invalidates
        // the AppKit canvas underneath it.
        XCTAssertTrue(stage.contains("let paneRenameValues = paneRenamer.phases"))
        XCTAssertTrue(stage.contains("paneRenames: paneRenameValues"))
        // What the title says in each phase is a pure value the card only paints.
        XCTAssertTrue(card.contains("PaneRenameChrome.make("))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
