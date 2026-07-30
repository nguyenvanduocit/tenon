import Foundation

enum AppStatePathError: Error, Sendable, Equatable, CustomStringConvertible {
    case pluginInventoryMissing(String)

    var description: String {
        switch self {
        case let .pluginInventoryMissing(path):
            return "Plugin inventory is missing or is not a directory: \(path)"
        }
    }
}

struct AppStatePaths: Sendable, Equatable {
    let pluginInventoryRoot: URL
    let stateRoot: URL

    /// Whether the host itself controls the inventory it just resolved, and may therefore
    /// authorize what it loads as bundled.
    ///
    /// True for the app bundle's own plugin root. `TENON_PLUGINS_DIR` names an arbitrary
    /// user directory, so an override is untrusted on its own — a developer standing that
    /// directory in for the bundle says so with `TENON_TRUST_PLUGIN_INVENTORY=1`.
    let trustsPluginInventory: Bool

    var pluginStateRoot: URL {
        stateRoot.appendingPathComponent("plugins", isDirectory: true)
    }

    var workspaceStateRoot: URL {
        stateRoot.appendingPathComponent("workspace", isDirectory: true)
    }

    var runtimeStateRoot: URL {
        stateRoot.appendingPathComponent("runtime", isDirectory: true)
    }

    static func resolve(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0],
        bundledPluginsRoot: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("plugins", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> AppStatePaths {
        let inventoryRoot: URL
        let trustsInventory: Bool
        if let override = environment["TENON_PLUGINS_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            inventoryRoot = URL(
                fileURLWithPath:
                    (override as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
            // Exact match only. Any other value — including "true" — leaves the override
            // untrusted, so a flag set by accident cannot grant standing consent.
            trustsInventory =
                environment["TENON_TRUST_PLUGIN_INVENTORY"] == "1"
        } else if let bundledPluginsRoot {
            inventoryRoot = bundledPluginsRoot.standardizedFileURL
            trustsInventory = true
        } else {
            throw AppStatePathError.pluginInventoryMissing(
                "<bundle>/plugins"
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: inventoryRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw AppStatePathError.pluginInventoryMissing(
                inventoryRoot.path
            )
        }

        let stateRoot = applicationSupportDirectory
            .appendingPathComponent("Tenon", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        let paths = AppStatePaths(
            pluginInventoryRoot: inventoryRoot,
            stateRoot: stateRoot,
            trustsPluginInventory: trustsInventory
        )
        for directory in [
            paths.pluginStateRoot,
            paths.workspaceStateRoot,
            paths.runtimeStateRoot,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return paths
    }
}
