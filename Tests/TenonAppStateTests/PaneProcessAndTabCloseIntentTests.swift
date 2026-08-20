import Foundation
import SwiftUI
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// T-132 (a) and (c) at the provider seam: the two answers reaching a caller outside the
/// host, over the typed services the app's own UI already calls.
@MainActor
final class PaneProcessAndTabCloseIntentTests: XCTestCase {
    // MARK: - (a) terminal.process.read.v1

    func testProcessReadNamesTheTtyAndForegroundProcessOfAMaterialisedPane() async throws {
        let store = WorkspaceStore()
        let registry = StubProvenanceRegistry()
        let pool = SurfacePool(backendName: "Stub") { slotID, _ in
            registry.surface(for: slotID)
        }
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        let surface = registry.surface(for: paneID)
        surface.ttyName = "/dev/ttys012"
        surface.foregroundPID = 4242
        _ = pool.surface(
            for: paneID,
            workspacePath: FileManager.default.temporaryDirectory
        )

        let value = try successReply(
            await invoke(
                .terminalProcessRead,
                paneID: paneID,
                store: store,
                pool: pool
            )
        )
        XCTAssertEqual(
            value,
            .object([
                "paneID": .string(paneID.uuidString),
                "ttyName": .string("/dev/ttys012"),
                "foregroundPID": .integer(4242),
            ])
        )
    }

    /// A pane the canvas has never displayed holds no surface, so it has no PTY and no
    /// foreground process. Saying so with nulls is the answer; inventing an error would
    /// make "this pane is idle" indistinguishable from "this pane does not exist".
    func testProcessReadAnswersNullsForAPaneThatNeverMaterialised() async throws {
        let store = WorkspaceStore()
        let pool = SurfacePool(backendName: "Stub") { _, _ in
            StubProvenanceSurface()
        }
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)

        let value = try successReply(
            await invoke(
                .terminalProcessRead,
                paneID: paneID,
                store: store,
                pool: pool
            )
        )
        XCTAssertEqual(
            value,
            .object([
                "paneID": .string(paneID.uuidString),
                "ttyName": .null,
                "foregroundPID": .null,
            ])
        )
    }

    func testProcessReadRefusesAPaneThatIsNotATerminal() async throws {
        let store = WorkspaceStore()
        let pool = SurfacePool(backendName: "Stub") { _, _ in
            StubProvenanceSurface()
        }
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        store.setSlotContent(paneID, .changes)

        let reply = try await invoke(
            .terminalProcessRead,
            paneID: paneID,
            store: store,
            pool: pool
        )
        guard case let .failure(failure) = reply else {
            return XCTFail("a non-terminal pane must not answer a process read")
        }
        XCTAssertEqual(
            failure.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.terminal-unavailable"))
        )
    }

    // MARK: - (c) workspace.tab.close.v1

    func testTabCloseRemovesTheScopedTabAndEveryPaneUnderIt() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        store.newTab(content: .terminal)
        let closing = try XCTUnwrap(store.catalog.activeTab)
        let closingPaneIDs = Set(closing.slots.map(\.id))
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, 2)
        XCTAssertFalse(closingPaneIDs.isEmpty)

        _ = try successReply(
            await invoke(
                .workspaceTabClose,
                scope: InvocationScope(tabID: closing.id),
                bindings: bindings
            )
        )

        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, 1)
        XCTAssertFalse(
            store.catalog.activeWorkspace?.tabs.contains { $0.id == closing.id } ?? true
        )
        for paneID in closingPaneIDs {
            XCTAssertNil(
                store.catalog.slot(id: paneID),
                "closing a tab must take its panes with it"
            )
        }
    }

    /// `WorkspaceCatalog.closeTab` keeps a workspace's last tab (`Workspace.swift:613`) and
    /// answers with no events. A scripted caller meets that case on its first loop, so the
    /// intent has to name it rather than report a success that closed nothing.
    func testClosingTheOnlyTabIsARefusalWithANamedCode() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let onlyTab = try XCTUnwrap(store.catalog.activeTab)
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, 1)

        let reply = try await invoke(
            .workspaceTabClose,
            scope: InvocationScope(tabID: onlyTab.id),
            bindings: bindings
        )
        guard case let .failure(failure) = reply else {
            return XCTFail("closing the last tab must not report success")
        }
        XCTAssertEqual(
            failure.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.close-refused"))
        )
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, 1)
    }

    func testTabCloseWithoutATabInScopeIsNotFound() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        store.newTab(content: .terminal)

        let reply = try await invoke(
            .workspaceTabClose,
            scope: InvocationScope(),
            bindings: bindings
        )
        guard case let .failure(failure) = reply else {
            return XCTFail("an unscoped tab close must not guess a tab")
        }
        XCTAssertEqual(
            failure.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.tab-not-found"))
        )
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, 2)
    }

    // MARK: - workspace.pane.close.v2

    /// `workspace.pane.close.v2` closes the pane it was scoped to and nothing else (T-193).
    /// The tab it emptied stays, holding one `.empty` pane, because a close names no other
    /// destination for the work — only a cross-tab *move* does, and only that closes the
    /// tab it emptied. The provider's own success guard reads "`closingPaneID` is gone",
    /// which the fresh placeholder identity satisfies (`WorkspaceIntentProvider.swift:552`).
    ///
    /// **Open, deliberately not decided here:** the 2026-08-13 decision row minted `.v2`
    /// precisely because *adding* this tab removal "changes observable side-effect meaning,
    /// so same-major evolution is forbidden". Removing it again is the same kind of change,
    /// which argues for a `.v3`; that reaches `CoreIntentName.swift`,
    /// `CoreCommandsPlugin.swift`, `plugins/core-commands/manifest.json` and three design
    /// docs, none of them in T-193's claimed file set. Recorded in `spatial-panes.prd.md`'s
    /// decision log for an owner to settle.
    func testPaneCloseLeavesItsEmptiedTabStandingWithAnEmptyPane() async throws {
        let store = WorkspaceStore()
        let closingTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        let closingPaneID = try XCTUnwrap(store.catalog.activeSlotID)
        store.newTab(content: .terminal)
        let survivingTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.selectTab(closingTabID)

        _ = try successReply(
            await invoke(
                .workspacePaneClose,
                scope: InvocationScope(paneID: closingPaneID),
                bindings: try WorkspaceIntentProvider(store: store).bindings()
            )
        )

        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.map(\.id),
            [closingTabID, survivingTabID],
            "closing a pane removes that pane, never the tab holding it"
        )
        XCTAssertNil(store.catalog.slot(id: closingPaneID))
        let emptied = try XCTUnwrap(
            store.catalog.activeWorkspace?.tabs.first { $0.id == closingTabID }
        )
        XCTAssertEqual(emptied.slots.map(\.content), [.empty])
        XCTAssertEqual(emptied.activeSlotID, emptied.slots.first?.id)
    }
}

// MARK: - Fixture

private extension PaneProcessAndTabCloseIntentTests {
    func invoke(
        _ name: CoreIntentName,
        paneID: UUID,
        store: WorkspaceStore,
        pool: SurfacePool
    ) async throws -> IntentProviderReply {
        try await invoke(
            name,
            scope: InvocationScope(paneID: paneID),
            bindings: try TerminalIntentProvider(
                store: store,
                surfaces: pool
            ).bindings()
        )
    }

    func invoke(
        _ name: CoreIntentName,
        scope: InvocationScope,
        bindings: [IntentProviderBinding]
    ) async throws -> IntentProviderReply {
        let intentID = try name.intentID
        let binding = try XCTUnwrap(
            bindings.first { $0.intentID == intentID },
            "no provider binding for \(name.rawValue)"
        )
        let envelope = IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: .object([:]),
            caller: IntentPrincipal(
                id: "test:t132",
                kind: .cli,
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
            throw AppIntentInputError.expectedObject
        }
        return value
    }
}

/// One stub per slot, so a test can set the PTY facts the pool will read back.
@MainActor
private final class StubProvenanceRegistry {
    private var bySlot: [UUID: StubProvenanceSurface] = [:]

    func surface(for slotID: UUID) -> StubProvenanceSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = StubProvenanceSurface()
        bySlot[slotID] = created
        return created
    }
}

/// A pane whose process identity the test decides. A PTY is the one thing a headless run
/// cannot have; `ttyName` and `foregroundPID` are exactly what the real surface reports.
@MainActor
private final class StubProvenanceSurface: TerminalSurface {
    let backendName = "Stub"
    var onTitleChange: ((String) -> Void)?
    var processExited = false
    var ttyName: String?
    var foregroundPID: UInt64?

    func makeView() -> AnyView { AnyView(EmptyView()) }
}
