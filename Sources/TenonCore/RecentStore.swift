// @domain: workspace-model
import Foundation
import TenonIntentCore

/// One workspace's recently-opened pane views, newest first.
///
/// `root` is the canonical folder the workspace was rooted at when the entry was written.
/// It is not the identity — `workspaceID` is, and it is the same UUID the catalog, the
/// events, and the intent surface all use — but it is what lets a bucket find its way home
/// when the catalog is rebuilt and mints new workspace ids (`RecentStore.adopt`).
public struct WorkspaceRecentViews: Equatable, Sendable {
    public let workspaceID: UUID
    public let root: String
    public let views: [SlotContent]

    public init(workspaceID: UUID, root: String, views: [SlotContent]) {
        self.workspaceID = workspaceID
        self.root = root
        self.views = views
    }
}

/// A live workspace as the recents store needs to see it: an identity and the folder it is
/// rooted at. Ordered rather than keyed, so matching by root is deterministic even when two
/// workspaces are open on the same folder.
public struct WorkspaceRoot: Equatable, Sendable {
    public let id: UUID
    public let root: String

    public init(id: UUID, path: URL) {
        self.id = id
        self.root = RecentWorkspaceStore.folderKey(path)
    }
}

/// The pane views the user opened most recently, **per workspace**, newest first, deduped by
/// value and capped. Persisted to a single JSON file (a missing file is an empty store; every
/// write is atomic), so recents survive relaunch.
///
/// The scope is the point. An empty pane's launcher offers what was opened *in the workspace
/// that owns that pane*, so a project's list is never seeded by another project's history and
/// nothing about another workspace — a plugin view, a file name — is reachable through it.
/// Both the ordering/cap rules and the workspace attribution are pure logic living here,
/// which is what lets `RecentStoreTests` assert them with two workspaces and no window.
public final class RecentStore {
    private let fileURL: URL
    private let limit: Int
    private let workspaceLimit: Int
    /// Buckets, most-recently-touched first. The array order carries workspace recency the
    /// same way each bucket's order carries view recency — no clock, nothing to keep in sync.
    private var workspaces: [WorkspaceRecentViews]

    public init(
        fileURL: URL,
        limit: Int = 6,
        workspaceLimit: Int = 32,
        preloaded: [WorkspaceRecentViews]? = nil,
        liveWorkspaces: [WorkspaceRoot] = []
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.workspaceLimit = workspaceLimit
        self.workspaces = preloaded ?? RecentStore.read(from: fileURL)
        adopt(liveWorkspaces)
    }

    /// Launch-time read seam. The app calls this from its concurrent preparation phase,
    /// then constructs the UI-owned store from the immutable result.
    package static func load(from fileURL: URL) -> [WorkspaceRecentViews] {
        read(from: fileURL)
    }

    /// What the launcher in a pane owned by `workspaceID` may offer. A workspace with no
    /// history — including one whose id this store has never seen — offers nothing, which is
    /// the only answer that cannot show another workspace's work.
    public func recent(for workspaceID: UUID) -> [SlotContent] {
        workspaces.first { $0.workspaceID == workspaceID }?.views ?? []
    }

    /// Move `content` to the front of `workspaceID`'s list (deduping by value), drop the
    /// empty placeholder, cap the list, move that workspace to the front, cap the number of
    /// workspaces kept, and persist. Re-opening the same view just re-surfaces it.
    public func record(_ content: SlotContent, for workspaceID: UUID, root: URL) {
        guard content != .empty else { return }
        var next = workspaces
        var views: [SlotContent] = []
        if let index = next.firstIndex(where: { $0.workspaceID == workspaceID }) {
            views = next.remove(at: index).views
        }
        views.removeAll { $0 == content }
        views.insert(content, at: 0)
        if views.count > limit {
            views.removeLast(views.count - limit)
        }
        next.insert(
            WorkspaceRecentViews(
                workspaceID: workspaceID,
                root: RecentWorkspaceStore.folderKey(root),
                views: views
            ),
            at: 0
        )
        if next.count > workspaceLimit {
            next.removeLast(next.count - workspaceLimit)
        }
        workspaces = next
        RecentStore.write(next, to: fileURL)
    }

    /// Forget one workspace's history. Every other workspace's list is left exactly as it
    /// was — there is no store-wide clear, because an app-global mutation is the shape this
    /// store exists to not have.
    public func clear(_ workspaceID: UUID) {
        let next = workspaces.filter { $0.workspaceID != workspaceID }
        guard next.count != workspaces.count else { return }
        workspaces = next
        RecentStore.write(next, to: fileURL)
    }

    // MARK: - Adoption

    /// Re-key buckets whose workspace id is no longer in the catalog onto the live workspace
    /// rooted at the same canonical folder, once, at launch.
    ///
    /// The catalog is the source of workspace identity, and it can be lost — a corrupt,
    /// oversized, or newer-versioned `.workspace-catalog.json` is declined wholesale and the
    /// next launch mints fresh ids for the same folders. Without this, every list would
    /// silently empty. The match is byte-equality on the canonical root, so a bucket only
    /// ever lands on the workspace it was actually written for; anything that does not match
    /// stays put (its workspace may simply be closed right now) and is bounded by
    /// `workspaceLimit` like everything else.
    ///
    /// A live workspace that already has its own bucket keeps it: two histories for one
    /// workspace have no true merge order, and the one under the live id is the current one.
    private func adopt(_ liveWorkspaces: [WorkspaceRoot]) {
        guard !liveWorkspaces.isEmpty else { return }
        let liveIDs = Set(liveWorkspaces.map(\.id))
        var claimed = Set(workspaces.map(\.workspaceID).filter(liveIDs.contains))
        var next: [WorkspaceRecentViews] = []
        var changed = false

        for bucket in workspaces {
            guard !liveIDs.contains(bucket.workspaceID) else {
                next.append(bucket)
                continue
            }
            guard let heir = liveWorkspaces.first(where: {
                $0.root == bucket.root && !claimed.contains($0.id)
            }) else {
                next.append(bucket)
                continue
            }
            claimed.insert(heir.id)
            next.append(WorkspaceRecentViews(
                workspaceID: heir.id,
                root: bucket.root,
                views: bucket.views
            ))
            changed = true
        }

        guard changed else { return }
        workspaces = next
        RecentStore.write(next, to: fileURL)
    }

    // MARK: - Persistence

    // One row per workspace: its identity, the folder it was rooted at, and its views. A row
    // missing `workspaceId` is dropped, which is also how the app-global list this store
    // replaced is handled — those rows carry no workspace at all, and guessing one would
    // reproduce, once, exactly the leak this scoping removes.
    private static func read(from url: URL) -> [WorkspaceRecentViews] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let rawID = row["workspaceId"] as? String,
                  let workspaceID = UUID(uuidString: rawID),
                  let root = row["root"] as? String,
                  let views = row["views"] as? [[String: String]]
            else { return nil }
            return WorkspaceRecentViews(
                workspaceID: workspaceID,
                root: root,
                views: views.compactMap(decode)
            )
        }
    }

    private static func write(_ items: [WorkspaceRecentViews], to url: URL) {
        let rows: [[String: Any]] = items.map { bucket in
            [
                "workspaceId": bucket.workspaceID.uuidString,
                "root": bucket.root,
                "views": bucket.views.map(encode),
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Each recent is one compact `{ "type": ... }` row. Plugin views persist their
    // validated manifest identity plus view ID; unknown or malformed rows are dropped.
    private static func encode(_ content: SlotContent) -> [String: String] {
        switch content {
        case .terminal:
            return ["type": "terminal"]
        case .changes:
            return ["type": "changes"]
        case .automation:
            return ["type": "automation"]
        case .pluginView(let pluginID, let viewID):
            return [
                "type": "pluginView",
                "pluginID": pluginID.rawValue,
                "viewID": viewID,
            ]
        case .diff, .file, .agentSession:
            // A diff, an open file, or a recorded session is a transient, context-bound
            // view; `decode` drops them all, so none persists into the recently-opened
            // list. A recorded session belongs there least of the three: the list of
            // sessions is itself the durable index, and it is the plugin's to keep.
            return ["type": "transient"]
        case .empty:
            return ["type": "empty"]
        }
    }

    private static func decode(_ row: [String: String]) -> SlotContent? {
        switch row["type"] {
        case "terminal":
            return .terminal
        case "changes":
            return .changes
        case "automation":
            return .automation
        case "pluginView":
            guard let rawPluginID = row["pluginID"],
                  let pluginID = try? PluginID(rawPluginID),
                  let viewID = row["viewID"]
            else {
                return nil
            }
            return .pluginView(pluginID: pluginID, viewID: viewID)
        default:
            return nil
        }
    }
}

extension WorkspaceEvent {
    /// The workspace this fact is about.
    ///
    /// Every workspace event names its workspace, so "which workspace did this open happen
    /// in" is answered by the mutation's own output rather than by reading a selection. That
    /// distinction is the whole point: `setSlotContent` addresses a pane anywhere in the
    /// catalog, so a pane filled in an unselected workspace must record there, and a
    /// selection-derived answer would put it in the wrong list.
    var workspaceID: UUID {
        switch self {
        case .workspaceAdded(let workspace),
             .workspaceRemoved(let workspace),
             .workspaceSelected(let workspace),
             .workspaceIdentityChanged(let workspace):
            return workspace
        case .workspaceMoved(let workspace, _, _):
            return workspace
        case .tabOpened(_, let workspace),
             .tabClosed(_, let workspace),
             .tabSelected(_, let workspace):
            return workspace
        case .tabMoved(_, _, _, let workspace):
            return workspace
        case .slotOpened(_, _, let workspace),
             .slotClosed(_, _, let workspace),
             .slotFocused(_, _, let workspace):
            return workspace
        case .slotSplit(_, _, _, _, let workspace):
            return workspace
        case .slotsMoved(_, _, let workspace),
             .slotsSwapped(_, _, _, let workspace):
            return workspace
        case .slotsResized(_, _, _, let workspace):
            return workspace
        case .slotContentChanged(_, _, _, let workspace):
            return workspace
        case .slotIdentityChanged(_, _, let workspace):
            return workspace
        case .slotMovedToTab(_, _, _, let workspace):
            return workspace
        }
    }
}
