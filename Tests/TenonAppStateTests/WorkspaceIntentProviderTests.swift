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
    func testWorkspaceIdentityIntentUpdatesTheExactWorkspaceAtomically() async throws {
        var catalog = WorkspaceCatalog(
            name: "First",
            path: URL(fileURLWithPath: "/first", isDirectory: true)
        )
        let selectedID = catalog.activeWorkspaceID
        catalog.addWorkspace(
            name: "Second",
            path: URL(fileURLWithPath: "/second", isDirectory: true)
        )
        let targetID = catalog.activeWorkspaceID
        catalog.selectWorkspace(selectedID)
        let store = WorkspaceStore(catalog: catalog)
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published.append(contentsOf: events) }
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        let value = try successReply(
            await invoke(
                .workspaceIdentitySet,
                input: .object([
                    "name": .string("Infra"),
                    "accent": .string("teal"),
                    "icon": .object([
                        "kind": .string("symbol"),
                        "name": .string("server"),
                    ]),
                ]),
                scope: InvocationScope(workspaceID: targetID),
                bindings: bindings
            )
        )

        XCTAssertEqual(
            value,
            .object([
                "workspaceID": .string(targetID.uuidString),
                "name": .string("Infra"),
                "accent": .string("teal"),
                "icon": .object([
                    "kind": .string("symbol"),
                    "name": .string("server"),
                ]),
            ])
        )
        XCTAssertEqual(store.catalog.activeWorkspaceID, selectedID)
        let target = try XCTUnwrap(store.catalog.workspaces.first { $0.id == targetID })
        XCTAssertEqual(target.name, "Infra")
        XCTAssertEqual(target.appearance, WorkspaceAppearance(symbol: .server, accent: .teal))
        XCTAssertEqual(published, [.workspaceIdentityChanged(targetID)])
    }

    func testWorkspaceIdentityIntentNormalizesCustomImageBytes() async throws {
        let source = Data("raw image supplied by cli".utf8)
        let png = try XCTUnwrap(
            Data(base64Encoded: """
                iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A
                AQUBAScY42YAAAAASUVORK5CYII=
                """.filter { !$0.isWhitespace })
        )
        let normalized = try XCTUnwrap(WorkspaceCustomIcon(pngData: png))
        let store = WorkspaceStore()
        let workspaceID = store.catalog.activeWorkspaceID
        let bindings = try WorkspaceIntentProvider(
            store: store,
            normalizeCustomIcon: { data in
                guard data == source else { throw TestError.invalidData }
                return normalized
            }
        ).bindings()

        let value = try successReply(
            await invoke(
                .workspaceIdentitySet,
                input: .object([
                    "icon": .object([
                        "kind": .string("custom"),
                        "data": .string(source.base64EncodedString()),
                    ]),
                ]),
                scope: InvocationScope(workspaceID: workspaceID),
                bindings: bindings
            )
        )

        XCTAssertEqual(store.catalog.activeWorkspace?.appearance.customIcon, normalized)
        guard case let .object(output) = value,
              case let .object(icon)? = output["icon"]
        else { return XCTFail("identity output must contain an icon object") }
        XCTAssertEqual(icon["kind"], .string("custom"))
        XCTAssertEqual(icon["id"], .string(normalized.id.uuidString))
        XCTAssertEqual(icon["data"], .string(normalized.pngData.base64EncodedString()))
    }

    func testWorkspaceIdentityIntentNeverFallsBackToSelection() async throws {
        let store = WorkspaceStore()
        let before = store.catalog.activeWorkspace
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        let reply = try await invoke(
            .workspaceIdentitySet,
            input: .object(["name": .string("Wrong workspace")]),
            scope: InvocationScope(),
            bindings: bindings
        )

        guard case let .failure(failure) = reply else {
            return XCTFail("missing workspace scope must fail closed")
        }
        XCTAssertEqual(
            failure.code,
            .domain(try IntentDomainErrorCode("dev.tenon.core.workspace-not-found"))
        )
        XCTAssertEqual(store.catalog.activeWorkspace, before)
    }

    func testAutomationContentRoundTripsThroughPublicWorkspaceIntents() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        let automation: IntentValue = .object([
            "kind": .string("automation")
        ])

        _ = try successReply(
            await invoke(
                .workspacePaneContentSet,
                input: .object(["content": automation]),
                paneID: paneID,
                bindings: bindings
            )
        )
        XCTAssertEqual(store.catalog.slot(id: paneID)?.content, .automation)

        let snapshot = try successReply(
            await invoke(
                .workspaceState,
                input: .object([:]),
                paneID: paneID,
                bindings: bindings
            )
        )
        guard case let .object(document) = snapshot,
              case let .array(nodes)? = document["nodes"]
        else {
            return XCTFail("workspace state must return a nodes array")
        }
        XCTAssertTrue(nodes.contains { node in
            guard case let .object(fields) = node,
                  fields["kind"] == .string("pane"),
                  fields["id"] == .string(paneID.uuidString)
            else {
                return false
            }
            return fields["content"] == automation
        })
    }

    /// A pane's owner is a property of the pane. Resolving it must not consult the
    /// selection, so a pane in a workspace nobody is looking at answers the same as one in
    /// the selected workspace.
    func testPaneOwnerResolvesForAPaneInAnUnselectedWorkspace() async throws {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "First", path: URL(fileURLWithPath: "/first"))
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/second"))
        let first = try XCTUnwrap(catalog.workspaces.first)
        let second = try XCTUnwrap(catalog.workspaces.last)
        catalog.selectWorkspace(first.id)
        let store = WorkspaceStore(catalog: catalog)
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        let secondTab = try XCTUnwrap(second.tabs.first)
        let unselectedPaneID = try XCTUnwrap(secondTab.slots.first?.id)
        XCTAssertNotEqual(store.catalog.activeWorkspaceID, second.id)

        let owner = try successReply(
            await invoke(
                .workspacePaneOwner,
                input: .object(["paneID": .string(unselectedPaneID.uuidString)]),
                paneID: unselectedPaneID,
                bindings: bindings
            )
        )
        XCTAssertEqual(
            owner,
            .object([
                "workspaceID": .string(second.id.uuidString),
                "workspacePath": .string("/second"),
                "tabID": .string(secondTab.id.uuidString),
            ])
        )
    }

    /// The paginated snapshot answers "what is the catalog shaped like"; it cannot answer
    /// "who owns this pane" past its first page, because the owning nodes simply are not in
    /// the page. The edge contract is total, so it answers anyway.
    func testPaneOwnerResolvesAPaneBeyondTheFirstSnapshotPage() async throws {
        var catalog = WorkspaceCatalog()
        for index in 0 ..< 90 {
            catalog.addWorkspace(
                name: "W\(index)",
                path: URL(fileURLWithPath: "/w\(index)")
            )
        }
        let first = try XCTUnwrap(catalog.workspaces.first)
        catalog.selectWorkspace(first.id)
        let store = WorkspaceStore(catalog: catalog)
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        let last = try XCTUnwrap(catalog.workspaces.last)
        let lastTab = try XCTUnwrap(last.tabs.first)
        let farPaneID = try XCTUnwrap(lastTab.slots.first?.id)

        let snapshot = try successReply(
            await invoke(
                .workspaceState,
                input: .object(["limit": .integer(256)]),
                paneID: farPaneID,
                bindings: bindings
            )
        )
        guard case let .object(document) = snapshot,
              case let .array(nodes)? = document["nodes"]
        else {
            return XCTFail("workspace state must return a nodes array")
        }
        XCTAssertFalse(
            nodes.contains { node in
                guard case let .object(fields) = node else { return false }
                return fields["id"] == .string(farPaneID.uuidString)
            },
            "the fixture must be big enough that the far pane falls off page one"
        )

        let owner = try successReply(
            await invoke(
                .workspacePaneOwner,
                input: .object(["paneID": .string(farPaneID.uuidString)]),
                paneID: farPaneID,
                bindings: bindings
            )
        )
        XCTAssertEqual(
            owner,
            .object([
                "workspaceID": .string(last.id.uuidString),
                "workspacePath": .string("/w89"),
                "tabID": .string(lastTab.id.uuidString),
            ])
        )
    }

    func testInvalidatedEmptyGridReservationDoesNotFallThroughToCreatingATab() async throws {
        let fixture = makeHalfCanvasStore()
        let bindings = try WorkspaceIntentProvider(store: fixture.store).bindings()
        let tabCount = try XCTUnwrap(fixture.store.catalog.activeWorkspace?.tabs.count)

        _ = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: GridRect(x: 6, y: 0, width: 6, height: 12)
        ) { scope in
            fixture.store.discardEmptySlot(
                try! XCTUnwrap(scope.paneID),
                restoringFocusTo: fixture.originalPaneID
            )
            let reply = try! await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("changes")])
                ]),
                scope: scope,
                bindings: bindings
            )
            guard case .failure = reply else {
                XCTFail("an invalidated fill reservation must fail closed")
                return self.intentSuccess()
            }
            return self.intentSuccess()
        }

        XCTAssertEqual(fixture.store.catalog.activeWorkspace?.tabs.count, tabCount)
        XCTAssertFalse(
            fixture.store.catalog.activeWorkspace?.tabs
                .flatMap(\.slots)
                .contains { $0.content == .changes } ?? false
        )
    }

    func testEmptyGridContentPlacementPreservesNewerWorkspaceNavigation() async throws {
        let fixture = makeHalfCanvasStore()
        let bindings = try WorkspaceIntentProvider(store: fixture.store).bindings()
        let sourceWorkspaceID = fixture.store.catalog.activeWorkspaceID
        fixture.store.addWorkspace(
            name: "Other",
            path: FileManager.default.temporaryDirectory,
            content: .terminal
        )
        let newerWorkspaceID = fixture.store.catalog.activeWorkspaceID
        fixture.store.selectWorkspace(sourceWorkspaceID)
        let target = GridRect(x: 6, y: 0, width: 6, height: 12)

        let outcome = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: target
        ) { scope in
            fixture.store.selectWorkspace(newerWorkspaceID)
            let reply = try! await self.invoke(
                .workspaceContentOpen,
                input: .object([
                    "content": .object(["kind": .string("changes")])
                ]),
                scope: scope,
                bindings: bindings
            )
            guard case .success = reply else { return nil }
            return self.intentSuccess()
        }

        XCTAssertEqual(outcome, .ran)
        XCTAssertEqual(fixture.store.catalog.activeWorkspaceID, newerWorkspaceID)
        let source = try XCTUnwrap(
            fixture.store.catalog.workspaces.first { $0.id == sourceWorkspaceID }
        )
        XCTAssertTrue(source.tabs.flatMap(\.slots).contains {
            $0.rect == target && $0.content == .changes
        })
    }

    func testInvalidatedEmptyGridReservationDoesNotFallThroughToContentPlacement() async throws {
        let fixture = makeHalfCanvasStore()
        let bindings = try WorkspaceIntentProvider(store: fixture.store).bindings()

        _ = await EmptyGridLauncherPlacement.invoke(
            in: fixture.store,
            targetRect: GridRect(x: 6, y: 0, width: 6, height: 12)
        ) { scope in
            fixture.store.discardEmptySlot(
                try! XCTUnwrap(scope.paneID),
                restoringFocusTo: fixture.originalPaneID
            )
            let reply = try! await self.invoke(
                .workspaceContentOpen,
                input: .object([
                    "content": .object(["kind": .string("changes")])
                ]),
                scope: scope,
                bindings: bindings
            )
            guard case .failure = reply else {
                XCTFail("an invalidated fill reservation must not use ordinary placement")
                return self.intentSuccess()
            }
            return self.intentSuccess()
        }

        XCTAssertEqual(fixture.store.catalog.activeTab?.slots.count, 1)
        XCTAssertEqual(fixture.store.catalog.activeTab?.slots.first?.content, .terminal)
    }

    func testTabCreationConsumesTheTitleBarPlusReservation() async throws {
        let store = WorkspaceStore()
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let originalTabCount = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)

        let result = await NewTabLauncherPlacement.invoke(in: store) { scope in
            guard let reply = try? await self.invoke(
                .workspaceTabCreate,
                input: .object([
                    "content": .object(["kind": .string("changes")])
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
        XCTAssertEqual(store.catalog.activeTab?.slots.map(\.content), [.changes])
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
                    "content": .object(["kind": .string("changes")])
                ]),
                scope: scope,
                bindings: bindings
            ), case .success = secondReply else { return nil }
            return self.intentSuccess()
        }

        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.count, originalTabCount + 2)
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .empty })
        XCTAssertTrue(tabs.flatMap(\.slots).contains { $0.content == .changes })
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
                    "content": .object(["kind": .string("changes")])
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
        XCTAssertTrue(sourceTabs.flatMap(\.slots).contains { $0.content == .changes })
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

    /// A tab holding no panes at all is restored state since T-193 — closing a pane leaves
    /// an `.empty` one behind — so the fixture is built the way `WorkspaceCatalogStore`
    /// decodes one (`WorkspaceCatalogStore.swift:355`) rather than through a close. What is
    /// pinned is unchanged: opening content into such a tab fills it and opens no tab.
    func testOpeningIntoAnEmptyTabAddsItsFirstPaneAndNeverOpensATab() async throws {
        let emptyTab = Tab(slots: [], activeSlotID: nil)
        let workspace = Workspace(
            name: "Empty",
            path: FileManager.default.temporaryDirectory,
            tabs: [emptyTab],
            activeTabID: emptyTab.id
        )
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        ))
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let tabID = try XCTUnwrap(store.catalog.activeTab?.id)
        let workspaceID = store.catalog.activeWorkspaceID
        let tabs = try XCTUnwrap(store.catalog.activeWorkspace?.tabs.count)
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

    func testTabFocusSelectsTheExactCopiedTabID() async throws {
        let store = WorkspaceStore()
        let firstTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.newTab()
        let targetTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.selectTab(firstTabID)
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        _ = try successReply(
            await invoke(
                .workspaceTabFocus,
                input: .object([:]),
                scope: InvocationScope(tabID: targetTabID),
                bindings: bindings
            )
        )

        XCTAssertEqual(store.catalog.activeTab?.id, targetTabID)
    }

    func testContentOpenUsesTheExactCopiedTabIDWithoutAPane() async throws {
        let store = WorkspaceStore()
        let firstTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.newTab()
        let targetTabID = try XCTUnwrap(store.catalog.activeTab?.id)
        store.selectTab(firstTabID)
        let bindings = try WorkspaceIntentProvider(store: store).bindings()

        _ = try successReply(
            await invoke(
                .workspaceContentOpen,
                input: .object([
                    "content": .object([
                        "kind": .string("file"),
                        "path": .string("target-tab.swift"),
                    ])
                ]),
                scope: InvocationScope(tabID: targetTabID),
                bindings: bindings
            )
        )

        let first = try XCTUnwrap(
            store.catalog.activeWorkspace?.tabs.first { $0.id == firstTabID }
        )
        let target = try XCTUnwrap(
            store.catalog.activeWorkspace?.tabs.first { $0.id == targetTabID }
        )
        XCTAssertFalse(first.slots.contains {
            $0.content == .file(path: "target-tab.swift")
        })
        XCTAssertTrue(target.slots.contains {
            $0.content == .file(path: "target-tab.swift")
        })
        XCTAssertEqual(store.catalog.activeTab?.id, targetTabID)
    }
}

private extension WorkspaceIntentProviderTests {
    func makeHalfCanvasStore() -> (store: WorkspaceStore, originalPaneID: UUID) {
        let originalPaneID = UUID()
        let tab = Tab(
            slots: [WorkspaceSlot(
                id: originalPaneID,
                rect: GridRect(x: 0, y: 0, width: 6, height: 12),
                content: .terminal
            )],
            activeSlotID: originalPaneID
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
            originalPaneID
        )
    }

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
        case invalidData
    }
}
