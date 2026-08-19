// @domain: agent-control
import Foundation
import TenonCore

/// Whether a recorded session can be picked up again, and what to say when it cannot.
///
/// The pane offering `+ Resume` has to answer that BEFORE the person clicks: a button that
/// fails on press teaches nothing, while a button that says "Claude Code is not installed"
/// has already explained the whole situation. So the offer is computed from the same two
/// facts the press would use — which agents this machine has, and how this provider spells a
/// resume — and the reason travels with the refusal instead of being invented at the call
/// site.
enum AgentSessionResumeOffer: Equatable, Sendable {
    /// The command line that continues this session, ready for a shell.
    case ready(commandLine: String)
    /// Why not, in a sentence a person can act on.
    case unavailable(reason: String)

    var commandLine: String? {
        switch self {
        case .ready(let commandLine): commandLine
        case .unavailable: nil
        }
    }

    var reason: String? {
        switch self {
        case .ready: nil
        case .unavailable(let reason): reason
        }
    }
}

enum AgentSessionResume {
    /// Composes through `AgentLaunchComposer` — the one place that turns "run this agent, on
    /// this work" into a command line — rather than spelling `--resume` here. A second speller
    /// would be a second answer to which options this person runs their agent with, and the
    /// composer already carries that: the model and permission mode they actually use come
    /// along, exactly as they do from the Launcher and from the sessions plugin.
    ///
    /// Resuming is always same-provider by construction: the reference names the agent that
    /// recorded the session, so this never reaches the composer's cross-agent handoff. Reading
    /// one agent's session with a different one is `agent.command.v1`'s job and stays there.
    static func offer(
        for ref: AgentSessionRef,
        installed: [AgentLaunchSuggestion],
        continuation: AgentSessionContinuation = .resume
    ) -> AgentSessionResumeOffer {
        let agent = ref.provider.launchAgent
        guard let suggestion = installed.first(where: { $0.agent == agent }) else {
            return .unavailable(
                reason: "\(agent.label) is not installed on this machine, so this session "
                    + "cannot be continued here. The reading above stays available."
            )
        }
        do {
            let plan = try AgentLaunchComposer.plan(
                agent: agent,
                executablePath: suggestion.executableURL.path,
                userArguments: suggestion.arguments,
                prompt: nil,
                session: AgentSessionHandoff(
                    provider: agent,
                    sessionID: ref.sessionID,
                    transcriptPath: ref.transcriptPath,
                    continuation: continuation
                )
            )
            return .ready(commandLine: plan.commandLine)
        } catch AgentLaunchPlanError.invalidSessionIdentifier {
            return .unavailable(
                reason: "\(agent.label) cannot resume this session: its identifier is not one "
                    + "the CLI accepts."
            )
        } catch {
            return .unavailable(
                reason: "\(agent.label) cannot be started with the options recorded for it "
                    + "on this machine."
            )
        }
    }
}

extension AgentSessionProvider {
    /// The CLI that recorded this session, which is the only one that can resume it.
    var launchAgent: AgentCLI {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}
