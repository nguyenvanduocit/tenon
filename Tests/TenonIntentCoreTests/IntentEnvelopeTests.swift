import Foundation
import XCTest
@testable import TenonIntentCore

final class IntentEnvelopeTests: XCTestCase {
    func testScopeOverrideRetargetsEntitiesButPreservesHostGesture() {
        let inheritedWorkspace = UUID()
        let inheritedPane = UUID()
        let gesture = UUID()
        let targetWorkspace = UUID()

        let applied = InvocationScopeOverride(
            workspaceID: targetWorkspace
        ).applying(
            to: InvocationScope(
                workspaceID: inheritedWorkspace,
                paneID: inheritedPane,
                userGestureID: gesture
            )
        )

        XCTAssertEqual(applied.workspaceID, targetWorkspace)
        XCTAssertNil(applied.paneID)
        XCTAssertEqual(applied.userGestureID, gesture)
    }

    func testEnvelopeCarriesOnlyHostMintedImmutableMetadataAndOwnedInput() throws {
        let requestID = UUID()
        let traceID = UUID()
        let parentRequestID = UUID()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let principal = IntentPrincipal(
            id: "plugin:dev.tenon.git",
            kind: .plugin,
            sessionRevision: 7
        )
        let scope = InvocationScope(
            workspaceID: UUID(),
            paneID: UUID(),
            userGestureID: UUID()
        )

        let envelope = IntentEnvelope(
            requestID: requestID,
            traceID: traceID,
            parentRequestID: parentRequestID,
            name: try IntentID("terminal.run.v1"),
            input: .object(["command": .string("git status")]),
            caller: principal,
            scope: scope,
            deadline: deadline,
            target: try ProviderID("core.terminal"),
            idempotencyKey: "terminal-run-1"
        )

        XCTAssertEqual(envelope.requestID, requestID)
        XCTAssertEqual(envelope.traceID, traceID)
        XCTAssertEqual(envelope.parentRequestID, parentRequestID)
        XCTAssertEqual(envelope.name.rawValue, "terminal.run.v1")
        XCTAssertEqual(envelope.caller, principal)
        XCTAssertEqual(envelope.scope, scope)
        XCTAssertEqual(envelope.target?.rawValue, "core.terminal")
        XCTAssertEqual(envelope.idempotencyKey, "terminal-run-1")
        XCTAssertEqual(envelope.deadline, deadline)
    }

    func testPrincipalAudienceIsDerivedExhaustivelyFromKind() {
        let pairs: [(IntentPrincipal.Kind, IntentAudience)] = [
            (.core, .core),
            (.plugin, .plugin),
            (.user, .user),
            (.cli, .cli),
            (.agent, .agent),
        ]

        XCTAssertEqual(pairs.count, IntentPrincipal.Kind.allCases.count)
        XCTAssertEqual(pairs.count, IntentAudience.allCases.count)
        for (kind, expectedAudience) in pairs {
            XCTAssertEqual(
                IntentPrincipal(
                    id: "principal:\(kind.rawValue)",
                    kind: kind,
                    sessionRevision: 1
                ).audience,
                expectedAudience
            )
        }
    }

    func testEffectsRequireRetentionForKeyedIdempotency() {
        XCTAssertThrowsError(
            try IntentEffects(
                kind: .write,
                idempotency: .keyed,
                retentionMilliseconds: nil,
                confirmation: .policy,
                external: false
            )
        )

        XCTAssertNoThrow(
            try IntentEffects(
                kind: .write,
                idempotency: .keyed,
                retentionMilliseconds: 60_000,
                confirmation: .policy,
                external: false
            )
        )
    }

    func testPessimisticEffectsMatchUntrustedPluginDefaults() {
        XCTAssertEqual(IntentEffects.pessimistic.kind, .write)
        XCTAssertEqual(IntentEffects.pessimistic.idempotency, .none)
        XCTAssertNil(IntentEffects.pessimistic.retentionMilliseconds)
        XCTAssertEqual(IntentEffects.pessimistic.confirmation, .policy)
        XCTAssertTrue(IntentEffects.pessimistic.external)
    }

    func testFoundationTypesAreSendable() throws {
        assertSendable(IntentValue.self)
        assertSendable(IntentEnvelope.self)
        assertSendable(IntentPrincipal.self)
        assertSendable(IntentEffects.self)
        assertSendable(IntentResult.self)
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
