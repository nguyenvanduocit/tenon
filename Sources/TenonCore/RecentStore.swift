// @domain: workspace-model
import Foundation
import TenonIntentCore

/// The pane views the user opened most recently, newest first, deduped by value
/// and capped. Persisted to a JSON file (a missing file is an empty store; every
/// write is atomic), so recents survive relaunch. All the ordering/cap rules live
/// here as pure logic — the shell only calls `record` and reads `recent`, which is
/// what lets `RecentStoreTests` assert them without a window.
public final class RecentStore {
    private let fileURL: URL
    private let limit: Int
    public private(set) var recent: [SlotContent]

    public init(
        fileURL: URL,
        limit: Int = 6,
        preloaded: [SlotContent]? = nil
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.recent = preloaded ?? RecentStore.read(from: fileURL)
    }

    /// Launch-time read seam. The app calls this from its concurrent preparation phase,
    /// then constructs the UI-owned store from the immutable result.
    package static func load(from fileURL: URL) -> [SlotContent] {
        read(from: fileURL)
    }

    /// Move `content` to the front (deduping by value), drop the empty placeholder,
    /// cap to `limit`, and persist. Re-opening the same view just re-surfaces it.
    public func record(_ content: SlotContent) {
        guard content != .empty else { return }
        var next = recent.filter { $0 != content }
        next.insert(content, at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        recent = next
        RecentStore.write(next, to: fileURL)
    }

    public func clear() {
        recent = []
        RecentStore.write([], to: fileURL)
    }

    // MARK: - Persistence

    // Each recent is one compact `{ "type": ... }` row. Plugin views persist their
    // validated manifest identity plus view ID; unknown or malformed rows are dropped.
    private static func read(from url: URL) -> [SlotContent] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: String]]
        else { return [] }
        return rows.compactMap(decode)
    }

    private static func write(_ items: [SlotContent], to url: URL) {
        let rows = items.map(encode)
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func encode(_ content: SlotContent) -> [String: String] {
        switch content {
        case .terminal:
            return ["type": "terminal"]
        case .changes:
            return ["type": "changes"]
        case .docs:
            return ["type": "docs"]
        case .automation:
            return ["type": "automation"]
        case .pluginView(let pluginID, let viewID):
            return [
                "type": "pluginView",
                "pluginID": pluginID.rawValue,
                "viewID": viewID,
            ]
        case .diff, .file:
            // A diff or an open file is a transient, context-bound view; `decode` drops
            // both so neither persists into the recently-opened list.
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
        case "docs":
            return .docs
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
