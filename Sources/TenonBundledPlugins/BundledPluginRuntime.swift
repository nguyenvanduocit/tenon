// @domain: plugin-host, plugin-contributions
import Foundation
import os
import TenonCore
import TenonIntentCore

// MARK: - Compiled program registry  @domain: plugin-host

/// The app's compiled plugin registry. It selects a backend; it does not decide whether a
/// plugin exists or is enabled. Those decisions still come from `PluginHost` and its inventory.
package enum BundledPluginRuntime {
    package static let factory = PluginHostRuntimeFactory { configuration in
        guard configuration.manifest.runtime == .bundledSwift else {
            return try await PluginHostRuntimeFactory.live.make(configuration)
        }
        guard let makeProgram = programs[configuration.manifest.id] else {
            throw PluginRuntimeError.bundledSwiftImplementationUnavailable(
                configuration.manifest.id
            )
        }
        return BundledPluginRuntimeActor(
            configuration: configuration,
            program: makeProgram()
        )
    }

    private static let programs: [
        PluginID: @Sendable () -> BundledPluginProgram
    ] = [
        CoreCommandsPlugin.id: CoreCommandsPlugin.makeProgram,
        ClockPlugin.id: ClockPlugin.makeProgram,
        HelloPalettePlugin.id: HelloPalettePlugin.makeProgram,
        ViewGalleryPlugin.id: ViewGalleryPlugin.makeProgram,
        WorkspaceStatusPlugin.id: WorkspaceStatusPlugin.makeProgram,
        BrowserPlugin.id: BrowserPlugin.makeProgram,
        FileExplorerPlugin.id: FileExplorerPlugin.makeProgram,
        ClaudeSessionsPlugin.id: ClaudeSessionsPlugin.makeProgram,
        GitPlugin.id: GitPlugin.makeProgram,
        KanbanPlugin.id: KanbanPlugin.makeProgram,
    ]
}

// MARK: - Callback pump plumbing  @domain: plugin-events

/// One unit of work on a generation's single bounded callback pump.
///
/// Events and view callbacks share the pump so the program observes one order — a select
/// enqueued between two events runs between them — and so the shutdown deadline reports a
/// stalled handler the same way whichever kind it was running.
private enum BundledPluginCallback {
    case event(name: String, payload: IntentValue)
    case contribution(BundledPluginContribution)
    case timerFired(Int)
    case watchedPaths(Int, [String])
    case watchOverflow(Int)
    case viewSelect(BundledPluginViewSelect)
    case viewSubmit(BundledPluginViewSubmit)
    case viewOpened(PluginViewInstanceKey, BundledPluginCallbackReply)
    case viewClosed(PluginViewInstanceKey, BundledPluginCallbackReply)

    var kind: String {
        switch self {
        case .event: "event"
        case .contribution: "contribution"
        case .timerFired: "timer"
        case .watchedPaths: "watch"
        case .watchOverflow: "watch overflow"
        case .viewSelect: "view select"
        case .viewSubmit: "view submit"
        case .viewOpened: "view open"
        case .viewClosed: "view close"
        }
    }

    var reply: BundledPluginCallbackReply? {
        switch self {
        case let .viewOpened(_, reply), let .viewClosed(_, reply): reply
        default: nil
        }
    }
}

/// A lifecycle caller awaits the same pump that owns the callback. This keeps compiled view
/// open/close semantics synchronous from the host's point of view without letting the caller
/// invoke plugin code around the pump's ordering or failure gate.
private final class BundledPluginCallbackReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BundledPluginContribution?, Error>?

    init(_ continuation: CheckedContinuation<BundledPluginContribution?, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<BundledPluginContribution?, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct BundledPluginTimerResource: Sendable {
    let task: Task<Void, Never>
    let repeats: Bool
    let owner: String?
    let handler: BundledPluginTimers.Handler
}

private struct BundledPluginWatchResource {
    let watcher: PathWatcher
    let owner: String?
    let handler: BundledPluginFileSystem.WatchHandler
}

private final class BundledPluginCallbackMailbox: Sendable {
    enum EnqueueResult {
        case enqueued
        case overflow
        case closed
    }

    let stream: AsyncStream<BundledPluginCallback>
    private let continuation: AsyncStream<BundledPluginCallback>.Continuation

    init(capacity: Int = 256) {
        let pair = AsyncStream.makeStream(
            of: BundledPluginCallback.self,
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func enqueue(_ callback: BundledPluginCallback) -> EnqueueResult {
        switch continuation.yield(callback) {
        case .enqueued:
            return .enqueued
        case .dropped:
            return .overflow
        case .terminated:
            return .closed
        @unknown default:
            return .closed
        }
    }

    func finish() {
        continuation.finish()
    }
}

private final class BundledPluginPumpCompletion: Sendable {
    private let finished = OSAllocatedUnfairLock(initialState: false)

    var isFinished: Bool {
        finished.withLock { $0 }
    }

    func finish() {
        finished.withLock { $0 = true }
    }
}

final actor BundledPluginRuntimeActor: PluginHostRuntime {
    nonisolated let manifest: PluginManifest
    nonisolated let directory: URL

    /// The channel the host addresses directly to tell a generation one of its declared
    /// settings has a new value.
    private static let settingsChangedEvent = "settings.changed"
    private static let maximumTimers = 256
    private static let maximumWatchers = 64

    private nonisolated let subscribedEvents: Set<String>
    private nonisolated let mailbox = BundledPluginCallbackMailbox()
    private nonisolated let pumpCompletion = BundledPluginPumpCompletion()
    private nonisolated let localState: BundledPluginLocalState
    private let configuration: PluginRuntimeConfiguration
    private let program: BundledPluginProgram
    private let watcherStart: @Sendable (PathWatcher) -> Bool
    private lazy var context = BundledPluginContext(
        state: localState,
        intents: configuration.intents,
        log: configuration.log,
        timers: BundledPluginTimers(
            schedule: { [weak self] milliseconds, repeats, owner, callback in
                guard let self else { throw PluginRuntimeError.runtimeStopped }
                return try await self.scheduleTimer(
                    milliseconds: milliseconds,
                    repeats: repeats,
                    ownedBy: owner,
                    callback: callback
                )
            },
            cancel: { [weak self] handle in
                await self?.cancelTimer(handle)
            }
        ),
        fs: BundledPluginFileSystem(
            start: { [weak self] path, recursive, owner, callback in
                await self?.startWatcher(
                    path: path,
                    recursive: recursive,
                    ownedBy: owner,
                    callback: callback
                )
            },
            cancel: { [weak self] handle in
                await self?.cancelWatcher(handle)
            }
        ),
        persistStorage: configuration.persistStorage,
        publishEvent: { [weak self] event, payload in
            guard let self else { throw PluginRuntimeError.runtimeStopped }
            try await publish(event: event, payload: payload)
        },
        publishContribution: { [weak self] contribution in
            guard let self else { return }
            await publishContribution(contribution)
        }
    )

    private var phase: PluginRuntimePhase = .initialized
    private var revision: UInt64 = 0
    private var contribution = BundledPluginContribution.empty
    private var openInstances: Set<PluginViewInstanceKey> = []
    private var timers: [Int: BundledPluginTimerResource] = [:]
    private var watchers: [Int: BundledPluginWatchResource] = [:]
    private var nextResourceID = 1
    private var permissionViolationSet: Set<String> = []
    private var permissionViolations: [String] = []
    private var pendingLifecycleReplies: [ObjectIdentifier: BundledPluginCallbackReply] = [:]
    private var eventPump: Task<Void, Never>?

    init(
        configuration: PluginRuntimeConfiguration,
        program: BundledPluginProgram,
        watcherStart: @escaping @Sendable (PathWatcher) -> Bool = { $0.start() }
    ) {
        manifest = configuration.manifest
        directory = configuration.directory
        subscribedEvents = program.subscribedEvents
        self.configuration = configuration
        self.program = program
        self.watcherStart = watcherStart
        localState = BundledPluginLocalState(configuration.local)
    }

    // MARK: - Lifecycle  @domain: plugin-host

    func start() async throws -> PluginRuntimeStartResult {
        guard phase == .initialized else {
            throw PluginRuntimeError.invalidLifecycle(
                expected: .initialized,
                actual: phase
            )
        }
        phase = .staging

        do {
            guard program.id == manifest.id else {
                throw PluginRuntimeError.bridgeProtocolViolation(
                    "compiled plugin id \(program.id.rawValue) does not match manifest "
                        + manifest.id.rawValue
                )
            }
            let declared = Set(manifest.intents.provides.map(\.name))
            let missing = declared.subtracting(program.providedIntents)
            guard missing.isEmpty else {
                throw PluginRuntimeError.missingIntentHandlers(
                    missing.sorted { $0.rawValue < $1.rawValue }
                )
            }
            guard program.providedIntents.subtracting(declared).isEmpty else {
                let undeclared = program.providedIntents.subtracting(declared)
                    .sorted { $0.rawValue < $1.rawValue }[0]
                throw PluginRuntimeError.undeclaredIntentHandler(undeclared)
            }

            contribution = try await activateWithinTimeout()
            phase = .active
            eventPump = Task {
                [weak self, stream = mailbox.stream, pumpCompletion] in
                defer { pumpCompletion.finish() }
                for await callback in stream {
                    guard !Task.isCancelled else { return }
                    await self?.consume(callback)
                }
            }
            revision &+= 1
            let current = makeSnapshot()
            let bindings = declared
                .sorted { $0.rawValue < $1.rawValue }
                .map(makeBinding(for:))
            return PluginRuntimeStartResult(
                bindings: bindings,
                snapshot: current
            )
        } catch {
            phase = .failed
            mailbox.finish()
            revision &+= 1
            await configuration.onStateChange(makeSnapshot())
            throw error
        }
    }

    /// Activation is plugin code, so it must not be allowed to hold host inventory loading
    /// forever. The operation is cancelled when the deadline wins; cooperative async plugin
    /// code then unwinds through the same failure path as any other startup error.
    private func activateWithinTimeout() async throws -> BundledPluginContribution {
        let timeout = configuration.startupTimeout
        guard timeout.isFinite, timeout >= 0 else {
            throw PluginRuntimeError.invalidStartupTimeout(timeout)
        }

        return try await withThrowingTaskGroup(of: BundledPluginContribution.self) { group in
            group.addTask { [context, program] in
                try await program.activate(context)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw PluginRuntimeError.startupTimedOut(timeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PluginRuntimeError.startupTimedOut(timeout)
            }
            return result
        }
    }

    func shutdown(timeout: TimeInterval) async -> PluginRuntimeShutdownReport {
        var stalledPhase: PluginRuntimeShutdownReport.StalledPhase?
        if phase != .stopped {
            phase = .stopping
            finishPendingLifecycleReplies(with: .failure(PluginRuntimeError.runtimeStopped))
            stopOwnedResources()
            mailbox.finish()
            eventPump?.cancel()
            let deadline = ContinuousClock.now + .seconds(max(0, timeout))
            while eventPump != nil,
                  !pumpCompletion.isFinished,
                  ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if eventPump != nil, !pumpCompletion.isFinished {
                stalledPhase = .callbackPump
            }
            eventPump = nil
            openInstances = []
            phase = .stopped
            revision &+= 1
            await configuration.onStateChange(makeSnapshot())
        }
        return PluginRuntimeShutdownReport(
            executorResult: .stopped,
            createdThreadIdentifier: nil,
            destroyedThreadIdentifier: nil,
            cancelledProviderCalls: 0,
            lateProviderReplyCount: 0,
            stalledPhase: stalledPhase
        )
    }

    // MARK: - Events and the shared pump  @domain: plugin-events

    nonisolated func handles(event: String) async -> Bool {
        subscribedEvents.contains(event)
    }

    nonisolated func acceptEvent(event: String, payload: IntentValue) -> Bool {
        switch mailbox.enqueue(.event(name: event, payload: payload)) {
        case .enqueued:
            return true
        case .overflow:
            mailbox.finish()
            Task { await failForCallbackOverflow() }
            return false
        case .closed:
            return false
        }
    }

    /// Host → plugin. A fact the host addresses to this generation directly, delivered on the
    /// same bounded pump every other callback uses so the program observes one order.
    ///
    /// `settings.changed` refreshes the owned settings before the callback is enqueued, which
    /// is what makes a handler asking for the key it was just told about read the new value —
    /// the JavaScript runtime does the same thing inside `__tenonEmit`
    /// (`PluginRuntimeBootstrap.swift`), and the compiled backend owes the same guarantee.
    func deliverEvent(event: String, payload: IntentValue) async throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        if event == Self.settingsChangedEvent,
           case let .object(fields) = payload,
           case let .string(key)? = fields["key"],
           let value = fields["value"]
        {
            localState.applySetting(key, value)
        }
        _ = await enqueueCallback(.event(name: event, payload: payload))
    }

    /// Plugin → host. The publish half of EVENT, reached only through the program's own
    /// context, and only for a channel the manifest declares. The host qualifies the local
    /// name with this plugin's id, so a program can publish under nobody else's name.
    private func publish(event: String, payload: IntentValue) async throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard manifest.events?.publishes.contains(event) == true else {
            throw PluginRuntimeError.undeclaredEventPublication(event)
        }
        await configuration.publishEvent(event, payload)
    }

    private func enqueueCallback(_ callback: BundledPluginCallback) async -> Bool {
        switch mailbox.enqueue(callback) {
        case .enqueued:
            return true
        case .overflow:
            mailbox.finish()
            await failForCallbackOverflow()
            return false
        case .closed:
            return false
        }
    }

    private func consume(_ callback: BundledPluginCallback) async {
        guard phase == .active else {
            finishLifecycleReply(
                for: callback,
                with: .failure(PluginRuntimeError.runtimeStopped)
            )
            return
        }
        do {
            if let next = try await run(callback) {
                guard phase == .active else {
                    finishLifecycleReply(
                        for: callback,
                        with: .failure(PluginRuntimeError.runtimeStopped)
                    )
                    return
                }
                contribution = next
                revision &+= 1
                await configuration.onStateChange(makeSnapshot())
            }
            finishLifecycleReply(for: callback, with: .success(nil))
        } catch {
            finishLifecycleReply(for: callback, with: .failure(error))
            guard phase == .active else { return }
            phase = .failed
            stopOwnedResources()
            mailbox.finish()
            revision &+= 1
            await configuration.log(
                "\(manifest.id.rawValue): compiled \(callback.kind) handler failed: \(error)"
            )
            await configuration.onStateChange(makeSnapshot())
        }
    }

    private func run(
        _ callback: BundledPluginCallback
    ) async throws -> BundledPluginContribution? {
        switch callback {
        case let .event(name, payload):
            return try await program.receiveEvent(name, payload, context)
        case let .contribution(next):
            return next
        case let .timerFired(handle):
            guard let resource = timers[handle] else { return nil }
            if !resource.repeats {
                timers.removeValue(forKey: handle)
            }
            await resource.handler()
            return nil
        case let .watchedPaths(handle, paths):
            guard let resource = watchers[handle] else { return nil }
            await resource.handler(paths)
            return nil
        case let .watchOverflow(handle):
            guard watchers[handle] != nil else { return nil }
            throw PluginRuntimeError.resourceLimitExceeded(
                "pending paths for watcher \(handle)"
            )
        case let .viewSelect(select):
            guard let handler = program.viewCallbacks[select.viewID]?.select else {
                return nil
            }
            return try await handler(select, context)
        case let .viewSubmit(submit):
            guard let handler = program.viewCallbacks[submit.viewID]?.submit else {
                return nil
            }
            return try await handler(submit, context)
        case let .viewOpened(key, _):
            guard let handler = program.viewCallbacks[key.viewID]?.open else {
                return nil
            }
            return try await handler(key.instanceID, context)
        case let .viewClosed(key, _):
            guard let handler = program.viewCallbacks[key.viewID]?.close else {
                return nil
            }
            return try await handler(key.instanceID, context)
        }
    }

    private func failForCallbackOverflow() async {
        guard phase == .active else { return }
        phase = .failed
        finishPendingLifecycleReplies(with: .failure(PluginRuntimeError.runtimeStopped))
        revision &+= 1
        await configuration.log(
            "\(manifest.id.rawValue): compiled callback mailbox exceeded 256 entries"
        )
        await configuration.onStateChange(makeSnapshot())
    }

    // MARK: - View instances and callbacks  @domain: plugin-contributions

    func isViewInstanced(_ viewID: String) -> Bool {
        contribution.viewRegistrations.first { $0.viewID == viewID }?.instanced ?? false
    }

    /// `true` means a select handler is registered for this view id, exactly like the
    /// JavaScript bootstrap's per-view handler map; the handler itself runs on the pump,
    /// after everything enqueued before it, and is never awaited by the host.
    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        itemID: String,
        value: IntentValue?
    ) async throws -> Bool {
        try await invokeViewSelect(
            viewID: viewID,
            instanceID: instanceID,
            action: .string(itemID),
            value: value
        )
    }

    func invokeViewSelect(
        viewID: String,
        instanceID: String?,
        action: PluginNodeAction,
        value: IntentValue?
    ) async throws -> Bool {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard program.viewCallbacks[viewID]?.select != nil else { return false }
        return await enqueueCallback(
            .viewSelect(
                BundledPluginViewSelect(
                    viewID: viewID,
                    instanceID: instanceID,
                    action: action,
                    value: value
                )
            )
        )
    }

    func invokeViewSubmit(
        viewID: String,
        instanceID: String?,
        itemID: String,
        text: String
    ) async throws -> Bool {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard program.viewCallbacks[viewID]?.submit != nil else { return false }
        return await enqueueCallback(
            .viewSubmit(
                BundledPluginViewSubmit(
                    viewID: viewID,
                    instanceID: instanceID,
                    itemID: itemID,
                    text: text
                )
            )
        )
    }

    func openViewInstance(viewID: String, instanceID: String) async throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard isViewInstanced(viewID) else { return }
        let key = PluginViewInstanceKey(viewID: viewID, instanceID: instanceID)
        guard openInstances.insert(key).inserted else { return }
        if program.viewCallbacks[viewID]?.open != nil {
            try await enqueueLifecycleCallback { reply in
                .viewOpened(key, reply)
            }
        }
        revision &+= 1
        await configuration.onStateChange(makeSnapshot())
    }

    func closeViewInstance(viewID: String, instanceID: String) async throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        let key = PluginViewInstanceKey(viewID: viewID, instanceID: instanceID)
        guard openInstances.remove(key) != nil else { return }
        if program.viewCallbacks[viewID]?.close != nil {
            try await enqueueLifecycleCallback { reply in
                .viewClosed(key, reply)
            }
        }
        cancelResources(ownedBy: instanceID)
        // Mirrors the JavaScript runtime dropping `viewBodies[viewID][instanceID]` at close:
        // the registration entry stays, the closed instance's published body does not. A
        // replacement contribution the program publishes later remains authoritative.
        contribution = contribution.removingBody(
            viewID: viewID,
            instanceID: instanceID
        )
        revision &+= 1
        await configuration.onStateChange(makeSnapshot())
    }

    private func enqueueLifecycleCallback(
        _ makeCallback: (BundledPluginCallbackReply) -> BundledPluginCallback
    ) async throws {
        let _: BundledPluginContribution? = try await withCheckedThrowingContinuation { continuation in
            let reply = BundledPluginCallbackReply(continuation)
            switch mailbox.enqueue(makeCallback(reply)) {
            case .enqueued:
                pendingLifecycleReplies[ObjectIdentifier(reply)] = reply
                break
            case .overflow:
                reply.resume(
                    with: .failure(
                        PluginRuntimeError.resourceLimitExceeded("runtime callbacks")
                    )
                )
                Task { await failForCallbackOverflow() }
            case .closed:
                reply.resume(with: .failure(PluginRuntimeError.runtimeStopped))
            }
        }
    }

    private func finishLifecycleReply(
        for callback: BundledPluginCallback,
        with result: Result<BundledPluginContribution?, Error>
    ) {
        guard let reply = callback.reply else { return }
        pendingLifecycleReplies.removeValue(forKey: ObjectIdentifier(reply))
        reply.resume(with: result)
    }

    private func finishPendingLifecycleReplies(
        with result: Result<BundledPluginContribution?, Error>
    ) {
        let replies = pendingLifecycleReplies.values
        pendingLifecycleReplies.removeAll()
        for reply in replies {
            reply.resume(with: result)
        }
    }

    func deliverPaletteQuery(text _: String, revision _: Int) {}

    // MARK: - Provider bindings  @domain: plugin-host, intent-bus

    private func makeBinding(for intentID: IntentID) -> IntentProviderBinding {
        IntentProviderBinding(intentID: intentID) { [weak self] envelope, context in
            guard let self else {
                return .failure(
                    IntentProviderFailure(code: .kernel(.providerRetired))
                )
            }
            return try await invokeIntent(envelope, context: context)
        }
    }

    private func invokeIntent(
        _ envelope: IntentEnvelope,
        context providerContext: IntentProviderContext
    ) async throws -> IntentProviderReply {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard program.providedIntents.contains(envelope.name) else {
            throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
        }
        try providerContext.checkCancellation()
        return try await program.invokeIntent(envelope, providerContext, context)
    }

    /// A contribution pushed from work that has no replacement value to return. It enters the
    /// same bounded pump as events and view callbacks, so an intent or timer cannot race a host
    /// event into an incoherent snapshot.
    private func publishContribution(_ next: BundledPluginContribution) async {
        guard phase == .active else { return }
        _ = await enqueueCallback(.contribution(next))
    }

    // MARK: - Generation-owned resources  @domain: plugin-host, plugin-events

    private func scheduleTimer(
        milliseconds: Double,
        repeats: Bool,
        ownedBy owner: String?,
        callback: BundledPluginTimers.Callback
    ) async throws -> Int {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard milliseconds.isFinite, milliseconds >= 0 else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "compiled timer interval must be finite and nonnegative"
            )
        }
        guard !repeats || milliseconds >= 10 else {
            throw PluginRuntimeError.bridgeProtocolViolation(
                "repeating timer interval must be at least 10 milliseconds"
            )
        }
        guard timers.count < Self.maximumTimers else {
            throw PluginRuntimeError.resourceLimitExceeded("timers")
        }

        let handle = nextResourceID
        nextResourceID &+= 1
        let nanoseconds = UInt64(
            max(1, (milliseconds * 1_000_000).rounded())
        )
        let task = Task { [weak self] in
            if repeats {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    _ = await self?.enqueueCallback(.timerFired(handle))
                }
            } else {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await self?.enqueueCallback(.timerFired(handle))
            }
        }
        timers[handle] = BundledPluginTimerResource(
            task: task,
            repeats: repeats,
            owner: owner,
            handler: callback.operation
        )
        return handle
    }

    private func cancelTimer(_ handle: Int) {
        timers.removeValue(forKey: handle)?.task.cancel()
    }

    private func startWatcher(
        path: String,
        recursive: Bool,
        ownedBy owner: String?,
        callback: BundledPluginFileSystem.Callback
    ) async -> Int? {
        guard phase == .active else { return nil }
        guard manifest.permissions.contains("filesystem.read") else {
            await recordPermissionViolation(
                "tenon.fs.watch requires permission filesystem.read"
            )
            return nil
        }
        guard watchers.count < Self.maximumWatchers else {
            await configuration.log("tenon.fs.watch rejected: watcher limit reached")
            return nil
        }
        let expandedPath = (path as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty else {
            await configuration.log("tenon.fs.watch rejected: invalid watch description")
            return nil
        }

        let handle = nextResourceID
        nextResourceID &+= 1
        let watcher = PathWatcher(
            path: URL(fileURLWithPath: expandedPath),
            recursive: recursive,
            label: "tenon.plugin-watch.\(manifest.id.rawValue).\(handle)",
            onOverflow: { [weak self] in
                Task { _ = await self?.enqueueCallback(.watchOverflow(handle)) }
            },
            onChange: { [weak self] paths in
                Task { _ = await self?.enqueueCallback(.watchedPaths(handle, paths)) }
            }
        )
        watchers[handle] = BundledPluginWatchResource(
            watcher: watcher,
            owner: owner,
            handler: callback.operation
        )
        guard watcherStart(watcher) else {
            watchers.removeValue(forKey: handle)
            await configuration.log(
                "tenon.fs.watch rejected: FSEvents stream could not start"
            )
            return nil
        }
        return handle
    }

    private func cancelWatcher(_ handle: Int) {
        watchers.removeValue(forKey: handle)?.watcher.stop()
    }

    private func cancelResources(ownedBy instanceID: String) {
        let timerHandles = timers.compactMap { handle, resource in
            resource.owner == instanceID ? handle : nil
        }
        for handle in timerHandles {
            cancelTimer(handle)
        }
        let watcherHandles = watchers.compactMap { handle, resource in
            resource.owner == instanceID ? handle : nil
        }
        for handle in watcherHandles {
            cancelWatcher(handle)
        }
    }

    private func stopOwnedResources() {
        for resource in timers.values {
            resource.task.cancel()
        }
        timers.removeAll()
        for resource in watchers.values {
            resource.watcher.stop()
        }
        watchers.removeAll()
    }

    private func recordPermissionViolation(_ message: String) async {
        guard permissionViolationSet.insert(message).inserted else { return }
        permissionViolations.append(message)
        revision &+= 1
        await configuration.log(message)
        await configuration.onStateChange(makeSnapshot())
    }

    // MARK: - Snapshots  @domain: plugin-contributions

    func snapshot() -> PluginRuntimeSnapshot {
        makeSnapshot()
    }

    private func makeSnapshot() -> PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(
            revision: revision,
            manifest: manifest,
            phase: phase,
            statusBarText: contribution.statusBarText,
            views: contribution.views,
            openViewInstances: openInstances.sorted {
                ($0.viewID, $0.instanceID) < ($1.viewID, $1.instanceID)
            },
            permissionViolations: permissionViolations,
            runtimeThreadIdentifier: nil,
            pendingNestedIntentCount: 0,
            lateProviderReplyCount: 0
        )
    }
}
