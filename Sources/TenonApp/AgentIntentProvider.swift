// @domain: agent-control
import Foundation
import TenonCore
import TenonIntentCore

/// The public boundary over the host's own agent detection.
///
/// The Launcher has always known which agents this person has and which options they pass;
/// every plugin that started an agent had to guess. These two read-only contracts hand that
/// same answer across the principal boundary — one lists, the other composes — while the
/// pane that ends up running the command stays owned by `terminal.open.v1`.
@MainActor
final class AgentIntentProvider {
    private struct ErrorCodes {
        let unavailable: IntentErrorCode
        let handoffUnresolved: IntentErrorCode

        init() throws {
            unavailable = .domain(
                try IntentDomainErrorCode("dev.tenon.core.agent-unavailable")
            )
            handoffUnresolved = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.agent-handoff-unresolved"
                )
            )
        }
    }

    private let detector: AgentLaunchDetector
    private let codes: ErrorCodes

    init(detector: AgentLaunchDetector = AgentLaunchDetector()) throws {
        self.detector = detector
        codes = try ErrorCodes()
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.agentInventory.intentID
            ) { _, context in
                try context.checkCancellation()
                let reply = await self.inventory()
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.agentCommand.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.command(envelope: envelope)
                try context.checkCancellation()
                return reply
            },
        ]
    }
}

private extension AgentIntentProvider {
    /// Detection is re-read per call rather than cached: a habit that changed an hour ago is
    /// the whole point of asking, and the read is bounded to the tail of the history files.
    func installed() async -> [AgentLaunchSuggestion] {
        let detector = detector
        return await Task.detached(priority: .userInitiated) {
            detector.scan()
        }.value
    }

    func inventory() async -> IntentProviderReply {
        let agents = await installed().map { suggestion in
            IntentValue.object([
                "id": .string(suggestion.agent.rawValue),
                "label": .string(suggestion.agent.label),
                "arguments": .array(suggestion.arguments.map(IntentValue.string)),
                "habit": suggestion.habitDescription.map(IntentValue.string)
                    ?? .null,
            ])
        }
        return .success(.object(["agents": .array(agents)]))
    }

    func command(envelope: IntentEnvelope) async -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let requested = try AppIntentProviderSupport.string("agent", in: object)
            guard let agent = AgentCLI(rawValue: requested) else {
                return AppIntentProviderSupport.failure(
                    code: codes.unavailable,
                    reason: "unknown-agent"
                )
            }
            guard let suggestion = await installed().first(
                where: { $0.agent == agent }
            ) else {
                return AppIntentProviderSupport.failure(
                    code: codes.unavailable,
                    reason: "agent-not-installed"
                )
            }

            let prompt = try AppIntentProviderSupport.optionalString(
                "prompt",
                in: object
            )
            let includeUserOptions = try AppIntentProviderSupport.optionalBool(
                "includeUserOptions",
                in: object
            ) ?? true
            let session = try self.session(in: object)

            let plan = try AgentLaunchComposer.plan(
                agent: agent,
                executablePath: suggestion.executableURL.path,
                userArguments: includeUserOptions ? suggestion.arguments : [],
                prompt: prompt,
                session: session
            )
            return .success(.object([
                "agent": .string(plan.agent.rawValue),
                "commandLine": .string(plan.commandLine),
                "arguments": .array(plan.arguments.map(IntentValue.string)),
                "handoff": .bool(plan.handoff),
            ]))
        } catch AgentLaunchPlanError.handoffTranscriptRequired {
            return AppIntentProviderSupport.failure(
                code: codes.handoffUnresolved,
                reason: "transcript-path-required"
            )
        } catch AgentLaunchPlanError.invalidSessionIdentifier {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("session.sessionID")
            )
        } catch let AgentLaunchPlanError.unusableText(field) {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField(field)
            )
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    /// The session's own agent need not be installed — it recorded a transcript, it does not
    /// have to run again — so only its name has to be one Tenon knows.
    func session(
        in object: [String: IntentValue]
    ) throws -> AgentSessionHandoff? {
        guard let field = object["session"] else { return nil }
        guard case let .object(session) = field else {
            throw AppIntentInputError.missingOrInvalidField("session")
        }
        let name = try AppIntentProviderSupport.string("agent", in: session)
        guard let provider = AgentCLI(rawValue: name) else {
            throw AppIntentInputError.missingOrInvalidField("session.agent")
        }
        return AgentSessionHandoff(
            provider: provider,
            sessionID: try AppIntentProviderSupport.string(
                "sessionID",
                in: session
            ),
            transcriptPath: try AppIntentProviderSupport.optionalString(
                "transcriptPath",
                in: session
            )
        )
    }
}
