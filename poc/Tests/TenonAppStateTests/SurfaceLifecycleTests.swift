import Foundation
import TenonCore
import XCTest
@testable import TenonApp

/// T-031: a pane nobody opened costs nothing. A surface — and with it the PTY and the
/// renderer buffers — exists only once a pane has actually been displayed on the visible
/// canvas; the render path's `surface(for:workspacePath:)` call is that signal. The
/// asymmetry under test: lazy to materialize, never torn down to save memory — a viewed
/// pane's surface dies exactly when its slot leaves the catalog, and nothing else kills it.
@MainActor
final class SurfaceLifecycleTests: XCTestCase {
    private var scratch: URL!
    private var slot: UUID!
    /// Every `(slotID, workingDirectory)` the pool asked the backend to build. Count 0
    /// is the literal "no surface, no PTY" claim; the directory is the spawn assertion.
    private var built: [(slotID: UUID, directory: URL)] = []

    override func setUp() async throws {
        try await super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-surface-life-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        slot = UUID()
        built = []
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    // MARK: - Lazy: nothing materializes without a view

    func testAPaneNobodyViewedBuildsNoSurfaceAndNoReadPathMaterializesOne() {
        let pool = makePool()

        XCTAssertFalse(pool.hasEverBeenViewed(slot))

        // Every path a background pane can be hit with while nobody is looking at it.
        // None of them may build: reads answer with their empty defaults, writes queue
        // or drop, and only an actual view spends the resources.
        pool.sendText("x", to: slot)
        pool.sendTextWhenReady("queued", to: slot)
        pool.focusSurface(for: slot)
        XCTAssertEqual(pool.renderedText(for: slot), "")
        XCTAssertFalse(pool.processExited(for: slot))
        XCTAssertEqual(pool.commandFinishedCount(for: slot), 0)
        XCTAssertNil(pool.terminalObservation(for: slot))
        pool.retainOnly([slot])

        XCTAssertFalse(pool.hasEverBeenViewed(slot))
        XCTAssertEqual(built.count, 0, "no surface and no PTY for a pane nobody displayed")
    }

    func testFirstViewMaterializesTheSurfaceWithoutLosingQueuedText() {
        let pool = makePool()
        pool.sendTextWhenReady("claude --resume abc\n", to: slot)
        XCTAssertFalse(pool.hasEverBeenViewed(slot), "queued text must not materialize")

        let surface = pool.surface(for: slot, workspacePath: scratch)

        XCTAssertTrue(pool.hasEverBeenViewed(slot))
        XCTAssertEqual(built.count, 1)
        pool.sendText("ls\n", to: slot)
        XCTAssertEqual(
            (surface as? StubTerminalSurface)?.sentText,
            ["claude --resume abc\n", "ls\n"],
            "the first frame must not lose text aimed at the pane before it was viewed"
        )
    }

    // MARK: - Never torn down for memory: the assertions that protect a running agent

    func testSwitchingTabsWorkspacesOrFocusNeverTearsDownAViewedSurface() {
        let pool = makePool()
        let other = UUID()
        let agentSurface = pool.surface(for: slot, workspacePath: scratch)
        _ = pool.surface(for: other, workspacePath: scratch)

        // Everything a tab switch, a workspace switch, or a focus move does to the
        // pool: the lifecycle sync re-asserts the same catalog (TenonApp.swift wires
        // exactly `retainOnly(allSlotIDs)` on every mutation) and focus goes elsewhere.
        // The pane itself is now hidden — and its shell must not notice.
        pool.retainOnly([slot, other])
        pool.focusSurface(for: other)
        pool.retainOnly([slot, other])
        pool.retainOnly([slot, other])

        XCTAssertTrue(pool.hasEverBeenViewed(slot), "the viewed latch never resets while the slot lives")
        XCTAssertTrue(
            agentSurface === pool.surface(for: slot, workspacePath: scratch),
            "the identical live surface, not a rebuilt one — a PTY is never torn down because the human looked away"
        )
        XCTAssertEqual(built.count, 2, "hiding a pane must not rebuild or replace anything")
    }

    func testASurfaceDiesExactlyWithItsSlotAndLeavesNoStrongReference() {
        let pool = makePool()
        weak var released: StubTerminalSurface?
        autoreleasepool {
            let surface = pool.surface(for: slot, workspacePath: scratch)
            released = surface as? StubTerminalSurface
        }
        XCTAssertNotNil(released, "the pool must keep a viewed pane's surface alive")

        pool.retainOnly([])

        XCTAssertFalse(pool.hasEverBeenViewed(slot), "the latch is bounded by the slot's lifetime")
        XCTAssertNil(pool.terminalObservation(for: slot))
        XCTAssertNil(
            released,
            "nothing may keep a strong reference to a closed slot's surface (invariant 10)"
        )
    }

    // MARK: - Restored panes: placeholder data now, a fresh shell on first view

    func testARestoredPaneShowsItsRecordedDirectoryAndSpawnsAFreshShellThere() throws {
        let recorded = try directory("repo/src")
        let pool = makePool()

        pool.seedRestoredDirectory(recorded, for: slot)

        XCTAssertFalse(pool.hasEverBeenViewed(slot), "seeding placeholder data is not viewing")
        XCTAssertEqual(
            pool.paneDirectory(for: slot)?.cwd,
            recorded,
            "the recorded cwd renders before any surface exists"
        )
        XCTAssertEqual(built.count, 0)

        _ = pool.surface(for: slot, workspacePath: scratch)

        XCTAssertEqual(
            built.first?.directory,
            recorded,
            "materializing spawns a FRESH shell in the recorded cwd — it does not resurrect the dead process or replay history"
        )
    }

    func testARelaunchRestoresManyPanesWithoutSpawningASingleShell() async throws {
        let root = scratch.appendingPathComponent("relaunch", isDirectory: true)
        let inventory = root.appendingPathComponent("inventory", isDirectory: true)
        let recordedCwd = root.appendingPathComponent("repo/deep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inventory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recordedCwd,
            withIntermediateDirectories: true
        )

        func makePaths() throws -> AppStatePaths {
            try AppStatePaths.resolve(
                environment: ["TENON_PLUGINS_DIR": inventory.path],
                applicationSupportDirectory: root.appendingPathComponent(
                    "Application Support",
                    isDirectory: true
                ),
                bundledPluginsRoot: nil
            )
        }

        // First session: a tree of terminal panes, one carrying a live title and cwd.
        let first = try AppComposition(paths: makePaths())
        let watchedSlotID = try XCTUnwrap(first.store.catalog.activeSlotID)
        first.store.setSlotContent(watchedSlotID, .terminal)
        first.store.newTab(content: .terminal)
        first.store.splitActiveSlot(.horizontal, content: .terminal)
        first.terminalSurfaces.setTitle("claude — building", for: watchedSlotID)
        first.terminalSurfaces.seedRestoredDirectory(recordedCwd, for: watchedSlotID)
        let slotsAtQuit = Set(first.store.catalog.allSlotIDs)
        XCTAssertEqual(slotsAtQuit.count, 3)
        await first.stop()

        // Relaunch: the whole tree comes back, and not one shell is spawned for it.
        let second = try AppComposition(paths: makePaths())
        addTeardownBlock { await second.stop() }

        XCTAssertEqual(Set(second.store.catalog.allSlotIDs), slotsAtQuit)
        for restoredSlotID in second.store.catalog.allSlotIDs {
            XCTAssertFalse(
                second.terminalSurfaces.hasEverBeenViewed(restoredSlotID),
                "a restored pane holds no surface and no PTY until the human opens it"
            )
        }
        XCTAssertEqual(
            second.terminalSurfaces.titles[watchedSlotID],
            "claude — building",
            "the recorded title is the restored pane's placeholder"
        )
        XCTAssertEqual(
            second.terminalSurfaces.paneDirectory(for: watchedSlotID)?.cwd,
            recordedCwd,
            "the recorded cwd is restored as placeholder data, before any surface exists"
        )
    }

    // MARK: - Helpers

    private func makePool() -> SurfacePool {
        SurfacePool(backendName: "Stub") { [weak self] slotID, directory in
            self?.built.append((slotID: slotID, directory: directory))
            return StubTerminalSurface()
        }
    }

    private func directory(_ relative: String) throws -> URL {
        let url = scratch.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
}
