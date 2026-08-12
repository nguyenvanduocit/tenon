// @domain: agent-lens
import Foundation
import Observation
import TenonCore

enum AgentLensInputError: Error, Equatable, Sendable {
    case empty
    case foregroundProcessChanged
    case cancelled
}

struct AgentLensInputTransport: Sendable {
    let sendFrame: @MainActor @Sendable (String) -> Bool
}

enum AgentOptionSubmission: Sendable {
    case hotkey
    case hotkeyThenReturn

    func frame(for hotkey: String) -> String {
        switch self {
        case .hotkey: hotkey
        case .hotkeyThenReturn: hotkey + "\r"
        }
    }
}

struct AgentOptionSubmissionGate: Sendable {
    private(set) var requestID: String?

    mutating func begin(requestID: String, pendingRequestID: String?) -> Bool {
        guard requestID == pendingRequestID, self.requestID != requestID else { return false }
        self.requestID = requestID
        return true
    }

    mutating func reconcile(pendingRequestID: String?) {
        guard requestID != pendingRequestID else { return }
        requestID = nil
    }

    mutating func fail(requestID: String) {
        guard self.requestID == requestID else { return }
        self.requestID = nil
    }
}

extension AgentProvider {
    var optionSubmission: AgentOptionSubmission {
        switch self {
        case .claude: .hotkeyThenReturn
        case .codex: .hotkey
        }
    }
}

/// FIFO input owns the caller continuations and the only draining task. `draining` stays
/// true across the inter-frame suspension, so actor reentrancy can append but can never
/// interleave two bracketed-paste transactions.
actor AgentLensInputQueue {
    private enum Payload {
        /// A message: pasted as one bracketed transaction, then submitted.
        case text(String)
        /// The provider-specific option selection, kept in one foreground-guarded PTY frame.
        case option(String)
    }

    private struct Request {
        let payload: Payload
        let continuation: CheckedContinuation<Result<Void, AgentLensInputError>, Never>
    }

    private let transport: AgentLensInputTransport
    private var requests: [Request] = []
    private var draining = false
    private var drainTask: Task<Void, Never>?
    private var stopped = false

    init(transport: AgentLensInputTransport) {
        self.transport = transport
    }

    func send(_ text: String) async throws {
        guard !text.isEmpty else { throw AgentLensInputError.empty }
        try await enqueue(.text(text))
    }

    /// Answers a prompt using the selection sequence its provider reads.
    func submitOption(_ key: String, using submission: AgentOptionSubmission) async throws {
        guard !key.isEmpty else { throw AgentLensInputError.empty }
        try await enqueue(.option(submission.frame(for: key)))
    }

    private func enqueue(_ payload: Payload) async throws {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Void, AgentLensInputError>, Never>) in
            guard !stopped else {
                continuation.resume(returning: .failure(.cancelled))
                return
            }
            requests.append(Request(payload: payload, continuation: continuation))
            startDrainIfNeeded()
        }
        try result.get()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        drainTask?.cancel()
        drainTask = nil
        draining = false
        let waiting = requests
        requests.removeAll()
        for request in waiting {
            request.continuation.resume(returning: .failure(.cancelled))
        }
    }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        draining = true
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !Task.isCancelled, !stopped, !requests.isEmpty {
            let request = requests.removeFirst()
            guard case let .text(text) = request.payload else {
                guard case let .option(frame) = request.payload else { continue }
                request.continuation.resume(
                    returning: await transport.sendFrame(frame)
                        ? .success(())
                        : .failure(.foregroundProcessChanged)
                )
                continue
            }
            let safeText = text.replacingOccurrences(
                of: "\u{1B}[201~",
                with: ""
            )
            let paste = "\u{1B}[200~\(safeText)\u{1B}[201~"
            guard await transport.sendFrame(paste) else {
                request.continuation.resume(returning: .failure(.foregroundProcessChanged))
                continue
            }
            do {
                try await Task.sleep(for: .milliseconds(35))
            } catch {
                request.continuation.resume(returning: .failure(.cancelled))
                break
            }
            guard await transport.sendFrame("\r") else {
                request.continuation.resume(returning: .failure(.foregroundProcessChanged))
                continue
            }
            request.continuation.resume(returning: .success(()))
        }

        if Task.isCancelled || stopped {
            let waiting = requests
            requests.removeAll()
            for request in waiting {
                request.continuation.resume(returning: .failure(.cancelled))
            }
        }
        drainTask = nil
        draining = false
        if !stopped && !requests.isEmpty { startDrainIfNeeded() }
    }
}

/// One actor per attached session. It serializes normalized events into a pure reducer
/// and coalesces high-frequency deltas before crossing to MainActor. Durable message,
/// tool, interaction, and lifecycle events publish immediately.
actor AgentLensSessionCoordinator {
    typealias Publisher = @MainActor @Sendable (AgentLensSnapshot) -> Void

    private var reducer = AgentLensReducer()
    private var publisher: Publisher?
    private var coalescedPublishTask: Task<Void, Never>?

    func consume(
        _ stream: AsyncThrowingStream<AgentLensEvent, any Error>,
        seed: [AgentLensEvent],
        publish: @escaping Publisher
    ) async {
        publisher = publish
        for event in seed { reducer.apply(event) }
        await publish(reducer.snapshot)

        do {
            for try await event in stream {
                guard !Task.isCancelled else { break }
                reducer.apply(event)
                if event.isHighFrequencyDelta {
                    scheduleCoalescedPublish()
                } else {
                    await publishImmediately()
                }
            }
        } catch {
            var evidence = AgentEvidence.terminalInference("agent-lens:event-stream")
            evidence.freshness = .gap
            reducer.apply(
                .diagnostic(
                    AgentLensDiagnostic(
                        id: "event-stream-ended",
                        severity: .error,
                        message: error is AgentLensSourceError
                            ? "Agent event buffer overflowed; projection is incomplete"
                            : "Agent event stream ended: \(error.localizedDescription)",
                        evidence: evidence
                    )
                )
            )
            await publishImmediately()
        }
        await publishImmediately()
    }

    func apply(_ event: AgentLensEvent, publish: @escaping Publisher) async {
        publisher = publish
        reducer.apply(event)
        await publishImmediately()
    }

    func stop() {
        coalescedPublishTask?.cancel()
        coalescedPublishTask = nil
        publisher = nil
    }

    private func scheduleCoalescedPublish() {
        guard coalescedPublishTask == nil else { return }
        coalescedPublishTask = Task {
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            await self.flushCoalescedPublish()
        }
    }

    private func flushCoalescedPublish() async {
        coalescedPublishTask = nil
        guard let publisher else { return }
        await publisher(reducer.snapshot)
    }

    private func publishImmediately() async {
        coalescedPublishTask?.cancel()
        coalescedPublishTask = nil
        guard let publisher else { return }
        await publisher(reducer.snapshot)
    }
}

@MainActor
@Observable
final class AgentLensViewModel {
    let slotID: UUID

    private(set) var snapshot = AgentLensSnapshot.empty
    private(set) var timelineItems: [AgentTimelineItem] = []
    private(set) var declaredQuestion: AgentQuestionRecord?
    private(set) var resolution: AgentLensResolution?
    private(set) var isSending = false
    /// Which reading of the attached session the Session renderer draws. Local host UI state:
    /// it changes no attachment, sends nothing to the PTY, and is independent of
    /// `mode`/`showsSplitView`.
    var account: AgentLensAccount = .chat
    private(set) var timelineGeneration: AgentTimelineGeneration = .idle
    /// How the NEXT reading will be taken. Local host UI state, like `account`: picking a
    /// different reader or lens changes nothing about the attachment until someone asks for a
    /// reading with it.
    var readingOptions = AgentReadingOptions()
    /// How the reading on screen — or the one in flight — was actually asked for.
    ///
    /// Separate from `readingOptions` because a run in flight has to keep the options it started
    /// with: the person is free to pick different ones while it works, and those belong to the
    /// next reading rather than retroactively to this one.
    private(set) var readingOptionsInUse: AgentReadingOptions?
    /// Which CLIs this machine can read a session with. Empty until the scan answers, and a
    /// single entry is not a choice — the pane offers a reader picker only over two or more.
    private(set) var availableReaders: [AgentCLI] = []
    /// The fact Chat should scroll to when it next draws, set by a milestone's anchor. Cleared
    /// by whichever list consumes it, so one anchor click scrolls once.
    var pendingChatFocus: String?
    /// Which renderer the pane shows. Detecting an agent fills in the pane's chrome header and
    /// leaves this alone: the pane is a live PTY someone is typing into, so the choice of
    /// renderer stays with them.
    var mode: AgentLensMode = .terminal
    var showsSplitView = false
    /// Whether the context-and-evidence panel is open.
    ///
    /// Pane state rather than view state, because two readers write it: the chrome header's
    /// toggle, which also has to READ it back to draw itself in the right position, and a
    /// timeline row raising the inspector on its own evidence. A `@State` inside the body view
    /// could serve only the second.
    var showsInspector = false
    /// Which fact the panel is showing evidence for, or nil for the session's own context.
    var inspection: AgentLensInspection?
    var draft = ""

    @ObservationIgnored private weak var terminalPool: SurfacePool?
    @ObservationIgnored private let discovery: AgentLensDiscovery
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var questionTask: Task<Void, Never>?
    @ObservationIgnored private let questions: AgentAskStore
    @ObservationIgnored private var coordinator: AgentLensSessionCoordinator?
    @ObservationIgnored private var inputQueue: AgentLensInputQueue?
    @ObservationIgnored private var consecutiveMisses = 0
    @ObservationIgnored private var didAnnounceHookCapabilities = false
    @ObservationIgnored private let resolveTimelineSynthesizer: AgentTimelineSynthesizerResolver
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineLedger = AgentTimelineRunLedger()
    /// How many facts the reading on screen was made from. Comparing counts is O(1) and moves
    /// only when something actually happened, so a streaming reply does not mark a fresh
    /// reading stale several times a second.
    @ObservationIgnored private var readingFactCount: Int?
    /// Run-local, content-free correlation for the bounded diagnostics transition ring.
    /// It is deliberately not the slot UUID or provider session identifier.
    @ObservationIgnored let diagnosticsPaneOrdinal: Int
    private var optionSubmissionGate = AgentOptionSubmissionGate()

    /// What this pane is reading: a live PTY, or a session that already finished. Fixed for
    /// the model's whole life — a resumed recording gets a NEW model, because the pane it
    /// becomes owns a surface this one never had.
    @ObservationIgnored let attachment: AgentLensAttachment

    /// `terminalPool` is optional because a recorded pane has no surface to hold. It is the
    /// same weak reference either way, so nothing downstream learns a second way to be absent.
    init(
        slotID: UUID,
        terminalPool: SurfacePool?,
        discovery: AgentLensDiscovery,
        attachment: AgentLensAttachment = .live,
        questions: AgentAskStore = AgentAskStore(),
        resolveTimelineSynthesizer: @escaping AgentTimelineSynthesizerResolver =
            AgentLensViewModel.installedTimelineSynthesizer
    ) {
        self.slotID = slotID
        self.terminalPool = terminalPool
        self.discovery = discovery
        self.attachment = attachment
        self.questions = questions
        self.resolveTimelineSynthesizer = resolveTimelineSynthesizer
        self.diagnosticsPaneOrdinal = DiagnosticsRuntimeSignals.shared.registerAgentLensPane()
        // A live pane opens on its terminal because someone is typing into it. A recorded one
        // opens on its reading, because the reading is the entire reason the pane exists.
        if attachment.recordedSession != nil { mode = .session }
    }

    /// Finding the agent binary reads the filesystem, which the interaction law forbids on
    /// `MainActor`, and it is asked for only when someone actually wants a reading — so it is
    /// resolved inside the generation's own task rather than at pane construction.
    static let installedTimelineSynthesizer: AgentTimelineSynthesizerResolver = { options in
        await Task.detached(priority: .userInitiated) {
            AgentCLITimelineSynthesizer.installed(provider: options.provider)
        }.value
    }

    /// The same scan, asked for the whole list rather than for one provider's binary.
    static let installedReaders: AgentReadingReaderDetector = {
        await Task.detached(priority: .utility) {
            AgentCLITimelineSynthesizer.installedProviders()
        }.value
    }

    /// Narrows the reader choice to the CLIs this machine actually has, and moves the pending
    /// choice onto one of them when the current pick is not installed.
    ///
    /// An empty answer leaves the choice alone rather than emptying it: a scan that found nothing
    /// says the reader picker has nothing to offer, and the invitation already reports a missing
    /// CLI honestly through `noSynthesizer` when someone asks for a reading anyway.
    func loadAvailableReaders(
        using detect: AgentReadingReaderDetector = AgentLensViewModel.installedReaders
    ) async {
        let readers = await detect()
        availableReaders = readers
        guard let first = readers.first, !readers.contains(readingOptions.provider) else { return }
        readingOptions.select(provider: first)
    }

    var isAgentDetected: Bool { resolution != nil || snapshot.provider != nil }

    var submittedOptionRequestID: String? { optionSubmissionGate.requestID }

    var canSend: Bool {
        attachment.allowsSending && resolution != nil && snapshot.canSend && !isSending &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        guard discoveryTask == nil else { return }
        observeDeclaredQuestions()
        // A recorded session is attached once, from the reference the pane was opened with.
        // There is no process to poll for, and polling would report the session as ended.
        guard attachment.startsDiscovery else {
            guard let resolution = attachment.resolution else { return }
            discoveryTask = Task { [weak self] in
                await self?.attach(resolution)
            }
            return
        }
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.discoveryLoop()
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        streamTask?.cancel()
        streamTask = nil
        questionTask?.cancel()
        questionTask = nil
        if let coordinator { Task { await coordinator.stop() } }
        if let inputQueue { Task { await inputQueue.stop() } }
        coordinator = nil
        inputQueue = nil
        optionSubmissionGate.reconcile(pendingRequestID: nil)
        discardTimeline()
    }

    /// The pane-owned declared channel outranks provider extraction. A separate stream is
    /// created for this model, because `AsyncStream` divides values between consumers rather
    /// than broadcasting one stream to every pane surface.
    private func observeDeclaredQuestions() {
        guard questionTask == nil else { return }
        let slotID = slotID
        let questions = questions
        questionTask = Task { [weak self] in
            let updates = await questions.updates(matching: .pane(slotID))
            for await record in updates {
                guard !Task.isCancelled else { break }
                self?.receiveDeclaredQuestion(record)
            }
        }
    }

    func receiveDeclaredQuestion(_ record: AgentQuestionRecord) {
        guard record.paneID == slotID else { return }
        if record.state == .pending, record.recipient == .human {
            declaredQuestion = record
        } else if declaredQuestion?.id == record.id {
            declaredQuestion = nil
        }
    }

    func answerDeclaredQuestion(with choice: AgentQuestionChoice) async -> Bool {
        guard let question = declaredQuestion,
              question.state == .pending,
              question.choices.contains(where: { $0.id == choice.id })
        else { return false }
        do {
            try await questions.answer(
                questionID: question.id,
                responder: AppIntentRuntime.userPrincipal,
                choiceID: choice.id
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - The synthesized reading  @domain: agent-lens

    /// Whether the session has moved since the reading on screen was made.
    ///
    /// Only a `ready` reading can be stale. A run in flight is already about to be replaced, and
    /// a failure describes an attempt rather than a state of the session.
    var timelineIsStale: Bool {
        guard case .ready = timelineGeneration, let readingFactCount else { return false }
        return snapshot.factCount != readingFactCount
    }

    /// Follows a milestone's anchor back to the fact it stood on.
    ///
    /// Two return paths, because they cover different facts. The inspector shows the evidence
    /// for ANY anchored fact — source, authority, location, byte offset, fingerprint — and it is
    /// what makes the synthesis checkable rather than merely readable. Chat additionally scrolls
    /// to the row, for the facts Chat draws.
    func returnToEvidence(_ factID: String) {
        guard let item = snapshot.timelineItems.first(where: { $0.id == factID }) else { return }
        inspection = AgentLensInspection(fact: item)
        showsInspector = inspection != nil
        account = .chat
        pendingChatFocus = factID
    }

    /// Reads this session into milestones. Explicit, never automatic: a reading costs the
    /// person a model call, so it happens when they ask for one.
    ///
    /// An unreadable session is refused here rather than reported, and refused silently: the
    /// invitation is only drawn over a session `AgentTimelineDigest.insufficiency(of:)` admits,
    /// so arriving with too little evidence means the snapshot shrank between the draw and the
    /// click. The account re-reads that same snapshot on the next pass and says so itself.
    func generateTimeline() {
        // Read once, here: what the person picks while this run works belongs to the next
        // reading, so the run carries a copy rather than the live field.
        let options = readingOptions
        guard case .success(let digest) =
            AgentTimelineDigest.build(from: snapshot, span: options.span)
        else { return }

        timelineTask?.cancel()
        let run = timelineLedger.begin()
        let factCount = snapshot.factCount
        readingOptionsInUse = options
        timelineGeneration = .running(fingerprint: digest.fingerprint, progress: .launching)
        // Whether this result may be shown is the ledger's answer and only the ledger's.
        // `Task.isCancelled` looks like a second guard and is a weaker one: a synthesizer that
        // has already returned settles before cancellation propagates, so the window it leaves
        // open is exactly the race this is here to close. One rule, one place.
        let announce = progressAnnouncer(run: run)
        timelineTask = Task { [weak self, resolveTimelineSynthesizer] in
            let outcome = await Self.read(
                digest,
                options: options,
                using: resolveTimelineSynthesizer,
                progress: announce
            )
            self?.land(outcome, run: run, factCount: factCount)
        }
    }

    /// The channel a run in flight uses to say what it is doing. Built here, on the pane, so the
    /// synthesizer never learns what an actor hop or a view model is.
    private func progressAnnouncer(run: Int) -> @Sendable (AgentTimelineProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in self?.note(progress, run: run) }
        }
    }

    /// Shows what the run in flight is doing.
    ///
    /// Guarded by the ledger for the same reason a result is: progress from a superseded run
    /// would otherwise narrate work whose answer can never be shown.
    private func note(_ progress: AgentTimelineProgress, run: Int) {
        guard run == timelineLedger.currentRun,
              case .running(let fingerprint, let current) = timelineGeneration,
              current != progress
        else { return }
        timelineGeneration = .running(fingerprint: fingerprint, progress: progress)
    }

    /// Stops the run in flight. The ledger advances past it in the same breath, so the work
    /// already started cannot land afterwards on top of whatever the person does next.
    func cancelTimelineGeneration() {
        guard timelineLedger.isRunning else { return }
        timelineTask?.cancel()
        timelineTask = nil
        timelineLedger.cancel()
        timelineGeneration = .failed(.cancelled)
    }

    private static func read(
        _ digest: AgentTimelineDigest,
        options: AgentReadingOptions,
        using resolve: AgentTimelineSynthesizerResolver,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async -> Result<AgentSessionTimeline, AgentTimelineFailure> {
        guard let synthesizer = await resolve(options) else { return .failure(.noSynthesizer) }
        do {
            let raw = try await synthesizer.synthesize(digest, options: options, progress: progress)
            return AgentTimelineDraftDecoder.decode(raw).flatMap { draft in
                AgentTimelineValidation
                    .validate(draft, against: digest, generatedAt: Date())
                    .mapError(AgentTimelineFailure.rejected)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(
                (error as? AgentTimelineFailure) ?? .runFailed(error.localizedDescription)
            )
        }
    }

    private func land(
        _ outcome: Result<AgentSessionTimeline, AgentTimelineFailure>,
        run: Int,
        factCount: Int
    ) {
        guard timelineLedger.settle(run: run) else { return }
        timelineTask = nil
        switch outcome {
        case .success(let timeline):
            readingFactCount = factCount
            timelineGeneration = .ready(timeline)
        case .failure(let failure):
            timelineGeneration = .failed(failure)
        }
    }

    /// A reading belongs to the session it was made from. Attaching to a different one, or
    /// losing the pane, drops it rather than leaving last session's milestones on screen.
    private func discardTimeline() {
        timelineTask?.cancel()
        timelineTask = nil
        if timelineLedger.isRunning { timelineLedger.cancel() }
        readingFactCount = nil
        readingOptionsInUse = nil
        timelineGeneration = .idle
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let inputQueue, let coordinator else { return }
        isSending = true
        do {
            try await inputQueue.send(text)
            draft = ""
            let evidence = AgentEvidence(
                source: .terminalInput,
                authority: .observed,
                location: "terminal-slot:\(slotID.uuidString)",
                byteOffset: nil,
                fingerprint: "",
                capturedAt: Date(),
                freshness: .current
            )
            let message = AgentLensMessage(
                id: "pending-\(UUID().uuidString)",
                role: .user,
                text: text,
                isStreaming: false,
                evidence: evidence
            )
            await coordinator.apply(.userMessage(message), publish: publisher)
        } catch {
            let evidence = AgentEvidence.terminalInference("terminal-slot:\(slotID.uuidString)")
            let diagnostic = AgentLensDiagnostic(
                id: "send-failed-\(UUID().uuidString)",
                severity: .error,
                message: (error as? AgentLensInputError) == .foregroundProcessChanged
                    ? "Agent is no longer the foreground process; input was not sent"
                    : "Input was cancelled before it reached the agent",
                evidence: evidence
            )
            await coordinator.apply(.diagnostic(diagnostic), publish: publisher)
        }
        isSending = false
    }

    /// A lifecycle hook fired inside this pane's own PTY. Claude Code writes its transcript
    /// at turn boundaries, so this is the only account of a tool that is still running or a
    /// question that is still waiting — the moment supervision is actually for.
    func ingest(_ event: AgentHookEvent) {
        guard event.paneID == slotID,
              let coordinator,
              let identity = terminalPool?.agentTerminalIdentity(for: slotID),
              // A reused pane holds a new surface token, so a hook from the PTY that has
              // already been replaced cannot describe the session shown here.
              identity.surfaceToken == event.surfaceToken,
              // What the hook says about itself is checked against the live process, the same
              // way a reported transcript binding is.
              AgentHookAdmission.admits(event, resolution: resolution)
        else { return }

        var events = AgentHookLensProjection.events(for: event, at: Date())
        guard !events.isEmpty else { return }
        if !didAnnounceHookCapabilities {
            didAnnounceHookCapabilities = true
            events.insert(
                .capabilitiesGained(
                    [.toolLifecycle, .questions, .approvals],
                    evidence: .terminalInference("agent-hook:\(event.hookEventName)")
                ),
                at: 0
            )
        }
        Task { [weak self] in
            guard let self else { return }
            for event in events {
                await coordinator.apply(event, publish: self.publisher)
            }
        }
    }

    /// The option a person picked, sent in the alphabet the agent's own prompt reads.
    ///
    /// Both providers render numbered choices, but Claude moves the highlight with the digit
    /// and needs Return to accept it while Codex commits the digit immediately. Only the
    /// decision the agent is showing right now can be answered: an earlier question in the
    /// same call is no longer on screen, and a digit sent for it would land on whatever the
    /// agent is asking instead.
    func answer(
        _ request: AgentInteractionRequest,
        with option: AgentInteractionOption
    ) async -> Bool {
        guard let inputQueue,
              let provider = snapshot.provider,
              snapshot.pendingInteraction?.id == request.id,
              let choice = request.options.firstIndex(where: { $0.id == option.id }),
              choice < 9
        else { return false }
        if optionSubmissionGate.requestID == request.id { return true }
        guard optionSubmissionGate.begin(
            requestID: request.id,
            pendingRequestID: snapshot.pendingInteraction?.id
        ) else { return false }
        isSending = true
        defer { isSending = false }
        do {
            try await inputQueue.submitOption(
                String(choice + 1),
                using: provider.optionSubmission
            )
            return true
        } catch {
            optionSubmissionGate.fail(requestID: request.id)
            await reportInputFailure(error)
            return false
        }
    }

    /// Says that input never reached the agent. The diagnostic carries a warning into the
    /// pane's chrome header and the text stays in the composer; whether that is worth switching
    /// to the raw terminal is the reader's call.
    private func reportInputFailure(_ error: any Error) async {
        guard let coordinator else { return }
        let diagnostic = AgentLensDiagnostic(
            id: "send-failed-\(UUID().uuidString)",
            severity: .error,
            message: (error as? AgentLensInputError) == .foregroundProcessChanged
                ? "Agent is no longer the foreground process; input was not sent"
                : "Input was cancelled before it reached the agent",
            evidence: .terminalInference("terminal-slot:\(slotID.uuidString)")
        )
        await coordinator.apply(.diagnostic(diagnostic), publish: publisher)
    }

    private var publisher: AgentLensSessionCoordinator.Publisher {
        { @MainActor [weak self] snapshot in self?.receive(snapshot) }
    }

    /// The one place a published snapshot lands on the pane.
    ///
    /// Named rather than left as a closure body so there is exactly one entry: the coordinator
    /// uses it in the app, and the headless suite drives the pane through the same door instead
    /// of needing a second write path to `snapshot` that only tests would ever take.
    func receive(_ next: AgentLensSnapshot) {
        optionSubmissionGate.reconcile(pendingRequestID: next.pendingInteraction?.id)
        guard snapshot != next else { return }
        timelineItems = next.sessionTimelineItems
        snapshot = next
        DiagnosticsRuntimeSignals.shared.noteAgentLensSnapshot(
            paneOrdinal: diagnosticsPaneOrdinal,
            account: account,
            mode: mode,
            split: showsSplitView,
            status: next.status,
            revision: next.renderRevision,
            messageCount: next.messages.count,
            toolCount: next.tools.count,
            interactionCount: next.interactions.count,
            diagnosticCount: next.diagnostics.count,
            timelineItemCount: timelineItems.count
        )
    }

    private func discoveryLoop() async {
        while !Task.isCancelled {
            guard let identity = terminalPool?.agentTerminalIdentity(for: slotID) else {
                await handleDiscoveryMiss()
                if await sleepForDiscovery() { break }
                continue
            }
            // Keep polling even after an exact attachment: `/new` can replace the root
            // Codex session without changing the foreground process group.
            let next = await discovery.resolve(identity)
            guard !Task.isCancelled else { break }
            if let next {
                consecutiveMisses = 0
                if next != resolution { await attach(next) }
            } else {
                await handleDiscoveryMiss()
            }
            if await sleepForDiscovery() { break }
        }
    }

    private func sleepForDiscovery() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(750))
            return false
        } catch {
            return true
        }
    }

    private func handleDiscoveryMiss() async {
        guard resolution != nil else {
            if snapshot.provider == nil { snapshot.status = .unavailable }
            return
        }
        consecutiveMisses += 1
        guard consecutiveMisses >= 2, let coordinator else { return }
        resolution = nil
        await coordinator.apply(
            .status(
                .completed,
                evidence: .terminalInference("terminal-slot:\(slotID.uuidString):foreground-ended")
            ),
            publish: publisher
        )
    }

    private func attach(_ next: AgentLensResolution) async {
        streamTask?.cancel()
        if let coordinator { await coordinator.stop() }
        if let inputQueue { await inputQueue.stop() }
        optionSubmissionGate.reconcile(pendingRequestID: nil)
        discardTimeline()

        resolution = next
        let coordinator = AgentLensSessionCoordinator()
        self.coordinator = coordinator
        // A recorded session has no PTY to write to, so it gets no input queue — the pane
        // that cannot send is the pane that holds no transport, rather than one that holds a
        // transport and remembers not to use it.
        if attachment.allowsSending {
            guard let terminalPool else { return }
            let expectedPID = next.foregroundPID
            inputQueue = AgentLensInputQueue(
                transport: AgentLensInputTransport { @MainActor [weak terminalPool] frame in
                    terminalPool?.sendAgentInputFrame(
                        frame,
                        to: self.slotID,
                        expectedForegroundPID: expectedPID
                    ) ?? false
                }
            )
        }

        let connectionEvidence = AgentEvidence.terminalInference(
            next.transcriptURL?.path ?? "terminal-process:\(next.foregroundPID)"
        )
        var seed: [AgentLensEvent] = [
            .connected(
                provider: next.provider,
                capabilities: next.capabilities,
                transcriptPath: next.transcriptURL?.path,
                evidence: connectionEvidence
            ),
        ]
        if next.confidence == .inferred {
            seed.append(
                .diagnostic(
                    AgentLensDiagnostic(
                        id: "inferred-transcript",
                        severity: .warning,
                        message: "Transcript identity is inferred from this directory; evidence remains inspectable",
                        evidence: connectionEvidence
                    )
                )
            )
        }

        guard let transcriptURL = next.transcriptURL else {
            seed.append(
                .diagnostic(
                    AgentLensDiagnostic(
                        id: "transcript-unavailable",
                        severity: .warning,
                        message: next.detail,
                        evidence: connectionEvidence
                    )
                )
            )
            for event in seed { await coordinator.apply(event, publish: publisher) }
            return
        }

        let tailer = AgentTranscriptTailer()
        let stream = await tailer.events(fileURL: transcriptURL, provider: next.provider)
        streamTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.consume(stream, seed: seed, publish: self.publisher)
        }
    }
}

/// Where a provider lifecycle hook reaches the pane it came from.
///
/// The hook server is host-private and knows only a pane id; the lens pool knows which
/// model owns that pane. Keeping the seam here means the composition root wires one line
/// and neither side learns the other's internals.
@MainActor
enum AgentHookLensBus {
    private(set) static weak var pool: AgentLensPool?

    static func attach(_ pool: AgentLensPool) {
        self.pool = pool
    }

    static func deliver(_ event: AgentHookEvent) {
        pool?.ingest(event)
    }
}

@MainActor
final class AgentLensPool {
    private let discovery: AgentLensDiscovery
    private let questions: AgentAskStore
    private let resolveTimelineSynthesizer: AgentTimelineSynthesizerResolver
    private var models: [UUID: AgentLensViewModel] = [:]

    init(
        discovery: AgentLensDiscovery = AgentLensDiscovery(),
        questions: AgentAskStore = AgentAskStore(),
        resolveTimelineSynthesizer: @escaping AgentTimelineSynthesizerResolver =
            AgentLensViewModel.installedTimelineSynthesizer
    ) {
        self.discovery = discovery
        self.questions = questions
        self.resolveTimelineSynthesizer = resolveTimelineSynthesizer
        AgentHookLensBus.attach(self)
    }

    func ingest(_ event: AgentHookEvent) {
        models[event.paneID]?.ingest(event)
    }

    func model(for slotID: UUID, terminalPool: SurfacePool) -> AgentLensViewModel {
        if let existing = models[slotID] { return existing }
        let model = AgentLensViewModel(
            slotID: slotID,
            terminalPool: terminalPool,
            discovery: discovery,
            questions: questions,
            resolveTimelineSynthesizer: resolveTimelineSynthesizer
        )
        models[slotID] = model
        return model
    }

    /// The model for a pane reading a session that already happened.
    ///
    /// Keyed by slot like every other model, but ALSO checked against the session it holds: one
    /// recorded pane takes the next recorded session (`SlotContent.yieldsPane`), so the same
    /// slot legitimately reads a different transcript over its life. Handing back the previous
    /// session's model would leave the pane reading the session the person just navigated away
    /// from, which is the one failure this lookup exists to prevent.
    func model(for slotID: UUID, recording ref: AgentSessionRef) -> AgentLensViewModel {
        if let existing = models[slotID],
           existing.attachment == .recorded(ref) {
            return existing
        }
        models[slotID]?.stop()
        let model = AgentLensViewModel(
            slotID: slotID,
            terminalPool: nil,
            discovery: discovery,
            attachment: .recorded(ref),
            questions: questions,
            resolveTimelineSynthesizer: resolveTimelineSynthesizer
        )
        models[slotID] = model
        return model
    }

    func retainOnly(_ slotIDs: Set<UUID>) {
        for key in models.keys where !slotIDs.contains(key) {
            models[key]?.stop()
            models.removeValue(forKey: key)
            Task { await questions.closePane(key) }
        }
    }
}
