import XCTest

@testable import TenonCore

/// T-138 / `WS-FR-025`: what dropping folders on the sidebar decides, asserted without a
/// window. The folders are real directories in a temp tree, so the one filesystem question
/// the rule asks is answered by the filesystem rather than by a stand-in.
final class WorkspaceFolderDropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-folder-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The decision

    func testAFolderNoWorkspaceIsRootedAtOpensANewOneUnderItsDerivedName() throws {
        let dropped = try makeFolder("hoangwebsite")

        let plan = WorkspaceFolderDrop.plan(urls: [dropped], workspaces: [])

        XCTAssertEqual(plan, [.open(name: "hoangwebsite", path: dropped)])
    }

    /// The open panel hands back `/tmp/a/` while a rehydrated catalog carries `/tmp/a`; the
    /// two are not `==`, and matching them on anything but `folderKey` would open a second
    /// workspace onto a tree that already has one.
    func testAFolderAlreadyOpenSelectsThatWorkspaceInsteadOfOpeningASecond() throws {
        let dropped = try makeFolder("tenon")
        // A path spelled without the trailing slash — what a stored string rehydrates to
        // when nobody asked the filesystem. The drop carries the directory URL, which has
        // one, so the two are unequal `URL`s naming one folder.
        let open = Workspace(
            name: "tenon",
            path: URL(fileURLWithPath: dropped.path, isDirectory: false)
        )
        XCTAssertNotEqual(open.path, dropped, "the fixture must exercise the folder key")

        let plan = WorkspaceFolderDrop.plan(urls: [dropped], workspaces: [open])

        XCTAssertEqual(plan, [.select(open.id)])
    }

    /// The product owner's call, 2026-08-12: a file is refused, never read as its parent.
    /// Dragging one file off the Desktop must not open the Desktop as a workspace.
    func testAPlainFileIsRefusedRatherThanReadAsItsParentFolder() throws {
        let file = try makeFile("notes.md")

        XCTAssertEqual(WorkspaceFolderDrop.plan(urls: [file], workspaces: []), [])
    }

    func testEveryFolderInOneDropOpensInTheOrderItArrived() throws {
        let first = try makeFolder("alpha")
        let second = try makeFolder("beta")

        let plan = WorkspaceFolderDrop.plan(urls: [first, second], workspaces: [])

        XCTAssertEqual(
            plan,
            [.open(name: "alpha", path: first), .open(name: "beta", path: second)]
        )
    }

    func testTheSameFolderTwiceInOneDropOpensOnce() throws {
        let dropped = try makeFolder("alpha")

        let plan = WorkspaceFolderDrop.plan(
            urls: [dropped, URL(fileURLWithPath: dropped.path, isDirectory: true)],
            workspaces: []
        )

        XCTAssertEqual(plan, [.open(name: "alpha", path: dropped)])
    }

    func testAMixedDropTakesTheFoldersAndLeavesTheFileAlone() throws {
        let folder = try makeFolder("alpha")
        let file = try makeFile("notes.md")

        let plan = WorkspaceFolderDrop.plan(urls: [file, folder], workspaces: [])

        XCTAssertEqual(plan, [.open(name: "alpha", path: folder)])
    }

    // MARK: - Applying it to the catalog

    func testTheStoreOpensBothDroppedFoldersAndLeavesTheLastOneActive() throws {
        let existing = try makeFolder("home")
        let first = try makeFolder("alpha")
        let second = try makeFolder("beta")
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: existing))

        store.openDroppedFolders([first, second])

        XCTAssertEqual(store.catalog.workspaces.map(\.name), ["home", "alpha", "beta"])
        XCTAssertEqual(
            store.catalog.workspaces.last?.id,
            store.catalog.activeWorkspaceID
        )
    }

    func testTheStoreSelectsAnAlreadyOpenFolderAndAddsNoWorkspace() throws {
        let first = try makeFolder("alpha")
        let second = try makeFolder("beta")
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: first))
        store.addWorkspace(name: "beta", path: second)
        let alpha = try XCTUnwrap(store.catalog.workspaces.first)
        XCTAssertNotEqual(alpha.id, store.catalog.activeWorkspaceID)

        store.openDroppedFolders([first])

        XCTAssertEqual(store.catalog.workspaces.count, 2)
        XCTAssertEqual(store.catalog.activeWorkspaceID, alpha.id)
    }

    func testTheStoreLeavesTheCatalogUntouchedWhenTheDropCarriesNoFolder() throws {
        let existing = try makeFolder("home")
        let file = try makeFile("notes.md")
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: existing))
        let before = store.catalog

        store.openDroppedFolders([file])

        XCTAssertEqual(store.catalog, before)
    }

    // MARK: - Fixtures

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        return url
    }
}
