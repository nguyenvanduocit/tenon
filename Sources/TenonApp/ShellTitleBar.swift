// @domain: workspace-model, attention
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The full-width top row shared with the traffic lights. Its left zone (app identity
/// + sidebar toggle) sits above the sidebar column; its right zone (the tab strip,
/// ending in the `+` launcher) sits above the content column.
///
/// # Who owns the pointer in this row
///
/// The row is drawn inside the window's title-bar band, and that band is the one place where
/// **macOS**, not this app, decides what a drag means. It decides it *before the press
/// happens*: AppKit computes a drag region for the window and uploads it to the window
/// server, which then starts the move itself, consulting nothing. A view stays out of that
/// region by answering `mouseDownCanMoveWindow` with `false` **and being an `NSControl`
/// descendant that accepts first responder** — the region builder ignores a plain `NSView`
/// saying it, and puts a control that refuses first responder back inside, which is why the
/// traffic lights (`NSButton`) are the baseline hole in the region and ordinary SwiftUI
/// content is not. Both halves are load-bearing and both were learned from a human drag:
/// `scripts/drag-region-probe.swift` measures them. So each zone of this row states who owns
/// its pointer, and the classification is a property of the views, not of the reading order:
///
/// | Zone | Owner | A drag there |
/// |---|---|---|
/// | the chips | `TabStripSurface` — one AppKit view over the chips, and nothing else | reorders the tab |
/// | empty chrome | `WindowDragArea` — `performDrag`, so double-click still zooms | moves the window |
/// | identity (icon, wordmark, unseen count, sidebar toggle) | SwiftUI | moves the window |
/// | the `+` launcher | SwiftUI | moves the window |
/// | quick commands | SwiftUI | moves the window |
///
/// The last three are deliberate rather than left over: they are chrome that happens to carry
/// a control, and dragging chrome is what a title bar is for. The chips are the zone where
/// that default is wrong, because a tab is a thing you move — so they, and only they, take the
/// pointer away from the window server, and then own everything that pointer can mean.
///
/// The boundary is exact for a reason. The first version of the surface stretched over the
/// `+` as well, and a control under it hears nothing at all: taking the pointer means owning
/// every meaning of it, so the surface is drawn over precisely the region whose meanings it
/// implements. `testTheNewTabButtonIsNotCoveredByTheStripSurface` holds that line.
struct ShellTitleBar: View {
    var host: PluginHost
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    var intentRuntime: AppIntentRuntime
    var router: DragRouter
    var palette: CommandPaletteState
    var quickCommands: QuickCommandStore
    let agentSuggestions: [AgentLaunchSuggestion]
    /// The resource monitor's presentation state, composed by the app.
    ///
    /// Optional because the title bar is mounted in offscreen renderers and tests that have
    /// no telemetry stack behind them; the trigger simply is not drawn there, rather than
    /// every one of those call sites having to build a sampler.
    var resourceMonitor: ResourceMonitorModel?
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void

    /// Past this much tab strip the resource summary drops its caption and keeps its icon. A
    /// caption is what a translation or a larger text size grows, so dropping it is what makes
    /// the crowded case fit instead of clip.
    private static let compactResourceSummaryWidth: CGFloat = 420

    @State private var launcherPresented = false
    /// Which tab's right-click launcher popover is open, if any. One value for the whole
    /// strip: opening a second tab's launcher closes the first.
    @State private var contextLauncherTab: UUID?

    /// Dispatch a launcher command as if it had been chosen *on this tab*.
    ///
    /// The scope is the whole point: the palette and unanchored launcher surfaces invoke
    /// against the focused pane, which for a right-click on a background tab would put the
    /// result in the wrong place.
    /// Placement itself stays host policy inside `workspace.content.open.v1` — this only
    /// says which tab is being talked about. The result flows back to the launcher, which
    /// settles it exactly as the `+` popover does.
    private func send(
        _ invocation: PaletteIntentInvocation,
        onTab tabID: UUID
    ) async -> LauncherOutcome {
        guard let paneID = TabContextPlacement.scopedPane(
            in: store.catalog,
            tabID: tabID
        ) else {
            return .targetUnavailable
        }
        let workspaceID = TabContextPlacement.owningWorkspace(
            in: store.catalog,
            tabID: tabID
        )
        if TabContextPlacement.requiresRevealing(
            in: store.catalog,
            tabID: tabID,
            placesContent: true
        ) {
            store.selectTab(tabID)
        }
        return LauncherOutcome(await PaletteIntentInvoker.send(
            invocation,
            scope: InvocationScope(
                workspaceID: workspaceID,
                tabID: tabID,
                paneID: paneID
            ),
            runtime: intentRuntime
        ))
    }

    /// Dispatch a title-bar `+` choice inside a fresh tab. The temporary tab provides
    /// ordinary pane scope to plugin openers; commands whose own meaning is "new tab"
    /// replace that placeholder instead of leaving two tabs behind.
    private func sendInNewTab(
        _ invocation: PaletteIntentInvocation
    ) async -> LauncherOutcome {
        LauncherOutcome(await NewTabLauncherPlacement.invoke(
            in: store,
            userGestureID: invocation.userGestureID
        ) { scope in
            await PaletteIntentInvoker.send(
                invocation,
                scope: scope,
                runtime: intentRuntime
            )
        })
    }

    private func requestClose(_ tab: TenonCore.Tab, title: String) {
        guard let workspaceID = activeWorkspace?.id else { return }
        Task { @MainActor in
            await closeCoordinator.requestClose(
                tab,
                workspaceID: workspaceID,
                title: title
            )
        }
    }

    /// Width the tab chips actually need, so the row can hand everything past them
    /// to the drag surface instead of letting the scroll view swallow the whole side.
    @State private var tabStripWidth: CGFloat = 0

    // MARK: - Reordering the strip  @domain: workspace-model

    /// Each chip's horizontal extent in the strip's own coordinate space (T-096). The strip
    /// already reports *window*-space chip frames to `DragRouter` for the canvas's pane
    /// drag; a reorder is a gesture entirely inside the strip, so it reads the strip's own
    /// space instead and needs no conversion, no flip, and no y.
    @State private var chipExtents: [UUID: ClosedRange<CGFloat>] = [:]
    /// Where each chip drew its close control, in that same space. Reported by the control
    /// itself rather than restated from `TabChip`'s padding, so the click that closes a tab
    /// and the ✕ a person aims at can never describe different rectangles.
    @State private var closeExtents: [UUID: ClosedRange<CGFloat>] = [:]
    /// The strip's own height, which is the band a release still counts as a drop in.
    @State private var stripHeight: CGFloat = 0
    /// The live reorder observed by the strip's AppKit event seam. It stays ordinary view
    /// state because the seam, rather than SwiftUI's gesture arena, owns cancellation.
    @State private var tabDrag: TabStripDrag?
    /// How long a tab takes to change places under the pointer. Short enough that the row has
    /// settled before the pointer reaches the next chip, long enough that the eye follows which
    /// chip went where instead of finding a row that has silently rearranged itself.
    private static let reorderAnimation: Animation = .easeInOut(duration: 0.12)
    /// The chip the pointer is resting on. The strip's surface owns every pointer inside the
    /// strip, so it owns the hover highlight too — a chip cannot notice a pointer that never
    /// reaches it.
    @State private var hoveredTab: UUID?

    /// The chips in display order, or fewer than there are tabs while a chip has not been
    /// laid out yet. Every reorder rule below refuses on that shortfall rather than
    /// reordering against indices it cannot see.
    private var chipStrip: [TabChipExtent] {
        activeTabs.compactMap { tab in
            chipExtents[tab.id].map {
                TabChipExtent(
                    id: tab.id,
                    minX: Double($0.lowerBound),
                    maxX: Double($0.upperBound)
                )
            }
        }
    }

    /// Whether the strip draws close controls at all — the last tab keeps no ✕, because a
    /// workspace always has one. Read by the chip that draws it and by the click that
    /// resolves against it, so a strip that stopped drawing the ✕ cannot still be answering
    /// for one: the extent a chip reported before it lost its control goes with it.
    private var canCloseTabs: Bool { activeTabs.count > 1 }

    /// The close controls in the same space as `chipStrip`, for the one rule that reads both.
    private var closeControls: [UUID: ClosedRange<Double>] {
        guard canCloseTabs else { return [:] }
        return closeExtents.mapValues { Double($0.lowerBound) ... Double($0.upperBound) }
    }

    /// A press that never travelled far enough to be a reorder. The strip owns the whole
    /// primary-button stream — that is what keeps a drag off the window server — so the
    /// click a chip's button used to answer is answered here, from the same geometry.
    private func pressStrip(at point: CGPoint) {
        switch TabReorder.press(
            at: Double(point.x),
            chips: chipStrip,
            closeControls: closeControls
        ) {
        case let .select(id):
            store.selectTab(id)
        case let .close(id):
            let tabs = activeTabs
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            requestClose(tabs[index], title: tabTitle(for: tabs[index]))
        case nil:
            break
        }
    }

    /// Which chip the pointer is over, from the surface that receives every pointer in the
    /// strip. `nil` once it leaves, so no chip stays lit behind a pointer that has gone.
    private func hoverStrip(at point: CGPoint?) {
        guard let point else {
            hoveredTab = nil
            return
        }
        hoveredTab = TabReorder.tab(at: Double(point.x), chips: chipStrip)
    }

    /// Start observing one drag only when its press landed on a fully measured chip. The index
    /// it started from is taken here and kept, because it is the only thing a release outside
    /// the strip can put the row back to once the tab has been travelling.
    private func beginReorder(at point: CGPoint) {
        let chips = chipStrip
        guard chips.count == activeTabs.count,
              let id = TabReorder.tab(at: Double(point.x), chips: chips),
              let origin = chips.firstIndex(where: { $0.id == id })
        else { return }
        tabDrag = TabStripDrag(tabID: id, originIndex: origin)
    }

    /// The preview *is* the move: while the pointer is inside the band the strip admits, the
    /// tab changes places under it, one chip at a time.
    ///
    /// Nothing is drawn beside the chips, and that is the point — a marker in a gap is a second
    /// description of where the tab will land, and two descriptions of one thing can disagree.
    /// The rules stay exactly the ones a release used to run: the gap the pointer means, and
    /// the array index that gap becomes. Applying them continuously closes a loop, since each
    /// move re-lays the chips the next pointer position is measured against — it settles
    /// because a gap is counted from midpoints, so the moved tab lands under the pointer and
    /// stops answering.
    private func updateReorder(at point: CGPoint) {
        guard let drag = tabDrag else { return }
        let chips = chipStrip
        guard chips.count == activeTabs.count,
              TabReorder.admitsDrop(
                  pointerY: Double(point.y),
                  stripHeight: Double(stripHeight)
              ),
              let destination = TabReorder.destination(
                  forTab: drag.tabID,
                  insertingAt: TabReorder.insertionIndex(at: Double(point.x), chips: chips),
                  chips: chips
              )
        else { return }
        withAnimation(Self.reorderAnimation) {
            store.moveTab(drag.tabID, to: destination)
        }
    }

    private func endReorder(at point: CGPoint) {
        guard let drag = tabDrag else { return }
        tabDrag = nil
        guard TabReorder.admitsDrop(
            pointerY: Double(point.y),
            stripHeight: Double(stripHeight)
        ) else {
            return restore(drag)
        }
        announceLanding(of: drag)
    }

    /// Puts the row back the way the drag found it, for a release aimed away from the strip.
    ///
    /// One move does it. Every other tab kept its relative order while the dragged one
    /// travelled, so returning that tab to the index it started at restores the sequence
    /// exactly — there is no snapshot to keep and none to go stale.
    private func restore(_ drag: TabStripDrag) {
        withAnimation(Self.reorderAnimation) {
            store.moveTab(drag.tabID, to: drag.originIndex)
        }
    }

    /// Says where the tab landed, once, when the pointer lets go.
    ///
    /// A live reorder passes through every place between the two ends, and narrating each one
    /// would bury the only one that is true under the ones that were not.
    private func announceLanding(of drag: TabStripDrag) {
        let tabs = activeTabs
        guard let index = tabs.firstIndex(where: { $0.id == drag.tabID }),
              index != drag.originIndex
        else { return }
        ReorderAnnouncer.say(
            TabReorder.announcement(
                title: tabTitle(for: tabs[index]),
                movedTo: index,
                of: tabs.count
            )
        )
    }

    /// The keyboard and VoiceOver route, which moves a tab and says so in one step: there is no
    /// pointer travelling to make the landing visible, so the move and its sentence arrive
    /// together.
    private func moveTab(_ tabID: UUID, to destination: Int) {
        let tabs = activeTabs
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let title = tabTitle(for: tabs[index])
        withAnimation(Self.reorderAnimation) {
            store.moveTab(tabID, to: destination)
        }
        ReorderAnnouncer.say(
            TabReorder.announcement(title: title, movedTo: destination, of: tabs.count)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            leftZone
                .frame(
                    width: sidebarVisible ? sidebarWidth : TenonTheme.sidebarWidth,
                    alignment: .leading
                )

            // With the sidebar expanded, the shell's full-height resize edge draws this
            // seam (and makes it draggable), so the title bar must not stack a second
            // static rule at the same x. With the icon rail there is no draggable edge
            // in the title bar, so the identity/tabs separator lives here.
            if !sidebarVisible {
                Rectangle()
                    .fill(TenonTheme.line)
                    .frame(width: 1)
            }

            rightZone
                .frame(maxWidth: .infinity)
        }
        .background(WindowDragArea(color: TenonTheme.chromeNS))
    }

    private var leftZone: some View {
        HStack(spacing: 8) {
            // Reserved for the OS traffic-light buttons, which overlay this corner.
            Color.clear
                .frame(width: TenonTheme.trafficLightInset)

            // Drop the wordmark first when the sidebar column is too narrow to hold
            // the full identity + toggle without the title crowding into the divider.
            // ViewThatFits keeps the last (title-less) candidate once nothing fits.
            ViewThatFits(in: .horizontal) {
                identityRow(showTitle: true)
                identityRow(showTitle: false)
            }
        }
        .padding(.trailing, 8)
    }

    /// Icon + optional "Tenon" wordmark, with the sidebar toggle pinned to the right.
    private func identityRow(showTitle: Bool) -> some View {
        HStack(spacing: 8) {
            (AppMark.image.map { Image(nsImage: $0) } ?? Image(systemName: "terminal.fill"))
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(TenonTheme.text)
                .accessibilityHidden(true)

            if showTitle {
                Text("Tenon")
                    .font(TenonTheme.interfaceFont(size: 13, weight: .bold))
                    .foregroundStyle(TenonTheme.text)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 6)

            // T-029: how many panes across the whole catalog await a human. The one
            // machine's rollup — hidden entirely while nothing needs attention.
            if totalUnseen > 0 {
                Text("\(totalUnseen)")
                    .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                    .foregroundStyle(TenonTheme.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TenonTheme.amber))
                    .help("\(totalUnseen) pane(s) finished and are waiting for you")
                    .accessibilityIdentifier("tenon.unseenCount")
            }

            ShellIconButton(
                symbol: sidebarVisible ? "sidebar.left" : "sidebar.leading",
                help: sidebarVisible ? "Collapse sidebar" : "Expand sidebar",
                action: onToggleSidebar
            )
            .accessibilityIdentifier("tenon.toggleSidebar")
        }
    }

    /// The tab anchor's concrete launcher view. Keeping this construction outside the
    /// strip's large result builder also gives the compiler one bounded expression to
    /// solve while preserving the exact LauncherMenu used by the `+` anchor.
    private func tabLauncher(for tab: TenonCore.Tab) -> LauncherMenu {
        LauncherMenu(
            host: host,
            intentRuntime: intentRuntime,
            palette: palette,
            agentSuggestions: agentSuggestions,
            launchAgent: { suggestion in
                AgentLaunchExecutor.run(
                    suggestion,
                    placement: .tab(tab.id),
                    workspaceStore: store,
                    terminalPool: pool
                )
            },
            copyTabID: { WorkspaceIdentifierClipboard.copy(tab.id) },
            paneArrangements: arrangements(for: tab),
            arrangePanes: { preset in
                if store.catalog.activeTab?.id != tab.id {
                    store.selectTab(tab.id)
                }
                store.arrangeActiveTab(preset)
            },
            send: { invocation in
                await send(invocation, onTab: tab.id)
            },
            dismiss: { contextLauncherTab = nil }
        )
    }

    /// One chip, with everything the strip needs back from it: the two frames it reports, and
    /// the launcher its secondary click opens. Kept out of the row's result builder so the
    /// compiler has one bounded expression to solve per chip rather than one for the strip.
    @ViewBuilder
    private func chipView(for tab: TenonCore.Tab, at index: Int) -> some View {
        let title = tabTitle(for: tab)
        TabChip(
            title: title,
            isActive: tab.id == activeWorkspace?.activeTabID,
            position: index,
            tabCount: activeTabs.count,
            isDragging: tabDrag?.tabID == tab.id,
            move: { destination in moveTab(tab.id, to: destination) },
            attentionState: PaneAttentionProjection.tabState(
                for: tab,
                attention: pool.paneAttention
            ),
            isUnseen: PaneAttentionProjection.tabIsUnseen(
                tab,
                attention: pool.paneAttention
            ),
            canClose: canCloseTabs,
            isHovered: hoveredTab == tab.id,
            reportCloseExtent: { closeExtents[tab.id] = $0 },
            isDropTarget: router.activeDropTarget == .existingTab(tab.id),
            select: { store.selectTab(tab.id) },
            close: { requestClose(tab, title: title) },
            openLauncher: { contextLauncherTab = tab.id },
            copyID: { WorkspaceIdentifierClipboard.copy(tab.id) }
        )
        // Report the chip's window-space frame so a pane dragged up from the canvas can be
        // hit-tested against it.
        .background(WindowFrameReporter { router.tabChipFrames[tab.id] = $0 })
        // …and its extent in the strip's own space, which is what a reorder measures
        // against (T-096).
        .background(TabChipExtentReporter { chipExtents[tab.id] = $0 })
        // Right-click opens the exact launcher the `+` button opens — one catalog and one
        // presentation — scoped to this chip's tab.
        .popover(
            isPresented: Binding(
                get: { contextLauncherTab == tab.id },
                set: { if !$0 { contextLauncherTab = nil } }
            ),
            arrowEdge: .bottom
        ) {
            tabLauncher(for: tab)
        }
    }

    private var rightZone: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: TabStripSpace.spacing) {
                    chipRow
                    newTabButton
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                tabStripWidth = width
                            }
                    }
                )
            }
            .tenonScrollbarStyle()
            .scrollIndicators(.hidden)
            // The strip claims only the width its chips need; everything past them
            // goes to the drag surface, so the empty stretch of the row drags and
            // double-clicks like a system title bar instead of dead-ending in the
            // scroll view. The priority keeps the strip served first, so it still
            // takes the whole side (and scrolls) once the chips outgrow it.
            .frame(maxWidth: max(tabStripWidth, 1))
            .layoutPriority(1)

            WindowDragArea(color: TenonTheme.chromeNS)
                .frame(maxWidth: .infinity)

            if let resourceMonitor {
                // Host chrome, not `WorkspaceStatusBar`: that strip is a closed
                // plugin-contribution surface and a host control in it would end the promise
                // it makes. The July design said "before Add Slot"; the title bar has no Add
                // Slot control any more, so this sits before the trailing host control that
                // does exist.
                ResourceMonitorButton(
                    model: resourceMonitor,
                    isCompact: tabStripWidth > Self.compactResourceSummaryWidth
                )
                .padding(.leading, 8)
                .accessibilityIdentifier("tenon.resourceMonitor.trigger")
            }

            QuickCommandControl(
                commands: quickCommands,
                workspaceStore: store,
                terminalPool: pool
            )
            .padding(.leading, 8)
            .accessibilityIdentifier("tenon.quickCommands.control")
        }
        // The whole strip is the "drop for a new tab" band; individual chips
        // carve out "drop into that tab" within it.
        .background(WindowFrameReporter { router.tabBarBand = $0 })
        .padding(.horizontal, 8)
        // Drop frames for tabs that have closed so a stale rect never claims a drop.
        .onChange(of: activeTabs.map(\.id)) { _, ids in
            router.tabChipFrames = router.tabChipFrames.filter { ids.contains($0.key) }
            chipExtents = chipExtents.filter { ids.contains($0.key) }
            closeExtents = closeExtents.filter { ids.contains($0.key) }
        }
    }

    /// The chips, and only the chips — the exact region the strip's surface takes from the
    /// window server. The `+` beside it is a control of its own and keeps its own click, so
    /// the surface stops where the last chip does.
    private var chipRow: some View {
        HStack(spacing: TabStripSpace.spacing) {
            ForEach(Array(activeTabs.enumerated()), id: \.element.id) { index, tab in
                chipView(for: tab, at: index)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, height in
                        stripHeight = height
                    }
            }
        )
        .coordinateSpace(name: TabStripSpace.name)
        // In front of the chips, and never conditionally: a point in the title-bar band that
        // resolves to a SwiftUI view is a point where the window server moves the window. The
        // chips' region owns every pointer inside it — six points of travel reorder, a shorter
        // press selects or closes, and the pointer at rest lights a chip.
        .overlay(
            TabStripSurface(
                began: beginReorder,
                changed: updateReorder,
                ended: endReorder,
                cancelled: { tabDrag = nil },
                pressed: pressStrip,
                hovered: hoverStrip
            )
        )
    }

    /// The `+`, outside the surface: a press here opens the launcher, and a drag here moves
    /// the window, exactly as a drag on the identity zone beside it does.
    private var newTabButton: some View {
        ShellIconButton(symbol: "plus", help: "Open something new") {
            launcherPresented = true
        }
        .accessibilityIdentifier("tenon.newTab")
        .overlay {
            if router.activeDropTarget == .newTab {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TenonTheme.amber, lineWidth: 1.5)
            }
        }
        .popover(isPresented: $launcherPresented, arrowEdge: .bottom) {
            LauncherMenu(
                host: host,
                intentRuntime: intentRuntime,
                palette: palette,
                agentSuggestions: agentSuggestions,
                launchAgent: { suggestion in
                    AgentLaunchExecutor.run(
                        suggestion,
                        placement: .newTab,
                        workspaceStore: store,
                        terminalPool: pool
                    )
                },
                paneArrangements: activeWorkspace?.activeTab.map {
                    arrangements(for: $0)
                } ?? [],
                arrangePanes: { preset in store.arrangeActiveTab(preset) },
                send: { invocation in
                    await sendInNewTab(invocation)
                },
                dismiss: { launcherPresented = false }
            )
        }
    }

    // MARK: - Derived state  @domain: workspace-model

    private var activeWorkspace: Workspace? {
        store.catalog.activeWorkspace
    }

    private func arrangements(for tab: TenonCore.Tab) -> [PaneArrangementPreset] {
        PaneArrangement.availablePresets(
            for: tab.spatialSlots,
            mainSlotID: tab.activeSlotID
        )
    }

    private var totalUnseen: Int {
        PaneAttentionProjection.totalUnseen(
            catalog: store.catalog,
            attention: pool.paneAttention
        )
    }

    private var activeTabs: [TenonCore.Tab] {
        activeWorkspace?.tabs ?? []
    }

    /// What a chip says: the terminal's own title, or the tab's number until it has one.
    ///
    /// The number is the tab's, not its place in the strip. Numbering by position made the
    /// reorder invisible — drag one unnamed tab past another and the chips swap while the
    /// labels swap back, so the strip reads exactly as it did before the drag (T-105).
    private func tabTitle(for tab: TenonCore.Tab) -> String {
        if let customTitle = tab.activeSlot?.customTitle {
            return customTitle
        }
        let terminalTitle = pool.title(for: tab)
        if terminalTitle != "Terminal" {
            return terminalTitle
        }
        return "Terminal \(tab.number)"
    }
}

/// One clipboard spelling for workspace entity identities. Menus copy the raw UUID because
/// it can be pasted directly into `tenon-cli --tab` or `--pane`; labels and prefixes belong
/// to the surrounding prose, not to the address itself.
@MainActor
enum WorkspaceIdentifierClipboard {
    @discardableResult
    static func copy(
        _ id: UUID,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(id.uuidString, forType: .string)
    }
}

struct TabChip: View {
    let title: String
    let isActive: Bool
    /// Where this chip sits in the strip, and how long the strip is. Spoken, and the origin
    /// every VoiceOver move counts from (T-096).
    let position: Int
    let tabCount: Int
    /// T-096: this chip is the one the pointer is holding, so it reads as lifted out of the row
    /// it is travelling through.
    var isDragging: Bool = false
    /// Move this tab to an index in the strip. The strip owns the mutation and the spoken
    /// announcement; the chip only names the destination.
    var move: (Int) -> Void = { _ in }
    /// T-029: the active slot's `PaneActivity` state — `nil` (no dot) while none of
    /// the tab's panes ever materialised.
    var attentionState: PaneActivityState?
    /// T-029: bold while any pane in this tab finished (or died) unviewed.
    var isUnseen: Bool = false
    let canClose: Bool
    /// Whether the pointer is resting on this chip. Supplied by the strip, because the strip's
    /// surface is what the pointer actually reaches — a chip inside the title-bar band that
    /// waited to notice a pointer itself would be waiting on events the window server took.
    var isHovered: Bool = false
    /// Where this chip drew its close control, in the strip's own space. The strip owns the
    /// primary-button stream, so this is how it knows a click landed on the ✕ rather than on
    /// the tab: from the control that drew itself, never from a copy of its layout.
    var reportCloseExtent: (ClosedRange<CGFloat>) -> Void = { _ in }
    var isDropTarget: Bool = false
    let select: () -> Void
    let close: () -> Void
    /// A right-click (or control-click) asks the owner to open the same `LauncherMenu`
    /// popover as the `+` button, already scoped to this chip's tab.
    let openLauncher: () -> Void
    /// Copies the stable tab address, supplied by the owner that has the tab value.
    var copyID: () -> Void = {}

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isActive ? TenonTheme.amber : TenonTheme.muted)
                    .accessibilityHidden(true)
                if let attentionState {
                    TabAttentionDot(state: attentionState)
                }
                Text(title)
                    .fontWeight(isUnseen ? .bold : .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }
            .font(TenonTheme.interfaceFont(size: 10, weight: .medium))
            .padding(.leading, 9)
            .padding(.trailing, canClose ? 28 : 9)
            // Content sizes the chip between its floor and the title's own cap, so a
            // one-word title still yields a chip you can read and aim at.
            .frame(minWidth: TenonTheme.tabMinWidth, alignment: .leading)
            .frame(height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActive
                        ? Color.primary.opacity(0.09)
                        : (isHovered ? Color.primary.opacity(0.04) : .clear)
                )
        }
        .overlay(alignment: .trailing) {
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(TenonTheme.muted)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .accessibilityLabel("Close \(title)")
                .background(TabChipExtentReporter(report: reportCloseExtent))
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(TenonTheme.amber, lineWidth: 1.5)
            }
        }
        // Dimmed, and left exactly where the row puts it: the chip travels by changing places
        // with its neighbours, not by following the pointer. Offsetting it would make the
        // extent it reports chase the pointer that is measured against that extent.
        .opacity(isDragging ? 0.5 : 1)
        .overlay(RightClickCatcher(action: openLauncher))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tenon.tab")
        .accessibilityLabel(title)
        .accessibilityValue(
            TabReorder.spokenPosition(position, of: tabCount, isActive: isActive)
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // A pointer drag is unreachable by keyboard and by VoiceOver, so reordering is
        // offered here as well — never only as a drag. The ends publish no action rather
        // than publishing one that does nothing.
        .accessibilityActions {
            if position > 0 {
                Button("Move tab left") { move(position - 1) }
            }
            if position < tabCount - 1 {
                Button("Move tab right") { move(position + 1) }
            }
            Button("Open launcher") { openLauncher() }
            Button("Copy Tab ID") { copyID() }
        }
    }
}

/// An invisible AppKit observer that turns a right-click (or control-click) into an action.
/// Its view never participates in hit-testing: left clicks, the close button, hover, and
/// the strip's reorder drag stay wholly inside SwiftUI.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var action: () -> Void
        private weak var view: CatcherView?
        private var eventMonitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach(to view: CatcherView) {
            detach()
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                guard let self, self.contains(event) else { return event }
                self.action()
                return nil
            }
        }

        func detach() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            view = nil
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard event.type == .rightMouseDown
                    || (event.type == .leftMouseDown
                        && event.modifierFlags.contains(.control)),
                  let view,
                  event.window === view.window
            else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }

    final class CatcherView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The tab strip's own AppKit view: the one owner of every pointer that enters the strip.
///
/// The strip is drawn up into the window's title-bar band, where the window server — not this
/// app — takes a travelling press, from a drag region AppKit computed before the press ever
/// happened. Getting the chips out of that region is `SurfaceView`'s job and the reason it is
/// an `NSControl`; the note on that class has the measurement.
///
/// Being out of the region is necessary and not sufficient: the press still has to *arrive*,
/// which means being the hit-test result. Three arrangements were measured, and only the third
/// is both:
///
/// - a `.background` observer is never the hit at all — SwiftUI resolves the point to the
///   chip in front of it and returns its own container;
/// - an `.overlay` that claims the point *only while a primary-button event is dispatching*
///   is not the hit view at every other moment, and a drag the app never receives is one it
///   cannot claim retroactively;
/// - an `.overlay` that claims unconditionally is the hit view, always.
///
/// Claiming the pointer means owning what was taken: the click that selects a tab or closes
/// it, and the hover that highlights one. Secondary click is untouched — `RightClickCatcher`
/// watches the event stream through a local monitor rather than through hit-testing — and
/// accessibility is untouched, because activation there never goes through a hit test.
struct TabStripSurface: NSViewRepresentable {
    /// How far the pointer travels before a press stops being a click and becomes a reorder.
    static let reorderThreshold: CGFloat = 6

    let began: (CGPoint) -> Void
    let changed: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    let pressed: (CGPoint) -> Void
    /// Where the pointer is resting, or `nil` once it has left the strip.
    let hovered: (CGPoint?) -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        apply(to: view)
    }

    /// SwiftUI calls this from inside its own graph teardown, so the release lands on the next
    /// turn of the run loop. Writing `@State` while `GraphHost.invalidate()` is running is not
    /// a late update — it is a fatal exclusivity violation, and the strip took one every time
    /// it was dismantled mid-hover.
    static func dismantleNSView(_ view: SurfaceView, coordinator: ()) {
        let hovered = view.hovered
        let cancelled = view.cancelled
        let wasDragging = view.releaseDrag()
        DispatchQueue.main.async {
            hovered(nil)
            if wasDragging { cancelled() }
        }
    }

    private func apply(to view: SurfaceView) {
        view.began = began
        view.changed = changed
        view.ended = ended
        view.cancelled = cancelled
        view.pressed = pressed
        view.hovered = hovered
    }

    /// An `NSControl` that accepts first responder — both halves, or the window moves.
    ///
    /// AppKit does not ask this view anything when a press lands. It computes the window's
    /// drag region ahead of time, uploads it to the window server, and the server starts the
    /// move on its own — which is why hit-testing, event delivery, and the reorder rules were
    /// all correct while a human drag still moved the window. `mouseDownCanMoveWindow`
    /// answers that region builder, and the builder honours a `false` only from an `NSControl`
    /// descendant **that accepts first responder**: that is how AppKit tells a control apart
    /// from chrome, and why the traffic lights (`_NSThemeWidget`, an `NSButton`) are the one
    /// hole in the baseline region.
    ///
    /// Measured through `NSWindow._lastDragRegionDataDescription`, with the close button and
    /// the empty chrome as the two-sided oracle, chrome unchanged throughout: as an `NSView`
    /// the chips are inside the region; as an `NSControl` they are outside it; as an
    /// `NSControl` answering `acceptsFirstResponder == false` they are **inside it again**.
    /// The strip shipped that third shape for a day and the original symptom came back whole,
    /// so the property is left at `NSControl`'s own answer and overridden nowhere.
    ///
    /// The keyboard the override was protecting is protected by the mouse path instead:
    /// nothing here calls `super`, so cell tracking never runs, the cell is never created, and
    /// no `makeFirstResponder` is ever issued — AppKit focuses no view on a press by itself.
    final class SurfaceView: NSControl {
        var began: (CGPoint) -> Void = { _ in }
        var changed: (CGPoint) -> Void = { _ in }
        var ended: (CGPoint) -> Void = { _ in }
        var cancelled: () -> Void = {}
        var pressed: (CGPoint) -> Void = { _ in }
        var hovered: (CGPoint?) -> Void = { _ in }

        private var start: CGPoint?
        private var isDragging = false
        private var tracking: NSTrackingArea?

        /// The strip reports its chips with SwiftUI's downward y, and one rule reads both, so
        /// this view counts y the same way rather than converting between them.
        override var isFlipped: Bool { true }

        /// Read by the drag-region builder, not by anything at press time: this is what keeps
        /// the chips out of the region the window server moves the window from.
        override var mouseDownCanMoveWindow: Bool { false }

        /// A tab answers the first click into an unfocused window, as the rest of the title
        /// bar does.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// `acceptsFirstResponder` is deliberately left at `NSControl`'s own answer, and that
        /// is load-bearing: the drag-region builder carves out a control that accepts first
        /// responder and leaves one that refuses inside the region. Answering `false` here —
        /// which this view did, to hand the keyboard back to the terminal — put every chip
        /// back under the window server and returned the original symptom whole.
        ///
        /// The keyboard is safe without it, measured rather than assumed: AppKit focuses no
        /// view on a press by itself, only a control that calls `makeFirstResponder` from its
        /// own mouse path, and nothing here calls `super`. A click on a tab leaves the
        /// terminal holding first responder, which is what
        /// `testStripSurfaceNeverTakesKeyboardFocusFromTheTerminal` now drives and asserts.

        /// Out of the Tab key-view loop, which a chip strip has no business being a stop in —
        /// and this one *is* safe to say, measured on the same two-sided oracle: refusing the
        /// key view loop leaves the view outside the drag region, where refusing first
        /// responder does not.
        override var canBecomeKeyView: Bool { false }

        /// `hitTest` is deliberately not overridden: staying out of the drag region only
        /// means the app *may* have the press, and it arrives at whichever view answers the
        /// hit test. The inherited behaviour already answers `self` for every point inside
        /// the strip, which is exactly the claim this view needs.

        // MARK: Hover  @domain: workspace-model

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovered(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            hovered(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            hovered(nil)
        }

        // MARK: The primary-button stream  @domain: workspace-model

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            if !isDragging {
                let travel = hypot(point.x - start.x, point.y - start.y)
                guard travel >= TabStripSurface.reorderThreshold else { return }
                isDragging = true
                began(start)
            }
            changed(point)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if releaseDrag() {
                ended(point)
            } else {
                pressed(point)
            }
        }

        /// Drops a live drag and says whether there was one. Both endings go through here —
        /// the release, and a view going away with the strip rebuilt or the window closed —
        /// so a tab is never left held by a drag that is over. Telling SwiftUI about it is
        /// the caller's job, because the timing differs between the two.
        func releaseDrag() -> Bool {
            let wasDragging = isDragging
            isDragging = false
            start = nil
            return wasDragging
        }

        // MARK: Accessibility  @domain: workspace-model

        /// Taking the pointer must not take the accessibility tree with it: assistive
        /// technology keeps finding the chips themselves, which publish the labels, the
        /// spoken position, and the move actions.
        override func isAccessibilityElement() -> Bool { false }

        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
    }
}

/// The tab strip's own coordinate space, and the one gap between its chips. Chip extents
/// and the reorder pointer are both read in this space, so a reorder compares two numbers
/// from one space and never converts between them.
enum TabStripSpace {
    static let name = "tenon.tabStrip"
    static let spacing: CGFloat = 3
}

/// A chip's own report of where it ended up along the strip.
///
/// It goes in a `.background` so the chip's button, close control, and right-click catcher
/// keep every event, and it reads the *laid-out* frame rather than an ideal size — a chip's
/// close control is an overlay, so what a chip would like to be and what it occupies are
/// different numbers, and a reorder measured with the first moves tabs against a row that is
/// not there. The dragged chip is deliberately never offset, so this reading cannot chase the
/// pointer that is measured against it — which matters more now that each move re-lays the
/// chips the next pointer position is read against.
struct TabChipExtentReporter: View {
    let report: (ClosedRange<CGFloat>) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear.onChange(
                of: proxy.frame(in: .named(TabStripSpace.name)),
                initial: true
            ) { _, frame in
                report(frame.minX ... max(frame.minX, frame.maxX))
            }
        }
    }
}

/// One live reorder: which tab was picked up, and the place it was picked up from.
///
/// Identity, not index, for the tab — the strip reorders underneath a VoiceOver move while a
/// pointer drag is impossible, and naming the tab keeps that true by construction. The origin
/// is an index because that is what putting the row back needs, and it is read only by the
/// release that refuses.
private struct TabStripDrag: Equatable {
    let tabID: UUID
    let originIndex: Int
}

/// Says a completed reorder out loud.
///
/// VoiceOver has no way to notice that a chip changed places in a strip it is not focused
/// on: the move produces no focus change and no new element. Without this, the drag and the
/// custom action are both silent, and the person who most needs the confirmation is the one
/// who cannot see it.
enum ReorderAnnouncer {
    @MainActor
    static func say(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// A tab's attention state, said out loud and — when the system asks for it — drawn as a shape
/// rather than a hue.
///
/// The dot is the entire signal on this surface. Colour alone excludes anyone who cannot
/// separate these hues and anyone reading the window through VoiceOver, so the state travels
/// as a spoken value always, and as a glyph whenever Differentiate Without Color is on.
private struct TabAttentionDot: View {
    let state: PaneActivityState

    var body: some View {
        Group {
            if PaneAttentionProjection.differentiatesWithoutColor {
                Image(systemName: PaneAttentionProjection.symbolName(for: state))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(
                        Color(nsColor: PaneAttentionProjection.dotColor(for: state))
                    )
            } else {
                Circle()
                    .fill(Color(nsColor: PaneAttentionProjection.dotColor(for: state)))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityIdentifier("tenon.tabAttentionDot")
        .accessibilityLabel("Activity")
        .accessibilityValue(PaneAttentionProjection.spokenState(for: state))
    }
}

private struct ShellIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TenonTheme.muted)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        // An icon-only control carries no text for VoiceOver to read. The tooltip is
        // already the sentence a person would say about it, so it is also the label.
        .accessibilityLabel(help)
    }
}
