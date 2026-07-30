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

    // Wired once by TenonApp.
    @ObservationIgnored var onTitleChange: ((String, UUID) -> Void)?
    @ObservationIgnored var onNewTab: (() -> Void)?
    @ObservationIgnored var onNewSplit: ((SplitAxis) -> Void)?
    @ObservationIgnored var onFocusNextSlot: (() -> Void)?
    @ObservationIgnored var onSlotFocusGained: ((UUID) -> Void)?
    @ObservationIgnored var onShellExited: ((UUID) -> Void)?

    let backendName: String
    /// Builds a surface for a slot. The slot `UUID` is passed so the backend can export it as
    /// `TENON_PANE_ID`, letting an agent running inside the pane target itself over the CLI.
    @ObservationIgnored private let makeSurface: (UUID, URL) -> TerminalSurface
    @ObservationIgnored private var surfaces: [UUID: TerminalSurface] = [:]
    /// Text aimed at a slot whose surface does not exist yet. A tab opened this very click
    /// builds its surface on the next SwiftUI render, so `terminal.run.v1` would otherwise
    /// write into nothing; the text waits here and flushes the moment the surface is built.
    @ObservationIgnored private var pendingText: [UUID: String] = [:]

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
        surface.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.titles[slotID] = title
            self.onTitleChange?(title, slotID)
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
