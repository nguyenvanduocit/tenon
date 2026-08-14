// @domain: workspace-model
import SwiftUI
import TenonCore

/// One density budget for the full workspace sidebar and its persistent icon rail.
enum WorkspaceSidebarLayout {
    static let expandedHorizontalInset: CGFloat = 7
    static let collapsedHorizontalInset: CGFloat = 5
    static let rowHeight: CGFloat = 46
    static let reorderThreshold: CGFloat = 6
    static let reorderAnimation: Animation = .easeInOut(duration: 0.12)

    static var collapsedRowWidth: CGFloat {
        SidebarResize.collapsedWidth - collapsedHorizontalInset * 2
    }
}

/// The left navigation column: one row per workspace and a contextual recent-workspace
/// library in the empty area around those rows. Collapsing preserves the marks as a compact
/// rail instead of removing navigation from the window.
// MARK: - Sidebar composition  @domain: workspace-model

struct WorkspaceSidebarView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
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

private struct WorkspaceRow: View {
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
    let canRemove: Bool
    let select: () -> Void
    let removal: WorkspaceRemovalAction
    let isCollapsed: Bool

    @State private var isHovering = false
    @State private var isCustomising = false

    var body: some View {
        Button(action: select) {
            if isCollapsed {
                WorkspaceMark(workspace: workspace)
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
            } else {
                HStack(spacing: 8) {
                    WorkspaceMark(workspace: workspace)
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
                        Text("\(workspace.tabs.count) \(workspace.tabs.count == 1 ? "tab" : "tabs")")
                            .font(TenonTheme.utilityFont(size: 8))
                            .foregroundStyle(TenonTheme.muted)
                    }
                    Spacer()

                    if unseenCount > 0 {
                        Text("\(unseenCount)")
                            .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                            .foregroundStyle(TenonTheme.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TenonTheme.amber))
                            .accessibilityIdentifier("tenon.workspaceUnseenCount")
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: WorkspaceSidebarLayout.rowHeight)
                .background { rowBackground }
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .help(workspace.name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("tenon.workspaceRow")
        // The mark is drawn, so it has to be spoken: the row announces the name it carries
        // and what it is marked with, and never leans on colour to tell two rows apart. The
        // tab count and the unseen count stay in the label — an explicit label replaces the
        // children VoiceOver would otherwise have read.
        .accessibilityLabel(
            WorkspaceRowAnnouncement.text(for: workspace, unseenCount: unseenCount)
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
        .contextMenu {
            Button("Customise Workspace…") { isCustomising = true }
            Button("Remove Workspace", role: .destructive) { removal.perform() }
                .disabled(!canRemove)
        }
        .popover(isPresented: $isCustomising, arrowEdge: .trailing) {
            WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: { isCustomising = false }
            )
        }
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
