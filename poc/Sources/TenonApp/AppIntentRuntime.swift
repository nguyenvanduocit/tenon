import Foundation
import TenonCore
import TenonIntentCore

enum AppIntentRuntimeError: Error, Sendable, Equatable {
    case bindingInventoryMismatch(
        missing: [IntentID],
        unexpected: [IntentID]
    )
}

/// The app composition root for the invocation kernel and its trusted core provider.
///
/// Construction is synchronous so `PluginHost` can receive the one shared kernel.
/// `start()` performs catalog compilation and atomic provider activation once, and
/// concurrent callers join the same in-flight task.
@MainActor
final class AppIntentRuntime {
    static let palettePrincipal = IntentPrincipal(
        id: "palette:tenon",
        kind: .palette,
        sessionRevision: 1
    )

    static let cliPrincipal = IntentPrincipal(
        id: "cli:local-user",
        kind: .cli,
        sessionRevision: 1
    )

    let kernel: IntentKernelComponents

    private let catalog: CoreIntentCatalog
    private let bindings: [IntentProviderBinding]
    private let workspaceStore: WorkspaceStore
    private var isStarted = false
    private var startTask: Task<Void, any Error>?
    private var startTaskID: UUID?
    private var lifecycleRevision: UInt64 = 0

    init(
        stateRoot: URL,
        workspaceStore: WorkspaceStore,
        terminalSurfaces: SurfacePool,
        webSurfaces: PluginWebSurfacePool,
        userInterface: PluginUIState
    ) throws {
        try FileManager.default.createDirectory(
            at: stateRoot,
            withIntermediateDirectories: true
        )
        let persistence = try IntentSQLiteIdempotencyPersistence(
            url: stateRoot.appendingPathComponent(
                "intent-idempotency.sqlite3",
                isDirectory: false
            )
        )
        kernel = try IntentKernelComponents(
            persistence: persistence,
            confirmationAuthorizer: userInterface
                .confirmationAuthorizer()
        )
        self.workspaceStore = workspaceStore
        catalog = CoreIntentCatalog(components: kernel)

        var collected: [IntentProviderBinding] = []
        collected.append(contentsOf: try FilesystemIntentProvider().bindings)
        collected.append(contentsOf: try ProcessIntentProvider().bindings)
        collected.append(contentsOf: try NetworkIntentProvider().bindings)
        collected.append(
            contentsOf: try SecretIntentProvider(
                store: SecretStore()
            ).bindings
        )
        collected.append(
            contentsOf: try WorkspaceIntentProvider(
                store: workspaceStore
            ).bindings()
        )
        collected.append(
            contentsOf: try TerminalIntentProvider(
                store: workspaceStore,
                surfaces: terminalSurfaces
            ).bindings()
        )
        collected.append(
            contentsOf: try SystemIntentProvider().bindings()
        )
        collected.append(
            contentsOf: try BrowserIntentProvider(
                pool: webSurfaces
            ).bindings()
        )
        collected.append(
            contentsOf: try UserInteractionIntentProvider(
                state: userInterface
            ).bindings()
        )
        bindings = collected
    }

    func start() async throws {
        if isStarted {
            return
        }
        if let startTask {
            return try await startTask.value
        }

        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        let taskID = UUID()
        let task = Task { @MainActor [self] in
            try await performStart()
        }
        startTaskID = taskID
        startTask = task

        do {
            try await task.value
            guard lifecycleRevision == revision,
                  startTaskID == taskID
            else {
                throw CancellationError()
            }
            isStarted = true
            clearStartTask(ifMatching: taskID)
        } catch {
            clearStartTask(ifMatching: taskID)
            throw error
        }
    }

    func stop() async throws {
        lifecycleRevision &+= 1
        let task = startTask
        let taskID = startTaskID
        task?.cancel()
        _ = try? await task?.value
        if let taskID {
            clearStartTask(ifMatching: taskID)
        }

        guard let providerID = try? CoreIntentCatalog.trustedProviderID()
        else {
            isStarted = false
            return
        }
        let snapshot = await kernel.providerActivation.snapshot()
        let hasResidentGeneration = snapshot.generations.contains {
            $0.providerID == providerID
                && [.staging, .active, .draining].contains(
                    $0.lifecycle
                )
        }
        if hasResidentGeneration {
            try await kernel.providerActivation.disable(providerID)
        }
        isStarted = false
    }

    func discover(
        as caller: IntentPrincipal,
        projection: IntentDiscoveryProjection = .callable
    ) async -> IntentDiscoverySnapshot {
        await kernel.dispatcher.discover(
            for: caller,
            projection: projection
        )
    }

    /// Dispatch with a caller-supplied scope. Control-plane adapters use this
    /// entry point so workspace, pane, and user-gesture authority is visible at
    /// the call site rather than inherited from mutable UI state.
    func send(
        _ intentID: IntentID,
        input: IntentValue = .object([:]),
        as caller: IntentPrincipal,
        scope: InvocationScope,
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil
    ) async -> IntentResult {
        await kernel.dispatcher.send(
            IntentDispatchRequest(
                intentID: intentID,
                input: input,
                caller: caller,
                scope: scope,
                target: target,
                idempotencyKey: idempotencyKey,
                requestedTimeout: requestedTimeout
            )
        )
    }

    /// In-app convenience for interactive callers whose scope is the currently
    /// selected workspace/pane. CLI traffic never uses this overload.
    func send(
        _ intentID: IntentID,
        input: IntentValue = .object([:]),
        as caller: IntentPrincipal,
        target: ProviderID? = nil,
        idempotencyKey: String? = nil,
        requestedTimeout: Duration? = nil,
        userGestureID: UUID? = nil
    ) async -> IntentResult {
        await send(
            intentID,
            input: input,
            as: caller,
            scope: InvocationScope(
                workspaceID: workspaceStore.catalog.activeWorkspaceID,
                paneID: workspaceStore.catalog.activeSlotID,
                userGestureID: userGestureID
            ),
            target: target,
            idempotencyKey: idempotencyKey,
            requestedTimeout: requestedTimeout
        )
    }
}

private extension AppIntentRuntime {
    func performStart() async throws {
        try Task.checkCancellation()
        let compiled = try await catalog.install()
        try Task.checkCancellation()
        try validateBindingInventory(compiled)
        try await configureTrustedPrincipals(compiled)
        try Task.checkCancellation()

        let providerID = compiled.trustedProviderID
        let generation = try await kernel.providerActivation
            .nextGeneration(for: providerID)
        let owner = IntentProviderOwner.core
        let principal = owner.principal(sessionRevision: generation)
        let fingerprint = try PolicyFingerprint(
            canonicalPolicy: .object([
                "providerID": .string(providerID.rawValue),
                "intents": .array(
                    bindings.map(\.intentID.rawValue)
                        .sorted()
                        .map(IntentValue.string)
                ),
            ])
        )
        let candidate = try ProviderGenerationCandidate(
            providerID: providerID,
            owner: owner,
            principal: principal,
            generation: generation,
            bindings: bindings,
            policyFingerprint: fingerprint,
            executionLanes: try makeCoreExecutionLanes()
        )

        var staged = false
        var activated = false
        do {
            try await kernel.providerActivation.stageCore(candidate)
            staged = true
            try Task.checkCancellation()
            try await kernel.providerActivation.activate(
                providerID: providerID,
                generation: generation
            )
            activated = true
            try Task.checkCancellation()
        } catch let startError {
            if activated {
                do {
                    try await kernel.providerActivation.disable(providerID)
                } catch {
                    throw error
                }
            } else if staged {
                do {
                    try await kernel.providerActivation.failStaging(
                        providerID: providerID,
                        generation: generation,
                        diagnostic: String(describing: startError)
                    )
                } catch {
                    throw error
                }
            }
            throw startError
        }
    }

    func clearStartTask(ifMatching taskID: UUID) {
        guard startTaskID == taskID else { return }
        startTaskID = nil
        startTask = nil
    }

    func validateBindingInventory(
        _ compiled: CompiledCoreIntentCatalog
    ) throws {
        let expected = Set(compiled.definitions.map(\.declaration.name))
        let actual = Set(bindings.map(\.intentID))
        guard bindings.count == actual.count,
              expected == actual
        else {
            throw AppIntentRuntimeError.bindingInventoryMismatch(
                missing: expected.subtracting(actual).sorted {
                    $0.rawValue < $1.rawValue
                },
                unexpected: actual.subtracting(expected).sorted {
                    $0.rawValue < $1.rawValue
                }
            )
        }
    }

    func makeCoreExecutionLanes() throws -> [ProviderExecutionLane] {
        try CoreIntentExecutionLane.allCases.map { lane in
            let intentIDs = try Set(
                CoreIntentName.allCases
                    .filter { $0.executionLane == lane }
                    .map { try $0.intentID }
            )
            return try ProviderExecutionLane(
                intentIDs: intentIDs,
                mailbox: IntentMailbox(
                    limits: try IntentMailboxLimits(
                        maxConcurrentRequests: lane.maxConcurrentRequests
                    )
                )
            )
        }
    }

    func configureTrustedPrincipals(
        _ compiled: CompiledCoreIntentCatalog
    ) async throws {
        let capabilities = Set(
            compiled.definitions.flatMap {
                $0.dispatchRule.capabilityBindings.map(\.capability)
            }
        )
        let grants = Set(capabilities.map { capability in
            let filesystem: FilesystemGrantScope = [
                "filesystem.read",
                "filesystem.write",
                "shell.open",
            ].contains(capability.rawValue) ? .all : .none
            let network: NetworkGrantScope = [
                "network",
                "web.view",
            ].contains(capability.rawValue) ? .all : .none
            return CapabilityGrant(
                capability: capability,
                scope: CapabilityGrantScope(
                    workspaces: .any,
                    panes: .any,
                    filesystem: filesystem,
                    network: network
                )
            )
        })

        try await kernel.policy.replaceGrants(
            grants,
            for: Self.cliPrincipal
        )
    }
}
