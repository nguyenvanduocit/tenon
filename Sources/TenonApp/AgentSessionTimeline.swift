// @domain: agent-lens
import Foundation

/// Which account of the SAME attached session the Session renderer is drawing.
///
/// Deliberately separate from `AgentLensPresentation`. That enum answers "which renderer, and
/// how many of them"; this one answers "which reading of the one the Session renderer shows".
/// Folding them into one picker would make Timeline look like a third thing to attach to,
/// when it is the same PTY, the same transcript, and the same reducer output read differently.
enum AgentLensAccount: String, CaseIterable, Identifiable, Sendable {
    /// The verbatim conversational record: every message, question and live tool run in order.
    case chat
    /// A synthesized reading: a few milestones, each anchored back into `chat`.
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .timeline: "Timeline"
        }
    }
}

// MARK: - What a milestone is  @domain: agent-lens

/// A milestone's return path to one fact in the session it was read from.
///
/// The `label` is written by the HOST from its own fact, never by the model: an anchor whose
/// words came from the synthesis could describe evidence that does not say that, which is the
/// exact failure "evidence-linked compression" exists to prevent. The model chooses *which*
/// facts support a milestone; what those facts say stays the transcript's answer.
struct AgentMilestoneAnchor: Identifiable, Equatable, Sendable {
    /// The `AgentTimelineItem.id` this anchor returns to.
    let factID: String
    /// Host-written, from the anchored fact.
    let label: String
    /// Where the anchored fact came from, so the inspector can be raised on it.
    let location: String

    var id: String { factID }
}

/// What a milestone claims about the work it groups.
///
/// Three states, because the fourth one people reach for — "failed" — is a property of the
/// facts, not of the reading: a milestone whose anchored command exited non-zero and whose
/// next milestone fixed it is `superseded`, and the failure is still visible in the anchors.
enum AgentMilestoneOutcome: String, Codable, CaseIterable, Sendable {
    /// Still open at the end of the evidence.
    case inProgress
    /// Finished, and nothing later undid it.
    case settled
    /// Finished, and later work replaced or reverted it.
    case superseded

    var title: String {
        switch self {
        case .inProgress: "In progress"
        case .settled: "Settled"
        case .superseded: "Superseded"
        }
    }
}

/// One moment where the session materially changed direction or state.
///
/// The time span is computed by the host from the anchored facts rather than written by the
/// model, so a milestone cannot claim a period the evidence does not cover.
struct AgentMilestone: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let whatChanged: String
    let whyItMattered: String
    let outcome: AgentMilestoneOutcome
    let anchors: [AgentMilestoneAnchor]
    let startedAt: Date
    let endedAt: Date

    /// How many underlying facts this milestone stands in for.
    var factCount: Int { anchors.count }
}

/// A validated reading of one session.
///
/// It carries no session-level completion claim on purpose. Whether the agent is still working
/// is `AgentLensSnapshot.status` — observed, live, and already on screen — so there is nothing
/// here for a synthesis to be wrong about. A timeline can only be stale, never falsely finished.
struct AgentSessionTimeline: Equatable, Sendable {
    let milestones: [AgentMilestone]
    /// The digest fingerprint this reading was made from. A newer digest makes it stale.
    let evidenceFingerprint: String
    /// How many facts the synthesis read.
    let factCount: Int
    let generatedAt: Date
}

// MARK: - What the model returns, before the host believes any of it  @domain: agent-lens

/// The raw shape a synthesis is required to produce.
///
/// It carries no dates, no anchor labels and no session verdict — only a title, two sentences,
/// an outcome word, and which facts each milestone stands on. Everything a reader can check is
/// therefore host-derived, and everything the model contributes is a judgement about grouping.
struct AgentTimelineDraft: Codable, Equatable, Sendable {
    struct Milestone: Codable, Equatable, Sendable {
        let title: String
        let whatChanged: String
        let whyItMattered: String
        let outcome: String
        /// `AgentTimelineItem.id` values from the digest, in the order they happened.
        let anchors: [String]
    }

    let milestones: [Milestone]
}

// MARK: - Bounds  @domain: agent-lens

/// Every limit the rendered timeline is held to. One place, because a bound that lives at its
/// use site is a bound the next use site will not have.
enum AgentTimelineBounds {
    /// A supervision surface a person scans, not an index.
    static let maximumMilestones = 12
    /// Below this there is nothing to compress and saying so is more honest than synthesizing.
    static let minimumFactsForSynthesis = 6
    /// The compression gate. `milestones * this <= facts`, so a reading that keeps one row per
    /// fact — a relabelled transcript — cannot be a timeline at any session length.
    static let minimumFactsPerMilestone = 3
    static let maximumTitleLength = 80
    static let maximumProseLength = 400
    static let maximumAnchorsPerMilestone = 24
    /// The raw synthesis output, before decoding. Bounded first so a runaway generation is
    /// refused rather than parsed.
    static let maximumOutputBytes = 64 << 10
}

/// Why a candidate reading is not a timeline.
///
/// Each case names the specific contradiction, because "malformed output" on screen tells a
/// person nothing about whether to retry, and this is the one surface where an unexplained
/// failure would be indistinguishable from an invented success.
enum AgentTimelineRejection: Error, Equatable, Sendable {
    case empty
    case tooManyMilestones(count: Int, limit: Int)
    /// One row per fact is a transcript with new labels, not a reading of it.
    case notCompression(milestones: Int, facts: Int)
    case fieldOutOfBounds(milestone: String, field: String)
    case unknownOutcome(milestone: String, value: String)
    case unanchored(milestone: String)
    case tooManyAnchors(milestone: String, count: Int)
    /// The synthesis cited a fact the digest never contained.
    case inventedAnchor(milestone: String, factID: String)
    /// Two milestones claim the same fact: grouping is a partition, not a tagging.
    case sharedAnchor(factID: String)
    /// A milestone claiming `settled` over work the host can see is still running or pending.
    case falseCompletion(milestone: String, factID: String)
    /// The title is one fact's own words, which is relabelling one row rather than reading many.
    case echoesOneFact(milestone: String)

    var message: String {
        switch self {
        case .empty:
            "The synthesis returned no milestones"
        case let .tooManyMilestones(count, limit):
            "The synthesis returned \(count) milestones; at most \(limit) are readable"
        case let .notCompression(milestones, facts):
            "\(milestones) milestones over \(facts) facts is a relabelled transcript, not a reading of one"
        case let .fieldOutOfBounds(milestone, field):
            "Milestone “\(milestone)” has an empty or oversized \(field)"
        case let .unknownOutcome(milestone, value):
            "Milestone “\(milestone)” claims the unknown outcome “\(value)”"
        case .unanchored(let milestone):
            "Milestone “\(milestone)” cites no evidence"
        case let .tooManyAnchors(milestone, count):
            "Milestone “\(milestone)” cites \(count) facts; it is a section, not a milestone"
        case let .inventedAnchor(milestone, factID):
            "Milestone “\(milestone)” cites “\(factID)”, which is not in this session"
        case .sharedAnchor(let factID):
            "Two milestones claim the same fact “\(factID)”"
        case let .falseCompletion(milestone, factID):
            "Milestone “\(milestone)” is settled while “\(factID)” is still open"
        case .echoesOneFact(let milestone):
            "Milestone “\(milestone)” restates one fact instead of grouping several"
        }
    }
}

// MARK: - Validation  @domain: agent-lens

/// The gate between what a model wrote and what a person is shown.
///
/// Pure, total, and asserted without a window. Everything it can check against the host's own
/// facts, it checks: the anchors must exist, they must partition rather than overlap, the span
/// is recomputed rather than accepted, and a completion claim is refused when the host can see
/// the work it names is still open.
enum AgentTimelineValidation {
    static func validate(
        _ draft: AgentTimelineDraft,
        against digest: AgentTimelineDigest,
        generatedAt: Date
    ) -> Result<AgentSessionTimeline, AgentTimelineRejection> {
        guard !draft.milestones.isEmpty else { return .failure(.empty) }
        guard draft.milestones.count <= AgentTimelineBounds.maximumMilestones else {
            return .failure(
                .tooManyMilestones(
                    count: draft.milestones.count,
                    limit: AgentTimelineBounds.maximumMilestones
                )
            )
        }
        guard draft.milestones.count * AgentTimelineBounds.minimumFactsPerMilestone
            <= digest.facts.count
        else {
            return .failure(
                .notCompression(milestones: draft.milestones.count, facts: digest.facts.count)
            )
        }

        let factsByID = Dictionary(uniqueKeysWithValues: digest.facts.map { ($0.id, $0) })
        var claimed: Set<String> = []
        var milestones: [AgentMilestone] = []
        milestones.reserveCapacity(draft.milestones.count)

        for (index, candidate) in draft.milestones.enumerated() {
            let name = candidate.title.isEmpty ? "#\(index + 1)" : candidate.title

            guard fits(candidate.title, limit: AgentTimelineBounds.maximumTitleLength) else {
                return .failure(.fieldOutOfBounds(milestone: name, field: "title"))
            }
            guard fits(candidate.whatChanged, limit: AgentTimelineBounds.maximumProseLength) else {
                return .failure(.fieldOutOfBounds(milestone: name, field: "whatChanged"))
            }
            guard fits(candidate.whyItMattered, limit: AgentTimelineBounds.maximumProseLength)
            else {
                return .failure(.fieldOutOfBounds(milestone: name, field: "whyItMattered"))
            }
            guard let outcome = AgentMilestoneOutcome(rawValue: candidate.outcome) else {
                return .failure(.unknownOutcome(milestone: name, value: candidate.outcome))
            }
            guard !candidate.anchors.isEmpty else {
                return .failure(.unanchored(milestone: name))
            }
            guard candidate.anchors.count <= AgentTimelineBounds.maximumAnchorsPerMilestone else {
                return .failure(
                    .tooManyAnchors(milestone: name, count: candidate.anchors.count)
                )
            }

            var anchors: [AgentMilestoneAnchor] = []
            anchors.reserveCapacity(candidate.anchors.count)
            for factID in candidate.anchors {
                guard let fact = factsByID[factID] else {
                    return .failure(.inventedAnchor(milestone: name, factID: factID))
                }
                guard claimed.insert(factID).inserted else {
                    return .failure(.sharedAnchor(factID: factID))
                }
                if outcome == .settled, fact.isUnsettled {
                    return .failure(.falseCompletion(milestone: name, factID: factID))
                }
                anchors.append(
                    AgentMilestoneAnchor(
                        factID: fact.id,
                        label: fact.anchorLabel,
                        location: fact.location
                    )
                )
            }

            if anchors.count == 1, echoes(candidate.title, factsByID[anchors[0].factID]) {
                return .failure(.echoesOneFact(milestone: name))
            }

            let times = anchors.compactMap { factsByID[$0.factID]?.occurredAt }
            milestones.append(
                AgentMilestone(
                    id: "milestone-\(index)-\(anchors[0].factID)",
                    title: candidate.title,
                    whatChanged: candidate.whatChanged,
                    whyItMattered: candidate.whyItMattered,
                    outcome: outcome,
                    anchors: anchors.sorted {
                        (factsByID[$0.factID]?.occurredAt ?? .distantPast)
                            < (factsByID[$1.factID]?.occurredAt ?? .distantPast)
                    },
                    startedAt: times.min() ?? digest.firstFactAt,
                    endedAt: times.max() ?? digest.lastFactAt
                )
            )
        }

        return .success(
            AgentSessionTimeline(
                milestones: milestones.sorted { lhs, rhs in
                    lhs.startedAt == rhs.startedAt
                        ? lhs.id < rhs.id
                        : lhs.startedAt < rhs.startedAt
                },
                evidenceFingerprint: digest.fingerprint,
                factCount: digest.facts.count,
                generatedAt: generatedAt
            )
        )
    }

    private static func fits(_ value: String, limit: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= limit
    }

    /// A title that is one fact's own opening words is that fact wearing a heading.
    private static func echoes(_ title: String, _ fact: AgentEvidenceFact?) -> Bool {
        guard let fact else { return false }
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return false }
        for candidate in [fact.title, fact.body] {
            let normalized = normalize(candidate)
            guard !normalized.isEmpty else { continue }
            if normalized == normalizedTitle { return true }
            if normalized.hasPrefix(normalizedTitle) { return true }
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
