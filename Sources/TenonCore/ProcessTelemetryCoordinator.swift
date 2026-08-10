// @domain: process-telemetry
import Foundation

// MARK: - Injected seams  @domain: process-telemetry

/// Reads the machine. The one call that touches Darwin, kept behind a protocol so every rule
/// above it is assertable without a process tree.
public protocol ProcessSampling: Sendable {
    func sample(panes: [PaneProvenance]) async throws -> ProcessSampleSet
}

/// Monotonic time for intervals, wall time for showing a person. They are separate because a
/// clock adjustment must not be able to turn a CPU delta negative.
public protocol TelemetryClock: Sendable {
    var nowNanoseconds: UInt64 { get }
    var now: Date { get }
}

/// Waits between samples. Injected so "every two seconds" and "backs off to thirty" are
/// facts a test states in microseconds rather than waits out in real time.
public protocol TelemetryTicker: Sendable {
    func wait(nanoseconds: UInt64) async throws
}

/// Who owns which pane, as the MainActor saw it. The revision is the whole point: a sample
/// that started before a pane moved describes a hierarchy that no longer exists, and
/// publishing it would attribute a process to the wrong workspace for one frame.
public struct ProvenanceSnapshot: Equatable, Sendable {
    public let revision: Int
    public let panes: [PaneProvenance]
    public let labels: TelemetryLabels

    public init(revision: Int, panes: [PaneProvenance], labels: TelemetryLabels) {
        self.revision = revision
        self.panes = panes
        self.labels = labels
    }

    public static let none = ProvenanceSnapshot(revision: 0, panes: [], labels: .none)
}

// MARK: - Coordinator  @domain: process-telemetry

/// Owns everything about *when* a sample happens and *whether its result may be published*.
///
/// It is an actor because the two rules that matter most are about concurrency: at most one
/// sample is in flight, and a result that outlived its lifecycle or its provenance is
/// discarded rather than shown. Both are trivially true inside one serial executor and
/// fiddly outside one.
public actor ProcessTelemetryCoordinator {
    /// Two seconds, matching the cadence a person reads a task manager at.
    public static let refreshInterval: UInt64 = 2 * 1_000_000_000
    /// What a run of failures waits, in seconds, before trying again while still visible.
    public static let backoffSeconds: [UInt64] = [2, 4, 8, 16, 30]
    /// One snapshot never describes more identities than this.
    public static let processCapacity = 4096

    private let sampler: ProcessSampling
    private let clock: TelemetryClock
    private let ticker: TelemetryTicker
    private let physicalMemory: UInt64
    private let provenance: @Sendable () async -> ProvenanceSnapshot

    private var visibleSurfaces = 0
    /// Bumped by every start and stop. A result carrying an older one is from a session
    /// nobody is watching any more.
    private var generation = 0
    private var previousCounters: [ProcessIdentity: ProcessCounters] = [:]
    private var consecutiveFailures = 0
    private var isSampling = false
    private var pendingRefresh = false
    private var loop: Task<Void, Never>?

    public private(set) var latest: TelemetrySnapshot?
    public private(set) var history = TelemetryHistory()
    /// Every snapshot this coordinator has published, newest last — the seam the shell binds
    /// to. Held as a continuation list so a test can await publications deterministically.
    private var observers: [UUID: @Sendable (TelemetrySnapshot) -> Void] = [:]

    public init(
        sampler: ProcessSampling,
        clock: TelemetryClock,
        ticker: TelemetryTicker,
        physicalMemory: UInt64,
        provenance: @escaping @Sendable () async -> ProvenanceSnapshot
    ) {
        self.sampler = sampler
        self.clock = clock
        self.ticker = ticker
        self.physicalMemory = physicalMemory
        self.provenance = provenance
    }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (TelemetrySnapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    // MARK: - Visibility  @domain: process-telemetry

    /// A monitor surface appeared. The first one starts periodic sampling and takes an
    /// immediate reading, because a person who just opened the popover is asking about now.
    public func surfaceAppeared() {
        visibleSurfaces += 1
        guard visibleSurfaces == 1 else { return }
        generation += 1
        consecutiveFailures = 0
        startLoop()
    }

    /// A monitor surface went away. When the last one does, periodic demand ends and the
    /// retained snapshot is restated as paused — real numbers, honestly labelled old, rather
    /// than a value that keeps looking current while nothing refreshes it.
    public func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        guard visibleSurfaces == 0 else { return }
        generation += 1
        loop?.cancel()
        loop = nil
        if let snapshot = latest, snapshot.state.isUsable {
            publish(snapshot.paused())
        }
    }

    public var isVisible: Bool { visibleSurfaces > 0 }

    /// Cancel everything and wait for quiescence — app shutdown's obligation.
    public func shutDown() async {
        visibleSurfaces = 0
        generation += 1
        loop?.cancel()
        let running = loop
        loop = nil
        await running?.value
    }

    // MARK: - Sampling  @domain: process-telemetry

    private func startLoop() {
        loop?.cancel()
        let myGeneration = generation
        loop = Task { [weak self] in
            guard let self else { return }
            while await self.shouldContinue(generation: myGeneration) {
                await self.sampleOnce(generation: myGeneration)
                let delay = await self.nextDelay()
                do {
                    try await self.tickerWait(delay)
                } catch {
                    return
                }
            }
        }
    }

    private func shouldContinue(generation candidate: Int) -> Bool {
        candidate == generation && visibleSurfaces > 0 && !Task.isCancelled
    }

    private func tickerWait(_ nanoseconds: UInt64) async throws {
        try await ticker.wait(nanoseconds: nanoseconds)
    }

    private func nextDelay() -> UInt64 {
        guard consecutiveFailures > 0 else { return Self.refreshInterval }
        let index = min(consecutiveFailures - 1, Self.backoffSeconds.count - 1)
        return Self.backoffSeconds[index] * 1_000_000_000
    }

    /// Ask for a reading right now.
    ///
    /// If one is already in flight this records a single pending refresh and returns. Ten
    /// requests during one slow sample therefore produce that sample and exactly one
    /// follow-up — the coalescing is a boolean, so there is no queue to grow.
    public func refreshNow() async {
        if isSampling {
            pendingRefresh = true
            return
        }
        await sampleOnce(generation: generation)
    }

    /// A person pressed Retry. It skips the remaining backoff without starting a second
    /// concurrent sample.
    public func retry() async {
        consecutiveFailures = 0
        await refreshNow()
    }

    private func sampleOnce(generation candidate: Int) async {
        guard !isSampling else {
            pendingRefresh = true
            return
        }
        isSampling = true
        defer { isSampling = false }

        let captured = await provenance()
        let startedAt = clock.nowNanoseconds

        do {
            let raw = try await sampler.sample(panes: captured.panes)

            // Two independent reasons a finished sample may not be published. Lifecycle:
            // nobody is watching this session any more. Provenance: the hierarchy it was
            // captured against has changed, so its ownership claims are about a layout that
            // no longer exists.
            guard candidate == generation else { return }
            let current = await provenance()
            guard current.revision == captured.revision else {
                // Ownership moved under us. Discard and take exactly one replacement, rather
                // than publishing a pane→process mapping that is already wrong.
                pendingRefresh = true
                await drainPendingRefresh(generation: candidate)
                return
            }

            let bounded = bound(raw)
            let now = clock.nowNanoseconds
            let snapshot = TelemetryProjection.project(
                panes: captured.panes,
                samples: bounded,
                previousCounters: previousCounters,
                labels: captured.labels,
                physicalMemory: physicalMemory,
                capturedAtNanoseconds: now,
                capturedAt: clock.now,
                generation: candidate,
                provenanceRevision: captured.revision
            )
            previousCounters = TelemetryProjection.counters(from: bounded, capturedAtNanoseconds: now)
            consecutiveFailures = 0
            history.record(snapshot)
            publish(snapshot)
        } catch {
            guard candidate == generation else { return }
            consecutiveFailures += 1
            let reason = String(describing: error)
            // A collector failure is never an empty machine. With a previous reading it
            // becomes stale; without one it is a terminal error with a Retry, and in neither
            // case does the tree quietly empty out.
            if let previous = latest, previous.state.isUsable {
                publish(previous.staled(reason: reason))
            } else {
                publish(failure(reason: reason, startedAt: startedAt, provenance: captured))
            }
        }

        await drainPendingRefresh(generation: candidate)
    }

    private func drainPendingRefresh(generation candidate: Int) async {
        guard pendingRefresh, candidate == generation else { return }
        pendingRefresh = false
        isSampling = false
        await sampleOnce(generation: candidate)
    }

    /// Cap the identity count so one runaway `make -j` cannot make a snapshot unbounded.
    /// Truncation is reported, never silent: a partial state says the list is not the whole
    /// story, which is the difference between a bound and a lie.
    private func bound(_ set: ProcessSampleSet) -> ProcessSampleSet {
        guard set.processes.count > Self.processCapacity else { return set }
        let kept = set.processes
            .sorted { $0.identity < $1.identity }
            .prefix(Self.processCapacity)
        return ProcessSampleSet(
            hostRecord: set.hostRecord,
            processes: Array(kept),
            truncated: true,
            unreadableCount: set.unreadableCount
        )
    }

    private func failure(reason: String, startedAt: UInt64, provenance: ProvenanceSnapshot) -> TelemetrySnapshot {
        TelemetrySnapshot(
            root: [],
            state: .failed(reason: reason),
            totalCPUPercent: .unavailable(.unreadable),
            totalFootprintBytes: .unavailable(.unreadable),
            physicalMemoryShare: .unavailable(.unreadable),
            paneCount: provenance.panes.count,
            processCount: 0,
            capturedAtNanoseconds: startedAt,
            capturedAt: clock.now,
            generation: generation,
            provenanceRevision: provenance.revision
        )
    }

    private func publish(_ snapshot: TelemetrySnapshot) {
        latest = snapshot
        for handler in observers.values { handler(snapshot) }
    }
}

// MARK: - Production seams  @domain: process-telemetry

public struct SystemTelemetryClock: TelemetryClock {
    public init() {}
    public var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
    public var now: Date { Date() }
}

public struct TaskSleepTicker: TelemetryTicker {
    public init() {}
    public func wait(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
