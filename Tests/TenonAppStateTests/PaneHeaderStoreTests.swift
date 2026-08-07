import Observation
import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// The app half of the pane header: the store that carries a host-native pane's contribution
/// across two SwiftUI graphs, and the projection that decides which header a slot draws.
///
/// Both halves are asserted headlessly because both are pure rules about *when a write
/// happens* and *where a value comes from* — neither needs a window, and neither is safe to
/// verify by looking at the app. Three of these five tests assert a NEGATIVE (no mutation, no
/// handler call, no header), so each one is paired with a positive control in the same test:
/// without the control, a broken observation harness or a dead store would pass every
/// negative for the wrong reason.
@MainActor
final class PaneHeaderStoreTests: XCTestCase {
    private let explorer: PluginID = "dev.tenon.file-explorer"
    private let kanban: PluginID = "dev.tenon.kanban"

    // MARK: - Fixtures

    private func badgeHeader(_ text: String) -> PaneHeader {
        PaneHeader(leading: [.badge(id: "count", text: text, tint: .green, tooltip: nil)])
    }

    private func slot(_ id: UUID, content: SlotContent) -> WorkspaceSlot {
        WorkspaceSlot(id: id, rect: GridRect(x: 0, y: 0, width: 6, height: 12), content: content)
    }

    private func section(
        plugin: PluginID,
        view: String,
        instance: String?,
        title: String
    ) -> PluginViewSection {
        PluginViewSection(
            pluginID: plugin,
            viewID: view,
            instanceID: instance,
            instanced: instance != nil,
            title: title,
            items: [],
            body: nil
        )
    }

    /// `withObservationTracking` hands its `onChange` a `@Sendable` closure, so the flag it
    /// raises cannot be a captured local `var`. A reference box is the smallest thing the
    /// closure and the assertion can share; every use here is synchronous and on the main
    /// actor, which is what makes the unchecked conformance honest rather than a shortcut.
    private final class ObservationFlag: @unchecked Sendable {
        var didChange = false
    }

    // MARK: - The store's write discipline

    /// The loop breaker. A content view republishing the header it already published must
    /// perform no `@Observable` write at all — not merely write the same value — because the
    /// write is what re-evaluates `WorkspaceStageView.body`, which is what re-runs the canvas
    /// configure pass that would publish again.
    func testPublishingAnEqualHeaderDoesNotMutateTheStore() {
        let store = PaneHeaderStore()
        let slotID = UUID()
        store.publish(badgeHeader("12"), for: slotID)

        let flag = ObservationFlag()
        withObservationTracking {
            _ = store.headers
        } onChange: {
            flag.didChange = true
        }

        store.publish(badgeHeader("12"), for: slotID)

        XCTAssertFalse(
            flag.didChange,
            "republishing an equal header must not mutate the store: the mutation is what "
                + "invalidates the stage, and the stage is what publishes again"
        )
        XCTAssertEqual((store.headers[slotID] ?? .empty), badgeHeader("12"))

        // The control: the same armed tracking DOES fire for a real change, so the assertion
        // above means "no write" rather than "no observer".
        store.publish(badgeHeader("13"), for: slotID)
        XCTAssertTrue(
            flag.didChange,
            "a header that actually changed must invalidate its reader"
        )
    }

    /// Why the canvas is allowed to ask for the backstop on every configure pass. A sweep
    /// that found nothing stale must be invisible to observation; if it were not, the
    /// backstop would invalidate the very stage that called it, on every pass, forever.
    func testASweepWithNothingStaleDoesNotMutateTheStore() async {
        let store = PaneHeaderStore()
        let live = UUID()
        let alsoLive = UUID()
        var swept = 0
        store.publish(badgeHeader("1"), for: live)
        store.publish(badgeHeader("2"), for: alsoLive)
        store.onCommand(for: alsoLive) { _, _ in swept += 1 }

        let flag = ObservationFlag()
        withObservationTracking {
            _ = store.headers
        } onChange: {
            flag.didChange = true
        }

        // A superset of what the store holds — the canvas passes every live slot in the
        // catalog, not just the ones that published.
        store.scheduleSweep(retaining: [live, alsoLive, UUID()])
        await store.pendingSweep?.value

        XCTAssertFalse(
            flag.didChange,
            "a sweep with nothing stale must perform zero observable writes"
        )
        XCTAssertEqual((store.headers[live] ?? .empty), badgeHeader("1"))
        XCTAssertEqual((store.headers[alsoLive] ?? .empty), badgeHeader("2"))
        store.perform(.changesRefresh, value: nil, for: alsoLive)
        XCTAssertEqual(swept, 1, "a retained slot keeps its handler")

        // The control: a sweep that IS stale still collects, and still invalidates.
        store.scheduleSweep(retaining: [live])
        await store.pendingSweep?.value
        XCTAssertTrue(flag.didChange, "dropping a stale slot must invalidate its reader")
        XCTAssertEqual((store.headers[alsoLive] ?? .empty), .empty)
        XCTAssertEqual((store.headers[live] ?? .empty), badgeHeader("1"))
        store.perform(.changesRefresh, value: nil, for: alsoLive)
        XCTAssertEqual(
            swept,
            1,
            "the backstop releases the handler too, or a pane torn down without onDisappear "
                + "keeps its model alive forever"
        )
    }

    /// The sweep's WRITE never happens on the caller's stack, because the caller is
    /// `SpatialCanvasNSView.configure` and that runs inside SwiftUI's view update. Deciding
    /// there is something to collect is a read and stays synchronous; collecting it lands
    /// after the update that asked for it.
    func testTheSweepDefersItsWriteOffTheCallersStack() async {
        let store = PaneHeaderStore()
        let live = UUID()
        let closed = UUID()
        var reachedClosedPane = 0
        store.publish(badgeHeader("1"), for: live)
        store.publish(badgeHeader("2"), for: closed)
        store.onCommand(for: closed) { _, _ in reachedClosedPane += 1 }

        store.scheduleSweep(retaining: [live])

        XCTAssertEqual(
            (store.headers[closed] ?? .empty),
            badgeHeader("2"),
            "the sweep must not have written anything by the time it returns"
        )

        await store.pendingSweep?.value

        XCTAssertEqual((store.headers[closed] ?? .empty), .empty, "…and must have by the time it runs")
        XCTAssertEqual((store.headers[live] ?? .empty), badgeHeader("1"))
        store.perform(.changesRefresh, value: nil, for: closed)
        XCTAssertEqual(reachedClosedPane, 0, "the handler goes with the header")
    }

    /// Two update passes in a row must not race each other into the store. The second
    /// replaces the first's slot set rather than queueing behind it, so what lands is the
    /// newest truth about which panes are alive — never an older set that would collect a
    /// pane opened in between.
    func testASecondSweepSupersedesAnUnstartedFirstOne() async {
        let store = PaneHeaderStore()
        let first = UUID()
        let second = UUID()
        store.publish(badgeHeader("1"), for: first)
        store.publish(badgeHeader("2"), for: second)

        store.scheduleSweep(retaining: [first])
        store.scheduleSweep(retaining: [second])
        await store.pendingSweep?.value

        XCTAssertEqual(
            (store.headers[second] ?? .empty),
            badgeHeader("2"),
            "the newer sweep decides, so the pane it retains survives"
        )
        XCTAssertEqual(
            (store.headers[first] ?? .empty),
            .empty,
            "…and the pane it no longer names is collected"
        )
    }

    /// `clear` is the symmetric release a content view performs in `.onDisappear`, and it
    /// releases BOTH halves. Leaving the handler behind would keep the closed pane's model
    /// alive and let a click on a recycled slot id reach a view that is gone.
    func testClearingOnDisappearReleasesTheSlotsHeaderAndHandler() {
        let store = PaneHeaderStore()
        let slotID = UUID()
        var received: [(PaneHeaderCommand, String?)] = []

        store.publish(badgeHeader("7"), for: slotID)
        store.onCommand(for: slotID) { command, value in
            received.append((command, value))
        }

        store.perform(.changesLayout, value: "flat", for: slotID)
        XCTAssertEqual(received.count, 1, "a live slot's handler receives its command")
        XCTAssertEqual(received.first?.0, .changesLayout)
        XCTAssertEqual(received.first?.1, "flat")

        store.clear(for: slotID)

        XCTAssertEqual(
            (store.headers[slotID] ?? .empty),
            .empty,
            "a cleared slot draws the bare chrome again"
        )
        store.perform(.changesRefresh, value: nil, for: slotID)
        XCTAssertEqual(
            received.count,
            1,
            "a cleared slot's handler must not be called: the view that owned the state it "
                + "would change is gone"
        )
    }

    // MARK: - The projection

    /// The one instance-matching predicate, which a pane's title, its body and its header all
    /// read. A plugin publishing one view into two panes publishes two sections; picking the
    /// wrong one shows a neighbour's contribution in this pane's chrome.
    func testAPluginPaneReadsItsOwnInstanceSectionAndNeverAnothers() {
        let mine = UUID()
        let theirs = UUID()
        let sections = [
            section(plugin: explorer, view: "tree", instance: theirs.uuidString, title: "Theirs"),
            section(plugin: explorer, view: "tree", instance: mine.uuidString, title: "Mine"),
            section(plugin: explorer, view: "sessions", instance: nil, title: "Sessions")
        ]

        XCTAssertEqual(
            PaneHeaderProjection.section(
                pluginID: explorer, viewID: "tree", slotID: mine, in: sections
            )?.title,
            "Mine",
            "an instanced view resolves to the section keyed by THIS slot"
        )
        XCTAssertEqual(
            PaneHeaderProjection.section(
                pluginID: explorer, viewID: "tree", slotID: theirs, in: sections
            )?.title,
            "Theirs",
            "and the neighbouring pane resolves to its own, from the same array"
        )
        XCTAssertEqual(
            PaneHeaderProjection.section(
                pluginID: explorer, viewID: "sessions", slotID: mine, in: sections
            )?.title,
            "Sessions",
            "a singleton view has no instance and belongs to whichever pane shows it"
        )

        XCTAssertNil(
            PaneHeaderProjection.section(
                pluginID: explorer, viewID: "tree", slotID: UUID(), in: sections
            ),
            "a pane with no instance of its own reads NOTHING rather than a neighbour's"
        )
        XCTAssertNil(
            PaneHeaderProjection.section(
                pluginID: kanban, viewID: "tree", slotID: mine, in: sections
            ),
            "another plugin's identically named view is not this pane's contribution"
        )
    }

    /// A plugin pane's header rides its contribution, so when the generation that published it
    /// retires there is nothing left to draw — even if the store still holds an entry under
    /// that slot id. That is what lets the store stay ignorant of plugins entirely.
    func testARetiredPluginGenerationLeavesNoHeaderBehind() {
        let store = PaneHeaderStore()
        let pluginSlotID = UUID()
        let terminalSlotID = UUID()
        let pluginSlot = slot(
            pluginSlotID,
            content: .pluginView(pluginID: explorer, viewID: "tree")
        )
        let terminalSlot = slot(terminalSlotID, content: .terminal)

        store.publish(badgeHeader("42"), for: pluginSlotID)
        store.publish(badgeHeader("42"), for: terminalSlotID)

        XCTAssertEqual(
            PaneHeaderProjection.header(
                for: pluginSlot,
                published: store.headers[pluginSlotID],
                pluginViewSections: []
            ),
            .empty,
            "a plugin pane never reads the store, so a retired generation cannot leave chrome "
                + "behind in it"
        )
        XCTAssertEqual(
            PaneHeaderProjection.header(
                for: terminalSlot,
                published: store.headers[terminalSlotID],
                pluginViewSections: []
            ),
            badgeHeader("42"),
            "the control: for a host-native pane the store IS the source"
        )
    }
}
