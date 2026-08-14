// @domain: agent-lens
import Foundation

/// One typed execution fact inside the quiet work log. It keeps the raw timeline id so a
/// milestone can return to the folded row without weakening its original evidence anchor.
enum AgentWorkContent: Equatable, Sendable {
    case tools(AgentTimelineToolGroup)
    case plan(AgentPlanUpdate)
    case changes(AgentChangeSet)
}

struct AgentWorkEntry: Identifiable, Equatable, Sendable {
    let id: String
    let occurredAt: Date
    let turnID: AgentTurnID?
    let content: AgentWorkContent

    var title: String {
        switch content {
        case .tools(let group): return group.title
        case .plan: return "Plan"
        case .changes: return "Changes"
        }
    }

    var summary: String {
        switch content {
        case .tools(let group): return group.summary
        case .plan(let plan):
            guard !plan.steps.isEmpty else { return plan.explanation }
            return "\(plan.completedCount)/\(plan.steps.count) steps complete"
        case .changes(let changeSet):
            guard !changeSet.changedPaths.isEmpty else { return "Turn diff updated" }
            let visible = changeSet.changedPaths.prefix(3).joined(separator: ", ")
            let remainder = changeSet.changedPaths.count - min(3, changeSet.changedPaths.count)
            return remainder > 0 ? "\(visible) +\(remainder)" : visible
        }
    }

    var detail: String {
        switch content {
        case .tools(let group):
            return group.tools
                .map { [$0.name, $0.summary, $0.detail].filter { !$0.isEmpty }.joined(separator: " — ") }
                .joined(separator: "\n")
        case .plan(let plan):
            let steps = plan.steps.map { step in
                let marker = switch step.state {
                case .pending: "·"
                case .running: "▸"
                case .completed: "✓"
                }
                return "\(marker) \(step.text)"
            }.joined(separator: "\n")
            return [plan.explanation, steps].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .changes(let changeSet): return changeSet.unifiedDiff
        }
    }

    var state: AgentToolState {
        switch content {
        case .tools(let group): return group.state
        case .plan(let plan):
            return plan.steps.contains(where: { $0.state == .running }) ? .running : .succeeded
        case .changes: return .succeeded
        }
    }

    var evidence: AgentEvidence {
        switch content {
        case .tools(let group):
            // A tool group is never empty: it can only be built from one run and appended to.
            return group.evidence ?? .terminalInference(
                "agent-lens:missing-tool-evidence",
                capturedAt: .distantPast
            )
        case .plan(let plan): return plan.evidence
        case .changes(let changeSet): return changeSet.evidence
        }
    }

    var category: String {
        switch content {
        case .tools(let group): return group.kind.rawValue
        case .plan: return AgentToolKind.plan.rawValue
        case .changes: return AgentToolKind.fileChange.rawValue
        }
    }
}

struct AgentWorkLog: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: AgentTurnID?
    var entries: [AgentWorkEntry]

    init(first entry: AgentWorkEntry) {
        id = "work-\(entry.id)"
        turnID = entry.turnID
        entries = [entry]
    }

    var occurredAt: Date { entries.first?.occurredAt ?? .distantPast }
    var evidence: AgentEvidence {
        entries.last?.evidence ?? .terminalInference(
            "agent-lens:empty-work",
            capturedAt: .distantPast
        )
    }

    var state: AgentToolState {
        if entries.contains(where: { $0.state == .failed }) { return .failed }
        if entries.contains(where: { $0.state == .running }) { return .running }
        if entries.contains(where: { $0.state == .declined }) { return .declined }
        return .succeeded
    }

    var title: String {
        entries.count == 1 ? (entries.first?.title ?? "Work") : "Work"
    }

    var summary: String {
        guard entries.count > 1 else { return entries.first?.summary ?? "" }
        let categories = entries.map(\.title).reduce(into: [String]()) { result, title in
            if !result.contains(title) { result.append(title) }
        }
        return "\(entries.count) steps · \(categories.prefix(3).joined(separator: ", "))"
    }

    var sourceItemIDs: Set<String> { Set(entries.map(\.id)) }

    mutating func append(_ entry: AgentWorkEntry) {
        entries.append(entry)
    }
}

struct AgentTaskProjection: Identifiable, Equatable, Sendable {
    let id: AgentTaskID
    var operations: [AgentToolRun]

    var state: AgentToolState {
        if operations.contains(where: { $0.state == .failed }) { return .failed }
        if operations.contains(where: { $0.state == .running }) { return .running }
        if operations.contains(where: { $0.state == .declined }) { return .declined }
        return .succeeded
    }
}

struct AgentContextProjection: Equatable, Sendable {
    let messages: [AgentLensMessage]
    let usage: AgentContextUsage?
}

/// Platform-neutral, deterministic read model. macOS SwiftUI consumes `conversation` today;
/// a mobile renderer can consume the same projections without inheriting terminal parsing or
/// AppKit state.
struct AgentLensReadModel: Equatable, Sendable {
    let conversation: [AgentTimelineItem]
    let work: [AgentWorkLog]
    let plans: [AgentPlanUpdate]
    let changes: [AgentChangeSet]
    let agents: [AgentTaskProjection]
    let interactions: [AgentInteractionRequest]
    let context: AgentContextProjection

    static let empty = Self(
        conversation: [],
        work: [],
        plans: [],
        changes: [],
        agents: [],
        interactions: [],
        context: AgentContextProjection(messages: [], usage: nil)
    )

    init(snapshot: AgentLensSnapshot) {
        let projected = Self.projectConversation(snapshot.timelineItems)
        conversation = projected.conversation
        work = projected.work
        plans = snapshot.plans
        changes = snapshot.changeSets
        agents = Self.projectTasks(snapshot.tools)
        interactions = snapshot.interactions
        context = AgentContextProjection(
            messages: snapshot.contextMessages,
            usage: snapshot.contextUsage
        )
    }

    private init(
        conversation: [AgentTimelineItem],
        work: [AgentWorkLog],
        plans: [AgentPlanUpdate],
        changes: [AgentChangeSet],
        agents: [AgentTaskProjection],
        interactions: [AgentInteractionRequest],
        context: AgentContextProjection
    ) {
        self.conversation = conversation
        self.work = work
        self.plans = plans
        self.changes = changes
        self.agents = agents
        self.interactions = interactions
        self.context = context
    }

    /// Raw fact ids remain Timeline anchors. This maps an execution fact to the folded Chat row
    /// that contains it, while conversation/interaction/diagnostic ids map to themselves.
    func conversationAnchor(forFactID factID: String) -> String? {
        for item in conversation {
            if item.id == factID { return item.id }
            if case .work(let log) = item.content, log.sourceItemIDs.contains(factID) {
                return item.id
            }
        }
        return nil
    }

    private static func projectConversation(
        _ timeline: [AgentTimelineItem]
    ) -> (conversation: [AgentTimelineItem], work: [AgentWorkLog]) {
        var conversation: [AgentTimelineItem] = []
        var work: [AgentWorkLog] = []
        var openLog: AgentWorkLog?

        func flush() {
            guard let log = openLog else { return }
            work.append(log)
            conversation.append(
                AgentTimelineItem(
                    id: log.id,
                    occurredAt: log.occurredAt,
                    sourceLocation: log.evidence.location,
                    sourceOffset: log.evidence.byteOffset,
                    turnID: log.turnID,
                    content: .work(log)
                )
            )
            openLog = nil
        }

        for item in timeline {
            guard let entry = workEntry(from: item) else {
                flush()
                conversation.append(item)
                continue
            }
            if var current = openLog, current.turnID == entry.turnID {
                current.append(entry)
                openLog = current
            } else {
                flush()
                openLog = AgentWorkLog(first: entry)
            }
        }
        flush()
        return (conversation, work)
    }

    private static func workEntry(from item: AgentTimelineItem) -> AgentWorkEntry? {
        let content: AgentWorkContent
        switch item.content {
        case .tools(let group): content = .tools(group)
        case .plan(let plan): content = .plan(plan)
        case .changes(let changeSet): content = .changes(changeSet)
        case .message, .interaction, .diagnostic, .work: return nil
        }
        return AgentWorkEntry(
            id: item.id,
            occurredAt: item.occurredAt,
            turnID: item.turnID,
            content: content
        )
    }

    private static func projectTasks(_ tools: [AgentToolRun]) -> [AgentTaskProjection] {
        var result: [AgentTaskProjection] = []
        var indexByID: [AgentTaskID: Int] = [:]
        for tool in tools where tool.kind == .subagent {
            let id = tool.taskID ?? AgentTaskID("tool:\(tool.id)")
            if let index = indexByID[id] {
                result[index].operations.append(tool)
            } else {
                indexByID[id] = result.count
                result.append(AgentTaskProjection(id: id, operations: [tool]))
            }
        }
        return result
    }
}

extension AgentLensSnapshot {
    var readModel: AgentLensReadModel { AgentLensReadModel(snapshot: self) }
    var sessionTimelineItems: [AgentTimelineItem] { readModel.conversation }
}
