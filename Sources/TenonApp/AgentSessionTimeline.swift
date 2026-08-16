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
/// It carries no dates, no anchor labels, no fact ids and no session verdict — only a title, two
/// sentences, an outcome word, and where the milestone starts and ends in the numbered evidence.
/// Everything a reader can check is therefore host-derived, and everything the model contributes
/// is a judgement about where one piece of work stops and the next begins.
///
/// **Why a span rather than a list of ids.** A milestone already renders as a stretch of time —
/// `startedAt` and `endedAt` were always the host's own min and max over the cited facts — so the
/// unit the model is really choosing is a period of the session. Asking it to express that period
/// by transcribing forty-four-character identifiers was a task with a measured failure rate and no
/// product in it: on 2026-08-16, against a real 215-fact session, a reading returned eleven usable
/// milestones and one anchor spelled `message-c9f48eda-83a9-4b4d-b8f9-none` — a true prefix with
/// an invented tail — and 277 seconds of work were discarded over it.
///
/// Two numbers cannot be misspelled into a fact that does not exist, so `inventedAnchor` and
/// `sharedAnchor` stop being failures a reading can suffer and become claims it cannot express.
struct AgentTimelineDraft: Codable, Equatable, Sendable {
    struct Milestone: Codable, Equatable, Sendable {
        let title: String
        let whatChanged: String
        let whyItMattered: String
        let outcome: String
        /// The first numbered fact of this milestone, 1-based and inclusive.
        let from: Int
        /// The last numbered fact of this milestone, 1-based and inclusive.
        let through: Int
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
    /// The compression gate, held per milestone: a span narrower than this is a row wearing a
    /// heading, so a reading that keeps one milestone per fact — a relabelled transcript — cannot
    /// be a timeline at any session length. Asked of each span rather than of the reading's
    /// average, because one wide milestone must not buy the right to eight narrow ones.
    static let minimumFactsPerMilestone = 3
    static let maximumTitleLength = 80
    static let maximumProseLength = 400
    /// The most facts one milestone may cover, given how much evidence there is.
    ///
    /// Relative rather than fixed, because the thing worth refusing is a reading that is one
    /// milestone wearing the session's clothes — and "one milestone" is a share of the evidence,
    /// not a count of it. Half is where that becomes true: below it a reading is at least two
    /// moments, which is the fewest a timeline can be made of.
    ///
    /// The constant it replaced was 24, and it was sized for a different unit. When a milestone
    /// cited a hand-picked list of facts, 24 was how many citations a person can read at once;
    /// when a milestone became the stretch of session it covers, that number started refusing
    /// correct work. Measured 2026-08-16 across three real transcripts of 215 to 320 facts, the
    /// phases a reading picked out ran **28 to 43 facts** — 13–15% of the digest, and every one of
    /// those three readings was refused by the old bound for describing its session accurately.
    static func maximumFactsPerMilestone(inDigestOf count: Int) -> Int {
        max(minimumFactsPerMilestone, count / 2)
    }
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
    /// A milestone standing on fewer facts than the compression bar is a relabelled row rather
    /// than a reading of several. Stated per milestone, because a span states its own size.
    case notCompression(milestone: String, facts: Int)
    case fieldOutOfBounds(milestone: String, field: String)
    case unknownOutcome(milestone: String, value: String)
    /// A span that ends before it starts names no stretch of the session at all.
    case emptySpan(milestone: String)
    case oversizedSpan(milestone: String, facts: Int, limit: Int)
    /// Two milestones' spans overlap on this fact: grouping is a partition, not a tagging.
    case sharedAnchor(factID: String)
    /// A milestone claiming `settled` over work the host can see is still running or pending.
    case falseCompletion(milestone: String, factID: String)

    var message: String {
        switch self {
        case .empty:
            "The synthesis returned no milestones"
        case let .tooManyMilestones(count, limit):
            "The synthesis returned \(count) milestones; at most \(limit) are readable"
        case let .notCompression(milestone, facts):
            "Milestone “\(milestone)” covers \(facts) facts; below \(AgentTimelineBounds.minimumFactsPerMilestone) it is a relabelled row, not a reading of several"
        case let .fieldOutOfBounds(milestone, field):
            "Milestone “\(milestone)” has an empty or oversized \(field)"
        case let .unknownOutcome(milestone, value):
            "Milestone “\(milestone)” claims the unknown outcome “\(value)”"
        case .emptySpan(let milestone):
            "Milestone “\(milestone)” ends before it starts, so it covers no evidence"
        case let .oversizedSpan(milestone, facts, limit):
            "Milestone “\(milestone)” covers \(facts) of the session's facts; above \(limit) it is the whole reading, not a moment in it"
        case .sharedAnchor(let factID):
            "Two milestones claim the same fact “\(factID)”"
        case let .falseCompletion(milestone, factID):
            "Milestone “\(milestone)” is settled while “\(factID)” is still open"
        }
    }
}

// MARK: - Validation  @domain: agent-lens

/// The gate between what a model wrote and what a person is shown.
///
/// Pure, total, and asserted without a window. Everything it can check against the host's own
/// facts, it checks: a span must fall inside the evidence, spans must partition rather than
/// overlap, the anchors and their labels are read out of the digest rather than accepted, and a
/// completion claim is refused when the host can see the work it names is still open.
///
/// Two of the checks it used to make are gone because they now describe impossible readings
/// rather than refused ones. A span cannot name a fact the session does not contain, and a
/// milestone of at least three facts cannot be one row wearing a heading. What replaced them is
/// not leniency — it is the same guarantee, moved from a refusal into the shape of the answer.
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

        let facts = digest.facts
        var spans: [Span] = []
        spans.reserveCapacity(draft.milestones.count)

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

            // Held inside the evidence rather than checked against it. An index is a bound, and
            // bounding one is the same thing the host does to every other number a reading
            // carries — unlike a fact id, a clamped index still names a fact this session
            // contains, so nothing unverifiable can survive the clamp.
            let from = min(max(candidate.from, 1), facts.count)
            let through = min(max(candidate.through, 1), facts.count)
            guard from <= through else { return .failure(.emptySpan(milestone: name)) }

            let covered = through - from + 1
            guard covered >= AgentTimelineBounds.minimumFactsPerMilestone else {
                return .failure(.notCompression(milestone: name, facts: covered))
            }
            let widest = AgentTimelineBounds.maximumFactsPerMilestone(inDigestOf: facts.count)
            guard covered <= widest else {
                return .failure(.oversizedSpan(milestone: name, facts: covered, limit: widest))
            }

            spans.append(
                Span(order: index, name: name, from: from, through: through, outcome: outcome)
            )
        }

        // Read in the order they happened rather than the order they were written. The digest is
        // oldest-first, so an index order is a time order, and sorting here means a reading whose
        // milestones arrived shuffled still renders as a timeline instead of being refused for
        // the model's writing order.
        spans.sort { $0.from == $1.from ? $0.order < $1.order : $0.from < $1.from }

        var milestones: [AgentMilestone] = []
        milestones.reserveCapacity(spans.count)
        var previousThrough = 0

        for span in spans {
            // The partition, enforced once over ordered spans instead of per cited id. Two
            // milestones can no longer stand on one fact, and the fact they collided on is named.
            guard span.from > previousThrough else {
                return .failure(.sharedAnchor(factID: facts[span.from - 1].id))
            }
            previousThrough = span.through

            let covered = Array(facts[(span.from - 1)...(span.through - 1)])
            if span.outcome == .settled, let open = covered.first(where: \.isUnsettled) {
                return .failure(.falseCompletion(milestone: span.name, factID: open.id))
            }

            let candidate = draft.milestones[span.order]
            milestones.append(
                AgentMilestone(
                    id: "milestone-\(span.order)-\(covered[0].id)",
                    title: candidate.title,
                    whatChanged: candidate.whatChanged,
                    whyItMattered: candidate.whyItMattered,
                    outcome: span.outcome,
                    anchors: covered.map {
                        AgentMilestoneAnchor(
                            factID: $0.id,
                            label: $0.anchorLabel,
                            location: $0.location
                        )
                    },
                    startedAt: covered[0].occurredAt,
                    endedAt: covered[covered.count - 1].occurredAt
                )
            )
        }

        return .success(
            AgentSessionTimeline(
                milestones: milestones,
                evidenceFingerprint: digest.fingerprint,
                factCount: digest.facts.count,
                generatedAt: generatedAt
            )
        )
    }

    /// One candidate milestone reduced to the stretch of evidence it names, before any of them is
    /// compared with its neighbours.
    private struct Span {
        let order: Int
        let name: String
        let from: Int
        let through: Int
        let outcome: AgentMilestoneOutcome
    }

    private static func fits(_ value: String, limit: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= limit
    }
}
