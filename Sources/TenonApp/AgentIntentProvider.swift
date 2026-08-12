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
        let questionPending: IntentErrorCode
        let questionCapacity: IntentErrorCode
        let questionPaneClosed: IntentErrorCode

        init() throws {
            unavailable = .domain(
                try IntentDomainErrorCode("dev.tenon.core.agent-unavailable")
            )
            handoffUnresolved = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.agent-handoff-unresolved"
                )
            )
            questionPending = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.agent-question-pending"
                )
            )
            questionCapacity = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.agent-question-capacity"
                )
            )
            questionPaneClosed = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.agent-question-pane-closed"
                )
            )
        }
    }

    private let detector: AgentLaunchDetector
    private let questions: AgentAskStore
    private let codes: ErrorCodes

    init(
        detector: AgentLaunchDetector = AgentLaunchDetector(),
        questions: AgentAskStore = AgentAskStore()
    ) throws {
        self.detector = detector
        self.questions = questions
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
            IntentProviderBinding(
                intentID: try CoreIntentName.agentAsk.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.ask(envelope: envelope)
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

    func ask(envelope: IntentEnvelope) async -> IntentProviderReply {
        do {
            guard let paneID = envelope.scope.paneID else {
                throw AppIntentInputError.missingOrInvalidField("scope.paneID")
            }
            let object = try AppIntentProviderSupport.object(envelope.input)
            let result = try await questions.ask(
                AgentAskRequest(
                    paneID: paneID,
                    asker: envelope.caller,
                    recipient: try recipient(in: object),
                    question: try AppIntentProviderSupport.string(
                        "question",
                        in: object
                    ),
                    choices: try choices(in: object),
                    evidence: try evidence(in: object),
                    timeoutMilliseconds: try requiredInteger(
                        "timeoutMs",
                        in: object
                    )
                )
            )
            return .success(.object([
                "questionID": .string(result.questionID.uuidString),
                "status": .string(result.status.rawValue),
                "value": result.value ?? .null,
            ]))
        } catch AgentAskStoreError.questionAlreadyPending {
            return AppIntentProviderSupport.failure(
                code: codes.questionPending,
                reason: "pane-already-has-question"
            )
        } catch AgentAskStoreError.capacityExceeded {
            return AppIntentProviderSupport.failure(
                code: codes.questionCapacity,
                reason: "question-capacity-reached",
                retryable: true
            )
        } catch AgentAskStoreError.paneClosed {
            return AppIntentProviderSupport.failure(
                code: codes.questionPaneClosed,
                reason: "pane-closed"
            )
        } catch is CancellationError {
            return .failure(IntentProviderFailure(code: .kernel(.cancelled)))
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func recipient(
        in object: [String: IntentValue]
    ) throws -> AgentQuestionRecipient {
        guard case let .object(recipient)? = object["recipient"] else {
            throw AppIntentInputError.missingOrInvalidField("recipient")
        }
        switch try AppIntentProviderSupport.string("kind", in: recipient) {
        case "human":
            return .human
        case "agent":
            let revision = try requiredInteger(
                "sessionRevision",
                in: recipient
            )
            guard let revision = UInt64(exactly: revision) else {
                throw AppIntentInputError.missingOrInvalidField(
                    "recipient.sessionRevision"
                )
            }
            return .agent(
                AppIntentRuntime.agentQuestionRecipientPrincipal(
                    id: try AppIntentProviderSupport.string(
                        "principalID",
                        in: recipient
                    ),
                    sessionRevision: revision
                )
            )
        default:
            throw AppIntentInputError.missingOrInvalidField("recipient.kind")
        }
    }

    func choices(
        in object: [String: IntentValue]
    ) throws -> [AgentQuestionChoice] {
        try AppIntentProviderSupport.objectArray("choices", in: object).map {
            choice in
            guard let value = choice["value"] else {
                throw AppIntentInputError.missingOrInvalidField("choices.value")
            }
            return AgentQuestionChoice(
                id: try AppIntentProviderSupport.string("id", in: choice),
                label: try AppIntentProviderSupport.string("label", in: choice),
                value: value
            )
        }
    }

    func evidence(
        in object: [String: IntentValue]
    ) throws -> [AgentQuestionEvidence] {
        try AppIntentProviderSupport.objectArray("evidence", in: object).map {
            item in
            AgentQuestionEvidence(
                label: try AppIntentProviderSupport.string("label", in: item),
                url: try AppIntentProviderSupport.string("url", in: item)
            )
        }
    }

    func requiredInteger(
        _ key: String,
        in object: [String: IntentValue]
    ) throws -> Int {
        guard let value = try AppIntentProviderSupport.optionalInteger(
            key,
            in: object
        ) else {
            throw AppIntentInputError.missingOrInvalidField(key)
        }
        return value
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
