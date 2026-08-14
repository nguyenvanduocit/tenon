// @domain: companion
import Foundation

/// The app-wide defaults for short, host-owned AI assistance tasks.
///
/// A task still owns its schema, evidence bounds, timeout, and cancellation. The Companion
/// owns only the person's reusable provider choices, so a feature never needs to hard-code
/// Claude, Haiku, reusable instructions, or a process working directory again.
public struct CompanionProfile: Codable, Equatable, Sendable {
    public static let maximumModelBytes = 120
    public static let maximumPromptBytes = 8 << 10
    public static let maximumWorkingDirectoryBytes = 4 << 10

    public var agent: AgentCLI {
        didSet {
            guard agent != oldValue else { return }
            model = Self.defaultModel(for: agent)
        }
    }
    public var model: String {
        didSet { model = Self.bounded(model, maximumBytes: Self.maximumModelBytes) }
    }
    public var customPrompt: String {
        didSet {
            customPrompt = Self.bounded(
                customPrompt,
                maximumBytes: Self.maximumPromptBytes
            )
        }
    }
    /// An absolute directory path, or the empty string to let each task choose a safe fallback.
    public var workingDirectory: String {
        didSet {
            workingDirectory = Self.bounded(
                workingDirectory,
                maximumBytes: Self.maximumWorkingDirectoryBytes
            )
        }
    }

    public init(
        agent: AgentCLI = .claude,
        model: String? = nil,
        customPrompt: String = "",
        workingDirectory: String = ""
    ) {
        self.agent = agent
        self.model = Self.normalizedModel(
            model ?? Self.defaultModel(for: agent),
            for: agent
        )
        self.customPrompt = Self.bounded(
            customPrompt,
            maximumBytes: Self.maximumPromptBytes
        )
        self.workingDirectory = Self.bounded(
            workingDirectory,
            maximumBytes: Self.maximumWorkingDirectoryBytes
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        let decodedAgent = try? container.decode(AgentCLI.self, forKey: .agent)
        agent = decodedAgent ?? defaults.agent
        model = Self.normalizedModel(
            decodedAgent == nil
                ? Self.defaultModel(for: agent)
                : try container.decodeIfPresent(String.self, forKey: .model)
                    ?? Self.defaultModel(for: agent),
            for: agent
        )
        customPrompt = Self.bounded(
            try container.decodeIfPresent(String.self, forKey: .customPrompt)
                ?? defaults.customPrompt,
            maximumBytes: Self.maximumPromptBytes
        )
        workingDirectory = Self.bounded(
            try container.decodeIfPresent(String.self, forKey: .workingDirectory)
                ?? defaults.workingDirectory,
            maximumBytes: Self.maximumWorkingDirectoryBytes
        )
    }

    public static func defaultModel(for agent: AgentCLI) -> String {
        switch agent {
        case .claude: "haiku"
        case .codex: ""
        }
    }

    /// Nil means "use the provider's configured default model".
    public var modelArgument: String? {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public var customPromptArgument: String? {
        let value = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public var workingDirectoryURL: URL? {
        let value = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        var byteCount = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result
    }

    private static func normalizedModel(_ value: String, for agent: AgentCLI) -> String {
        let bounded = bounded(value, maximumBytes: maximumModelBytes)
        if agent == .codex,
           bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultModel(for: .claude)
        {
            return defaultModel(for: .codex)
        }
        return bounded
    }
}
