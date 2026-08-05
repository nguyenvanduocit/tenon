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
    case conversation
    case activity
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .activity: "Activity"
        case .terminal: "Terminal"
        }
    }
}

enum AgentEvidenceSource: String, Codable, Sendable {
    case transcript
    case nativeProtocol
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
}

struct AgentLensMessage: Identifiable, Equatable, Sendable {
    let id: String
    var role: AgentMessageRole
    var text: String
    var isStreaming: Bool
    var evidence: AgentEvidence
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

struct AgentInteractionRequest: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AgentInteractionKind
    var title: String
    var detail: String
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

enum AgentActivityKind: String, Sendable {
    case lifecycle
    case message
    case tool
    case interaction
    case diagnostic
}

struct AgentLensActivity: Identifiable, Equatable, Sendable {
    let id: String
    let kind: AgentActivityKind
    let title: String
    let detail: String
    let occurredAt: Date
    let evidence: AgentEvidence
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

struct AgentLensSnapshot: Equatable, Sendable {
    var provider: AgentProvider?
    var capabilities: AgentLensCapabilities = []
    var status: AgentLensStatus = .detecting
    var messages: [AgentLensMessage] = []
    var tools: [AgentToolRun] = []
    var interactions: [AgentInteractionRequest] = []
    var activities: [AgentLensActivity] = []
    var diagnostics: [AgentLensDiagnostic] = []
    var transcriptPath: String?
    var earlierHistoryAvailable = false
    var canSend = false
    var renderRevision = 0

    static let empty = Self()
}

enum AgentLensEvent: Equatable, Sendable {
    case reset(source: AgentEvidence)
    case connected(
        provider: AgentProvider,
        capabilities: AgentLensCapabilities,
        transcriptPath: String?,
        evidence: AgentEvidence
    )
    case earlierHistoryAvailable(AgentEvidence)
    case userMessage(AgentLensMessage)
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
    private static let activityCapacity = 500
    private static let diagnosticCapacity = 40

    private(set) var snapshot = AgentLensSnapshot.empty

    mutating func apply(_ event: AgentLensEvent) {
        switch event {
        case .reset(let source):
            let provider = snapshot.provider
            let capabilities = snapshot.capabilities
            let transcriptPath = snapshot.transcriptPath
            snapshot = .empty
            snapshot.provider = provider
            snapshot.capabilities = capabilities
            snapshot.transcriptPath = transcriptPath
            snapshot.status = .degraded("Transcript was replaced; history reloaded")
            appendActivity(
                kind: .diagnostic,
                title: "Transcript replaced",
                detail: "The source restarted or rotated.",
                evidence: source
            )

        case let .connected(provider, capabilities, transcriptPath, evidence):
            snapshot.provider = provider
            snapshot.capabilities = capabilities
            snapshot.transcriptPath = transcriptPath
            snapshot.status = .ready
            snapshot.canSend = capabilities.contains(.terminalInput) ||
                capabilities.contains(.structuredInput)
            appendActivity(
                kind: .lifecycle,
                title: "Connected to \(provider.displayName)",
                detail: transcriptPath ?? "Native protocol",
                evidence: evidence
            )

        case .earlierHistoryAvailable(let evidence):
            snapshot.earlierHistoryAvailable = true
            appendActivity(
                kind: .diagnostic,
                title: "Earlier history available",
                detail: "The live projection loaded a bounded recent window.",
                evidence: evidence
            )

        case .userMessage(let message):
            upsertMessage(message)
            appendActivity(
                kind: .message,
                title: "User message",
                detail: Self.preview(message.text),
                evidence: message.evidence
            )

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
            appendActivity(
                kind: .message,
                title: "Assistant message",
                detail: Self.preview(message.text),
                evidence: message.evidence
            )

        case .reasoning(let message):
            upsertMessage(message)
            appendActivity(
                kind: .message,
                title: "Reasoning summary",
                detail: Self.preview(message.text),
                evidence: message.evidence
            )

        case .toolStarted(let tool):
            upsertTool(tool)
            snapshot.status = .running
            appendActivity(
                kind: .tool,
                title: "Started \(tool.name)",
                detail: tool.summary,
                evidence: tool.evidence
            )

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
            appendActivity(
                kind: .tool,
                title: "\(tool.name) \(tool.state.rawValue)",
                detail: tool.summary,
                evidence: tool.evidence
            )

        case .interactionRequested(let request):
            if let index = snapshot.interactions.firstIndex(where: { $0.id == request.id }) {
                snapshot.interactions[index] = request
            } else {
                snapshot.interactions.append(request)
            }
            snapshot.status = .waitingForUser
            appendActivity(
                kind: .interaction,
                title: request.title,
                detail: request.detail,
                evidence: request.evidence
            )

        case let .interactionResolved(id, evidence):
            if let index = snapshot.interactions.firstIndex(where: { $0.id == id }) {
                snapshot.interactions[index].state = .answered
                snapshot.interactions[index].evidence = stronger(
                    snapshot.interactions[index].evidence,
                    evidence
                )
            }
            if !snapshot.interactions.contains(where: { $0.state == .pending }) {
                snapshot.status = .running
            }

        case let .status(status, evidence):
            snapshot.status = status
            appendActivity(
                kind: .lifecycle,
                title: status.title,
                detail: Self.statusDetail(status),
                evidence: evidence
            )

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
            appendActivity(
                kind: .diagnostic,
                title: diagnostic.severity.rawValue.capitalized,
                detail: diagnostic.message,
                evidence: diagnostic.evidence
            )
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
            if replacement.detail.isEmpty {
                replacement.detail = snapshot.tools[index].detail
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

    private mutating func appendActivity(
        kind: AgentActivityKind,
        title: String,
        detail: String,
        evidence: AgentEvidence
    ) {
        let identity = "\(kind.rawValue):\(evidence.location):\(evidence.byteOffset ?? 0):\(title)"
        if snapshot.activities.last?.id == identity { return }
        snapshot.activities.append(
            AgentLensActivity(
                id: identity,
                kind: kind,
                title: title,
                detail: detail,
                occurredAt: evidence.capturedAt,
                evidence: evidence
            )
        )
        if snapshot.activities.count > Self.activityCapacity {
            snapshot.activities.removeFirst(snapshot.activities.count - Self.activityCapacity)
        }
    }

    private func stronger(_ current: AgentEvidence, _ candidate: AgentEvidence) -> AgentEvidence {
        if candidate.authority.rank > current.authority.rank { return candidate }
        if candidate.authority.rank < current.authority.rank { return current }
        if candidate.source == .nativeProtocol && current.source != .nativeProtocol {
            return candidate
        }
        if current.source == .terminalInput && candidate.source == .transcript {
            return candidate
        }
        return current
    }

    private static func preview(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ")
        return capped(normalized, at: 180)
    }

    private static func capped(_ value: String, at limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func statusDetail(_ status: AgentLensStatus) -> String {
        switch status {
        case .failed(let detail), .degraded(let detail): detail
        default: ""
        }
    }
}
