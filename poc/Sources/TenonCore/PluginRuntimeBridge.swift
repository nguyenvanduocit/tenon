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
