// @domain: plugin-host
import CoreFoundation
import Darwin
import Dispatch
import Foundation
import os

/// A serial actor executor backed by exactly one long-lived Foundation thread.
///
/// An actor that uses this executor must retain it for the actor's entire lifetime:
///
/// ```swift
/// actor RuntimeActor {
///     private let executor: PinnedThreadExecutor
///
///     nonisolated var unownedExecutor: UnownedSerialExecutor {
///         executor.asUnownedSerialExecutor()
///     }
/// }
/// ```
///
/// The executor owns the worker lifecycle, while the worker thread's entry closure retains
/// only the worker. This avoids an executor/thread retain cycle. Enqueued jobs are accepted
/// in lock-acquisition order, drained FIFO, and executed to their next suspension point on
/// the same operating-system thread.
///
/// `shutdown(timeout:)` is an owner operation: stop issuing actor calls before invoking it,
/// invoke it from outside every actor that uses this executor, and keep those actors alive
/// until it returns `.stopped`. `SerialExecutor.enqueue` cannot reject work, so violating
/// that ordering is a programmer error instead of silently dropping or rerouting a job.
public final class PinnedThreadExecutor: SerialExecutor {
    public enum StartupError: Error, Equatable, Sendable {
        case invalidTimeout(TimeInterval)
        case wakeChannelUnavailable(Int32)
        case runLoopUnavailable
        case timedOut(TimeInterval)
    }

    public enum ShutdownResult: Equatable, Sendable {
        case stopped
        case timedOut
        case invalidTimeout
    }

    private static let deinitShutdownTimeout: TimeInterval = 1

    private let worker: PinnedThreadWorker

    public init(
        name: String,
        qualityOfService: QualityOfService = .userInitiated,
        startupTimeout: TimeInterval = 2
    ) throws {
        guard startupTimeout.isFinite, startupTimeout >= 0 else {
            throw StartupError.invalidTimeout(startupTimeout)
        }

        let worker: PinnedThreadWorker
        do {
            worker = try PinnedThreadWorker()
        } catch let error as PinnedThreadWorker.CreationError {
            switch error {
            case let .wakeChannelUnavailable(code):
                throw StartupError.wakeChannelUnavailable(code)
            }
        }
        self.worker = worker

        switch worker.start(
            name: name,
            qualityOfService: qualityOfService,
            timeout: startupTimeout
        ) {
        case .started:
            break
        case .runLoopUnavailable:
            throw StartupError.runLoopUnavailable
        case .timedOut:
            throw StartupError.timedOut(startupTimeout)
        }
    }

    /// The Darwin thread identifier recorded by the worker before startup completes.
    public var threadIdentifier: UInt64? {
        worker.threadIdentifier
    }

    public var isShutdown: Bool {
        worker.isStopped
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        // ExecutorJob is move-only and therefore cannot currently be stored in Array.
        // SE-0392 provides UnownedJob specifically for this queueing boundary.
        let queuedJob = UnownedJob(job)
        let accepted = worker.enqueue(
            job: queuedJob,
            executor: asUnownedSerialExecutor()
        )

        precondition(
            accepted,
            "PinnedThreadExecutor received work after shutdown began. "
                + "Quiesce and release every actor caller before shutdown."
        )
    }

    /// Answers using the actual operating-system thread, not a queue-specific marker.
    public func isIsolatingCurrentContext() -> Bool? {
        worker.isCurrentThread
    }

    /// Backward-compatible fallback for runtimes that cannot use
    /// `isIsolatingCurrentContext()` directly.
    public func checkIsolated() {
        precondition(
            isIsolatingCurrentContext() == true,
            "PinnedThreadExecutor isolation check failed: work is on the wrong thread."
        )
    }

    /// Stops accepting work, drains already accepted jobs, and waits without blocking a
    /// Swift cooperative-pool thread. Repeated calls are safe and return `.stopped`.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 2) async -> ShutdownResult {
        guard timeout.isFinite, timeout >= 0 else {
            return .invalidTimeout
        }

        worker.requestShutdown()
        return await worker.waitUntilStopped(timeout: timeout) ? .stopped : .timedOut
    }

    deinit {
        worker.requestShutdown()

        // Waiting for our own currently executing job would deadlock until the timeout.
        // The worker observes the stop request immediately after that job returns.
        if !worker.isCurrentThread {
            _ = worker.waitUntilStoppedSynchronously(
                timeout: Self.deinitShutdownTimeout
            )
        }
    }
}

/// The queue/thread mechanism behind `PinnedThreadExecutor`.
///
/// It is internal so focused tests can exercise FIFO and bounded teardown directly without
/// manufacturing Swift runtime jobs. The public scheduling boundary remains the actor.
final class PinnedThreadWorker: Sendable {
    enum CreationError: Error, Equatable, Sendable {
        case wakeChannelUnavailable(Int32)
    }

    enum StartResult: Equatable, Sendable {
        case started
        case runLoopUnavailable
        case timedOut
    }

    private enum Phase: Sendable {
        case ready
        case starting
        case running
        case stopping
        case stopped
    }

    private enum WorkItem: Sendable {
        case executorJob(UnownedJob, UnownedSerialExecutor)
        case operation(@Sendable () -> Void)

        func run() {
            switch self {
            case let .executorJob(job, executor):
                job.runSynchronously(on: executor)
            case let .operation(operation):
                operation()
            }
        }
    }

    private enum StartupOutcome: Sendable {
        case pending
        case started
        case runLoopUnavailable
    }

    private struct State: Sendable {
        var phase = Phase.ready
        var startupOutcome = StartupOutcome.pending
        var queue: [WorkItem?] = []
        var nextIndex = 0
        var threadIdentifier: UInt64?

        var queueIsEmpty: Bool {
            nextIndex == queue.count
        }

        mutating func append(_ work: WorkItem) {
            queue.append(work)
        }

        mutating func popFirst() -> WorkItem? {
            guard !queueIsEmpty else { return nil }

            let work = queue[nextIndex]
            queue[nextIndex] = nil
            nextIndex += 1

            if nextIndex == queue.count {
                queue.removeAll(keepingCapacity: true)
                nextIndex = 0
            } else if nextIndex >= 1_024, nextIndex >= queue.count / 2 {
                queue.removeFirst(nextIndex)
                nextIndex = 0
            }

            return work
        }
    }

    private enum NextAction {
        case run([WorkItem], queueRemains: Bool)
        case wait
        case stop
    }

    private enum ShutdownAction {
        case none
        case wake
        case finishWithoutStarting
    }

    private static let maximumBatchSize = 64
    private static let maximumRunLoopSleep: TimeInterval = 10_000_000_000

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = DispatchGroup()
    private let stopped = DispatchGroup()
    private let wakeReadDescriptor: Int32
    private let wakeWriteDescriptor: Int32

    init() throws {
        let descriptors = try Self.makeWakePipe()
        wakeReadDescriptor = descriptors.read
        wakeWriteDescriptor = descriptors.write
        started.enter()
        stopped.enter()
    }

    deinit {
        Darwin.close(wakeReadDescriptor)
        Darwin.close(wakeWriteDescriptor)
    }

    var threadIdentifier: UInt64? {
        state.withLock { $0.threadIdentifier }
    }

    var isStopped: Bool {
        state.withLock { $0.phase == .stopped }
    }

    var isCurrentThread: Bool {
        guard let current = Self.currentThreadIdentifier() else { return false }
        return state.withLock { state in
            guard state.phase == .running || state.phase == .stopping,
                  let expected = state.threadIdentifier
            else {
                return false
            }
            return expected == current
        }
    }

    func start(
        name: String,
        qualityOfService: QualityOfService,
        timeout: TimeInterval
    ) -> StartResult {
        let canStart = state.withLock { state in
            guard state.phase == .ready else { return false }
            state.phase = .starting
            return true
        }
        precondition(canStart, "PinnedThreadWorker can only be started once.")

        let thread = Thread { [self] in
            runLoop()
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()

        guard started.wait(timeout: Self.deadline(after: timeout)) == .success else {
            requestShutdown()
            return .timedOut
        }

        return state.withLock { state in
            switch state.startupOutcome {
            case .started:
                return state.phase == .running ? .started : .timedOut
            case .runLoopUnavailable:
                return .runLoopUnavailable
            case .pending:
                preconditionFailure(
                    "PinnedThreadWorker completed startup without an outcome."
                )
            }
        }
    }

    func enqueue(job: UnownedJob, executor: UnownedSerialExecutor) -> Bool {
        enqueue(.executorJob(job, executor))
    }

    /// Internal bootstrap/verification lane. `@Sendable` prevents non-Sendable runtime
    /// objects from being captured and moved onto the worker thread.
    func enqueue(operation: @escaping @Sendable () -> Void) -> Bool {
        enqueue(.operation(operation))
    }

    func requestShutdown() {
        let action = state.withLock { state -> ShutdownAction in
            switch state.phase {
            case .ready:
                state.phase = .stopped
                return .finishWithoutStarting
            case .starting, .running:
                state.phase = .stopping
                return .wake
            case .stopping, .stopped:
                return .none
            }
        }

        switch action {
        case .none:
            break
        case .wake:
            signalRunLoop()
        case .finishWithoutStarting:
            started.leave()
            stopped.leave()
        }
    }

    func waitUntilStopped(timeout: TimeInterval) async -> Bool {
        if isStopped { return true }

        let stopped = self.stopped
        let deadline = Self.deadline(after: timeout)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: stopped.wait(timeout: deadline) == .success
                )
            }
        }
    }

    func waitUntilStoppedSynchronously(timeout: TimeInterval) -> Bool {
        if isStopped { return true }
        return stopped.wait(timeout: Self.deadline(after: timeout)) == .success
    }

    static func currentThreadIdentifier() -> UInt64? {
        var identifier: UInt64 = 0
        guard pthread_threadid_np(nil, &identifier) == 0 else {
            return nil
        }
        return identifier
    }

    private func enqueue(_ work: WorkItem) -> Bool {
        let accepted = state.withLock { state -> Bool in
            guard state.phase == .running else { return false }

            state.append(work)
            return true
        }

        guard accepted else { return false }
        signalRunLoop()
        return true
    }

    private func runLoop() {
        var descriptorContext = CFFileDescriptorContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let fileDescriptor = CFFileDescriptorCreate(
            kCFAllocatorDefault,
            wakeReadDescriptor,
            false,
            pinnedThreadWakeCallback,
            &descriptorContext
        ), let source = CFFileDescriptorCreateRunLoopSource(
            kCFAllocatorDefault,
            fileDescriptor,
            0
        ) else {
            failRunLoopStartup()
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
        CFFileDescriptorEnableCallBacks(
            fileDescriptor,
            CFOptionFlags(kCFFileDescriptorReadCallBack)
        )

        let shouldRun = state.withLock { state -> Bool in
            state.threadIdentifier = Self.currentThreadIdentifier()
            state.startupOutcome = .started

            switch state.phase {
            case .starting:
                state.phase = .running
                return true
            case .stopping:
                return false
            case .ready, .running, .stopped:
                preconditionFailure("PinnedThreadWorker entered an invalid startup phase.")
            }
        }

        started.leave()
        defer {
            CFRunLoopRemoveSource(currentRunLoop, source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
            CFFileDescriptorInvalidate(fileDescriptor)
            finish()
        }
        guard shouldRun else { return }

        while true {
            switch nextAction() {
            case let .run(workItems, queueRemains):
                for work in workItems {
                    autoreleasepool {
                        work.run()
                    }
                }

                let shouldServiceRunLoop = state.withLock { state in
                    state.phase == .running
                }
                guard shouldServiceRunLoop else { continue }

                if queueRemains {
                    signalRunLoop()
                }
                serviceRunLoop()
            case .wait:
                serviceRunLoop()
            case .stop:
                return
            }
        }
    }

    private func nextAction() -> NextAction {
        state.withLock { state in
            var batch: [WorkItem] = []
            batch.reserveCapacity(Self.maximumBatchSize)

            while batch.count < Self.maximumBatchSize,
                  let work = state.popFirst()
            {
                batch.append(work)
            }

            if !batch.isEmpty {
                return .run(batch, queueRemains: !state.queueIsEmpty)
            }

            switch state.phase {
            case .running:
                return .wait
            case .stopping, .stopped:
                return .stop
            case .ready, .starting:
                preconditionFailure("PinnedThreadWorker processed work before startup.")
            }
        }
    }

    private func serviceRunLoop() {
        let result = CFRunLoopRunInMode(
            .defaultMode,
            Self.maximumRunLoopSleep,
            true
        )
        precondition(
            result != .finished,
            "PinnedThreadWorker run loop lost its wake source."
        )
    }

    private func signalRunLoop() {
        var byte: UInt8 = 1

        while true {
            let written = withUnsafePointer(to: &byte) { pointer in
                Darwin.write(wakeWriteDescriptor, pointer, 1)
            }

            if written == 1 {
                return
            }
            if written == -1, errno == EINTR {
                continue
            }
            if written == -1, errno == EAGAIN {
                // A full non-blocking pipe is already a pending wake-up.
                return
            }

            preconditionFailure(
                "PinnedThreadWorker failed to signal its run loop: errno \(errno)."
            )
        }
    }

    private func failRunLoopStartup() {
        let shouldSignal = state.withLock { state -> Bool in
            state.startupOutcome = .runLoopUnavailable
            state.phase = .stopped
            return true
        }

        started.leave()
        if shouldSignal {
            stopped.leave()
        }
    }

    private func finish() {
        let shouldSignal = state.withLock { state -> Bool in
            guard state.phase != .stopped else { return false }
            state.phase = .stopped
            return true
        }

        if shouldSignal {
            stopped.leave()
        }
    }

    private static func deadline(after timeout: TimeInterval) -> DispatchTime {
        .now() + timeout
    }

    private static func makeWakePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw CreationError.wakeChannelUnavailable(errno)
        }

        do {
            try configureWakeDescriptor(descriptors[0])
            try configureWakeDescriptor(descriptors[1])
            return (read: descriptors[0], write: descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    private static func configureWakeDescriptor(_ descriptor: Int32) throws {
        let statusFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard statusFlags != -1,
              Darwin.fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) != -1
        else {
            throw CreationError.wakeChannelUnavailable(errno)
        }

        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags != -1,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) != -1
        else {
            throw CreationError.wakeChannelUnavailable(errno)
        }
    }
}

/// Drains the non-blocking wake pipe. No executor or runtime state crosses the C callback
/// boundary; returning from this source gives the owning thread back to `nextAction()`.
private func pinnedThreadWakeCallback(
    _ descriptor: CFFileDescriptor?,
    _ callbackTypes: CFOptionFlags,
    _ info: UnsafeMutableRawPointer?
) {
    guard let descriptor,
          callbackTypes & CFOptionFlags(kCFFileDescriptorReadCallBack) != 0
    else {
        return
    }

    let nativeDescriptor = CFFileDescriptorGetNativeDescriptor(descriptor)
    var buffer = [UInt8](repeating: 0, count: 256)

    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(nativeDescriptor, bytes.baseAddress, bytes.count)
        }

        if count > 0 {
            continue
        }
        if count == -1, errno == EINTR {
            continue
        }
        break
    }

    CFFileDescriptorEnableCallBacks(
        descriptor,
        CFOptionFlags(kCFFileDescriptorReadCallBack)
    )
}
