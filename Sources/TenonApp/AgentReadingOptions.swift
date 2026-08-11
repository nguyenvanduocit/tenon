// @domain: agent-lens
import Foundation

/// How much of the session one reading is allowed to see.
///
/// A span is not a performance knob. On a long supervision session "what just happened" and
/// "what has this session been" are different questions, and asking the second one when you
/// meant the first buries the answer under three hours of settled work.
enum AgentReadingSpan: String, CaseIterable, Identifiable, Sendable {
    /// The newest work only.
    case recentWork
    /// Everything the digest can carry — what a reading saw before there was a choice.
    case wholeSession

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentWork: "Recent work"
        case .wholeSession: "Whole session"
        }
    }

    /// How much of the session "the newest work" is.
    ///
    /// A quarter of the digest's own ceiling. There is no measurement that settles this number —
    /// it is a product judgement about what "what just happened" means on a supervision session,
    /// and it is written here as one named constant so the judgement is visible rather than
    /// buried in an expression.
    static let recentWorkFacts = 80

    /// The most facts a digest may carry under this span.
    ///
    /// The digest's own ceiling still applies over the top of this, so a span can only ever
    /// narrow what a reading sees — and never below the bar that refuses a synthesis outright,
    /// because both cuts are floored at `AgentTimelineBounds.minimumFactsForSynthesis`.
    var maximumFacts: Int {
        switch self {
        case .recentWork:
            max(Self.recentWorkFacts, AgentTimelineBounds.minimumFactsForSynthesis)
        case .wholeSession:
            AgentTimelineDigest.maximumFacts
        }
    }
}

/// What the reading is asked to look for.
///
/// The lens changes the framing sentence and NOTHING else: the schema, the anchor rules, the
/// partition, the compression gate and the `settled` refusal are one shared block every lens
/// carries verbatim. That is the whole safety argument for making this a choice at all — a
/// person picking a different reading is choosing what the model is asked to notice, never what
/// the host will accept as checkable.
enum AgentReadingLens: String, CaseIterable, Identifiable, Sendable {
    /// Where the session changed direction. The reading this feature shipped with.
    case milestones
    /// What broke, what was tried, and what is still open.
    case problems
    /// What was chosen, over what, and why.
    case decisions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .milestones: "Milestones"
        case .problems: "Problems"
        case .decisions: "Decisions"
        }
    }

    /// One line under the picker, so the choice is legible before it costs a model call.
    var hint: String {
        switch self {
        case .milestones: "Where the session changed direction"
        case .problems: "What broke, and what is still open"
        case .decisions: "What was chosen, and what it was chosen over"
        }
    }

    /// What this reading is asked to find. The only part of the instruction a lens owns.
    ///
    /// Each one names the same output unit — a milestone — because the schema and the validator
    /// are shared. What differs is which moments of the session count as one.
    var framing: String {
        switch self {
        case .milestones:
            """
            You are reading one terminal AI-agent session and writing the few milestones that \
            explain it to a person who was not watching.

            A milestone is a moment the session materially changed direction or state — \
            "reproduced the focus loop", "found the competing focus writers", "changed the \
            ownership rule", "verified the fix".
            """
        case .problems:
            """
            You are reading one terminal AI-agent session and writing what went wrong in it, \
            for a person deciding whether this session still needs them.

            A milestone here is ONE problem: what broke, what was tried against it, and where \
            it stands now — "the focus test hung", "the fix moved the oscillation instead of \
            ending it". Work that simply went to plan is not a problem and does not appear. A \
            problem that was fixed and stayed fixed is `settled`; one whose fix was later \
            undone is `superseded`; one still open is `inProgress`.
            """
        case .decisions:
            """
            You are reading one terminal AI-agent session and writing the decisions it made, \
            for a person who has to live with them.

            A milestone here is ONE decision: what was chosen, what it was chosen over, and \
            what made the difference — "put both focus edges behind one routing type rather \
            than patching each writer". A step where there was no alternative is not a \
            decision. A decision later reversed is `superseded`, not `settled`.
            """
        }
    }
}

/// Which model does the reading.
///
/// The cases are the provider's own documented aliases rather than names of our choosing.
/// Measured 2026-08-11: `claude --help` names `fable`, `opus` and `sonnet`; a model id the CLI
/// does not know fails at run time in a way nothing in this suite could catch, so a name that
/// has not been read off the CLI does not appear here.
enum AgentReadingModel: String, CaseIterable, Identifiable, Sendable {
    /// Whatever the CLI is configured for. No `--model` is passed at all.
    case providerDefault
    case sonnet
    case opus
    case fable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault: "Default model"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .fable: "Fable"
        }
    }

    /// How this model is spelled on the command line, or nil when the run takes the CLI's own.
    var alias: String? {
        self == .providerDefault ? nil : rawValue
    }

    /// Codex takes `-m`, but its model ids come from the person's own `config.toml` rather than
    /// from a documented alias list, so offering names here would be guessing at ids the CLI
    /// would reject. Its readings run whatever that CLI is configured for.
    static func choices(for provider: AgentCLI) -> [Self] {
        switch provider {
        case .claude: allCases
        case .codex: [.providerDefault]
        }
    }
}

/// How one reading of a session is taken: who reads it, how much of it they see, and what they
/// are asked to look for.
///
/// One value carried with the request rather than four independent pieces of pane state, because
/// a run in flight has to keep the options it started with while the person is free to pick
/// different ones for the next reading.
struct AgentReadingOptions: Equatable, Sendable {
    private(set) var provider: AgentCLI
    private(set) var model: AgentReadingModel
    var span: AgentReadingSpan
    var lens: AgentReadingLens

    /// The one place provider and model are held consistent: a provider that cannot be told
    /// which model to run cannot be left holding another provider's alias.
    init(
        provider: AgentCLI = .claude,
        model: AgentReadingModel = .providerDefault,
        span: AgentReadingSpan = .wholeSession,
        lens: AgentReadingLens = .milestones
    ) {
        self.provider = provider
        // Asked of the same list the picker draws from, so a model that is not offered for this
        // provider cannot arrive by any other route either.
        self.model = AgentReadingModel.choices(for: provider).contains(model) ? model : .providerDefault
        self.span = span
        self.lens = lens
    }

    mutating func select(provider: AgentCLI) {
        self = Self(provider: provider, model: model, span: span, lens: lens)
    }

    mutating func select(model: AgentReadingModel) {
        self = Self(provider: provider, model: model, span: span, lens: lens)
    }

    /// What the pane says a finished reading was taken with.
    var summary: String {
        var parts = [provider.label]
        if model != .providerDefault { parts.append(model.title) }
        parts.append(span.title.lowercased())
        parts.append(lens.title.lowercased())
        return parts.joined(separator: " · ")
    }
}

/// How the pane learns which readers this machine actually has.
///
/// A CLI that is not installed is not a choice: picking it buys a run whose only possible answer
/// is `noSynthesizer`. Injectable because the answer is on the filesystem, and asynchronous
/// because reading the filesystem is forbidden on `MainActor`.
typealias AgentReadingReaderDetector = @Sendable () async -> [AgentCLI]
