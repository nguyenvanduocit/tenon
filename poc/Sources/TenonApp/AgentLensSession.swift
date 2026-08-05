import Foundation
import Observation

enum AgentLensInputError: Error, Equatable, Sendable {
    case empty
    case foregroundProcessChanged
    case cancelled
}

struct AgentLensInputTransport: Sendable {
    let sendFrame: @MainActor @Sendable (String) -> Bool
}

/// FIFO input owns the caller continuations and the only draining task. `draining` stays
/// true across the inter-frame suspension, so actor reentrancy can append but can never
/// interleave two bracketed-paste transactions.
actor AgentLensInputQueue {
    private struct Request {
        let text: String
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
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Void, AgentLensInputError>, Never>) in
            guard !stopped else {
                continuation.resume(returning: .failure(.cancelled))
                return
            }
            requests.append(Request(text: text, continuation: continuation))
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
            let safeText = request.text.replacingOccurrences(
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
    private(set) var resolution: AgentLensResolution?
    private(set) var isSending = false
    var mode: AgentLensMode = .terminal
    var draft = ""

    @ObservationIgnored private weak var terminalPool: SurfacePool?
    @ObservationIgnored private let discovery: AgentLensDiscovery
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var coordinator: AgentLensSessionCoordinator?
    @ObservationIgnored private var inputQueue: AgentLensInputQueue?
    @ObservationIgnored private var didAutoSwitch = false
    @ObservationIgnored private var consecutiveMisses = 0

    init(slotID: UUID, terminalPool: SurfacePool, discovery: AgentLensDiscovery) {
        self.slotID = slotID
        self.terminalPool = terminalPool
        self.discovery = discovery
    }

    var isAgentDetected: Bool { resolution != nil || snapshot.provider != nil }

    var canSend: Bool {
        resolution != nil && snapshot.canSend && !isSending &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        guard discoveryTask == nil else { return }
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
        if let coordinator { Task { await coordinator.stop() } }
        if let inputQueue { Task { await inputQueue.stop() } }
        coordinator = nil
        inputQueue = nil
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
            mode = .terminal
        }
        isSending = false
    }

    private var publisher: AgentLensSessionCoordinator.Publisher {
        { @MainActor [weak self] snapshot in
            guard let self else { return }
            if self.snapshot != snapshot { self.snapshot = snapshot }
        }
    }

    private func discoveryLoop() async {
        while !Task.isCancelled {
            guard let identity = terminalPool?.agentTerminalIdentity(for: slotID) else {
                await handleDiscoveryMiss()
                if await sleepForDiscovery() { break }
                continue
            }
            if resolution?.foregroundPID == identity.foregroundPID,
               resolution?.transcriptURL != nil,
               resolution?.confidence == .exact
            {
                consecutiveMisses = 0
                if await sleepForDiscovery() { break }
                continue
            }

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

        resolution = next
        let coordinator = AgentLensSessionCoordinator()
        self.coordinator = coordinator
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

        if !didAutoSwitch {
            didAutoSwitch = true
            mode = .conversation
        }
        let tailer = AgentTranscriptTailer()
        let stream = await tailer.events(fileURL: transcriptURL, provider: next.provider)
        streamTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.consume(stream, seed: seed, publish: self.publisher)
        }
    }
}

@MainActor
final class AgentLensPool {
    private let discovery: AgentLensDiscovery
    private var models: [UUID: AgentLensViewModel] = [:]

    init(discovery: AgentLensDiscovery = AgentLensDiscovery()) {
        self.discovery = discovery
    }

    func model(for slotID: UUID, terminalPool: SurfacePool) -> AgentLensViewModel {
        if let existing = models[slotID] { return existing }
        let model = AgentLensViewModel(
            slotID: slotID,
            terminalPool: terminalPool,
            discovery: discovery
        )
        models[slotID] = model
        return model
    }

    func retainOnly(_ slotIDs: Set<UUID>) {
        for key in models.keys where !slotIDs.contains(key) {
            models[key]?.stop()
            models.removeValue(forKey: key)
        }
    }
}
