// @domain: workspace-model, terminal-teardown
import Foundation
import Observation
import SwiftUI
import TenonCore

/// One host-native close gate for both tab and workspace gestures.
///
/// Process identity belongs to terminal surfaces while the mutations belong to
/// `WorkspaceStore`, so this app-layer coordinator is the typed DIRECT seam that joins them.
/// A target carries the exact slots inspected; an asynchronous idle answer is never applied
/// to a tab or workspace whose pane set or terminal process identity changed while `ps` was
/// running.
@MainActor
@Observable
final class ShellCloseCoordinator {
    enum Kind: Equatable {
        case tab
        case workspace
    }

    struct Target: Equatable {
        let kind: Kind
        let workspaceID: UUID
        let tabID: UUID?
        let title: String
        let slotIDs: Set<UUID>

        static func tab(
            _ tab: TenonCore.Tab,
            workspaceID: UUID,
            title: String
        ) -> Target {
            Target(
                kind: .tab,
                workspaceID: workspaceID,
                tabID: tab.id,
                title: title,
                slotIDs: Set(tab.slots.map(\.id))
            )
        }

        static func workspace(_ workspace: Workspace) -> Target {
            Target(
                kind: .workspace,
                workspaceID: workspace.id,
                tabID: nil,
                title: workspace.name,
                slotIDs: Set(workspace.tabs.flatMap(\.slots).map(\.id))
            )
        }
    }

    struct Confirmation: Equatable {
        let target: Target
        let reason: TerminalJobTermination.Inspection
    }

    enum TargetState: Equatable {
        case exact
        case changed
        case missing
    }

    typealias Snapshot = @MainActor (Set<UUID>) -> TerminalProcessInspectionSnapshot
    typealias Inspect = @MainActor (Set<UInt64>) async -> TerminalJobTermination.Inspection
    typealias IsCurrent = @MainActor (Target) -> TargetState
    typealias Commit = @MainActor (Target) -> Void

    private(set) var pendingConfirmation: Confirmation?

    @ObservationIgnored private let snapshot: Snapshot
    @ObservationIgnored private let inspect: Inspect
    @ObservationIgnored private let isCurrent: IsCurrent
    @ObservationIgnored private let commit: Commit
    @ObservationIgnored private var requestID: UUID?

    init(
        snapshot: @escaping Snapshot,
        inspect: @escaping Inspect,
        isCurrent: @escaping IsCurrent,
        commit: @escaping Commit
    ) {
        self.snapshot = snapshot
        self.inspect = inspect
        self.isCurrent = isCurrent
        self.commit = commit
    }

    convenience init(store: WorkspaceStore, pool: SurfacePool) {
        self.init(
            snapshot: { pool.terminalProcessSnapshot(for: $0) },
            inspect: { foregroundPIDs in
                await TerminalJobInspector.live.inspect(foregroundPIDs: foregroundPIDs)
            },
            isCurrent: { target in
                Self.state(of: target, in: store.catalog)
            },
            commit: { target in
                switch target.kind {
                case .tab:
                    guard let tabID = target.tabID else { return }
                    store.closeTab(tabID, in: target.workspaceID)
                case .workspace:
                    store.removeWorkspace(target.workspaceID)
                }
            }
        )
    }

    func requestClose(
        _ tab: TenonCore.Tab,
        workspaceID: UUID,
        title: String
    ) async {
        await requestClose(.tab(tab, workspaceID: workspaceID, title: title))
    }

    func requestClose(_ workspace: Workspace) async {
        await requestClose(.workspace(workspace))
    }

    func requestClose(_ target: Target) async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        pendingConfirmation = nil

        let processSnapshot = snapshot(target.slotIDs)
        guard processSnapshot.liveTerminalCount > 0 else {
            finishImmediateRequest(currentRequestID, target: target)
            return
        }
        guard processSnapshot.hasCompleteIdentity else {
            finishWithUnavailableConfirmation(currentRequestID, target: target)
            return
        }

        let inspection = await inspect(processSnapshot.foregroundPIDs)
        guard requestID == currentRequestID else { return }

        switch isCurrent(target) {
        case .missing:
            requestID = nil
            return
        case .changed:
            requestID = nil
            pendingConfirmation = Confirmation(target: target, reason: .unavailable)
        case .exact:
            // `ps` describes the identities captured before the await. A command can start
            // in an existing pane without changing the target's slot set, so compare a fresh
            // surface snapshot before trusting an idle result. Any identity drift fails safe.
            guard snapshot(target.slotIDs) == processSnapshot else {
                requestID = nil
                pendingConfirmation = Confirmation(target: target, reason: .unavailable)
                return
            }
            requestID = nil
            switch inspection {
            case .idle:
                commit(target)
            case .running, .unavailable:
                pendingConfirmation = Confirmation(target: target, reason: inspection)
            }
        }
    }

    func confirmPendingClose() {
        requestID = UUID()
        guard let pendingConfirmation else { return }
        self.pendingConfirmation = nil
        guard isCurrent(pendingConfirmation.target) != .missing else { return }
        commit(pendingConfirmation.target)
    }

    func cancelPendingClose() {
        requestID = UUID()
        pendingConfirmation = nil
    }

    private func finishImmediateRequest(_ id: UUID, target: Target) {
        guard requestID == id else { return }
        requestID = nil
        switch isCurrent(target) {
        case .exact:
            commit(target)
        case .changed:
            pendingConfirmation = Confirmation(target: target, reason: .unavailable)
        case .missing:
            break
        }
    }

    private func finishWithUnavailableConfirmation(_ id: UUID, target: Target) {
        guard requestID == id else { return }
        requestID = nil
        guard isCurrent(target) != .missing else { return }
        pendingConfirmation = Confirmation(target: target, reason: .unavailable)
    }

    private static func state(
        of target: Target,
        in catalog: WorkspaceCatalog
    ) -> TargetState {
        guard let workspace = catalog.workspaces.first(where: { $0.id == target.workspaceID }) else {
            return .missing
        }

        let currentSlotIDs: Set<UUID>
        switch target.kind {
        case .tab:
            guard let tabID = target.tabID,
                  let tab = workspace.tabs.first(where: { $0.id == tabID })
            else {
                return .missing
            }
            currentSlotIDs = Set(tab.slots.map(\.id))
        case .workspace:
            currentSlotIDs = Set(workspace.tabs.flatMap(\.slots).map(\.id))
        }
        return currentSlotIDs == target.slotIDs ? .exact : .changed
    }
}

extension View {
    /// Projects the coordinator's one pending decision as the system alert used by both
    /// title-bar tab close and sidebar workspace removal.
    func shellCloseConfirmation(_ coordinator: ShellCloseCoordinator) -> some View {
        modifier(ShellCloseConfirmationModifier(coordinator: coordinator))
    }
}

private struct ShellCloseConfirmationModifier: ViewModifier {
    var coordinator: ShellCloseCoordinator

    func body(content: Content) -> some View {
        content.alert(
            alertTitle,
            isPresented: Binding(
                get: { coordinator.pendingConfirmation != nil },
                set: { if !$0 { coordinator.cancelPendingClose() } }
            ),
            presenting: coordinator.pendingConfirmation
        ) { confirmation in
            Button(actionTitle(for: confirmation.target.kind), role: .destructive) {
                coordinator.confirmPendingClose()
            }
            Button("Cancel", role: .cancel) {
                coordinator.cancelPendingClose()
            }
        } message: { confirmation in
            Text(message(for: confirmation))
        }
    }

    private var alertTitle: String {
        switch coordinator.pendingConfirmation?.target.kind {
        case .workspace:
            "Remove Workspace?"
        case .tab, nil:
            "Close Tab?"
        }
    }

    private func actionTitle(for kind: ShellCloseCoordinator.Kind) -> String {
        kind == .workspace ? "Remove Workspace" : "Close Tab"
    }

    private func message(for confirmation: ShellCloseCoordinator.Confirmation) -> String {
        let title = confirmation.target.title
        let action = confirmation.target.kind == .workspace
            ? "Removing the workspace"
            : "Closing the tab"
        switch confirmation.reason {
        case .running:
            return "“\(title)” has running terminal processes. \(action) will terminate them."
        case .unavailable:
            return "Tenon couldn’t verify whether “\(title)” has running terminal processes. \(action) will terminate any work still running."
        case .idle:
            return ""
        }
    }
}
