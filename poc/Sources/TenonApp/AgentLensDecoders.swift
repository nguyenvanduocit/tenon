// @domain: agent-lens
import CryptoKit
import Foundation

enum AgentLensDecodeError: Error, Equatable, Sendable {
    case malformedJSON
    case recordTooLarge
}

struct AgentTranscriptDecoder: Sendable {
    private static let outputLimit = 64 << 10
    private static let subagentOperationNames: Set<String> = [
        "followup_task",
        "interrupt_agent",
        "list_agents",
        "send_message",
        "spawn_agent",
        "wait_agent",
    ]

    let provider: AgentProvider

    func decode(line: Data, byteOffset: UInt64, location: String) throws -> [AgentLensEvent] {
        guard line.count <= 2 << 20 else { throw AgentLensDecodeError.recordTooLarge }
        guard let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { throw AgentLensDecodeError.malformedJSON }
        let evidence = Self.evidence(
            source: .transcript,
            authority: .reported,
            location: location,
            byteOffset: byteOffset,
            data: line,
            timestamp: Self.timestamp(record["timestamp"])
        )
        switch provider {
        case .claude:
            return decodeClaude(record, evidence: evidence, byteOffset: byteOffset)
        case .codex:
            return decodeCodex(record, evidence: evidence, byteOffset: byteOffset)
        }
    }

    private func decodeClaude(
        _ record: [String: Any],
        evidence: AgentEvidence,
        byteOffset: UInt64
    ) -> [AgentLensEvent] {
        guard let recordType = record["type"] as? String,
              recordType == "user" || recordType == "assistant",
              let message = record["message"] as? [String: Any]
        else { return [] }

        let fallbackID = "claude-\(byteOffset)"
        let messageID = Self.string(record["uuid"]) ?? Self.string(message["id"]) ?? fallbackID
        // Claude Code stamps every record with the directory the call ran in, which is what
        // lets a path be shown the way a person recognizes it.
        let workspaceRoot = Self.string(record["cwd"])
        let blocks = Self.contentBlocks(message["content"])
        var events: [AgentLensEvent] = []
        var visibleTexts: [String] = []
        var reasoningTexts: [String] = []

        for (index, block) in blocks.enumerated() {
            let type = Self.string(block["type"]) ?? "text"
            switch type {
            case "text", "input_text", "output_text":
                if let text = Self.string(block["text"]), !text.isEmpty {
                    visibleTexts.append(text)
                }
            case "thinking", "reasoning":
                if let text = Self.string(block["thinking"]) ?? Self.string(block["text"]),
                   !text.isEmpty
                {
                    reasoningTexts.append(text)
                }
            case "tool_use":
                let id = Self.string(block["id"]) ?? "\(messageID)-tool-\(index)"
                let rawName = Self.string(block["name"]) ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                // A question is a decision, and it carries the same identity the live hook
                // gives it, so the record of one that was already answered reconciles with
                // it instead of appearing again as a fresh prompt.
                if rawName == "AskUserQuestion" {
                    for (questionIndex, question) in ClaudeToolFacts.questions(input: input)
                        .enumerated()
                    {
                        events.append(
                            .interactionRequested(
                                AgentInteractionRequest(
                                    id: "\(id)-\(questionIndex)",
                                    kind: .question,
                                    title: question.prompt,
                                    detail: question.header,
                                    options: question.options,
                                    state: .pending,
                                    evidence: evidence
                                )
                            )
                        )
                    }
                    break
                }
                let presentation = ClaudeToolFacts.presentation(
                    toolName: rawName,
                    input: input,
                    workspaceRoot: workspaceRoot
                )
                events.append(
                    .toolStarted(
                        AgentToolRun(
                            id: id,
                            name: presentation.name,
                            kind: presentation.kind,
                            summary: presentation.summary,
                            detail: presentation.kind == .plan
                                ? Self.planDetail(Self.summary(block["input"]))
                                : "",
                            state: .running,
                            exitCode: nil,
                            evidence: evidence
                        )
                    )
                )
            case "tool_result":
                let id = Self.string(block["tool_use_id"]) ?? "\(messageID)-result-\(index)"
                let isError = block["is_error"] as? Bool == true
                // Claude Code keeps the structured result beside the message rather than
                // inside the block: exit status, the patch a file edit applied, the answers
                // a question received.
                let result = record["toolUseResult"]
                let answers = ClaudeToolFacts.answers(response: result)
                if !answers.isEmpty {
                    for answerIndex in answers.indices {
                        events.append(
                            .interactionResolved(id: "\(id)-\(answerIndex)", evidence: evidence)
                        )
                    }
                    break
                }
                let completion = ClaudeToolFacts.completion(
                    toolName: "",
                    response: result,
                    isError: isError
                )
                let detail = completion.detail.isEmpty
                    ? Self.capped(Self.contentText(block["content"]))
                    : completion.detail
                events.append(
                    .toolFinished(
                        AgentToolRun(
                            id: id,
                            name: "Tool",
                            summary: "",
                            detail: detail,
                            state: completion.state,
                            exitCode: completion.exitCode,
                            evidence: evidence
                        )
                    )
                )
            default:
                break
            }
        }

        if !reasoningTexts.isEmpty {
            events.append(
                .reasoning(
                    AgentLensMessage(
                        id: "\(messageID)-reasoning",
                        role: .reasoning,
                        text: reasoningTexts.joined(separator: "\n\n"),
                        isStreaming: false,
                        evidence: evidence
                    )
                )
            )
        }

        let visibleText = visibleTexts.joined(separator: "\n\n")
        if visibleText.contains(where: { !$0.isWhitespace }) {
            let role: AgentMessageRole = recordType == "user" ? .user : .assistant
            let kind = Self.messageKind(role: role, text: visibleText)
            let value = AgentLensMessage(
                id: messageID,
                role: role,
                kind: kind,
                text: visibleText,
                isStreaming: false,
                evidence: evidence
            )
            if kind != .conversation {
                events.append(.contextMessage(value))
            } else {
                events.append(recordType == "user" ? .userMessage(value) : .assistantMessage(value))
            }
        }
        return events
    }

    private func decodeCodex(
        _ record: [String: Any],
        evidence: AgentEvidence,
        byteOffset: UInt64
    ) -> [AgentLensEvent] {
        guard let payload = record["payload"] as? [String: Any] else { return [] }
        let baseID = Self.string(payload["id"]) ?? Self.string(payload["call_id"])
            ?? "codex-\(byteOffset)"

        switch Self.string(record["type"]) {
        case "response_item":
            return Self.codexItem(payload, id: baseID, completed: true, evidence: evidence)

        case "event_msg":
            switch Self.string(payload["type"]) {
            case "user_message":
                guard let text = Self.string(payload["message"]), !text.isEmpty else { return [] }
                return [
                    .userMessage(
                        AgentLensMessage(
                            id: baseID,
                            role: .user,
                            text: text,
                            isStreaming: false,
                            evidence: evidence
                        )
                    ),
                ]
            case "agent_message":
                guard let text = Self.string(payload["message"]), !text.isEmpty else { return [] }
                return [
                    .assistantMessage(
                        AgentLensMessage(
                            id: baseID,
                            role: .assistant,
                            text: text,
                            isStreaming: false,
                            evidence: evidence
                        )
                    ),
                ]
            case "turn_started", "task_started":
                return [.status(.running, evidence: evidence)]
            case "turn_complete", "turn_completed", "task_complete", "task_completed":
                return [.status(.completed, evidence: evidence)]
            case "turn_aborted", "task_aborted", "task_failed":
                return [.status(.failed("Turn interrupted"), evidence: evidence)]
            default:
                return []
            }
        default:
            return []
        }
    }

    fileprivate static func codexItem(
        _ item: [String: Any],
        id: String,
        completed: Bool,
        evidence: AgentEvidence
    ) -> [AgentLensEvent] {
        let itemType = string(item["type"])
        switch itemType {
        case "userMessage":
            let text = contentText(item["content"])
            guard !text.isEmpty else { return [] }
            let kind = messageKind(role: .user, text: text)
            let message = AgentLensMessage(
                id: id,
                role: .user,
                kind: kind,
                text: text,
                isStreaming: !completed,
                evidence: evidence
            )
            return kind == .conversation ? [.userMessage(message)] : [.contextMessage(message)]

        case "message":
            let text = contentText(item["content"])
            guard !text.isEmpty else { return [] }
            guard let role = messageRole(string(item["role"])) else { return [] }
            let message = AgentLensMessage(
                id: id,
                role: role,
                kind: messageKind(role: role, text: text),
                text: text,
                isStreaming: !completed,
                evidence: evidence
            )
            if message.kind != .conversation {
                return [.contextMessage(message)]
            }
            switch role {
            case .assistant:
                return [.assistantMessage(message)]
            case .user:
                return [.userMessage(message)]
            case .system, .developer:
                return [.contextMessage(message)]
            case .reasoning:
                return [.reasoning(message)]
            }

        case "agentMessage":
            guard let text = string(item["text"]), !text.isEmpty else { return [] }
            return [
                .assistantMessage(
                    AgentLensMessage(
                        id: id,
                        role: .assistant,
                        text: text,
                        isStreaming: !completed,
                        evidence: evidence
                    )
                ),
            ]

        case "reasoning":
            let text = string(item["text"]) ?? stringArray(item["summary"]).joined(separator: "\n")
            guard !text.isEmpty else { return [] }
            return [
                .reasoning(
                    AgentLensMessage(
                        id: id,
                        role: .reasoning,
                        text: text,
                        isStreaming: !completed,
                        evidence: evidence
                    )
                ),
            ]

        case "function_call", "local_shell_call", "custom_tool_call":
            let rawName = string(item["name"]) ?? (itemType == "local_shell_call" ? "local_shell_call" : "Tool")
            let input = summary(item["arguments"] ?? item["input"] ?? item["action"])
            let kind = toolKind(name: rawName, input: input)
            let name = toolName(rawName, kind: kind, input: input)
            return [
                .toolStarted(
                    AgentToolRun(
                        id: string(item["call_id"]) ?? id,
                        name: name,
                        kind: kind,
                        summary: toolSummary(input, name: name, kind: kind),
                        detail: kind == .plan ? planDetail(input) : "",
                        state: .running,
                        exitCode: nil,
                        evidence: evidence
                    )
                ),
            ]

        case "function_call_output", "custom_tool_call_output":
            let output = item["output"]
            let outputRecord = output as? [String: Any]
            let failed = outputRecord?["success"] as? Bool == false ||
                outputRecord?["is_error"] as? Bool == true
            return [
                .toolFinished(
                    AgentToolRun(
                        id: string(item["call_id"]) ?? id,
                        name: "Tool",
                        summary: failed ? "Tool failed" : "Tool completed",
                        detail: capped(contentText(outputRecord?["content"] ?? output)),
                        state: failed ? .failed : .succeeded,
                        exitCode: nil,
                        evidence: evidence
                    )
                ),
            ]

        case "commandExecution":
            let status = string(item["status"]) ?? (completed ? "completed" : "inProgress")
            let state = toolState(status: status, exitCode: item["exitCode"] as? Int)
            let tool = AgentToolRun(
                id: id,
                name: "Command",
                kind: .command,
                summary: string(item["command"]) ?? "Shell command",
                detail: capped(string(item["aggregatedOutput"]) ?? ""),
                state: state,
                exitCode: item["exitCode"] as? Int,
                evidence: observedCopy(evidence)
            )
            return [completed || state != .running ? .toolFinished(tool) : .toolStarted(tool)]

        case "fileChange":
            let status = string(item["status"]) ?? (completed ? "completed" : "inProgress")
            let tool = AgentToolRun(
                id: id,
                name: "File change",
                kind: .fileChange,
                summary: changesSummary(item["changes"]),
                detail: "",
                state: toolState(status: status, exitCode: nil),
                exitCode: nil,
                evidence: observedCopy(evidence)
            )
            return [completed ? .toolFinished(tool) : .toolStarted(tool)]

        case "mcpToolCall", "dynamicToolCall":
            let name = string(item["tool"]) ?? "Tool"
            let server = string(item["server"])
            let status = string(item["status"]) ?? (completed ? "completed" : "inProgress")
            let tool = AgentToolRun(
                id: id,
                name: server.map { "\($0) / \(name)" } ?? name,
                summary: summary(item["arguments"]),
                detail: capped(summary(item["result"] ?? item["contentItems"] ?? item["error"])),
                state: toolState(status: status, exitCode: nil),
                exitCode: nil,
                evidence: evidence
            )
            return [completed ? .toolFinished(tool) : .toolStarted(tool)]

        case "webSearch":
            let tool = AgentToolRun(
                id: id,
                name: "Web search",
                kind: .webSearch,
                summary: string(item["query"]) ?? "Search",
                detail: summary(item["action"]),
                state: completed ? .succeeded : .running,
                exitCode: nil,
                evidence: evidence
            )
            return [completed ? .toolFinished(tool) : .toolStarted(tool)]

        case "plan":
            guard let text = string(item["text"]), !text.isEmpty else { return [] }
            let tool = AgentToolRun(
                id: id,
                name: "Plan",
                kind: .plan,
                summary: text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Execution plan",
                detail: text,
                state: completed ? .succeeded : .running,
                exitCode: nil,
                evidence: evidence
            )
            return [completed ? .toolFinished(tool) : .toolStarted(tool)]

        default:
            return []
        }
    }

    fileprivate static func evidence(
        source: AgentEvidenceSource,
        authority: AgentEvidenceAuthority,
        location: String,
        byteOffset: UInt64?,
        data: Data,
        timestamp: Date? = nil
    ) -> AgentEvidence {
        AgentEvidence(
            source: source,
            authority: authority,
            location: location,
            byteOffset: byteOffset,
            fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            capturedAt: timestamp ?? Date(),
            freshness: .current
        )
    }

    fileprivate static func observedCopy(_ evidence: AgentEvidence) -> AgentEvidence {
        AgentEvidence(
            source: evidence.source,
            authority: .observed,
            location: evidence.location,
            byteOffset: evidence.byteOffset,
            fingerprint: evidence.fingerprint,
            capturedAt: evidence.capturedAt,
            freshness: evidence.freshness
        )
    }

    fileprivate static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        if let text = value as? String { return [["type": "text", "text": text]] }
        return value as? [[String: Any]] ?? []
    }

    fileprivate static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let array = value as? [Any] else { return summary(value) }
        return array.compactMap { item -> String? in
            if let text = item as? String { return text }
            guard let record = item as? [String: Any] else { return nil }
            return string(record["text"]) ?? string(record["output_text"])
                ?? string(record["input_text"]) ?? string(record["content"])
        }.joined(separator: "\n")
    }

    fileprivate static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value
    }

    fileprivate static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            string(value) ?? string((value as? [String: Any])?["text"])
        }
    }

    private static func messageRole(_ value: String?) -> AgentMessageRole? {
        switch value?.lowercased() {
        case "assistant": .assistant
        case "user": .user
        case "system": .system
        case "developer": .developer
        default: nil
        }
    }

    private static func messageKind(
        role: AgentMessageRole,
        text: String
    ) -> AgentMessageKind {
        if isInjectedSkillInstructions(text) {
            return .skill
        }
        if role == .user, isInjectedProjectInstructions(text) {
            return .instruction
        }
        guard role == .system || role == .developer else { return .conversation }
        if text.contains("<skills_instructions>") || text.contains("SKILL.md") {
            return .skill
        }
        return .instruction
    }

    private static func isInjectedSkillInstructions(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Base directory for this skill:") else { return false }
        guard let firstLineEnd = trimmed.firstIndex(of: "\n") else { return false }
        let baseDirectory = trimmed[..<firstLineEnd].lowercased()
        return baseDirectory.contains("/skills/")
    }

    private static func isInjectedProjectInstructions(_ text: String) -> Bool {
        guard text.contains("<INSTRUCTIONS>"), text.contains("<environment_context>") else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "# AGENTS.md instructions for "
        if trimmed.hasPrefix(marker) { return true }
        guard trimmed.hasPrefix("<recommended_plugins>"),
              let envelopeEnd = trimmed.range(of: "</recommended_plugins>")
        else { return false }
        return trimmed[envelopeEnd.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(marker)
    }

    private static func toolKind(name: String, input: String) -> AgentToolKind {
        let normalized = name.lowercased()
        if subagentOperationNames.contains(normalized) || normalized.contains("subagent") {
            return .subagent
        }
        if normalized == "skill" || input.contains("SKILL.md") {
            return .skill
        }
        if normalized == "todowrite" || normalized == "update_plan" || normalized == "updateplan" {
            return .plan
        }
        if normalized == "local_shell_call" || normalized == "shell" {
            return .command
        }
        return .generic
    }

    private static func toolName(
        _ rawName: String,
        kind: AgentToolKind,
        input: String
    ) -> String {
        switch kind {
        case .plan:
            return "Plan"
        case .skill:
            return skillName(in: input) ?? "Skill"
        case .subagent:
            return switch rawName.lowercased() {
            case "spawn_agent": "Spawn subagent"
            case "followup_task": "Continue subagent"
            case "send_message": "Message subagent"
            case "wait_agent": "Wait for subagent"
            case "interrupt_agent": "Interrupt subagent"
            case "list_agents": "List subagents"
            default: "Subagent"
            }
        default:
            return rawName
        }
    }

    private static func toolSummary(
        _ input: String,
        name: String,
        kind: AgentToolKind
    ) -> String {
        switch kind {
        case .plan: planSummary(input)
        case .skill: "Loaded \(name) instructions"
        case .subagent: input.isEmpty ? "Subagent operation" : input
        default: input
        }
    }

    private static func skillName(in input: String) -> String? {
        guard let marker = input.range(of: "/SKILL.md", options: .backwards) else {
            return nil
        }
        return input[..<marker.lowerBound]
            .split(separator: "/")
            .last
            .map(String.init)
    }

    private static func planSummary(_ input: String) -> String {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let todos = object["todos"] as? [[String: Any]],
              !todos.isEmpty
        else { return "Execution checklist" }
        let completed = todos.filter { string($0["status"]) == "completed" }.count
        return "\(completed)/\(todos.count) steps complete"
    }

    private static func planDetail(_ input: String) -> String {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let todos = object["todos"] as? [[String: Any]],
              !todos.isEmpty
        else { return input }
        return todos.compactMap { todo in
            guard let content = string(todo["content"]), !content.isEmpty else { return nil }
            let marker = switch string(todo["status"]) {
            case "completed": "✓"
            case "in_progress": "▸"
            default: "·"
            }
            return "\(marker) \(content)"
        }.joined(separator: "\n")
    }

    fileprivate static func summary(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return capped(string) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return capped(text)
    }

    fileprivate static func capped(_ value: String) -> String {
        guard value.utf8.count > outputLimit else { return value }
        return String(value.prefix(outputLimit)) + "…"
    }

    fileprivate static func timestamp(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return seconds > 10_000_000_000
                ? Date(timeIntervalSince1970: seconds / 1_000)
                : Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    private static func changesSummary(_ value: Any?) -> String {
        guard let changes = value as? [[String: Any]], !changes.isEmpty else {
            return "Files changed"
        }
        let paths = changes.compactMap { string($0["path"]) }.prefix(4)
        let suffix = changes.count > 4 ? " +\(changes.count - 4)" : ""
        return paths.joined(separator: ", ") + suffix
    }

    private static func toolState(status: String, exitCode: Int?) -> AgentToolState {
        switch status {
        case "failed", "failure": .failed
        case "declined", "rejected": .declined
        case "completed", "success", "succeeded": exitCode == nil || exitCode == 0
            ? .succeeded
            : .failed
        default: .running
        }
    }
}

/// Decoder for Codex app-server v2 JSON-RPC frames. The shape is grounded in the
/// schema emitted by the installed `codex app-server generate-json-schema` command;
/// unknown methods are ignored rather than guessed into UI semantics.
struct CodexProtocolFrameDecoder: Sendable {
    func decode(line: Data, sequence: UInt64, location: String = "codex app-server") throws
        -> [AgentLensEvent]
    {
        guard line.count <= 2 << 20 else { throw AgentLensDecodeError.recordTooLarge }
        guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = frame["method"] as? String
        else { throw AgentLensDecodeError.malformedJSON }
        let params = frame["params"] as? [String: Any] ?? [:]
        let evidence = AgentTranscriptDecoder.evidence(
            source: .nativeProtocol,
            authority: .reported,
            location: "\(location):\(method)",
            byteOffset: sequence,
            data: line,
            timestamp: nil
        )

        switch method {
        case "thread/started":
            return [
                .connected(
                    provider: .codex,
                    capabilities: .protocolNative,
                    transcriptPath: nil,
                    evidence: evidence
                ),
                .status(.ready, evidence: evidence),
            ]
        case "turn/started":
            return [.status(.running, evidence: evidence)]
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            if status == "failed" {
                return [.status(.failed(AgentTranscriptDecoder.summary(turn?["error"])), evidence: evidence)]
            }
            return [.status(.completed, evidence: evidence)]
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return [] }
            let id = AgentTranscriptDecoder.string(item["id"]) ?? "item-\(sequence)"
            return AgentTranscriptDecoder.codexItem(
                item,
                id: id,
                completed: method == "item/completed",
                evidence: evidence
            )
        case "item/agentMessage/delta":
            guard let id = AgentTranscriptDecoder.string(params["itemId"]),
                  let delta = AgentTranscriptDecoder.string(params["delta"])
            else { return [] }
            return [.assistantDelta(id: id, text: delta, evidence: evidence)]
        case "item/commandExecution/outputDelta":
            guard let id = AgentTranscriptDecoder.string(params["itemId"]),
                  let delta = AgentTranscriptDecoder.string(params["delta"])
            else { return [] }
            return [.toolDelta(id: id, text: delta, evidence: evidence)]
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let id = AgentTranscriptDecoder.string(params["itemId"]),
                  let delta = AgentTranscriptDecoder.string(params["delta"])
            else { return [] }
            return [
                .reasoning(
                    AgentLensMessage(
                        id: id,
                        role: .reasoning,
                        text: delta,
                        isStreaming: true,
                        evidence: evidence
                    )
                ),
            ]
        case "item/plan/delta":
            guard let id = AgentTranscriptDecoder.string(params["itemId"]),
                  let delta = AgentTranscriptDecoder.string(params["delta"])
            else { return [] }
            return [.toolDelta(id: id, text: delta, evidence: evidence)]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            let requestID = Self.requestID(frame["id"]) ?? "approval-\(sequence)"
            return [
                .interactionRequested(
                    AgentInteractionRequest(
                        id: requestID,
                        kind: .approval,
                        title: "Approval required",
                        detail: AgentTranscriptDecoder.summary(params),
                        state: .pending,
                        evidence: evidence
                    )
                ),
            ]
        case "item/tool/requestUserInput", "mcpServer/elicitation/request":
            let requestID = Self.requestID(frame["id"]) ?? "question-\(sequence)"
            let presentation = Self.questionPresentation(params)
            return [
                .interactionRequested(
                    AgentInteractionRequest(
                        id: requestID,
                        kind: .question,
                        title: presentation.title,
                        detail: presentation.detail,
                        options: presentation.options,
                        state: .pending,
                        evidence: evidence
                    )
                ),
            ]
        case "serverRequest/resolved":
            guard let requestID = Self.requestID(params["requestId"]) else { return [] }
            return [.interactionResolved(id: requestID, evidence: evidence)]
        case "error":
            let message = AgentTranscriptDecoder.string(params["message"])
                ?? AgentTranscriptDecoder.summary(params)
            return [.status(.failed(message), evidence: evidence)]
        default:
            return []
        }
    }

    private static func requestID(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func questionPresentation(_ params: [String: Any]) -> (
        title: String,
        detail: String,
        options: [AgentInteractionOption]
    ) {
        let question = (params["questions"] as? [[String: Any]])?.first ?? params
        let title = AgentTranscriptDecoder.string(question["question"])
            ?? AgentTranscriptDecoder.string(question["prompt"])
            ?? AgentTranscriptDecoder.string(question["title"])
            ?? "Input required"
        let detail = AgentTranscriptDecoder.string(question["header"])
            ?? AgentTranscriptDecoder.string(question["description"])
            ?? ""
        let rawOptions = question["options"] as? [Any] ?? []
        let options = rawOptions.enumerated().compactMap { index, value -> AgentInteractionOption? in
            if let label = value as? String, !label.isEmpty {
                return AgentInteractionOption(id: "\(index)-\(label)", label: label, detail: "")
            }
            guard let record = value as? [String: Any],
                  let label = AgentTranscriptDecoder.string(record["label"])
                    ?? AgentTranscriptDecoder.string(record["value"]),
                  !label.isEmpty
            else { return nil }
            return AgentInteractionOption(
                id: "\(index)-\(label)",
                label: label,
                detail: AgentTranscriptDecoder.string(record["description"]) ?? ""
            )
        }
        return (title, detail, options)
    }
}
