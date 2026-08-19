// @domain: workspace-model
import SwiftUI
import TenonCore

/// One density budget for the full workspace sidebar and its persistent icon rail.
enum WorkspaceSidebarLayout {
    static let expandedHorizontalInset: CGFloat = 7
    static let collapsedHorizontalInset: CGFloat = 5
    static let reorderThreshold: CGFloat = 6
    static let reorderAnimation: Animation = .easeInOut(duration: 0.12)

    static var collapsedRowWidth: CGFloat {
        SidebarResize.collapsedWidth - collapsedHorizontalInset * 2
    }

    /// The width the collapsed rail leaves a mark, so the row it fills is a square there
    /// rather than a stripe. The expanded row takes the same height, where it is
    /// `designs.md`'s two-line utility row — a name over a tab count, contracted at 36–40 pt.
    static var rowHeight: CGFloat { collapsedRowWidth }
}

/// The left navigation column: one row per workspace and a contextual recent-workspace
/// library in the empty area around those rows. Collapsing preserves the marks as a compact
/// rail instead of removing navigation from the window.
// MARK: - Sidebar composition  @domain: workspace-model

struct WorkspaceSidebarView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    /// Which panes an agent occupies, for every workspace at once. Optional because the
    /// sidebar is mounted in snapshots and previews that compose no hook server; a row with
    /// no roster falls back to its tab count, which is what a workspace with no agent shows
    /// anyway.
    var agentPanes: AgentPaneRoster?
    var isCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            // The workspace rows read `store.catalog`, so they must re-render on every
            // tab/slot change. The contextual library therefore lives with that isolated
            // list instead of making the full sidebar depend on the catalog.
            WorkspaceFolderDropZone(store: store) {
                // Sized inside the drop zone, so a column holding two workspaces still
                // takes a folder anywhere below them rather than only over the rows.
                WorkspaceRowList(
                    store: store,
                    pool: pool,
                    closeCoordinator: closeCoordinator,
                    agentPanes: agentPanes,
                    isCollapsed: isCollapsed
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }

            SidebarFooter(isCollapsed: isCollapsed)
        }
        .background(TenonTheme.chrome)
        .overlay(alignment: .trailing) {
            if isCollapsed {
                Rectangle()
                    .fill(TenonTheme.line)
                    .frame(width: 1)
            }
        }
    }

}

/// The scrollable list of workspace rows and the contextual library's click target. Row
/// frames keep each workspace's own Customise/Remove menu independent from the empty-area
/// recent-workspace surface.
// MARK: - Reorderable workspace list  @domain: workspace-model

private struct WorkspaceRowList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    var agentPanes: AgentPaneRoster?
    let isCollapsed: Bool

    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var contextPoint = CGPoint(x: 1, y: 1)
    @State private var isRecentMenuPresented = false
    @State private var workspaceDrag: WorkspaceSidebarDrag?

    var body: some View {
        ScrollView {
            // Workspace order needs every row's midpoint, including rows beyond the current
            // scroll viewport. Catalogs are human-scale, so laying out this short navigation
            // list eagerly keeps reorder complete without making a second geometry model.
            VStack(spacing: 3) {
                ForEach(Array(store.catalog.workspaces.enumerated()), id: \.element.id) {
                    index, workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        store: store,
                        isActive: workspace.id == store.catalog.activeWorkspaceID,
                        position: index,
                        workspaceCount: store.catalog.workspaces.count,
                        isDragging: workspaceDrag?.workspaceID == workspace.id,
                        move: { destination in
                            moveWorkspace(workspace.id, to: destination)
                        },
                        // T-029: this row's rollup of the one attention machine.
                        // Read here, inside the row list, so the open context menu
                        // above never re-lays-out on attention churn.
                        unseenCount: PaneAttentionProjection.unseenCount(
                            in: workspace,
                            attention: pool.paneAttention
                        ),
                        // T-178: the same read, one level finer — which panes, not how
                        // many. Joined here beside the rollup for the same reason.
                        agentEntries: agentEntries(in: workspace),
                        canRemove: store.catalog.workspaces.count > 1,
                        select: { store.selectWorkspace(workspace.id) },
                        removal: WorkspaceRemovalAction(
                            workspace: workspace,
                            coordinator: closeCoordinator
                        ),
                        isCollapsed: isCollapsed
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: WorkspaceRowFramesPreferenceKey.self,
                                value: [
                                    workspace.id: proxy.frame(
                                        in: .named("tenon.workspaceSidebarContext")
                                    ),
                                ]
                            )
                        }
                    }
                    .simultaneousGesture(reorderGesture(for: workspace.id))
                }
            }
            .padding(
                .horizontal,
                isCollapsed
                    ? WorkspaceSidebarLayout.collapsedHorizontalInset
                    : WorkspaceSidebarLayout.expandedHorizontalInset
            )
            .padding(.top, 8)
        }
        .tenonScrollbarStyle()
        .scrollIndicators(.hidden)
        .coordinateSpace(.named("tenon.workspaceSidebarContext"))
        .onPreferenceChange(WorkspaceRowFramesPreferenceKey.self) { rowFrames = $0 }
        .overlay {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(isPresented: $isRecentMenuPresented, arrowEdge: .leading) {
                        WorkspaceRecentMenu(
                            store: store,
                            dismiss: { isRecentMenuPresented = false }
                        )
                    }
                    .allowsHitTesting(false)
                    // Attach the popover while this source is still 1×1. `position`
                    // returns a view with the sidebar's full proposal, so attaching after
                    // it anchors to the middle of the sidebar instead of the click.
                    .position(contextPoint)

                SidebarContextClickCatcher { point in
                    guard !rowFrames.values.contains(where: { $0.contains(point) }) else {
                        return false
                    }
                    contextPoint = CGPoint(x: max(1, point.x), y: max(1, point.y))
                    isRecentMenuPresented = true
                    return true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// This workspace's agent panes, joined from the three registries that each hold one part
    /// of the answer: the roster says which panes an agent is in, `SurfacePool` says which
    /// incarnation of each pane is mounted and what it is currently called, and the attention
    /// machine says what each one is doing. All three cover every workspace, not just the
    /// selected one, which is what lets a background row say anything at all.
    private func agentEntries(in workspace: Workspace) -> [WorkspaceAgentTagline.Entry] {
        guard let agentPanes else { return [] }
        let tokens = workspace.tabs.reduce(into: [UUID: UUID]()) { tokens, tab in
            for slot in tab.slots {
                tokens[slot.id] = pool.surfaceToken(for: slot.id)
            }
        }
        return WorkspaceAgentTagline.entries(
            in: workspace,
            agentPanes: agentPanes.panes(matching: tokens),
            titles: pool.titles,
            attention: pool.paneAttention
        )
    }

    private var rowStrip: [WorkspaceRowExtent] {
        store.catalog.workspaces.compactMap { workspace in
            rowFrames[workspace.id].map {
                WorkspaceRowExtent(
                    id: workspace.id,
                    minY: Double($0.minY),
                    maxY: Double($0.maxY)
                )
            }
        }
    }

    private var horizontalBand: ClosedRange<Double>? {
        let frames = store.catalog.workspaces.compactMap { rowFrames[$0.id] }
        guard frames.count == store.catalog.workspaces.count,
              let minX = frames.map(\.minX).min(),
              let maxX = frames.map(\.maxX).max()
        else { return nil }
        return Double(minX) ... Double(maxX)
    }

    private func reorderGesture(for workspaceID: UUID) -> some Gesture {
        DragGesture(
            minimumDistance: WorkspaceSidebarLayout.reorderThreshold,
            coordinateSpace: .named("tenon.workspaceSidebarContext")
        )
        .onChanged { updateReorder(workspaceID, at: $0.location) }
        .onEnded { endReorder(workspaceID, at: $0.location) }
    }

    private func updateReorder(_ workspaceID: UUID, at point: CGPoint) {
        let workspaces = store.catalog.workspaces
        let rows = rowStrip
        guard rows.count == workspaces.count, let band = horizontalBand else { return }

        if workspaceDrag == nil {
            guard let origin = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return
            }
            workspaceDrag = WorkspaceSidebarDrag(
                workspaceID: workspaceID,
                originIndex: origin
            )
        }

        guard workspaceDrag?.workspaceID == workspaceID,
              WorkspaceReorder.admitsDrop(
                  pointerX: Double(point.x),
                  minX: band.lowerBound,
                  maxX: band.upperBound
              ),
              let destination = WorkspaceReorder.destination(
                  forWorkspace: workspaceID,
                  insertingAt: WorkspaceReorder.insertionIndex(
                      at: Double(point.y),
                      rows: rows
                  ),
                  rows: rows
              )
        else { return }

        withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
            store.moveWorkspace(workspaceID, to: destination)
        }
    }

    private func endReorder(_ workspaceID: UUID, at point: CGPoint) {
        guard let drag = workspaceDrag, drag.workspaceID == workspaceID else { return }
        workspaceDrag = nil
        guard let band = horizontalBand,
              WorkspaceReorder.admitsDrop(
                  pointerX: Double(point.x),
                  minX: band.lowerBound,
                  maxX: band.upperBound
              )
        else {
            restore(drag)
            return
        }
        announceLanding(of: drag)
    }

    private func restore(_ drag: WorkspaceSidebarDrag) {
        withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
            store.moveWorkspace(drag.workspaceID, to: drag.originIndex)
        }
    }

    private func announceLanding(of drag: WorkspaceSidebarDrag) {
        let workspaces = store.catalog.workspaces
        guard let index = workspaces.firstIndex(where: { $0.id == drag.workspaceID }),
              index != drag.originIndex
        else { return }
        ReorderAnnouncer.say(
            WorkspaceReorder.announcement(
                name: workspaces[index].name,
                movedTo: index,
                of: workspaces.count
            )
        )
    }

    private func moveWorkspace(_ workspaceID: UUID, to destination: Int) {
        let workspaces = store.catalog.workspaces
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              destination >= 0,
              destination < workspaces.count,
              destination != index
        else { return }
        let name = workspaces[index].name
        withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
            store.moveWorkspace(workspaceID, to: destination)
        }
        ReorderAnnouncer.say(
            WorkspaceReorder.announcement(
                name: name,
                movedTo: destination,
                of: workspaces.count
            )
        )
    }
}

private struct WorkspaceSidebarDrag {
    let workspaceID: UUID
    let originIndex: Int
}

/// The typed adapter behind the sidebar's destructive menu item. Keeping the task launch in
/// this value makes the production gesture behaviorally testable without reaching through a
/// SwiftUI context menu by source-text inspection.
// MARK: - Row actions  @domain: workspace-model

@MainActor
struct WorkspaceRemovalAction {
    let workspace: Workspace
    let coordinator: ShellCloseCoordinator

    @discardableResult
    func perform() -> Task<Void, Never> {
        Task { @MainActor in
            await coordinator.requestClose(workspace)
        }
    }
}

// MARK: - Workspace row  @domain: workspace-model

/// The row's two on-demand surfaces — the agent list and the customisation form — share one
/// anchor and one piece of state. SwiftUI drives at most one active `.popover` per view; two
/// independent `isPresented` bindings on the same button raced each other for it instead of
/// taking turns, which is what made the rail's popover feel like it was fighting itself on
/// every hover.
private struct WorkspaceRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let workspace: Workspace
    /// T-097: the customisation popover writes straight through to the typed workspace
    /// service, so the row hands it the store rather than a fourth closure.
    var store: WorkspaceStore
    let isActive: Bool
    let position: Int
    let workspaceCount: Int
    let isDragging: Bool
    let move: (Int) -> Void
    /// T-029: how many of this workspace's panes finished (or died) unviewed.
    /// The row bolds and counts while it is non-zero; viewing clears it upstream.
    let unseenCount: Int
    /// T-178: the agent panes this workspace holds, in the order the line names them.
    let agentEntries: [WorkspaceAgentTagline.Entry]
    let canRemove: Bool
    let select: () -> Void
    let removal: WorkspaceRemovalAction
    let isCollapsed: Bool

    @State private var isHovering = false
    @State private var isCustomizing = false
    /// Whether this row's account is showing, under the line it belongs to. Only
    /// `accountToggle` changes it now — a hover used to, and closing the moment the pointer
    /// reached a neighbouring row moved that row's own click target out from under a pointer
    /// already committed to landing on it, so a click meant for the next workspace missed.
    /// Pinned instead: it stays exactly as the operator left it, whether or not this
    /// workspace is the selected one.
    @State private var isShowingAgentsInline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if !isCollapsed, isShowingAgentsInline {
                agentList
            }
        }
    }

    private var rowContent: some View {
        Group {
            if isCollapsed {
                collapsedMark
            } else {
                expandedRow
            }
        }
        .opacity(isDragging ? 0.5 : 1)
        .onHover { isHovering = $0 }
        // An agent that finishes or exits while the account is open leaves it; an account
        // naming nobody would sit under the line with nothing in it.
        .onChange(of: agentEntries.isEmpty) { _, isEmpty in
            if isEmpty {
                withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
                    isShowingAgentsInline = false
                }
            }
        }
        .help(workspace.name)
        .contextMenu {
            // The rail has no room for the disclosure toggle, so its context menu is the
            // only way to reach a rail row's panes without returning to the expanded
            // width. An expanded row already names them inline — the toggle's account, or
            // the still line itself — so repeating them here would only duplicate that list.
            if isCollapsed {
                ForEach(agentEntries) { entry in
                    Button(entry.title) { store.focusSlot(entry.slotID) }
                }
                if !agentEntries.isEmpty {
                    Divider()
                }
            }
            Button("Customise Workspace…") { isCustomizing = true }
            Button("Remove Workspace", role: .destructive) { removal.perform() }
                .disabled(!canRemove)
        }
        .popover(isPresented: $isCustomizing, arrowEdge: .trailing) {
            WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: { isCustomizing = false }
            )
        }
    }

    private var collapsedMark: some View {
        rowAccessibility(
            Button(action: select) {
                WorkspaceMark(workspace: workspace, size: 20)
                    .frame(width: 29, height: 29)
                    .overlay(alignment: .topTrailing) {
                        if unseenCount > 0 {
                            Circle()
                                .fill(TenonTheme.amber)
                                .frame(width: 7, height: 7)
                                .overlay {
                                    Circle()
                                        .stroke(TenonTheme.chrome, lineWidth: 1)
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: WorkspaceSidebarLayout.rowHeight)
                    .background { rowBackground }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        )
    }

    /// The row's own click target and the disclosure toggle sit side by side as two buttons,
    /// not one nested in the other's label: a button nested in a button's label only ever
    /// fires the outer one, and the toggle's whole point is that clicking it must not select
    /// the workspace underneath it.
    private var expandedRow: some View {
        HStack(spacing: 8) {
            rowAccessibility(
                Button(action: select) {
                    HStack(spacing: 8) {
                        WorkspaceMark(workspace: workspace, size: 20)
                            .frame(width: 29, height: 29)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(
                                    TenonTheme.interfaceFont(
                                        size: 11,
                                        weight: unseenCount > 0 ? .bold : .semibold
                                    )
                                )
                                .foregroundStyle(isActive ? TenonTheme.text : TenonTheme.muted)
                                .lineLimit(1)
                            WorkspaceAgentTaglineView(
                                entries: agentEntries,
                                path: workspace.path
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            )

            if unseenCount > 0 {
                Text("\(unseenCount)")
                    .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                    .foregroundStyle(TenonTheme.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TenonTheme.amber))
                    .accessibilityIdentifier("tenon.workspaceUnseenCount")
            }

            if !agentEntries.isEmpty {
                accountToggle
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: WorkspaceSidebarLayout.rowHeight)
        .background { rowBackground }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The one control that opens or closes the account below this row. It never selects the
    /// workspace, and selecting the workspace never moves it — the two actions are unrelated
    /// on purpose, since a supervisor bringing a background pane forward should not have to
    /// also bring its workspace's whole tab set forward with it.
    private var accountToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
                isShowingAgentsInline.toggle()
            }
        } label: {
            Image(systemName: isShowingAgentsInline ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TenonTheme.muted)
                .frame(width: 20, height: WorkspaceSidebarLayout.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tenon.workspaceRow.accountToggle")
        .accessibilityLabel(
            isShowingAgentsInline
                ? "Hide agent panes for \(workspace.name)"
                : "Show agent panes for \(workspace.name)"
        )
    }

    /// The row's spoken identity lives on its own click target, not on a container above it:
    /// a container holding more than one focusable child — the toggle sits beside this one —
    /// does not adopt a label placed on the container, so an identity attached there would
    /// silently never be spoken at all.
    private func rowAccessibility(_ button: some View) -> some View {
        button
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("tenon.workspaceRow")
            // The mark is drawn, so it has to be spoken: the row announces the name it carries
            // and what it is marked with, and never leans on colour to tell two rows apart. The
            // tab count and the unseen count stay in the label — an explicit label replaces the
            // children VoiceOver would otherwise have read.
            .accessibilityLabel(
                WorkspaceRowAnnouncement.text(
                    for: workspace,
                    unseenCount: unseenCount,
                    agentEntries: agentEntries
                )
            )
            .accessibilityValue(
                WorkspaceReorder.spokenPosition(
                    position,
                    of: workspaceCount,
                    isActive: isActive
                )
            )
            .accessibilityActions {
                if position > 0 {
                    Button("Move workspace up") { move(position - 1) }
                }
                if position < workspaceCount - 1 {
                    Button("Move workspace down") { move(position + 1) }
                }
            }
    }

    /// This row's agent list, grown in place under the line it belongs to once
    /// `accountToggle` opens it. The rail never shows it — a 48 pt rail has no room to grow a
    /// row into, and its context menu already reaches every pane the list would have named.
    private var agentList: some View {
        WorkspaceAgentList(
            entries: agentEntries,
            isActive: isActive,
            focus: { slotID in
                store.focusSlot(slotID)
            }
        )
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                isActive
                    ? Color.primary.opacity(0.09)
                    : (isHovering ? Color.primary.opacity(0.04) : .clear)
            )
    }
}

/// The line under a workspace's name: where it lives on disk, held still.
///
/// The path is fixed regardless of what the workspace's agents are doing, so a row is legible
/// at a glance and in a screenshot without depending on a pane's title text. A count of however
/// many more panes the workspace holds sits alongside it when there is more than one. The full
/// account, with each pane's own `working`/idle state, lives behind the row's own disclosure
/// toggle, in `WorkspaceAgentList` — reachable there, or from the row's context menu without
/// ever opening it.
///
/// Nothing scheduled is the point. T-141 measured a 5 Hz poll of every pane taking 83% of a
/// stalled main thread, and the shape that caused it was work scheduled per pane whether or
/// not the pane had anything to say. A sidebar of any size runs no timer for this line.
// MARK: - Agent tagline  @domain: attention, workspace-model

private struct WorkspaceAgentTaglineView: View {
    let entries: [WorkspaceAgentTagline.Entry]
    let path: URL

    var body: some View {
        HStack(spacing: 4) {
            // Truncates from the head, so a deep path keeps its most identifying component —
            // the workspace's own directory — on screen rather than the drive it sits under.
            Text(path.path)
                .font(TenonTheme.utilityFont(size: 8))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
            if entries.count > 1 {
                Text("+\(entries.count - 1)")
                    .font(TenonTheme.utilityFont(size: 8, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted)
                    .fixedSize()
            }
        }
        .frame(height: 10)
        .help(path.path)
    }
}

/// Every agent pane the toggled-open workspace holds, and the way into each one.
///
/// The row carries one line, so this is where a workspace running several agents is actually
/// read: one line per pane, in the order the tabs hold them, each naming what that pane last
/// called itself beside the state its own attention machine is in. Choosing one hands it the
/// keyboard — `WorkspaceStore.focusSlot` brings its workspace, its tab and the pane itself
/// forward in a single typed mutation, so a pane in a workspace nobody was looking at is one
/// click away.
// MARK: - Agent list  @domain: attention, workspace-model

struct WorkspaceAgentList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entries: [WorkspaceAgentTagline.Entry]
    /// Whether the workspace this list hangs under is the selected one. Mirrors the row's own
    /// name, so a list left open under a workspace that lost focus reads as muted right along
    /// with it rather than staying at full weight while everything above it dims.
    var isActive: Bool = true
    let focus: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceAgentListLayout.spacing) {
            ForEach(entries) { entry in
                AgentListRow(
                    entry: entry,
                    isAnimated: !reduceMotion,
                    isActive: isActive,
                    select: { focus(entry.slotID) }
                )
            }
        }
        .padding(WorkspaceAgentListLayout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The list's density budget, stated once so the height a row draws and the height a test
/// measures cannot drift apart.
enum WorkspaceAgentListLayout {
    static let rowHeight: CGFloat = 22
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 1

    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 2 * padding }
        return CGFloat(rows) * rowHeight
            + CGFloat(rows - 1) * spacing
            + 2 * padding
    }
}

private struct AgentListRow: View {
    let entry: WorkspaceAgentTagline.Entry
    let isAnimated: Bool
    /// Mirrors the parent workspace row's own `isActive`: a list left open under a workspace
    /// that lost focus reads as muted right along with the name above it (WS-FR-036).
    let isActive: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                AgentStateIndicator(state: entry.state, isAnimated: isAnimated, size: 8)
                Text(entry.title)
                    // One step below the workspace name's 11 pt (WorkspaceSidebarView.swift's
                    // `expandedRow`): the account is the workspace's nested detail, not a peer
                    // of its own name, and the two read at the same weight of "identical
                    // importance" once they share a size.
                    .font(TenonTheme.interfaceFont(size: 10))
                    .foregroundStyle(isActive ? TenonTheme.text : TenonTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: WorkspaceAgentListLayout.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The title is truncated at this width, so the tooltip is where a long sentence is
        // read in full without leaving the list.
        .help(entry.title)
        .accessibilityLabel(
            "\(entry.title), \(WorkspaceRowAnnouncement.spoken(entry.state))"
        )
    }
}

/// The one attention vocabulary, drawn. Shared by the row's line and the account list's rows,
/// so a pane cannot look one way in the sidebar and another in the list.
private struct AgentStateIndicator: View {
    let state: PaneActivityState
    var isAnimated = true
    var size: CGFloat = 7

    var body: some View {
        content
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var content: some View {
        switch WorkspaceAgentTagline.indicator(for: state) {
        case .pulse:
            PulsingDot(isAnimated: isAnimated, diameter: size - 1)
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(
                    state == .finishedUnseen ? TenonTheme.amber : TenonTheme.muted
                )
        }
    }
}

/// The one indicator that moves: a filled dot breathing at the pace of a slow breath.
///
/// Opacity only, so the whole animation is one Core Animation property on one small layer —
/// it neither invalidates SwiftUI nor touches the main thread once it has started, which is
/// what lets a row keep it running while the rest of the sidebar sits still.
private struct PulsingDot: View {
    var isAnimated = true
    var diameter: CGFloat = 6

    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(TenonTheme.muted)
            .frame(width: diameter, height: diameter)
            .opacity(isDim ? 0.35 : 1)
            .animation(
                isAnimated
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: isDim
            )
            .onAppear { isDim = isAnimated }
    }
}

