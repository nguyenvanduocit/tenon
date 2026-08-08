import XCTest
@testable import TenonApp
import TenonCore

/// T-088. Creating a pane from the empty-space launcher used to leave the old and the new
/// pane trading focus without further input. The loop lived between two edges that are both
/// correct alone, so these tests drive the production wiring rather than a model of it:
/// `PaneFocusRouting.connect` / `.scheduleFocusCommand` are the same calls `TenonApp.wire`
/// makes, and `StubTerminalSurface.focus()` fires `onFocusGained` exactly as
/// `GhosttySurface.becomeFirstResponder` does.
@MainActor
final class PaneFocusSettlementTests: XCTestCase {
    /// Counts every write the surface→model edge makes, which is the transition count the
    /// task asks to be bounded.
    private final class FocusLedger {
        var writes: [UUID] = []
    }

    private struct Fixture {
        let store: WorkspaceStore
        let pool: SurfacePool
        let ledger: FocusLedger
        let path: URL
        let paneA: UUID
        let paneB: UUID
    }

    // MARK: - The loop

    func testTwoCompetingFocusCommandsSettleInsteadOfTradingFocusForever() async {
        let fixture = makeFixture()

        // The empty-space launcher creates and focuses a pane while the pane the person was
        // leaving is still the one AppKit will hand first responder back to. Both focus
        // commands are therefore in flight at once, which is the state the bug needed.
        fixture.store.focusSlot(fixture.paneB)
        fixture.pool.focusSurface(for: fixture.paneA)

        await settle()

        XCTAssertLessThanOrEqual(
            fixture.ledger.writes.count,
            1,
            "focus transitions after creation must be bounded, not self-sustaining"
        )
        XCTAssertEqual(
            fixture.store.catalog.activeSlotID,
            fixture.paneB,
            "the pane the launcher created is the one focus settles on"
        )
    }

    func testAHostDrivenFocusReportsNothingBackToTheWorkspace() async {
        let fixture = makeFixture()

        // The workspace already believes A is focused. Moving the responder chain to match
        // is not news, so it must not re-enter the model and re-issue itself.
        fixture.pool.focusSurface(for: fixture.paneA)

        await settle()

        XCTAssertEqual(fixture.ledger.writes, [])
    }

    func testAStaleFocusCommandIsDroppedWhenTheModelHasMovedOn() async {
        let fixture = makeFixture()
        let surfaceB = fixture.pool.surface(for: fixture.paneB, workspacePath: fixture.path) as? StubTerminalSurface
        let before = surfaceB?.focusCount ?? 0

        // A command queued for B, then the person picks A before the turn runs.
        PaneFocusRouting.scheduleFocusCommand(
            for: fixture.paneB,
            store: fixture.store,
            surfaces: fixture.pool
        )
        fixture.store.focusSlot(fixture.paneA)

        await settle()

        XCTAssertEqual(
            surfaceB?.focusCount,
            before,
            "a command for a pane the workspace no longer considers active does nothing"
        )
        XCTAssertEqual(fixture.store.catalog.activeSlotID, fixture.paneA)
    }

    // MARK: - What must keep working

    func testAPersonClickingIntoAPaneStillMovesTheWorkspacesFocus() async {
        let fixture = makeFixture()
        let surfaceB = fixture.pool.surface(for: fixture.paneB, workspacePath: fixture.path) as? StubTerminalSurface

        // Nothing host-driven is in progress: this is the window server reporting a real
        // click, and it is the one report that must reach the model.
        surfaceB?.onFocusGained?()

        await settle()

        XCTAssertEqual(fixture.ledger.writes, [fixture.paneB])
        XCTAssertEqual(fixture.store.catalog.activeSlotID, fixture.paneB)
    }

    func testAnOverlayRestoringFirstResponderCannotReclaimFocus() async {
        let fixture = makeFixture()
        let surfaceA = fixture.pool.surface(for: fixture.paneA, workspacePath: fixture.path) as? StubTerminalSurface

        // The launcher is up, so it owns the key window. It creates and focuses a pane…
        fixture.pool.isOverlayOwningFocus = true
        fixture.store.focusSlot(fixture.paneB)
        // …and dismissing it makes AppKit hand first responder back to the pane the person
        // was leaving. That restoration is not a choice and must not be adopted.
        surfaceA?.onFocusGained?()
        fixture.pool.isOverlayOwningFocus = false

        await settle()

        XCTAssertEqual(fixture.ledger.writes, [])
        XCTAssertEqual(fixture.store.catalog.activeSlotID, fixture.paneB)
    }

    // MARK: - Fixture

    private func makeFixture() -> Fixture {
        let paneA = UUID()
        let paneB = UUID()
        let tab = TenonCore.Tab(
            slots: [
                WorkspaceSlot(id: paneA, rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                              content: .terminal),
                WorkspaceSlot(id: paneB, rect: GridRect(x: 6, y: 0, width: 6, height: 12),
                              content: .terminal),
            ],
            activeSlotID: paneA
        )
        let workspace = Workspace(
            name: "Focus",
            path: FileManager.default.temporaryDirectory,
            tabs: [tab],
            activeTabID: tab.id
        )
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let ledger = FocusLedger()

        // The production wiring, both edges.
        PaneFocusRouting.connect(store: store, surfaces: pool)
        let modelWriter = pool.onSlotFocusGained
        pool.onSlotFocusGained = { slotID in
            ledger.writes.append(slotID)
            modelWriter?(slotID)
        }
        store.onEvents = { [weak store, weak pool] events, _ in
            guard let store, let pool else { return }
            for event in events {
                if case let .slotFocused(slotID, _, _) = event {
                    PaneFocusRouting.scheduleFocusCommand(
                        for: slotID,
                        store: store,
                        surfaces: pool
                    )
                }
            }
        }

        // Both panes are displayed, so both have a live surface — the state in which two
        // focus commands can actually fight.
        _ = pool.surface(for: paneA, workspacePath: workspace.path)
        _ = pool.surface(for: paneB, workspacePath: workspace.path)
        return Fixture(
            store: store,
            pool: pool,
            ledger: ledger,
            path: workspace.path,
            paneA: paneA,
            paneB: paneB
        )
    }

    /// Lets every queued focus command — and every command those commands queue — run. A
    /// self-sustaining cycle never runs out of turns, so the bound has to be the assertion
    /// rather than the wait.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}
