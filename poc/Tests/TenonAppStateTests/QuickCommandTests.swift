import Foundation
import TenonCore
import XCTest
@testable import TenonApp

final class QuickCommandTests: XCTestCase {
    private var defaults: UserDefaults!
    private var storageKey: String!

    override func setUp() async throws {
        try await super.setUp()
        storageKey = "quick-command-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: storageKey)
        defaults.removePersistentDomain(forName: storageKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: storageKey)
        defaults = nil
        storageKey = nil
        try await super.tearDown()
    }

    @MainActor
    func testStorePersistsCommandsAndRecentSelection() {
        let command = QuickCommand(
            label: "Code Review",
            runner: .claude,
            body: "Review the branch and cite evidence",
            destination: .newTab,
            scope: .project(path: "/tmp/tenon")
        )
        let first = QuickCommandStore(defaults: defaults, storageKey: storageKey)
        first.upsert(command)
        first.recordRun(command.id)

        let restored = QuickCommandStore(defaults: defaults, storageKey: storageKey)

        XCTAssertEqual(restored.commands, [command])
        XCTAssertEqual(restored.recentCommandID, command.id)
    }

    @MainActor
    func testLegacyActionAndAgentFieldsMigrateIntoOneRunner() throws {
        let id = UUID()
        let json = """
        {
          "commands": [{
            "id": "\(id.uuidString)",
            "label": "Review",
            "action": "agentPrompt",
            "body": "Review the branch",
            "agent": "claude",
            "appendEnter": true,
            "scope": { "type": "global" }
          }],
          "recentCommandID": null
        }
        """
        defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: storageKey)

        let restored = QuickCommandStore(defaults: defaults, storageKey: storageKey)
        let command = try XCTUnwrap(restored.commands.first)

        XCTAssertEqual(command.runner, .claude)
        XCTAssertEqual(command.destination, .newTab)
    }

    @MainActor
    func testProjectCommandsAreVisibleOnlyInTheirWorkspaceAndRankFirstWithoutAQuery() {
        let projectPath = "/tmp/tenon-quick-project"
        let store = QuickCommandStore(defaults: defaults, storageKey: storageKey)
        store.upsert(QuickCommand(label: "Build Global", body: "swift build"))
        store.upsert(QuickCommand(
            label: "Build Project",
            body: "swift build",
            scope: .project(path: projectPath)
        ))

        XCTAssertEqual(
            store.ranked(query: "", projectPath: projectPath).map(\.label),
            ["Build Project", "Build Global"]
        )
        XCTAssertEqual(
            store.visible(projectPath: projectPath).count,
            2
        )
        XCTAssertEqual(
            store.visible(projectPath: "/tmp/another-project").map(\.label),
            ["Build Global"]
        )
    }

    @MainActor
    func testTerminalCommandReusesFocusedTerminalAndHonorsAppendEnter() throws {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .terminal)
        )
        let paneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }
        let surface = try XCTUnwrap(
            terminalPool.surface(for: paneID, workspacePath: root)
                as? StubTerminalSurface
        )

        XCTAssertTrue(QuickCommandExecutor.run(
            QuickCommand(label: "Insert", body: "git status", appendEnter: false),
            workspaceStore: workspaceStore,
            terminalPool: terminalPool
        ))
        XCTAssertEqual(surface.sentText, ["git status"])

        XCTAssertTrue(QuickCommandExecutor.run(
            QuickCommand(label: "Run", body: "swift test"),
            workspaceStore: workspaceStore,
            terminalPool: terminalPool
        ))
        XCTAssertEqual(surface.sentText, ["git status", "swift test\n"])
        XCTAssertEqual(workspaceStore.catalog.activeWorkspace?.tabs.count, 1)
    }

    @MainActor
    func testTerminalRunbookCanDeliberatelyOpenAFreshTab() throws {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .terminal)
        )
        let originalPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }

        XCTAssertTrue(QuickCommandExecutor.run(
            QuickCommand(
                label: "Serve",
                body: "npm run dev",
                destination: .newTab
            ),
            workspaceStore: workspaceStore,
            terminalPool: terminalPool
        ))

        let createdPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        XCTAssertNotEqual(createdPaneID, originalPaneID)
        let surface = try XCTUnwrap(
            terminalPool.surface(for: createdPaneID, workspacePath: root)
                as? StubTerminalSurface
        )
        XCTAssertEqual(surface.sentText, ["npm run dev\n"])
        XCTAssertEqual(workspaceStore.catalog.activeWorkspace?.tabs.count, 2)
    }

    @MainActor
    func testAgentPromptCreatesFreshTerminalAndQuotesPromptAsOneArgument() throws {
        let root = FileManager.default.temporaryDirectory
        let workspaceStore = WorkspaceStore(
            catalog: WorkspaceCatalog(path: root, content: .terminal)
        )
        let originalPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        let terminalPool = SurfacePool(backendName: "Stub") { _, _ in
            StubTerminalSurface()
        }
        let prompt = "review $(touch /tmp/nope) and user's diff"

        XCTAssertTrue(QuickCommandExecutor.run(
            QuickCommand(
                label: "Review",
                runner: .codex,
                body: prompt,
                destination: .focusedTerminal
            ),
            workspaceStore: workspaceStore,
            terminalPool: terminalPool
        ))

        let createdPaneID = try XCTUnwrap(workspaceStore.catalog.activeSlotID)
        XCTAssertNotEqual(createdPaneID, originalPaneID)
        let surface = try XCTUnwrap(
            terminalPool.surface(for: createdPaneID, workspacePath: root)
                as? StubTerminalSurface
        )
        XCTAssertEqual(
            surface.sentText,
            ["codex \(AutomationAuthoring.posixQuoted(prompt))\n"]
        )
        XCTAssertEqual(
            terminalPool.paneDirectory(for: createdPaneID)?.cwd.standardizedFileURL,
            root.standardizedFileURL
        )
    }

    @MainActor
    func testAgentRunbookAlwaysNormalizesToAFreshTab() {
        let command = QuickCommand(
            label: "Review",
            runner: .codex,
            body: "Review this project",
            destination: .focusedTerminal
        )

        XCTAssertEqual(command.normalized.destination, .newTab)
    }

    func testRunbookPresentationStaysWithinTenonDesktopDensity() {
        XCTAssertLessThanOrEqual(RunbookMetrics.libraryWidth, 320)
        XCTAssertLessThanOrEqual(RunbookMetrics.editorWidth, 520)
        XCTAssertLessThanOrEqual(RunbookMetrics.editorHeight, 520)
        XCTAssertEqual(RunbookMetrics.controlHeight, 30)
        XCTAssertEqual(RunbookMetrics.cornerRadius, 6)
        XCTAssertEqual(RunbookMetrics.libraryListHeight(rows: 1), 48)
        XCTAssertEqual(RunbookMetrics.libraryListHeight(rows: 100), 280)
    }
}
