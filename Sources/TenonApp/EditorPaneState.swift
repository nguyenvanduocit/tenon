// @domain: editor-and-diff
import Foundation

/// Scroll offset, selection, and unsaved buffer of a file pane's editor, kept outside
/// the SwiftUI view tree so it survives the pane's view being destroyed on a tab or
/// pane switch. kero hangs this on `FileTab`; Tenon's `SlotContent.file` is a pure
/// value with nowhere to put it, so the state lives in `EditorPaneStateStore` instead.
struct EditorPaneState: Equatable {
    /// The file this state belongs to. Restoring is refused when the pane's content
    /// moved to a different path — inheriting another file's scroll position would be
    /// worse than opening at the top.
    var path: String
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
    /// The unsaved buffer, nil while the pane is clean. Kept so switching away from a
    /// dirty editor and back does not silently discard the user's edits.
    var pendingText: String?
    /// Hash of the disk text `pendingText` was edited from, so a restore can tell
    /// "the file changed on disk underneath the unsaved buffer" and flag the conflict.
    var savedTextHash: Int?
    /// Whether the pane had already seen its file change on disk while dirty, so the
    /// conflict warning survives a pane switch instead of silently vanishing.
    var conflicted: Bool = false

    init(
        path: String,
        selectionLocation: Int? = nil,
        selectionLength: Int? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        pendingText: String? = nil,
        savedTextHash: Int? = nil,
        conflicted: Bool = false
    ) {
        self.path = path
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pendingText = pendingText
        self.savedTextHash = savedTextHash
        self.conflicted = conflicted
    }
}

/// Per-slot editor state, owned by the app shell and threaded to every file pane —
/// the `SurfacePool.titles`/`directories` shape ("state that belongs to a pane, not
/// to its content value") in a store this feature owns.
///
/// Entries are keyed by slot AND checked against the pane's current path on the way
/// out. Slot IDs are never reused, so an entry outliving its closed pane is inert;
/// the LRU cap bounds the store (invariant 10) without a catalog subscription.
@MainActor
final class EditorPaneStateStore {
    static let capacity = 64

    private var states: [UUID: EditorPaneState] = [:]
    /// Coldest slot first. Bounded by `capacity`, so the scans below stay trivial.
    private var recency: [UUID] = []

    var count: Int { states.count }

    func state(for slotID: UUID, path: String) -> EditorPaneState? {
        guard let state = states[slotID], state.path == path else {
            return nil
        }
        return state
    }

    func recordScroll(for slotID: UUID, path: String, x: Double, y: Double) {
        mutate(for: slotID, path: path) {
            $0.scrollX = x
            $0.scrollY = y
        }
    }

    func recordSelection(
        for slotID: UUID,
        path: String,
        location: Int,
        length: Int
    ) {
        mutate(for: slotID, path: path) {
            $0.selectionLocation = location
            $0.selectionLength = length
        }
    }

    func recordBuffer(
        for slotID: UUID,
        path: String,
        pendingText: String?,
        savedTextHash: Int?,
        conflicted: Bool
    ) {
        mutate(for: slotID, path: path) {
            $0.pendingText = pendingText
            $0.savedTextHash = savedTextHash
            $0.conflicted = conflicted
        }
    }

    private func mutate(
        for slotID: UUID,
        path: String,
        _ change: (inout EditorPaneState) -> Void
    ) {
        // A recording under a different path replaces the slot's entry outright:
        // the pane's content moved on, and the old file's state must not survive
        // to be restored into the new one.
        var state = states[slotID].flatMap { $0.path == path ? $0 : nil }
            ?? EditorPaneState(path: path)
        change(&state)
        states[slotID] = state
        recency.removeAll { $0 == slotID }
        recency.append(slotID)
        while states.count > Self.capacity, !recency.isEmpty {
            states.removeValue(forKey: recency.removeFirst())
        }
    }
}

/// The rule for a file that changed on disk while a pane holds it. The disk text
/// matching what we last knew is our own save echoing back through the watcher (or a
/// touch that changed nothing) — never an external edit. A clean pane reloads: no
/// user work exists to lose. A dirty pane keeps the user's buffer and flags the
/// conflict: silently reloading would destroy their edits, silently ignoring would
/// leave them editing a ghost.
enum ExternalFileChange {
    enum Action: Equatable {
        case ignore
        case reload
        case conflict
    }

    static func action(
        diskText: String,
        savedText: String,
        isDirty: Bool
    ) -> Action {
        guard diskText != savedText else {
            return .ignore
        }
        return isDirty ? .conflict : .reload
    }
}

/// Cancels its underlying file watch when deallocated. The token is owned by the
/// pane's document model, so the watcher provably dies with its pane (invariant 10).
final class EditorFileWatchToken {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit {
        cancel()
    }
}
