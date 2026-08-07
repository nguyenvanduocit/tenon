import Darwin
import Foundation
import JavaScriptCore
import TenonIntentCore
import os

struct PluginRuntimeResourceCounts: Sendable, Equatable {
    let timers: Int
    let processes: Int
    let watchers: Int
}

/// Owns finite host operations started by one plugin generation. Registration uses a
/// pending marker so a very fast task cannot finish before its handle is published and
/// leave a completed task retained forever.
private final class PluginRuntimeTaskLedger: @unchecked Sendable {
    private struct State {
        var pending: Set<UUID> = []
        var tasks: [UUID: Task<Void, Never>] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    @discardableResult
    func launch(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        let id = UUID()
        guard lock.withLock({ state in
            guard state.pending.count + state.tasks.count < capacity else {
                return false
            }
            state.pending.insert(id)
            return true
        }) else { return false }

        let task = Task.detached(priority: priority) { [weak self] in
            await operation()
            self?.complete(id)
        }
        lock.withLock { state in
            if state.pending.remove(id) != nil {
                state.tasks[id] = task
            }
        }
        return true
    }

    func cancelAndDrain() async {
        let owned = lock.withLock { state in
            let tasks = Array(state.tasks.values)
            state.pending.removeAll()
            state.tasks.removeAll()
            return tasks
        }
        for task in owned { task.cancel() }
        for task in owned { await task.value }
    }

    private func complete(_ id: UUID) {
        lock.withLock { state in
            state.pending.remove(id)
            state.tasks.removeValue(forKey: id)
        }
    }
}

/// One plugin runtime, isolated onto one long-lived operating-system thread.
///
/// JavaScriptCore values never cross this actor boundary. The bridge copies JavaScript
/// values into `IntentValue` while still on the pinned thread, and every Foundation
/// callback carries only a `Sendable` snapshot through a finite callback mailbox.
public actor PluginRuntime {
    public nonisolated let manifest: PluginManifest
    public nonisolated let directory: URL

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private struct ViewRegistration {
        let title: String
        let instanced: Bool
    }

    private struct ViewBody {
        let items: [PluginRowItem]
        let body: PluginViewNode?
        let header: PaneHeader
        let modal: PluginViewModal?
    }

    private struct PendingProviderCall {
        let intentID: IntentID
        let context: IntentProviderContext
        let cancellation: PluginProviderCancellation
        let progress: ProviderProgressDelivery
        let continuation: CheckedContinuation<IntentProviderReply, any Error>
    }

    private struct ProviderProgressDelivery: Sendable {
        let continuation: AsyncStream<IntentProgress>.Continuation
        let task: Task<Void, Never>

        init(context: IntentProviderContext) {
            let pair = AsyncStream<IntentProgress>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            continuation = pair.continuation
            task = Task { @concurrent [stream = pair.stream] in
                for await progress in stream {
                    guard !Task.isCancelled else { return }
                    await context.reportProgress(progress)
                }
            }
        }

        func yield(_ progress: IntentProgress) {
            continuation.yield(progress)
        }

        func cancel() {
            continuation.finish()
            task.cancel()
        }
    }

    private struct PendingNestedIntent {
        let callToken: String
        let task: Task<Void, Never>
    }

    private struct ProcessResource {
        let process: Process
        let standardOutput: FileHandle
        let standardError: FileHandle
        var standardOutputEnded = false
        var standardErrorEnded = false
        var terminationStatus: Int32?
    }

    private struct TimerResource {
        let timer: Timer
        let repeats: Bool
    }

    private struct ShutdownPreparation {
        let callbackPump: Task<Void, Never>?
        let createdThreadIdentifier: UInt64?
        let destroyedThreadIdentifier: UInt64?
        let cancelledProviderCalls: Int
        let lateProviderReplyCount: Int
    }

    private static let singletonViewKey = ""
    private static let maximumPendingOutboundIntents = 256
    private static let maximumPendingStorageWrites = 256
    private static let maximumTimers = 256
    private static let maximumProcesses = 32
    private static let maximumWatchers = 64
    private static let maximumBridgeMessagesPerDrain = 8_192
    private static let maximumPendingCallbacks = 256
    private static let maximumOwnedHostTasks = 512
    private static let maximumPaletteProviders = 8
    private static let maximumPaletteResults = 50
    private static let maximumPaletteActions = 8
    private static let maximumPaletteTextLength = 256

    private let configuration: PluginRuntimeConfiguration
    private let executor: PinnedThreadExecutor
    private let javaScriptMailbox = PluginJavaScriptMailbox()
    private let processOutputMailbox = PluginProcessOutputMailbox()
    private let callbackMailbox: PluginRuntimeCallbackMailbox
    private let invocationGate = PluginRuntimeInvocationGate()
    private let lifecycle = PluginRuntimeLifecycle()
    private let hostTasks = PluginRuntimeTaskLedger(
        capacity: maximumOwnedHostTasks
    )
    private let stateEmitter: PluginRuntimeStateEmitter
    private let processRun: @Sendable (Process) throws -> Void
    private let watcherStart: @Sendable (PathWatcher) -> Bool

    private var callbackPump: Task<Void, Never>?
    private var virtualMachine: JSVirtualMachine?
    private var context: JSContext?
    private var phase: PluginRuntimePhase = .initialized
    private var revision: UInt64 = 0
    private var createdThreadIdentifier: UInt64?
    private var destroyedThreadIdentifier: UInt64?

    private var boundIntentIDs: Set<IntentID> = []
    private var pendingProviderCalls: [String: PendingProviderCall] = [:]
    private var pendingOutboundIntentTokens: Set<String> = []
    /// T-049: published facts handed to the host and not yet settled. Bounds a plugin that
    /// publishes in a loop.
    private var pendingPublishedEvents = 0
    private var pendingIntentListTokens: Set<String> = []
    private var pendingNestedIntents: [String: PendingNestedIntent] = [:]
    private var pendingStorageTokens: Set<String> = []
    private var storageCommitTail: Task<Void, Never>?
    private var lateProviderReplyCount = 0

    private var statusBarText: String?
    private let eventSubscriptions = OSAllocatedUnfairLock(
        initialState: Set<String>()
    )
    private var permissionViolationSet: Set<String> = []
    private var permissionViolations: [String] = []

    private var viewRegistrations: [String: ViewRegistration] = [:]
    private var viewBodies: [String: [String: ViewBody]] = [:]
    private var openViewInstances: Set<PluginViewInstanceKey> = []

    /// Palette provider contributions, keyed by provider ID. `deliveredRevision` is the
    /// newest query revision handed to this generation; a publication for any other
    /// revision answers a question the user is no longer asking and is dropped here.
    private struct PaletteProviderState {
        var title: String
        var deliveredRevision = 0
        var publishedRevision = 0
        var results: [PaletteResultItem] = []
    }

    private var paletteProviderStates: [String: PaletteProviderState] = [:]

    private var timers: [Int: TimerResource] = [:]
    private var processes: [Int: ProcessResource] = [:]
    private var watchers: [Int: PathWatcher] = [:]

    public init(configuration: PluginRuntimeConfiguration) throws {
        try self.init(
            configuration: configuration,
            callbackCapacity: Self.maximumPendingCallbacks
        )
    }

    init(
        configuration: PluginRuntimeConfiguration,
        callbackCapacity: Int,
        processRun: @escaping @Sendable (Process) throws -> Void = {
            try $0.run()
        },
        watcherStart: @escaping @Sendable (PathWatcher) -> Bool = {
            $0.start()
        }
    ) throws {
        self.configuration = configuration
        manifest = configuration.manifest
        directory = configuration.directory
        self.processRun = processRun
        self.watcherStart = watcherStart
        executor = try PinnedThreadExecutor(
            name: "dev.tenon.plugin.\(configuration.manifest.id.rawValue)",
            startupTimeout: configuration.startupTimeout
        )
        callbackMailbox = PluginRuntimeCallbackMailbox(capacity: callbackCapacity)
        stateEmitter = PluginRuntimeStateEmitter(sink: configuration.onStateChange)
    }

    /// Creates the VM/context, evaluates the plugin, validates all declared bindings, and
    /// returns bindings suitable for an unpublished provider generation.
    public func start() throws -> PluginRuntimeStartResult {
        guard phase == .initialized else {
            throw PluginRuntimeError.invalidLifecycle(expected: .initialized, actual: phase)
        }

        phase = .staging
        createdThreadIdentifier = Self.currentThreadIdentifier()
        startCallbackPump()

        do {
            let entrypoint = PluginLoader.entrypoint(for: directory)
            guard let source = try? String(contentsOf: entrypoint, encoding: .utf8) else {
                throw PluginLoadError.entrypointMissing(entrypoint.path)
            }

            let machine = JSVirtualMachine()
            guard let javaScriptContext = JSContext(virtualMachine: machine) else {
                throw PluginRuntimeError.javascriptContextUnavailable
            }
            virtualMachine = machine
            context = javaScriptContext

            installNativeBridge(in: javaScriptContext)
            javaScriptContext.evaluateScript(PluginRuntimeBootstrap.source)
            try drainBridgeMessages()

            _ = try callJavaScript(
                "__tenonStart",
                arguments: [
                    PluginRuntimeValueParsing.foundationObject(from: bootstrapConfiguration())
                ]
            )
            try drainBridgeMessages()

            javaScriptContext.evaluateScript(
                source,
                withSourceURL: entrypoint
            )
            try drainBridgeMessages()

            let expected = Set(manifest.intents.provides.map(\.name))
            let missing = expected.subtracting(boundIntentIDs)
            guard missing.isEmpty else {
                throw PluginRuntimeError.missingIntentHandlers(
                    missing.sorted { $0.rawValue < $1.rawValue }
                )
            }

            _ = try callJavaScript("__tenonActivate")
            try drainBridgeMessages()
            phase = .active
            markStateChanged()

            let bindings = expected
                .sorted { $0.rawValue < $1.rawValue }
                .map(makeBinding(for:))
            return PluginRuntimeStartResult(bindings: bindings, snapshot: makeSnapshot())
        } catch {
            phase = .failed
            stopOwnedResources()
            callbackMailbox.close()
            releaseJavaScriptResources()
            markStateChanged()
            throw error
        }
    }

    /// Immutable state for UI aggregation and diagnostics.
    public func snapshot() -> PluginRuntimeSnapshot {
        makeSnapshot()
    }

    var resourceCounts: PluginRuntimeResourceCounts {
        PluginRuntimeResourceCounts(
            timers: timers.count,
            processes: processes.count,
            watchers: watchers.count
        )
    }

    public nonisolated func handles(event: String) async -> Bool {
        eventSubscriptions.withLock { $0.contains(event) }
    }

    public func isViewInstanced(_ viewID: String) -> Bool {
        viewRegistrations[viewID]?.instanced ?? false
    }

    public func emit(event: String, payload: IntentValue) throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        _ = try callJavaScript(
            "__tenonEmit",
            arguments: [
                event,
                PluginRuntimeValueParsing.foundationObject(from: payload),
            ]
        )
        try drainBridgeMessages()
    }

    @discardableResult
    public func invokeViewSelect(
        viewID: String,
        instanceID: String? = nil,
        itemID: String,
        value: IntentValue? = nil
    ) throws -> Bool {
        try callJavaScriptBool(
            "__tenonViewSelect",
            arguments: [
                viewID,
                instanceID ?? NSNull(),
                decodeActionIdentifier(itemID),
                value.map(PluginRuntimeValueParsing.foundationObject(from:)) ?? NSNull(),
            ]
        )
    }

    @discardableResult
    public func invokeViewSubmit(
        viewID: String,
        instanceID: String? = nil,
        itemID: String,
        text: String
    ) throws -> Bool {
        try callJavaScriptBool(
            "__tenonViewSubmit",
            arguments: [viewID, instanceID ?? NSNull(), decodeActionIdentifier(itemID), text]
        )
    }

    public func openViewInstance(viewID: String, instanceID: String) throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard viewRegistrations[viewID]?.instanced == true else { return }
        let key = PluginViewInstanceKey(viewID: viewID, instanceID: instanceID)
        guard openViewInstances.insert(key).inserted else { return }
        _ = try callJavaScript("__tenonViewOpen", arguments: [viewID, instanceID])
        try drainBridgeMessages()
        markStateChanged()
    }

    /// Hands one palette query fact to every registered provider of this generation.
    ///
    /// EVENT delivery: fire-and-forget onto this runtime's own pinned thread. The host
    /// never awaits the JavaScript handler — a provider that dawdles or never answers
    /// leaves its `publishedRevision` behind and simply stays pending; nothing upstream
    /// blocks. The invocation gate is the same one provider bindings take: a keystroke
    /// racing this generation's retirement is refused here instead of enqueueing onto a
    /// stopped executor.
    public nonisolated func deliverPaletteQuery(
        text: String,
        revision: Int
    ) async {
        guard invocationGate.acquire() else { return }
        defer { invocationGate.release() }
        await performPaletteQueryDelivery(text: text, revision: revision)
    }

    /// Recording `deliveredRevision` before invoking JavaScript is what lets
    /// `setPaletteResults` reject a publication for a superseded query (keystroke N+1
    /// cancels keystroke N). A bridge failure marks this runtime failed, exactly like
    /// every other callback path — the host stays alive.
    private func performPaletteQueryDelivery(text: String, revision: Int) {
        guard phase == .active, !paletteProviderStates.isEmpty else { return }
        let bounded = String(text.prefix(Self.maximumPaletteTextLength))
        do {
            for providerID in paletteProviderStates.keys.sorted() {
                paletteProviderStates[providerID]?.deliveredRevision = revision
                _ = try callJavaScript(
                    "__tenonPaletteQuery",
                    arguments: [providerID, bounded, revision]
                )
            }
            try drainBridgeMessages()
            markStateChanged()
        } catch {
            emitLog("palette query bridge error: \(error)")
            transitionToFailed(error)
        }
    }

    public func closeViewInstance(viewID: String, instanceID: String) throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        let key = PluginViewInstanceKey(viewID: viewID, instanceID: instanceID)
        guard openViewInstances.remove(key) != nil else { return }
        _ = try callJavaScript("__tenonViewClose", arguments: [viewID, instanceID])
        try drainBridgeMessages()
        viewBodies[viewID]?[instanceID] = nil
        markStateChanged()
    }

    /// Testing/diagnostic hook that preserves the runtime boundary: only an owned JSON value
    /// is returned, never `JSValue`.
    public func evaluateForTesting(_ script: String) throws -> IntentValue {
        guard phase == .staging || phase == .active,
              let context
        else {
            throw PluginRuntimeError.runtimeStopped
        }
        guard let value = context.evaluateScript(script) else {
            try drainBridgeMessages()
            throw PluginRuntimeError.javascriptException("evaluation returned no value")
        }
        let result = try PluginJavaScriptValueDecoder.decode(value)
        try drainBridgeMessages()
        return result
    }

    /// Explicit teardown is part of the runtime contract. It first closes provider
    /// admission, settles active calls, destroys JSC on its owning thread, and only then
    /// stops the executor. Concurrent calls join the same operation.
    public nonisolated func shutdown(
        timeout: TimeInterval = 2
    ) async -> PluginRuntimeShutdownReport {
        switch lifecycle.beginShutdown() {
        case let .complete(report):
            return report
        case .wait:
            return await lifecycle.waitForReport()
        case .owner:
            break
        }

        invocationGate.close()
        let preparation = await prepareForShutdown()
        if let callbackPump = preparation.callbackPump {
            await callbackPump.value
        }
        await invocationGate.waitUntilIdle()
        await stateEmitter.finish()
        let executorResult = await executor.shutdown(timeout: timeout)
        let report = PluginRuntimeShutdownReport(
            executorResult: executorResult,
            createdThreadIdentifier: preparation.createdThreadIdentifier,
            destroyedThreadIdentifier: preparation.destroyedThreadIdentifier,
            cancelledProviderCalls: preparation.cancelledProviderCalls,
            lateProviderReplyCount: preparation.lateProviderReplyCount
        )
        lifecycle.finish(report)
        return report
    }

    deinit {
        precondition(
            lifecycle.hasCompletedShutdown,
            "PluginRuntime requires explicit await shutdown() before its last release"
        )
    }
}

// MARK: - JavaScript lifecycle

private extension PluginRuntime {
    func startCallbackPump() {
        guard callbackPump == nil else { return }
        let mailbox = callbackMailbox
        let notifications = mailbox.notifications
        callbackPump = Task.detached { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                let batch = mailbox.drain()
                if batch.overflowed {
                    await self.transitionToFailed(
                        PluginRuntimeError.resourceLimitExceeded("runtime callbacks")
                    )
                    return
                }
                for event in batch.events {
                    await self.consumeCallback(event)
                }
            }
        }
    }

    func installNativeBridge(in context: JSContext) {
        let mailbox = javaScriptMailbox
        let nativePost: @convention(block) (String, JSValue) -> Void = { topic, value in
            mailbox.post(topic: topic, value: value)
        }
        context.setObject(nativePost, forKeyedSubscript: "__tenonNativePost" as NSString)
        context.exceptionHandler = { _, exception in
            mailbox.postProtocolError(
                "JavaScript exception: \(exception?.toString() ?? "unknown")"
            )
        }
    }

    func bootstrapConfiguration() -> IntentValue {
        .object([
            "pluginID": .string(manifest.id.rawValue),
            "uses": .array(manifest.intents.uses.map { .string($0.rawValue) }),
            "provides": .array(manifest.intents.provides.map { .string($0.name.rawValue) }),
            "settings": .object(configuration.local.settings),
            "storage": .object(configuration.local.storage),
        ])
    }

    @discardableResult
    func callJavaScript(
        _ functionName: String,
        arguments: [Any] = []
    ) throws -> JSValue {
        guard let context,
              let function = context.objectForKeyedSubscript(functionName),
              function.isObject,
              !function.isUndefined,
              !function.isNull,
              let result = function.call(withArguments: arguments)
        else {
            throw PluginRuntimeError.javascriptException(
                "\(functionName) is unavailable"
            )
        }
        return result
    }

    func callJavaScriptBool(
        _ functionName: String,
        arguments: [Any]
    ) throws -> Bool {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        let value = try callJavaScript(functionName, arguments: arguments)
        let result = value.toBool()
        try drainBridgeMessages()
        return result
    }

    func releaseJavaScriptResources() {
        context?.exceptionHandler = nil
        context = nil
        virtualMachine = nil
        destroyedThreadIdentifier = Self.currentThreadIdentifier()
    }

    private func prepareForShutdown() async -> ShutdownPreparation {
        if phase == .stopped {
            return ShutdownPreparation(
                callbackPump: callbackPump,
                createdThreadIdentifier: createdThreadIdentifier,
                destroyedThreadIdentifier: destroyedThreadIdentifier,
                cancelledProviderCalls: 0,
                lateProviderReplyCount: lateProviderReplyCount
            )
        }

        phase = .stopping
        _ = try? callJavaScript("__tenonBeginShutdown")

        stopOwnedResources()

        // No generation-owned host effect may finish after retirement. Cancellation
        // requests stop cooperative work; the join makes even a late result part of
        // this generation's shutdown rather than the next generation's lifetime.
        await hostTasks.cancelAndDrain()

        let pending = pendingProviderCalls
        pendingProviderCalls.removeAll()
        cancelAllNestedIntents()
        for (callToken, call) in pending {
            call.cancellation.cancel()
            call.progress.cancel()
            _ = try? callJavaScript("__tenonCancelProvider", arguments: [callToken])
            call.continuation.resume(throwing: CancellationError())
        }

        // Storage writes are FIFO and commit-then-publish. After the JavaScript
        // phase enters stopping no new write is admitted, so awaiting the tail
        // drains every accepted local persistence operation before teardown.
        await storageCommitTail?.value
        storageCommitTail = nil

        _ = try? callJavaScript("__tenonShutdown")
        do {
            try drainBridgeMessages()
        } catch {
            emitLog("shutdown bridge error: \(error)")
        }

        pendingOutboundIntentTokens.removeAll()
        pendingIntentListTokens.removeAll()
        pendingStorageTokens.removeAll()
        callbackMailbox.close()
        callbackPump?.cancel()
        releaseJavaScriptResources()
        phase = .stopped
        markStateChanged()

        return ShutdownPreparation(
            callbackPump: callbackPump,
            createdThreadIdentifier: createdThreadIdentifier,
            destroyedThreadIdentifier: destroyedThreadIdentifier,
            cancelledProviderCalls: pending.count,
            lateProviderReplyCount: lateProviderReplyCount
        )
    }

    func stopOwnedResources() {
        eventSubscriptions.withLock { $0.removeAll() }

        for resource in timers.values {
            resource.timer.invalidate()
        }
        timers.removeAll()

        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()

        for resource in processes.values {
            resource.standardOutput.readabilityHandler = nil
            resource.standardError.readabilityHandler = nil
            resource.process.terminationHandler = nil
            if resource.process.isRunning {
                resource.process.terminate()
            }
            try? resource.standardOutput.close()
            try? resource.standardError.close()
        }
        processes.removeAll()
        processOutputMailbox.removeAll()
    }

    static func currentThreadIdentifier() -> UInt64 {
        var identifier: UInt64 = 0
        pthread_threadid_np(nil, &identifier)
        return identifier
    }
}

// MARK: - Provider bindings

private extension PluginRuntime {
    func makeBinding(for intentID: IntentID) -> IntentProviderBinding {
        let runtime = self
        let gate = invocationGate
        let callbackMailbox = callbackMailbox

        return IntentProviderBinding(intentID: intentID) { [weak runtime] envelope, context in
            guard gate.acquire() else {
                return .failure(IntentProviderFailure(code: .kernel(.providerRetired)))
            }
            defer { gate.release() }

            guard let runtime else {
                return .failure(IntentProviderFailure(code: .kernel(.providerRetired)))
            }

            let callToken = envelope.requestID.uuidString
            let cancellation = PluginProviderCancellation()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await runtime.invokeProvider(
                    callToken: callToken,
                    envelope: envelope,
                    context: context,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
                callbackMailbox.enqueue(.cancelProvider(callToken: callToken))
            }
        }
    }

    func invokeProvider(
        callToken: String,
        envelope: IntentEnvelope,
        context providerContext: IntentProviderContext,
        cancellation: PluginProviderCancellation
    ) async throws -> IntentProviderReply {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard boundIntentIDs.contains(envelope.name) else {
            throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
        }
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingProviderCalls[callToken] = PendingProviderCall(
                intentID: envelope.name,
                context: providerContext,
                cancellation: cancellation,
                progress: ProviderProgressDelivery(context: providerContext),
                continuation: continuation
            )

            do {
                let accepted = try callJavaScript(
                    "__tenonInvokeProvider",
                    arguments: [
                        callToken,
                        envelope.name.rawValue,
                        PluginRuntimeValueParsing.foundationObject(from: envelope.input),
                        PluginRuntimeValueParsing.foundationObject(
                            from: providerMetadata(envelope)
                        ),
                    ]
                ).toBool()
                guard accepted else {
                    failProviderCall(
                        callToken,
                        error: PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                    )
                    return
                }
                try drainBridgeMessages()
                if cancellation.isCancelled {
                    cancelProviderCall(callToken)
                }
            } catch {
                failProviderCall(callToken, error: error)
            }
        }
    }

    func providerMetadata(_ envelope: IntentEnvelope) -> IntentValue {
        var scope: [String: IntentValue] = [:]
        if let workspaceID = envelope.scope.workspaceID {
            scope["workspaceID"] = .string(workspaceID.uuidString)
        }
        if let paneID = envelope.scope.paneID {
            scope["paneID"] = .string(paneID.uuidString)
        }
        if let userGestureID = envelope.scope.userGestureID {
            scope["userGestureID"] = .string(userGestureID.uuidString)
        }

        return .object([
            "requestID": .string(envelope.requestID.uuidString),
            "caller": .object([
                "id": .string(envelope.caller.id),
                "kind": .string(envelope.caller.kind.rawValue),
                "audience": .string(envelope.caller.audience.rawValue),
                "sessionRevision": envelope.caller.sessionRevision > UInt64(Int64.max)
                    ? .number(Double(envelope.caller.sessionRevision))
                    : .integer(Int64(envelope.caller.sessionRevision)),
            ]),
            "scope": .object(scope),
        ])
    }

    func failProviderCall(_ callToken: String, error: any Error) {
        guard let pending = pendingProviderCalls.removeValue(forKey: callToken) else {
            lateProviderReplyCount += 1
            return
        }
        pending.cancellation.cancel()
        pending.progress.cancel()
        cancelNestedIntents(for: callToken)
        do {
            _ = try callJavaScript("__tenonCancelProvider", arguments: [callToken])
        } catch {
            pending.continuation.resume(throwing: error)
            transitionToFailed(error)
            return
        }
        pending.continuation.resume(throwing: error)
    }

    func cancelProviderCall(_ callToken: String) {
        guard let pending = pendingProviderCalls.removeValue(forKey: callToken) else {
            return
        }
        pending.cancellation.cancel()
        pending.progress.cancel()
        cancelNestedIntents(for: callToken)
        do {
            _ = try callJavaScript("__tenonCancelProvider", arguments: [callToken])
        } catch {
            pending.continuation.resume(throwing: error)
            transitionToFailed(error)
            return
        }
        pending.continuation.resume(throwing: CancellationError())
    }

    func cancelNestedIntents(for callToken: String) {
        let tokens = pendingNestedIntents.compactMap { token, pending in
            pending.callToken == callToken ? token : nil
        }
        for token in tokens {
            pendingNestedIntents.removeValue(forKey: token)?.task.cancel()
        }
    }

    func cancelAllNestedIntents() {
        let tasks = pendingNestedIntents.values.map(\.task)
        pendingNestedIntents.removeAll()
        for task in tasks {
            task.cancel()
        }
    }
}

// MARK: - Bridge messages

private extension PluginRuntime {
    func drainBridgeMessages() throws {
        var handledCount = 0
        while true {
            let drained = javaScriptMailbox.drain()
            if let error = drained.errors.first {
                throw PluginRuntimeError.javascriptException(error)
            }
            guard !drained.messages.isEmpty else { return }

            handledCount += drained.messages.count
            guard handledCount <= Self.maximumBridgeMessagesPerDrain else {
                throw PluginRuntimeError.resourceLimitExceeded("bridge messages per turn")
            }
            for message in drained.messages {
                guard message.threadIdentifier == executor.threadIdentifier else {
                    throw PluginRuntimeError.bridgeProtocolViolation(
                        "JavaScript callback arrived on a foreign thread"
                    )
                }
                try handleJavaScriptMessage(message)
            }
        }
    }

    func handleJavaScriptMessage(_ message: PluginJavaScriptMessage) throws {
        guard let object = message.payload.objectValue else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "\(message.topic) payload must be an object"
            )
        }

        switch message.topic {
        case "log":
            emitLog(object["message"]?.stringValue ?? "")
        case "runtime.fatal":
            throw PluginRuntimeError.bridgeProtocolViolation(
                object["reason"]?.stringValue ?? "fatal JavaScript runtime violation"
            )

        case "intent.bind":
            try bindIntent(object)
        case "intent.send":
            try sendIntent(object)
        case "intent.list":
            listIntents(object)
        case "provider.send":
            try sendNestedIntent(object)
        case "provider.progress":
            reportProviderProgress(object)
        case "provider.reply":
            settleProviderReply(object)

        case "event.bind":
            if let name = object["name"]?.stringValue {
                eventSubscriptions.withLock { subscriptions in
                    _ = subscriptions.insert(name)
                }
            }
        case "event.emit":
            try publishEvent(object)
        case "event.unbind":
            if let name = object["name"]?.stringValue {
                eventSubscriptions.withLock { subscriptions in
                    _ = subscriptions.remove(name)
                }
            }

        case "timer.start":
            try startTimer(object)
        case "timer.cancel":
            if let handle = object["handle"]?.intValue {
                timers.removeValue(forKey: handle)?.timer.invalidate()
            }

        case "process.start":
            startProcess(object)
        case "process.cancel":
            if let handle = object["handle"]?.intValue {
                cancelProcess(handle)
            }

        case "watch.start":
            startWatcher(object)
        case "watch.cancel":
            if let handle = object["handle"]?.intValue {
                watchers.removeValue(forKey: handle)?.stop()
            }

        case "storage.set":
            try persistStorage(object)
        case "status.set":
            statusBarText = object["text"]?.stringValue
            markStateChanged()
        case "view.register":
            registerView(object)
        case "view.set":
            setViewBody(object)
        case "palette.register":
            try registerPaletteProvider(object)
        case "palette.results":
            setPaletteResults(object)

        default:
            throw PluginRuntimeError.bridgeProtocolViolation(
                "unknown bridge topic \(message.topic)"
            )
        }
    }

    func bindIntent(_ object: [String: IntentValue]) throws {
        guard phase == .staging else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "intent handlers may bind only during staging"
            )
        }
        guard let rawName = object["name"]?.stringValue else {
            throw PluginRuntimeError.bridgeProtocolViolation("intent.bind missing name")
        }
        let intentID = try IntentID(rawName)
        guard manifest.intents.provides.contains(where: { $0.name == intentID }) else {
            throw PluginRuntimeError.undeclaredIntentHandler(intentID)
        }
        guard boundIntentIDs.insert(intentID).inserted else {
            throw PluginRuntimeError.duplicateIntentHandler(intentID)
        }
    }

    func sendIntent(_ object: [String: IntentValue]) throws {
        guard let token = object["token"]?.stringValue else {
            throw PluginRuntimeError.bridgeProtocolViolation("intent.send missing token")
        }
        guard pendingOutboundIntentTokens.count < Self.maximumPendingOutboundIntents else {
            _ = try callJavaScript(
                "__tenonSettleIntent",
                arguments: [
                    token,
                    PluginRuntimeValueParsing.foundationObject(
                        from: Self.overloadedResultValue()
                    ),
                ]
            )
            return
        }
        let request = try PluginRuntimeValueParsing.intentRequest(
            name: object["name"],
            input: object["input"],
            options: object["options"]
        )
        pendingOutboundIntentTokens.insert(token)

        let send = configuration.intents.send
        let callback = callbackMailbox
        let launched = hostTasks.launch(priority: Task.currentPriority) {
            let result = await send(request)
            callback.enqueue(.intentResult(token: token, result: result))
        }
        if !launched {
            pendingOutboundIntentTokens.remove(token)
            _ = try? callJavaScript(
                "__tenonSettleIntent",
                arguments: [
                    token,
                    PluginRuntimeValueParsing.foundationObject(
                        from: Self.overloadedResultValue()
                    ),
                ]
            )
        }
    }

    /// A fact this plugin published (T-049).
    ///
    /// Fail-closed on the manifest: publishing a channel the plugin did not declare is
    /// refused here, so naming a channel never grants the right to publish on it
    /// (invariant 5). Only the LOCAL name crosses — the host owns qualification, which is
    /// why a plugin cannot name `automation.fired` or another plugin's channel.
    ///
    /// Bounded (invariant 10): a plugin publishing in a loop is capped at the same
    /// in-flight limit as its outbound intents, and the overflow is dropped with a log
    /// rather than queued. A fact nobody can deliver is not worth unbounded memory.
    func publishEvent(_ object: [String: IntentValue]) throws {
        guard let name = object["name"]?.stringValue else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "event.emit missing name"
            )
        }
        guard configuration.manifest.events?.publishes.contains(name) == true else {
            throw PluginRuntimeError.undeclaredEventPublication(name)
        }
        guard pendingPublishedEvents < Self.maximumPendingOutboundIntents else {
            emitLog(
                "tenon.events.emit dropped \(name): too many events in flight"
            )
            return
        }
        let payload = object["payload"] ?? .null
        pendingPublishedEvents += 1
        let publish = configuration.publishEvent
        let callback = callbackMailbox
        let launched = hostTasks.launch(priority: Task.currentPriority) {
            await publish(name, payload)
            callback.enqueue(.publishedEventSettled)
        }
        if !launched { pendingPublishedEvents -= 1 }
    }

    func listIntents(_ object: [String: IntentValue]) {
        guard let token = object["token"]?.stringValue else { return }
        guard pendingIntentListTokens.count < Self.maximumPendingOutboundIntents else {
            _ = try? callJavaScript(
                "__tenonSettleList",
                arguments: [token, []]
            )
            return
        }
        pendingIntentListTokens.insert(token)
        let list = configuration.intents.list
        let callback = callbackMailbox
        let launched = hostTasks.launch(priority: Task.currentPriority) {
            let result = await list()
            callback.enqueue(.intentList(token: token, value: result))
        }
        if !launched {
            pendingIntentListTokens.remove(token)
            _ = try? callJavaScript("__tenonSettleList", arguments: [token, []])
        }
    }

    func sendNestedIntent(_ object: [String: IntentValue]) throws {
        guard let callToken = object["callToken"]?.stringValue,
              let token = object["token"]?.stringValue,
              let pending = pendingProviderCalls[callToken]
        else {
            return
        }
        guard !pending.cancellation.isCancelled else {
            cancelProviderCall(callToken)
            return
        }
        let request = try PluginRuntimeValueParsing.intentRequest(
            name: object["name"],
            input: object["input"],
            options: object["options"]
        )
        guard pendingNestedIntents.count < Self.maximumPendingOutboundIntents else {
            _ = try callJavaScript(
                "__tenonSettleNestedIntent",
                arguments: [
                    token,
                    PluginRuntimeValueParsing.foundationObject(
                        from: Self.overloadedResultValue()
                    ),
                ]
            )
            return
        }
        let coreRequest = IntentProviderSendRequest(
            intentID: request.intentID,
            input: request.input,
            target: request.target,
            idempotencyKey: request.idempotencyKey,
            requestedTimeout: request.requestedTimeout,
            scopeOverride: request.scopeOverride
        )
        let providerContext = pending.context
        let cancellation = pending.cancellation
        let callback = callbackMailbox
        // The synchronous JavaScript bridge cannot await this operation. The runtime actor
        // therefore owns the task handle until completion or outer-call termination.
        let task = Task {
            let result = await providerContext.send(coreRequest)
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            callback.enqueue(
                .nestedIntentResult(
                    callToken: callToken,
                    token: token,
                    result: result
                )
            )
        }
        pendingNestedIntents[token] = PendingNestedIntent(
            callToken: callToken,
            task: task
        )
        if pending.cancellation.isCancelled {
            cancelProviderCall(callToken)
        }
    }

    func reportProviderProgress(_ object: [String: IntentValue]) {
        guard let callToken = object["callToken"]?.stringValue,
              let pending = pendingProviderCalls[callToken],
              let progress = PluginRuntimeValueParsing.progress(from: object["progress"])
        else {
            return
        }
        pending.progress.yield(progress)
    }

    func settleProviderReply(_ object: [String: IntentValue]) {
        guard let callToken = object["callToken"]?.stringValue else { return }
        guard let pending = pendingProviderCalls.removeValue(forKey: callToken) else {
            lateProviderReplyCount += 1
            markStateChanged()
            return
        }
        pending.progress.cancel()
        cancelNestedIntents(for: callToken)
        guard !pending.cancellation.isCancelled else {
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        if object["ok"]?.boolValue == true {
            pending.continuation.resume(returning: .success(object["value"] ?? .null))
        } else {
            pending.continuation.resume(
                returning: .failure(
                    PluginRuntimeValueParsing.providerFailure(from: object["error"])
                )
            )
        }
    }
}

// MARK: - External callback delivery

private extension PluginRuntime {
    func consumeCallback(_ event: PluginRuntimeCallbackEvent) {
        guard phase == .staging || phase == .active else { return }

        do {
            switch event {
            case let .intentResult(token, result):
                guard pendingOutboundIntentTokens.remove(token) != nil else { return }
                _ = try callJavaScript(
                    "__tenonSettleIntent",
                    arguments: [
                        token,
                        PluginRuntimeValueParsing.foundationObject(
                            from: PluginRuntimeValueParsing.intentResultValue(result)
                        ),
                    ]
                )

            case let .intentList(token, value):
                guard pendingIntentListTokens.remove(token) != nil else { return }
                _ = try callJavaScript(
                    "__tenonSettleList",
                    arguments: [
                        token,
                        PluginRuntimeValueParsing.foundationObject(from: value),
                    ]
                )

            case .publishedEventSettled:
                // Nothing to hand back to JavaScript: a published fact has no reply, by
                // definition. This only frees the in-flight slot.
                pendingPublishedEvents = max(0, pendingPublishedEvents - 1)

            case let .nestedIntentResult(callToken, token, result):
                guard let pending = pendingNestedIntents[token],
                      pending.callToken == callToken
                else {
                    return
                }
                pendingNestedIntents.removeValue(forKey: token)
                guard let providerCall = pendingProviderCalls[callToken] else {
                    lateProviderReplyCount += 1
                    markStateChanged()
                    return
                }
                guard !providerCall.cancellation.isCancelled else {
                    cancelProviderCall(callToken)
                    return
                }
                _ = try callJavaScript(
                    "__tenonSettleNestedIntent",
                    arguments: [
                        token,
                        PluginRuntimeValueParsing.foundationObject(
                            from: PluginRuntimeValueParsing.intentResultValue(result)
                        ),
                    ]
                )

            case let .cancelProvider(callToken):
                cancelProviderCall(callToken)

            case let .timerFired(handle):
                guard timers[handle] != nil else { return }
                let stillRegistered = try callJavaScript(
                    "__tenonFireTimer",
                    arguments: [handle]
                ).toBool()
                if !stillRegistered {
                    timers.removeValue(forKey: handle)?.timer.invalidate()
                } else if timers[handle]?.repeats == false {
                    timers.removeValue(forKey: handle)?.timer.invalidate()
                }

            case let .processOutputAvailable(handle):
                deliverProcessOutput(handle)

            case let .processEndOfFile(handle, isStandardError):
                markProcessEndOfFile(handle, isStandardError: isStandardError)

            case let .processTerminated(handle, status):
                markProcessTerminated(handle, status: status)

            case let .watchedPaths(handle, paths):
                guard watchers[handle] != nil else { return }
                _ = try callJavaScript(
                    "__tenonWatchPaths",
                    arguments: [handle, paths]
                )

            case let .watchOverflow(handle):
                guard watchers[handle] != nil else { return }
                throw PluginRuntimeError.resourceLimitExceeded(
                    "pending paths for watcher \(handle)"
                )
            }

            try drainBridgeMessages()
        } catch {
            emitLog("callback bridge error: \(error)")
            transitionToFailed(error)
        }
    }

    func transitionToFailed(_ error: any Error) {
        guard phase == .active || phase == .staging else { return }
        phase = .failed
        stopOwnedResources()
        callbackMailbox.close()
        let pending = pendingProviderCalls
        pendingProviderCalls.removeAll()
        cancelAllNestedIntents()
        for (callToken, call) in pending {
            call.cancellation.cancel()
            call.progress.cancel()
            _ = try? callJavaScript("__tenonCancelProvider", arguments: [callToken])
            call.continuation.resume(throwing: error)
        }
        releaseJavaScriptResources()
        markStateChanged()
    }
}

// MARK: - Timers, processes, and file watches

private extension PluginRuntime {
    func startTimer(_ object: [String: IntentValue]) throws {
        guard let handle = object["handle"]?.intValue,
              let milliseconds = object["milliseconds"]?.doubleValue,
              milliseconds.isFinite,
              milliseconds >= 0
        else {
            throw PluginRuntimeError.bridgeProtocolViolation("invalid timer.start")
        }
        let repeats = object["repeats"]?.boolValue ?? false
        guard !repeats || milliseconds >= 10 else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "repeating timer interval must be at least 10 milliseconds"
            )
        }
        guard timers.count < Self.maximumTimers else {
            throw PluginRuntimeError.resourceLimitExceeded("timers")
        }
        let callback = callbackMailbox
        let timer = Timer(timeInterval: max(0.001, milliseconds / 1_000), repeats: repeats) {
            _ in
            callback.enqueue(.timerFired(handle: handle))
        }
        RunLoop.current.add(timer, forMode: .common)
        timers[handle] = TimerResource(timer: timer, repeats: repeats)
    }

    func startProcess(_ object: [String: IntentValue]) {
        guard let handle = object["handle"]?.intValue else {
            emitLog("tenon.process.stream rejected: invalid process handle")
            return
        }
        guard manifest.permissions.contains("process.exec") else {
            reportPermissionViolation(
                "tenon.process.stream requires permission process.exec"
            )
            rejectProcess(handle)
            return
        }
        guard processes.count < Self.maximumProcesses else {
            rejectProcess(
                handle,
                reason: "tenon.process.stream rejected: process limit reached"
            )
            return
        }
        guard let executable = object["executable"]?.stringValue,
              !executable.isEmpty
        else {
            rejectProcess(
                handle,
                reason: "tenon.process.stream rejected: invalid process description"
            )
            return
        }
        let arguments = object["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard arguments.count == (object["arguments"]?.arrayValue?.count ?? 0) else {
            rejectProcess(
                handle,
                reason: "tenon.process.stream rejected: arguments must be strings"
            )
            return
        }

        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd = object["cwd"]?.stringValue, !cwd.isEmpty {
            process.currentDirectoryURL = URL(
                fileURLWithPath: (cwd as NSString).expandingTildeInPath
            )
        }
        if let environment = object["environment"]?.objectValue {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                if let value = value.stringValue {
                    merged[key] = value
                }
            }
            process.environment = merged
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = outputPipe.fileHandleForReading
        let standardError = errorPipe.fileHandleForReading
        let callback = callbackMailbox
        let outputMailbox = processOutputMailbox

        output.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                callback.enqueue(
                    .processEndOfFile(handle: handle, isStandardError: false)
                )
            } else if outputMailbox.append(
                data,
                isStandardError: false,
                handle: handle
            ) {
                callback.enqueue(.processOutputAvailable(handle: handle))
            }
        }
        standardError.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                callback.enqueue(
                    .processEndOfFile(handle: handle, isStandardError: true)
                )
            } else if outputMailbox.append(
                data,
                isStandardError: true,
                handle: handle
            ) {
                callback.enqueue(.processOutputAvailable(handle: handle))
            }
        }
        process.terminationHandler = { process in
            callback.enqueue(
                .processTerminated(handle: handle, status: process.terminationStatus)
            )
        }

        processOutputMailbox.register(handle: handle)
        processes[handle] = ProcessResource(
            process: process,
            standardOutput: output,
            standardError: standardError
        )
        do {
            try processRun(process)
        } catch {
            cancelProcess(handle)
            rejectProcess(
                handle,
                reason: "tenon.process.stream could not start \(executable): \(error)"
            )
        }
    }

    func rejectProcess(_ handle: Int, reason: String? = nil) {
        if let reason {
            emitLog(reason)
        }
        _ = try? callJavaScript("__tenonProcessExit", arguments: [handle, -1])
    }

    func deliverProcessOutput(_ handle: Int) {
        guard processes[handle] != nil,
              let batch = processOutputMailbox.drain(handle: handle)
        else {
            return
        }
        let stdout = String(decoding: batch.stdout, as: UTF8.self)
        let stderr = String(decoding: batch.stderr, as: UTF8.self)
        _ = try? callJavaScript(
            "__tenonProcessOutput",
            arguments: [handle, stdout, stderr, batch.overflowed]
        )
        if batch.overflowed, let resource = processes[handle], resource.process.isRunning {
            resource.process.terminate()
        }
    }

    func markProcessEndOfFile(_ handle: Int, isStandardError: Bool) {
        guard var resource = processes[handle] else { return }
        if isStandardError {
            resource.standardErrorEnded = true
            resource.standardError.readabilityHandler = nil
        } else {
            resource.standardOutputEnded = true
            resource.standardOutput.readabilityHandler = nil
        }
        processes[handle] = resource
        finishProcessIfComplete(handle)
    }

    func markProcessTerminated(_ handle: Int, status: Int32) {
        guard var resource = processes[handle] else { return }
        resource.terminationStatus = status
        processes[handle] = resource
        deliverProcessOutput(handle)
        finishProcessIfComplete(handle)
    }

    func finishProcessIfComplete(_ handle: Int) {
        guard let resource = processes[handle],
              resource.standardOutputEnded,
              resource.standardErrorEnded,
              let status = resource.terminationStatus
        else {
            return
        }
        deliverProcessOutput(handle)
        resource.process.terminationHandler = nil
        try? resource.standardOutput.close()
        try? resource.standardError.close()
        processes.removeValue(forKey: handle)
        processOutputMailbox.remove(handle: handle)
        _ = try? callJavaScript("__tenonProcessExit", arguments: [handle, status])
    }

    func cancelProcess(_ handle: Int) {
        guard let resource = processes.removeValue(forKey: handle) else { return }
        resource.standardOutput.readabilityHandler = nil
        resource.standardError.readabilityHandler = nil
        resource.process.terminationHandler = nil
        if resource.process.isRunning {
            resource.process.terminate()
        }
        try? resource.standardOutput.close()
        try? resource.standardError.close()
        processOutputMailbox.remove(handle: handle)
    }

    func startWatcher(_ object: [String: IntentValue]) {
        guard let handle = object["handle"]?.intValue else {
            emitLog("tenon.fs.watch rejected: invalid watch handle")
            return
        }
        guard manifest.permissions.contains("filesystem.read") else {
            reportPermissionViolation("tenon.fs.watch requires permission filesystem.read")
            rejectWatcher(handle)
            return
        }
        guard watchers.count < Self.maximumWatchers else {
            rejectWatcher(
                handle,
                reason: "tenon.fs.watch rejected: watcher limit reached"
            )
            return
        }
        guard let path = object["path"]?.stringValue,
              !path.isEmpty
        else {
            rejectWatcher(
                handle,
                reason: "tenon.fs.watch rejected: invalid watch description"
            )
            return
        }
        let callback = callbackMailbox
        let watcher = PathWatcher(
            path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            recursive: object["recursive"]?.boolValue ?? false,
            label: "dev.tenon.plugin-watch.\(manifest.id.rawValue).\(handle)",
            onOverflow: {
                callback.enqueue(.watchOverflow(handle: handle))
            }
        ) { paths in
            callback.enqueue(.watchedPaths(handle: handle, paths: paths))
        }
        watchers[handle] = watcher
        guard watcherStart(watcher) else {
            watchers.removeValue(forKey: handle)
            rejectWatcher(
                handle,
                reason: "tenon.fs.watch rejected: FSEvents stream could not start"
            )
            return
        }
    }

    func rejectWatcher(_ handle: Int, reason: String? = nil) {
        if let reason {
            emitLog(reason)
        }
        _ = try? callJavaScript("__tenonWatchRejected", arguments: [handle])
    }
}

// MARK: - Contributions and snapshots

private extension PluginRuntime {
    func persistStorage(_ object: [String: IntentValue]) throws {
        guard let token = object["token"]?.stringValue,
              let key = object["key"]?.stringValue,
              let value = object["value"]
        else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "storage.set requires token, key, and value"
            )
        }
        guard pendingStorageTokens.count < Self.maximumPendingStorageWrites else {
            _ = try callJavaScript(
                "__tenonSettleStorage",
                arguments: [
                    token,
                    false,
                    "too many pending storage writes",
                ]
            )
            return
        }
        guard pendingStorageTokens.insert(token).inserted else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "duplicate storage write token"
            )
        }

        let predecessor = storageCommitTail
        let sink = configuration.persistStorage
        let task = Task.detached { [weak self] in
            await predecessor?.value
            do {
                try await sink(key, value)
                await self?.settleStorage(token: token, errorMessage: nil)
            } catch {
                await self?.settleStorage(
                    token: token,
                    errorMessage: String(describing: error)
                )
            }
        }
        storageCommitTail = task
    }

    func settleStorage(token: String, errorMessage: String?) {
        guard pendingStorageTokens.remove(token) != nil else { return }
        guard phase == .staging || phase == .active || phase == .stopping else {
            return
        }
        do {
            _ = try callJavaScript(
                "__tenonSettleStorage",
                arguments: [
                    token,
                    errorMessage == nil,
                    errorMessage ?? "",
                ]
            )
            try drainBridgeMessages()
        } catch {
            emitLog("storage callback bridge error: \(error)")
            transitionToFailed(error)
        }
    }

    func registerView(_ object: [String: IntentValue]) {
        guard let viewID = object["viewID"]?.stringValue else { return }
        viewRegistrations[viewID] = ViewRegistration(
            title: object["title"]?.stringValue ?? viewID,
            instanced: object["instanced"]?.boolValue ?? false
        )
        markStateChanged()
    }

    func setViewBody(_ object: [String: IntentValue]) {
        guard let viewID = object["viewID"]?.stringValue,
              let registration = viewRegistrations[viewID],
              let specification = object["specification"]
        else {
            return
        }
        let instanceID = object["instanceID"]?.stringValue
        let key: String
        if registration.instanced {
            guard let instanceID else { return }
            key = instanceID
        } else {
            key = Self.singletonViewKey
        }
        let parsed = PluginRuntimeValueParsing.viewBody(from: specification)
        // A header item the plugin wrote and the host could not draw is named in the plugin's
        // OWN log, the way a rejected palette result already is. Silence would leave its author
        // looking at a control that is simply not there, with nothing to read and no way to
        // tell a typo from a bound.
        for diagnostic in parsed.diagnostics {
            emitLog("tenon.views.set(\(viewID)): \(diagnostic)")
        }
        viewBodies[viewID, default: [:]][key] = ViewBody(
            items: parsed.items,
            body: parsed.body,
            header: parsed.header,
            modal: parsed.modal
        )
        markStateChanged()
    }

    /// CONTRIBUTION registration: the plugin owns the declaration, the host owns
    /// validation and rendering. Exceeding the provider bound is a protocol violation
    /// that fails this runtime, exactly like the timer/process resource limits.
    func registerPaletteProvider(_ object: [String: IntentValue]) throws {
        guard let providerID = object["providerID"]?.stringValue,
              providerID.count <= Self.maximumPaletteTextLength
        else {
            emitLog(
                "tenon.palette.registerProvider needs a provider ID of at most "
                    + "\(Self.maximumPaletteTextLength) characters"
            )
            return
        }
        guard paletteProviderStates[providerID] != nil
            || paletteProviderStates.count < Self.maximumPaletteProviders
        else {
            throw PluginRuntimeError.resourceLimitExceeded("palette providers")
        }
        let title = object["title"]?.stringValue ?? providerID
        var state = paletteProviderStates[providerID] ?? PaletteProviderState(title: title)
        state.title = String(title.prefix(Self.maximumPaletteTextLength))
        paletteProviderStates[providerID] = state
        markStateChanged()
    }

    /// CONTRIBUTION publication: replaces this provider's previous snapshot. Only the
    /// revision most recently delivered to this generation is accepted — anything else
    /// answers a superseded query. Rows are shape-validated and bounded here; naming an
    /// intent grants nothing, the dispatcher still authorizes every invocation.
    func setPaletteResults(_ object: [String: IntentValue]) {
        guard let providerID = object["providerID"]?.stringValue,
              var state = paletteProviderStates[providerID],
              let revisionValue = object["revision"]?.intValue,
              let rawResults = object["results"]?.arrayValue
        else {
            emitLog(
                "tenon.palette.setResults needs a registered providerID, an integer "
                    + "revision, and a results array — call registerProvider first"
            )
            return
        }
        guard revisionValue == state.deliveredRevision else {
            emitLog(
                "tenon.palette.setResults(\(providerID)) dropped revision "
                    + "\(revisionValue): the current query revision is "
                    + "\(state.deliveredRevision)"
            )
            return
        }
        state.publishedRevision = revisionValue
        state.results = rawResults
            .prefix(Self.maximumPaletteResults)
            .compactMap { parsePaletteResult($0, providerID: providerID) }
        paletteProviderStates[providerID] = state
        markStateChanged()
    }

    func parsePaletteResult(
        _ value: IntentValue,
        providerID: String
    ) -> PaletteResultItem? {
        guard let object = value.objectValue,
              let rowID = object["id"]?.stringValue,
              let title = object["title"]?.stringValue,
              let designation = parsePaletteIntentDesignation(object["intent"])
        else {
            emitLog(
                "tenon.palette.setResults(\(providerID)) dropped a result: each result "
                    + "needs {id, title, intent: {name}} with the intent declared in "
                    + "manifest.intents.provides"
            )
            return nil
        }
        let actions = (object["actions"]?.arrayValue ?? [])
            .prefix(Self.maximumPaletteActions)
            .compactMap { raw -> PaletteResultAction? in
                guard let action = raw.objectValue,
                      let actionTitle = action["title"]?.stringValue,
                      let actionDesignation =
                          parsePaletteIntentDesignation(action["intent"])
                else {
                    emitLog(
                        "tenon.palette.setResults(\(providerID)) dropped an action on "
                            + "\(rowID): each action needs {title, intent: {name}} with "
                            + "the intent declared in manifest.intents.provides"
                    )
                    return nil
                }
                return PaletteResultAction(
                    title: String(actionTitle.prefix(Self.maximumPaletteTextLength)),
                    intentID: actionDesignation.intentID,
                    input: actionDesignation.input
                )
            }
        return PaletteResultItem(
            id: String(rowID.prefix(Self.maximumPaletteTextLength)),
            title: String(title.prefix(Self.maximumPaletteTextLength)),
            subtitle: object["subtitle"]?.stringValue
                .map { String($0.prefix(Self.maximumPaletteTextLength)) },
            icon: object["icon"]?.stringValue
                .map { String($0.prefix(Self.maximumPaletteTextLength)) },
            intentID: designation.intentID,
            input: designation.input,
            actions: Array(actions)
        )
    }

    /// A result may only designate an intent its own plugin provides. This is shape
    /// validation of the contribution, not authority: the palette principal's dispatch
    /// is still policy-checked on the one shared path.
    func parsePaletteIntentDesignation(
        _ value: IntentValue?
    ) -> (intentID: IntentID, input: IntentValue)? {
        guard let object = value?.objectValue,
              let rawName = object["name"]?.stringValue,
              let intentID = try? IntentID(rawName),
              manifest.intents.provides.contains(where: { $0.name == intentID })
        else {
            return nil
        }
        return (intentID, object["input"] ?? .object([:]))
    }

    func makePaletteSnapshots() -> [PaletteProviderInfo] {
        paletteProviderStates
            .map { providerID, state in
                PaletteProviderInfo(
                    providerID: providerID,
                    title: state.title,
                    deliveredRevision: state.deliveredRevision,
                    publishedRevision: state.publishedRevision,
                    results: state.results
                )
            }
            .sorted { $0.providerID < $1.providerID }
    }

    func makeSnapshot() -> PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(
            revision: revision,
            manifest: manifest,
            phase: phase,
            statusBarText: statusBarText,
            views: makeViewSnapshots(),
            paletteProviders: makePaletteSnapshots(),
            openViewInstances: openViewInstances.sorted {
                ($0.viewID, $0.instanceID) < ($1.viewID, $1.instanceID)
            },
            permissionViolations: permissionViolations,
            runtimeThreadIdentifier: executor.threadIdentifier,
            pendingNestedIntentCount: pendingNestedIntents.count,
            lateProviderReplyCount: lateProviderReplyCount
        )
    }

    func makeViewSnapshots() -> [PluginViewInfo] {
        var result: [PluginViewInfo] = []
        for (viewID, registration) in viewRegistrations {
            if registration.instanced {
                for (instanceID, body) in viewBodies[viewID] ?? [:] {
                    result.append(
                        PluginViewInfo(
                            viewID: viewID,
                            instanceID: instanceID,
                            instanced: true,
                            title: registration.title,
                            items: body.items,
                            body: body.body,
                            header: body.header,
                            modal: body.modal
                        )
                    )
                }
            } else {
                let body = viewBodies[viewID]?[Self.singletonViewKey]
                    ?? ViewBody(items: [], body: nil, header: .empty, modal: nil)
                result.append(
                    PluginViewInfo(
                        viewID: viewID,
                        instanceID: nil,
                        instanced: false,
                        title: registration.title,
                        items: body.items,
                        body: body.body,
                        header: body.header,
                        modal: body.modal
                    )
                )
            }
        }
        return result.sorted {
            ($0.viewID, $0.instanceID ?? "") < ($1.viewID, $1.instanceID ?? "")
        }
    }

    func markStateChanged() {
        revision &+= 1
        stateEmitter.emit(makeSnapshot())
    }

    func reportPermissionViolation(_ message: String) {
        guard permissionViolationSet.insert(message).inserted else { return }
        permissionViolations.append(message)
        emitLog(message)
        markStateChanged()
    }

    func emitLog(_ message: String) {
        let prefix = "[\(manifest.name)] "
        let sink = configuration.log
        _ = hostTasks.launch {
            await sink(prefix + message)
        }
    }

    func decodeActionIdentifier(_ identifier: String) -> Any {
        guard identifier.hasPrefix("\u{1}") else { return identifier }
        let json = String(identifier.dropFirst())
        guard let data = json.data(using: .utf8),
              let value = try? IntentValue(jsonData: data)
        else {
            return identifier
        }
        return PluginRuntimeValueParsing.foundationObject(from: value)
    }

    static func overloadedResultValue() -> IntentValue {
        PluginRuntimeValueParsing.intentResultValue(
            .failure(
                error: IntentError(
                    code: .kernel(.overloaded),
                    details: nil,
                    retryable: true,
                    retryAfterMilliseconds: nil,
                    outcome: .notStarted
                ),
                requestID: UUID(),
                providerID: nil
            )
        )
    }
}
