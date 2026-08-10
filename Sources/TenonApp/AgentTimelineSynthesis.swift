// @domain: agent-lens
import Foundation

// MARK: - The instruction  @domain: agent-lens

/// What the synthesizing agent is asked, as one pure function of the digest.
///
/// Pure because the prompt is the largest thing in this feature that can silently rot: it is
/// prose, it is never compiled, and nothing else in the pipeline notices when it stops asking
/// for the shape the validator enforces. Keeping it here means a test can assert that the
/// instruction and `AgentTimelineBounds` still agree.
enum AgentTimelinePrompt {
    static func text(for digest: AgentTimelineDigest) -> String {
        let ceiling = min(
            AgentTimelineBounds.maximumMilestones,
            max(1, digest.facts.count / AgentTimelineBounds.minimumFactsPerMilestone)
        )

        var lines: [String] = [
            """
            You are reading one terminal AI-agent session and writing the few milestones that \
            explain it to a person who was not watching.

            A milestone is a moment the session materially changed direction or state — \
            "reproduced the focus loop", "found the competing focus writers", "changed the \
            ownership rule", "verified the fix". It is NOT one row per prompt, tool call, file \
            edit or hook event. Group the prompts, runs, retries and checks that served one \
            milestone under that milestone, and leave out repetitive exploration and incidental \
            tool noise entirely — a fact you do not cite simply does not appear.

            Return ONLY a JSON object, no prose and no code fence:

            {"milestones":[{"title":"...","whatChanged":"...","whyItMattered":"...",\
            "outcome":"inProgress|settled|superseded","anchors":["fact-id","fact-id"]}]}

            Rules, all enforced by the host — a violation is rejected, not repaired:
            - At most \(ceiling) milestones for this session. Fewer is better.
            - `anchors` are fact ids copied EXACTLY from the list below. Inventing one is \
            rejected. Every milestone needs at least one.
            - A fact belongs to at most ONE milestone. Do not cite the same id twice.
            - `title` is at most \(AgentTimelineBounds.maximumTitleLength) characters and must \
            not restate one fact's own words.
            - `whatChanged` and `whyItMattered` are one sentence each, at most \
            \(AgentTimelineBounds.maximumProseLength) characters.
            - `outcome` is `settled` only when the work finished and nothing later undid it, \
            `superseded` when later work replaced or reverted it, `inProgress` when it is still \
            open. A fact marked OPEN below can never be inside a `settled` milestone.
            - Claim nothing the facts do not support. If the session is mostly setup and \
            exploration, say that in one milestone rather than inventing several.
            """,
            "",
            digest.isTruncated
                ? "FACTS (the most recent \(digest.facts.count); earlier work is not shown):"
                : "FACTS (\(digest.facts.count), oldest first):",
        ]

        let stamp = ISO8601DateFormatter()
        for fact in digest.facts {
            let openMark = fact.isUnsettled ? " OPEN" : ""
            let body = fact.body.isEmpty ? "" : " :: \(fact.body)"
            lines.append(
                "[\(fact.id)] \(stamp.string(from: fact.occurredAt)) \(fact.kind.rawValue)\(openMark) \(fact.title)\(body)"
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
    /// The reply is arriving.
    case writing(characters: Int)

    var message: String {
        switch self {
        case .launching: "Starting the agent CLI"
        case .connected: "Reading the session"
        case .writing(let characters): "Writing the reading — \(characters) characters"
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
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async throws -> String
}

/// How a pane finds its synthesizer. Async because the answer is on the filesystem, and
/// injectable because a headless test must be able to prove the whole loop without one.
typealias AgentTimelineSynthesizerResolver = @Sendable () async -> (any AgentTimelineSynthesizer)?

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

/// What one line of the CLI's NDJSON stream says.
enum AgentCLIStreamReading: Equatable, Sendable {
    /// Framing this host has no use for. Most lines are this, and that is fine.
    case ignored
    /// The CLI announced its session, so the run is past process startup.
    case connected
    /// A piece of the reply arrived.
    case wrote(String)
    /// The run reached its terminal event.
    case finished(Result<String, AgentTimelineFailure>)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ignored, .ignored), (.connected, .connected):
            true
        case let (.wrote(left), .wrote(right)):
            left == right
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

/// Reads one line of `claude --print --output-format stream-json --verbose`.
///
/// Pure, per line, so the CLI's shape is asserted against recorded fixtures rather than against
/// a live login. Verified 2026-08-10 against the installed CLI: `{"type":"system",
/// "subtype":"init",…}`, `{"type":"stream_event","event":{"type":"content_block_delta",
/// "delta":{"type":"text_delta","text":"…"}}}`, and
/// `{"type":"result","subtype":"success","is_error":false,"result":"…"}`.
enum AgentCLIStreamReader {
    static func read(line: Data) -> AgentCLIStreamReading {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return .ignored }
        switch record["type"] as? String {
        case "system" where record["subtype"] as? String == "init":
            return .connected

        case "stream_event":
            guard let event = record["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
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

// MARK: - The CLI-backed synthesizer  @domain: agent-lens

/// Reads a session by running the person's own installed agent CLI headlessly.
///
/// It runs in a scratch directory rather than in the workspace on purpose: the question is about
/// the digest in the prompt, and a run rooted in the project would inherit that project's
/// instructions and directory context, making the reading depend on where the pane happens to
/// be. One turn, no interactive input, output bounded and the process killed at the deadline.
struct AgentCLITimelineSynthesizer: AgentTimelineSynthesizer {
    /// How long a run may say nothing at all before the host stops waiting on it.
    ///
    /// Silence rather than duration, because the stream makes liveness observable: a reading
    /// that is still writing is working, however long it takes, and one that has gone quiet is
    /// the only kind worth killing.
    static let silenceSeconds = 45
    /// The backstop for a run that keeps talking and never finishes.
    static let ceilingSeconds = 600
    /// The CLI's own framing is small; the reply is bounded separately by the decoder.
    static let maximumOutputBytes = 512 << 10

    let executableURL: URL

    /// The installed agent CLI this host would use, or nil when none is on the person's PATH.
    ///
    /// Reuses `AgentLaunchDetector` rather than probing again: where the agent binaries are is
    /// already one question with one answer in this app.
    static func installed(detector: AgentLaunchDetector = AgentLaunchDetector()) -> Self? {
        let suggestions = detector.scan()
        guard let claude = suggestions.first(where: { $0.agent == .claude }) else { return nil }
        return Self(executableURL: claude.executableURL)
    }

    func synthesize(
        _ digest: AgentTimelineDigest,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async throws -> String {
        let prompt = AgentTimelinePrompt.text(for: digest)
        let executableURL = executableURL
        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Self.run(
                            executableURL: executableURL,
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

    /// The arguments a reading is worth.
    ///
    /// `--safe-mode` because this run has one job — read the digest in the prompt and answer in
    /// the schema the host validates — and every customization it would otherwise load is either
    /// irrelevant to that or actively dangerous to it: a custom output style can break the JSON
    /// the validator requires. Measured 2026-08-10 on this machine, dropping them takes a
    /// trivial run from 8.1 s to 4.5 s of wall clock and from 11.3 s to 1.3 s of CPU.
    /// `--no-session-persistence` because a reading is not a session anybody will resume, and
    /// writing one leaves a transcript that Agent Lens would then be able to find.
    static let arguments = [
        "--print",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--max-turns", "1",
        "--safe-mode",
        "--no-session-persistence",
    ]

    private static func run(
        executableURL: URL,
        prompt: String,
        handle: ProcessHandle,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) -> Result<String, any Error> {
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
        do {
            try process.run()
        } catch {
            return .failure(AgentTimelineFailure.runFailed(error.localizedDescription))
        }
        progress(.launching)

        let activity = ActivityClock()
        // The deadline lives with the process, not with the caller's await: a CLI that never
        // writes and never exits would otherwise hold a pipe open for as long as the pane does.
        // It watches silence rather than duration — the stream is what makes that difference
        // observable — and keeps a ceiling for a run that talks forever.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        watchdog.setEventHandler {
            if activity.elapsed >= Double(ceilingSeconds) {
                handle.expire(.ceiling)
            } else if activity.silence >= Double(silenceSeconds) {
                handle.expire(.silence)
            }
        }
        watchdog.resume()

        let reading = StreamReading()
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
                    if let update = reading.consume(AgentCLIStreamReader.read(line: line)) {
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

        switch handle.stopReason {
        case .silence:
            return .failure(AgentTimelineFailure.stalled(silentSeconds: silenceSeconds))
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
        guard process.terminationStatus == 0 else {
            return .failure(
                AgentTimelineFailure.runFailed("the agent CLI exited \(process.terminationStatus)")
            )
        }
        return .failure(AgentTimelineFailure.malformedOutput("the CLI wrote no result event"))
    }

    /// When the run last said anything, and when it started. Both questions the watchdog asks
    /// every second, from a thread that is not the one answering them.
    private final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private let started = Date()
        private var last = Date()

        var silence: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        var elapsed: TimeInterval { Date().timeIntervalSince(started) }

        func touch() {
            lock.withLock { last = Date() }
        }
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
                case .wrote(let text):
                    characters += text.count
                    guard characters - reported >= Self.reportEvery || reported == 0 else {
                        return nil
                    }
                    reported = characters
                    return .writing(characters: characters)
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
