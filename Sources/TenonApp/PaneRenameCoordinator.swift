// @domain: pane-chrome
import Foundation
import Observation
import TenonCore

/// The pane-rename state every pane header reads, keyed by the pane it belongs to.
///
/// There is no window-level presentation here and no single "current" rename: a rename is
/// something ONE pane is doing, so two panes can be naming themselves at once and each one's
/// task dies with its own pane. `retainOnly` stays the single teardown authority — the
/// catalog's liveness is what cancels work, not the view that started it.
@MainActor
@Observable
final class PaneRenameCoordinator {
    /// How long a failed generation stays legible on the pane title before it clears itself.
    /// The failure is information, not a dialog: nothing has to be dismissed, and the pane's
    /// automatic title comes back on its own.
    static let failureLinger: Duration = .seconds(5)

    private(set) var phases: [UUID: PaneRenamePhase] = [:]

    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let pool: SurfacePool
    @ObservationIgnored private let generator: (any PaneTitleGenerating)?
    @ObservationIgnored private let failureLinger: Duration
    @ObservationIgnored private var generationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failureTasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: WorkspaceStore,
        pool: SurfacePool,
        generator: (any PaneTitleGenerating)?,
        failureLinger: Duration = PaneRenameCoordinator.failureLinger
    ) {
        self.store = store
        self.pool = pool
        self.generator = generator
        self.failureLinger = failureLinger
    }

    func phase(for slotID: UUID) -> PaneRenamePhase? {
        phases[slotID]
    }

    func beginManual(slotID: UUID, currentTitle: String) {
        guard let slot = store.catalog.slot(id: slotID) else { return }
        cancelWork(for: slotID)
        phases[slotID] = .editing(draft: slot.customTitle ?? currentTitle)
    }

    func commitManual(slotID: UUID, to text: String) {
        guard case .editing = phases[slotID] else { return }
        phases[slotID] = nil
        store.renameSlot(slotID, to: text)
    }

    func beginAI(slotID: UUID, currentTitle: String) {
        guard let slot = store.catalog.slot(id: slotID),
              let owner = store.catalog.owner(ofSlot: slotID)
        else { return }

        cancelWork(for: slotID)
        phases[slotID] = .generating

        guard let generator else {
            fail(slotID: slotID, reason: CompanionTaskFailure.unavailable.localizedDescription)
            return
        }

        let terminalExcerpt = terminalExcerpt(for: slot)
        generationTasks[slotID] = Task { [weak self] in
            let brief = await PaneRenameBrief.make(
                slot: slot,
                currentTitle: currentTitle,
                workspacePath: owner.workspacePath,
                terminalExcerpt: terminalExcerpt
            )
            do {
                try Task.checkCancellation()
                let generated = try await generator.generateTitle(from: brief)
                try Task.checkCancellation()
                guard let self,
                      self.phases[slotID] == .generating,
                      self.store.catalog.slot(id: slotID) != nil
                else { return }
                self.generationTasks[slotID] = nil
                self.phases[slotID] = nil
                self.store.renameSlot(slotID, to: generated)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.phases[slotID] == .generating else { return }
                self.generationTasks[slotID] = nil
                self.fail(slotID: slotID, reason: error.localizedDescription)
            }
        }
    }

    func cancel(slotID: UUID) {
        cancelWork(for: slotID)
        phases[slotID] = nil
    }

    /// Catalog closure is the pane teardown authority. It catches direct close, closing a tab,
    /// removing a workspace, and any future path that removes the UUID from the same model.
    func retainOnly(_ liveSlotIDs: Set<UUID>) {
        for slotID in phases.keys where !liveSlotIDs.contains(slotID) {
            cancel(slotID: slotID)
        }
        for slotID in generationTasks.keys where !liveSlotIDs.contains(slotID) {
            cancel(slotID: slotID)
        }
    }

    /// A failure is reported and then withdrawn on a timer, because there is no dialog left to
    /// dismiss it. The pane goes back to its automatic title on its own; retrying is the menu
    /// item that started this, not a button that has to survive on a 34-point strip.
    private func fail(slotID: UUID, reason: String) {
        phases[slotID] = .failed(reason: reason)
        let linger = failureLinger
        failureTasks[slotID]?.cancel()
        failureTasks[slotID] = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self else { return }
            // Only this failure clears itself. A rename the operator started in the meantime
            // owns the pane's title now.
            guard case .failed = self.phases[slotID] else { return }
            self.failureTasks[slotID] = nil
            self.phases[slotID] = nil
        }
    }

    private func cancelWork(for slotID: UUID) {
        generationTasks.removeValue(forKey: slotID)?.cancel()
        failureTasks.removeValue(forKey: slotID)?.cancel()
    }

    private func terminalExcerpt(for slot: WorkspaceSlot) -> String? {
        guard slot.content == .terminal,
              let lines = pool.scrollbackLines(for: slot.id)
        else { return nil }
        let tail = lines.suffix(80).map { String($0.suffix(512)) }.joined(separator: "\n")
        return PaneRenameBrief.bounded(
            tail,
            maximumBytes: PaneRenameBrief.maximumExcerptBytes
        )
    }
}
