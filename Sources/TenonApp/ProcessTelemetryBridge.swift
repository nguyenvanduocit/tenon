// @domain: process-telemetry
import Foundation
import Observation
import SwiftUI
import TenonCore

// MARK: - Provenance bridge  @domain: process-telemetry

/// Reads the workspace catalog and the surface pool on `MainActor` and hands the coordinator
/// plain values.
///
/// It owns exactly one piece of state of its own: a monotonic revision that changes whenever
/// pane ownership could have changed. That number is what makes "a sample cannot publish under
/// a hierarchy that no longer exists" checkable — the coordinator captures it before sampling
/// and compares it after, and any drift makes the result unpublishable.
@MainActor
final class ProcessTelemetryBridge {
    private let store: WorkspaceStore
    private let surfaces: SurfacePool
    private var revision = 1
    /// The ownership shape the revision currently describes. Compared structurally rather than
    /// bumped from every workspace event, because most events — a title change, a scroll, a
    /// selection — move no pane and must not invalidate a sample in flight.
    private var lastShape: [String] = []

    init(store: WorkspaceStore, surfaces: SurfacePool) {
        self.store = store
        self.surfaces = surfaces
        lastShape = Self.shape(of: store)
    }

    /// Recompute the revision if the ownership shape moved. Cheap enough to call before every
    /// sample: it is a string list built from ids already in memory.
    func refreshRevision() {
        let current = Self.shape(of: store)
        guard current != lastShape else { return }
        lastShape = current
        revision += 1
    }

    /// Which panes exist, where their processes are, and what to call them.
    ///
    /// Only terminal panes contribute provenance. A file, diff, or plugin pane has no process
    /// of its own, and giving it a row with unavailable metrics would fill the tree with
    /// unanswerable questions; the panes that *can* own processes are the ones the monitor is
    /// about.
    func snapshot() -> ProvenanceSnapshot {
        refreshRevision()

        var panes: [PaneProvenance] = []
        var workspaceLabels: [UUID: String] = [:]
        var tabLabels: [UUID: String] = [:]
        var paneLabels: [UUID: String] = [:]

        let terminalSlotIDs = store.catalog.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots.filter { $0.content == .terminal }.map(\.id)
            }
        }
        let provenance = surfaces.terminalProvenance(for: terminalSlotIDs)

        for workspace in store.catalog.workspaces {
            workspaceLabels[workspace.id] = workspace.name
            for tab in workspace.tabs {
                tabLabels[tab.id] = "Terminal \(tab.number)"
                for slot in tab.slots where slot.content == .terminal {
                    let reported = provenance[slot.id]
                    paneLabels[slot.id] = surfaces.titles[slot.id] ?? "Pane"
                    panes.append(
                        PaneProvenance(
                            slotID: slot.id,
                            tabID: tab.id,
                            workspaceID: workspace.id,
                            // An unmaterialised or PTY-less surface resolves to no device, so
                            // the pane appears with unavailable metrics rather than silently
                            // matching some other pane's processes.
                            ttyDevice: reported?.ttyName.flatMap(TerminalDeviceResolver.device(forTTYPath:)),
                            foregroundPID: reported?.foregroundPID.map { Int32(truncatingIfNeeded: $0) }
                        )
                    )
                }
            }
        }

        return ProvenanceSnapshot(
            revision: revision,
            panes: panes,
            labels: TelemetryLabels(workspaces: workspaceLabels, tabs: tabLabels, panes: paneLabels)
        )
    }

    /// Everything that decides which pane owns which process: the workspaces, their tabs, and
    /// the terminal slots inside them, in order. A rename or a colour change is deliberately
    /// absent — it changes a label, not an owner.
    private static func shape(of store: WorkspaceStore) -> [String] {
        store.catalog.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.slots
                    .filter { $0.content == .terminal }
                    .map { "\(workspace.id.uuidString)/\(tab.id.uuidString)/\($0.id.uuidString)" }
            }
        }
    }
}

// MARK: - Observable model  @domain: process-telemetry

/// What the SwiftUI monitor binds to.
///
/// It holds presentation state — which rows are open, how the list is sorted, whether the
/// popover is up — and nothing else. Every graph, metric, ordering, failure, and retry rule is
/// in `TenonCore`, so this type has no behaviour a headless test would want to assert.
@Observable
@MainActor
final class ResourceMonitorModel {
    private(set) var snapshot: TelemetrySnapshot?
    private(set) var history: [String: [UInt64]] = [:]
    var sortKey: TelemetrySortKey = .memory
    var sortDirection: TelemetrySortDirection = .descending
    var expanded: Set<String> = []
    var selection: String?

    /// True once the popover has been open long enough that a skeleton is worth showing. A
    /// spinner that appears instantly on a sample that takes 3 ms is a flash, not feedback.
    private(set) var showsSkeleton = false

    @ObservationIgnored private let coordinator: ProcessTelemetryCoordinator
    @ObservationIgnored private let bridge: ProcessTelemetryBridge
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var skeletonTask: Task<Void, Never>?
    /// Focus and reveal a pane. The one action the monitor performs, and it is navigation:
    /// there is no route from here to terminating anything.
    @ObservationIgnored var revealPane: ((UUID) -> Void)?

    init(coordinator: ProcessTelemetryCoordinator, bridge: ProcessTelemetryBridge) {
        self.coordinator = coordinator
        self.bridge = bridge
    }

    /// Rows in the order the current sort puts them.
    var rows: [TelemetryNode] {
        guard let snapshot else { return [] }
        return TelemetrySort.apply(snapshot.root, key: sortKey, direction: sortDirection)
    }

    func toggleSort(_ key: TelemetrySortKey) {
        if sortKey == key {
            sortDirection = sortDirection.toggled
        } else {
            sortKey = key
            sortDirection = key == .name ? .ascending : .descending
        }
    }

    func toggleExpansion(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func opened() async {
        let token = await coordinator.observe { [weak self] snapshot in
            Task { @MainActor in self?.receive(snapshot) }
        }
        observerToken = token
        if let existing = await coordinator.latest { receive(existing) }
        startSkeletonTimer()
        await coordinator.surfaceAppeared()
    }

    func closed() async {
        skeletonTask?.cancel()
        skeletonTask = nil
        showsSkeleton = false
        if let observerToken { await coordinator.removeObserver(observerToken) }
        observerToken = nil
        await coordinator.surfaceDisappeared()
    }

    func retry() async {
        await coordinator.retry()
    }

    // MARK: - Keyboard outline navigation  @domain: process-telemetry

    /// The rows a person can actually move through: the tree flattened to what is expanded.
    ///
    /// A drag or a click is not the route here — an outline has to be walkable without either,
    /// and the same list is what VoiceOver reads, so the spoken order and the arrow-key order
    /// cannot drift apart.
    var visibleRowIDs: [String] {
        var ids: [String] = []
        func walk(_ nodes: [TelemetryNode]) {
            for node in nodes {
                ids.append(node.id)
                if expanded.contains(node.id) { walk(node.children) }
            }
        }
        walk(rows)
        return ids
    }

    /// Up/Down. Clamps rather than wrapping: an outline that jumps from the last row to the
    /// first loses a person's place in a list whose contents move every two seconds.
    func moveSelection(by offset: Int) {
        let ids = visibleRowIDs
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = offset > 0 ? ids.first : ids.last
            return
        }
        selection = ids[min(max(index + offset, 0), ids.count - 1)]
    }

    func moveSelectionToFirst() { selection = visibleRowIDs.first }
    func moveSelectionToLast() { selection = visibleRowIDs.last }

    /// Right: open this row, or step into it if it is already open.
    func expandOrDescend() {
        guard let selection, let node = find(selection, in: rows) else { return }
        guard !node.children.isEmpty else { return }
        if expanded.contains(selection) {
            self.selection = node.children.first?.id
        } else {
            expanded.insert(selection)
        }
    }

    /// Left: close this row, or step out to its parent if it is already closed. The mirror of
    /// `expandOrDescend`, which is what makes the two keys a way to walk the tree rather than
    /// two separate toggles.
    func collapseOrAscend() {
        guard let selection else { return }
        if expanded.contains(selection) {
            expanded.remove(selection)
            return
        }
        if let parent = parent(of: selection, in: rows, ancestor: nil) {
            self.selection = parent
        }
    }

    private func parent(of id: String, in nodes: [TelemetryNode], ancestor: String?) -> String? {
        for node in nodes {
            if node.id == id { return ancestor }
            if let found = parent(of: id, in: node.children, ancestor: node.id) { return found }
        }
        return nil
    }

    /// Space toggles the selected row without moving the selection.
    func toggleSelectedExpansion() {
        guard let selection else { return }
        toggleExpansion(selection)
    }

    /// Return on a row that names a pane goes to that pane. It is the only thing Return does.
    func activateSelection() {
        guard let selection, let node = find(selection, in: snapshot?.root ?? []) else { return }
        guard let pane = node.revealsPane else { return }
        revealPane?(pane)
    }

    /// Publish a snapshot without a sampler behind it, so navigation, sorting, and expansion
    /// can be asserted over a known tree.
    func applyForTesting(_ snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
    }

    private func receive(_ snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
        if snapshot.state.isUsable {
            showsSkeleton = false
            skeletonTask?.cancel()
            skeletonTask = nil
        }
        Task { [weak self] in
            guard let self else { return }
            let series = await coordinator.history.series
            await MainActor.run { self.history = series }
        }
    }

    private func startSkeletonTimer() {
        guard snapshot == nil else { return }
        skeletonTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.snapshot == nil else { return }
                self.showsSkeleton = true
            }
        }
    }

    private func find(_ id: String, in nodes: [TelemetryNode]) -> TelemetryNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }
}
