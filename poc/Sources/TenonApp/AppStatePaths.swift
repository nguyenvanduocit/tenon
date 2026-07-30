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
        if let override = environment["TENON_PLUGINS_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            inventoryRoot = URL(
                fileURLWithPath:
                    (override as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        } else if let bundledPluginsRoot {
            inventoryRoot = bundledPluginsRoot.standardizedFileURL
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
            stateRoot: stateRoot
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
