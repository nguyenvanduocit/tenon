import Foundation
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// `workspace.pane.title.set.v1` is the one thing an agent can do to the chrome around it:
/// say, on the tab the operator is already looking at, what it is working on.
///
/// It is a public adapter over `WorkspaceStore.renameSlot` — the same typed operation the
/// rename UI and the Companion title generator call DIRECT — so a title set by an agent is
/// indistinguishable from one a person typed, and clearing works the same way for both.
@MainActor
final class PaneTitleIntentTests: XCTestCase {
    func testAnAgentLabelsItsOwnPaneAndAnEmptyTitleReturnsItToTheContentDerivedOne() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        XCTAssertNil(store.catalog.slot(id: paneID)?.customTitle)

        _ = try successReply(
            await invoke(
                .workspacePaneTitleSet,
                input: .object(["title": .string("Fixing the auth flow")]),
                paneID: paneID,
                bindings: bindings
            )
        )
        XCTAssertEqual(
            store.catalog.slot(id: paneID)?.customTitle,
            "Fixing the auth flow"
        )

        // Clearing is the same contract, not a second one: an agent that finishes its work
        // hands the pane back to whatever its content says it is.
        _ = try successReply(
            await invoke(
                .workspacePaneTitleSet,
                input: .object(["title": .string("")]),
                paneID: paneID,
                bindings: bindings
            )
        )
        XCTAssertNil(store.catalog.slot(id: paneID)?.customTitle)
    }

    /// The title is bounded before it reaches the catalog, by the same `PaneTitle` rule a
    /// typed rename passes through. An agent cannot widen a tab chip with 4 KB of prose.
    func testAnOversizedOrWhitespaceOnlyTitleIsBoundedRatherThanRefused() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)

        _ = try successReply(
            await invoke(
                .workspacePaneTitleSet,
                input: .object([
                    "title": .string(String(repeating: "a", count: 4096))
                ]),
                paneID: paneID,
                bindings: bindings
            )
        )
        XCTAssertEqual(
            store.catalog.slot(id: paneID)?.customTitle?.count,
            PaneTitle.maximumLength
        )

        _ = try successReply(
            await invoke(
                .workspacePaneTitleSet,
                input: .object(["title": .string("   \n\t  ")]),
                paneID: paneID,
                bindings: bindings
            )
        )
        XCTAssertNil(store.catalog.slot(id: paneID)?.customTitle)
    }

    /// Scope names the pane, exactly as it does for focus, close, and content — a caller
    /// naming a pane that is not there gets the same typed refusal, and nothing is renamed.
    func testAPaneThatIsNotInTheCatalogIsRefusedWithoutRenamingAnything() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let livePaneID = try XCTUnwrap(store.catalog.activeSlotID)
        store.renameSlot(livePaneID, to: "Untouched")

        let reply = try await invoke(
            .workspacePaneTitleSet,
            input: .object(["title": .string("Should not land")]),
            paneID: UUID(),
            bindings: bindings
        )
        guard case let .failure(error) = reply else {
            return XCTFail("a pane that is not in the catalog must be refused")
        }
        XCTAssertEqual(
            error.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.pane-not-found"))
        )
        XCTAssertEqual(store.catalog.slot(id: livePaneID)?.customTitle, "Untouched")
    }

    /// Scope is the only way to name the pane. A caller that omits it is refused rather than
    /// falling back to whichever pane happens to be focused — the failure mode that would
    /// make one agent rename another agent's work.
    func testAnInvocationWithNoPaneScopeIsRefusedRatherThanRenamingTheFocusedPane() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let focusedPaneID = try XCTUnwrap(store.catalog.activeSlotID)

        let reply = try await invoke(
            .workspacePaneTitleSet,
            input: .object(["title": .string("Should not land")]),
            scope: InvocationScope(),
            bindings: bindings
        )
        guard case .failure = reply else {
            return XCTFail("an unscoped rename must be refused")
        }
        XCTAssertNil(store.catalog.slot(id: focusedPaneID)?.customTitle)
    }
}

private extension PaneTitleIntentTests {
    func invoke(
        _ name: CoreIntentName,
        input: IntentValue,
        paneID: UUID,
        bindings: [IntentProviderBinding]
    ) async throws -> IntentProviderReply {
        try await invoke(
            name,
            input: input,
            scope: InvocationScope(paneID: paneID),
            bindings: bindings
        )
    }

    func invoke(
        _ name: CoreIntentName,
        input: IntentValue,
        scope: InvocationScope,
        bindings: [IntentProviderBinding]
    ) async throws -> IntentProviderReply {
        let intentID = try name.intentID
        let binding = try XCTUnwrap(bindings.first { $0.intentID == intentID })
        let envelope = IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
            caller: IntentPrincipal(
                id: "agent:pane:test",
                kind: .agent,
                sessionRevision: 1
            ),
            scope: scope,
            deadline: .now.advanced(by: .seconds(5)),
            target: nil,
            idempotencyKey: nil
        )
        let context = IntentProviderContext(
            requestID: envelope.requestID,
            nestedSend: { request in
                .failure(
                    error: IntentError(
                        code: .kernel(.internal),
                        details: .string(request.intentID.rawValue),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: nil
                )
            }
        )
        return try await binding.invoke(envelope: envelope, context: context)
    }

    func successReply(_ reply: IntentProviderReply) throws -> IntentValue {
        guard case let .success(value) = reply else {
            XCTFail("expected success, got \(reply)")
            throw TestError.expectedSuccess
        }
        return value
    }

    enum TestError: Error {
        case expectedSuccess
    }
}
