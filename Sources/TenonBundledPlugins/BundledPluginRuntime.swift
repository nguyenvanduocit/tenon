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
        WorkspaceStatusPlugin.id: WorkspaceStatusPlugin.makeProgram,
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
    case viewSelect(BundledPluginViewSelect)
    case viewSubmit(BundledPluginViewSubmit)
    case viewOpened(PluginViewInstanceKey)
    case viewClosed(PluginViewInstanceKey)

    var kind: String {
        switch self {
        case .event: "event"
        case .viewSelect: "view select"
        case .viewSubmit: "view submit"
        case .viewOpened: "view open"
        case .viewClosed: "view close"
        }
    }
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

    private nonisolated let subscribedEvents: Set<String>
    private nonisolated let mailbox = BundledPluginCallbackMailbox()
    private nonisolated let pumpCompletion = BundledPluginPumpCompletion()
    private let configuration: PluginRuntimeConfiguration
    private let context: BundledPluginContext
    private let program: BundledPluginProgram

    private var phase: PluginRuntimePhase = .initialized
    private var revision: UInt64 = 0
    private var contribution = BundledPluginContribution.empty
    private var openInstances: Set<PluginViewInstanceKey> = []
    private var eventPump: Task<Void, Never>?

    init(
        configuration: PluginRuntimeConfiguration,
        program: BundledPluginProgram
    ) {
        manifest = configuration.manifest
        directory = configuration.directory
        subscribedEvents = program.subscribedEvents
        self.configuration = configuration
        self.program = program
        context = BundledPluginContext(
            local: configuration.local,
            intents: configuration.intents,
            log: configuration.log,
            persistStorage: configuration.persistStorage
        )
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

            contribution = try await program.activate(context)
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

    func shutdown(timeout: TimeInterval) async -> PluginRuntimeShutdownReport {
        var stalledPhase: PluginRuntimeShutdownReport.StalledPhase?
        if phase != .stopped {
            phase = .stopping
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

    func emit(event: String, payload: IntentValue) async throws {
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
        guard phase == .active else { return }
        do {
            if let next = try await run(callback) {
                guard phase == .active else { return }
                contribution = next
                revision &+= 1
                await configuration.onStateChange(makeSnapshot())
            }
        } catch {
            guard phase == .active else { return }
            phase = .failed
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
        case let .viewOpened(key):
            guard let handler = program.viewCallbacks[key.viewID]?.open else {
                return nil
            }
            return try await handler(key.instanceID, context)
        case let .viewClosed(key):
            guard let handler = program.viewCallbacks[key.viewID]?.close else {
                return nil
            }
            return try await handler(key.instanceID, context)
        }
    }

    private func failForCallbackOverflow() async {
        guard phase == .active else { return }
        phase = .failed
        revision &+= 1
        await configuration.log(
            "\(manifest.id.rawValue): compiled callback mailbox exceeded 256 entries"
        )
        await configuration.onStateChange(makeSnapshot())
    }

    // MARK: - View instances and callbacks  @domain: plugin-contributions

    func isViewInstanced(_ viewID: String) -> Bool {
        contribution.views.first { $0.viewID == viewID }?.instanced ?? false
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
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        guard program.viewCallbacks[viewID]?.select != nil else { return false }
        return await enqueueCallback(
            .viewSelect(
                BundledPluginViewSelect(
                    viewID: viewID,
                    instanceID: instanceID,
                    itemID: itemID,
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
            _ = await enqueueCallback(.viewOpened(key))
        }
        revision &+= 1
        await configuration.onStateChange(makeSnapshot())
    }

    func closeViewInstance(viewID: String, instanceID: String) async throws {
        guard phase == .active else { throw PluginRuntimeError.runtimeStopped }
        let key = PluginViewInstanceKey(viewID: viewID, instanceID: instanceID)
        guard openInstances.remove(key) != nil else { return }
        if program.viewCallbacks[viewID]?.close != nil {
            _ = await enqueueCallback(.viewClosed(key))
        }
        // Mirrors the JavaScript runtime dropping `viewBodies[viewID][instanceID]` at close:
        // the registration entry stays, the closed instance's published body does not. A
        // replacement contribution the program publishes later remains authoritative.
        contribution = BundledPluginContribution(
            statusBarText: contribution.statusBarText,
            views: contribution.views.filter {
                !($0.viewID == viewID && $0.instanceID == instanceID)
            }
        )
        revision &+= 1
        await configuration.onStateChange(makeSnapshot())
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
        return try await program.invokeIntent(envelope, providerContext)
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
            permissionViolations: [],
            runtimeThreadIdentifier: nil,
            pendingNestedIntentCount: 0,
            lateProviderReplyCount: 0
        )
    }
}
