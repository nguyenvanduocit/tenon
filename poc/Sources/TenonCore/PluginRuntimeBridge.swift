// @domain: plugin-host
import Darwin
import Foundation
import JavaScriptCore
import TenonIntentCore
import os

struct PluginJavaScriptMessage: Sendable {
    let topic: String
    let payload: IntentValue
    let threadIdentifier: UInt64
}

/// The native JavaScript block writes owned JSON messages here while JavaScriptCore is on
/// the pinned thread. The runtime drains the mailbox before it returns to the run loop.
final class PluginJavaScriptMailbox: Sendable {
    private struct State: Sendable {
        var messages: [PluginJavaScriptMessage] = []
        var protocolErrors: [String] = []
    }

    private static let maximumMessagesPerTurn = 4_096
    private let state = OSAllocatedUnfairLock(initialState: State())

    func post(topic: String, value: JSValue) {
        let decoded: Result<IntentValue, Error> = Result {
            try PluginJavaScriptValueDecoder.decode(value)
        }

        state.withLock { state in
            guard state.messages.count < Self.maximumMessagesPerTurn else {
                if state.protocolErrors.isEmpty {
                    state.protocolErrors.append(
                        "more than \(Self.maximumMessagesPerTurn) bridge messages in one turn"
                    )
                }
                return
            }

            switch decoded {
            case let .success(payload):
                var threadIdentifier: UInt64 = 0
                pthread_threadid_np(nil, &threadIdentifier)
                state.messages.append(
                    PluginJavaScriptMessage(
                        topic: topic,
                        payload: payload,
                        threadIdentifier: threadIdentifier
                    )
                )
            case let .failure(error):
                state.protocolErrors.append("\(topic): \(error)")
            }
        }
    }

    func postProtocolError(_ message: String) {
        state.withLock { $0.protocolErrors.append(message) }
    }

    func drain() -> (messages: [PluginJavaScriptMessage], errors: [String]) {
        state.withLock { state in
            let result = (state.messages, state.protocolErrors)
            state.messages.removeAll(keepingCapacity: true)
            state.protocolErrors.removeAll(keepingCapacity: true)
            return result
        }
    }
}

enum PluginJavaScriptValueDecoder {
    private struct Accounting {
        var count = 0
    }

    static func decode(_ value: JSValue) throws -> IntentValue {
        var accounting = Accounting()
        let result = try decode(value, depth: 1, accounting: &accounting)
        try result.validate()
        return result
    }

    private static func decode(
        _ value: JSValue,
        depth: Int,
        accounting: inout Accounting
    ) throws -> IntentValue {
        guard depth <= IntentValueLimits.default.maxDepth else {
            throw IntentValueError.maximumDepthExceeded(
                limit: IntentValueLimits.default.maxDepth
            )
        }
        accounting.count += 1
        guard accounting.count <= IntentValueLimits.default.maxValueCount else {
            throw IntentValueError.maximumValueCountExceeded(
                limit: IntentValueLimits.default.maxValueCount
            )
        }

        if value.isUndefined || value.isNull {
            return .null
        }
        if value.isBoolean {
            return .bool(value.toBool())
        }
        if value.isNumber {
            let number = value.toDouble()
            guard number.isFinite else {
                throw IntentValueError.nonFiniteNumber
            }
            if number.rounded(.towardZero) == number,
               number >= Double(Int64.min),
               number <= Double(Int64.max)
            {
                return .integer(Int64(number))
            }
            return .number(number)
        }
        if value.isString {
            return .string(value.toString())
        }
        if value.isArray {
            let count = Int(value.forProperty("length").toInt32())
            guard count <= IntentValueLimits.default.maxCollectionCount else {
                throw IntentValueError.maximumCollectionCountExceeded(
                    limit: IntentValueLimits.default.maxCollectionCount
                )
            }
            return .array(
                try (0 ..< count).map { index in
                    try decode(value.atIndex(index), depth: depth + 1, accounting: &accounting)
                }
            )
        }
        if value.isObject {
            guard let context = value.context,
                  let object = context.objectForKeyedSubscript("Object"),
                  let keysFunction = object.objectForKeyedSubscript("keys"),
                  let keysValue = keysFunction.call(withArguments: [value]),
                  let keys = keysValue.toArray() as? [String]
            else {
                throw IntentValueError.invalidJSON
            }
            guard keys.count <= IntentValueLimits.default.maxCollectionCount else {
                throw IntentValueError.maximumCollectionCountExceeded(
                    limit: IntentValueLimits.default.maxCollectionCount
                )
            }
            var result: [String: IntentValue] = [:]
            result.reserveCapacity(keys.count)
            for key in keys {
                result[key] = try decode(
                    value.forProperty(key),
                    depth: depth + 1,
                    accounting: &accounting
                )
            }
            return .object(result)
        }

        throw IntentValueError.invalidJSON
    }
}

enum PluginRuntimeCallbackEvent: Sendable {
    case intentResult(token: String, result: IntentResult)
    case intentList(token: String, value: IntentValue)
    /// T-049: one published fact reached the host; the in-flight slot is free again.
    case publishedEventSettled
    case nestedIntentResult(callToken: String, token: String, result: IntentResult)
    case cancelProvider(callToken: String)
    case timerFired(handle: Int)
    case processOutputAvailable(handle: Int)
    case processEndOfFile(handle: Int, isStandardError: Bool)
    case processTerminated(handle: Int, status: Int32)
    case watchedPaths(handle: Int, paths: [String])
    case watchOverflow(handle: Int)
    /// A fact this generation subscribed to, accepted for delivery and waiting for the
    /// JavaScript thread. It rides the same mailbox as every other callback so one generation's
    /// slow observer costs that generation its own queue depth and nobody else's time.
    case eventPublished(name: String, payload: IntentValue)
}

/// Runs `operation`, returning its result or `nil` if `deadline` passes first.
///
/// The operation is deliberately neither cancelled nor awaited afterwards. What it waits on is
/// a plugin's own JavaScript, which may be in a loop that no cancellation flag can interrupt —
/// so the guarantee on offer is that the *caller* stops waiting, not that the plugin cooperates.
/// Its eventual result lands in a settlement that has already closed and is dropped.
func withPluginDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    let settlement = PluginDeadlineSettlement<T>()
    let work = Task { settlement.resume(await operation()) }
    let timer = Task {
        try? await Task.sleep(until: deadline, clock: .continuous)
        settlement.resume(nil)
    }
    defer {
        timer.cancel()
        // `work` is intentionally left running: see above.
        _ = work
    }
    return await withCheckedContinuation { continuation in
        settlement.attach(continuation)
    }
}

/// One-shot handoff for `withPluginDeadline`: the work and the deadline race, exactly one
/// resumes the continuation, and a caller cancelled before it suspends cannot lose it.
private final class PluginDeadlineSettlement<T: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting
        case attached(CheckedContinuation<T?, Never>)
        case resumed(T?)
        case finished
    }

    private let lock = NSLock()
    private var state: State = .waiting

    func attach(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        switch state {
        case .waiting:
            state = .attached(continuation)
            lock.unlock()
        case let .resumed(value):
            state = .finished
            lock.unlock()
            continuation.resume(returning: value)
        case .attached, .finished:
            lock.unlock()
        }
    }

    func resume(_ value: T?) {
        lock.lock()
        switch state {
        case .waiting:
            state = .resumed(value)
            lock.unlock()
        case let .attached(continuation):
            state = .finished
            lock.unlock()
            continuation.resume(returning: value)
        case .resumed, .finished:
            lock.unlock()
        }
    }
}

/// A plugin's log lines, ordered, bounded, and delivered without re-entering the runtime.
///
/// Three properties, each learned the hard way (T-080):
///
/// - **Ordered.** One line per detached task meant two lines written in order could arrive in
///   either order, and a log line's whole job is to be read by an author who cannot see the
///   failure any other way.
/// - **Bounded, and loud about it.** A full queue counts what it refused and says so once,
///   rather than dropping lines in silence.
/// - **Outside the actor.** The consumer never calls back into the runtime, because the
///   runtime runs on a pinned executor that stops accepting work during shutdown — a drain
///   that hopped back onto it would trap exactly when the last lines matter most.
final class PluginLogQueue: Sendable {
    private struct State {
        var lines: [String] = []
        var suppressed = 0
        var isDraining = false
        var isClosed = false
    }

    private let capacity: Int
    private let sink: @Sendable (String) async -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let drain = OSAllocatedUnfairLock(initialState: Task<Void, Never>?.none)

    init(capacity: Int = 512, sink: @escaping @Sendable (String) async -> Void) {
        self.capacity = capacity
        self.sink = sink
    }

    func append(_ line: String) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.isClosed else { return false }
            guard state.lines.count < capacity else {
                state.suppressed += 1
                return false
            }
            state.lines.append(line)
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldStart else { return }
        let task = Task.detached(priority: .utility) { [self] in
            while let line = next() {
                await sink(line)
            }
        }
        drain.withLock { $0 = task }
    }

    /// Delivers everything queued, then stops accepting more. Awaited during shutdown because
    /// the last thing a failing generation says is usually the most useful thing it said.
    func finish() async {
        let task = drain.withLock { $0 }
        await task?.value
        state.withLock { $0.isClosed = true }
    }

    private func next() -> String? {
        state.withLock { state -> String? in
            if state.lines.isEmpty {
                if state.suppressed > 0 {
                    let dropped = state.suppressed
                    state.suppressed = 0
                    return "\(dropped) log line(s) were dropped: "
                        + "this plugin logged faster than the host wrote"
                }
                state.isDraining = false
                return nil
            }
            return state.lines.removeFirst()
        }
    }
}

/// A finite, failure-aware handoff from Foundation callbacks to the runtime actor.
///
/// One wake-up is enough to drain every queued event. Repeating timer ticks for the same
/// handle coalesce while queued; every other callback either enters the mailbox or makes
/// overflow explicit. Overflow discards the partial batch so the runtime can fail the
/// generation instead of observing an unknowably incomplete lifecycle.
final class PluginRuntimeCallbackMailbox: Sendable {
    enum EnqueueResult: Sendable, Equatable {
        case enqueued
        case coalesced
        case overflowed
        case closed
    }

    struct Batch: Sendable {
        let events: [PluginRuntimeCallbackEvent]
        let overflowed: Bool
    }

    private struct State: Sendable {
        var events: [PluginRuntimeCallbackEvent] = []
        var queuedTimerHandles: Set<Int> = []
        var overflowed = false
        var closed = false
    }

    let notifications: AsyncStream<Void>

    private let capacity: Int
    private let notificationContinuation: AsyncStream<Void>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 256) {
        precondition(capacity >= 0, "callback mailbox capacity must be nonnegative")
        self.capacity = capacity
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        notifications = pair.stream
        notificationContinuation = pair.continuation
    }

    @discardableResult
    func enqueue(_ event: PluginRuntimeCallbackEvent) -> EnqueueResult {
        let outcome = state.withLock { state -> (EnqueueResult, shouldNotify: Bool) in
            guard !state.closed else { return (.closed, false) }
            guard !state.overflowed else { return (.overflowed, false) }

            if case let .timerFired(handle) = event,
               state.queuedTimerHandles.contains(handle)
            {
                return (.coalesced, false)
            }

            guard state.events.count < capacity else {
                state.events.removeAll(keepingCapacity: true)
                state.queuedTimerHandles.removeAll(keepingCapacity: true)
                state.overflowed = true
                return (.overflowed, true)
            }

            state.events.append(event)
            if case let .timerFired(handle) = event {
                state.queuedTimerHandles.insert(handle)
            }
            return (.enqueued, true)
        }
        if outcome.shouldNotify {
            notificationContinuation.yield()
        }
        return outcome.0
    }

    func drain() -> Batch {
        state.withLock { state in
            guard !state.overflowed else {
                return Batch(events: [], overflowed: true)
            }
            let events = state.events
            state.events.removeAll(keepingCapacity: true)
            state.queuedTimerHandles.removeAll(keepingCapacity: true)
            return Batch(events: events, overflowed: false)
        }
    }

    func close() {
        let shouldFinish = state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            state.events.removeAll(keepingCapacity: false)
            state.queuedTimerHandles.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish {
            notificationContinuation.finish()
        }
    }
}

/// Coalesces process output before it enters the actor. Readability callbacks can arrive
/// faster than JavaScript consumes them, so each process gets a byte budget and at most one
/// outstanding wake-up.
final class PluginProcessOutputMailbox: Sendable {
    struct Batch: Sendable {
        let stdout: Data
        let stderr: Data
        let overflowed: Bool
    }

    private struct ProcessBuffer: Sendable {
        var stdout = Data()
        var stderr = Data()
        var overflowed = false
        var notificationOutstanding = false
    }

    private let maximumBufferedBytesPerProcess: Int
    private let state = OSAllocatedUnfairLock(initialState: [Int: ProcessBuffer]())

    init(maximumBufferedBytesPerProcess: Int = 256 * 1_024) {
        self.maximumBufferedBytesPerProcess = maximumBufferedBytesPerProcess
    }

    func register(handle: Int) {
        state.withLock { $0[handle] = ProcessBuffer() }
    }

    func append(_ data: Data, isStandardError: Bool, handle: Int) -> Bool {
        guard !data.isEmpty else { return false }

        return state.withLock { state in
            guard var buffer = state[handle] else { return false }

            let currentBytes = buffer.stdout.count + buffer.stderr.count
            let available = max(0, maximumBufferedBytesPerProcess - currentBytes)
            if available < data.count {
                buffer.overflowed = true
            }
            if available > 0 {
                let prefix = data.prefix(available)
                if isStandardError {
                    buffer.stderr.append(contentsOf: prefix)
                } else {
                    buffer.stdout.append(contentsOf: prefix)
                }
            }

            let shouldNotify = !buffer.notificationOutstanding
            buffer.notificationOutstanding = true
            state[handle] = buffer
            return shouldNotify
        }
    }

    func drain(handle: Int) -> Batch? {
        state.withLock { state in
            guard var buffer = state[handle] else { return nil }
            let batch = Batch(
                stdout: buffer.stdout,
                stderr: buffer.stderr,
                overflowed: buffer.overflowed
            )
            buffer.stdout.removeAll(keepingCapacity: true)
            buffer.stderr.removeAll(keepingCapacity: true)
            buffer.notificationOutstanding = false
            state[handle] = buffer
            return batch
        }
    }

    func remove(handle: Int) {
        _ = state.withLock { $0.removeValue(forKey: handle) }
    }

    func removeAll() {
        state.withLock { $0.removeAll() }
    }
}

/// Prevents a provider binding from enqueueing actor work after executor shutdown begins.
final class PluginRuntimeInvocationGate: Sendable {
    private struct State {
        var isOpen = true
        var activeInvocations = 0
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquire() -> Bool {
        state.withLock { state in
            guard state.isOpen else { return false }
            state.activeInvocations += 1
            return true
        }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            precondition(state.activeInvocations > 0)
            state.activeInvocations -= 1
            guard !state.isOpen, state.activeInvocations == 0 else { return [] }
            let waiters = state.idleWaiters
            state.idleWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func close() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = false
            guard state.activeInvocations == 0 else { return [] }
            let waiters = state.idleWaiters
            state.idleWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                guard state.activeInvocations > 0 else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

/// Makes repeated concurrent `shutdown()` calls join one teardown operation.
final class PluginRuntimeLifecycle: Sendable {
    enum BeginResult {
        case owner
        case wait
        case complete(PluginRuntimeShutdownReport)
    }

    private struct State {
        var shutdownStarted = false
        var report: PluginRuntimeShutdownReport?
        var waiters: [CheckedContinuation<PluginRuntimeShutdownReport, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func beginShutdown() -> BeginResult {
        state.withLock { state in
            if let report = state.report {
                return .complete(report)
            }
            guard !state.shutdownStarted else { return .wait }
            state.shutdownStarted = true
            return .owner
        }
    }

    func waitForReport() async -> PluginRuntimeShutdownReport {
        await withCheckedContinuation { continuation in
            let report = state.withLock { state -> PluginRuntimeShutdownReport? in
                if let report = state.report {
                    return report
                }
                state.waiters.append(continuation)
                return nil
            }
            if let report {
                continuation.resume(returning: report)
            }
        }
    }

    func finish(_ report: PluginRuntimeShutdownReport) {
        let waiters = state.withLock { state -> [CheckedContinuation<PluginRuntimeShutdownReport, Never>] in
            precondition(state.report == nil)
            state.report = report
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: report)
        }
    }

    var hasCompletedShutdown: Bool {
        state.withLock { $0.report != nil }
    }
}

final class PluginProviderCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }
}

/// Delivers the latest snapshot without making JavaScriptCore wait on UI work.
final class PluginRuntimeStateEmitter: Sendable {
    private let continuation: AsyncStream<PluginRuntimeSnapshot>.Continuation
    private let task: Task<Void, Never>

    init(sink: @escaping PluginRuntimeConfiguration.StateChange) {
        let pair = AsyncStream<PluginRuntimeSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = pair.continuation
        task = Task.detached {
            for await snapshot in pair.stream {
                await sink(snapshot)
            }
        }
    }

    func emit(_ snapshot: PluginRuntimeSnapshot) {
        continuation.yield(snapshot)
    }

    func finish() async {
        continuation.finish()
        await task.value
    }
}
