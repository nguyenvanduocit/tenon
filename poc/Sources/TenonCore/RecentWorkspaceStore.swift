import Foundation
import Observation

/// The workspaces the user opened most recently, newest first, deduped by path and
/// capped. Persisted to a JSON file (a missing file is an empty store; every write is
/// atomic), so the "recent workspaces" list survives relaunch. All the ordering/cap
/// rules live here as pure logic — the shell only calls `record` and reads `recent`,
/// which is what lets `RecentWorkspaceStoreTests` assert them without a window.
///
/// `@Observable` so the sidebar's Add-Workspace menu refreshes when the list changes
/// without having to read the churning workspace catalog (see `WorkspaceSidebarView`).
@Observable
public final class RecentWorkspaceStore {
    /// One remembered workspace: its path re-opens it, its name labels the menu row.
    public struct Entry: Equatable, Identifiable, Sendable {
        public let name: String
        public let path: URL
        public var id: URL { path }

        public init(name: String, path: URL) {
            self.name = name
            self.path = path
        }
    }

    private let fileURL: URL
    private let limit: Int
    public private(set) var recent: [Entry]

    public init(fileURL: URL, limit: Int = 8) {
        self.fileURL = fileURL
        self.limit = limit
        self.recent = RecentWorkspaceStore.read(from: fileURL)
    }

    /// Move the workspace at `path` to the front (deduping by path so re-opening it just
    /// re-surfaces the one entry, with its latest label), cap to `limit`, and persist.
    public func record(name: String, path: URL) {
        var next = recent.filter { $0.path != path }
        next.insert(Entry(name: name, path: path), at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        recent = next
        RecentWorkspaceStore.write(next, to: fileURL)
    }

    public func clear() {
        recent = []
        RecentWorkspaceStore.write([], to: fileURL)
    }

    // MARK: - Persistence

    // Each recent is one compact `{ "name": ..., "path": ... }` row; rows missing either
    // field are dropped on read so a hand-edited or partial file can't crash the launcher.
    private static func read(from url: URL) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: String]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"], let path = row["path"] else { return nil }
            return Entry(name: name, path: URL(fileURLWithPath: path))
        }
    }

    private static func write(_ items: [Entry], to url: URL) {
        let rows = items.map { ["name": $0.name, "path": $0.path.path] }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
