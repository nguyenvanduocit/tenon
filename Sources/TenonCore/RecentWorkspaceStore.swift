// @domain: workspace-model
import Foundation
import Observation

/// The workspaces the user opened most recently, newest first, deduped by path and
/// capped at twenty by default. Persisted to a JSON file (a missing file is an empty store;
/// every write is atomic), so the "recent workspaces" list survives relaunch. All ordering/cap
/// rules live here as pure logic — the shell records/updates identity and reads `recent`,
/// which is what lets `RecentWorkspaceStoreTests` assert them without a window.
///
/// `@Observable` so the sidebar's contextual library refreshes when the list changes
/// without having to read the churning workspace catalog (see `WorkspaceSidebarView`).
@Observable
public final class RecentWorkspaceStore {
    /// One remembered workspace: its path re-opens it while its presentation values let
    /// every recent-workspace surface draw the same name, mark, and tint it had when open.
    public struct Entry: Equatable, Identifiable, Sendable {
        public let name: String
        public let path: URL
        public let appearance: WorkspaceAppearance
        public var id: URL { path }

        public init(
            name: String,
            path: URL,
            appearance: WorkspaceAppearance = .default
        ) {
            self.name = name
            self.path = path
            self.appearance = appearance
        }
    }

    private let fileURL: URL
    private let limit: Int
    public private(set) var recent: [Entry]

    public init(
        fileURL: URL,
        limit: Int = 20,
        preloaded: [Entry]? = nil
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.recent = Array(
            (preloaded ?? RecentWorkspaceStore.read(from: fileURL)).prefix(limit)
        )
    }

    /// Launch-time read seam. The app calls this from its concurrent preparation phase,
    /// then constructs the observable store from the immutable result.
    package static func load(from fileURL: URL) -> [Entry] {
        read(from: fileURL)
    }

    /// Move the workspace at `path` to the front (deduping by path so re-opening it just
    /// re-surfaces the one entry, with its latest label), cap to `limit`, and persist.
    public func record(
        name: String,
        path: URL,
        appearance: WorkspaceAppearance = .default
    ) {
        let folder = RecentWorkspaceStore.folderKey(path)
        var next = recent.filter {
            RecentWorkspaceStore.folderKey($0.path) != folder
        }
        next.insert(Entry(name: name, path: path, appearance: appearance), at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        recent = next
        RecentWorkspaceStore.write(next, to: fileURL)
    }

    /// Refresh presentation without changing recency. Renaming or recolouring an open
    /// workspace is not another open, so its place in the list must stay where it was.
    public func updateIdentity(
        name: String,
        path: URL,
        appearance: WorkspaceAppearance
    ) {
        let folder = RecentWorkspaceStore.folderKey(path)
        guard let index = recent.firstIndex(where: {
            RecentWorkspaceStore.folderKey($0.path) == folder
        }) else { return }
        let updated = Entry(name: name, path: path, appearance: appearance)
        guard recent[index] != updated else { return }
        recent[index] = updated
        RecentWorkspaceStore.write(recent, to: fileURL)
    }

    /// The remembered workspaces that aren't in `openFolders`, newest first. The menu offers
    /// what you can't already reach: a workspace sitting in the catalog is one sidebar row
    /// away, so repeating it here is noise. The remembered list itself is untouched — the
    /// entry comes back the moment that workspace closes.
    public func recent(excludingFolders openFolders: Set<String>) -> [Entry] {
        recent.filter { !openFolders.contains(RecentWorkspaceStore.folderKey($0.path)) }
    }

    /// The identity of the folder a workspace is rooted at. Two `URL`s naming the same
    /// folder are not `==` — the open panel hands back a directory URL (`/tmp/a/`) while
    /// this file rehydrates a plain path (`/tmp/a`) — so matching a workspace to a
    /// remembered path compares this key. Standardizing is pure string work, unlike
    /// `URL(fileURLWithPath:)`, which asks the filesystem whether the folder exists.
    public static func folderKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    public func clear() {
        recent = []
        RecentWorkspaceStore.write([], to: fileURL)
    }

    // MARK: - Persistence

    // Name and path remain the only required fields, so files written before workspace
    // customisation restore with the default mark and automatic tint. Unknown future values
    // fail soft the same way rather than dropping an otherwise usable path.
    private static func read(from url: URL) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: String]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"], let path = row["path"] else { return nil }
            return Entry(
                name: name,
                path: URL(fileURLWithPath: path),
                appearance: WorkspaceAppearance(
                    symbol: row["symbol"].flatMap(WorkspaceSymbol.init(rawValue:)) ?? .default,
                    accent: row["accent"].flatMap(AccentColor.init(rawValue:)),
                    customIcon: customIcon(from: row)
                )
            )
        }
    }

    private static func write(_ items: [Entry], to url: URL) {
        let rows = items.map { entry in
            var row = [
                "name": entry.name,
                "path": entry.path.path,
                "symbol": entry.appearance.symbol.rawValue,
            ]
            if let accent = entry.appearance.accent {
                row["accent"] = accent.rawValue
            }
            if let icon = entry.appearance.customIcon {
                row["customIconID"] = icon.id.uuidString
                row["customIconPNG"] = icon.pngData.base64EncodedString()
            }
            return row
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func customIcon(
        from row: [String: String]
    ) -> WorkspaceCustomIcon? {
        guard let rawID = row["customIconID"],
              let id = UUID(uuidString: rawID),
              let rawPNG = row["customIconPNG"],
              let png = Data(base64Encoded: rawPNG)
        else { return nil }
        return WorkspaceCustomIcon(id: id, pngData: png)
    }
}
