// @domain: agent-lens
import Foundation

enum AgentProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

struct AgentLensCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let semanticMessages = Self(rawValue: 1 << 0)
    static let messageDeltas = Self(rawValue: 1 << 1)
    static let toolLifecycle = Self(rawValue: 1 << 2)
    static let approvals = Self(rawValue: 1 << 3)
    static let questions = Self(rawValue: 1 << 4)
    static let terminalInput = Self(rawValue: 1 << 5)
    static let structuredInput = Self(rawValue: 1 << 6)
    static let evidenceAnchors = Self(rawValue: 1 << 7)
    static let transcript = Self(rawValue: 1 << 8)
    static let nativeProtocol = Self(rawValue: 1 << 9)

    static let transcriptPTY: Self = [
        .semanticMessages,
        .toolLifecycle,
        .terminalInput,
        .evidenceAnchors,
        .transcript,
    ]

    static let protocolNative: Self = [
        .semanticMessages,
        .messageDeltas,
        .toolLifecycle,
        .approvals,
        .questions,
        .structuredInput,
        .evidenceAnchors,
        .nativeProtocol,
    ]
}

enum AgentLensMode: String, CaseIterable, Identifiable, Sendable {
    case session
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Session"
        case .terminal: "Terminal"
        }
    }
}

enum AgentEvidenceSource: String, Codable, Sendable {
    case transcript
    case nativeProtocol
    case providerHook
    case terminalInput
    case terminalInference
}

enum AgentEvidenceAuthority: String, Codable, Sendable {
    /// Text or status reported by the agent/provider, not independently verified by Tenon.
    case reported
    /// A direct process, command, file, or lifecycle observation made by Tenon.
    case observed

    fileprivate var rank: Int {
        switch self {
        case .reported: 0
        case .observed: 1
        }
    }
}

enum AgentEvidenceFreshness: String, Codable, Sendable {
    case current
    case stale
    case sourceMissing
    case gap
}

struct AgentEvidence: Equatable, Sendable {
    let source: AgentEvidenceSource
    let authority: AgentEvidenceAuthority
    let location: String
    let byteOffset: UInt64?
    let fingerprint: String
    let capturedAt: Date
    var freshness: AgentEvidenceFreshness

    static func terminalInference(_ detail: String, capturedAt: Date = Date()) -> Self {
        Self(
            source: .terminalInference,
            authority: .observed,
            location: detail,
            byteOffset: nil,
            fingerprint: "",
            capturedAt: capturedAt,
            freshness: .current
        )
    }
}

enum AgentMessageRole: String, Sendable {
    case user
    case assistant
    case reasoning
    case system
    case developer
}

enum AgentMessageKind: String, Sendable {
    case conversation
    case instruction
    case skill
}

struct AgentLensMessage: Identifiable, Equatable, Sendable {
    let id: String
    var role: AgentMessageRole
    var kind: AgentMessageKind = .conversation
    var text: String
    var isStreaming: Bool
    var evidence: AgentEvidence
}

enum AgentToolKind: String, Sendable {
    case generic
    case command
    case fileChange
    case fileRead
    case search
    case webSearch
    case plan
    case skill
    case subagent
    case question
}

enum AgentToolState: String, Sendable {
    case running
    case succeeded
    case failed
    case declined
}

struct AgentToolRun: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var kind: AgentToolKind = .generic
    var summary: String
    var detail: String
    var state: AgentToolState
    var exitCode: Int?
    var evidence: AgentEvidence
}

enum AgentInteractionKind: String, Sendable {
    case question
    case approval
}

enum AgentInteractionState: String, Sendable {
    case pending
    case answered
    case expired
}

struct AgentInteractionOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String
}

struct AgentInteractionRequest: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AgentInteractionKind
    var title: String
    var detail: String
    var options: [AgentInteractionOption] = []
    var state: AgentInteractionState
    var evidence: AgentEvidence
}

enum AgentLensStatus: Equatable, Sendable {
    case detecting
    case unavailable
    case ready
    case running
    case waitingForUser
    case completed
    case failed(String)
    case degraded(String)

    var title: String {
        switch self {
        case .detecting: "Detecting"
        case .unavailable: "Terminal"
        case .ready: "Ready"
        case .running: "Running"
        case .waitingForUser: "Needs input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .degraded: "Degraded"
        }
    }
}

enum AgentDiagnosticSeverity: String, Sendable {
    case info
    case warning
    case error
}

struct AgentLensDiagnostic: Identifiable, Equatable, Sendable {
    let id: String
    let severity: AgentDiagnosticSeverity
    let message: String
    let evidence: AgentEvidence
}

struct AgentTimelineToolGroup: Identifiable, Equatable, Sendable {
    let id: String
    var tools: [AgentToolRun]

    init(tool: AgentToolRun) {
        id = "tools-\(tool.id)"
        tools = [tool]
    }

    var kind: AgentToolKind { tools.first?.kind ?? .generic }

    var title: String {
        switch kind {
        case .subagent: "Subagent workflow"
        case .command: "Command"
        case .fileChange: "File change"
        case .webSearch: "Web search"
        case .plan: "Plan"
        default: tools.first?.name ?? "Tool"
        }
    }

    var summary: String {
        switch kind {
        case .skill where tools.count > 1:
            "Loaded \(tools.count) instruction chunks"
        case .subagent:
            "\(tools.count) coordinated \(tools.count == 1 ? "step" : "steps")"
        case .plan:
            "Execution checklist"
        default:
            tools.last(where: { !$0.summary.isEmpty })?.summary ?? ""
        }
    }

    var state: AgentToolState {
        if tools.contains(where: { $0.state == .failed }) { return .failed }
        if tools.contains(where: { $0.state == .running }) { return .running }
        if tools.contains(where: { $0.state == .declined }) { return .declined }
        return .succeeded
    }

    var evidence: AgentEvidence? { tools.first?.evidence }

    mutating func append(_ tool: AgentToolRun) {
        tools.append(tool)
    }

    func canMerge(with tool: AgentToolRun) -> Bool {
        switch (kind, tool.kind) {
        case (.subagent, .subagent):
            true
        case (.skill, .skill):
            tools.first?.name.caseInsensitiveCompare(tool.name) == .orderedSame
        default:
            false
        }
    }
}

enum AgentTimelineContent: Equatable, Sendable {
    case message(AgentLensMessage)
    case tools(AgentTimelineToolGroup)
    case interaction(AgentInteractionRequest)
    case diagnostic(AgentLensDiagnostic)
}

struct AgentTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let occurredAt: Date
    let sourceLocation: String
    let sourceOffset: UInt64?
    var content: AgentTimelineContent
}

struct AgentLensSnapshot: Equatable, Sendable {
    var provider: AgentProvider?
    var capabilities: AgentLensCapabilities = []
    var status: AgentLensStatus = .detecting
    var messages: [AgentLensMessage] = []
    var tools: [AgentToolRun] = []
    var interactions: [AgentInteractionRequest] = []
    var diagnostics: [AgentLensDiagnostic] = []
    var transcriptPath: String?
    var earlierHistoryAvailable = false
    var canSend = false
    var renderRevision = 0

    static let empty = Self()

    var contextMessages: [AgentLensMessage] {
        messages.filter { $0.kind != .conversation }
    }

    var timelineItems: [AgentTimelineItem] {
        var items: [AgentTimelineItem] = []
        items.reserveCapacity(messages.count + tools.count + interactions.count + diagnostics.count)

        for message in messages where message.kind == .conversation {
            items.append(
                AgentTimelineItem(
                    id: "message-\(message.id)",
                    occurredAt: message.evidence.capturedAt,
                    sourceLocation: message.evidence.location,
                    sourceOffset: message.evidence.byteOffset,
                    content: .message(message)
                )
            )
        }
        for tool in tools {
            items.append(
                AgentTimelineItem(
                    id: "tool-\(tool.id)",
                    occurredAt: tool.evidence.capturedAt,
                    sourceLocation: tool.evidence.location,
                    sourceOffset: tool.evidence.byteOffset,
                    content: .tools(AgentTimelineToolGroup(tool: tool))
                )
            )
        }
        for interaction in interactions {
            items.append(
                AgentTimelineItem(
                    id: "interaction-\(interaction.id)",
                    occurredAt: interaction.evidence.capturedAt,
                    sourceLocation: interaction.evidence.location,
                    sourceOffset: interaction.evidence.byteOffset,
                    content: .interaction(interaction)
                )
            )
        }
        for diagnostic in diagnostics {
            items.append(
                AgentTimelineItem(
                    id: "diagnostic-\(diagnostic.id)",
                    occurredAt: diagnostic.evidence.capturedAt,
                    sourceLocation: diagnostic.evidence.location,
                    sourceOffset: diagnostic.evidence.byteOffset,
                    content: .diagnostic(diagnostic)
                )
            )
        }

        items.sort { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            if lhs.sourceLocation != rhs.sourceLocation { return lhs.sourceLocation < rhs.sourceLocation }
            if lhs.sourceOffset != rhs.sourceOffset {
                return (lhs.sourceOffset ?? .max) < (rhs.sourceOffset ?? .max)
            }
            return lhs.id < rhs.id
        }

        var grouped: [AgentTimelineItem] = []
        grouped.reserveCapacity(items.count)
        for item in items {
            guard case let .tools(nextGroup) = item.content,
                  let nextTool = nextGroup.tools.first,
                  let lastIndex = grouped.indices.last,
                  case var .tools(previousGroup) = grouped[lastIndex].content,
                  previousGroup.canMerge(with: nextTool)
            else {
                grouped.append(item)
                continue
            }
            previousGroup.append(nextTool)
            grouped[lastIndex].content = .tools(previousGroup)
        }
        return grouped
    }

    /// The Session view keeps completed execution history in the snapshot but projects
    /// only the most recently started tool that is still running. Detailed execution
    /// remains available in the terminal instead of accumulating in the conversation.
    var sessionTimelineItems: [AgentTimelineItem] {
        var items = timelineItems.filter { item in
            guard case .tools = item.content else { return true }
            return false
        }
        guard let tool = tools.last(where: { $0.state == .running }) else { return items }
        items.append(
            AgentTimelineItem(
                id: "tool-\(tool.id)",
                occurredAt: tool.evidence.capturedAt,
                sourceLocation: tool.evidence.location,
                sourceOffset: tool.evidence.byteOffset,
                content: .tools(AgentTimelineToolGroup(tool: tool))
            )
        )
        items.sort { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            if lhs.sourceLocation != rhs.sourceLocation { return lhs.sourceLocation < rhs.sourceLocation }
            if lhs.sourceOffset != rhs.sourceOffset {
                return (lhs.sourceOffset ?? .max) < (rhs.sourceOffset ?? .max)
            }
            return lhs.id < rhs.id
        }
        return items
    }

    var goalSummary: String {
        guard let message = messages.last(where: {
            $0.role == .user && $0.kind == .conversation
        }) else { return "Waiting for your first instruction" }
        return Self.summary(message.text, limit: 180)
    }

    var currentActionSummary: String {
        if let request = interactions.last(where: { $0.state == .pending }) {
            return request.title
        }
        if let tool = tools.last(where: { $0.state == .running }) {
            return tool.summary.isEmpty ? tool.name : Self.summary(tool.summary, limit: 120)
        }
        if messages.last(where: { $0.role == .assistant })?.isStreaming == true {
            return "Writing a response"
        }
        return switch status {
        case .detecting: "Detecting the foreground agent"
        case .unavailable: "Terminal is available"
        case .ready: "Ready to work"
        case .running: "Working"
        case .waitingForUser: "Waiting for your decision"
        case .completed: "Ready for a follow-up"
        case .failed(let detail), .degraded(let detail): Self.summary(detail, limit: 120)
        }
    }

    var pendingInteraction: AgentInteractionRequest? {
        interactions.last(where: { $0.state == .pending })
    }

    private static func summary(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}

enum AgentLensEvent: Equatable, Sendable {
    case reset(source: AgentEvidence)
    case connected(
        provider: AgentProvider,
        capabilities: AgentLensCapabilities,
        transcriptPath: String?,
        evidence: AgentEvidence
    )
    /// A transport proved itself at runtime — Claude Code's hooks only report tool
    /// lifecycle and questions once they are actually installed and firing.
    case capabilitiesGained(AgentLensCapabilities, evidence: AgentEvidence)
    case earlierHistoryAvailable(AgentEvidence)
    case userMessage(AgentLensMessage)
    case contextMessage(AgentLensMessage)
    case assistantDelta(id: String, text: String, evidence: AgentEvidence)
    case assistantMessage(AgentLensMessage)
    case reasoning(AgentLensMessage)
    case toolStarted(AgentToolRun)
    case toolDelta(id: String, text: String, evidence: AgentEvidence)
    case toolFinished(AgentToolRun)
    case interactionRequested(AgentInteractionRequest)
    case interactionResolved(id: String, evidence: AgentEvidence)
    case status(AgentLensStatus, evidence: AgentEvidence)
    case diagnostic(AgentLensDiagnostic)

    var isHighFrequencyDelta: Bool {
        switch self {
        case .assistantDelta, .toolDelta:
            true
        default:
            false
        }
    }
}

/// Pure projection from normalized provider facts to the immutable snapshot SwiftUI reads.
/// It owns no tasks, files, PTYs, or clocks, so replaying the same event sequence is exact.
struct AgentLensReducer: Sendable {
    private static let messageCapacity = 600
    private static let toolCapacity = 240
    private static let interactionCapacity = 120
    private static let diagnosticCapacity = 40

    private(set) var snapshot = AgentLensSnapshot.empty

    mutating func apply(_ event: AgentLensEvent) {
        switch event {
        case .reset:
            let provider = snapshot.provider
            let capabilities = snapshot.capabilities
            let transcriptPath = snapshot.transcriptPath
            snapshot = .empty
            snapshot.provider = provider
            snapshot.capabilities = capabilities
            snapshot.transcriptPath = transcriptPath
            snapshot.status = .degraded("Transcript was replaced; history reloaded")

        case let .connected(provider, capabilities, transcriptPath, _):
            snapshot.provider = provider
            snapshot.capabilities = capabilities
            snapshot.transcriptPath = transcriptPath
            snapshot.status = .ready
            snapshot.canSend = capabilities.contains(.terminalInput) ||
                capabilities.contains(.structuredInput)

        case .capabilitiesGained(let capabilities, _):
            snapshot.capabilities.formUnion(capabilities)

        case .earlierHistoryAvailable:
            snapshot.earlierHistoryAvailable = true

        case .userMessage(let message):
            upsertMessage(message)

        case .contextMessage(let message):
            upsertMessage(message)

        case let .assistantDelta(id, text, evidence):
            if let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
                snapshot.messages[index].text += text
                snapshot.messages[index].isStreaming = true
                snapshot.messages[index].evidence = stronger(
                    snapshot.messages[index].evidence,
                    evidence
                )
            } else {
                snapshot.messages.append(
                    AgentLensMessage(
                        id: id,
                        role: .assistant,
                        text: text,
                        isStreaming: true,
                        evidence: evidence
                    )
                )
                trimMessages()
            }
            snapshot.status = .running

        case .assistantMessage(let message):
            upsertMessage(message)

        case .reasoning(let message):
            upsertMessage(message)

        case .toolStarted(let tool):
            upsertTool(tool)
            snapshot.status = .running

        case let .toolDelta(id, text, evidence):
            if let index = snapshot.tools.firstIndex(where: { $0.id == id }) {
                snapshot.tools[index].detail = Self.capped(
                    snapshot.tools[index].detail + text,
                    at: 64 << 10
                )
                snapshot.tools[index].evidence = stronger(snapshot.tools[index].evidence, evidence)
            }

        case .toolFinished(let tool):
            upsertTool(tool)

        case .interactionRequested(let request):
            if let index = snapshot.interactions.firstIndex(where: { $0.id == request.id }) {
                // The live hook raises a question the transcript describes again once the
                // turn flushes. A decision already made is history, not a fresh prompt.
                guard snapshot.interactions[index].state == .pending else {
                    snapshot.interactions[index].evidence = stronger(
                        snapshot.interactions[index].evidence,
                        request.evidence
                    )
                    break
                }
                snapshot.interactions[index] = request
            } else {
                snapshot.interactions.append(request)
                if snapshot.interactions.count > Self.interactionCapacity {
                    snapshot.interactions.removeFirst(
                        snapshot.interactions.count - Self.interactionCapacity
                    )
                }
            }
            snapshot.status = .waitingForUser

        case let .interactionResolved(id, evidence):
            guard let index = snapshot.interactions.firstIndex(where: { $0.id == id }) else {
                break
            }
            snapshot.interactions[index].state = .answered
            snapshot.interactions[index].evidence = stronger(
                snapshot.interactions[index].evidence,
                evidence
            )
            if snapshot.status == .waitingForUser,
               !snapshot.interactions.contains(where: { $0.state == .pending })
            {
                snapshot.status = .running
            }

        case let .status(status, _):
            snapshot.status = status

        case .diagnostic(let diagnostic):
            snapshot.diagnostics.append(diagnostic)
            if snapshot.diagnostics.count > Self.diagnosticCapacity {
                snapshot.diagnostics.removeFirst(
                    snapshot.diagnostics.count - Self.diagnosticCapacity
                )
            }
            if diagnostic.severity != .info {
                snapshot.status = .degraded(diagnostic.message)
            }
        }
        snapshot.renderRevision &+= 1
    }

    private mutating func upsertMessage(_ message: AgentLensMessage) {
        if let index = snapshot.messages.firstIndex(where: { $0.id == message.id }) {
            snapshot.messages[index] = message
            return
        }
        // Transcript formats often repeat a durable response as an event record and a
        // response-item record. Optimistic PTY input is repeated once the transcript
        // flushes too. Coalesce only an adjacent exact semantic duplicate.
        if let last = snapshot.messages.indices.last,
           snapshot.messages[last].role == message.role,
           snapshot.messages[last].text == message.text
        {
            snapshot.messages[last].isStreaming = message.isStreaming
            snapshot.messages[last].evidence = stronger(
                snapshot.messages[last].evidence,
                message.evidence
            )
            return
        }
        snapshot.messages.append(message)
        trimMessages()
    }

    private mutating func trimMessages() {
        if snapshot.messages.count > Self.messageCapacity {
            snapshot.messages.removeFirst(snapshot.messages.count - Self.messageCapacity)
            snapshot.earlierHistoryAvailable = true
        }
    }

    private mutating func upsertTool(_ tool: AgentToolRun) {
        if let index = snapshot.tools.firstIndex(where: { $0.id == tool.id }) {
            var replacement = tool
            if replacement.kind == .generic, snapshot.tools[index].kind != .generic {
                replacement.kind = snapshot.tools[index].kind
            }
            if replacement.name == "Tool", snapshot.tools[index].name != "Tool" {
                replacement.name = snapshot.tools[index].name
            }
            if replacement.detail.isEmpty {
                replacement.detail = snapshot.tools[index].detail
            }
            if replacement.summary.isEmpty {
                replacement.summary = snapshot.tools[index].summary
            }
            // The hook reports a call as it happens; the transcript describes the same call
            // from its start, and arrives later. How a run ended is settled once.
            if snapshot.tools[index].state != .running, replacement.state == .running {
                replacement.state = snapshot.tools[index].state
                replacement.exitCode = snapshot.tools[index].exitCode
                if replacement.summary.isEmpty { replacement.summary = snapshot.tools[index].summary }
            }
            replacement.evidence = stronger(snapshot.tools[index].evidence, replacement.evidence)
            snapshot.tools[index] = replacement
        } else {
            snapshot.tools.append(tool)
            if snapshot.tools.count > Self.toolCapacity {
                snapshot.tools.removeFirst(snapshot.tools.count - Self.toolCapacity)
            }
        }
    }

    private func stronger(_ current: AgentEvidence, _ candidate: AgentEvidence) -> AgentEvidence {
        if candidate.authority.rank > current.authority.rank { return candidate }
        if candidate.authority.rank < current.authority.rank { return current }
        if candidate.source == .nativeProtocol && current.source != .nativeProtocol {
            return candidate
        }
        // The hook is first to know and the transcript is what a human can return to: it
        // carries the byte offset and fingerprint that make a claim inspectable. So the
        // durable record supersedes the live one for the same fact.
        if candidate.source == .transcript,
           current.source == .terminalInput || current.source == .providerHook
        {
            return candidate
        }
        return current
    }

    private static func capped(_ value: String, at limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

}
