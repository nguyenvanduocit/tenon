import Foundation
import TenonCore
import XCTest
@testable import TenonApp

final class AgentLaunchSuggestionTests: XCTestCase {
    func testHistoryLearnsOnlyAllowlistedLaunchOptionsAndDropsPromptContent() {
        let history = """
        : 1786000000:0;codex -m gpt-5.4 --dangerously-bypass-approvals-and-sandbox "review $(touch /tmp/nope)"
        claude --model opus --permission-mode=bypassPermissions "fix the branch"
        """

        XCTAssertEqual(
            AgentLaunchHistory.preferredArguments(for: .codex, in: history),
            [],
            "a shell substitution makes the whole chained/expanded invocation ineligible"
        )
        XCTAssertEqual(
            AgentLaunchHistory.preferredArguments(for: .claude, in: history),
            ["--model", "opus", "--permission-mode", "bypassPermissions"]
        )
    }

    func testOldOneOffOptionIsNotMistakenForTheCurrentHabit() {
        let history = """
        codex --dangerously-bypass-approvals-and-sandbox
        codex
        """

        XCTAssertEqual(
            AgentLaunchHistory.preferredArguments(for: .codex, in: history),
            []
        )
    }

    func testRepeatedOptionRemainsAHabitAfterAPlainLaunch() {
        let history = """
        codex --full-auto
        codex --full-auto
        codex
        """

        XCTAssertEqual(
            AgentLaunchHistory.preferredArguments(for: .codex, in: history),
            ["--full-auto"]
        )
    }

    func testDetectorFindsInstalledAgentsAndReadsOnlyNormalizedArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-launch-detector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codex.path
        )
        let history = root.appendingPathComponent("history")
        try Data("codex --sandbox workspace-write --resume secret-session\n".utf8)
            .write(to: history)

        let suggestions = AgentLaunchDetector(
            environment: ["PATH": bin.path],
            homeDirectory: root,
            executableDirectories: [bin],
            historyFileURLs: [history]
        ).scan()

        XCTAssertEqual(suggestions.map(\.agent), [.codex])
        XCTAssertEqual(suggestions.first?.arguments, ["--sandbox", "workspace-write"])
        XCTAssertFalse(suggestions.first?.displayCommand.contains("secret-session") == true)
    }

    @MainActor
    func testExecutorOpensAFreshTerminalAndSendsTheLearnedInvocation() throws {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .terminal)
        )
        let originalPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }
        let suggestion = AgentLaunchSuggestion(
            agent: .codex,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--dangerously-bypass-approvals-and-sandbox"]
        )

        XCTAssertEqual(
            AgentLaunchExecutor.run(
                suggestion,
                placement: .newTab,
                workspaceStore: workspaceStore,
                terminalPool: terminalPool
            ),
            .ran
        )

        let createdPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        XCTAssertNotEqual(createdPaneID, originalPaneID)
        let surface = try XCTUnwrap(
            terminalPool.surface(for: createdPaneID, workspacePath: root)
                as? StubTerminalSurface
        )
        XCTAssertEqual(
            surface.sentText,
            ["'/usr/bin/true' '--dangerously-bypass-approvals-and-sandbox'\n"]
        )
        XCTAssertEqual(
            terminalPool.paneDirectory(for: createdPaneID)?.cwd.standardizedFileURL,
            root.standardizedFileURL
        )
    }

    @MainActor
    func testExecutorFillsTheExactEmptyPaneInsteadOfOpeningAnotherTab() throws {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .empty)
        )
        let emptyPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }
        let suggestion = AgentLaunchSuggestion(
            agent: .claude,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--permission-mode", "bypassPermissions"]
        )

        XCTAssertEqual(
            AgentLaunchExecutor.run(
                suggestion,
                placement: .emptySlot(emptyPaneID),
                workspaceStore: workspaceStore,
                terminalPool: terminalPool
            ),
            .ran
        )
        XCTAssertEqual(workspaceStore.catalog.activeSlotID, emptyPaneID)
        XCTAssertEqual(workspaceStore.catalog.slot(id: emptyPaneID)?.content, .terminal)
        XCTAssertEqual(workspaceStore.catalog.activeWorkspace?.tabs.count, 1)
    }

    @MainActor
    func testExecutorFailsBeforeMutatingWhenExecutableDisappeared() {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .terminal)
        )
        let originalTabIDs = workspaceStore.catalog.activeWorkspace?.tabs.map(\.id)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }

        XCTAssertEqual(
            AgentLaunchExecutor.run(
                AgentLaunchSuggestion(
                    agent: .codex,
                    executableURL: root.appendingPathComponent("missing-codex"),
                    arguments: []
                ),
                placement: .newTab,
                workspaceStore: workspaceStore,
                terminalPool: terminalPool
            ),
            .agentUnavailable
        )
        XCTAssertEqual(workspaceStore.catalog.activeWorkspace?.tabs.map(\.id), originalTabIDs)
    }
}
