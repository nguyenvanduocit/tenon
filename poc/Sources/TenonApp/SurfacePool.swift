import Foundation
import Observation
import SwiftUI
import TenonCore

struct TerminalObservation: Equatable {
    let text: String
    let processExited: Bool
    let commandFinishedCount: Int
    let columns: Int?
    let rows: Int?
}

/// Owns one `TerminalSurface` per slot, plus the per-slot titles the tab bar shows.
/// This is pure app shell: TenonCore's workspace only ever sees slot IDs, never a
/// terminal type. Releasing a surface here is what frees its ghostty resources.
@Observable
@MainActor
final class SurfacePool {
    private(set) var titles: [UUID: String] = [:]
    /// Where each pane's shell is, and the project root that cwd resolves to. Rides beside
    /// `titles` for the same reason: it is per-slot shell state the header and the panels
    /// both read, and the workspace model must not learn about terminals to carry it.
    private(set) var directories: [UUID: ProjectRoot.PaneDirectory] = [:]

    // Wired once by TenonApp.
    @ObservationIgnored var onTitleChange: ((String, UUID) -> Void)?
    /// Fires only when a pane's *project root* actually moves — an ordinary `cd` inside one
    /// repository updates `directories` and stays silent here, so the panels never thrash.
    @ObservationIgnored var onPaneDirectoryChange: ((ProjectRoot.PaneDirectory, UUID) -> Void)?
    @ObservationIgnored var onNewTab: (() -> Void)?
    @ObservationIgnored var onNewSplit: ((SplitAxis) -> Void)?
    @ObservationIgnored var onFocusNextSlot: (() -> Void)?
    @ObservationIgnored var onSlotFocusGained: ((UUID) -> Void)?
    @ObservationIgnored var onShellExited: ((UUID) -> Void)?
    /// T-029: the per-slot attention projection the shell surfaces read (tab chips,
    /// pane headers, sidebar rollups, title-bar count). Rewritten only when a machine
    /// reports events or is born, so the 200 ms poll never thrashes SwiftUI.
    private(set) var paneAttention: [UUID: PaneActivity] = [:]
    /// T-029, the notification seam: every slot whose `.becameUnseen` fired in ONE
    /// poll pass, delivered as a single batch — the coalescing unit.
    @ObservationIgnored var onPanesBecameUnseen: (([UUID]) -> Void)?
    /// T-029: the live machines behind `paneAttention`, mutated on every poll
    /// (detector streaks move even when nothing observable changes).
    @ObservationIgnored private var activityMachines: [UUID: PaneActivity] = [:]
    /// T-029: the slots currently satisfying the three-condition viewed rule, as last
    /// projected by the shell. Read at machine birth so a pane materialising into a
    /// displayed canvas starts viewed.
    @ObservationIgnored private var viewedSlotIDs: Set<UUID> = []

    let backendName: String
    /// Builds a surface for a slot. The slot `UUID` is passed so the backend can export it as
    /// `TENON_PANE_ID`, letting an agent running inside the pane target itself over the CLI.
    @ObservationIgnored private let makeSurface: (UUID, UUID, URL) -> TerminalSurface
    @ObservationIgnored private var surfaces: [UUID: TerminalSurface] = [:]
    @ObservationIgnored private var surfaceTokens: [UUID: UUID] = [:]
    /// Text aimed at a slot whose surface does not exist yet. A tab opened this very click
    /// builds its surface on the next SwiftUI render, so `terminal.run.v1` would otherwise
    /// write into nothing; the text waits here and flushes the moment the surface is built.
    @ObservationIgnored private var pendingText: [UUID: String] = [:]
    init(
        backendName: String,
        makeSurface: @escaping (UUID, URL) -> TerminalSurface
    ) {
        self.backendName = backendName
        self.makeSurface = { slotID, _, directory in makeSurface(slotID, directory) }
    }

    init(
        backendName: String,
        makeSurfaceWithIdentity: @escaping (UUID, UUID, URL) -> TerminalSurface
    ) {
        self.backendName = backendName
        makeSurface = makeSurfaceWithIdentity
    }

    /// T-031: calling this IS the "pane became visible" signal. The shell's render path
    /// is the only production caller and reaches here exactly when a terminal pane is
    /// actually displayed on the visible canvas, so materialization is lazy by
    /// construction: a restored background pane costs nothing until the human opens it.
    func surface(for slotID: UUID, workspacePath: URL) -> TerminalSurface {
        if let existing = surfaces[slotID] {
            return existing
        }
        // A restored pane materializes as a FRESH shell in the cwd it recorded before
        // the quit (seeded below without a surface); everything else starts in its
        // workspace. Nothing resurrects a dead process or replays history.
        let spawnDirectory = directories[slotID]?.cwd ?? workspacePath
        let surfaceToken = UUID()
        let surface = makeSurface(slotID, surfaceToken, spawnDirectory)
        surfaceTokens[slotID] = surfaceToken
        // Seed from the directory the shell is actually starting in, so a pane reports a
        // project root immediately — before any OSC 7 arrives, and even where the bundle
        // ships no shell integration to emit one.
        updateDirectory(cwd: spawnDirectory, for: slotID)
        surface.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.titles[slotID] = title
            self.onTitleChange?(title, slotID)
        }
        surface.onPwdChange = { [weak self] pwd in
            self?.updateDirectory(
                cwd: URL(fileURLWithPath: pwd, isDirectory: true),
                for: slotID
            )
        }
        if let ghostty = surface as? GhosttySurface {
            ghostty.onProcessExit = { [weak self] in self?.onShellExited?(slotID) }
            ghostty.onNewTab = { [weak self] in self?.onNewTab?() }
            ghostty.onNewSplit = { [weak self] axis in self?.onNewSplit?(axis) }
            ghostty.onGotoSplit = { [weak self] in self?.onFocusNextSlot?() }
            ghostty.onFocusGained = { [weak self] in self?.onSlotFocusGained?(slotID) }
        }
        surfaces[slotID] = surface
        if let queued = pendingText.removeValue(forKey: slotID) {
            surface.sendText(queued)
        }
        return surface
    }

    /// Let a non-terminal pane (a browser) publish the per-slot title the header and
    /// tab bar show, riding the same `titles` registry terminals write to.
    func setTitle(_ title: String, for slotID: UUID) {
        titles[slotID] = title
    }

    /// Where a pane's shell is, and what that resolves to. `nil` for a pane that has
    /// neither a surface nor restored placeholder data.
    func paneDirectory(for slotID: UUID) -> ProjectRoot.PaneDirectory? {
        directories[slotID]
    }

    /// T-031: the one-way viewed latch. True from the moment a pane was first actually
    /// displayed (which is what builds its surface), false again only when the slot
    /// leaves the catalog. Materialization IS the latch — one source of truth, so this
    /// can never disagree with which panes hold live surfaces.
    func hasEverBeenViewed(_ slotID: UUID) -> Bool {
        surfaces[slotID] != nil
    }

    /// Say where a pane's shell will start, before — and without — any surface. The pane
    /// renders that directory immediately and first view spawns the fresh shell there.
    /// Seeding is not viewing: the latch stays down and nothing materializes here, so
    /// T-031's laziness survives. A pane that already holds a surface has live state, which
    /// a seed must never overwrite.
    ///
    /// Two callers, one meaning: T-031/T-027 replay the cwd a restored pane recorded before
    /// the quit, and `terminal.open.v1` states where a pane it just created should start.
    func seedSpawnDirectory(_ cwd: URL, for slotID: UUID) {
        guard surfaces[slotID] == nil else { return }
        updateDirectory(cwd: cwd, for: slotID)
    }

    /// The single place a pane's directories change. Records the new cwd unconditionally —
    /// the status bar shows it, and it churns on every `cd` — but calls back only when the
    /// *project root* moved, which is what Files and Git re-root on.
    private func updateDirectory(cwd: URL, for slotID: UUID) {
        let next = ProjectRoot.PaneDirectory(cwd: cwd)
        let previous = directories[slotID]
        guard previous != next else { return }
        directories[slotID] = next
        guard let previous else {
            onPaneDirectoryChange?(next, slotID)
            return
        }
        if ProjectRoot.rerootsPanels(from: previous.resolution, to: next.resolution) {
            onPaneDirectoryChange?(next, slotID)
        }
    }

    /// T-029, the feed: one fixed-interval pass mapping every live surface's
    /// observation onto its slot's `PaneActivity` machine. The cadence is the caller's
    /// (the same 200 ms `terminal.wait.v1`'s loop uses); the instant is a parameter so
    /// the whole feed is deterministic in tests. A pane that never materialised has no
    /// surface, so it is not observed and holds no activity state — nothing is invented
    /// for it.
    func pollActivity(at now: Date) {
        var becameUnseen: [UUID] = []
        for slotID in surfaces.keys {
            guard let observation = terminalObservation(for: slotID) else { continue }
            let isNewMachine = activityMachines[slotID] == nil
            var machine = activityMachines[slotID] ?? PaneActivity(
                viewed: viewedSlotIDs.contains(slotID),
                at: now
            )
            let events = machine.observe(
                PaneActivity.Observation(
                    text: observation.text,
                    processExited: observation.processExited,
                    commandFinishedCount: observation.commandFinishedCount
                ),
                at: now
            )
            activityMachines[slotID] = machine
            if isNewMachine || !events.isEmpty {
                paneAttention[slotID] = machine
            }
            if events.contains(.becameUnseen) {
                becameUnseen.append(slotID)
            }
        }
        if !becameUnseen.isEmpty {
            onPanesBecameUnseen?(becameUnseen)
        }
    }

    /// T-029: the shell's viewed projection lands here as a set; the pool diffs it and
    /// calls `setViewed` only on the slots entering or leaving the condition. No timer
    /// ever reaches this — callers are the frontmost transitions and catalog events.
    func applyViewed(_ viewed: Set<UUID>, at now: Date) {
        guard viewed != viewedSlotIDs else { return }
        let entering = viewed.subtracting(viewedSlotIDs)
        let leaving = viewedSlotIDs.subtracting(viewed)
        viewedSlotIDs = viewed
        for slotID in entering {
            setMachineViewed(slotID, viewed: true, at: now)
        }
        for slotID in leaving {
            setMachineViewed(slotID, viewed: false, at: now)
        }
    }

    /// A never-materialised pane has no machine: its membership in `viewedSlotIDs` is
    /// remembered above so the machine is born viewed when the surface appears.
    private func setMachineViewed(_ slotID: UUID, viewed: Bool, at now: Date) {
        guard var machine = activityMachines[slotID] else { return }
        let events = machine.setViewed(viewed, at: now)
        activityMachines[slotID] = machine
        if !events.isEmpty {
            paneAttention[slotID] = machine
        }
    }

    /// Route keyboard focus to an existing slot's surface.
    func focusSurface(for slotID: UUID) {
        surfaces[slotID]?.focus()
    }

    /// Deliver `terminal.write.v1` text into a slot's PTY, through the seam so every
    /// backend receives it the same way (the stub records it for the lifecycle tests).
    /// Aiming at a pane that has never been viewed delivers nothing and builds nothing.
    func sendText(_ text: String, to slotID: UUID) {
        surfaces[slotID]?.sendText(text)
    }

    /// Same delivery, but for a slot that may not have rendered yet: the text is queued and
    /// flushed when the surface is built (`terminal.run.v1` into a freshly opened tab).
    func sendTextWhenReady(_ text: String, to slotID: UUID) {
        if surfaces[slotID] != nil {
            sendText(text, to: slotID)
        } else {
            pendingText[slotID, default: ""] += text
        }
    }

    /// The visible screen text of a slot's surface, used by
    /// `terminal.viewport.read.v1`. Empty without a live PTY surface.
    func renderedText(for slotID: UUID) -> String {
        surfaces[slotID]?.renderedText ?? ""
    }

    /// Every row a slot's surface retains, oldest first, for
    /// `terminal.scrollback.read.v1`. `nil` separates a pane with no surface — which can
    /// answer nothing — from a live surface that truthfully retains no rows, because the
    /// intent must fail for the first and succeed with an empty page for the second.
    func scrollbackLines(for slotID: UUID) -> [String]? {
        surfaces[slotID]?.scrollbackLines
    }

    /// Whether a slot's child process has exited, for `tenon-cli pane.wait --for exit`.
    func processExited(for slotID: UUID) -> Bool {
        surfaces[slotID]?.processExited ?? false
    }

    /// How many shell commands have finished in a slot, for `pane.wait --for command-finished`.
    func commandFinishedCount(for slotID: UUID) -> Int {
        surfaces[slotID]?.commandFinishedCount ?? 0
    }

    /// A coherent identity for the host-owned Agent Lens. Returning nil for a shell,
    /// a closed process, or a surface that has not materialised prevents discovery from
    /// inventing an agent session from a title or stale transcript alone.
    func agentTerminalIdentity(for slotID: UUID) -> AgentTerminalIdentity? {
        guard let surface = surfaces[slotID],
              let surfaceToken = surfaceTokens[slotID],
              !surface.processExited,
              let foregroundPID = surface.foregroundPID,
              foregroundPID > 0,
              let cwd = directories[slotID]?.cwd
        else { return nil }
        return AgentTerminalIdentity(
            slotID: slotID,
            surfaceToken: surfaceToken,
            foregroundPID: foregroundPID,
            cwd: cwd,
            title: titles[slotID] ?? ""
        )
    }

    /// DIRECT same-owner input with a process-identity guard. A mode switch, shell exit,
    /// or foreground-process change between composing and sending refuses the write rather
    /// than pasting text into an unrelated shell command.
    @discardableResult
    func sendAgentInputFrame(
        _ text: String,
        to slotID: UUID,
        expectedForegroundPID: UInt64
    ) -> Bool {
        guard let surface = surfaces[slotID],
              !surface.processExited,
              surface.foregroundPID == expectedForegroundPID
        else { return false }
        surface.sendText(text)
        return true
    }

    /// The terminal grid size of a slot, when its backend is a live ghostty surface.
    func terminalSize(for slotID: UUID) -> (cols: Int, rows: Int)? {
        guard let size = (surfaces[slotID] as? GhosttySurface)?.surfaceSize else { return nil }
        return (size.columns, size.rows)
    }

    /// One coherent main-actor observation for bounded terminal read/wait
    /// intents. `nil` distinguishes a pane whose surface is not ready from a
    /// live surface that truthfully renders an empty viewport.
    func terminalObservation(for slotID: UUID) -> TerminalObservation? {
        guard let surface = surfaces[slotID] else {
            return nil
        }
        let size = terminalSize(for: slotID)
        return TerminalObservation(
            text: surface.renderedText,
            processExited: surface.processExited,
            commandFinishedCount: surface.commandFinishedCount,
            columns: size?.cols,
            rows: size?.rows
        )
    }

    /// Drop surfaces only when their slots leave the entire catalog. Inactive
    /// workspaces keep their shells alive.
    ///
    /// T-084: dropping the surface is where the pane's job tree is stopped, and the order is
    /// deliberate — `terminate()` runs while the surface can still name its own processes, and
    /// only then is it released. Because the removal happens in the same pass, a repeated
    /// catalog sync cannot signal the same pane twice.
    func retainOnly(_ slotIDs: Set<UUID>) {
        for key in surfaces.keys where !slotIDs.contains(key) {
            surfaces[key]?.terminate()
            surfaces.removeValue(forKey: key)
            surfaceTokens.removeValue(forKey: key)
            titles.removeValue(forKey: key)
            directories.removeValue(forKey: key)
        }
        // T-029: attention state is bounded by the slot's lifetime, exactly like the
        // surface itself (invariant 10).
        for key in activityMachines.keys where !slotIDs.contains(key) {
            activityMachines.removeValue(forKey: key)
        }
        for key in paneAttention.keys where !slotIDs.contains(key) {
            paneAttention.removeValue(forKey: key)
        }
        viewedSlotIDs.formIntersection(slotIDs)
        // Text queued for a pane that closed before it ever rendered has nowhere to go.
        for key in pendingText.keys where !slotIDs.contains(key) {
            pendingText.removeValue(forKey: key)
        }
    }

    func title(for tab: TenonCore.Tab) -> String {
        guard let activeSlotID = tab.activeSlotID else { return "Terminal" }
        return titles[activeSlotID] ?? "Terminal"
    }
}
