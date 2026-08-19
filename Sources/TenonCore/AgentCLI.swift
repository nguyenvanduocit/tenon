// @domain: agent-control, companion
import Foundation

/// Coding-agent executables the host knows how to invoke.
///
/// This vocabulary lives in the headless module because both interactive agent launch and
/// the persisted Companion profile name the same providers. Provider-specific command-line
/// mechanics remain in `TenonApp`, beside the subprocesses they drive.
public enum AgentCLI: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .opencode: "opencode"
        }
    }

    public var executableName: String { rawValue }
}
