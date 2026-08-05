import CryptoKit
import Foundation

enum AgentLensDecodeError: Error, Equatable, Sendable {
    case malformedJSON
    case recordTooLarge
}

struct AgentTranscriptDecoder: Sendable {
    private static let outputLimit = 64 << 10

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
                let name = Self.string(block["name"]) ?? "Tool"
                events.append(
                    .toolStarted(
                        AgentToolRun(
                            id: id,
                            name: name,
                            summary: Self.summary(block["input"]),
                            detail: "",
                            state: .running,
                            exitCode: nil,
                            evidence: evidence
                        )
                    )
                )
            case "tool_result":
                let id = Self.string(block["tool_use_id"]) ?? "\(messageID)-result-\(index)"
                let isError = block["is_error"] as? Bool == true
                events.append(
                    .toolFinished(
                        AgentToolRun(
                            id: id,
                            name: "Tool",
                            summary: isError ? "Tool failed" : "Tool completed",
                            detail: Self.capped(Self.contentText(block["content"])),
                            state: isError ? .failed : .succeeded,
                            exitCode: nil,
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

        let visibleText = visibleTexts.joined(separator: "\n\n").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !visibleText.isEmpty {
            let value = AgentLensMessage(
                id: messageID,
                role: recordType == "user" ? .user : .assistant,
                text: visibleText,
                isStreaming: false,
                evidence: evidence
            )
            events.append(recordType == "user" ? .userMessage(value) : .assistantMessage(value))
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
            case "turn_started":
                return [.status(.running, evidence: evidence)]
            case "turn_complete", "turn_completed":
                return [.status(.completed, evidence: evidence)]
            case "turn_aborted":
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
        switch string(item["type"]) {
        case "message", "userMessage":
            let text = contentText(item["content"])
            guard !text.isEmpty else { return [] }
            let role: AgentMessageRole = string(item["role"]) == "assistant" ? .assistant : .user
            let message = AgentLensMessage(
                id: id,
                role: role,
                text: text,
                isStreaming: !completed,
                evidence: evidence
            )
            return [role == .assistant ? .assistantMessage(message) : .userMessage(message)]

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

        case "function_call", "local_shell_call":
            let name = string(item["name"]) ?? "Tool"
            return [
                .toolStarted(
                    AgentToolRun(
                        id: string(item["call_id"]) ?? id,
                        name: name,
                        summary: summary(item["arguments"] ?? item["input"] ?? item["action"]),
                        detail: "",
                        state: .running,
                        exitCode: nil,
                        evidence: evidence
                    )
                ),
            ]

        case "function_call_output":
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
                summary: string(item["query"]) ?? "Search",
                detail: summary(item["action"]),
                state: completed ? .succeeded : .running,
                exitCode: nil,
                evidence: evidence
            )
            return [completed ? .toolFinished(tool) : .toolStarted(tool)]

        case "plan":
            guard let text = string(item["text"]), !text.isEmpty else { return [] }
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
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/plan/delta":
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
            return [
                .interactionRequested(
                    AgentInteractionRequest(
                        id: requestID,
                        kind: .question,
                        title: "Input required",
                        detail: AgentTranscriptDecoder.summary(params),
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
}
