// @domain: agent-control
import Foundation
import TenonCore

/// The session a launch is continuing: which agent recorded it, its identifier, and where
/// its transcript sits on this machine. The transcript matters only when the agent about to
/// run is not the one that wrote it.
struct AgentSessionHandoff: Equatable, Sendable {
    let provider: AgentCLI
    let sessionID: String
    let transcriptPath: String?
}

/// One composed invocation: the argument vector after the executable, the shell-ready line,
/// and whether the agent is picking up a session another agent recorded.
struct AgentLaunchPlan: Equatable, Sendable {
    let agent: AgentCLI
    let arguments: [String]
    let commandLine: String
    let handoff: Bool
}

enum AgentLaunchPlanError: Error, Equatable, Sendable {
    case handoffTranscriptRequired
    case invalidSessionIdentifier
    case unusableText(String)
}

/// The one place that turns "run this agent, on this work" into a command line.
///
/// It exists because the alternative was measured: every plugin that started an agent wrote
/// its own `"claude " + quote(prompt)`, so the options a person actually runs their agent
/// with — the model, the permission mode — reached the Launcher and nothing else, and each
/// caller re-derived quoting and provider argument order for itself.
///
/// Two rules carry the provider knowledge. Options this person passes come first, because
/// `codex` takes its options ahead of its subcommand and `claude` does not care. A resume is
/// spelled the provider's own way, and only for the provider that recorded the session:
/// across providers there is no flag to spell it with, so the session arrives as a prompt
/// naming its transcript and the other agent reads the content itself.
enum AgentLaunchComposer {
    static func plan(
        agent: AgentCLI,
        executablePath: String,
        userArguments: [String],
        prompt: String?,
        session: AgentSessionHandoff?
    ) throws -> AgentLaunchPlan {
        guard executablePath.hasPrefix("/"), isPlain(executablePath) else {
            throw AgentLaunchPlanError.unusableText("executablePath")
        }
        for argument in userArguments where !isPlain(argument) {
            throw AgentLaunchPlanError.unusableText("arguments")
        }
        if let prompt, !isProse(prompt) {
            throw AgentLaunchPlanError.unusableText("prompt")
        }

        var arguments = userArguments
        var handoff = false

        if let session {
            guard isIdentifier(session.sessionID) else {
                throw AgentLaunchPlanError.invalidSessionIdentifier
            }
            if session.provider == agent {
                arguments += resumeArguments(agent: agent, sessionID: session.sessionID)
                if let prompt, !prompt.isEmpty { arguments.append(prompt) }
            } else {
                guard let transcript = session.transcriptPath, !transcript.isEmpty else {
                    throw AgentLaunchPlanError.handoffTranscriptRequired
                }
                guard transcript.hasPrefix("/"), isPlain(transcript) else {
                    throw AgentLaunchPlanError.unusableText("transcriptPath")
                }
                handoff = true
                arguments.append(
                    handoffPrompt(
                        recordedBy: session.provider,
                        transcriptPath: transcript,
                        callerPrompt: prompt
                    )
                )
            }
        } else if let prompt, !prompt.isEmpty {
            arguments.append(prompt)
        }

        let commandLine = ([executablePath] + arguments)
            .map(AutomationAuthoring.posixQuoted)
            .joined(separator: " ")

        return AgentLaunchPlan(
            agent: agent,
            arguments: arguments,
            commandLine: commandLine,
            handoff: handoff
        )
    }

    /// How each provider spells "continue the session you recorded".
    private static func resumeArguments(
        agent: AgentCLI,
        sessionID: String
    ) -> [String] {
        switch agent {
        case .claude: ["--resume", sessionID]
        case .codex: ["resume", sessionID]
        }
    }

    /// What one agent is told about another agent's session. The transcript is named, its
    /// format is stated, and the reading order is the cheap one — a live session's file runs
    /// to megabytes, and the end of it is what "where were we" actually means.
    static func handoffPrompt(
        recordedBy provider: AgentCLI,
        transcriptPath: String,
        callerPrompt: String?
    ) -> String {
        var text = """
        You are continuing a session that was recorded by \(provider.label), not by you. \
        Its full transcript is on this machine at:

          \(transcriptPath)

        That file is JSON Lines — one JSON record per line, oldest first. Read the end of it \
        first to recover what was happening, then read further back only as far as you need. \
        Before changing anything, tell me what that session was doing and what it left \
        unfinished.
        """
        if let callerPrompt, !callerPrompt.isEmpty {
            text += "\n\nThen: " + callerPrompt
        }
        return text
    }

    /// A session identifier is a UUID or a name a provider minted. Anything with a space, a
    /// shell metacharacter, or a leading dash is not one, and would reach a command line as
    /// an option rather than as an id.
    private static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    /// No control characters at all: an escape sequence in an argument is a terminal
    /// instruction wearing the costume of a word.
    private static func isPlain(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !isControl($0) }
    }

    /// Prose may wrap and indent; it still may not steer a terminal.
    private static func isProse(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar == "\n" || scalar == "\t" || !isControl(scalar)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
