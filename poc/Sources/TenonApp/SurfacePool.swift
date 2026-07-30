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
    /// Fires on every pin/unpin so the catalog persistence can note the change — a pin
    /// set right before quitting, with no workspace mutation after it, must still land.
    @ObservationIgnored var onPinChange: (() -> Void)?

    let backendName: String
    /// Builds a surface for a slot. The slot `UUID` is passed so the backend can export it as
    /// `TENON_PANE_ID`, letting an agent running inside the pane target itself over the CLI.
    @ObservationIgnored private let makeSurface: (UUID, URL) -> TerminalSurface
    @ObservationIgnored private var surfaces: [UUID: TerminalSurface] = [:]
    /// Text aimed at a slot whose surface does not exist yet. A tab opened this very click
    /// builds its surface on the next SwiftUI render, so `terminal.run.v1` would otherwise
    /// write into nothing; the text waits here and flushes the moment the surface is built.
    @ObservationIgnored private var pendingText: [UUID: String] = [:]
    /// "Set Project Directory…" per pane. A pin outranks whatever the shell reports, and
    /// clearing it ("Use Automatic") re-resolves from the pane's current cwd.
    @ObservationIgnored private var pinnedRoots: [UUID: URL] = [:]

    init(
        backendName: String,
        makeSurface: @escaping (UUID, URL) -> TerminalSurface
    ) {
        self.backendName = backendName
        self.makeSurface = makeSurface
    }

    func surface(for slotID: UUID, workspacePath: URL) -> TerminalSurface {
        if let existing = surfaces[slotID] {
            return existing
        }
        let surface = makeSurface(slotID, workspacePath)
        // Seed from the directory the shell is actually starting in, so a pane reports a
        // project root immediately — before any OSC 7 arrives, and even where the bundle
        // ships no shell integration to emit one.
        updateDirectory(cwd: workspacePath, for: slotID)
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
            (surface as? GhosttySurface)?.sendText(queued)
        }
        return surface
    }

    /// Let a non-terminal pane (a browser) publish the per-slot title the header and
    /// tab bar show, riding the same `titles` registry terminals write to.
    func setTitle(_ title: String, for slotID: UUID) {
        titles[slotID] = title
    }

    /// Where a pane's shell is, and what that resolves to. `nil` for a pane that has never
    /// had a surface built.
    func paneDirectory(for slotID: UUID) -> ProjectRoot.PaneDirectory? {
        directories[slotID]
    }

    /// "Set Project Directory…" (`root`) and "Use Automatic" (`nil`). Re-resolves the pane
    /// against its current cwd and publishes only if the anchor actually moved. Restoring
    /// a persisted pin lands here too, before the pane has a surface: the pin is recorded
    /// and applies when the surface's first directory seed reads `pinnedRoots`.
    func pinProjectRoot(_ root: URL?, for slotID: UUID) {
        pinnedRoots[slotID] = root
        onPinChange?()
        guard let cwd = directories[slotID]?.cwd else { return }
        updateDirectory(cwd: cwd, for: slotID)
    }

    /// The pins, verbatim, for catalog persistence (T-027). `SurfacePool` stays the one
    /// runtime owner; the catalog document is just where they sleep between launches.
    var pinnedProjectRoots: [UUID: URL] { pinnedRoots }

    /// Whether a pane's root is a human's pin rather than the resolved one.
    func hasPinnedProjectRoot(for slotID: UUID) -> Bool {
        pinnedRoots[slotID] != nil
    }

    /// The single place a pane's directories change. Records the new cwd unconditionally —
    /// the status bar shows it, and it churns on every `cd` — but calls back only when the
    /// *project root* moved, which is what Files and Git re-root on.
    private func updateDirectory(cwd: URL, for slotID: UUID) {
        let next = ProjectRoot.PaneDirectory(cwd: cwd, pinned: pinnedRoots[slotID])
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

    /// Route keyboard focus to an existing slot's surface.
    func focusSurface(for slotID: UUID) {
        surfaces[slotID]?.focus()
    }

    /// Deliver `terminal.write.v1` text into a slot's PTY. Stub backend: no-op.
    func sendText(_ text: String, to slotID: UUID) {
        (surfaces[slotID] as? GhosttySurface)?.sendText(text)
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

    /// Whether a slot's child process has exited, for `tenon-cli pane.wait --for exit`.
    func processExited(for slotID: UUID) -> Bool {
        surfaces[slotID]?.processExited ?? false
    }

    /// How many shell commands have finished in a slot, for `pane.wait --for command-finished`.
    func commandFinishedCount(for slotID: UUID) -> Int {
        surfaces[slotID]?.commandFinishedCount ?? 0
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
    func retainOnly(_ slotIDs: Set<UUID>) {
        for key in surfaces.keys where !slotIDs.contains(key) {
            surfaces.removeValue(forKey: key)
            titles.removeValue(forKey: key)
            directories.removeValue(forKey: key)
            pinnedRoots.removeValue(forKey: key)
        }
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
