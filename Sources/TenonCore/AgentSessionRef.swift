// @domain: workspace-model
import Foundation

/// Which agent CLI recorded a session.
///
/// Deliberately not `AgentCLI`: that type answers which provider the host can invoke now;
/// this one is durable session provenance held by the workspace value tree. A recorded
/// provider may remain meaningful after its executable support changes, so the two closed
/// vocabularies stay explicit and are bridged by one mapping at the app boundary.
public enum AgentSessionProvider: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case codex
    case claude
    case opencode

    /// The file shape a recorded transcript takes on disk. Codex and Claude Code write
    /// line-delimited JSON; opencode keeps its parts in a SQLite database.
    public var transcriptFileExtension: String {
        switch self {
        case .codex, .claude: "jsonl"
        case .opencode: "db"
        }
    }
}

/// A session that has already happened, named well enough to open a pane over it.
///
/// Every field is bounded at construction because the first caller is a plugin: the Agent
/// Sessions list hands this host a path and an id it chose. `init?` is the only way to make
/// one, so a malformed reference cannot exist far enough into the host to become a pane —
/// refusal is a `nil` at the door rather than an empty pane with a broken title.
///
/// It says nothing about whether the transcript is READABLE, and cannot: containment under an
/// allowed provider root is a filesystem question decided with symlinks resolved, which the
/// workspace value tree has no business asking. `AgentTranscriptPath` asks it at the app
/// boundary before this reference is ever built.
public struct AgentSessionRef: Equatable, Sendable, Hashable {
    /// Long enough for both providers' identifiers — a Claude Code session id is a UUID, a
    /// Codex rollout id carries a timestamp — and short enough that no id can be used to carry
    /// a payload through the workspace catalog.
    public static let sessionIDLimit = 256
    public static let transcriptPathLimit = 4_096
    public static let titleLimit = 1_024

    public let provider: AgentSessionProvider
    public let sessionID: String
    public let transcriptPath: String
    /// What the list called this session, kept only so the pane's chrome can name it. Absent
    /// is normal and drawn from the session id instead.
    public let title: String?

    public init?(
        provider: AgentSessionProvider,
        sessionID: String,
        transcriptPath: String,
        title: String? = nil
    ) {
        let trimmedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              trimmedID.count <= Self.sessionIDLimit,
              trimmedID.unicodeScalars.allSatisfy({ !CharacterSet.newlines.contains($0) }),
              !trimmedID.contains("/")
        else { return nil }

        // Absolute and a recognized provider transcript shape are shape, not permission: the
        // containment question is asked before this initializer with symlinks resolved.
        // Refusing the obviously-wrong shapes here keeps a relative path from reaching a
        // pane through a route that never asked.
        guard transcriptPath.hasPrefix("/"),
              transcriptPath.count <= Self.transcriptPathLimit,
              transcriptPath.hasSuffix(".\(provider.transcriptFileExtension)"),
              transcriptPath.unicodeScalars.allSatisfy({ !CharacterSet.newlines.contains($0) })
        else { return nil }

        self.provider = provider
        self.sessionID = trimmedID
        self.transcriptPath = transcriptPath
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.titleLimit))
        } else {
            self.title = nil
        }
    }

    /// What the pane's chrome calls this session.
    public var displayName: String {
        title ?? "\(provider.rawValue) \(sessionID.prefix(8))"
    }
}
