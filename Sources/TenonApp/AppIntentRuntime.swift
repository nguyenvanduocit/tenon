// @domain: intent-bus
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
/// The shared kernel is prepared off `MainActor` before construction. `start()` performs
/// catalog compilation and atomic provider activation once, and concurrent callers join
/// the same in-flight task.
@MainActor
final class AppIntentRuntime {
    /// A person acting, now, in this window. The palette, the launcher, a rebindable
    /// product keybinding, and any other host surface that carries an accepted gesture are
    /// surfaces of this one principal rather than principals of their own — which is why no
    /// separate identity has to be minted for built-in UI.
    /// See `docs/design-open-handlers.md`.
    static let userPrincipal = IntentPrincipal(
        id: "user:tenon",
        kind: .user,
        sessionRevision: 1
    )

    static let cliPrincipal = IntentPrincipal(
        id: "cli:local-user",
        kind: .cli,
        sessionRevision: 1
    )

    /// Tenon's second user, named by the pane it is running in.
    ///
    /// Per pane rather than one process-wide identity, because the product problem is
    /// telling two agents apart and telling either from the person. `PolicyEngine` keys
    /// grants by the whole principal, so each of these has to be registered — see
    /// `agentPrincipal(forPane:)`, which does that once per pane and bounds how many it
    /// keeps.
    ///
    /// It is never constructed from anything a caller said. `IntentPrincipal.audience` is a
    /// computed consequence of `kind` with no writable field behind it, so the only way to
    /// hold this identity is for the host to have handed it to you.
    static func agentPrincipal(forPane paneID: UUID) -> IntentPrincipal {
        IntentPrincipal(
            id: "agent:pane:\(paneID.uuidString)",
            kind: .agent,
            sessionRevision: 1
        )
    }

    /// How many agent panes keep a registered grant set before the oldest is retired.
    ///
    /// Panes come and go for the life of the process, and every mint writes into the policy
    /// engine, so something has to bound it (invariant 10). Eviction costs an evicted pane
    /// one re-registration on its next call, which is idempotent.
    static let agentPrincipalCapacity = 64

    let kernel: IntentKernelComponents

    private let catalog: CoreIntentCatalog
    private let bindings: [IntentProviderBinding]
    private let workspaceStore: WorkspaceStore
    /// The narrowed grant set every agent pane receives, computed once from the compiled
    /// catalog alongside the CLI's. Empty until then, which is the one case
    /// `agentPrincipal(forPane:)` refuses to mint in.
    private var agentGrants: Set<CapabilityGrant> = []
    /// Agent panes whose grants are registered, oldest first.
    private var registeredAgentPanes: [UUID] = []
    private var isStarted = false
    private var startTask: Task<Void, any Error>?
    private var startTaskID: UUID?
    private var lifecycleRevision: UInt64 = 0

    init(
        kernel: IntentKernelComponents,
        workspaceStore: WorkspaceStore,
        terminalSurfaces: SurfacePool,
        webSurfaces: PluginWebSurfacePool,
        userInterface: PluginUIState
    ) throws {
        self.kernel = kernel
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
        collected.append(
            contentsOf: try AgentIntentProvider().bindings()
        )
        bindings = collected
    }

    // MARK: - Durable kernel state  @domain: intent-bus

    /// Opens and prepares durable kernel state away from the UI executor. The returned
    /// components are `Sendable`; the non-Sendable SQLite connection is consumed by the
    /// kernel's idempotency actor before this value crosses back to `MainActor`.
    ///
    /// Standing consent is both written and read here: the writer goes to the engine so a
    /// grant is durable before it is remembered, and what an earlier launch kept is adopted
    /// before any provider can be reached.
    @concurrent
    static func prepareKernel(
        stateRoot: URL,
        confirmationAuthorizer: IntentConfirmationAuthorizer,
        standingConsent: StandingConsentStore? = nil
    ) async throws -> IntentKernelComponents {
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
        let components = try IntentKernelComponents(
            persistence: persistence,
            confirmationAuthorizer: confirmationAuthorizer,
            standingConsentWriter: standingConsent?.writer()
        )
        // Adopted before any provider can be reached, so the first invocation of the launch
        // sees the answers the person already gave rather than asking them again.
        if let kept = standingConsent?.load(), !kept.isEmpty {
            try await components.policy.restoreStandingConsents(kept)
        }
        return components
    }

    // MARK: - Lifecycle  @domain: intent-bus

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

    // MARK: - Dispatch surface  @domain: intent-bus

    /// The principal for one agent pane, with its narrowed grants registered.
    ///
    /// Registration is idempotent — `PolicyEngine.replaceGrants` returns without advancing a
    /// revision when the set is unchanged — so the ordinary path costs one actor hop and
    /// changes nothing.
    ///
    /// Before the catalog is compiled there is no narrowed set to register, and minting then
    /// would produce a principal authorized for nothing at all. That window answers with the
    /// CLI principal: it is the identity every agent call already carries today, so the
    /// failure is the status quo rather than a wider authority than the mint grants.
    func agentPrincipal(forPane paneID: UUID) async -> IntentPrincipal {
        guard !agentGrants.isEmpty else { return Self.cliPrincipal }
        let principal = Self.agentPrincipal(forPane: paneID)
        guard (try? await kernel.policy.replaceGrants(agentGrants, for: principal)) != nil
        else {
            // The grants did not land, so the principal holds none. Handing it back anyway
            // fails the call closed; handing back the CLI principal would answer a policy
            // error by widening authority.
            return principal
        }
        registeredAgentPanes.removeAll { $0 == paneID }
        registeredAgentPanes.append(paneID)
        while registeredAgentPanes.count > Self.agentPrincipalCapacity {
            let evicted = registeredAgentPanes.removeFirst()
            try? await kernel.policy.removePrincipal(
                Self.agentPrincipal(forPane: evicted)
            )
        }
        return principal
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
                tabID: workspaceStore.catalog.activeTab?.id,
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
    // MARK: - Activation  @domain: intent-bus

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

    /// The grants one trusted local principal holds, over the whole compiled catalog.
    ///
    /// `reachesTheNetwork` is the axis the agent principal is narrowed on, and it is the
    /// only difference between the two sets — which is what makes "strictly narrower"
    /// something a test can check rather than something a comment claims.
    ///
    /// Why the network and not something else. The narrowing had to leave the supervised
    /// loop whole — `terminal.open/write/wait/scrollback.read`, `filesystem.*`,
    /// `workspace.*` and `agent.*` are how one agent supervises another, and `AC-FR-024`
    /// forbids silently changing what `tenon.agents.run` can do. The network is where an
    /// agent loses real authority and loses nothing it needs: its own process already has
    /// network access, so fetching through Tenon only borrows the human's identity for the
    /// request, and `url.open.v1` against a remote address stops being a way to drive the
    /// operator's browser. Pane scope was the other candidate and it fails: narrowing
    /// `panes` to the agent's own pane would break `terminal.open.v1`, whose whole job is
    /// to create a pane that is not the caller's.
    /// Capabilities whose entire subject is a remote address. A caller with no network
    /// reach does not hold a `.none`-scoped version of these — it does not hold them,
    /// because a grant that can authorize nothing is dead weight that reads as authority.
    static let networkOnlyCapabilities: Set<String> = ["network", "web.view"]

    static func trustedGrants(
        over compiled: CompiledCoreIntentCatalog,
        reachesTheNetwork: Bool
    ) -> Set<CapabilityGrant> {
        let capabilities = Set(
            compiled.definitions.flatMap {
                $0.dispatchRule.capabilityBindings.map(\.capability)
            }
        )
        return Set(capabilities.compactMap { capability in
            guard reachesTheNetwork
                || !Self.networkOnlyCapabilities.contains(capability.rawValue)
            else { return nil }
            let filesystem: FilesystemGrantScope = [
                "filesystem.read",
                "filesystem.write",
                "shell.open",
            ].contains(capability.rawValue) ? .all : .none
            // `shell.open` covers addresses as well as paths, so its grant has to carry a
            // network scope or `url.open.v1` resolves to no authorized host. It is the one
            // capability the narrowing splits rather than removes: an agent keeps opening
            // files and loses driving the operator's browser to a remote address.
            let network: NetworkGrantScope =
                reachesTheNetwork && [
                    "network",
                    "web.view",
                    "shell.open",
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
    }

    func configureTrustedPrincipals(
        _ compiled: CompiledCoreIntentCatalog
    ) async throws {
        let grants = Self.trustedGrants(over: compiled, reachesTheNetwork: true)
        agentGrants = Self.trustedGrants(over: compiled, reachesTheNetwork: false)

        try await kernel.policy.replaceGrants(
            grants,
            for: Self.cliPrincipal
        )

    }
}
