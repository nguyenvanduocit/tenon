import Foundation

/// Everything a plugin declares about itself, verbatim from `manifest.json`.
public struct PluginManifest: Equatable, Codable {
    public let name: String
    public let version: String
    public let permissions: [String]
    public let settings: [PluginSettingSpec]

    public init(name: String, version: String, permissions: [String] = [], settings: [PluginSettingSpec] = []) {
        self.name = name
        self.version = version
        self.permissions = permissions
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        settings = try c.decodeIfPresent([PluginSettingSpec].self, forKey: .settings) ?? []
    }

    /// Capabilities this host version gates. Anything else is surfaced as a warning.
    ///
    /// Per VISION principle 5, a plugin without permissions can render UI and react
    /// to events — statusBar, commands, generic events, and log are the free tier.
    /// Permissions exist only for sensitive capabilities: reading terminal state
    /// (`terminal.*` event topics), writing into the terminal, reading and writing
    /// the filesystem, spawning processes, and driving the workspace.
    public static let knownPermissions: Set<String> = [
        "terminal.read",
        "terminal.write",
        "filesystem.read",
        "filesystem.write",
        "process.exec",
        "workspace.control",
    ]

    public var unknownPermissions: [String] {
        permissions.filter { !Self.knownPermissions.contains($0) }
    }
}

/// One entry in the manifest's optional `settings` array — a value the user can
/// override per plugin, read back through `tenon.settings.get(key)`. Fields the
/// host doesn't know are ignored, like everywhere else in the manifest.
public struct PluginSettingSpec: Equatable, Codable {
    public enum SettingType: String, Equatable, Codable {
        case string
        case boolean
        case number
    }

    public let key: String
    public let label: String
    public let type: SettingType
    public let defaultValue: PluginSettingValue?

    enum CodingKeys: String, CodingKey {
        case key, label, type
        case defaultValue = "default"
    }
}

/// A JSON scalar a setting can hold — exactly the three manifest setting types.
public enum PluginSettingValue: Equatable, Codable {
    case string(String)
    case boolean(Bool)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let bool = try? c.decode(Bool.self) {
            self = .boolean(bool)
        } else if let number = try? c.decode(Double.self) {
            self = .number(number)
        } else if let string = try? c.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "a setting default must be a string, boolean, or number"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let string): try c.encode(string)
        case .boolean(let bool): try c.encode(bool)
        case .number(let number): try c.encode(number)
        }
    }

    /// The value as the plain type `JSValue(object:in:)` bridges into JS.
    public var anyValue: Any {
        switch self {
        case .string(let string): return string
        case .boolean(let bool): return bool
        case .number(let number): return number
        }
    }
}

public enum PluginLoadError: Error, CustomStringConvertible, Equatable {
    case manifestMissing(String)
    case manifestInvalid(String, String)
    case entrypointMissing(String)

    public var description: String {
        switch self {
        case .manifestMissing(let p): return "manifest.json not found at \(p)"
        case .manifestInvalid(let p, let why): return "manifest.json at \(p) is invalid: \(why)"
        case .entrypointMissing(let p): return "main.js not found at \(p)"
        }
    }
}

public enum PluginLoader {
    /// Reads `<directory>/manifest.json` and validates that `main.js` exists next to it.
    public static func loadManifest(at directory: URL) throws -> PluginManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
            throw PluginLoadError.manifestMissing(manifestURL.path)
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginLoadError.manifestInvalid(manifestURL.path, "\(error)")
        }
        let entrypoint = directory.appendingPathComponent("main.js")
        guard FileManager.default.fileExists(atPath: entrypoint.path) else {
            throw PluginLoadError.entrypointMissing(entrypoint.path)
        }
        return manifest
    }

    /// Every immediate subdirectory of `root` that contains a manifest.json, sorted by name.
    public static func discover(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
