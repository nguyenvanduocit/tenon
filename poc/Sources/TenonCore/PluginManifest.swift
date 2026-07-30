import Foundation
import TenonIntentCore

/// Everything a plugin declares about itself, verbatim from `manifest.json`.
public struct PluginManifest: Sendable, Equatable, Codable {
    /// Stable authority and namespace identity. Directory names and display names are not
    /// security identities.
    public let id: PluginID
    public let name: String
    public let version: String
    public let permissions: [String]
    public let intents: PluginIntentManifest
    public let settings: [PluginSettingSpec]
    /// SF Symbol for the plugin's flat entry in the Settings sidebar (optional).
    public let icon: String?
    /// Title for that entry, when the plugin wants something other than `name`.
    public let displayName: String?
    /// Optional host allowlist applied to `network.fetch.v1`.
    public let network: PluginNetworkPolicy?

    public init(
        id: PluginID,
        name: String,
        version: String,
        permissions: [String] = [],
        intents: PluginIntentManifest = PluginIntentManifest(),
        settings: [PluginSettingSpec] = [],
        icon: String? = nil,
        displayName: String? = nil,
        network: PluginNetworkPolicy? = nil
    ) throws {
        self.id = id
        self.name = name
        self.version = version
        self.permissions = permissions
        self.intents = intents
        self.settings = settings
        self.icon = icon
        self.displayName = displayName
        self.network = network
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PluginID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        intents = try c.decode(
            PluginIntentManifest.self,
            forKey: .intents
        )
        settings = try c.decodeIfPresent([PluginSettingSpec].self, forKey: .settings) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        network = try c.decodeIfPresent(PluginNetworkPolicy.self, forKey: .network)
        try validate()
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
        "web.view",
        // Hand a path to the OS: reveal it in Finder, or open it in whatever app owns
        // it. The host performs it (AppKit lives in the shell); the permission exists
        // because launching another application is a real escalation.
        "shell.open",
        // Make HTTP requests. Unlike every other permission, this one is not sufficient
        // on its own: the manifest must also list the hosts under `network.allow`, so
        // "can reach the network" is never the same grant as "can reach anywhere".
        "network",
        // Read and write this plugin's own secrets in the Keychain. Separate from the
        // permission-free `tenon.storage` because that is a JSON file next to the
        // plugins, which is the wrong place for a token.
        "secrets",
    ]

    public var unknownPermissions: [String] {
        permissions.filter { !Self.knownPermissions.contains($0) }
    }

    /// Hosts this plugin may reach with `network.fetch.v1`, from the manifest's
    /// `"network": { "allow": [...] }`. Empty means none — declaring the `network`
    /// permission without an allowlist grants nothing, which is the point.
    ///
    /// An entry may be an exact host (`api.github.com`) or a wildcard covering
    /// subdomains (`*.github.com`, which does NOT match `github.com` itself).
    public var networkAllowlist: [String] { network?.allow ?? [] }

    public func allowsNetworkHost(_ host: String) -> Bool {
        let candidate = host.lowercased()
        return networkAllowlist.contains { entry in
            let allowed = entry.lowercased()
            if allowed.hasPrefix("*.") { return candidate.hasSuffix(String(allowed.dropFirst(1))) }
            return candidate == allowed
        }
    }

    private func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 64
        else {
            throw PluginManifestError.invalidName
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.utf8.count <= 64
        else {
            throw PluginManifestError.invalidVersion
        }
        guard Set(permissions).count == permissions.count else {
            throw PluginManifestError.duplicatePermission
        }
        var settingKeys: Set<String> = []
        for setting in settings {
            guard settingKeys.insert(setting.key).inserted else {
                throw PluginManifestError.duplicateSettingKey(setting.key)
            }
        }
        try intents.validate(owner: id)
    }
}

/// Static invocation declarations. The host can compile contracts, authorize callers, and
/// construct palette/MCP projections before evaluating plugin source.
public struct PluginIntentManifest: Sendable, Equatable, Codable {
    public let uses: [IntentID]
    public let provides: [PluginIntentProvision]

    public init(
        uses: [IntentID] = [],
        provides: [PluginIntentProvision] = []
    ) {
        self.uses = uses
        self.provides = provides
    }

    fileprivate func validate(owner: PluginID) throws {
        guard Set(uses).count == uses.count else {
            throw PluginManifestError.duplicateIntentUse
        }
        let providedNames = provides.map(\.name)
        guard Set(providedNames).count == providedNames.count else {
            throw PluginManifestError.duplicateIntentProvision
        }
        for provision in provides {
            try provision.validate(owner: owner)
        }
    }
}

/// A name-only entry binds an implementation of a canonical core/open contract. An entry
/// carrying contract fields declares a plugin-owned contract in the plugin's own namespace.
public struct PluginIntentProvision: Sendable, Equatable, Codable {
    public static let allowedAudiences: Set<IntentAudience> = [
        .plugin,
        .palette,
        .cli,
        .agent,
    ]

    public let name: IntentID
    public let title: String?
    public let description: String?
    public let audiences: Set<IntentAudience>?
    public let effects: IntentEffects?
    public let inputSchema: IntentValue?
    public let outputSchema: IntentValue?
    public let errors: Set<IntentDomainErrorCode>?
    public let palette: PluginPalettePresentation?

    public init(
        name: IntentID,
        title: String? = nil,
        description: String? = nil,
        audiences: Set<IntentAudience>? = nil,
        effects: IntentEffects? = nil,
        inputSchema: IntentValue? = nil,
        outputSchema: IntentValue? = nil,
        errors: Set<IntentDomainErrorCode>? = nil,
        palette: PluginPalettePresentation? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.audiences = audiences
        self.effects = effects
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.errors = errors
        self.palette = palette
    }

    public var isContractReference: Bool {
        title == nil
            && description == nil
            && audiences == nil
            && effects == nil
            && inputSchema == nil
            && outputSchema == nil
            && errors == nil
            && palette == nil
    }

    public func declaration(owner: PluginID) throws -> IntentContractDeclaration? {
        guard !isContractReference else { return nil }
        guard let audiences,
              let effects,
              let inputSchema,
              let outputSchema
        else {
            throw PluginManifestError.partialIntentContract(name)
        }
        return IntentContractDeclaration(
            name: name,
            contractClass: .pluginOwned,
            owner: .plugin(owner),
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            audiences: audiences,
            effects: effects,
            title: title,
            description: description,
            deprecated: false,
            domainErrors: errors ?? []
        )
    }

    fileprivate func validate(owner: PluginID) throws {
        guard !isContractReference else { return }
        guard name.rawValue.hasPrefix(owner.rawValue + ".") else {
            throw PluginManifestError.intentOutsidePluginNamespace(
                intent: name,
                owner: owner
            )
        }
        guard let audiences,
              effects != nil,
              inputSchema != nil,
              outputSchema != nil,
              !audiences.isEmpty
        else {
            throw PluginManifestError.partialIntentContract(name)
        }
        if palette != nil, !audiences.contains(.palette) {
            throw PluginManifestError.paletteIntentMissingAudience(name)
        }
        if let unsupported = audiences
            .subtracting(Self.allowedAudiences)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first
        {
            throw PluginManifestError.unsupportedIntentAudience(
                intent: name,
                audience: unsupported
            )
        }
        _ = try declaration(owner: owner)
    }
}

public struct PluginPalettePresentation: Sendable, Equatable, Codable {
    public let category: String?
    public let icon: String?
    public let keywords: [String]
    public let key: String?
    public let when: String?
    /// Marks a creation verb — something that opens a terminal, a view, an agent. A
    /// launcher surface (the tab strip's `+`) offers exactly these; the palette still
    /// offers everything. Default `false`, so a destructive or navigational command
    /// never volunteers itself under a plus sign.
    public let launcher: Bool

    public init(
        category: String? = nil,
        icon: String? = nil,
        keywords: [String] = [],
        key: String? = nil,
        when: String? = nil,
        launcher: Bool = false
    ) {
        self.category = category
        self.icon = icon
        self.keywords = keywords
        self.key = key
        self.when = when
        self.launcher = launcher
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case category
        case icon
        case keywords
        case key
        case when
        case launcher
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let allFields = try decoder.container(
            keyedBy: AnyCodingKey.self
        )
        let allowedFields = Set(
            CodingKeys.allCases.map(\.rawValue)
        )
        if let unknown = allFields.allKeys.first(
            where: { !allowedFields.contains($0.stringValue) }
        ) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription:
                        "unknown palette field \(unknown.stringValue)"
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decodeIfPresent(
            String.self,
            forKey: .category
        )
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        keywords = try container.decodeIfPresent(
            [String].self,
            forKey: .keywords
        ) ?? []
        key = try container.decodeIfPresent(String.self, forKey: .key)
        when = try container.decodeIfPresent(String.self, forKey: .when)
        launcher = try container.decodeIfPresent(
            Bool.self,
            forKey: .launcher
        ) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(icon, forKey: .icon)
        if !keywords.isEmpty {
            try container.encode(keywords, forKey: .keywords)
        }
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(when, forKey: .when)
        if launcher {
            try container.encode(launcher, forKey: .launcher)
        }
    }
}

public enum PluginManifestError: Error, Sendable, Equatable {
    case invalidName
    case invalidVersion
    case duplicatePermission
    case duplicateSettingKey(String)
    case duplicateIntentUse
    case duplicateIntentProvision
    case partialIntentContract(IntentID)
    case intentOutsidePluginNamespace(intent: IntentID, owner: PluginID)
    case paletteIntentMissingAudience(IntentID)
    case unsupportedIntentAudience(intent: IntentID, audience: IntentAudience)
}

/// The manifest's optional `network` block. Its own type so the allowlist has somewhere
/// to grow (methods, paths, rate limits) without widening `PluginManifest` itself.
public struct PluginNetworkPolicy: Sendable, Equatable, Codable {
    public let allow: [String]

    public init(allow: [String] = []) {
        self.allow = allow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
    }
}

/// One entry in the manifest's optional `settings` array — a value the user can
/// override per plugin, read back through `tenon.settings.get(key)`. Fields the
/// host doesn't know are ignored, like everywhere else in the manifest.
public struct PluginSettingSpec: Sendable, Equatable, Codable {
    public enum SettingType: String, Sendable, Equatable, Codable {
        case string
        case boolean
        case number
        /// A one-of-N choice; its stored value is a `string` from `options`.
        case select
    }

    public let key: String
    public let label: String
    public let type: SettingType
    public let defaultValue: PluginSettingValue?
    /// Choices for a `select` — `nil` for the scalar types. A `select` that omits this
    /// is a plugin bug the UI degrades on, not a manifest decode failure.
    public let options: [PluginSettingOption]?
    /// Section this control sits under in the flat settings view; `nil` groups it into
    /// an unnamed leading section.
    public let group: String?

    public init(
        key: String,
        label: String,
        type: SettingType,
        defaultValue: PluginSettingValue? = nil,
        options: [PluginSettingOption]? = nil,
        group: String? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.options = options
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case key, label, type, options, group
        case defaultValue = "default"
    }
}

/// One choice of a `select` setting: the persisted `value` and its `label` in the UI.
public struct PluginSettingOption: Sendable, Equatable, Codable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// A JSON scalar a setting can hold — exactly the three manifest setting types.
public enum PluginSettingValue: Sendable, Equatable, Codable {
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

    /// The owned value used by settings persistence and runtime boundaries.
    public var intentValue: IntentValue {
        switch self {
        case .string(let string): return .string(string)
        case .boolean(let bool): return .bool(bool)
        case .number(let number): return .number(number)
        }
    }
}

public enum PluginLoadError: Error, Sendable, CustomStringConvertible, Equatable {
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
