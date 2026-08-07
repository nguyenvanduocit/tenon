import Foundation

/// Turns one provider lifecycle hook into the lens facts it carries.
///
/// Claude Code writes its transcript at turn boundaries, so a tool that is still running —
/// and above all a question that is still waiting — exists nowhere on disk while a human
/// is looking at it. The hooks fire at the moment itself and carry the provider's own
/// `tool_use_id`, which is the same identity the transcript later writes, so the live fact
/// and the durable record reconcile into one run rather than two.
///
/// Prose is deliberately not projected here. The transcript is the only source that can
/// anchor a sentence to a byte offset, and a claim a human cannot walk back to its source
/// is exactly what this product refuses to show twice.
///
/// Pure: no clock of its own, no file access, no provider transport. Replaying the same
/// hook sequence yields the same events.
enum AgentHookLensProjection {
    /// One waiting notification per session. A provider that repeats it — Claude Code
    /// re-notifies while a prompt stays unanswered — updates the same decision instead of
    /// stacking duplicates down the timeline.
    static func notificationID(sessionID: String) -> String {
        "hook-notification-\(sessionID)"
    }

    static func events(for event: AgentHookEvent, at capturedAt: Date) -> [AgentLensEvent] {
        // A subagent's hooks describe work nested inside a tool call the root session
        // already shows. Mixing them into the root timeline would report one agent's
        // activity as another's.
        guard event.agentID == nil else { return [] }

        let activity = event.activity
        let evidence = AgentEvidence(
            source: .providerHook,
            authority: .reported,
            location: event.transcriptPath ?? "hook:\(event.sessionID)",
            byteOffset: nil,
            fingerprint: "",
            capturedAt: capturedAt,
            freshness: .current
        )

        switch event.hookEventName {
        case "PreToolUse":
            guard let toolName = activity.toolName, let toolUseID = activity.toolUseID else {
                return []
            }
            let input = object(activity.toolInputJSON)
            var events = started(
                toolName: toolName,
                toolUseID: toolUseID,
                input: input,
                activity: activity,
                evidence: evidence
            )
            // Work resuming is the evidence that a human answered whatever was waiting.
            events.append(
                .interactionResolved(
                    id: notificationID(sessionID: event.sessionID),
                    evidence: evidence
                )
            )
            return events

        case "PostToolUse":
            guard let toolName = activity.toolName, let toolUseID = activity.toolUseID else {
                return []
            }
            let input = object(activity.toolInputJSON)
            let response = value(activity.toolResponseJSON)
            if toolName == "AskUserQuestion" {
                return ClaudeToolFacts.questions(input: input).indices.map { index in
                    .interactionResolved(id: "\(toolUseID)-\(index)", evidence: evidence)
                }
            }
            let presentation = ClaudeToolFacts.presentation(
                toolName: toolName,
                input: input,
                workspaceRoot: activity.workingDirectory
            )
            let completion = ClaudeToolFacts.completion(
                toolName: toolName,
                response: response,
                isError: activity.isToolError
            )
            return [
                .toolFinished(
                    AgentToolRun(
                        id: toolUseID,
                        name: presentation.name,
                        kind: presentation.kind,
                        summary: presentation.summary,
                        detail: completion.detail,
                        state: completion.state,
                        exitCode: completion.exitCode,
                        evidence: evidence
                    )
                ),
            ]

        case "Notification":
            guard let message = activity.message, !message.isEmpty else { return [] }
            return [
                .interactionRequested(
                    AgentInteractionRequest(
                        id: notificationID(sessionID: event.sessionID),
                        kind: .approval,
                        title: message,
                        detail: activity.permissionMode.map { "Permission mode: \($0)" } ?? "",
                        options: [],
                        state: .pending,
                        evidence: evidence
                    )
                ),
            ]

        case "UserPromptSubmit":
            return [
                .interactionResolved(
                    id: notificationID(sessionID: event.sessionID),
                    evidence: evidence
                ),
                .status(.running, evidence: evidence),
            ]

        case "Stop":
            return [.status(.completed, evidence: evidence)]

        default:
            return []
        }
    }

    private static func started(
        toolName: String,
        toolUseID: String,
        input: [String: Any],
        activity: AgentHookActivity,
        evidence: AgentEvidence
    ) -> [AgentLensEvent] {
        // A question is a decision, not an execution step. Projecting it as both would put
        // the same moment on the timeline twice and leave the human choosing which to read.
        if toolName == "AskUserQuestion" {
            return ClaudeToolFacts.questions(input: input).enumerated().map { index, question in
                .interactionRequested(
                    AgentInteractionRequest(
                        id: "\(toolUseID)-\(index)",
                        kind: .question,
                        title: question.prompt,
                        detail: question.header,
                        options: question.options,
                        state: .pending,
                        evidence: evidence
                    )
                )
            }
        }
        let presentation = ClaudeToolFacts.presentation(
            toolName: toolName,
            input: input,
            workspaceRoot: activity.workingDirectory
        )
        return [
            .toolStarted(
                AgentToolRun(
                    id: toolUseID,
                    name: presentation.name,
                    kind: presentation.kind,
                    summary: presentation.summary,
                    detail: "",
                    state: .running,
                    exitCode: nil,
                    evidence: evidence
                )
            ),
        ]
    }

    private static func object(_ json: String?) -> [String: Any] {
        value(json) as? [String: Any] ?? [:]
    }

    private static func value(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
