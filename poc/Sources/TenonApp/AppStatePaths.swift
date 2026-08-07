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
    let instanceChannel: AppInstanceChannel
    let pluginInventoryRoot: URL
    let applicationSupportRoot: URL
    let stateRoot: URL

    /// Whether the host itself controls the inventory it just resolved, and may therefore
    /// authorize what it loads as bundled.
    ///
    /// True for the app bundle's own plugin root. `TENON_PLUGINS_DIR` names an arbitrary
    /// user directory, so an override is untrusted on its own — a developer standing that
    /// directory in for the bundle says so with `TENON_TRUST_PLUGIN_INVENTORY=1`.
    let trustsPluginInventory: Bool

    /// Whether the resolved primary inventory may be written to (T-062).
    ///
    /// False for the app bundle's own plugins folder, and that is not a preference:
    /// writing there breaks the bundle's code signature, and the next install replaces
    /// the bundle and deletes whatever was added. A developer's `TENON_PLUGINS_DIR` is
    /// an ordinary directory and stays writable.
    let pluginInventoryIsWritable: Bool

    /// Where a plugin the user (or an agent working with them) authors is kept —
    /// outside any bundle, surviving reinstalls. Always writable, never trusted:
    /// standing consent is earned by installing Tenon, not by a file's location.
    var userPluginInventoryRoot: URL {
        stateRoot
            .deletingLastPathComponent()
            .appendingPathComponent("user-plugins", isDirectory: true)
    }

    var pluginStateRoot: URL {
        stateRoot.appendingPathComponent("plugins", isDirectory: true)
    }

    var workspaceStateRoot: URL {
        stateRoot.appendingPathComponent("workspace", isDirectory: true)
    }

    var runtimeStateRoot: URL {
        stateRoot.appendingPathComponent("runtime", isDirectory: true)
    }

    var commandFrecencyFile: URL {
        applicationSupportRoot.appendingPathComponent(".command-frecency.json")
    }

    /// The persisted workspace catalog (T-027), beside `.recent-workspaces.json` and
    /// `.recent-views.json` in the workspace state root.
    var workspaceCatalogFile: URL {
        workspaceStateRoot.appendingPathComponent(".workspace-catalog.json")
    }

    /// Which plugins a person has let handle delegable contracts. Kept beside the other
    /// application-level preferences rather than in workspace state: a handler choice is
    /// about this person and this machine, not about one project.
    var openHandlerApprovalsFile: URL {
        applicationSupportRoot.appendingPathComponent(".open-handler-approvals.json")
    }

    static func resolve(
        instanceChannel requestedInstanceChannel: AppInstanceChannel? = nil,
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
        let instanceChannel = if let requestedInstanceChannel {
            requestedInstanceChannel
        } else {
            try AppInstanceChannel.resolve()
        }
        let inventoryRoot: URL
        let trustsInventory: Bool
        let inventoryIsWritable: Bool
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
            inventoryIsWritable = true
        } else if let bundledPluginsRoot {
            inventoryRoot = bundledPluginsRoot.standardizedFileURL
            trustsInventory = true
            // The bundle is sealed: a write here invalidates the code signature and
            // the next install deletes it. Authoring goes to the user inventory.
            inventoryIsWritable = false
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

        let applicationSupportRoot = applicationSupportDirectory
            .appendingPathComponent(
                instanceChannel.applicationSupportDirectoryName,
                isDirectory: true
            )
        let stateRoot = applicationSupportRoot
            .appendingPathComponent("state", isDirectory: true)
        let paths = AppStatePaths(
            instanceChannel: instanceChannel,
            pluginInventoryRoot: inventoryRoot,
            applicationSupportRoot: applicationSupportRoot,
            stateRoot: stateRoot,
            trustsPluginInventory: trustsInventory,
            pluginInventoryIsWritable: inventoryIsWritable
        )
        for directory in [
            paths.pluginStateRoot,
            paths.workspaceStateRoot,
            paths.runtimeStateRoot,
            paths.userPluginInventoryRoot,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return paths
    }
}
