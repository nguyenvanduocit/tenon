import Foundation
import XCTest
@testable import TenonIntentCore

/// Falsification criterion #7 of the interaction boundary law speaks of "the budget". Until
/// this test existed the word appeared exactly once in that document, with no number, and
/// `Tests/` contained no performance measurement at all — the criterion could not fail,
/// which makes it a sentiment rather than a falsifier.
///
/// The budget is a **ratio**, not an absolute: one `IntentDispatcher.send` against the same
/// provider operation invoked as a typed DIRECT actor call. An absolute microsecond figure
/// from one machine under one load is unreproducible, and an unreproducible budget is not a
/// budget. The ceiling is read out of the law document itself, so law and enforcement cannot
/// drift apart.
final class IntentKernelLatencyBudgetTests: XCTestCase {
    func testOneKernelSendStaysInsideTheDocumentedLatencyBudget() async throws {
        let law = try lawText()
        let ceiling = try XCTUnwrap(
            Self.firstCapturedInteger(in: law, pattern: #"MUST cost at most (\d+)× the CPU"#),
            """
            The interaction boundary law states no kernel latency ceiling, so falsification \
            criterion #7 cannot fail. Add "### The kernel latency budget" to the performance \
            section, opening with the sentence that one `IntentDispatcher.send` MUST cost at \
            most N× the CPU of the same provider operation invoked as a typed DIRECT call.
            """
        )

        let fixture = try await LatencyBudgetFixture.make()

        for _ in 0 ..< 200 {
            _ = await fixture.service.echo(1)
            _ = await fixture.send(value: 1)
        }

        let sampleCount = 15
        let iterations = 100
        var ratios: [Double] = []
        var directTotal = 0.0
        var intentTotal = 0.0

        for sample in 0 ..< sampleCount {
            let directStart = Self.cpuNanos()
            for iteration in 0 ..< iterations {
                _ = await fixture.service.echo(Int64(iteration))
            }
            let directNanos = Self.cpuNanos() - directStart

            let intentStart = Self.cpuNanos()
            for iteration in 0 ..< iterations {
                _ = await fixture.send(value: Int64(iteration))
            }
            let intentNanos = Self.cpuNanos() - intentStart

            // A degenerate `getrusage` reading would make the ratio meaningless or infinite.
            // Fail loudly on the instrument rather than quietly on the measurement.
            XCTAssertGreaterThan(
                directNanos,
                0,
                "Sample \(sample): the DIRECT baseline consumed no measurable CPU, so the "
                    + "ratio is not a measurement. Suspect the getrusage instrument, not the kernel."
            )

            let directPerCall = directNanos / Double(iterations)
            let intentPerCall = intentNanos / Double(iterations)
            directTotal += directPerCall
            intentTotal += intentPerCall
            ratios.append(intentPerCall / directPerCall)
        }

        let sorted = ratios.sorted()
        // Judge on the BEST sample, not the median. CPU time is load-resistant but not
        // load-proof: a send crosses actors and a mailbox, so under CPU contention it
        // absorbs scheduler work that the DIRECT baseline never pays, and the ratio
        // inflates with other people's processes rather than with our kernel. The least
        // contended sample is the closest thing to the true cost, and it is still a real
        // gate — a genuine regression raises the floor along with everything else. This
        // repo runs many agents at once; a median-based ceiling would measure the crowd.
        let best = try XCTUnwrap(sorted.first)

        XCTAssertLessThanOrEqual(
            best,
            Double(ceiling),
            """
            One `IntentDispatcher.send` costs \(String(format: "%.1f", best))× the CPU of the \
            same operation called DIRECT at its cheapest sample, over the documented ceiling \
            of \(ceiling)×. Median \(String(format: "%.1f", sorted[sorted.count / 2]))×, worst \
            \(String(format: "%.1f", sorted.last ?? 0))×; direct \
            \(String(format: "%.0f", directTotal / Double(sampleCount))) ns/call, intent \
            \(String(format: "%.0f", intentTotal / Double(sampleCount))) ns/call. \
            The likely causes are a JSON round trip between in-process Swift layers, a \
            per-send schema recompile, or a second policy pass.
            """
        )
    }

    func testTheDirectBaselineDoesTheSameWorkAsTheProvider() async throws {
        let fixture = try await LatencyBudgetFixture.make()

        guard case let .success(success) = await fixture.send(value: 7) else {
            XCTFail("The fixture's own intent must succeed before it can be a denominator")
            return
        }
        let direct = await fixture.service.echo(7)

        XCTAssertEqual(success.value, .object(["echo": .integer(7)]))
        XCTAssertEqual(direct, .object(["echo": .integer(7)]))
        XCTAssertEqual(
            success.value,
            direct,
            """
            The DIRECT baseline and the provider must compute the same result. The documented \
            ceiling over a denominator that does less work is satisfiable by inflating the \
            denominator rather than by keeping the kernel cheap.
            """
        )
    }
}

/// The typed DIRECT denominator: an `actor` method returning the same `IntentValue`, awaited
/// from the same context, so both arms pay exactly one actor hop. A non-actor baseline would
/// omit the hop the intent path necessarily pays and inflate the ratio for free.
private actor DirectEchoService {
    func echo(_ value: Int64) -> IntentValue {
        .object(["echo": .integer(value)])
    }
}

private struct LatencyBudgetFixture: Sendable {
    let intentID: IntentID
    let caller: IntentPrincipal
    let service: DirectEchoService
    let dispatcher: IntentDispatcher

    static func make() async throws -> LatencyBudgetFixture {
        let intentID = try IntentID("test.echo.v1")
        let providerID = try ProviderID("dev.tenon.test-provider")
        let capability = try CapabilityID("test.invoke")
        let caller = IntentPrincipal(
            id: "plugin:dev.tenon.test:latency",
            kind: .plugin,
            sessionRevision: 1
        )
        let service = DirectEchoService()

        let catalog = ContractCatalog()
        _ = try await catalog.register(
            IntentContractDeclaration(
                name: intentID,
                contractClass: .sealed,
                owner: .core,
                inputSchema: objectSchema(
                    properties: [
                        "value": .object(["type": .string("integer")])
                    ],
                    required: ["value"]
                ),
                outputSchema: objectSchema(
                    properties: [
                        "echo": .object(["type": .string("integer")])
                    ],
                    required: ["echo"]
                ),
                audiences: [.core, .plugin],
                effects: .pessimistic,
                title: "Echo",
                description: nil,
                deprecated: false,
                domainErrors: []
            )
        )

        let policy = PolicyEngine()
        try await policy.replaceDeclaredUses([intentID], for: caller)
        try await policy.replaceGrants(
            [
                CapabilityGrant(
                    capability: capability,
                    scope: CapabilityGrantScope(
                        workspaces: .any,
                        panes: .any,
                        filesystem: .none
                    )
                )
            ],
            for: caller
        )

        let registry = ProviderRegistry()
        let mailbox = IntentMailbox(limits: try IntentMailboxLimits())
        let candidate = try ProviderGenerationCandidate(
            providerID: providerID,
            owner: .core,
            principal: IntentProviderOwner.core.principal(sessionRevision: 1),
            generation: 1,
            bindings: [
                IntentProviderBinding(intentID: intentID) { envelope, _ in
                    guard case let .object(fields) = envelope.input,
                        case let .integer(value)? = fields["value"]
                    else {
                        return .failure(
                            IntentProviderFailure(code: .kernel(.invalidInput))
                        )
                    }
                    return .success(await service.echo(value))
                }
            ],
            policyFingerprint: try PolicyFingerprint(
                canonicalPolicy: .object(["provider": .string(providerID.rawValue)])
            ),
            mailbox: mailbox
        )
        try await registry.stage(candidate)
        try await registry.activate(providerID: providerID, generation: 1)

        let dispatcher = IntentDispatcher(
            catalog: catalog,
            policy: policy,
            registry: registry,
            idempotency: try IntentIdempotencyStore(
                limits: IntentIdempotencyLimits(),
                persistence: IntentSQLiteIdempotencyPersistence.inMemory()
            ),
            telemetry: try IntentTelemetry(),
            limits: try IntentDispatcherLimits(),
            confirmationAuthorizer: IntentConfirmationAuthorizer { _ in .allowOnce }
        )
        try await dispatcher.registerRule(
            IntentDispatchRule(
                intentID: intentID,
                capabilityBindings: [IntentCapabilityBinding(capability: capability)],
                exposure: IntentExposure(
                    discoverableBy: [.core, .plugin],
                    invocableBy: [.core, .plugin]
                ),
                trustedDefault: providerID,
                allowsAutomaticSelection: false,
                providerConsent: .never,
                admissionClass: .interactive
            )
        )

        return LatencyBudgetFixture(
            intentID: intentID,
            caller: caller,
            service: service,
            dispatcher: dispatcher
        )
    }

    func send(value: Int64) async -> IntentResult {
        await dispatcher.send(
            IntentDispatchRequest(
                intentID: intentID,
                input: .object(["value": .integer(value)]),
                caller: caller,
                idempotencyKey: nil,
                requestedTimeout: nil
            )
        )
    }
}

private extension IntentKernelLatencyBudgetTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func lawText() throws -> String {
        let url = packageRoot
            .appendingPathComponent("docs/architecture-interaction-boundaries.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// User + system CPU nanoseconds. `RUSAGE_SELF` is **process**-wide and every test target
    /// links into one `TenonPackageTests.xctest`, so background work leaked by other test
    /// classes — plugin runtimes, FSEvents, automation schedulers — lands in both arms. Because
    /// contamination scales with each arm's elapsed time it largely cancels in the ratio, but it
    /// is the first thing to suspect if this test starts drifting. This measurement is valid
    /// only while XCTest runs test classes serially; under parallel test classes it must be
    /// revised, not suppressed.
    static func cpuNanos() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) * 1_000_000_000
            + Double(usage.ru_utime.tv_usec) * 1_000
        let system = Double(usage.ru_stime.tv_sec) * 1_000_000_000
            + Double(usage.ru_stime.tv_usec) * 1_000
        return user + system
    }

    static func firstCapturedInteger(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[captured])
    }
}
