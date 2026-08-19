// @domain: agent-lens
import Foundation
import TenonCore

/// What an Agent Lens pane is attached TO, and what that permits.
///
/// A lens pane has always meant one thing — a live PTY someone is typing into — and every
/// capability followed from that without ever being written down: discovery polls because
/// there is a foreground process to poll, the composer draws because there is a terminal to
/// write to, an option can be answered because the agent is waiting for the answer. Reading a
/// session that has already finished keeps the whole reading and none of those.
///
/// This is that difference as one value, so the rules are asserted headlessly instead of being
/// re-derived by each view that draws a button. Every capability below is stated as what the
/// attachment ALLOWS, never as "not recorded" scattered across call sites: a later third kind
/// of attachment then answers each question once, here, rather than in each `if`.
enum AgentLensAttachment: Equatable, Sendable {
    /// A terminal running an agent right now, found by discovery.
    case live
    /// A transcript on disk. There is no process, and the pane holds no surface.
    case recorded(AgentSessionRef)

    var recordedSession: AgentSessionRef? {
        switch self {
        case .live: nil
        case .recorded(let ref): ref
        }
    }

    /// Whether the pane polls for a foreground process. A recorded session has none — there is
    /// nothing to find, and a poll that keeps missing would report the session as ended.
    var startsDiscovery: Bool {
        switch self {
        case .live: true
        case .recorded: false
        }
    }

    /// Whether anything the person types can reach an agent.
    ///
    /// A recorded pane can never say yes, whatever the transcript contains. A finished session
    /// that ends mid-question still carries a pending request, and the snapshot built from it
    /// therefore still reports the session as answerable: this is the rule that stops the pane
    /// offering to answer a question nobody is waiting for.
    var allowsSending: Bool {
        switch self {
        case .live: true
        case .recorded: false
        }
    }

    /// Whether the pane mounts a terminal surface at all. A recorded pane holds no PTY until
    /// someone resumes it, and mounting one would start a shell nobody asked for.
    var holdsTerminalSurface: Bool {
        switch self {
        case .live: true
        case .recorded: false
        }
    }

    /// Whether the pane offers to resume the session into a live one.
    var offersResume: Bool {
        switch self {
        case .live: false
        case .recorded: true
        }
    }

    /// What discovery would have returned, had there been a process to discover.
    ///
    /// A recorded attachment is `.exact` by construction and not by inference: the transcript
    /// was named by the session list and proven to resolve under a provider root before the
    /// reference existed, which is a stronger claim than the cwd match `.inferred` marks. The
    /// PID is zero because there is no process, and nothing may treat it as one — the input
    /// queue that would use it is not built for a recorded attachment.
    var resolution: AgentLensResolution? {
        guard case .recorded(let ref) = self else { return nil }
        return AgentLensResolution(
            provider: ref.provider.lensProvider,
            sessionID: ref.sessionID,
            foregroundPID: 0,
            transcriptURL: URL(fileURLWithPath: ref.transcriptPath),
            confidence: .exact,
            detail: "Recorded session"
        )
    }
}

extension AgentSessionProvider {
    /// The workspace's name for a provider, read as the lens's name for it.
    ///
    /// Two enums exist because they answer to different owners — `AgentSessionProvider` is
    /// workspace content that survives a restart, `AgentProvider` is what a lens reads — and
    /// this is the single crossing between them rather than a `rawValue` comparison repeated
    /// wherever the two meet.
    var lensProvider: AgentProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}

extension AgentProvider {
    var sessionProvider: AgentSessionProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}
