import AppKit
import Foundation
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

/// T-176 (`CMD-FR-020`, `CMD-FR-021`): the two halves of an empty pane's search field that a
/// render cannot prove — that every row it draws resolves to something, and that a typed
/// command line reaches a shell in the pane the person was looking at.
@MainActor
final class EmptyPaneSearchTests: XCTestCase {
    private func suggestion(_ agent: AgentCLI) -> AgentLaunchSuggestion {
        AgentLaunchSuggestion(
            agent: agent,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: agent == .codex
                ? ["--dangerously-bypass-approvals-and-sandbox"]
                : ["--permission-mode", "bypassPermissions"]
        )
    }

    private var offerings: EmptyPaneOfferings {
        EmptyPaneOfferings(
            agents: [suggestion(.codex), suggestion(.claude)],
            recents: [.terminal, .changes, .file(path: "/tmp/judge.go"), .automation, .empty]
        )
    }

    // MARK: - No row is a dead end

    func testEveryRowTheRankerCanDrawResolvesToSomethingItCanDo() throws {
        let offerings = self.offerings
        let commands = offerings.commands
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            XCTAssertNotNil(
                offerings.pick(itemID: command.id),
                "\(command.id) draws, highlights, accepts Enter — and does nothing"
            )
        }
        XCTAssertEqual(
            Set(commands.map(\.id)).count,
            commands.count,
            "two rows sharing an id would make ↓/↑ land on one and Enter run the other"
        )
    }

    func testAPickResolvesToTheExactOfferingItsRowNamed() throws {
        let offerings = self.offerings
        XCTAssertEqual(offerings.pick(itemID: EmptyPaneOfferings.terminalID), .terminal)
        XCTAssertEqual(offerings.pick(itemID: "agent.codex"), .agent(suggestion(.codex)))
        XCTAssertEqual(offerings.pick(itemID: "view.1"), .content(.changes))
        XCTAssertEqual(
            offerings.pick(itemID: "recent.2"),
            .content(.file(path: "/tmp/judge.go")),
            "the recents the ranker sees are the recents the card draws, in that order"
        )
    }

    func testAnIdForSomethingThisPaneDoesNotOfferResolvesToNothing() {
        let bare = EmptyPaneOfferings(agents: [], recents: [])
        XCTAssertNil(bare.pick(itemID: "agent.codex"), "no agent was detected on this machine")
        XCTAssertNil(bare.pick(itemID: "recent.0"), "this workspace has opened nothing yet")
        XCTAssertNil(bare.pick(itemID: "view.99"))
        XCTAssertNil(bare.pick(itemID: "nonsense"))
    }

    func testTheCardOnlyOffersTheRecentsItWillDraw() {
        let five: [SlotContent] = [
            .terminal, .changes, .automation, .file(path: "/tmp/a.swift"), .file(path: "/tmp/b.swift"),
        ]
        let offerings = EmptyPaneOfferings(agents: [], recents: five)
        XCTAssertEqual(offerings.recents.count, 4)
        XCTAssertNil(offerings.pick(itemID: "recent.4"), "the fifth is never drawn, so never picked")
    }

    // MARK: - Typing a command line

    func testATypedCommandFillsTheExactEmptyPaneAndReachesItsShell() throws {
        let root = FileManager.default.temporaryDirectory
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: root, content: .empty))
        let emptyPaneID = try XCTUnwrap(store.catalog.activeSlotID)
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }

        XCTAssertEqual(
            TerminalCommandLaunch.run(
                commandLine: "npm run dev",
                placement: .emptySlot(emptyPaneID),
                workspaceStore: store,
                terminalPool: pool
            ),
            .ran
        )

        XCTAssertEqual(store.catalog.slot(id: emptyPaneID)?.content, .terminal)
        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.count,
            1,
            "the command fills the pane that was looked at; it does not open a tab elsewhere"
        )
        let surface = try XCTUnwrap(
            pool.surface(for: emptyPaneID, workspacePath: root) as? StubTerminalSurface
        )
        XCTAssertEqual(surface.sentText, ["npm run dev\n"], "with the Enter that runs it")
        XCTAssertEqual(
            pool.paneDirectory(for: emptyPaneID)?.cwd.standardizedFileURL,
            root.standardizedFileURL,
            "and in the workspace's own directory, not wherever the app was launched from"
        )
    }

    func testATypedCommandInAnEmptyTabAddsThePaneItRunsIn() throws {
        let root = FileManager.default.temporaryDirectory
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: root, content: .empty))
        let openingPaneID = try XCTUnwrap(store.catalog.activeSlotID)
        store.closeSlot(openingPaneID)
        XCTAssertEqual(store.catalog.activeTab?.slots.count, 0, "the tab is genuinely empty")
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }

        XCTAssertEqual(
            TerminalCommandLaunch.run(
                commandLine: "swift test",
                placement: .emptyTab,
                workspaceStore: store,
                terminalPool: pool
            ),
            .ran
        )

        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        XCTAssertEqual(store.catalog.slot(id: paneID)?.content, .terminal)
        let surface = try XCTUnwrap(
            pool.surface(for: paneID, workspacePath: root) as? StubTerminalSurface
        )
        XCTAssertEqual(surface.sentText, ["swift test\n"])
    }

    func testACommandForAPaneThatIsNoLongerEmptyChangesNothing() throws {
        let root = FileManager.default.temporaryDirectory
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: root, content: .terminal))
        let busyPaneID = try XCTUnwrap(store.catalog.activeSlotID)
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }

        XCTAssertEqual(
            TerminalCommandLaunch.run(
                commandLine: "rm -rf /",
                placement: .emptySlot(busyPaneID),
                workspaceStore: store,
                terminalPool: pool
            ),
            .targetUnavailable,
            "the pane filled itself between the keystroke and the Enter"
        )
        XCTAssertNil(
            (pool.surface(for: busyPaneID, workspacePath: root) as? StubTerminalSurface)?
                .sentText.first,
            "and nothing was typed into the shell that took its place"
        )
    }

    /// The whole chain, in the order a person performs it: type, rank, pick the row that
    /// leads, get the command line back. This is what the card does on Enter.
    func testTypingACommandLineAndPressingEnterCarriesTheExactStringTyped() throws {
        let rows = EmptyPaneLauncher.rows(
            query: "  ./scripts/internal/prune-build-cache.sh  ",
            items: offerings.commands
        )
        XCTAssertEqual(
            rows.first?.kind,
            .runCommand("./scripts/internal/prune-build-cache.sh")
        )
    }

    // MARK: - What the card draws

    private func height(typing query: String) -> CGFloat {
        let hosting = NSHostingView(
            rootView: EmptyStateCard(
                recents: [.terminal, .changes, .file(path: "/tmp/judge.go"), .automation],
                agentSuggestions: [suggestion(.codex), suggestion(.claude)],
                isActive: false,
                initialQuery: query,
                onLaunch: { _ in },
                onLaunchAgent: { _ in },
                onRunCommand: { _ in }
            )
            .preferredColorScheme(.dark)
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    func testAQueryReplacesTheGroupedLayoutInsteadOfAppearingBesideIt() {
        let grouped = height(typing: "")
        let filtered = height(typing: "ch")
        XCTAssertGreaterThan(grouped, 0, "the card drew nothing at all")
        XCTAssertLessThan(
            filtered,
            grouped,
            "two matches and a run offer must be shorter than the whole grouped layout"
        )
        XCTAssertLessThan(
            height(typing: "npm run dev"),
            filtered,
            "one row is shorter than three"
        )
    }

    // MARK: - "Open a view" tracks the real plugin catalog

    /// `EmptyPaneOfferings.views` is a hand-maintained list; `LauncherMenu`'s own "Open a
    /// view" section reads live off every plugin manifest's `fillsPane` declaration instead
    /// (`groupedPaneFillers`, `LauncherMenu.swift`). T-188 named this exact divergence a
    /// "second command registry" and left it unrewritten because closing it for real needs
    /// `SlotContent` to stop being a closed enum (T-149, `command-surfaces.prd.md` §3). Until
    /// then, this walks the real `plugins/` inventory so a new or removed `fillsPane` command
    /// fails this test the same day, instead of silently reappearing as the two popovers
    /// disagreeing again (T-191).
    func testOpenAViewOffersEveryFillsPaneCommandInTheRealPluginInventory() throws {
        // The SlotContent a fillsPane command resolves to has no derivable relationship to
        // its intent id — that is the exact gap T-149 exists to close — so this map is
        // hand-written, same as `EmptyPaneOfferings.views` itself.
        let expectedContent: [String: SlotContent] = [
            "dev.tenon.core-commands.changes.open.v1": .changes,
            "dev.tenon.core-commands.automation.open.v1": .automation,
            "dev.tenon.file-explorer.open.v1":
                .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree"),
            "dev.tenon.browser.open.v1":
                .pluginView(pluginID: "dev.tenon.browser", viewID: "browser"),
            "dev.tenon.claude-sessions.open.v1":
                .pluginView(pluginID: "dev.tenon.claude-sessions", viewID: "sessions"),
            "dev.tenon.kanban.open.v1":
                .pluginView(pluginID: "dev.tenon.kanban", viewID: "board"),
        ]
        // "New Terminal" is also `fillsPane`, but the card already offers it as its own CTA
        // (`EmptyPaneOfferings.terminalID`), not as an "Open a view" row.
        let terminalCommandID = "dev.tenon.core-commands.terminal.new.v1"

        let pluginsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins")

        var discovered: Set<String> = []
        for directory in PluginLoader.discover(in: pluginsRoot) {
            let manifest = try PluginLoader.loadManifest(at: directory)
            for provision in manifest.intents.provides
            where provision.palette?.launcher == true && provision.palette?.fillsPane == true {
                discovered.insert(provision.name.rawValue)
            }
        }
        discovered.remove(terminalCommandID)

        XCTAssertEqual(
            discovered,
            Set(expectedContent.keys),
            "a plugin shipped or dropped a fillsPane command without this test's map, and "
                + "EmptyPaneOfferings.views, following"
        )
        for (id, content) in expectedContent {
            XCTAssertTrue(
                EmptyPaneOfferings.views.contains { $0.content == content },
                "\(id) is fillsPane but EmptyPaneOfferings.views offers no \(content) row for it"
            )
        }
    }
}
