import Foundation

/// Per-plugin setting overrides, persisted to `<pluginsRoot>/.settings.json`
/// (dot-prefixed like `.disabled.json`, so discovery and the watcher both ignore
/// it). A missing file is an empty store; every write is atomic.
public final class SettingsStore {
    private let fileURL: URL
    /// plugin name → setting key → JSON value.
    private var overrides: [String: [String: Any]]

    public init(pluginsRoot: URL) {
        fileURL = pluginsRoot.appendingPathComponent(".settings.json")
        overrides = readValuesByPlugin(at: fileURL)
    }

    /// The user's override for `key`, or `defaultValue` (the manifest default)
    /// when the user never changed it.
    public func value(for key: String, plugin: String, default defaultValue: Any? = nil) -> Any? {
        overrides[plugin]?[key] ?? defaultValue
    }

    public func setValue(_ value: Any, forKey key: String, plugin: String) {
        overrides[plugin, default: [:]][key] = value
        writeValuesByPlugin(overrides, to: fileURL)
    }

    public func values(for plugin: String) -> [String: Any] {
        overrides[plugin] ?? [:]
    }
}

/// The per-plugin persistent key→value store behind `tenon.storage`, persisted to
/// `<pluginsRoot>/.storage.json`. Same rules as `SettingsStore`: dot-prefixed,
/// atomic writes, missing file = empty. Living on the host (not the runtime) is
/// what makes values survive a hot reload.
public final class PluginStorage {
    private let fileURL: URL
    /// plugin name → key → JSON value.
    private var values: [String: [String: Any]]

    public init(pluginsRoot: URL) {
        fileURL = pluginsRoot.appendingPathComponent(".storage.json")
        values = readValuesByPlugin(at: fileURL)
    }

    public func value(forKey key: String, plugin: String) -> Any? {
        values[plugin]?[key]
    }

    public func setValue(_ value: Any, forKey key: String, plugin: String) {
        values[plugin, default: [:]][key] = value
        writeValuesByPlugin(values, to: fileURL)
    }
}

// Both stores share one file shape: { "<plugin>": { "<key>": <JSON value> } }.

private func readValuesByPlugin(at url: URL) -> [String: [String: Any]] {
    guard let data = FileManager.default.contents(atPath: url.path),
          let json = try? JSONSerialization.jsonObject(with: data),
          let parsed = json as? [String: [String: Any]]
    else { return [:] }
    return parsed
}

private func writeValuesByPlugin(_ values: [String: [String: Any]], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
}
