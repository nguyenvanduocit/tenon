// @domain: agent-lens
import Foundation
import TenonCore

// MARK: - The instruction  @domain: agent-lens

/// What the synthesizing agent is asked, as one pure function of the digest.
///
/// Pure because the prompt is the largest thing in this feature that can silently rot: it is
/// prose, it is never compiled, and nothing else in the pipeline notices when it stops asking
/// for the shape the validator enforces. Keeping it here means a test can assert that the
/// instruction and `AgentTimelineBounds` still agree.
enum AgentTimelinePrompt {
    /// The shape the validator enforces, quoted here so a test can hold the instruction and the
    /// decoder to the same one.
    static let schemaLine = """
        {"milestones":[{"title":"...","whatChanged":"...","whyItMattered":"...",\
        "outcome":"inProgress|settled|superseded","from":1,"through":9}]}
        """

    /// Everything the host will refuse a reading for, in one block every lens carries verbatim.
    ///
    /// It is a separate string rather than three similar paragraphs because the lens is a
    /// person's choice and these are not: a reading asked for a different thing still has to
    /// survive the same checks, and the cheapest way to guarantee that is to have one copy.
    static func rules(forFacts factCount: Int) -> String {
        let ceiling = min(
            AgentTimelineBounds.maximumMilestones,
            max(1, factCount / AgentTimelineBounds.minimumFactsPerMilestone)
        )
        return """
        It is NOT one row per prompt, tool call, file edit or hook event. Group the prompts, \
        runs, retries and checks that served one milestone under that milestone, and leave the \
        repetitive exploration and incidental tool noise in the gaps BETWEEN milestones — facts \
        no milestone covers simply do not appear.

        Each fact below is numbered. A milestone is the stretch of numbers it covers: `from` is \
        its first fact and `through` is its last, both inclusive.

        Return ONLY a JSON object, no prose and no code fence:

        \(schemaLine)

        Rules, all enforced by the host — a violation is rejected, not repaired:
        - At most \(ceiling) milestones for this session. Fewer is better.
        - `from` and `through` are fact numbers from the list below, and `from` is never \
        greater than `through`.
        - Milestones do not overlap and run oldest first: each `from` is greater than the \
        previous milestone's `through`. Skip over the facts that belong to no milestone.
        - A milestone covers at least \(AgentTimelineBounds.minimumFactsPerMilestone) facts and \
        at most \(AgentTimelineBounds.maximumFactsPerMilestone(inDigestOf: factCount)); a \
        milestone wider than that is the whole reading rather than a moment in it.
        - `title` is at most \(AgentTimelineBounds.maximumTitleLength) characters and must \
        not restate one fact's own words.
        - `whatChanged` and `whyItMattered` are one sentence each, at most \
        \(AgentTimelineBounds.maximumProseLength) characters.
        - `outcome` is `settled` only when the work finished and nothing later undid it, \
        `superseded` when later work replaced or reverted it, `inProgress` when it is still \
        open. A fact marked OPEN below can never be inside a `settled` milestone.
        - Claim nothing the facts do not support. If the session is mostly setup and \
        exploration, say that in one milestone rather than inventing several.
        """
    }

    static func text(
        for digest: AgentTimelineDigest,
        lens: AgentReadingLens = .milestones
    ) -> String {
        var lines: [String] = [
            lens.framing,
            "",
            rules(forFacts: digest.facts.count),
            "",
            digest.isTruncated
                ? "FACTS (the most recent \(digest.facts.count), numbered 1…\(digest.facts.count); earlier work is not shown):"
                : "FACTS (\(digest.facts.count), oldest first, numbered 1…\(digest.facts.count)):",
        ]

        // Numbered rather than identified. The id a milestone lands on is the host's own lookup
        // now, so the prompt carries a short ordinal in place of a 44-character key it was
        // previously asking the model to transcribe by hand — measured at ~15 KB of an 82.6 KB
        // digest, and at one whole reading discarded when a single transcription went wrong.
        let stamp = ISO8601DateFormatter()
        for (number, fact) in zip(1..., digest.facts) {
            let openMark = fact.isUnsettled ? " OPEN" : ""
            let body = fact.body.isEmpty ? "" : " :: \(fact.body)"
            lines.append(
                "[\(number)] \(stamp.string(from: fact.occurredAt)) \(fact.kind.rawValue)\(openMark) \(fact.title)\(body)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - How the reading is produced  @domain: agent-lens

/// What a reading in flight has told us about itself.
///
/// A reading takes as long as it takes, and the person watching has one question: is this
/// working. Duration cannot answer it and a spinner cannot answer it — only what the run has
/// actually done since it started. It is also what makes the deadline honest, because a run
/// that is still writing is alive by observation rather than by assumption.
enum AgentTimelineProgress: Equatable, Sendable {
    /// The process is up; the CLI has not announced itself yet.
    case launching
    /// The CLI opened its session and is working on the digest.
    case connected
    /// The request is with the API and no part of the reply has come back. Nothing is being read
    /// here and the wait has no stated length, which is the one state a person is likely to watch
    /// for minutes.
    case waiting
    /// The reply is arriving.
    case writing(characters: Int)
    /// The API pushed back and the CLI is waiting out its own backoff before trying again.
    case retrying(attempt: Int)

    var message: String {
        switch self {
        case .launching: "Starting the agent CLI"
        case .connected: "Reading the session"
        case .waiting: "Waiting for the model to start"
        case .writing(let characters): "Writing the reading — \(characters) characters"
        case .retrying(let attempt): "The API is busy — retrying (attempt \(attempt))"
        }
    }
}

/// The seam between Agent Lens and whatever actually does the reasoning.
///
/// It returns the model's RAW text rather than a decoded draft, so decoding and validation stay
/// in one host-owned place. A synthesizer that could hand back an already-decoded
/// `AgentTimelineDraft` would be a second place where "what the model said" becomes "what the
/// host believes", which is the seam this feature most needs to keep single.
///
/// Progress is reported as it happens rather than returned, because its whole value is being
/// early: a fact about the run that arrives with the result explains nothing that the result
/// did not already say.
protocol AgentTimelineSynthesizer: Sendable {
    func synthesize(
        _ digest: AgentTimelineDigest,
        options: AgentReadingOptions,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async throws -> String
}

/// How a pane finds its synthesizer. Async because the answer is on the filesystem, injectable
/// because a headless test must be able to prove the whole loop without one, and given the
/// options because which CLI reads the session is one of them.
typealias AgentTimelineSynthesizerResolver =
    @Sendable (AgentReadingOptions) async -> (any AgentTimelineSynthesizer)?

/// Why a reading did not arrive. Every case says something a person can act on, because on this
/// surface an unexplained failure and an invented success look the same from the outside.
enum AgentTimelineFailure: Error, Equatable, Sendable {
    case noSynthesizer
    case runFailed(String)
    /// The run went quiet. Distinct from `timedOut`, because a reading that stopped saying
    /// anything and a reading that ran long are different things to be told.
    case stalled(silentSeconds: Int)
    case timedOut(seconds: Int)
    case malformedOutput(String)
    case rejected(AgentTimelineRejection)
    case cancelled

    var message: String {
        switch self {
        case .noSynthesizer:
            "No agent CLI was found to read this session with"
        case .runFailed(let detail):
            detail
        case .stalled(let silentSeconds):
            "The reading stopped responding after \(silentSeconds)s of silence"
        case .timedOut(let seconds):
            "The reading did not finish within \(seconds)s"
        case .malformedOutput(let detail):
            "The reading was not usable: \(detail)"
        case .rejected(let rejection):
            rejection.message
        case .cancelled:
            "The reading was cancelled"
        }
    }

    /// Retrying a rejected or malformed reading can plausibly produce a different one; retrying
    /// with no CLI installed cannot. Offering a button that provably does nothing is worse than
    /// offering none.
    var isRetryable: Bool {
        switch self {
        case .noSynthesizer: false
        case .runFailed, .stalled, .timedOut, .malformedOutput, .rejected, .cancelled: true
        }
    }
}

/// What the Timeline account is showing right now.
///
/// Whether the session is long enough to read is deliberately NOT one of these. It is a
/// property of the current snapshot, so it is computed where it is drawn — a stored verdict
/// would be scored once and then keep answering for a session that has since grown.
enum AgentTimelineGeneration: Equatable, Sendable {
    /// Nothing has been asked for yet.
    case idle
    /// A reading of `fingerprint` is being produced, and `progress` is the last thing it said
    /// about itself.
    case running(fingerprint: String, progress: AgentTimelineProgress)
    case ready(AgentSessionTimeline)
    case failed(AgentTimelineFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var timeline: AgentSessionTimeline? {
        if case .ready(let timeline) = self { return timeline }
        return nil
    }
}

/// The gate that stops a slow reading from replacing a newer one.
///
/// A session grows while it is being read. Two refreshes in flight settle in whatever order the
/// model happens to finish them, so "newest wins" cannot be left to arrival order — it has to be
/// a property of the run. Pure, so the race is asserted without ever starting a process.
struct AgentTimelineRunLedger: Equatable, Sendable {
    private(set) var currentRun = 0
    private(set) var settledRun = 0

    /// True while a begun run has neither landed nor been cancelled.
    var isRunning: Bool { currentRun > settledRun }

    /// Starts a run and returns the token its result must carry to land.
    mutating func begin() -> Int {
        currentRun += 1
        return currentRun
    }

    /// Whether this run's result may be shown. `false` means a newer run superseded it, or it
    /// was cancelled, and the work it carries is discarded rather than rendered.
    mutating func settle(run: Int) -> Bool {
        guard run == currentRun, currentRun > settledRun else { return false }
        settledRun = run
        return true
    }

    /// Cancelling advances past the run in flight, so its result can never land.
    mutating func cancel() {
        currentRun += 1
        settledRun = currentRun
    }
}

// MARK: - Reading the model's answer  @domain: agent-lens

/// Turns raw synthesizer output into a draft, or says exactly what was wrong with it.
///
/// Bounded before parsed: a runaway generation is refused at the byte count rather than handed
/// to `JSONDecoder`, so the failure is "too large" instead of a decoder's guess about it.
enum AgentTimelineDraftDecoder {
    static func decode(_ raw: String) -> Result<AgentTimelineDraft, AgentTimelineFailure> {
        guard raw.utf8.count <= AgentTimelineBounds.maximumOutputBytes else {
            return .failure(
                .malformedOutput(
                    "\(raw.utf8.count) bytes exceeds the \(AgentTimelineBounds.maximumOutputBytes)-byte limit"
                )
            )
        }
        guard let object = jsonObject(in: raw) else {
            return .failure(.malformedOutput("no JSON object in the reply"))
        }
        do {
            return .success(try JSONDecoder().decode(AgentTimelineDraft.self, from: Data(object.utf8)))
        } catch {
            return .failure(.malformedOutput(shortened(error)))
        }
    }

    /// The outermost `{…}` in the reply. Models wrap JSON in a fence or introduce it with a
    /// sentence often enough that refusing those replies would be refusing correct readings for
    /// a formatting habit; anything past the braces is not read.
    private static func jsonObject(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(raw[start...end])
    }

    private static func shortened(_ error: any Error) -> String {
        let description = (error as? DecodingError).map(Self.describe) ?? error.localizedDescription
        return description.count > 160 ? String(description.prefix(160)) + "…" : description
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, _): "missing “\(key.stringValue)”"
        case let .typeMismatch(_, context): "wrong type at \(path(context))"
        case let .valueNotFound(_, context): "missing value at \(path(context))"
        case .dataCorrupted(let context): "corrupted at \(path(context))"
        @unknown default: "unreadable JSON"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "the root" : joined
    }
}

/// When a run last said anything, when it started, and whether its quiet has been accounted
/// for. All three are questions the watchdog asks every second, from a thread that is not the
/// one answering them.
///
/// File-scope rather than nested because the silence rule is the part of this feature most worth
/// asserting on its own, and a private nested class cannot be asserted at all.
final class AgentRunActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var last = Date()
    /// Startup is excused from the first instant, because the silence budget would otherwise ask a
    /// program to prove it is alive before it has finished being started.
    ///
    /// Measured 2026-08-16 against CLI 2.1.233, with the arguments this file builds and a real
    /// 320-fact digest: the first frame lands **15.7 s** into an idle run and **25.3 s** into one
    /// of eight concurrent readings — 56% of the 45 s budget spent before the CLI can say a word.
    /// Two things fill that window and both grow with load. Node cold start is one. The other is
    /// structural: the macOS pipe buffer measures 65 536 bytes against a 48.8–82.6 KB prompt, so
    /// `run(…)`'s own `write` blocks for 2.2–11.0 s handing over a prompt the CLI has to finish
    /// reading before it can answer at all.
    ///
    /// It is the same rule `awaitsReply()` states for the other quiet window, applied to the one
    /// phase that was missing it: where the CLI publishes no heartbeat, silence is not evidence,
    /// and the ceiling is the only honest bound. `replyStarted()` revokes it.
    private var explainedUntil: Date? = .distantFuture

    var silence: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    /// Whether something the run said still accounts for the quiet since it said it.
    var silenceIsExplained: Bool {
        lock.withLock { explainedUntil.map { Date() < $0 } ?? false }
    }

    func touch() {
        lock.withLock { last = Date() }
    }

    /// The whole watchdog rule, as one question asked of what the run has said about itself.
    ///
    /// A method here rather than a closure inside `run(…)` because this is the rule the feature
    /// turns on, and a rule that lives in a `DispatchSource` handler can only be asserted by a
    /// child process that goes quiet on demand — which is exactly the seam T-111 recorded as
    /// missing. `silenceBudget` is nil for a provider whose quiet says nothing about it, and the
    /// ceiling outranks every account, so an explained silence can still not hold a pipe forever.
    func expiry(
        silenceBudget: Int?,
        ceilingSeconds: Int
    ) -> AgentCLITimelineSynthesizer.ProcessStopReason? {
        if elapsed >= Double(ceilingSeconds) { return .ceiling }
        guard let silenceBudget, !silenceIsExplained, silence >= Double(silenceBudget) else {
            return nil
        }
        return .silence
    }

    /// Records that the request is with the API and no part of the reply has come back.
    ///
    /// Excused without a deadline, because nothing on the wire states one and the host declines to
    /// invent it. That is the same answer `silenceSeconds(for: .codex)` already gives to the same
    /// question: where the CLI publishes no heartbeat, silence is not evidence, and the absolute
    /// ceiling is the only honest bound. Measured 2026-08-12 against CLI 2.1.228, this stretch is
    /// the only one in a healthy run with no frame in it at all.
    func awaitsReply() {
        lock.withLock {
            explainedUntil = .distantFuture
            last = Date()
        }
    }

    /// Records that the reply started arriving, which is where the CLI's own heartbeat begins.
    ///
    /// It revokes the excuse rather than merely noting the time: from here the run emits a frame
    /// every ~1.4 s, so unexplained quiet is evidence again and the silence deadline is the tight,
    /// measured bound it was written to be.
    func replyStarted() {
        lock.withLock {
            explainedUntil = nil
            last = Date()
        }
    }

    /// Records that the run named its own reason for going quiet, and how long it said that
    /// reason would last.
    ///
    /// The excuse is a deadline rather than an amnesty, because the host is not guessing: the
    /// CLI puts `retry_delay_ms` on the wire. It gets the delay it asked for plus the ordinary
    /// silence budget to say something once the wait is over — a run that misses its own restart
    /// is exactly the kind worth stopping.
    ///
    /// A retry that states no delay is the one case nothing here can bound, so it is excused
    /// outright and the absolute ceiling is left in charge. That is a weaker answer than the
    /// timed one and it is only reached when the CLI declines to say.
    func explain(forSeconds seconds: TimeInterval?) {
        lock.withLock {
            guard let seconds else {
                explainedUntil = .distantFuture
                return
            }
            let budget = seconds + Double(AgentCLITimelineSynthesizer.silenceSeconds)
            explainedUntil = Date().addingTimeInterval(budget)
        }
    }
}

/// What one line of the CLI's NDJSON stream says.
enum AgentCLIStreamReading: Equatable, Sendable {
    /// Framing this host has no use for. Most lines are this, and that is fine.
    case ignored
    /// The CLI announced its session, so the run is past process startup.
    case connected
    /// The CLI handed the request to the API. Everything from here until the reply starts is quiet
    /// the CLI has no heartbeat for, and no frame on the wire says how long it will last.
    case requesting
    /// The model began answering. The CLI heartbeats from here, so quiet means something again.
    case replying
    /// A piece of the reply arrived.
    case wrote(String)
    /// The CLI hit a retryable API error and announced that it is backing off before the next
    /// attempt, carrying the delay it intends to wait when it states one. The run is working,
    /// and the quiet that follows is the backoff it just named — for as long as it named.
    case retrying(attempt: Int, delay: TimeInterval?)
    /// The run reached its terminal event.
    case finished(Result<String, AgentTimelineFailure>)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ignored, .ignored), (.connected, .connected), (.requesting, .requesting),
             (.replying, .replying):
            true
        case let (.wrote(left), .wrote(right)):
            left == right
        case let (.retrying(leftAttempt, leftDelay), .retrying(rightAttempt, rightDelay)):
            leftAttempt == rightAttempt && leftDelay == rightDelay
        case let (.finished(left), .finished(right)):
            switch (left, right) {
            case let (.success(a), .success(b)): a == b
            case let (.failure(a), .failure(b)): a == b
            default: false
            }
        default:
            false
        }
    }
}

/// Reads one line of the provider's own headless event stream.
///
/// Pure, per line, so each CLI's shape is asserted against recorded fixtures rather than against
/// a live login. Verified 2026-08-10 against the installed Claude CLI: `{"type":"system",
/// "subtype":"init",…}`, `{"type":"stream_event","event":{"type":"content_block_delta",
/// "delta":{"type":"text_delta","text":"…"}}}`, and
/// `{"type":"result","subtype":"success","is_error":false,"result":"…"}`. Verified 2026-08-11
/// against the installed Codex CLI: `{"type":"thread.started",…}`, `{"type":"turn.started"}`,
/// `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}`,
/// `{"type":"turn.completed","usage":{…}}`.
enum AgentCLIStreamReader {
    static func read(line: Data, provider: AgentCLI = .claude) -> AgentCLIStreamReading {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return .ignored }
        switch provider {
        case .claude: return claude(record)
        case .codex: return codex(record)
        case .opencode:
            // opencode's answer arrives across several `text` parts and no result event, so it
            // is read by the stateful `AgentOpenCodeCLIStreamReader` instead.
            return .ignored
        }
    }

    /// Codex answers in one message rather than in deltas, so there is no `wrote` to report —
    /// its liveness comes from the process, which is why silence is not a deadline for it.
    private static func codex(_ record: [String: Any]) -> AgentCLIStreamReading {
        switch record["type"] as? String {
        case "thread.started":
            return .connected

        case "item.completed":
            guard let item = record["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String
            else { return .ignored }
            guard !text.isEmpty else {
                return .finished(.failure(.malformedOutput("the CLI returned an empty reply")))
            }
            return .finished(.success(text))

        case "error":
            let detail = record["message"] as? String ?? "the agent CLI reported an error"
            return .finished(.failure(.runFailed(detail)))

        default:
            // `turn.started`, `turn.completed` and reasoning items are framing around the one
            // message that carries the reply.
            return .ignored
        }
    }

    private static func claude(_ record: [String: Any]) -> AgentCLIStreamReading {
        switch record["type"] as? String {
        case "system" where record["subtype"] as? String == "init":
            return .connected

        case "system" where record["subtype"] as? String == "api_retry":
            // Read off the frame the CLI actually builds, confirmed in the installed 2.1.227:
            // `subtype:"api_retry",attempt:…retryAttempt,max_retries:…maxRetries,
            // retry_delay_ms:…retryInMs,error_status:…error.status??null,error:…`. The counters
            // are still optional here, because the subtype is the contract this deadline is bet
            // on and a field name is a weaker thing to bet it on.
            let milliseconds = record["retry_delay_ms"] as? Double
            return .retrying(
                attempt: record["attempt"] as? Int ?? 1,
                delay: milliseconds.map { $0 / 1000 }
            )

        case "system" where record["subtype"] as? String == "status":
            // Recorded from the installed 2.1.228: `{"type":"system","subtype":"status",
            // "status":"requesting",…}`, emitted the moment the request leaves for the API. Only
            // this status accounts for quiet — a future one means something else, and an excuse
            // for arbitrary silence is not a thing to hand out on a name we have not read.
            guard record["status"] as? String == "requesting" else { return .ignored }
            return .requesting

        case "stream_event":
            guard let event = record["event"] as? [String: Any] else { return .ignored }
            // The first frame of the reply, and the point the CLI starts heartbeating: from here
            // it emits `system/thinking_tokens` roughly every 1.4 s even while the model is only
            // thinking, so the run stops being unobservable.
            if event["type"] as? String == "message_start" { return .replying }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return .ignored }
            return .wrote(text)

        case "result":
            let text = record["result"] as? String ?? ""
            if record["is_error"] as? Bool == true {
                return .finished(
                    .failure(.runFailed(text.isEmpty ? "the agent CLI reported an error" : text))
                )
            }
            guard !text.isEmpty else {
                return .finished(.failure(.malformedOutput("the CLI returned an empty reply")))
            }
            return .finished(.success(text))

        default:
            // `assistant` repeats what the deltas already carried, and the rest is framing.
            return .ignored
        }
    }
}

/// Reads opencode's `--format json` stream, which differs from the other two CLIs in one way
/// that matters to a result: its answer arrives as a sequence of complete `text` parts with no
/// result event, so the reader accumulates them and the terminal `step_finish` flushes the
/// accumulation as the result. Stateful where `AgentCLIStreamReader` is pure, because the result
/// is the accumulation of what came before the final event.
final class AgentOpenCodeCLIStreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private var textParts: [String] = []

    func read(line: Data) -> AgentCLIStreamReading {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String
        else { return .ignored }
        switch type {
        case "step_start":
            return .connected

        case "text":
            guard let part = record["part"] as? [String: Any],
                  let text = part["text"] as? String, !text.isEmpty
            else { return .ignored }
            lock.withLock { textParts.append(text) }
            return .wrote(text)

        case "step_finish":
            guard let part = record["part"] as? [String: Any] else { return .ignored }
            switch part["reason"] as? String {
            case "stop":
                let text = lock.withLock { textParts.joined(separator: "\n\n") }
                guard !text.isEmpty else {
                    return .finished(.failure(.malformedOutput("the CLI returned an empty reply")))
                }
                return .finished(.success(text))
            case "error", "tool-error":
                return .finished(.failure(.runFailed("the agent CLI reported an error")))
            default:
                // `tool-calls` and friends end a step that continues in a later one; the answer
                // comes in the text part that follows.
                return .ignored
            }

        case "error":
            let detail = record["message"] as? String ?? "the agent CLI reported an error"
            return .finished(.failure(.runFailed(detail)))

        default:
            return .ignored
        }
    }
}

// MARK: - The CLI-backed synthesizer  @domain: agent-lens

/// Reads a session by running the person's own installed agent CLI headlessly.
///
/// It runs in a scratch directory rather than in the workspace on purpose: the question is about
/// the digest in the prompt, and a run rooted in the project would inherit that project's
/// instructions and directory context, making the reading depend on where the pane happens to
/// be. One turn, no interactive input, output bounded and the process killed at the deadline.
struct AgentCLITimelineSynthesizer: AgentTimelineSynthesizer {
    /// How long a run whose reply is arriving may say nothing before the host stops waiting on it.
    ///
    /// Silence rather than duration, because the stream makes liveness observable: a reading
    /// that is still writing is working, however long it takes, and one that has gone quiet is
    /// the only kind worth killing.
    ///
    /// It bounds the streaming phase only, and it is generous for it: measured 2026-08-12 against
    /// CLI 2.1.228, a 97 KB reading emitted 192 frames over 126.9 s with a largest gap of **2.62 s**,
    /// because the CLI heartbeats through even a purely thinking stretch. The quiet *before* the
    /// reply starts has no such frame in it and is accounted for instead — see
    /// `AgentRunActivity.awaitsReply()`.
    static let silenceSeconds = 45
    /// The backstop for a run that keeps talking and never finishes.
    static let ceilingSeconds = 600
    /// The CLI's own framing is small; the reply is bounded separately by the decoder.
    static let maximumOutputBytes = 512 << 10

    let executableURL: URL
    /// Which CLI this is. Answered once, when the synthesizer was resolved, so nothing later has
    /// to reconcile a stored provider with a requested one.
    let provider: AgentCLI

    /// The installed agent CLI this host would use, or nil when that one is not on the person's
    /// PATH.
    ///
    /// Asks `AgentExecutableLocator`, which is where the agent binaries are and nothing else.
    /// `AgentLaunchDetector` answers a larger question — where the binaries are *and* which
    /// arguments this person habitually passes them — by reading and parsing up to 512 KB of
    /// every shell history file it can find. A reading names its own arguments, so that work was
    /// bought and discarded on the path that launches the CLI: measured on one developer machine
    /// (T-175), 98.1 ms of history parsing against 0.5 ms of directory probing.
    static func installed(
        provider: AgentCLI = .claude,
        locator: AgentExecutableLocator = AgentExecutableLocator()
    ) -> Self? {
        guard let executableURL = locator.scan()[provider] else { return nil }
        return Self(executableURL: executableURL, provider: provider)
    }

    func synthesize(
        _ digest: AgentTimelineDigest,
        options: AgentReadingOptions,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async throws -> String {
        let prompt = AgentTimelinePrompt.text(for: digest, lens: options.lens)
        let executableURL = executableURL
        let provider = provider
        let arguments = Self.arguments(provider: provider, model: options.model)
        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Self.run(
                            executableURL: executableURL,
                            arguments: arguments,
                            provider: provider,
                            prompt: prompt,
                            handle: handle,
                            progress: progress
                        )
                    )
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// The arguments a reading is worth, spelled the way each CLI spells a one-shot run.
    ///
    /// For Claude: `--safe-mode` because this run has one job — read the digest in the prompt and
    /// answer in the schema the host validates — and every customization it would otherwise load
    /// is either irrelevant to that or actively dangerous to it: a custom output style can break
    /// the JSON the validator requires. Measured 2026-08-10 on this machine, dropping them takes
    /// a trivial run from 8.1 s to 4.5 s of wall clock and from 11.3 s to 1.3 s of CPU.
    /// `--no-session-persistence` because a reading is not a session anybody will resume, and
    /// writing one leaves a transcript that Agent Lens would then be able to find.
    ///
    /// For Codex, measured against the installed CLI on 2026-08-11: `exec --json` is the headless
    /// one-shot, `--skip-git-repo-check` because the run is rooted in scratch space rather than in
    /// the project, `-s read-only` because reading a digest never needs to write, and the trailing
    /// `-` because that is how it takes its prompt from stdin.
    static func arguments(provider: AgentCLI, model: AgentReadingModel) -> [String] {
        switch provider {
        case .claude:
            var arguments = [
                "--print",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--max-turns", "1",
                "--safe-mode",
                "--no-session-persistence",
            ]
            if let alias = model.alias { arguments += ["--model", alias] }
            return arguments
        case .codex:
            var arguments = [
                "exec",
                "--json",
                "--skip-git-repo-check",
                "-s", "read-only",
            ]
            if let alias = model.alias { arguments += ["--model", alias] }
            // `-` last, because `codex exec` reads its prompt from stdin only when the prompt
            // argument is absent or is exactly that.
            arguments.append("-")
            return arguments
        case .opencode:
            // `run --format json` reads the prompt from stdin when no message is given, which is
            // how the shared runner hands it over. The model id is `provider/model`.
            var arguments = ["run", "--format", "json"]
            if let alias = model.alias { arguments += ["--model", alias] }
            return arguments
        }
    }

    /// How long a run of this provider may say nothing, or nil when silence says nothing about
    /// it.
    ///
    /// The silence rule was justified by the stream: a reading that is still writing is alive by
    /// observation. A CLI that answers in one message at the end has no such signal, so the same
    /// rule would kill healthy runs — the ceiling is the only honest bound there.
    static func silenceSeconds(for provider: AgentCLI) -> Int? {
        switch provider {
        case .claude: silenceSeconds
        // `codex exec --json` reports items as they complete rather than tokens as they arrive,
        // so a healthy run is quiet for its whole reasoning turn. The ceiling is its only bound.
        // opencode is the same shape: `text` arrives as one complete part per message, so a
        // healthy run can be quiet across a whole reasoning turn too.
        case .codex, .opencode: nil
        }
    }

    /// The readers this machine actually has, in the order `AgentCLI` declares them.
    ///
    /// Answered from the same locator `installed(provider:)` uses, so the list a person picks
    /// from and the binary their run finds can never be two different questions.
    static func installedProviders(
        locator: AgentExecutableLocator = AgentExecutableLocator()
    ) -> [AgentCLI] {
        let found = locator.scan()
        return AgentCLI.allCases.filter { found[$0] != nil }
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        provider: AgentCLI,
        prompt: String,
        handle: ProcessHandle,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) -> Result<String, any Error> {
        let silence = silenceSeconds(for: provider)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        guard handle.adopt(process) else { return .failure(AgentTimelineFailure.cancelled) }
        let startedAt = Date()
        do {
            try process.run()
        } catch {
            TenonLog.agentLens.error(
                "reading failed to start: \(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .public)"
            )
            return .failure(AgentTimelineFailure.runFailed(error.localizedDescription))
        }
        progress(.launching)
        TenonLog.agentLens.info(
            """
            reading started: provider=\(provider.rawValue, privacy: .public) \
            prompt=\(prompt.utf8.count, privacy: .public)B \
            silenceBudget=\(silence.map(String.init) ?? "none", privacy: .public) \
            ceiling=\(ceilingSeconds, privacy: .public)s
            """
        )

        let activity = AgentRunActivity()
        // The deadline lives with the process, not with the caller's await: a CLI that never
        // writes and never exits would otherwise hold a pipe open for as long as the pane does.
        // It watches silence rather than duration — the stream is what makes that difference
        // observable — and keeps a ceiling for a run that talks forever.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        watchdog.setEventHandler {
            if let reason = activity.expiry(
                silenceBudget: silence,
                ceilingSeconds: ceilingSeconds
            ) {
                handle.expire(reason)
            }
        }
        watchdog.resume()

        let reading = StreamReading()
        let opencodeReader = provider == .opencode ? AgentOpenCodeCLIStreamReader() : nil
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 64 << 10),
                  !chunk.isEmpty
            {
                activity.touch()
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let length = pending.distance(from: pending.startIndex, to: newline)
                    let line = Data(pending.prefix(length))
                    pending.removeFirst(length + 1)
                    guard !line.isEmpty else { continue }
                    let event = opencodeReader.map { $0.read(line: line) }
                        ?? AgentCLIStreamReader.read(line: line, provider: provider)
                    // Which phase the run is in decides whether its quiet means anything, so the
                    // deadline is told before the pane is.
                    switch event {
                    case .requesting: activity.awaitsReply()
                    case .replying: activity.replyStarted()
                    case .retrying(_, let delay): activity.explain(forSeconds: delay)
                    case .ignored, .connected, .wrote, .finished: break
                    }
                    if let update = reading.consume(event) {
                        progress(update)
                    }
                }
                // One line carries the whole reply, so the cap belongs to the line rather than
                // to the transcript of framing around it.
                if pending.count > maximumOutputBytes {
                    handle.expire(.overflow)
                    break
                }
            }
            group.leave()
        }
        // Drained and discarded concurrently: a chatty stderr filling its pipe buffer deadlocks
        // the stdout read, and that hang has no symptom a timeout here would explain.
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 64 << 10),
                  !chunk.isEmpty
            {}
            group.leave()
        }

        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        let outcome = settlement(
            stopReason: handle.stopReason,
            reading: reading,
            silence: silence,
            terminationStatus: process.terminationStatus
        )
        // The one line that makes a reported failure readable instead of reconstructable: which
        // deadline stopped it, how long it lasted, and what the CLI had managed to say by then.
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        switch outcome {
        case .success(let raw):
            TenonLog.agentLens.info(
                "reading finished: \(elapsed, privacy: .public)s reply=\(raw.utf8.count, privacy: .public)B"
            )
        case .failure(let error):
            let reason = (error as? AgentTimelineFailure)?.message ?? error.localizedDescription
            TenonLog.agentLens.error(
                """
                reading ended without a result: \(elapsed, privacy: .public)s \
                exit=\(process.terminationStatus, privacy: .public) \
                reason=\(reason, privacy: .public)
                """
            )
        }
        return outcome
    }

    /// Why the run ended, read once from the process and the stream together.
    ///
    /// Separated from `run(…)` so the terminal state has a name before it is both returned and
    /// logged — the alternative is eight return statements each having to remember to say what
    /// they did.
    private static func settlement(
        stopReason: ProcessStopReason?,
        reading: StreamReading,
        silence: Int?,
        terminationStatus: Int32
    ) -> Result<String, any Error> {
        switch stopReason {
        case .silence:
            return .failure(AgentTimelineFailure.stalled(silentSeconds: silence ?? silenceSeconds))
        case .ceiling:
            return .failure(AgentTimelineFailure.timedOut(seconds: ceilingSeconds))
        case .cancelled:
            return .failure(AgentTimelineFailure.cancelled)
        case .overflow:
            return .failure(
                AgentTimelineFailure
                    .malformedOutput("the CLI wrote more than \(maximumOutputBytes) bytes")
            )
        case .none:
            break
        }
        if let outcome = reading.outcome {
            return outcome.mapError { $0 as any Error }
        }
        guard terminationStatus == 0 else {
            return .failure(
                AgentTimelineFailure.runFailed("the agent CLI exited \(terminationStatus)")
            )
        }
        return .failure(AgentTimelineFailure.malformedOutput("the CLI wrote no result event"))
    }

    /// Folds the stream into the two things the host needs from it: what to show now, and the
    /// one result to return. Throttled, because a reply arrives in fragments and a person
    /// cannot read a counter that changes forty times a second.
    private final class StreamReading: @unchecked Sendable {
        private static let reportEvery = 250
        private let lock = NSLock()
        private var characters = 0
        private var reported = 0
        private var result: Result<String, AgentTimelineFailure>?

        var outcome: Result<String, AgentTimelineFailure>? { lock.withLock { result } }

        func consume(_ reading: AgentCLIStreamReading) -> AgentTimelineProgress? {
            lock.withLock {
                switch reading {
                case .ignored:
                    return nil
                case .connected:
                    return .connected
                case .requesting:
                    return .waiting
                case .replying:
                    // The model has started, so "waiting for it to start" has stopped being true —
                    // but a character count is not true yet either, because it may think for a
                    // long time before writing a word. Measured 2026-08-12: 11752 thinking tokens
                    // and 126 s before the first one.
                    return .connected
                case .wrote(let text):
                    characters += text.count
                    guard characters - reported >= Self.reportEvery || reported == 0 else {
                        return nil
                    }
                    reported = characters
                    return .writing(characters: characters)
                case .retrying(let attempt, _):
                    // Reported rather than throttled: a retry is rare, and it is the one thing
                    // that explains a long quiet to the person watching.
                    return .retrying(attempt: attempt)
                case .finished(let value):
                    if result == nil { result = value }
                    return nil
                }
            }
        }
    }

    /// Why a run stopped, when it stopped for a reason of ours rather than by finishing.
    enum ProcessStopReason: Equatable, Sendable {
        case cancelled
        case silence
        case ceiling
        case overflow
    }

    /// The one place the process and its stop reason are shared across threads.
    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var reason: ProcessStopReason?

        var stopReason: ProcessStopReason? { lock.withLock { reason } }

        /// `false` when cancellation already arrived, so a process is never started for a run
        /// nobody is waiting on.
        func adopt(_ process: Process) -> Bool {
            lock.withLock {
                guard reason == nil else { return false }
                self.process = process
                return true
            }
        }

        func terminate() {
            stop(because: .cancelled, evenIfFinished: true)
        }

        func expire(_ cause: ProcessStopReason) {
            stop(because: cause, evenIfFinished: false)
        }

        /// The first reason wins: a process killed for silence that a cancel then reaches must
        /// still report the silence, or the person is told they stopped something that had
        /// already stopped itself.
        private func stop(because cause: ProcessStopReason, evenIfFinished: Bool) {
            let running = lock.withLock { () -> Process? in
                let isRunning = process?.isRunning == true
                guard isRunning || (evenIfFinished && process == nil) else { return nil }
                if reason == nil { reason = cause }
                return isRunning ? process : nil
            }
            running?.terminate()
        }
    }
}
