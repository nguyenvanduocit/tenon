// @domain: agent-lens
import CryptoKit
import Foundation

/// One fact from the reconciled session, in the bounded form a synthesis is allowed to read.
///
/// It is derived from `AgentLensSnapshot.timelineItems`, which is already the reconciliation of
/// the transcript with the provider's lifecycle hooks — so the digest inherits that settlement
/// rather than performing a second, differently-opinionated one.
struct AgentEvidenceFact: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case userMessage
        case assistantMessage
        case reasoning
        case toolRun
        case interaction
        case diagnostic
    }

    /// The `AgentTimelineItem.id` this fact came from. It is the anchor key, so a milestone
    /// citing it lands on the row a person can already see in Chat.
    let id: String
    let occurredAt: Date
    let kind: Kind
    let title: String
    let body: String
    /// The host's own reading of whether this work has finished: a running tool, a pending
    /// question. Validation refuses a `settled` milestone standing on one of these.
    let isUnsettled: Bool
    /// Where the fact came from, carried through to the anchor's return path.
    let location: String

    /// What an anchor row says. Host-written, from this fact.
    var anchorLabel: String {
        let head = title.isEmpty ? kind.spokenName : title
        guard !body.isEmpty else { return head }
        let words = body.split(whereSeparator: \.isWhitespace)
        let kept = words.prefix(14)
        guard !kept.isEmpty else { return head }
        // The cut is marked. An anchor row that simply stops mid-sentence reads as the fact's
        // whole text, which is the one thing a citation must not misrepresent.
        let summary = kept.joined(separator: " ") + (words.count > kept.count ? "…" : "")
        return "\(head) — \(summary)"
    }
}

extension AgentEvidenceFact.Kind {
    var spokenName: String {
        switch self {
        case .userMessage: "You"
        case .assistantMessage: "Agent"
        case .reasoning: "Reasoning"
        case .toolRun: "Tool"
        case .interaction: "Decision"
        case .diagnostic: "Diagnostic"
        }
    }
}

/// Why this session has nothing worth synthesizing yet.
///
/// Each of these is an honest state the pane shows instead of a reading. The alternative —
/// asking a model to find milestones in four messages — is how a supervision surface invents
/// the thing it exists to make checkable.
enum AgentTimelineInsufficiency: Error, Equatable, Sendable {
    case noSession
    case empty
    case tooShort(facts: Int, needed: Int)

    var message: String {
        switch self {
        case .noSession:
            "No agent session is attached to this pane"
        case .empty:
            "This session has no evidence yet"
        case let .tooShort(facts, needed):
            "\(facts) of \(needed) facts — this session is still short enough to read in Chat"
        }
    }
}

/// The bounded evidence one synthesis run is allowed to see.
struct AgentTimelineDigest: Equatable, Sendable {
    /// A supervision session is long; a prompt is not. The newest window is what a person is
    /// asking about, so the digest keeps the tail.
    static let maximumFacts = 320
    static let maximumBodyCharacters = 900
    static let maximumTotalCharacters = 96 << 10

    let facts: [AgentEvidenceFact]
    /// SHA-256 over the exact facts. Two digests with the same fingerprint are the same
    /// question, so a finished reading of one is a finished reading of the other.
    let fingerprint: String
    /// True when the tail was cut to fit, so the pane can say the reading starts mid-session.
    let isTruncated: Bool

    var firstFactAt: Date { facts.first?.occurredAt ?? .distantPast }
    var lastFactAt: Date { facts.last?.occurredAt ?? .distantPast }

    /// Why this snapshot cannot be read right now, or `nil` when it can.
    ///
    /// The same question `build(from:)` answers, asked without paying for the digest. It is
    /// asked from a view body on every snapshot change, so it stops at the sixth admitted fact
    /// and never hashes: building 320 bounded facts and a SHA-256 to decide which of two
    /// sentences to draw is a cost with no reader.
    ///
    /// Cheaper, but not a second opinion — it shares `fact(from:)` and the one bar in
    /// `AgentTimelineBounds`, and `testTheTwoSufficiencyAnswersNeverDisagree` stands over the
    /// seam regardless.
    static func insufficiency(of snapshot: AgentLensSnapshot) -> AgentTimelineInsufficiency? {
        guard snapshot.provider != nil else { return .noSession }
        let items = snapshot.timelineItems
        guard !items.isEmpty else { return .empty }

        // Counting to the bar and stopping is the same answer `build` reaches: both of its cuts
        // are floored at `minimumFactsForSynthesis`, so a snapshot that admits that many facts
        // still has them after the digest is bounded.
        var admitted = 0
        for item in items where fact(from: item) != nil {
            admitted += 1
            if admitted >= AgentTimelineBounds.minimumFactsForSynthesis { return nil }
        }
        guard admitted > 0 else { return .empty }
        return .tooShort(facts: admitted, needed: AgentTimelineBounds.minimumFactsForSynthesis)
    }

    /// Reads one snapshot into the bounded evidence a synthesis may see, or says why it cannot.
    ///
    /// The span narrows that evidence before a model ever sees it, and can only narrow it: the
    /// digest's own ceiling still applies, and both cuts are floored at the bar below which a
    /// synthesis is refused outright.
    static func build(
        from snapshot: AgentLensSnapshot,
        span: AgentReadingSpan = .wholeSession
    ) -> Result<Self, AgentTimelineInsufficiency> {
        guard snapshot.provider != nil else { return .failure(.noSession) }

        // `timelineItems` rather than `sessionTimelineItems`: Chat deliberately hides completed
        // tool runs so the conversation stays readable, and those runs are exactly what a
        // milestone about "found the competing writers" has to stand on.
        let items = snapshot.timelineItems
        guard !items.isEmpty else { return .failure(.empty) }

        var facts = items.compactMap(fact(from:))
        guard !facts.isEmpty else { return .failure(.empty) }

        // The narrower of the two ceilings, floored at the bar: a span can only take facts away,
        // and never enough of them to turn a readable session into a refused one.
        let ceiling = max(
            min(maximumFacts, span.maximumFacts),
            AgentTimelineBounds.minimumFactsForSynthesis
        )
        var isTruncated = false
        if facts.count > ceiling {
            facts.removeFirst(facts.count - ceiling)
            isTruncated = true
        }
        while facts.count > minimumFactsToKeep, totalCharacters(facts) > maximumTotalCharacters {
            facts.removeFirst()
            isTruncated = true
        }

        guard facts.count >= AgentTimelineBounds.minimumFactsForSynthesis else {
            return .failure(
                .tooShort(
                    facts: facts.count,
                    needed: AgentTimelineBounds.minimumFactsForSynthesis
                )
            )
        }

        return .success(
            Self(facts: facts, fingerprint: fingerprint(of: facts), isTruncated: isTruncated)
        )
    }

    private static let minimumFactsToKeep = AgentTimelineBounds.minimumFactsForSynthesis

    private static func totalCharacters(_ facts: [AgentEvidenceFact]) -> Int {
        facts.reduce(0) { $0 + $1.title.count + $1.body.count + $1.id.count }
    }

    private static func fingerprint(of facts: [AgentEvidenceFact]) -> String {
        var hasher = SHA256()
        for fact in facts {
            hasher.update(data: Data(fact.id.utf8))
            hasher.update(data: Data(fact.state.utf8))
            hasher.update(data: Data(fact.body.prefix(64).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fact(from item: AgentTimelineItem) -> AgentEvidenceFact? {
        switch item.content {
        case .message(let message):
            // Instructions, project context and loaded skills are the session's setting, not
            // things that happened in it. Chat already collapses them into the inspector.
            guard message.kind == .conversation, let kind = factKind(for: message.role) else {
                return nil
            }
            return AgentEvidenceFact(
                id: item.id,
                occurredAt: item.occurredAt,
                kind: kind,
                title: kind.spokenName,
                body: clipped(message.text),
                isUnsettled: message.isStreaming,
                location: item.sourceLocation
            )

        case .tools(let group):
            return AgentEvidenceFact(
                id: item.id,
                occurredAt: item.occurredAt,
                kind: .toolRun,
                title: group.title,
                body: clipped(toolBody(group)),
                isUnsettled: group.state == .running,
                location: item.sourceLocation
            )

        case .interaction(let request):
            return AgentEvidenceFact(
                id: item.id,
                occurredAt: item.occurredAt,
                kind: .interaction,
                title: request.title,
                body: clipped(request.detail),
                isUnsettled: request.state == .pending,
                location: item.sourceLocation
            )

        case .diagnostic(let diagnostic):
            // A gap or an overflow changes what the rest of the reading is worth, so it travels
            // with the evidence rather than being quietly dropped as noise.
            guard diagnostic.severity != .info else { return nil }
            return AgentEvidenceFact(
                id: item.id,
                occurredAt: item.occurredAt,
                kind: .diagnostic,
                title: "Diagnostic",
                body: clipped(diagnostic.message),
                isUnsettled: false,
                location: item.sourceLocation
            )
        }
    }

    /// `nil` for a role that is context rather than an event. System and developer turns are the
    /// session's setting, and Chat already collapses them into the inspector.
    private static func factKind(for role: AgentMessageRole) -> AgentEvidenceFact.Kind? {
        switch role {
        case .user: .userMessage
        case .assistant: .assistantMessage
        case .reasoning: .reasoning
        case .system, .developer: nil
        }
    }

    private static func toolBody(_ group: AgentTimelineToolGroup) -> String {
        var parts: [String] = []
        if !group.summary.isEmpty { parts.append(group.summary) }
        if group.tools.count > 1 { parts.append("\(group.tools.count) runs") }
        if let exitCode = group.tools.compactMap(\.exitCode).last(where: { $0 != 0 }) {
            parts.append("exit \(exitCode)")
        }
        return parts.joined(separator: " · ")
    }

    private static func clipped(_ value: String) -> String {
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maximumBodyCharacters else { return normalized }
        return String(normalized.prefix(maximumBodyCharacters)) + "…"
    }
}

private extension AgentEvidenceFact {
    /// The part of a fact whose change makes an existing reading stale: what it is, and whether
    /// it has finished. Prose that grows while streaming would otherwise re-fingerprint on
    /// every delta and ask for a fresh synthesis several times a second.
    var state: String { "\(kind.rawValue)|\(isUnsettled)" }
}
