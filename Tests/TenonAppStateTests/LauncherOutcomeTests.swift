import TenonIntentCore
import XCTest
@testable import TenonApp
@testable import TenonCore

/// One launcher choice, one settlement rule, shared by every surface that presents the
/// launcher catalog (`+`, a tab's right-click). These pin the rules headlessly: frecency
/// learns only from a command that actually ran, an error is reported where the click
/// happened, and only success closes the launcher.
@MainActor
final class LauncherOutcomeTests: XCTestCase {
    private func success() throws -> IntentResult {
        .success(
            value: .object(["ok": .bool(true)]),
            requestID: UUID(),
            providerID: try ProviderID("dev.tenon.test")
        )
    }

    private func failure(
        code: IntentKernelErrorCode,
        outcome: IntentOutcome = .notStarted
    ) -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(code),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: outcome
            ),
            requestID: UUID(),
            providerID: nil
        )
    }

    func testASuccessfulRunRecordsFrecencyAndClosesTheLauncher() throws {
        let outcome = LauncherOutcome(try success())

        XCTAssertEqual(outcome, .ran)
        XCTAssertTrue(outcome.recordsFrecency)
        XCTAssertTrue(outcome.dismisses)
        XCTAssertNil(outcome.errorMessage)
    }

    func testAFailureIsReportedInPlaceAndTeachesTheRankingNothing() {
        let outcome = LauncherOutcome(failure(code: .denied))

        XCTAssertEqual(outcome, .failed(code: "tenon.denied"))
        XCTAssertFalse(outcome.recordsFrecency)
        XCTAssertFalse(outcome.dismisses)
        XCTAssertEqual(outcome.errorMessage, "tenon.denied")
    }

    func testAVanishedIntentSaysSoAndTeachesTheRankingNothing() {
        let outcome = LauncherOutcome(nil)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(outcome.recordsFrecency)
        XCTAssertFalse(outcome.dismisses)
        XCTAssertEqual(outcome.errorMessage, "Intent is no longer available.")
    }

    func testEmptyGridPlacementFillsTheExactReservedRectangle() async throws {
        let fixture = makeHalfCanvasStore()
        let target = GridRect(x: 6, y: 0, width: 6, height: 12)

        let outcome = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: target
        ) { scope in
            let paneID = try! XCTUnwrap(scope.paneID)
            XCTAssertEqual(fixture.store.catalog.slot(id: paneID)?.rect, target)
            XCTAssertEqual(fixture.store.catalog.slot(id: paneID)?.content, .empty)
            fixture.store.focusSlot(paneID)
            fixture.store.openContent(.changes)
            return try! self.success()
        }

        XCTAssertEqual(outcome, .ran)
        XCTAssertEqual(fixture.store.catalog.slot(id: fixture.originalID)?.rect, fixture.originalRect)
        XCTAssertEqual(
            fixture.store.catalog.activeTab?.slots.first(where: { $0.id != fixture.originalID })?.content,
            .changes
        )
        XCTAssertEqual(
            fixture.store.catalog.activeTab?.slots.first(where: { $0.id != fixture.originalID })?.rect,
            target
        )
    }

    func testEmptyGridPlacementConsumesPaneFillingTabCreation() async throws {
        let fixture = makeHalfCanvasStore()
        let target = GridRect(x: 6, y: 0, width: 6, height: 12)
        let originalTabCount = try XCTUnwrap(fixture.store.catalog.activeWorkspace?.tabs.count)

        let outcome = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: target
        ) { scope in
            XCTAssertEqual(
                EmptyGridLauncherPlacement.consumeReservedTabCreation(
                    scope: scope,
                    content: .changes,
                    store: fixture.store
                ),
                .consumed
            )
            return try! self.success()
        }

        XCTAssertEqual(outcome, .ran)
        XCTAssertEqual(fixture.store.catalog.activeWorkspace?.tabs.count, originalTabCount)
        XCTAssertEqual(
            fixture.store.catalog.activeTab?.slots.first(where: { $0.id != fixture.originalID })?.content,
            .changes
        )
    }

    func testEmptyGridFailureRemovesReservationWithoutExpandingItsNeighbor() async throws {
        let fixture = makeHalfCanvasStore()

        let outcome = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: GridRect(x: 6, y: 0, width: 6, height: 12)
        ) { _ in
            self.failure(code: .denied)
        }

        XCTAssertEqual(outcome, .failed(code: "tenon.denied"))
        XCTAssertEqual(fixture.store.catalog.activeTab?.slots.map(\.id), [fixture.originalID])
        XCTAssertEqual(fixture.store.catalog.slot(id: fixture.originalID)?.rect, fixture.originalRect)
        XCTAssertEqual(fixture.store.catalog.activeSlotID, fixture.originalID)
    }

    func testEmptyGridSuccessThatDoesNotFillTargetStaysOpenAndRollsBack() async throws {
        let fixture = makeHalfCanvasStore()

        let outcome = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: GridRect(x: 6, y: 0, width: 6, height: 12)
        ) { _ in
            try! self.success()
        }

        XCTAssertEqual(outcome, .targetNotFilled)
        XCTAssertFalse(outcome.dismisses)
        XCTAssertEqual(outcome.errorMessage, "This item could not fill this space.")
        XCTAssertEqual(fixture.store.catalog.activeTab?.slots.map(\.id), [fixture.originalID])
    }

    func testPlusPlacementScopesContentIntoAFreshTab() async throws {
        let store = WorkspaceStore()
        let originalTab = try XCTUnwrap(store.catalog.activeTab)
        let content = SlotContent.pluginView(
            pluginID: "dev.tenon.test",
            viewID: "board"
        )

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            let paneID = try! XCTUnwrap(scope.paneID)
            XCTAssertNotEqual(paneID, originalTab.activeSlotID)
            XCTAssertEqual(store.catalog.slot(id: paneID)?.content, .empty)
            store.focusSlot(paneID)
            store.openContent(content)
            return try! self.success()
        }

        guard case .success = result else {
            return XCTFail("the launcher intent should succeed")
        }
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(
            tabs.first { $0.id == originalTab.id }?.slots.map(\.content),
            [.terminal],
            "the tab the plus was clicked beside stays untouched"
        )
        XCTAssertEqual(store.catalog.activeTab?.slots.map(\.content), [content])
    }

    func testPlusPlacementKeepsOnlyTheTabCreatedByTheCommand() async throws {
        let store = WorkspaceStore()
        let originalTabIDs = Set(
            try XCTUnwrap(store.catalog.activeWorkspace?.tabs.map(\.id))
        )

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            XCTAssertEqual(
                store.catalog.slot(id: try! XCTUnwrap(scope.paneID))?.content,
                .empty
            )
            XCTAssertTrue(NewTabLauncherPlacement.consumeReservedTabCreation(
                scope: scope,
                content: .changes,
                store: store
            ))
            return try! self.success()
        }

        guard case .success = result else {
            return XCTFail("the launcher intent should succeed")
        }
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, originalTabIDs.count + 1)
        XCTAssertEqual(store.catalog.activeTab?.slots.map(\.content), [.changes])
        XCTAssertFalse(
            tabs.flatMap(\.slots).contains { $0.content == .empty },
            "the scoped placeholder is collapsed when the intent opens its own tab"
        )
    }

    func testPlusPlacementDoesNotMistakeAnUnrelatedNewTabForItsResult() async throws {
        let store = WorkspaceStore()

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            XCTAssertFalse(NewTabLauncherPlacement.consumeReservedTabCreation(
                scope: InvocationScope(
                    workspaceID: scope.workspaceID,
                    paneID: scope.paneID,
                    userGestureID: UUID()
                ),
                content: .terminal,
                store: store
            ))
            store.newTab(content: .terminal)
            return try! self.success()
        }

        guard case .success = result else {
            return XCTFail("the launcher intent should succeed")
        }
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertTrue(
            tabs.flatMap(\.slots).contains { $0.content == .empty },
            "a concurrent tab must not consume the plus invocation's reserved tab"
        )
    }

    func testPlusPlacementKeepsItsResultWhenAnotherTabAppearsDuringTheSend() async throws {
        let store = WorkspaceStore()
        let content = SlotContent.pluginView(
            pluginID: "dev.tenon.test",
            viewID: "board"
        )

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            let paneID = try! XCTUnwrap(scope.paneID)
            store.focusSlot(paneID)
            store.openContent(content)
            store.newTab(content: .terminal)
            return try! self.success()
        }

        guard case .success = result else {
            return XCTFail("the launcher intent should succeed")
        }
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertTrue(
            tabs.contains { $0.slots.map(\.content) == [content] },
            "an unrelated tab must not make the launcher discard its scoped result"
        )
    }

    func testPlusPlacementRollsBackTheFreshTabWhenTheCommandFails() async throws {
        let store = WorkspaceStore()
        let originalTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        let originalTabCount = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)

        let result = await NewTabLauncherPlacement.invoke(in: store) { _ in
            self.failure(code: .denied)
        }

        guard case .failure = result else {
            return XCTFail("the launcher intent should fail")
        }
        XCTAssertEqual(store.catalog.activeWorkspace?.tabs.count, originalTabCount)
        XCTAssertEqual(store.catalog.activeTab?.id, originalTabID)
        XCTAssertFalse(
            store.catalog.activeTab?.slots.contains { $0.content == .empty } ?? true
        )
    }

    func testPlusPlacementKeepsAResultWhenFailureOutcomeIsUnknown() async throws {
        let store = WorkspaceStore()
        let content = SlotContent.pluginView(
            pluginID: "dev.tenon.test",
            viewID: "board"
        )

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            let paneID = try! XCTUnwrap(scope.paneID)
            store.focusSlot(paneID)
            store.openContent(content)
            return self.failure(code: .internal, outcome: .unknown)
        }

        guard case .failure = result else {
            return XCTFail("the launcher intent should report its failure")
        }
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(
            tabs.contains { $0.slots.map(\.content) == [content] },
            "unknown means the provider may have completed this side effect"
        )
    }

    func testPlusFailureDoesNotOverrideNewerTabNavigation() async throws {
        let store = WorkspaceStore()
        let originalTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.newTab(content: .changes)
        let newerSelection = try XCTUnwrap(store.catalog.activeTab?.id)
        store.selectTab(originalTabID)

        _ = await NewTabLauncherPlacement.invoke(in: store) { _ in
            store.selectTab(newerSelection)
            return self.failure(code: .denied)
        }

        XCTAssertEqual(
            store.catalog.activeTab?.id,
            newerSelection,
            "async cleanup must preserve navigation that happened after the click"
        )
    }

    func testPlusSuccessCleansItsPlaceholderAfterCrossWorkspaceNavigation() async throws {
        let store = WorkspaceStore()
        let sourceWorkspaceID = store.catalog.activeWorkspaceID
        store.addWorkspace(
            name: "Other",
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        let newerWorkspaceID = store.catalog.activeWorkspaceID
        store.selectWorkspace(sourceWorkspaceID)

        _ = await NewTabLauncherPlacement.invoke(in: store) { scope in
            XCTAssertTrue(NewTabLauncherPlacement.consumeReservedTabCreation(
                scope: scope,
                content: .changes,
                store: store
            ))
            store.selectWorkspace(newerWorkspaceID)
            return try! self.success()
        }

        XCTAssertEqual(store.catalog.activeWorkspaceID, newerWorkspaceID)
        let sourceTabs = try XCTUnwrap(
            store.catalog.workspaces.first { $0.id == sourceWorkspaceID }?.tabs
        )
        XCTAssertEqual(sourceTabs.count, 2)
        XCTAssertFalse(sourceTabs.flatMap(\.slots).contains { $0.content == .empty })
    }

    func testPlusFailureCleansItsPlaceholderAfterCrossWorkspaceNavigation() async throws {
        let store = WorkspaceStore()
        let sourceWorkspaceID = store.catalog.activeWorkspaceID
        store.addWorkspace(
            name: "Other",
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        let newerWorkspaceID = store.catalog.activeWorkspaceID
        store.selectWorkspace(sourceWorkspaceID)

        _ = await NewTabLauncherPlacement.invoke(in: store) { _ in
            store.selectWorkspace(newerWorkspaceID)
            return self.failure(code: .denied)
        }

        XCTAssertEqual(store.catalog.activeWorkspaceID, newerWorkspaceID)
        let sourceTabs = try XCTUnwrap(
            store.catalog.workspaces.first { $0.id == sourceWorkspaceID }?.tabs
        )
        XCTAssertEqual(sourceTabs.count, 1)
        XCTAssertFalse(sourceTabs.flatMap(\.slots).contains { $0.content == .empty })
    }

    private func makeHalfCanvasStore() -> (
        store: WorkspaceStore,
        originalID: UUID,
        originalRect: GridRect
    ) {
        let originalID = UUID()
        let originalRect = GridRect(x: 0, y: 0, width: 6, height: 12)
        let tab = Tab(
            slots: [WorkspaceSlot(id: originalID, rect: originalRect, content: .terminal)],
            activeSlotID: originalID
        )
        let workspace = Workspace(
            name: "Test",
            path: FileManager.default.temporaryDirectory,
            tabs: [tab],
            activeTabID: tab.id
        )
        return (
            WorkspaceStore(catalog: WorkspaceCatalog(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )),
            originalID,
            originalRect
        )
    }
}
