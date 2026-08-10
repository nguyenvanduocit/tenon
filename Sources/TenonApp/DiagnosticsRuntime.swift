// @domain: diagnostics

import Darwin
import Foundation
import TenonCore

struct DiagnosticsRunIdentity: Equatable, Sendable {
    let runID: String
    let pid: Int32
    let version: String
    let build: String
    let channel: String

    static func current(channel: String) -> Self {
        func bundleString(_ key: String) -> String {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "unavailable" }
            return value
        }
        return Self(
            runID: UUID().uuidString.lowercased(),
            pid: ProcessInfo.processInfo.processIdentifier,
            version: bundleString("CFBundleShortVersionString"),
            build: bundleString("CFBundleVersion"),
            channel: channel
        )
    }

    var figures: [String: String] {
        [
            "schema": "2",
            "runID": runID,
            "pid": "\(pid)",
            "version": version,
            "build": build,
            "channel": channel,
        ]
    }
}

enum DiagnosticsSampleResult: Equatable, Sendable {
    case finished(exitStatus: Int32)
    case launchFailed
    case timedOut
}

struct DiagnosticsTransition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case agentLensSnapshot = "agent-lens-snapshot"
        case agentLensScrollAdmitted = "agent-lens-scroll-admitted"
        case agentLensScrollCoalesced = "agent-lens-scroll-coalesced"
        case agentLensScrollExecuted = "agent-lens-scroll-executed"
        case watchdogProbe = "watchdog-probe"
    }

    let uptimeMS: UInt64
    let kind: Kind
    var paneOrdinal: Int? = nil
    var account: String? = nil
    var mode: String? = nil
    var split: Bool? = nil
    var status: String? = nil
    var revision: Int? = nil
    var messageCount: Int? = nil
    var toolCount: Int? = nil
    var interactionCount: Int? = nil
    var diagnosticCount: Int? = nil
    var timelineItemCount: Int? = nil
    var pinned: Bool? = nil
    var cpuCorePercent: Double? = nil
    var footprintMB: UInt64? = nil
    var beatAgeMS: UInt64? = nil
    var mainQueueAckAgeMS: UInt64? = nil
    var runloopPhase: String? = nil

    init(uptimeMS: UInt64, kind: Kind) {
        self.uptimeMS = uptimeMS
        self.kind = kind
    }
}

/// A privacy-closed ring of typed state transitions immediately preceding a stall.
///
/// Callers can submit only the fields below; there is no generic breadcrumb API through which
/// terminal text, paths, commands, session identifiers, or pane identifiers could leak.
final class DiagnosticsRuntimeSignals: @unchecked Sendable {
    static let shared = DiagnosticsRuntimeSignals()

    private let lock = NSLock()
    private let capacity: Int
    private let now: @Sendable () -> TimeInterval
    private var transitions: [DiagnosticsTransition?]
    private var nextTransitionIndex = 0
    private var transitionCount = 0
    private var nextPaneOrdinal = 1

    init(
        capacity: Int = 128,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.capacity = max(1, capacity)
        self.now = now
        self.transitions = Array(repeating: nil, count: max(1, capacity))
    }

    func registerAgentLensPane() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let ordinal = nextPaneOrdinal
        nextPaneOrdinal += 1
        return ordinal
    }

    func noteAgentLensSnapshot(
        paneOrdinal: Int,
        account: AgentLensAccount,
        mode: AgentLensMode,
        split: Bool,
        status: AgentLensStatus,
        revision: Int,
        messageCount: Int,
        toolCount: Int,
        interactionCount: Int,
        diagnosticCount: Int,
        timelineItemCount: Int
    ) {
        var transition = makeTransition(kind: .agentLensSnapshot)
        transition.paneOrdinal = paneOrdinal
        transition.account = account.rawValue
        transition.mode = mode.rawValue
        transition.split = split
        transition.status = Self.agentLensStatusName(status)
        transition.revision = revision
        transition.messageCount = messageCount
        transition.toolCount = toolCount
        transition.interactionCount = interactionCount
        transition.diagnosticCount = diagnosticCount
        transition.timelineItemCount = timelineItemCount
        append(transition)
    }

    func noteAgentLensScroll(
        paneOrdinal: Int,
        admitted: Bool,
        pinned: Bool
    ) {
        var transition = makeTransition(
            kind: admitted ? .agentLensScrollAdmitted : .agentLensScrollCoalesced
        )
        transition.paneOrdinal = paneOrdinal
        transition.pinned = pinned
        append(transition)
    }

    func noteAgentLensScrollExecuted(paneOrdinal: Int) {
        var transition = makeTransition(kind: .agentLensScrollExecuted)
        transition.paneOrdinal = paneOrdinal
        append(transition)
    }

    func noteWatchdogProbe(
        cpuCorePercent: Double?,
        footprintBytes: UInt64?,
        beatAge: TimeInterval,
        mainQueueAckAge: TimeInterval?,
        runloopPhase: String
    ) {
        var transition = makeTransition(kind: .watchdogProbe)
        transition.cpuCorePercent = cpuCorePercent
        transition.footprintMB = footprintBytes.map { $0 / 1_048_576 }
        transition.beatAgeMS = Self.milliseconds(beatAge)
        transition.mainQueueAckAgeMS = mainQueueAckAge.map(Self.milliseconds)
        transition.runloopPhase = runloopPhase
        append(transition)
    }

    func snapshot() -> [DiagnosticsTransition] {
        lock.lock()
        defer { lock.unlock() }
        guard transitionCount > 0 else { return [] }
        let start = transitionCount == capacity ? nextTransitionIndex : 0
        return (0..<transitionCount).compactMap { offset in
            transitions[(start + offset) % capacity]
        }
    }

    private func makeTransition(kind: DiagnosticsTransition.Kind) -> DiagnosticsTransition {
        DiagnosticsTransition(uptimeMS: UInt64(max(now(), 0) * 1_000), kind: kind)
    }

    private func append(_ transition: DiagnosticsTransition) {
        lock.lock()
        transitions[nextTransitionIndex] = transition
        nextTransitionIndex = (nextTransitionIndex + 1) % capacity
        transitionCount = min(transitionCount + 1, capacity)
        lock.unlock()
    }

    private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000)
    }

    private static func agentLensStatusName(_ status: AgentLensStatus) -> String {
        switch status {
        case .detecting: "detecting"
        case .unavailable: "unavailable"
        case .ready: "ready"
        case .running: "running"
        case .waitingForUser: "waiting-for-user"
        case .completed: "completed"
        case .failed: "failed"
        case .degraded: "degraded"
        }
    }
}

/// Watches the main runloop from outside it, and writes down what it sees.
///
/// The arrangement that matters: the **beat** is a `CFRunLoopObserver` on the main runloop,
/// and the **probe** is a timer on a private queue. A probe scheduled on the main queue would
/// be wedged by exactly the condition it exists to detect — during the T-091 hang the main
/// thread never returned from one observer call, so anything queued behind it waited two
/// hours with it. The watchdog has to live somewhere the stall cannot reach.
///
/// The judgement itself is `RunloopHealth`, which is pure and tested without a window. This
/// type owns only the clock, the threads, and the writing down.
final class DiagnosticsRuntime: @unchecked Sendable {
    private final class IncidentReceiptState: @unchecked Sendable {
        private let lock = NSLock()
        private var durableOnset = false
        private var durablePrelude = false

        func markPrelude(onsetDurable: Bool, captureDurable: Bool) {
            lock.lock()
            durableOnset = onsetDurable
            durablePrelude = captureDurable
            lock.unlock()
        }

        var canPersistIncidentRecords: Bool {
            lock.lock()
            defer { lock.unlock() }
            return durableOnset
        }

        var canPersistCaptureReceipts: Bool {
            lock.lock()
            defer { lock.unlock() }
            return durablePrelude
        }
    }

    private struct MeasurementSnapshot: Sendable {
        let at: Date
        let uptime: TimeInterval
        let footprintBytes: UInt64?
        let cpuCorePercent: Double?
        let runloopPhase: String
        let beatSequence: UInt64
        let lastBeatAt: TimeInterval
        let mainQueuePingAt: TimeInterval?
    }

    private struct Incident: Sendable {
        let id: String
        let runName: String
        let directory: URL
        let relativeSamplePath: String
        let transitions: [DiagnosticsTransition]
        let receiptState: IncidentReceiptState
    }

    private struct CapturedSample: Sendable {
        let result: DiagnosticsSampleResult
        let data: Data?
        let observedByteCount: UInt64
        let exceededLimit: Bool
    }

    /// Drains sampler stdout concurrently so the child cannot fill a pipe and wedge. Raw bytes
    /// go only to an already-unlinked inode, and only the configured prefix is ever written.
    private final class BoundedSampleDrain: @unchecked Sendable {
        private let source: FileHandle
        private let destination: Int32
        private let maximumBytes: Int
        private let completed = DispatchSemaphore(value: 0)
        private let cancellationLock = NSLock()
        private var cancellationRequested = false
        private var observedByteCount: UInt64 = 0
        private var storedByteCount = 0
        private var writeFailed = false
        private var storedData: Data?

        init?(source: FileHandle, destination: Int32, maximumBytes: Int) {
            self.source = source
            self.destination = destination
            self.maximumBytes = maximumBytes
            let flags = Darwin.fcntl(source.fileDescriptor, F_GETFL)
            guard flags >= 0,
                  Darwin.fcntl(source.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                try? source.close()
                Darwin.close(destination)
                return nil
            }
        }

        func start(on queue: DispatchQueue) {
            queue.async { [self] in
                defer {
                    try? source.close()
                    Darwin.close(destination)
                    completed.signal()
                }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while !isCancellationRequested {
                    let amount = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(source.fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if amount > 0 {
                        consume(buffer, count: amount)
                        continue
                    }
                    if amount == 0 { break }
                    if errno == EINTR { continue }
                    guard errno == EAGAIN || errno == EWOULDBLOCK else {
                        writeFailed = true
                        break
                    }
                    var readiness = pollfd(
                        fd: source.fileDescriptor,
                        events: Int16(POLLIN | POLLHUP | POLLERR),
                        revents: 0
                    )
                    let polled = Darwin.poll(&readiness, 1, 50)
                    if polled < 0, errno != EINTR {
                        writeFailed = true
                        break
                    }
                }
                if isCancellationRequested {
                    writeFailed = true
                }
                storedData = readStoredData()
            }
        }

        func finish(
            waitingForEOF timeout: TimeInterval
        ) -> (data: Data?, observedByteCount: UInt64, exceededLimit: Bool) {
            if completed.wait(timeout: .now() + max(0, timeout)) == .timedOut {
                cancellationLock.withLock { cancellationRequested = true }
                guard completed.wait(timeout: .now() + 0.5) == .success else {
                    return (nil, 0, false)
                }
            }
            return (
                storedData,
                observedByteCount,
                observedByteCount > UInt64(maximumBytes)
            )
        }

        private var isCancellationRequested: Bool {
            cancellationLock.withLock { cancellationRequested }
        }

        private func consume(_ buffer: [UInt8], count: Int) {
            let amount = UInt64(count)
            observedByteCount = UInt64.max - observedByteCount < amount
                ? UInt64.max
                : observedByteCount + amount
            let remaining = max(0, maximumBytes - storedByteCount)
            let accepted = min(remaining, count)
            guard accepted > 0, !writeFailed else { return }
            let wroteAll = buffer.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < accepted {
                    let written = Darwin.write(
                        destination,
                        base.advanced(by: offset),
                        accepted - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            if wroteAll {
                storedByteCount += accepted
            } else {
                writeFailed = true
            }
        }

        private func readStoredData() -> Data? {
            guard !writeFailed, Darwin.lseek(destination, 0, SEEK_SET) == 0 else { return nil }
            var data = Data(count: storedByteCount)
            let readAll = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return storedByteCount == 0 }
                var offset = 0
                while offset < storedByteCount {
                    let amount = Darwin.read(
                        destination,
                        base.advanced(by: offset),
                        storedByteCount - offset
                    )
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { return false }
                    offset += amount
                }
                return true
            }
            return readAll ? data : nil
        }
    }

    private let journal: DiagnosticsJournal
    private let now: @Sendable () -> TimeInterval
    private let footprintBytes: @Sendable () -> UInt64?
    private let cpuTimeSeconds: @Sendable () -> TimeInterval?
    private let identity: DiagnosticsRunIdentity
    private let signals: DiagnosticsRuntimeSignals
    private let retainedIncidentCount: Int
    private let maximumSampleBytes: Int
    private let recordQueueCapacity: Int
    private let recordFlushTimeout: TimeInterval
    private let persistRecord: @Sendable (DiagnosticsRecord) -> Bool
    /// Takes the stack sample. Injected so the capture policy can be tested without spawning
    /// anything, and so a test never samples the test runner.
    private let captureSample: @Sendable (FileHandle) -> DiagnosticsSampleResult

    private let lock = NSLock()
    private let captureReceiptLock = NSLock()
    private let captureAdmissionLock = NSLock()
    private let recordAdmissionLock = NSLock()
    private var health: RunloopHealth
    private var lastBeatAt: TimeInterval
    private var lastRunloopPhase = "startup"
    private var beatSequence: UInt64 = 0
    private var lastProbeAt: TimeInterval
    private var lastCPUTime: TimeInterval?
    private var latestCPUCorePercent: Double?
    private var latestFootprintBytes: UInt64?
    private var pendingMainQueuePingAt: TimeInterval?
    private var monitorsMainQueue = false
    private var responsivenessStallStartedAt: TimeInterval?
    private var responsivenessLastEscalationAt: TimeInterval?
    private var activeRunloopIncident: Incident?
    private var activeResponsivenessIncident: Incident?
    /// A runloop stall can recover before the old main-queue ping is accepted. Retain its
    /// identity until that ping acks so the signal handoff cannot mint a duplicate incident.
    private var recentRunloopIncidentAwaitingPing: Incident?
    private var nextIncidentOrdinal = 1
    private var hasStarted = false
    private var hasStopped = false
    private var abortQueuedCaptureReceipts = false
    private var captureReceiptsEnabled = true
    private var admittedCaptureJobs = 0
    private var admittedRecordEvents = 0
    private var loggedRecordCapacity = false

    private var observer: CFRunLoopObserver?
    private var probeTimer: DispatchSourceTimer?
    private let probeQueue = DispatchQueue(label: "dev.tenon.diagnostics.watchdog")
    /// Sampling is deliberately not on the watchdog queue. A wedged `/usr/bin/sample` must not
    /// blind escalation and recovery detection after the initial stall receipt.
    private let captureQueue = DispatchQueue(label: "dev.tenon.diagnostics.capture")
    private let captureDrainQueue = DispatchQueue(
        label: "dev.tenon.diagnostics.capture-drain",
        qos: .utility
    )
    private let recordQueue = DispatchQueue(label: "dev.tenon.diagnostics.records")

    /// How often the watchdog looks. Frequent enough that a stall is noticed while it is
    /// still worth sampling, rare enough to cost nothing.
    private let probeInterval: TimeInterval
    private let stallThreshold: TimeInterval
    private let escalationInterval: TimeInterval

    #if DEBUG
    func waitForCaptureQueueToDrainForTesting(timeout: TimeInterval = 5) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        captureQueue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }
    #endif

    init(
        journal: DiagnosticsJournal,
        threshold: TimeInterval = 5,
        escalationInterval: TimeInterval = 60,
        probeInterval: TimeInterval = 1,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        footprintBytes: @escaping @Sendable () -> UInt64? = DiagnosticsRuntime.physicalFootprint,
        cpuTimeSeconds: @escaping @Sendable () -> TimeInterval? =
            DiagnosticsRuntime.processCPUTime,
        channel: String = "unknown",
        identity: DiagnosticsRunIdentity? = nil,
        signals: DiagnosticsRuntimeSignals = .shared,
        retainedIncidentCount: Int = 8,
        maximumSampleBytes: Int = 64 * 1_048_576,
        recordQueueCapacity: Int = 64,
        recordFlushTimeout: TimeInterval = 0.25,
        persistRecord: (@Sendable (DiagnosticsRecord) -> Bool)? = nil,
        captureSample: @escaping @Sendable (FileHandle) -> DiagnosticsSampleResult =
            DiagnosticsRuntime.sampleThisProcess
    ) {
        let startedAt = now()
        self.journal = journal
        self.now = now
        self.footprintBytes = footprintBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.identity = identity ?? .current(channel: channel)
        self.signals = signals
        self.retainedIncidentCount = max(1, retainedIncidentCount)
        self.maximumSampleBytes = max(1, maximumSampleBytes)
        self.recordQueueCapacity = max(1, recordQueueCapacity)
        self.recordFlushTimeout = max(0.01, recordFlushTimeout)
        self.persistRecord = persistRecord ?? { journal.append($0) }
        self.captureSample = captureSample
        self.probeInterval = probeInterval
        self.stallThreshold = threshold
        self.escalationInterval = escalationInterval
        self.lastBeatAt = startedAt
        self.lastProbeAt = startedAt
        self.lastCPUTime = cpuTimeSeconds()
        self.health = RunloopHealth(
            threshold: threshold,
            escalationInterval: escalationInterval,
            startedAt: startedAt
        )
    }

    deinit {
        probeTimer?.cancel()
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    // MARK: - Lifetime  @domain: diagnostics

    /// Begin watching. A durable same-run `termination` positively identifies an orderly close;
    /// an unmatched run remains ambiguous between an unclean end and unavailable persistence.
    @MainActor
    func start() {
        lock.lock()
        let shouldStart = !hasStarted
        hasStarted = true
        lock.unlock()
        guard shouldStart else { return }
        // A force-killed sampler may leave a prior-run partial directory. Prune before this
        // run can enqueue its first capture; the capture queue keeps cleanup off MainActor.
        captureQueue.async { [weak self] in self?.pruneIncidentArtifacts() }
        let observerArmed = installObserver()
        recordQueue.async { [weak self] in
            _ = self?.write(
                kind: "launch",
                message: "diagnostics started",
                extraFigures: [
                    "runloopObserver": observerArmed ? "armed" : "unavailable",
                    "watchdog": "armed",
                ]
            )
        }
        startProbe()
    }

    func stop() {
        lock.lock()
        let shouldWriteTermination = hasStarted && !hasStopped
        hasStopped = true
        monitorsMainQueue = false
        lock.unlock()
        probeTimer?.cancel()
        probeTimer = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        // Completion receipts and termination share one absolute deadline. A sampler already
        // running either queues before termination or observes disabled receipts afterwards;
        // a durable termination is final without ever making quit wait on diagnostics forever.
        let receiptDeadline = Date().addingTimeInterval(recordFlushTimeout)
        guard captureReceiptLock.lock(before: receiptDeadline) else {
            lock.lock()
            abortQueuedCaptureReceipts = true
            lock.unlock()
            TenonLog.diagnostics.error("diagnostics stop skipped durable termination: receipt busy")
            return
        }
        captureReceiptsEnabled = false
        let flushed = DispatchSemaphore(value: 0)
        recordQueue.async { [weak self] in
            if shouldWriteTermination {
                _ = self?.write(kind: "termination", message: "diagnostics stopped cleanly")
            }
            flushed.signal()
        }
        let remaining = max(receiptDeadline.timeIntervalSinceNow, 0)
        let flushResult = flushed.wait(timeout: .now() + remaining)
        captureReceiptLock.unlock()
        if flushResult == .timedOut {
            TenonLog.diagnostics.error(
                "diagnostics stop did not confirm termination before its bounded deadline"
            )
        }
    }

    @MainActor
    private func installObserver() -> Bool {
        guard observer == nil else { return true }
        // Every activity counts as a beat: the claim under test is only "the runloop is still
        // turning", and any phase firing proves it.
        let activities: CFRunLoopActivity = [
            .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit,
        ]
        let created = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities.rawValue,
            true,
            // Order matters: a large value puts this observer late in the phase, so a
            // framework observer that never returns stops the beat rather than being masked
            // by ours running first. That is the T-091 shape exactly.
            .max
        ) { [weak self] _, activity in
            self?.beat(runloopPhase: Self.runloopPhase(activity))
        }
        guard let created else { return false }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
        return true
    }

    /// Start only the watchdog, without touching the main runloop. Separate from `start()`
    /// because the probe is the half that must work when the main runloop does not — a caller
    /// that wants to observe that property has to be able to run it alone.
    func startProbe() {
        guard probeTimer == nil else { return }
        lock.lock()
        monitorsMainQueue = true
        lock.unlock()
        scheduleMainQueuePingIfNeeded(at: now())
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + probeInterval, repeating: probeInterval)
        timer.setEventHandler { [weak self] in
            self?.probeOnce()
        }
        timer.resume()
        probeTimer = timer
    }

    // MARK: - The two signals  @domain: diagnostics

    /// The main runloop completed a turn.
    func beat() {
        beat(runloopPhase: "manual")
    }

    private func beat(runloopPhase: String) {
        let timestamp = now()
        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        lastBeatAt = timestamp
        lastRunloopPhase = runloopPhase
        beatSequence += 1
        let event = health.beat(at: timestamp).map {
            RuntimeEvent(
                payload: prepareRunloopEventPayloadLocked($0),
                measurement: measurementSnapshotLocked(at: timestamp)
            )
        }
        enqueueRecordsLocked(event.map { [$0] } ?? [])
        lock.unlock()
    }

    /// The watchdog looked. Exposed so a test can drive it without waiting on a timer.
    func probeOnce() {
        let timestamp = now()
        let cpuTime = cpuTimeSeconds()
        let footprint = footprintBytes()

        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        updateProcessFigures(at: timestamp, cpuTime: cpuTime, footprintBytes: footprint)
        let beatAge = max(timestamp - lastBeatAt, 0)
        let ackAge = pendingMainQueuePingAt.map { max(timestamp - $0, 0) }
        let phase = lastRunloopPhase
        let cpu = latestCPUCorePercent
        signals.noteWatchdogProbe(
            cpuCorePercent: cpu,
            footprintBytes: footprint,
            beatAge: beatAge,
            mainQueueAckAge: ackAge,
            runloopPhase: phase
        )
        let event = health.probe(at: timestamp).map {
            RuntimeEvent(
                payload: prepareRunloopEventPayloadLocked($0),
                measurement: measurementSnapshotLocked(at: timestamp)
            )
        }
        let responsivenessPayload = monitorsMainQueue
            ? responsivenessEventPayload(at: timestamp, beatAge: beatAge, ackAge: ackAge)
            : nil
        let responsivenessEvent = responsivenessPayload.map {
            RuntimeEvent(
                payload: $0,
                measurement: measurementSnapshotLocked(at: timestamp)
            )
        }
        let shouldProbeMainQueue = monitorsMainQueue
        enqueueRecordsLocked([event, responsivenessEvent].compactMap { $0 })
        lock.unlock()
        if shouldProbeMainQueue { scheduleMainQueuePingIfNeeded(at: timestamp) }
    }

    // MARK: - Writing it down  @domain: diagnostics

    private enum RuntimeEventPayload {
        case runloopStalled(TimeInterval, Incident, captureEvidence: Bool)
        case runloopStillStalled(TimeInterval, Incident?)
        case runloopRecovered(TimeInterval, Incident?)
        case responsivenessStalled(TimeInterval, Incident, captureEvidence: Bool)
        case responsivenessStillStalled(TimeInterval, Incident?)
        case responsivenessRecovered(TimeInterval, Incident)
    }

    private struct RuntimeEvent {
        let payload: RuntimeEventPayload
        let measurement: MeasurementSnapshot

        var captureIncident: Incident? {
            switch payload {
            case let .runloopStalled(_, incident, captureEvidence),
                 let .responsivenessStalled(_, incident, captureEvidence):
                captureEvidence ? incident : nil
            default:
                nil
            }
        }
    }

    private func record(_ event: RuntimeEvent, captureAdmitted: Bool?) {
        switch event.payload {
        case let .runloopStalled(duration, incident, captureEvidence):
            let onsetPersisted = write(
                kind: "stall",
                message: "main runloop stopped completing turns",
                seconds: duration,
                incidentID: incident.id,
                measurement: event.measurement
            )
            TenonLog.diagnostics.error(
                "main runloop stalled for \(duration, format: .fixed(precision: 1))s"
            )
            if captureEvidence {
                let admissionPersisted = recordCaptureAdmission(
                    captureAdmitted,
                    incident: incident,
                    onsetPersisted: onsetPersisted
                )
                incident.receiptState.markPrelude(
                    onsetDurable: onsetPersisted,
                    captureDurable: onsetPersisted && admissionPersisted
                )
            }
        case let .runloopStillStalled(duration, incident):
            guard incident?.receiptState.canPersistIncidentRecords == true else { return }
            write(
                kind: "stall-continues",
                message: "main runloop still stalled",
                seconds: duration,
                incidentID: incident?.id,
                measurement: event.measurement
            )
            TenonLog.diagnostics.error(
                "main runloop still stalled after \(duration, format: .fixed(precision: 0))s"
            )
        case let .runloopRecovered(stallDuration, incident):
            guard incident?.receiptState.canPersistIncidentRecords == true else { return }
            write(
                kind: "recovered",
                message: "main runloop resumed",
                seconds: stallDuration,
                incidentID: incident?.id,
                measurement: event.measurement
            )
            TenonLog.diagnostics.notice(
                "main runloop recovered after \(stallDuration, format: .fixed(precision: 1))s"
            )
        case let .responsivenessStalled(duration, incident, captureEvidence):
            let onsetPersisted = write(
                kind: "responsiveness-stall",
                message: "main queue stopped accepting bounded probes while the runloop still turned",
                seconds: duration,
                incidentID: incident.id,
                measurement: event.measurement
            )
            if captureEvidence {
                let admissionPersisted = recordCaptureAdmission(
                    captureAdmitted,
                    incident: incident,
                    onsetPersisted: onsetPersisted
                )
                incident.receiptState.markPrelude(
                    onsetDurable: onsetPersisted,
                    captureDurable: onsetPersisted && admissionPersisted
                )
            }
        case let .responsivenessStillStalled(duration, incident):
            guard incident?.receiptState.canPersistIncidentRecords == true else { return }
            write(
                kind: "responsiveness-stall-continues",
                message: "main queue still not accepting bounded probes",
                seconds: duration,
                incidentID: incident?.id,
                measurement: event.measurement
            )
        case let .responsivenessRecovered(duration, incident):
            guard incident.receiptState.canPersistIncidentRecords else { return }
            write(
                kind: "responsiveness-recovered",
                message: "main queue accepted a bounded probe",
                seconds: duration,
                incidentID: incident.id,
                measurement: event.measurement
            )
        }
    }

    /// Caller holds `lock`, which makes enqueue order identical to health-state order even when
    /// the watchdog and a recovering main thread cross. Neither the main thread nor watchdog
    /// waits for filesystem I/O; orderly stop drains this queue before its final receipt.
    private func enqueueRecordsLocked(_ events: [RuntimeEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            let captureIncident = event.captureIncident
            let captureAdmitted = captureIncident.map { _ in admitCaptureJob() }
            let accepted = enqueueRecordEvent { [weak self] in
                self?.record(event, captureAdmitted: captureAdmitted)
            }
            if accepted, captureAdmitted == true, let captureIncident {
                submitCaptureJob(captureIncident)
            } else if captureAdmitted == true {
                releaseCaptureAdmission()
            }
        }
    }

    /// Bounds retained work if diagnostics storage itself stops responding. The watchdog and
    /// main queue only enqueue; neither can be trapped behind persistence.
    @discardableResult
    private func enqueueRecordEvent(_ work: @escaping @Sendable () -> Void) -> Bool {
        recordAdmissionLock.lock()
        guard admittedRecordEvents < recordQueueCapacity else {
            let shouldLog = !loggedRecordCapacity
            loggedRecordCapacity = true
            recordAdmissionLock.unlock()
            if shouldLog {
                TenonLog.diagnostics.error("diagnostics record capacity reached; events dropped")
            }
            return false
        }
        admittedRecordEvents += 1
        recordAdmissionLock.unlock()
        recordQueue.async { [weak self] in
            work()
            guard let self else { return }
            self.recordAdmissionLock.lock()
            self.admittedRecordEvents -= 1
            if self.admittedRecordEvents < self.recordQueueCapacity {
                self.loggedRecordCapacity = false
            }
            self.recordAdmissionLock.unlock()
        }
        return true
    }

    /// Freezes the typed transition prelude and samples the process once for this incident.
    ///
    /// This is the piece T-091 could not get: the only sample of that hang was taken by hand
    /// two hours in, after 10.4 GB had swapped, when every turn was slow for reasons that had
    /// nothing to do with the cause. A sample taken five seconds into the stall shows the
    /// cycle while it is still just a cycle. Once per stall — a spin lasting two hours must not
    /// spend those hours writing samples.
    private func admitCaptureJob() -> Bool {
        captureAdmissionLock.lock()
        guard admittedCaptureJobs < 2 else {
            captureAdmissionLock.unlock()
            return false
        }
        admittedCaptureJobs += 1
        captureAdmissionLock.unlock()
        return true
    }

    private func recordCaptureAdmission(
        _ admitted: Bool?,
        incident: Incident,
        onsetPersisted: Bool
    ) -> Bool {
        guard admitted == true else {
            guard onsetPersisted else { return false }
            return write(
                kind: "stall-sample-failed",
                message: "stack sample was not scheduled",
                incidentID: incident.id,
                extraFigures: [
                    "reason": "capture-capacity",
                    "exitStatus": "unavailable",
                ]
            )
        }
        guard onsetPersisted else { return false }
        return write(
            kind: "stall-sample-scheduled",
            message: "stack sampling scheduled",
            incidentID: incident.id,
            extraFigures: ["sampleFile": incident.relativeSamplePath]
        )
    }

    private func releaseCaptureAdmission() {
        captureAdmissionLock.lock()
        admittedCaptureJobs -= 1
        captureAdmissionLock.unlock()
    }

    private func submitCaptureJob(_ incident: Incident) {
        let capture = captureSample
        // Off both the main queue and the watchdog queue: neither the wedged UI nor a broken
        // sampler may stop continued-stall evidence.
        captureQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.releaseCaptureAdmission()
            }
            guard self.captureReceiptsAreEnabled() else { return }
            guard self.createOwnedIncidentDirectory(incident) else {
                _ = self.writeCaptureReceipt(
                    kind: "stall-transitions-failed",
                    message: "typed pre-incident transitions could not be committed",
                    incident: incident,
                    extraFigures: ["reason": "artifact-directory-create-failed"]
                )
                _ = self.writeCaptureReceipt(
                    kind: "stall-sample-failed",
                    message: "stack sample was not started",
                    incident: incident,
                    extraFigures: [
                        "reason": "artifact-directory-create-failed",
                        "exitStatus": "unavailable",
                    ]
                )
                return
            }

            self.writeTransitions(incident)
            guard self.captureReceiptsAreEnabled() else {
                self.removeOwnedArtifact(named: "sample.partial", incident: incident)
                return
            }
            guard let sample = self.captureIntoOwnedArtifact(
                incident: incident,
                capture: capture
            ) else {
                _ = self.writeCaptureReceipt(
                    kind: "stall-sample-failed",
                    message: "stack sample output could not be opened safely",
                    incident: incident,
                    extraFigures: [
                        "reason": "artifact-open-failed",
                        "exitStatus": "unavailable",
                    ]
                )
                return
            }
            // Old builds used this durable leaf, and an adversarial same-user process may try
            // to recreate it while capture runs. Current raw bytes never target it; remove only
            // the verified incident-relative name before publishing the sanitized artifact.
            self.removeOwnedArtifact(named: "sample.partial", incident: incident)
            self.commitSample(sample, incident: incident)
            self.pruneIncidentArtifacts()
        }
    }

    /// `/usr/bin/sample` against our own pid. It reads the target's threads from outside, so
    /// it works while the main thread is inside a call that will never return — which is the
    /// only condition under which it is ever run.
    static let sampleThisProcess: @Sendable (FileHandle) -> DiagnosticsSampleResult = { destination in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            "3",
        ]
        // stdout is the pipe writer drained into Tenon's bounded, already-unlinked inode.
        // Never hand `/usr/bin/sample` a pathname: its `-file` implementation follows symlinks.
        process.standardOutput = destination
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return .launchFailed
        }
        guard completed.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return .timedOut
        }
        return .finished(exitStatus: process.terminationStatus)
    }

    @discardableResult
    private func write(
        kind: String,
        message: String,
        seconds: TimeInterval? = nil,
        incidentID: String? = nil,
        extraFigures: [String: String] = [:],
        measurement frozenMeasurement: MeasurementSnapshot? = nil
    ) -> Bool {
        var figures = identity.figures
        let measurement: MeasurementSnapshot
        if let frozenMeasurement {
            measurement = frozenMeasurement
        } else {
            let timestamp = now()
            let fallbackFootprint = footprintBytes()
            lock.lock()
            measurement = MeasurementSnapshot(
                at: Date(),
                uptime: timestamp,
                footprintBytes: latestFootprintBytes ?? fallbackFootprint,
                cpuCorePercent: latestCPUCorePercent,
                runloopPhase: lastRunloopPhase,
                beatSequence: beatSequence,
                lastBeatAt: lastBeatAt,
                mainQueuePingAt: pendingMainQueuePingAt
            )
            lock.unlock()
        }
        let ackAge = measurement.mainQueuePingAt.map {
            max(measurement.uptime - $0, 0)
        }

        figures["footprintMB"] = measurement.footprintBytes
            .map { "\($0 / 1_048_576)" } ?? "unavailable"
        figures["cpuCorePercent"] = measurement.cpuCorePercent
            .map { String(format: "%.1f", $0) } ?? "unavailable"
        figures["lastRunloopPhase"] = measurement.runloopPhase
        figures["beatSequence"] = "\(measurement.beatSequence)"
        figures["lastBeatAgeMS"] = String(
            format: "%.0f",
            max(measurement.uptime - measurement.lastBeatAt, 0) * 1_000
        )
        figures["mainQueueAckAgeMS"] = ackAge.map {
            String(format: "%.0f", $0 * 1_000)
        } ?? "none"
        if let seconds {
            figures["seconds"] = String(format: "%.1f", seconds)
        }
        if let incidentID { figures["incidentID"] = incidentID }
        figures.merge(extraFigures) { _, replacement in replacement }
        let appended = persistRecord(
            DiagnosticsRecord(
                at: measurement.at,
                kind: kind,
                message: message,
                figures: figures
            )
        )
        if !appended {
            TenonLog.diagnostics.error("diagnostics journal append failed for kind \(kind)")
        }
        return appended
    }

    // MARK: - Responsiveness and incident artifacts  @domain: diagnostics

    private func scheduleMainQueuePingIfNeeded(at timestamp: TimeInterval) {
        lock.lock()
        guard monitorsMainQueue, pendingMainQueuePingAt == nil else {
            lock.unlock()
            return
        }
        pendingMainQueuePingAt = timestamp
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.acknowledgeMainQueuePing()
        }
    }

    private func acknowledgeMainQueuePing() {
        let timestamp = now()
        lock.lock()
        let sentAt = pendingMainQueuePingAt
        pendingMainQueuePingAt = nil
        var payloads: [RuntimeEventPayload] = []
        if !hasStopped,
           let startedAt = responsivenessStallStartedAt,
           let incident = activeResponsivenessIncident {
            responsivenessStallStartedAt = nil
            responsivenessLastEscalationAt = nil
            activeResponsivenessIncident = nil
            payloads.append(.responsivenessRecovered(max(timestamp - startedAt, 0), incident))
        } else if !hasStopped,
                  let sentAt,
                  timestamp - sentAt >= stallThreshold {
            // The ping can cross the threshold and return between one-second watchdog probes.
            // Preserve that bounded outage as a stall+recovery pair instead of missing it.
            let sharedIncident = activeRunloopIncident
                ?? recentRunloopIncidentAwaitingPing
            let incident = sharedIncident ?? makeIncidentLocked()
            let duration = max(timestamp - sentAt, 0)
            payloads.append(
                .responsivenessStalled(
                    duration,
                    incident,
                    captureEvidence: sharedIncident == nil
                )
            )
            payloads.append(.responsivenessRecovered(duration, incident))
        }
        recentRunloopIncidentAwaitingPing = nil
        let measurement = measurementSnapshotLocked(at: timestamp)
        let events = payloads.map { RuntimeEvent(payload: $0, measurement: measurement) }
        enqueueRecordsLocked(events)
        lock.unlock()
    }

    /// Detects queue saturation that a runloop-phase observer cannot: the observer may keep
    /// firing even while ordinary main-queue work waits many seconds behind a self-feeding burst.
    /// `beatAge < threshold` is the discriminator that prevents duplicating a no-turn stall.
    private func responsivenessEventPayload(
        at timestamp: TimeInterval,
        beatAge: TimeInterval,
        ackAge: TimeInterval?
    ) -> RuntimeEventPayload? {
        guard let ackAge,
              ackAge >= stallThreshold,
              beatAge < stallThreshold
        else { return nil }

        if responsivenessStallStartedAt == nil {
            responsivenessStallStartedAt = timestamp - ackAge
            responsivenessLastEscalationAt = timestamp
            let sharedIncident = activeRunloopIncident ?? recentRunloopIncidentAwaitingPing
            let incident = sharedIncident ?? makeIncidentLocked()
            activeResponsivenessIncident = incident
            return .responsivenessStalled(
                ackAge,
                incident,
                captureEvidence: sharedIncident == nil
            )
        }
        guard let startedAt = responsivenessStallStartedAt,
              timestamp - (responsivenessLastEscalationAt ?? startedAt) >= escalationInterval
        else { return nil }
        responsivenessLastEscalationAt = timestamp
        return .responsivenessStillStalled(
            max(timestamp - startedAt, 0),
            activeResponsivenessIncident
        )
    }

    /// Called while `lock` is held so a recovery cannot outrun the stall's incident identity.
    private func prepareRunloopEventPayloadLocked(
        _ event: RunloopHealth.Event
    ) -> RuntimeEventPayload {
        switch event {
        case let .stalled(duration):
            let sharedIncident = activeResponsivenessIncident
            let incident = sharedIncident ?? makeIncidentLocked()
            activeRunloopIncident = incident
            recentRunloopIncidentAwaitingPing = nil
            return .runloopStalled(
                duration,
                incident,
                captureEvidence: sharedIncident == nil
            )
        case let .stillStalled(duration):
            return .runloopStillStalled(duration, activeRunloopIncident)
        case let .recovered(duration):
            let incident = activeRunloopIncident
            activeRunloopIncident = nil
            recentRunloopIncidentAwaitingPing = pendingMainQueuePingAt == nil ? nil : incident
            return .runloopRecovered(duration, incident)
        }
    }

    private func updateProcessFigures(
        at timestamp: TimeInterval,
        cpuTime: TimeInterval?,
        footprintBytes: UInt64?
    ) {
        let wallDelta = timestamp - lastProbeAt
        if let cpuTime, let lastCPUTime, wallDelta > 0 {
            let cpuDelta = cpuTime - lastCPUTime
            latestCPUCorePercent = cpuDelta >= 0 ? (cpuDelta / wallDelta) * 100 : nil
        } else {
            latestCPUCorePercent = nil
        }
        lastProbeAt = timestamp
        lastCPUTime = cpuTime
        latestFootprintBytes = footprintBytes
    }

    /// Caller holds `lock`. Event records use this immutable view of the exact detection turn;
    /// a slow journal queue must never relabel onset with post-recovery metrics or timestamps.
    private func measurementSnapshotLocked(at timestamp: TimeInterval) -> MeasurementSnapshot {
        MeasurementSnapshot(
            at: Date(),
            uptime: timestamp,
            footprintBytes: latestFootprintBytes,
            cpuCorePercent: latestCPUCorePercent,
            runloopPhase: lastRunloopPhase,
            beatSequence: beatSequence,
            lastBeatAt: lastBeatAt,
            mainQueuePingAt: pendingMainQueuePingAt
        )
    }

    /// Caller holds `lock`; the transition ring has its own lock.
    private func makeIncidentLocked() -> Incident {
        let ordinal = nextIncidentOrdinal
        nextIncidentOrdinal += 1

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let incidentID = String(format: "%04d-%@", ordinal, String(suffix))
        let safeRunID = Self.safePathComponent(identity.runID)
        let directory = journal.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("incidents", isDirectory: true)
            .appendingPathComponent(safeRunID, isDirectory: true)
            .appendingPathComponent(incidentID, isDirectory: true)
        return Incident(
            id: incidentID,
            runName: safeRunID,
            directory: directory,
            relativeSamplePath: "incidents/\(safeRunID)/\(incidentID)/sample.txt",
            transitions: signals.snapshot(),
            receiptState: IncidentReceiptState()
        )
    }

    private func writeTransitions(_ incident: Incident) {
        let encoder = JSONEncoder()
        do {
            let lines = try incident.transitions.map { transition -> String in
                let data = try encoder.encode(transition)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                return line
            }
            let data = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
            guard writeOwnedArtifact(data, named: "transitions.jsonl", incident: incident) else {
                throw CocoaError(.fileWriteUnknown)
            }
            _ = writeCaptureReceipt(
                kind: "stall-transitions-completed",
                message: "typed pre-incident transitions committed",
                incident: incident,
                extraFigures: [
                    "transitionFile": incident.relativeSamplePath
                        .replacingOccurrences(of: "sample.txt", with: "transitions.jsonl"),
                    "transitionCount": "\(incident.transitions.count)",
                    "transitionBytes": "\(data.count)",
                ],
                artifactToRemoveOnFailure: "transitions.jsonl"
            )
        } catch {
            _ = writeCaptureReceipt(
                kind: "stall-transitions-failed",
                message: "typed pre-incident transitions could not be committed",
                incident: incident,
                extraFigures: ["reason": "write-failed"]
            )
        }
    }

    private func commitSample(_ sample: CapturedSample, incident: Incident) {
        guard case let .finished(exitStatus) = sample.result, exitStatus == 0 else {
            recordSampleFailure(sample.result, incident: incident)
            return
        }
        guard sample.observedByteCount > 0 else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "stack sample did not produce a complete artifact",
                incident: incident,
                extraFigures: ["reason": "empty-output", "exitStatus": "0"]
            )
            return
        }
        guard !sample.exceededLimit else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "stack sample exceeded the artifact limit",
                incident: incident,
                extraFigures: [
                    "reason": "oversized-output",
                    "sampleBytes": "\(sample.observedByteCount)",
                    "maximumSampleBytes": "\(maximumSampleBytes)",
                    "exitStatus": "0",
                ]
            )
            return
        }
        guard let originalData = sample.data else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "stack sample could not be read from its private capture",
                incident: incident,
                extraFigures: ["reason": "artifact-read-failed", "exitStatus": "0"]
            )
            return
        }
        guard let originalText = String(data: originalData, encoding: .utf8) else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "stack sample could not be privacy-filtered",
                incident: incident,
                extraFigures: ["reason": "redaction-failed", "exitStatus": "0"]
            )
            return
        }
        let sanitizedData = Data(Self.sanitizedSampleText(originalText).utf8)
        guard sanitizedData.count <= maximumSampleBytes else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "privacy-filtered stack sample exceeded the artifact limit",
                incident: incident,
                extraFigures: [
                    "reason": "sanitized-output-oversized",
                    "sampleBytes": "\(sanitizedData.count)",
                    "maximumSampleBytes": "\(maximumSampleBytes)",
                    "exitStatus": "0",
                ]
            )
            return
        }
        let byteCount = sanitizedData.count
        guard captureReceiptsAreEnabled() else {
            return
        }
        if writeOwnedArtifact(sanitizedData, named: "sample.txt", incident: incident) {
            _ = writeCaptureReceipt(
                kind: "stall-sample-completed",
                message: "stack sample committed",
                incident: incident,
                extraFigures: [
                    "sampleFile": incident.relativeSamplePath,
                    "sampleBytes": "\(byteCount)",
                    "exitStatus": "0",
                ],
                artifactToRemoveOnFailure: "sample.txt"
            )
        } else {
            _ = writeCaptureReceipt(
                kind: "stall-sample-failed",
                message: "stack sample could not be committed",
                incident: incident,
                extraFigures: ["reason": "commit-failed", "exitStatus": "0"]
            )
        }
    }

    private func recordSampleFailure(
        _ result: DiagnosticsSampleResult,
        incident: Incident
    ) {
        let figures: [String: String] = switch result {
        case let .finished(exitStatus):
            ["reason": "nonzero-exit", "exitStatus": "\(exitStatus)"]
        case .launchFailed:
            ["reason": "launch-failed", "exitStatus": "unavailable"]
        case .timedOut:
            ["reason": "timeout", "exitStatus": "unavailable"]
        }
        _ = writeCaptureReceipt(
            kind: "stall-sample-failed",
            message: "stack sample did not complete",
            incident: incident,
            extraFigures: figures
        )
    }

    static func sanitizedSampleText(_ text: String) -> String {
        var result = text
        let sensitiveLinePattern = #"(?m)^(Command|Arguments|Environment|Working Directory|CWD):.*$"#
        result = result.replacingOccurrences(
            of: sensitiveLinePattern,
            with: "$1: [redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)/(Users|Volumes)/.*$"#,
            with: "[redacted-user-path]",
            options: .regularExpression
        )
        return result.replacingOccurrences(
            of: #"dev\.tenon\.plugin(?:-watch)?\.[^\s]+"#,
            with: "dev.tenon.plugin.[redacted]",
            options: .regularExpression
        )
    }

    private func captureReceiptsAreEnabled() -> Bool {
        lock.lock()
        let stopped = hasStopped
        lock.unlock()
        guard !stopped else { return false }
        captureReceiptLock.lock()
        defer { captureReceiptLock.unlock() }
        return captureReceiptsEnabled
    }

    @discardableResult
    private func writeCaptureReceipt(
        kind: String,
        message: String,
        incident: Incident,
        extraFigures: [String: String],
        artifactToRemoveOnFailure: String? = nil
    ) -> Bool {
        captureReceiptLock.lock()
        lock.lock()
        let stopped = hasStopped
        lock.unlock()
        guard captureReceiptsEnabled, !stopped else {
            captureReceiptLock.unlock()
            if let artifactToRemoveOnFailure {
                removeOwnedArtifact(named: artifactToRemoveOnFailure, incident: incident)
            }
            return false
        }
        // At most two capture jobs are admitted, so their completion receipts add a fixed
        // maximum of four queued writes. Reserve that tiny bound instead of letting ordinary
        // event pressure orphan an already-captured artifact.
        recordQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let mustAbort = self.abortQueuedCaptureReceipts
            self.lock.unlock()
            guard !mustAbort else {
                if let artifactToRemoveOnFailure {
                    self.removeOwnedArtifact(named: artifactToRemoveOnFailure, incident: incident)
                }
                return
            }
            guard incident.receiptState.canPersistCaptureReceipts else {
                if let artifactToRemoveOnFailure {
                    self.removeOwnedArtifact(named: artifactToRemoveOnFailure, incident: incident)
                }
                return
            }
            let persisted = self.write(
                kind: kind,
                message: message,
                incidentID: incident.id,
                extraFigures: extraFigures
            )
            if !persisted, let artifactToRemoveOnFailure {
                self.removeOwnedArtifact(named: artifactToRemoveOnFailure, incident: incident)
            }
        }
        captureReceiptLock.unlock()
        return true
    }

    /// Create and reopen every incident path component descriptor-relatively. A corrupted
    /// `incidents/<run>` symlink must fail before the external sampler receives a destination.
    private func createOwnedIncidentDirectory(_ incident: Incident) -> Bool {
        withOwnedIncidentDirectory(incident, create: true) { _ in true } ?? false
    }

    private func withOwnedIncidentDirectory<T>(
        _ incident: Incident,
        create: Bool,
        body: (Int32) -> T
    ) -> T? {
        let diagnosticsRoot = journal.fileURL.deletingLastPathComponent()
        if create {
            try? FileManager.default.createDirectory(
                at: diagnosticsRoot,
                withIntermediateDirectories: true
            )
        }
        let rootDescriptor = Darwin.open(
            diagnosticsRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return nil }
        defer { Darwin.close(rootDescriptor) }
        guard let incidentsDescriptor = openOwnedDirectory(
            parent: rootDescriptor,
            name: "incidents",
            create: create
        ) else { return nil }
        defer { Darwin.close(incidentsDescriptor) }
        guard let runDescriptor = openOwnedDirectory(
            parent: incidentsDescriptor,
            name: incident.runName,
            create: create
        ) else { return nil }
        defer { Darwin.close(runDescriptor) }
        guard let incidentDescriptor = openOwnedDirectory(
            parent: runDescriptor,
            name: incident.id,
            create: create
        ) else { return nil }
        defer { Darwin.close(incidentDescriptor) }
        return body(incidentDescriptor)
    }

    private func openOwnedDirectory(
        parent: Int32,
        name: String,
        create: Bool
    ) -> Int32? {
        guard name != ".", name != "..", Self.safePathComponent(name) == name else { return nil }
        if create, Darwin.mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
            return nil
        }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        return descriptor >= 0 ? descriptor : nil
    }

    /// Capture through a bounded pipe into an immediately unlinked inode. A force kill cannot
    /// strand raw sample text, and the sampler can never place more than `maximumSampleBytes`
    /// on disk even if its stdout exceeds the limit.
    private func captureIntoOwnedArtifact(
        incident: Incident,
        capture: @Sendable (FileHandle) -> DiagnosticsSampleResult
    ) -> CapturedSample? {
        withOwnedIncidentDirectory(incident, create: false) { directory in
            _ = Darwin.unlinkat(directory, "sample-staging.tmp", 0)
            let descriptor = Darwin.openat(
                directory,
                "sample-staging.tmp",
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { return nil as CapturedSample? }
            guard Darwin.unlinkat(directory, "sample-staging.tmp", 0) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            let pipe = Pipe()
            guard let drain = BoundedSampleDrain(
                source: pipe.fileHandleForReading,
                destination: descriptor,
                maximumBytes: maximumSampleBytes
            ) else {
                try? pipe.fileHandleForWriting.close()
                return nil
            }
            drain.start(on: captureDrainQueue)
            let result = capture(pipe.fileHandleForWriting)
            try? pipe.fileHandleForWriting.close()
            let waitsForCompleteOutput: TimeInterval = switch result {
            case .finished(exitStatus: 0): 1
            case .finished, .launchFailed, .timedOut: 0
            }
            let output = drain.finish(waitingForEOF: waitsForCompleteOutput)
            return CapturedSample(
                result: result,
                data: output.data,
                observedByteCount: output.observedByteCount,
                exceededLimit: output.exceededLimit
            )
        } ?? nil
    }

    /// Atomically replace one fixed-name artifact below an already verified incident
    /// directory. Neither the temporary leaf nor the final rename follows symlinks.
    private func writeOwnedArtifact(
        _ data: Data,
        named name: String,
        incident: Incident
    ) -> Bool {
        guard Self.ownedArtifactNames.contains(name),
              let temporary = Self.ownedArtifactTemporaryNames[name]
        else { return false }
        return withOwnedIncidentDirectory(incident, create: false) { directory in
            // A force-kill may strand the fixed temporary leaf. Removing this exact name via
            // the verified directory fd is safe; a random hidden temp would evade retention.
            _ = Darwin.unlinkat(directory, temporary, 0)
            let descriptor = Darwin.openat(
                directory,
                temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { return false }
            defer {
                Darwin.close(descriptor)
                _ = Darwin.unlinkat(directory, temporary, 0)
            }
            let wroteAll = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            guard wroteAll, Darwin.fsync(descriptor) == 0 else { return false }
            return Darwin.renameat(directory, temporary, directory, name) == 0
        } ?? false
    }

    private func removeOwnedArtifact(named name: String, incident: Incident) {
        guard Self.ownedArtifactNames.contains(name) else { return }
        _ = withOwnedIncidentDirectory(incident, create: false) { directory in
            Darwin.unlinkat(directory, name, 0)
        }
    }

    private static let ownedArtifactNames: Set<String> = [
        "sample.partial", "sample.txt", "transitions.jsonl",
    ]
    private static let ownedArtifactTemporaryNames: [String: String] = [
        "sample.partial": "sample-staging.tmp",
        "sample.txt": "sample-commit.tmp",
        "transitions.jsonl": "transitions-commit.tmp",
    ]
    private static let ownedTransientArtifactNames: Set<String> = [
        "sample.partial", "sample-staging.tmp", "sample-commit.tmp", "transitions-commit.tmp",
    ]

    private func pruneIncidentArtifacts() {
        let root = journal.fileURL.deletingLastPathComponent()
            .appendingPathComponent("incidents", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let runDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var incidents: [(runName: String, incidentName: String, modified: Date)] = []
        for runDirectory in runDirectories {
            let runValues = try? runDirectory.resourceValues(forKeys: keys)
            guard runValues?.isDirectory == true,
                  runValues?.isSymbolicLink != true,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: runDirectory,
                      includingPropertiesForKeys: Array(keys),
                      options: [.skipsHiddenFiles]
                  )
            else { continue }
            for child in children {
                let childValues = try? child.resourceValues(forKeys: keys)
                guard childValues?.isDirectory == true,
                      childValues?.isSymbolicLink != true
                else { continue }
                removeOwnedIncidentTransientArtifacts(
                    below: root,
                    runName: runDirectory.lastPathComponent,
                    incidentName: child.lastPathComponent
                )
                incidents.append(
                    (
                        runName: runDirectory.lastPathComponent,
                        incidentName: child.lastPathComponent,
                        modified: childValues?.contentModificationDate ?? .distantPast
                    )
                )
            }
        }
        let expired = incidents.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            if $0.runName != $1.runName { return $0.runName > $1.runName }
            return $0.incidentName > $1.incidentName
        }.dropFirst(retainedIncidentCount)
        for incident in expired {
            removeOwnedIncidentArtifacts(
                below: root,
                runName: incident.runName,
                incidentName: incident.incidentName
            )
        }
    }

    /// Upgrade cleanup for incidents created by older builds. Retained evidence stays, but raw
    /// partials and interrupted commit leaves are removed from every verified incident at launch.
    private func removeOwnedIncidentTransientArtifacts(
        below root: URL,
        runName: String,
        incidentName: String
    ) {
        guard runName != ".", runName != "..",
              incidentName != ".", incidentName != "..",
              Self.safePathComponent(runName) == runName,
              Self.safePathComponent(incidentName) == incidentName
        else { return }
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return }
        defer { Darwin.close(rootDescriptor) }
        let runDescriptor = Darwin.openat(
            rootDescriptor,
            runName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard runDescriptor >= 0 else { return }
        defer { Darwin.close(runDescriptor) }
        let incidentDescriptor = Darwin.openat(
            runDescriptor,
            incidentName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard incidentDescriptor >= 0 else { return }
        defer { Darwin.close(incidentDescriptor) }
        for artifact in Self.ownedTransientArtifactNames {
            _ = Darwin.unlinkat(incidentDescriptor, artifact, 0)
        }
    }

    /// Delete only files this runtime owns, through no-follow directory descriptors. Unknown
    /// content deliberately makes `AT_REMOVEDIR` fail: retention leaks a suspicious directory
    /// instead of recursively deleting through an attacker-controlled tree.
    private func removeOwnedIncidentArtifacts(
        below root: URL,
        runName: String,
        incidentName: String
    ) {
        guard runName != ".", runName != "..",
              incidentName != ".", incidentName != "..",
              Self.safePathComponent(runName) == runName,
              Self.safePathComponent(incidentName) == incidentName
        else { return }
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return }
        defer { Darwin.close(rootDescriptor) }
        let runDescriptor = Darwin.openat(
            rootDescriptor,
            runName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard runDescriptor >= 0 else { return }
        defer { Darwin.close(runDescriptor) }
        let incidentDescriptor = Darwin.openat(
            runDescriptor,
            incidentName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard incidentDescriptor >= 0 else { return }
        for artifact in Self.ownedArtifactNames.union(Self.ownedTransientArtifactNames) {
            _ = Darwin.unlinkat(incidentDescriptor, artifact, 0)
        }
        Darwin.close(incidentDescriptor)
        _ = Darwin.unlinkat(runDescriptor, incidentName, AT_REMOVEDIR)
        _ = Darwin.unlinkat(rootDescriptor, runName, AT_REMOVEDIR)
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars.prefix(96))
    }

    private static func runloopPhase(_ activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry: "entry"
        case .beforeTimers: "before-timers"
        case .beforeSources: "before-sources"
        case .beforeWaiting: "before-waiting"
        case .afterWaiting: "after-waiting"
        case .exit: "exit"
        default: "unknown"
        }
    }

    // MARK: - Process figures  @domain: diagnostics

    /// The number that told the T-091 story: 11.0 GB of physical footprint, which is what
    /// `heap` and `vmmap` report and what Activity Monitor calls Memory. `ru_maxrss` and
    /// resident size both understate it once memory is compressed or swapped — during that
    /// hang `ps` showed 232 MB resident while the real footprint was 11 GB.
    static let physicalFootprint: @Sendable () -> UInt64? = {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Cumulative user + system CPU time. Consecutive watchdog probes convert this to core
    /// percent, so a spin (~100% for one saturated core) is distinguishable from a wait (~0%).
    static let processCPUTime: @Sendable () -> TimeInterval? = {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ value: timeval) -> TimeInterval {
            TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
