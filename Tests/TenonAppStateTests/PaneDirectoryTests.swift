import XCTest
@testable import TenonApp
@testable import TenonCore

/// `ProjectRootTests` proves the resolution rule. These prove the thing the rule exists
/// for: that a pane's registry updates on every `cd` while the *panels* are told only when
/// the project root actually moves.
@MainActor
final class PaneDirectoryTests: XCTestCase {
    private var scratch: URL!
    private var slot: UUID!

    // The async variants, so these stay on the main actor with the rest of the class —
    // `SurfacePool` is `@MainActor`, and the `WithError` overrides are not.
    override func setUp() async throws {
        try await super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-pane-dir-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        slot = UUID()
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    func testAPaneReportsAProjectRootBeforeAnyDirectoryIsEverReported() throws {
        let repo = try repository("repo")
        let pool = makePool()

        _ = pool.surface(for: slot, workspacePath: repo)

        // Seeded from the launch directory, so a pane is useful even where the bundle
        // ships no shell integration and no OSC 7 ever arrives.
        XCTAssertEqual(pool.paneDirectory(for: slot)?.projectRoot, repo)
    }

    func testAnOrdinaryCdInsideOneRepositoryUpdatesTheCwdButNotifiesNobody() throws {
        let repo = try repository("repo")
        let deep = try directory("repo/src/app")
        let pool = makePool()
        let stub = try XCTUnwrap(
            pool.surface(for: slot, workspacePath: repo) as? StubTerminalSurface
        )
        var notifications = 0
        pool.onPaneDirectoryChange = { _, _ in notifications += 1 }

        stub.onPwdChange?(deep.path)

        XCTAssertEqual(pool.paneDirectory(for: slot)?.cwd, deep, "the cwd must track the shell")
        XCTAssertEqual(pool.paneDirectory(for: slot)?.projectRoot, repo)
        XCTAssertEqual(
            notifications,
            0,
            "walking around inside one repository must not re-root the panels"
        )
    }

    func testSteppingIntoALinkedWorktreeNotifiesExactlyOnce() throws {
        let repo = try repository("main")
        let worktree = try linkedWorktree("agent-worktree", of: repo)
        let pool = makePool()
        let stub = try XCTUnwrap(
            pool.surface(for: slot, workspacePath: repo) as? StubTerminalSurface
        )
        var reported: [URL?] = []
        pool.onPaneDirectoryChange = { directory, _ in reported.append(directory.projectRoot) }

        stub.onPwdChange?(worktree.appendingPathComponent("Sources").path)

        XCTAssertEqual(reported, [worktree])
    }

    func testTheNotificationCarriesTheSlotItBelongsTo() throws {
        let repo = try repository("main")
        let worktree = try linkedWorktree("wt", of: repo)
        let pool = makePool()
        let stub = try XCTUnwrap(
            pool.surface(for: slot, workspacePath: repo) as? StubTerminalSurface
        )
        var seen: UUID?
        pool.onPaneDirectoryChange = { _, slotID in seen = slotID }

        stub.onPwdChange?(worktree.path)

        XCTAssertEqual(seen, slot)
    }

    func testTwoPanesTrackTheirOwnDirectoriesIndependently() throws {
        let repo = try repository("main")
        let worktree = try linkedWorktree("wt", of: repo)
        let other = UUID()
        let pool = makePool()
        let first = try XCTUnwrap(
            pool.surface(for: slot, workspacePath: repo) as? StubTerminalSurface
        )
        _ = pool.surface(for: other, workspacePath: repo)

        first.onPwdChange?(worktree.path)

        XCTAssertEqual(pool.paneDirectory(for: slot)?.projectRoot, worktree)
        XCTAssertEqual(
            pool.paneDirectory(for: other)?.projectRoot,
            repo,
            "one agent changing worktree must not move another pane"
        )
    }

    func testClosingAPaneReleasesItsDirectory() throws {
        let repo = try repository("repo")
        let pool = makePool()
        _ = pool.surface(for: slot, workspacePath: repo)

        pool.retainOnly([])

        XCTAssertNil(pool.paneDirectory(for: slot))
    }

    // MARK: - Helpers

    private func makePool() -> SurfacePool {
        SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
    }

    private func directory(_ relative: String) throws -> URL {
        let url = scratch.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func repository(_ relative: String) throws -> URL {
        let repo = try directory(relative)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return repo
    }

    private func linkedWorktree(_ relative: String, of repo: URL) throws -> URL {
        let worktree = try directory(relative)
        try "gitdir: \(repo.path)/.git/worktrees/\(relative)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        return worktree
    }
}
