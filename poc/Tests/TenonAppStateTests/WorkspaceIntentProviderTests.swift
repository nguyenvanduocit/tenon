import Foundation
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

/// `workspace.content.open.v1` is the public adapter over the same typed placement policy
/// the built-in Changes panel calls DIRECT: reuse the tab's pane for this kind of content,
/// split beside it when there is none, and never open a tab.
@MainActor
final class WorkspaceIntentProviderTests: XCTestCase {
    func testTabCreationConsumesTheTitleBarPlusReservation() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let originalTabCount = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            guard let reply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("docs")])
                ]),
                scope: scope,
                bindings: bindings
            ), case .success = reply else { return nil }
            return self.intentSuccess()
        }

        guard case .success = result else {
            return XCTFail("the tab-create intent should succeed")
        }
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, originalTabCount + 1)
        XCTAssertEqual(store.catalog.activeTab?.slots.map(\.content), [.docs])
    }

    func testDifferentGestureCannotConsumeTheTitleBarPlusReservation() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let originalTabCount = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)

        _ = await NewTabLauncherPlacement.invoke(in: store) { scope in
            let unrelatedScope = InvocationScope(
                workspaceID: scope.workspaceID,
                paneID: scope.paneID,
                userGestureID: UUID()
            )
            guard let reply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("terminal")])
                ]),
                scope: unrelatedScope,
                bindings: bindings
            ), case .success = reply else { return nil }
            return self.intentSuccess()
        }

        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, originalTabCount + 2)
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .empty })
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .terminal })
    }

    func testReservationCanBeConsumedOnlyOnce() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let originalTabCount = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)

        _ = await NewTabLauncherPlacement.invoke(in: store) { scope in
            guard let firstReply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("empty")])
                ]),
                scope: scope,
                bindings: bindings
            ), case .success = firstReply,
            let secondReply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("docs")])
                ]),
                scope: scope,
                bindings: bindings
            ), case .success = secondReply else { return nil }
            return self.intentSuccess()
        }

        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, originalTabCount + 2)
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .empty })
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .docs })
    }

    func testReservationConsumptionPreservesNewerWorkspaceNavigation() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let sourceWorkspaceID = store.catalog.activeWorkspaceID
        store.addWorkspace(
            name: "Other",
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        let newerWorkspaceID = store.catalog.activeWorkspaceID
        store.selectWorkspace(sourceWorkspaceID)

        _ = await NewTabLauncherPlacement.invoke(in: store) { scope in
            store.selectWorkspace(newerWorkspaceID)
            guard let reply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("docs")])
                ]),
                scope: scope,
                bindings: bindings
            ), case .success = reply else { return nil }
            return self.intentSuccess()
        }

        XCTAssertEqual(store.catalog.activeWorkspaceID, newerWorkspaceID)
        let sourceTabs = try XCTUnwrap(
            store.catalog.workspaces.first { $0.id == sourceWorkspaceID }?.tabs
        )
        XCTAssertEqual(sourceTabs.count, 2)
        XCTAssertTrue(sourceTabs.flatMap(\.slots).contains { $0.content == .docs })
    }

    func testOpeningAFileReusesThePaneAndNeverOpensATab() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        let panes = store.catalog.activeTab?.slots.count ?? 0
        let tabs = store.catalog.activeWorkspace?.tabs.count ?? 0

        _ = try successReply(
            await invoke(.workspaceContentOpen, file: "a.swift", paneID: paneID, bindings: bindings)
        )
        XCTAssertEqual(store.catalog.activeTab?.slots.count, panes + 1, "one editor pane opened")
        XCTAssertEqual(filePaths(store), ["a.swift"])

        _ = try successReply(
            await invoke(.workspaceContentOpen, file: "b.swift", paneID: paneID, bindings: bindings)
        )
        XCTAssertEqual(
            store.catalog.activeTab?.slots.count,
            panes + 1,
            "the second file reused the editor pane"
        )
        XCTAssertEqual(filePaths(store), ["b.swift"])
        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.count,
            tabs,
            "opening content never adds a tab"
        )
    }

    func testOpeningLandsInTheScopePanesTabNotTheActiveOne() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let firstTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        let scopePaneID = try XCTUnwrap(store.catalog.activeSlotID)
        store.newTab(content: .terminal)
        let secondTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        XCTAssertNotEqual(firstTabID, secondTabID)

        _ = try successReply(
            await invoke(
                .workspaceContentOpen,
                file: "a.swift",
                paneID: scopePaneID,
                bindings: bindings
            )
        )

        let firstTab = try XCTUnwrap(
            store.catalog.activeWorkspace?.tabs.first { $0.id == firstTabID }
        )
        let secondTab = try XCTUnwrap(
            store.catalog.activeWorkspace?.tabs.first { $0.id == secondTabID }
        )
        XCTAssertTrue(
            firstTab.slots.contains { $0.content == .file(path: "a.swift") },
            "the caller's own tab took the file"
        )
        XCTAssertFalse(
            secondTab.slots.contains { $0.content == .file(path: "a.swift") },
            "the other tab was left alone"
        )
    }

    func testOpeningIntoAnEmptyTabAddsItsFirstPaneAndNeverOpensATab() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let tabID = try XCTUnwrap(store.catalog.activeTab?.id)
        let workspaceID = store.catalog.activeWorkspaceID
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)
        store.closeActiveSlot()
        XCTAssertEqual(store.catalog.activeTab?.slots, [])

        _ = try successReply(
            await invoke(
                .workspaceContentOpen,
                input: .object([
                    "content": .object([
                        "kind": .string("file"),
                        "path": .string("empty-tab.swift"),
                    ])
                ]),
                scope: InvocationScope(workspaceID: workspaceID),
                bindings: bindings
            )
        )

        XCTAssertEqual(store.catalog.activeTab?.id, tabID)
        XCTAssertEqual(filePaths(store), ["empty-tab.swift"])
        XCTAssertEqual(store.catalog.activeTab?.slots.count, 1)
        XCTAssertEqual(
            store.catalog.activeWorkspace?.tabs.count,
            tabs,
            "opening content into an empty tab must add a pane, never another tab"
        )
    }

    func testOpeningRejectsAMissingContentField() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)

        let reply = try await invoke(
            .workspaceContentOpen,
            input: .object([:]),
            paneID: paneID,
            bindings: bindings
        )
        guard case .failure = reply else {
            return XCTFail("content is required, got \(reply)")
        }
        XCTAssertEqual(store.catalog.activeTab?.slots.count, 1, "nothing was placed")
    }

    func testOpeningRejectsAPaneScopeThatIsGone() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        let reply = try await invoke(
            .workspaceContentOpen,
            file: "a.swift",
            paneID: UUID(),
            bindings: bindings
        )
        guard case let .failure(failure) = reply else {
            return XCTFail("a stale pane scope must fail closed, got \(reply)")
        }
        XCTAssertEqual(
            failure.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.pane-not-found"))
        )
        XCTAssertEqual(filePaths(store), [], "nothing was placed")
    }
}

private extension WorkspaceIntentProviderTests {
    func intentSuccess() -> IntentResult {
        .success(
            value: .object([:]),
            requestID: UUID(),
            providerID: try! ProviderID("dev.tenon.test")
        )
    }

    func filePaths(_ store: WorkspaceStore) -> [String] {
        (store.catalog.activeTab?.slots ?? []).compactMap {
            if case let .file(path) = $0.content { return path }
            return nil
        }
    }

    func invoke(
        _ name: CoreIntentName,
        file path: String,
        paneID: UUID,
        bindings: [IntentProviderBinding]
    ) async throws -> IntentProviderReply {
        try await invoke(
            name,
            input: .object([
                "content": .object([
                    "kind": .string("file"),
                    "path": .string(path),
                ])
            ]),
            paneID: paneID,
            bindings: bindings
        )
    }

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
                id: "test:workspace-provider",
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
            throw TestError.expectedSuccess
        }
        return value
    }

    enum TestError: Error {
        case expectedSuccess
    }
}
