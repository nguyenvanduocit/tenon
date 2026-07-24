import Foundation
import Observation
import SwiftUI
import TenonCore

/// Owns one `TerminalSurface` per slot, plus the per-slot titles the tab bar shows.
/// This is pure app shell: TenonCore's workspace only ever sees slot IDs, never a
/// terminal type. Releasing a surface here is what frees its ghostty resources.
@Observable
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
    @ObservationIgnored private let makeSurface: (URL) -> TerminalSurface
    @ObservationIgnored private var surfaces: [UUID: TerminalSurface] = [:]

    init(
        backendName: String,
        makeSurface: @escaping (URL) -> TerminalSurface
    ) {
        self.backendName = backendName
        self.makeSurface = makeSurface
    }

    func surface(for slotID: UUID, workspacePath: URL) -> TerminalSurface {
        if let existing = surfaces[slotID] {
            return existing
        }
        let surface = makeSurface(workspacePath)
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

    /// Deliver `tenon.terminal.write` text into a slot's PTY. Stub backend: no-op.
    func sendText(_ text: String, to slotID: UUID) {
        (surfaces[slotID] as? GhosttySurface)?.sendText(text)
    }

    /// Drop surfaces only when their slots leave the entire catalog. Inactive
    /// workspaces keep their shells alive.
    func retainOnly(_ slotIDs: Set<UUID>) {
        for key in surfaces.keys where !slotIDs.contains(key) {
            surfaces.removeValue(forKey: key)
            titles.removeValue(forKey: key)
        }
    }

    func title(for tab: TenonCore.Tab) -> String {
        guard let activeSlotID = tab.activeSlotID else { return "Terminal" }
        return titles[activeSlotID] ?? "Terminal"
    }
}
