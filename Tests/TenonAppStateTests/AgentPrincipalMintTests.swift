import Foundation
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// Tenon's second user, given an identity of its own (`AC-FR-037`, T-136).
///
/// The finding this closes: `IntentPrincipal.Kind.agent` was constructed in exactly one
/// place in the tree and it was a test rejecting a spoof. Every call an agent made arrived
/// as the human's `cli:local-user`, so `IntentDispatcher.effectiveConfirmation`'s agent
/// hardening tested a condition production never built.
///
/// What these assert, in order: that a caller descended from a pane's agent is minted
/// `.agent`; that a caller who merely claims to be one is not; that the minted principal
/// holds strictly narrower authority than the CLI principal it replaces while keeping the
/// supervised loop intact; and that the dispatcher's guard now fires on a principal the
/// host actually produces.
@MainActor
final class AgentPrincipalMintTests: XCTestCase {
    private let pane = UUID()

    // MARK: - Fixture

    private func makeRuntime() throws -> AppIntentRuntime {
        let userInterface = PluginUIState()
        return try AppIntentRuntime(
            kernel: IntentKernelComponents(
                persistence: try IntentSQLiteIdempotencyPersistence.inMemory(),
                confirmationAuthorizer: userInterface.confirmationAuthorizer()
            ),
            workspaceStore: WorkspaceStore(),
            terminalSurfaces: SurfacePool(backendName: "Mint") { _, _ in
                StubTerminalSurface()
            },
            webSurfaces: PluginWebSurfacePool(),
            userInterface: userInterface
        )
    }

    /// The shape measured on this machine 2026-08-12: a tool subprocess (68849) whose
    /// parent is the `claude` the pane is running (18432), whose parents run out to the
    /// login shell. `admit` walks it nearest-first.
    private static let insideTheAgent: [Int32] = [68_849, 18_432, 18_347, 18_343]
    /// The same machine, from a shell the person is typing in: nothing in the chain is the
    /// pane's agent.
    private static let besideTheAgent: [Int32] = [70_001, 18_347, 18_343]

    private func principal(
        runtime: AppIntentRuntime,
        peer: Int32?,
        ancestry: [Int32],
        candidates: [AgentPaneCandidate]
    ) async -> IntentPrincipal {
        await CLICommandExecutor.callerPrincipal(
            origin: CLIRequestOrigin(peerProcessID: peer),
            runtime: runtime,
            agentPanes: { candidates },
            ancestry: { _ in ancestry }
        )
    }

    // MARK: - The mint

    func testACallFromInsideAnAgentPaneCarriesTheAgentPrincipal() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()

        let minted = await principal(
            runtime: runtime,
            peer: 68_849,
            ancestry: Self.insideTheAgent,
            candidates: [AgentPaneCandidate(slotID: pane, agentPID: 18_432)]
        )

        XCTAssertEqual(minted.kind, .agent)
        XCTAssertEqual(minted.audience, .agent)
        XCTAssertEqual(minted.id, "agent:pane:\(pane.uuidString)")
    }

    /// Two agents are two identities. The whole point of minting from the pane rather than
    /// from the process is that the host can tell them apart — and tell either from the
    /// person.
    func testTwoAgentPanesMintTwoDifferentIdentities() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()
        let other = UUID()

        let first = await principal(
            runtime: runtime,
            peer: 68_849,
            ancestry: Self.insideTheAgent,
            candidates: [AgentPaneCandidate(slotID: pane, agentPID: 18_432)]
        )
        let second = await principal(
            runtime: runtime,
            peer: 70_500,
            ancestry: [70_500, 25_461],
            candidates: [AgentPaneCandidate(slotID: other, agentPID: 25_461)]
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.kind, .agent)
        XCTAssertEqual(second.kind, .agent)
    }

    // MARK: - What must stay `.cli`

    /// The hard constraint. Nothing a caller can say puts it inside a pane: the identity
    /// material is the kernel's answer for this connection and the host's own reading of
    /// its panes, and neither is reachable from the wire.
    func testACallerOutsideEveryAgentSubtreeStaysCLI() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()

        let minted = await principal(
            runtime: runtime,
            peer: 70_001,
            ancestry: Self.besideTheAgent,
            candidates: [AgentPaneCandidate(slotID: pane, agentPID: 18_432)]
        )

        XCTAssertEqual(minted, AppIntentRuntime.cliPrincipal)
        XCTAssertEqual(minted.kind, .cli)
    }

    /// Every other way the chain can fail to prove a pane lands on the same answer.
    func testEveryUnprovenOriginStaysCLI() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()
        let agentPane = [AgentPaneCandidate(slotID: pane, agentPID: 18_432)]

        // The kernel would not name the peer — an in-process caller, or a socket option
        // that came back empty.
        var minted = await principal(
            runtime: runtime,
            peer: nil,
            ancestry: Self.insideTheAgent,
            candidates: agentPane
        )
        XCTAssertEqual(minted, AppIntentRuntime.cliPrincipal, "an unnamed peer minted an agent")

        // No pane in the workspace is running an agent the host can see.
        minted = await principal(
            runtime: runtime,
            peer: 68_849,
            ancestry: Self.insideTheAgent,
            candidates: []
        )
        XCTAssertEqual(minted, AppIntentRuntime.cliPrincipal, "an empty candidate set minted an agent")

        // The caller's process is gone, so the walk produced nothing.
        minted = await principal(
            runtime: runtime,
            peer: 68_849,
            ancestry: [],
            candidates: agentPane
        )
        XCTAssertEqual(minted, AppIntentRuntime.cliPrincipal, "an empty ancestry minted an agent")
    }

    // MARK: - Authority

    /// The mint must not break the CLI it replaces. Every capability the supervised loop
    /// runs on has to survive it, or an agent's first call fails `missingCapability` and
    /// the identity is worse than none.
    func testTheAgentPrincipalKeepsTheSupervisedLoopCallable() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()
        let agent = await runtime.agentPrincipal(forPane: pane)
        XCTAssertEqual(agent.kind, .agent)

        let callable = Set(
            await runtime.discover(as: agent).items.map(\.name.rawValue)
        )
        for intent in [
            "terminal.open.v1",
            "terminal.write.v1",
            "terminal.wait.v1",
            "terminal.scrollback.read.v1",
            "agent.inventory.v1",
            "agent.command.v1",
            "filesystem.file.read.v1",
            "filesystem.file.write.v1",
        ] {
            XCTAssertTrue(
                callable.contains(intent),
                "\(intent) stopped being callable once the caller became an agent"
            )
        }
    }

    /// …and it must be a real narrowing, or it is theatre. The network is the axis: the
    /// agent principal carries `network: .none` where the CLI principal carries `.all`,
    /// so a fetch through Tenon — and driving the operator's browser to a remote address —
    /// stops being something an agent inherits from the person.
    func testTheAgentPrincipalIsStrictlyNarrowerThanTheCLIPrincipal() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()
        let agent = await runtime.agentPrincipal(forPane: pane)

        let byAgent = Set(await runtime.discover(as: agent).items.map(\.name.rawValue))
        let byPerson = Set(
            await runtime.discover(as: AppIntentRuntime.cliPrincipal)
                .items.map(\.name.rawValue)
        )

        XCTAssertTrue(
            byAgent.isSubset(of: byPerson),
            "the agent principal reached something the person cannot: "
                + "\(byAgent.subtracting(byPerson).sorted())"
        )
        XCTAssertFalse(
            byAgent.contains("network.fetch.v1"),
            "the agent principal kept the human's network authority"
        )
        XCTAssertTrue(
            byPerson.contains("network.fetch.v1"),
            "the CLI principal lost network authority — the narrowing hit the wrong caller"
        )
        // The split, not a removal: `shell.open` survives with `network: .none`, so an
        // agent still opens a file and no longer sends the operator's browser anywhere.
        XCTAssertTrue(
            byAgent.contains("url.open.v1"),
            "the narrowing took away opening a path, which is not a network reach"
        )
    }

    // MARK: - The guard that could not fire

    /// `IntentDispatcher.effectiveConfirmation` forces `.always` for an open-class policy
    /// contract called by an agent audience. The rule was always tested; what it never had
    /// was a principal production could produce. This drives it from one the host minted.
    ///
    /// Delete the `caller.audience == .agent` line and this goes red.
    func testTheDispatchersAgentHardeningFiresOnAMintedPrincipal() async throws {
        let runtime = try makeRuntime()
        try await runtime.start()
        let agent = await runtime.agentPrincipal(forPane: pane)
        let contract = try await Self.openPolicyContract()

        XCTAssertEqual(
            IntentDispatcher.effectiveConfirmation(contract: contract, caller: agent),
            .always,
            "an open-class policy contract did not re-ask a minted agent"
        )
        XCTAssertEqual(
            IntentDispatcher.effectiveConfirmation(
                contract: contract,
                caller: AppIntentRuntime.cliPrincipal
            ),
            .policy,
            "the person lost standing consent"
        )
    }

    // MARK: - Occupancy: what the host itself can see

    /// The host's two readings agreeing is what produces a candidate at all: the hook says
    /// an agent is bound to this pane, and the host's own read of that pane's PTY names a
    /// foreground process in the group the hook declared.
    func testABoundPaneWhoseAgentIsStillItsForegroundProcessIsACandidate() async throws {
        let fixture = try await makeOccupiedPane(declaredGroup: 4_242, observedGroup: 4_242)

        let candidates = await AgentPaneOccupancyReader.candidates(
            surfaces: fixture.surfaces,
            registry: fixture.registry,
            processGroupID: { _ in 4_242 }
        )

        XCTAssertEqual(
            candidates,
            [AgentPaneCandidate(slotID: fixture.paneID, agentPID: 4_242)]
        )
    }

    /// The binding outlives the agent that wrote it — `retainOnly` prunes on pane close,
    /// not on process exit — so without the cross-check a person typing at the shell prompt
    /// they just got back would descend from that pane's foreground process and be minted
    /// an agent out of a dead agent's binding. The host's own reading is what refuses it.
    func testAPaneThatMovedOnFromItsBoundAgentIsNotACandidate() async throws {
        let fixture = try await makeOccupiedPane(declaredGroup: 4_242, observedGroup: 4_242)

        let candidates = await AgentPaneOccupancyReader.candidates(
            surfaces: fixture.surfaces,
            registry: fixture.registry,
            // The agent exited; the pane's foreground is now some other job entirely.
            processGroupID: { _ in 9_999 }
        )

        XCTAssertEqual(candidates, [])
    }

    /// A pane nothing has bound identifies nobody, however ordinary its process looks.
    /// This is what keeps every plain shell pane out of the mint.
    func testAPaneWithNoAgentBoundToItIsNeverACandidate() async throws {
        let surfaces = SurfacePool(backendName: "Occupancy") { _, _ in
            let stub = StubTerminalSurface()
            stub.foregroundPID = 4_242
            return stub
        }
        _ = surfaces.surface(
            for: pane,
            workspacePath: FileManager.default.temporaryDirectory
        )

        let candidates = await AgentPaneOccupancyReader.candidates(
            surfaces: surfaces,
            registry: AgentSessionRegistry(allowedTranscriptRoots: []),
            processGroupID: { _ in 4_242 }
        )

        XCTAssertEqual(candidates, [])
    }

    private struct OccupiedPane {
        let paneID: UUID
        let surfaces: SurfacePool
        let registry: AgentSessionRegistry
    }

    /// One pane with a real surface, a real surface token, and a real hook binding recorded
    /// against both — assembled the way the app assembles it, minus the PTY.
    private func makeOccupiedPane(
        declaredGroup: UInt64,
        observedGroup: UInt64
    ) async throws -> OccupiedPane {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t136-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transcript = sessions.appendingPathComponent("rollout.jsonl")
        try Data().write(to: transcript)

        let paneID = UUID()
        let surfaces = SurfacePool(backendName: "Occupancy") { _, _ in
            let stub = StubTerminalSurface()
            stub.foregroundPID = observedGroup
            return stub
        }
        _ = surfaces.surface(for: paneID, workspacePath: root)
        let identity = try XCTUnwrap(surfaces.agentTerminalIdentity(for: paneID))

        let registry = AgentSessionRegistry(allowedTranscriptRoots: [sessions])
        await registry.record(
            AgentHookEvent(
                paneID: paneID,
                surfaceToken: identity.surfaceToken,
                provider: .codex,
                sessionID: "t136-session",
                transcriptPath: transcript.path,
                hookEventName: "SessionStart",
                agentID: nil,
                processGroupID: declaredGroup
            )
        )
        return OccupiedPane(paneID: paneID, surfaces: surfaces, registry: registry)
    }

    private static func openPolicyContract() async throws -> IntentContract {
        let schema = IntentValue.object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
        let declaration = IntentContractDeclaration(
            name: try IntentID("url.open.v1"),
            contractClass: .open,
            owner: .core,
            inputSchema: schema,
            outputSchema: schema,
            audiences: [.plugin, .cli, .agent],
            effects: try IntentEffects(
                kind: .write,
                idempotency: .none,
                retentionMilliseconds: nil,
                confirmation: .policy,
                external: true
            ),
            title: "Open address",
            description: "test fixture",
            deprecated: false,
            domainErrors: []
        )
        let compiler = IntentSchemaCompiler()
        async let input = compiler.compile(declaration.inputSchema)
        async let output = compiler.compile(declaration.outputSchema)
        return try await IntentContract(
            declaration: declaration,
            inputSchema: input,
            outputSchema: output
        )
    }
}
