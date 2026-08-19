import Foundation
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

/// T-029 app half: adapters and projection over the one core `PaneActivity` machine.
/// The shell decides nothing — the viewed rule, the rollups, the poll feed and the
/// notification batching are all asserted here headlessly, without a window. Time is
/// a parameter throughout: every mutation receives an injected instant on the same
/// 200 ms cadence `terminal.wait.v1`'s loop uses.
@MainActor
final class PaneAttentionTests: XCTestCase {
    private var scratch: URL!
    /// Every surface the pool built, keyed by slot, so tests can script what the
    /// fixed-interval poll observes (text / exit / finish counter).
    private var scripted: [UUID: ScriptedTerminalSurface] = [:]

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The poll cadence as an injected clock: tick(n) is n × 200 ms after t0.
    private func tick(_ n: Int) -> Date {
        t0.addingTimeInterval(Double(n) * 0.2)
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-pane-attention-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        scripted = [:]
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    // MARK: - The three-condition viewed rule (pure projection)

    func testViewedNeedsFrontmostAndSelectedWorkspaceAndDisplayedPane() {
        let world = makeCatalogWithHiddenPanes()

        XCTAssertEqual(
            PaneAttentionProjection.viewedSlots(
                appFrontmost: false,
                catalog: world.catalog
            ),
            [],
            "app frontmost is condition (a): while Tenon is in the background nothing is viewed, whatever is selected"
        )
        XCTAssertEqual(
            PaneAttentionProjection.viewedSlots(
                appFrontmost: true,
                catalog: world.catalog
            ),
            world.visibleSlots,
            "exactly the selected workspace's displayed canvas: the background tab's pane and the other workspace's pane are excluded"
        )
    }

    // MARK: - The fixed-interval poll feed

    func testPollFeedsTheMachineAndAStableScreenReachesIdle() {
        let pool = makePool()
        let slot = UUID()
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "

        pool.pollActivity(at: tick(0))
        XCTAssertEqual(
            pool.paneAttention[slot]?.state,
            .working,
            "one sample is not stability — the embedded IdleDetector needs consecutive identical polls"
        )

        pool.pollActivity(at: tick(1))
        pool.pollActivity(at: tick(2))
        XCTAssertEqual(
            pool.paneAttention[slot]?.state,
            .idle,
            "three consecutive identical 200 ms polls are the one idle rule — the feed must be poll-shaped, never event-shaped"
        )
    }

    /// T-178's own hazard: an interactive agent (`claude`, `codex`, `opencode`) never returns
    /// its foreground shell command, so OSC 133 never fires between its turns — a pane running
    /// one can only ever poll into `.working` or `.idle`, and a turn that genuinely finished
    /// reads identically to a prompt that never had anything to say. `noteAgentTurnFinished` is
    /// the hook-driven escape from that ceiling.
    func testAnAgentsHookDrivenFinishReachesTheSameStateARealCommandFinishWould() {
        let pool = makePool()
        let slot = UUID()
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "

        pool.pollActivity(at: tick(0))
        pool.pollActivity(at: tick(1))
        pool.pollActivity(at: tick(2))
        XCTAssertEqual(
            pool.paneAttention[slot]?.state,
            .idle,
            "no OSC 133 finish ever arrived, so a stable screen alone reads as idle — this is the bug"
        )

        pool.noteAgentTurnFinished(for: slot)
        pool.pollActivity(at: tick(3))

        XCTAssertEqual(
            pool.paneAttention[slot]?.state,
            .finishedUnseen,
            "a Stop-driven finish must be indistinguishable from a real OSC 133 one to the machine"
        )
    }

    /// T-141. The poll asks every open pane, five times a second, on the main thread — and the
    /// only thing it ever does with a screen is compare it to the previous one
    /// (`IdleDetector.record` is a single `==`). Taking the rendered-text answer for that
    /// comparison is what incident `0005-87f24878` measured at **83% of the main thread**:
    /// `AppComposition.startAttentionPolling` → `SurfacePool.pollActivity` →
    /// `GhosttySurface.renderedText`, which builds one Swift `String` per row character by
    /// character and runs one ICU regular expression per row — per pane, per poll.
    func testTheActivityPollNeverRendersAScreenAsText() {
        let pool = makePool()
        let slots = (0 ..< 8).map { _ in UUID() }
        for slot in slots {
            _ = pool.surface(for: slot, workspacePath: scratch)
            scripted[slot]?.text = "$ "
        }

        for turn in 0 ..< 5 {
            pool.pollActivity(at: tick(turn))
        }

        let reads = slots.compactMap { scripted[$0]?.renderedTextReads }.reduce(0, +)
        XCTAssertEqual(
            reads,
            0,
            """
            the activity poll rendered \(reads) screens to text across 8 panes and 5 turns, to \
            answer a question that is `==`. At the shipped cadence that is \(reads * 40) \
            renders a minute per eight panes, on the main thread.
            """
        )
    }

    func testANeverMaterialisedPaneReportsNoActivity() {
        let pool = makePool()
        let slot = UUID()
        pool.seedSpawnDirectory(scratch, for: slot)

        pool.applyViewed([slot], at: tick(0))
        pool.pollActivity(at: tick(0))
        pool.pollActivity(at: tick(1))

        XCTAssertNil(
            pool.paneAttention[slot],
            "a pane with no surface has nothing to observe: no invented observation, no fake state, and nothing to count"
        )
    }

    // MARK: - Bold-until-viewed through the adapters

    func testAFinishWhileUnviewedBoldsAndOnlyViewingClears() {
        let pool = makePool()
        let slot = UUID()
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "
        pool.pollActivity(at: tick(0))

        scripted[slot]?.finishedCount = 1
        pool.pollActivity(at: tick(1))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            true,
            "the finish counter rose while unviewed — that is the bold"
        )

        pool.pollActivity(at: tick(2))
        pool.pollActivity(at: tick(3))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            true,
            "quiet stability and passing polls never clear the bold — no timer ever views a pane"
        )
        XCTAssertEqual(pool.paneAttention[slot]?.state, .finishedUnseen)

        pool.applyViewed([slot], at: tick(4))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            false,
            "viewing is the only clearer"
        )
        XCTAssertEqual(pool.paneAttention[slot]?.state, .seen)
    }

    func testAFinishUnderTheHumansEyesNeverBoldsAndLeavingRearms() {
        let pool = makePool()
        let slot = UUID()
        // Viewed-ness can precede materialisation: the tab is displayed, then the
        // render path builds the surface, then the first poll observes it.
        pool.applyViewed([slot], at: tick(0))
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "
        pool.pollActivity(at: tick(0))

        scripted[slot]?.finishedCount = 1
        pool.pollActivity(at: tick(1))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            false,
            "a finish under the human's eyes needs no flag"
        )

        pool.applyViewed([], at: tick(2))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            false,
            "un-viewing acknowledges nothing and re-flags nothing"
        )

        scripted[slot]?.finishedCount = 2
        pool.pollActivity(at: tick(3))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            true,
            "leaving the viewed condition re-arms the machine for the next finish"
        )
    }

    func testAnExitKeepsItsUnseenFlagUntilViewedAndStateStaysExited() {
        let pool = makePool()
        let slot = UUID()
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "
        pool.pollActivity(at: tick(0))

        scripted[slot]?.exited = true
        pool.pollActivity(at: tick(1))
        XCTAssertEqual(pool.paneAttention[slot]?.state, .exited)
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            true,
            "a crash nobody watched still needs a human"
        )

        pool.applyViewed([slot], at: tick(2))
        XCTAssertEqual(
            pool.paneAttention[slot]?.isUnseen,
            false,
            "viewing an exited pane clears the bold"
        )
        XCTAssertEqual(
            pool.paneAttention[slot]?.state,
            .exited,
            "but the state stays exited — viewing does not resurrect a dead shell"
        )
    }

    // MARK: - The notification seam

    func testBecameUnseenFiresAsOnePollPassBatchAcrossPanes() {
        let pool = makePool()
        let first = UUID()
        let second = UUID()
        _ = pool.surface(for: first, workspacePath: scratch)
        _ = pool.surface(for: second, workspacePath: scratch)
        scripted[first]?.text = "$ "
        scripted[second]?.text = "$ "

        var bursts: [Set<UUID>] = []
        pool.onPanesBecameUnseen = { bursts.append(Set($0)) }

        pool.pollActivity(at: tick(0))
        XCTAssertTrue(bursts.isEmpty, "baselining invents no attention")

        scripted[first]?.finishedCount = 1
        scripted[second]?.finishedCount = 1
        pool.pollActivity(at: tick(1))
        XCTAssertEqual(
            bursts,
            [[first, second]],
            "several panes landing in one poll pass are ONE batch — the coalescing unit"
        )

        pool.pollActivity(at: tick(2))
        XCTAssertEqual(
            bursts.count,
            1,
            "an already-bold pane emits nothing — becameUnseen fires once per needs-attention episode"
        )
    }

    func testNotifierFiresOnlyInBackgroundAndCoalescesABurstToOneAlert() {
        var delivered: [PaneAttentionNotifier.Alert] = []
        var frontmost = true
        let notifier = PaneAttentionNotifier(
            isAppFrontmost: { frontmost },
            deliver: { delivered.append($0) }
        )
        let build = UUID()
        let tests = UUID()
        let titles = [build: "cargo build", tests: "swift test"]

        notifier.panesBecameUnseen([build, tests], titles: titles)
        XCTAssertTrue(
            delivered.isEmpty,
            "while the app is frontmost the human is already here — no system notification"
        )

        frontmost = false
        notifier.panesBecameUnseen([build, tests], titles: titles)
        XCTAssertEqual(
            delivered.count,
            1,
            "a burst is one notification, never one per finished pane"
        )
        XCTAssertTrue(
            delivered.first?.body.contains("2") == true,
            "the coalesced alert says how many panes need a human, got: \(String(describing: delivered.first?.body))"
        )

        notifier.panesBecameUnseen([build], titles: titles)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertTrue(
            delivered.last?.body.contains("cargo build") == true,
            "a single pane is named by its title, got: \(String(describing: delivered.last?.body))"
        )
        XCTAssertEqual(
            delivered.count == 2 ? delivered.last?.slotIDs : nil,
            [build],
            "the alert carries its slots so activation can focus the pane — the viewed rule then clears the bold, no second clearing path"
        )
    }

    // MARK: - Lifetimes and rollups

    func testRetainOnlyDropsAttentionWithTheSlot() {
        let pool = makePool()
        let slot = UUID()
        _ = pool.surface(for: slot, workspacePath: scratch)
        scripted[slot]?.text = "$ "
        pool.pollActivity(at: tick(0))
        XCTAssertNotNil(pool.paneAttention[slot])

        pool.retainOnly([])

        XCTAssertNil(
            pool.paneAttention[slot],
            "attention state is bounded by the slot's lifetime (invariant 10)"
        )
        pool.pollActivity(at: tick(1))
        XCTAssertTrue(
            pool.paneAttention.isEmpty,
            "a departed slot's machine never resurrects on a later poll"
        )
    }

    func testRollupsCountUnseenSlotsPerWorkspaceAndAcrossTheCatalog() {
        let world = makeCatalogWithHiddenPanes()
        var attention: [UUID: PaneActivity] = [:]
        attention[world.activeSlot] = finishedUnseenActivity()
        attention[world.splitSlot] = idleActivity()
        attention[world.otherWorkspaceSlot] = finishedUnseenActivity()

        let selected = world.catalog.workspaces[0]
        let other = world.catalog.workspaces[1]
        XCTAssertEqual(
            PaneAttentionProjection.unseenCount(in: selected, attention: attention),
            1,
            "the sidebar row counts that workspace's unseen slots"
        )
        XCTAssertEqual(
            PaneAttentionProjection.unseenCount(in: other, attention: attention),
            1
        )
        XCTAssertEqual(
            PaneAttentionProjection.totalUnseen(
                catalog: world.catalog,
                attention: attention
            ),
            2,
            "the title bar counts unseen slots across the whole catalog"
        )

        let visibleTab = selected.tabs[0]
        XCTAssertEqual(
            PaneAttentionProjection.tabState(for: visibleTab, attention: attention),
            .finishedUnseen,
            "the chip's dot is its active slot's state — the same pane the chip's title names"
        )
        XCTAssertTrue(
            PaneAttentionProjection.tabIsUnseen(visibleTab, attention: attention),
            "the chip bolds while any of its slots is unseen"
        )

        let emptyAttention: [UUID: PaneActivity] = [:]
        XCTAssertNil(
            PaneAttentionProjection.tabState(for: visibleTab, attention: emptyAttention),
            "a tab whose panes never materialised shows no dot instead of a fake state"
        )
        XCTAssertFalse(
            PaneAttentionProjection.tabIsUnseen(visibleTab, attention: emptyAttention)
        )
    }

    // MARK: - Helpers

    private func makePool() -> SurfacePool {
        SurfacePool(backendName: "Scripted") { [weak self] slotID, _ in
            let surface = ScriptedTerminalSurface()
            self?.scripted[slotID] = surface
            return surface
        }
    }

    /// A machine that finished while nobody viewed it, on a stable screen: state
    /// `.finishedUnseen`, `isUnseen` true. Built through the real core machine so the
    /// rollup tests cannot drift from its semantics.
    private func finishedUnseenActivity() -> PaneActivity {
        var activity = PaneActivity(at: t0)
        _ = activity.observe(
            .init(screen: "$ ".hashValue, processExited: false, commandFinishedCount: 0),
            at: tick(0)
        )
        _ = activity.observe(
            .init(screen: "$ ".hashValue, processExited: false, commandFinishedCount: 1),
            at: tick(1)
        )
        _ = activity.observe(
            .init(screen: "$ ".hashValue, processExited: false, commandFinishedCount: 1),
            at: tick(2)
        )
        return activity
    }

    private func idleActivity() -> PaneActivity {
        var activity = PaneActivity(at: t0)
        for n in 0 ..< 3 {
            _ = activity.observe(
                .init(screen: "$ ".hashValue, processExited: false, commandFinishedCount: 0),
                at: tick(n)
            )
        }
        return activity
    }

    private struct CatalogWorld {
        let catalog: WorkspaceCatalog
        /// The selected workspace's active tab: what the canvas actually displays.
        let visibleSlots: Set<UUID>
        /// The active (focused) slot of the displayed tab.
        let activeSlot: UUID
        /// The displayed tab's second pane (a split — visible alongside the active one).
        let splitSlot: UUID
        /// A pane hidden in a background tab of the selected workspace.
        let hiddenTabSlot: UUID
        /// A pane in the unselected workspace.
        let otherWorkspaceSlot: UUID
    }

    /// Two workspaces; the selected one has a two-pane split on its active tab plus a
    /// background tab. Every viewed-rule distinction lives in this one catalog.
    private func makeCatalogWithHiddenPanes() -> CatalogWorld {
        let active = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 6, height: 12)
        )
        let split = WorkspaceSlot(
            rect: GridRect(x: 6, y: 0, width: 6, height: 12)
        )
        let hidden = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12)
        )
        let other = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12)
        )
        let visibleTab = Tab(slots: [active, split], activeSlotID: active.id)
        let backgroundTab = Tab(slots: [hidden], activeSlotID: hidden.id)
        let selected = Workspace(
            name: "Selected",
            path: scratch,
            tabs: [visibleTab, backgroundTab],
            activeTabID: visibleTab.id
        )
        let otherTab = Tab(slots: [other], activeSlotID: other.id)
        let unselected = Workspace(
            name: "Other",
            path: scratch,
            tabs: [otherTab],
            activeTabID: otherTab.id
        )
        return CatalogWorld(
            catalog: WorkspaceCatalog(
                workspaces: [selected, unselected],
                activeWorkspaceID: selected.id
            ),
            visibleSlots: [active.id, split.id],
            activeSlot: active.id,
            splitSlot: split.id,
            hiddenTabSlot: hidden.id,
            otherWorkspaceSlot: other.id
        )
    }
}

/// A `TerminalSurface` the tests script directly: the pool's fixed-interval poll reads
/// whatever the test last wrote. A fake conformance on the existing seam (docs/tdd.md),
/// not a parallel protocol.
@MainActor
private final class ScriptedTerminalSurface: TerminalSurface {
    let backendName = "Scripted"
    var onTitleChange: ((String) -> Void)?
    var text = "" {
        didSet { revision += 1 }
    }

    var exited = false
    var finishedCount = 0

    /// How often anyone asked this screen for its characters. The poll must never be the
    /// caller: rendering text is what put 83% of the main thread inside `renderedText` during
    /// incident `0005-87f24878` (T-141).
    private(set) var renderedTextReads = 0
    private var revision = 0

    var renderedText: String {
        renderedTextReads += 1
        return text
    }

    /// Changes with the screen and never asks for its characters, which is the whole contract.
    var screenFingerprint: Int { revision }
    var processExited: Bool { exited }
    var commandFinishedCount: Int { finishedCount }

    func noteAgentTurnFinished() {
        finishedCount += 1
    }

    func makeView() -> AnyView {
        AnyView(EmptyView())
    }
}
