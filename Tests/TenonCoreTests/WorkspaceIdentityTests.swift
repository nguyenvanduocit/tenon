import XCTest
@testable import TenonCore

/// T-097: a workspace can be named, marked, and tinted, and none of that touches the
/// workspace itself. Every rule here is pure — no window, no shell, no filesystem.
final class WorkspaceIdentityTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)

    // MARK: - The two naming rules

    func testTheDerivedNameIsTheFoldersOwnName() {
        XCTAssertEqual(
            WorkspaceName.derived(
                for: URL(fileURLWithPath: "/Users/someone/code/tenon", isDirectory: true)
            ),
            "tenon"
        )
    }

    func testTheDerivedNameFallsBackToThePathWhenTheFolderHasNoName() {
        XCTAssertEqual(
            WorkspaceName.derived(for: URL(fileURLWithPath: "/", isDirectory: true)),
            "/"
        )
    }

    func testATypedNameIsTrimmed() {
        XCTAssertEqual(WorkspaceName.sanitized("   Payments   "), "Payments")
    }

    /// A name pasted out of a terminal arrives with newlines and runs of padding; a one-line
    /// row would render those as a gap it cannot explain.
    func testATypedNameCollapsesInteriorWhitespaceAndNewlines() {
        XCTAssertEqual(WorkspaceName.sanitized("Payments\n\tservice   API"), "Payments service API")
    }

    func testANameThatCarriesNoCharactersIsRefused() {
        XCTAssertNil(WorkspaceName.sanitized(""))
        XCTAssertNil(WorkspaceName.sanitized("    "))
        XCTAssertNil(WorkspaceName.sanitized("\n\t \u{00A0}"))
    }

    func testATypedNameStopsAtTheMaximumLength() {
        let long = String(repeating: "n", count: WorkspaceName.maximumLength + 40)

        XCTAssertEqual(
            WorkspaceName.sanitized(long)?.count,
            WorkspaceName.maximumLength
        )
    }

    /// The cap counts what a person sees, not what UTF-8 stores, so a name of composed
    /// characters is not cut through the middle of one.
    func testTheLengthCapCountsCharactersNotBytes() {
        let name = String(repeating: "Đ", count: WorkspaceName.maximumLength)

        XCTAssertEqual(WorkspaceName.sanitized(name), name)
    }

    // MARK: - Renaming leaves the workspace where it is

    func testRenamingChangesTheNameAndNothingElse() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.newTab(content: .automation)
        let id = catalog.activeWorkspaceID
        let before = try XCTUnwrap(catalog.activeWorkspace)

        let events = catalog.renameWorkspace(id, to: "Payments")

        let after = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(events, [.workspaceIdentityChanged(id)])
        XCTAssertEqual(after.name, "Payments")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.path, before.path)
        XCTAssertEqual(after.tabs, before.tabs)
        XCTAssertEqual(after.activeTabID, before.activeTabID)
        XCTAssertEqual(catalog.activeWorkspaceID, id)
        XCTAssertEqual(catalog.allSlotIDs.count, before.tabs.flatMap(\.slots).count)
    }

    func testRenamingTrimsWhatWasTyped() throws {
        var catalog = WorkspaceCatalog(path: projectPath)

        catalog.renameWorkspace(catalog.activeWorkspaceID, to: "  Payments  ")

        XCTAssertEqual(try XCTUnwrap(catalog.activeWorkspace).name, "Payments")
    }

    func testClearingTheNameRestoresTheDerivedDefault() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.renameWorkspace(catalog.activeWorkspaceID, to: "Payments")

        let events = catalog.renameWorkspace(catalog.activeWorkspaceID, to: "   ")

        XCTAssertEqual(events, [.workspaceIdentityChanged(catalog.activeWorkspaceID)])
        XCTAssertEqual(try XCTUnwrap(catalog.activeWorkspace).name, "tenon-project")
    }

    func testRenamingToTheNameItAlreadyCarriesPublishesNothing() {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.renameWorkspace(catalog.activeWorkspaceID, to: "Payments")

        XCTAssertEqual(catalog.renameWorkspace(catalog.activeWorkspaceID, to: "Payments"), [])
        XCTAssertEqual(catalog.renameWorkspace(catalog.activeWorkspaceID, to: " Payments "), [])
    }

    func testCustomisingAWorkspaceThatIsNotInTheCatalogPublishesNothing() {
        var catalog = WorkspaceCatalog(path: projectPath)
        let stranger = UUID()

        XCTAssertEqual(catalog.renameWorkspace(stranger, to: "Payments"), [])
        XCTAssertEqual(
            catalog.setWorkspaceAppearance(stranger, WorkspaceAppearance(symbol: .bolt)),
            []
        )
        XCTAssertEqual(catalog.resetWorkspaceIdentity(stranger), [])
    }

    /// Identity is the `UUID`. Two workspaces may carry one display name because nothing
    /// downstream ever reads a name to find a workspace.
    func testTwoWorkspacesMayCarryTheSameNameAndStayIndividuallyAddressable() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        let first = catalog.activeWorkspaceID
        catalog.addWorkspace(name: "Two", path: URL(fileURLWithPath: "/tmp/two", isDirectory: true))
        let second = catalog.activeWorkspaceID
        let secondTabs = try XCTUnwrap(catalog.workspaces.first { $0.id == second }).tabs

        catalog.renameWorkspace(first, to: "Payments")
        catalog.renameWorkspace(second, to: "Payments")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(catalog.workspaces.map(\.name), ["Payments", "Payments"])

        // Addressed by id, each still resolves to its own root and its own panes.
        catalog.setWorkspaceAppearance(second, WorkspaceAppearance(symbol: .bolt, accent: .green))
        XCTAssertEqual(catalog.workspaces.first { $0.id == first }?.appearance, .default)
        XCTAssertEqual(
            catalog.workspaces.first { $0.id == second }?.appearance,
            WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        XCTAssertEqual(catalog.workspaces.first { $0.id == second }?.tabs, secondTabs)

        catalog.selectWorkspace(first)
        XCTAssertEqual(catalog.activeWorkspace?.path, projectPath)

        catalog.removeWorkspace(second)
        XCTAssertEqual(catalog.workspaces.map(\.id), [first])
    }

    // MARK: - Mark and tint

    func testAWorkspaceOpensWithTenonsDefaultAppearance() throws {
        let catalog = WorkspaceCatalog(path: projectPath)
        let workspace = try XCTUnwrap(catalog.activeWorkspace)

        XCTAssertEqual(workspace.appearance, .default)
        XCTAssertEqual(workspace.appearance.symbol, .folder)
        XCTAssertNil(workspace.appearance.accent)
        XCTAssertTrue(workspace.appearance.isDefault)
        XCTAssertFalse(workspace.hasCustomIdentity)
    }

    func testMarkingAndTintingLeavesTheWorkspacesTreeUntouched() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.newTab(content: .changes)
        let id = catalog.activeWorkspaceID
        let before = try XCTUnwrap(catalog.activeWorkspace)

        let events = catalog.setWorkspaceAppearance(
            id,
            WorkspaceAppearance(symbol: .metrics, accent: .purple)
        )

        let after = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(events, [.workspaceIdentityChanged(id)])
        XCTAssertEqual(after.appearance.symbol, .metrics)
        XCTAssertEqual(after.appearance.accent, .purple)
        XCTAssertEqual(after.name, before.name)
        XCTAssertEqual(after.tabs, before.tabs)
        XCTAssertEqual(after.activeTabID, before.activeTabID)
        XCTAssertTrue(after.hasCustomIdentity)
    }

    func testSettingTheAppearanceItAlreadyHasPublishesNothing() {
        var catalog = WorkspaceCatalog(path: projectPath)

        XCTAssertEqual(catalog.setWorkspaceAppearance(catalog.activeWorkspaceID, .default), [])
    }

    /// Clearing the tint returns the workspace to the app accent rather than painting it
    /// with a colour that happens to match today's preference.
    func testClearingTheTintKeepsTheMarkAndFollowsTheAppAccentAgain() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        let id = catalog.activeWorkspaceID
        catalog.setWorkspaceAppearance(id, WorkspaceAppearance(symbol: .bolt, accent: .pink))

        catalog.setWorkspaceAppearance(id, WorkspaceAppearance(symbol: .bolt, accent: nil))

        let workspace = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(workspace.appearance.symbol, .bolt)
        XCTAssertNil(workspace.appearance.accent)
        XCTAssertTrue(workspace.hasCustomIdentity)
    }

    // MARK: - Reset

    func testResetRestoresTheDefaultsWithoutRecreatingTheWorkspace() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.newTab(content: .automation)
        let id = catalog.activeWorkspaceID
        let before = try XCTUnwrap(catalog.activeWorkspace)
        catalog.renameWorkspace(id, to: "Payments")
        catalog.setWorkspaceAppearance(id, WorkspaceAppearance(symbol: .bug, accent: .blue))

        let events = catalog.resetWorkspaceIdentity(id)

        let after = try XCTUnwrap(catalog.activeWorkspace)
        XCTAssertEqual(events, [.workspaceIdentityChanged(id)])
        XCTAssertEqual(after.name, "tenon-project")
        XCTAssertEqual(after.appearance, .default)
        XCTAssertFalse(after.hasCustomIdentity)
        // The same workspace, not a replacement wearing its folder.
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.path, before.path)
        XCTAssertEqual(after.tabs, before.tabs)
        XCTAssertEqual(after.activeTabID, before.activeTabID)
        XCTAssertEqual(catalog.activeWorkspaceID, id)
    }

    func testResettingAWorkspaceThatWasNeverCustomisedPublishesNothing() {
        var catalog = WorkspaceCatalog(path: projectPath)

        XCTAssertEqual(catalog.resetWorkspaceIdentity(catalog.activeWorkspaceID), [])
    }

    // MARK: - The store publishes it

    func testTheStorePublishesTheIdentityFactAndANewSnapshot() {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published.append(contentsOf: events) }
        let snapshotBefore = store.snapshotID
        let id = store.catalog.activeWorkspaceID

        store.renameWorkspace(id, to: "Payments")
        store.setWorkspaceAppearance(id, to: WorkspaceAppearance(symbol: .book, accent: .green))
        store.resetWorkspaceIdentity(id)

        XCTAssertEqual(
            published,
            [
                .workspaceIdentityChanged(id),
                .workspaceIdentityChanged(id),
                .workspaceIdentityChanged(id),
            ]
        )
        XCTAssertNotEqual(store.snapshotID, snapshotBefore)
        XCTAssertEqual(store.catalog.activeWorkspace?.name, "tenon-project")
        XCTAssertEqual(store.catalog.activeWorkspace?.appearance, .default)
    }

    /// A rename is not a move: the sidebar's Add-Workspace menu filters remembered folders
    /// against the open ones, and that set must not churn because a name changed.
    func testRenamingDoesNotRepublishTheOpenWorkspaceFolders() {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        let folders = store.openWorkspaceFolders

        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")

        XCTAssertEqual(store.openWorkspaceFolders, folders)
    }

    // MARK: - It survives the relaunch

    func testTheChosenIdentitySurvivesCaptureAndRestore() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        let id = catalog.activeWorkspaceID
        catalog.renameWorkspace(id, to: "Payments")
        catalog.setWorkspaceAppearance(id, WorkspaceAppearance(symbol: .metrics, accent: .purple))

        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                WorkspaceCatalogSnapshot.document(capturing: catalog),
                isDirectory: { _ in true },
                isFileReadable: { _ in true },
                isKnownPluginView: { _, _ in true }
            )
        )

        let workspace = try XCTUnwrap(restored.catalog.activeWorkspace)
        XCTAssertEqual(workspace.id, id)
        XCTAssertEqual(workspace.name, "Payments")
        XCTAssertEqual(workspace.appearance.symbol, .metrics)
        XCTAssertEqual(workspace.appearance.accent, .purple)
    }

    /// The migration: a document written before this task carries no appearance at all. It
    /// restores with Tenon's default appearance and loses nothing else.
    func testACatalogWrittenBeforeCustomisationRestoresWithTheDefaultAppearance() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let slotID = UUID()
        let json = """
        {
          "version": 1,
          "activeWorkspaceID": "\(workspaceID.uuidString)",
          "workspaces": [
            {
              "id": "\(workspaceID.uuidString)",
              "name": "Payments",
              "path": "/tmp/tenon-project",
              "activeTabID": "\(tabID.uuidString)",
              "tabs": [
                {
                  "id": "\(tabID.uuidString)",
                  "activeSlotID": "\(slotID.uuidString)",
                  "slots": [
                    {
                      "id": "\(slotID.uuidString)",
                      "x": 0, "y": 0, "width": 12, "height": 12,
                      "content": { "type": "terminal" },
                      "title": "zsh"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """

        let document = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: Data(json.utf8)
        )
        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                document,
                isDirectory: { _ in true },
                isFileReadable: { _ in true },
                isKnownPluginView: { _, _ in true }
            )
        )

        let workspace = try XCTUnwrap(restored.catalog.activeWorkspace)
        XCTAssertEqual(workspace.id, workspaceID)
        XCTAssertEqual(workspace.name, "Payments")
        XCTAssertEqual(workspace.appearance, .default)
        XCTAssertEqual(workspace.tabs.map(\.id), [tabID])
        XCTAssertEqual(workspace.tabs[0].slots.map(\.id), [slotID])
        XCTAssertEqual(workspace.tabs[0].slots[0].content, .terminal)
        XCTAssertEqual(restored.titles[slotID], "zsh")
    }

    /// Forward compatibility, matching how an unknown pane content degrades: a mark or tint
    /// from a newer build costs that one value, never the workspace.
    func testAMarkOrTintThisBuildDoesNotKnowDegradesToTheDefault() throws {
        var catalog = WorkspaceCatalog(path: projectPath)
        catalog.renameWorkspace(catalog.activeWorkspaceID, to: "Payments")
        var document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        document.workspaces[0].appearance = WorkspaceCatalogSnapshot.AppearanceRecord(
            symbol: "hologram",
            accent: "ultraviolet"
        )

        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                document,
                isDirectory: { _ in true },
                isFileReadable: { _ in true },
                isKnownPluginView: { _, _ in true }
            )
        )

        let workspace = try XCTUnwrap(restored.catalog.activeWorkspace)
        XCTAssertEqual(workspace.name, "Payments")
        XCTAssertEqual(workspace.appearance, .default)
    }

    /// An uncustomised catalog writes the same bytes it wrote before this task existed, so
    /// the ordinary document does not grow a key that says "unchanged".
    func testAnUncustomisedCatalogRecordsNoAppearanceAtAll() {
        let catalog = WorkspaceCatalog(path: projectPath)

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)

        XCTAssertNil(document.workspaces[0].appearance)
    }

    func testANameThatSurvivedAsWhitespaceComesBackAsTheDerivedDefault() throws {
        let catalog = WorkspaceCatalog(path: projectPath)
        var document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        document.workspaces[0].name = "   \n "

        let restored = try XCTUnwrap(
            WorkspaceCatalogSnapshot.restore(
                document,
                isDirectory: { _ in true },
                isFileReadable: { _ in true },
                isKnownPluginView: { _, _ in true }
            )
        )

        XCTAssertEqual(restored.catalog.activeWorkspace?.name, "tenon-project")
    }

    // MARK: - The vocabulary

    func testEveryMarkInTheVocabularyCarriesADistinctSymbolAndLabel() {
        let symbols = WorkspaceSymbol.allCases.map(\.systemName)
        let labels = WorkspaceSymbol.allCases.map(\.label)

        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(WorkspaceSymbol.default, .folder)
    }
}
