import XCTest
@testable import TenonCore

/// The pure rule that turns "where the shell is" into "what the panels should show".
///
/// These run against real directories in a temp tree rather than a stubbed predicate: the
/// two cases that actually matter — a linked worktree and a submodule — are distinguished
/// from a plain repo *only* by `.git` being a file instead of a directory, and a fake
/// filesystem is exactly where that distinction would be assumed rather than proven.
final class ProjectRootTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Standardized so the expectations below compare against the same identity the
        // rule produces: on macOS the temp tree lives under /var, which is a symlink.
        scratch = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent("tenon-project-root-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Automatic resolution

    func testResolvesToTheNearestAncestorHoldingAGitDirectory() throws {
        let repo = try directory("repo")
        try gitDirectory(in: repo)
        let deep = try directory("repo/src/app/feature")

        let resolution = ProjectRoot.resolve(cwd: deep)

        XCTAssertEqual(resolution.root, repo)
    }

    func testTheRepositoryRootResolvesToItself() throws {
        let repo = try directory("repo")
        try gitDirectory(in: repo)

        XCTAssertEqual(ProjectRoot.resolve(cwd: repo).root, repo)
    }

    /// The linked-worktree case, and the whole reason this rule cannot just look for a
    /// `.git` *directory*: `git worktree add` writes `.git` as a FILE containing a
    /// `gitdir:` pointer back into the main repository's `.git/worktrees/<name>`.
    func testResolvesALinkedWorktreeWhereGitIsAFile() throws {
        let main = try directory("main")
        try gitDirectory(in: main)
        let worktree = try directory("agent-worktree")
        try gitFile(
            in: worktree,
            pointingAt: main.appendingPathComponent(".git/worktrees/agent-worktree")
        )
        let deep = try directory("agent-worktree/Sources")

        let resolution = ProjectRoot.resolve(cwd: deep)

        XCTAssertEqual(
            resolution.root,
            worktree,
            "a linked worktree is its own project root, not the repo it points back into"
        )
    }

    /// A submodule is the same shape as a worktree — `.git` as a file — and the nearest
    /// enclosing root wins, so a pane inside the submodule shows the submodule.
    func testASubmoduleIsItsOwnRootRatherThanItsSuperproject() throws {
        let superproject = try directory("super")
        try gitDirectory(in: superproject)
        let submodule = try directory("super/vendor/lib")
        try gitFile(
            in: submodule,
            pointingAt: superproject.appendingPathComponent(".git/modules/lib")
        )
        let deep = try directory("super/vendor/lib/src")

        XCTAssertEqual(ProjectRoot.resolve(cwd: deep).root, submodule)
    }

    func testANestedRepositoryWinsOverItsParentRepository() throws {
        let outer = try directory("outer")
        try gitDirectory(in: outer)
        let inner = try directory("outer/vendor/inner")
        try gitDirectory(in: inner)

        XCTAssertEqual(ProjectRoot.resolve(cwd: inner).root, inner)
        // …and stepping back out re-roots onto the parent again.
        XCTAssertEqual(ProjectRoot.resolve(cwd: outer).root, outer)
    }

    func testNoRepositoryAnywhereResolvesToNoRootRatherThanGuessing() throws {
        let loose = try directory("loose/deep")

        let resolution = ProjectRoot.resolve(cwd: loose)

        XCTAssertNil(
            resolution.root,
            "with no repository the panels must fall back to the workspace, not to /"
        )
    }

    func testASymlinkedCwdResolvesToTheSameRootAsTheRealPath() throws {
        let repo = try directory("repo")
        try gitDirectory(in: repo)
        let real = try directory("repo/src")
        let link = scratch.appendingPathComponent("link-to-src", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            ProjectRoot.resolve(cwd: link).root,
            repo,
            "one repository must not get two identities depending on how it was reached"
        )
    }

    func testABrokenGitSymlinkDoesNotRootADirectory() throws {
        // Defensive: an entry named `.git` that resolves to nothing is not a repository,
        // and must not out-rank a real repository further up the tree.
        let repo = try directory("repo")
        try gitDirectory(in: repo)
        let rubble = try directory("repo/rubble")
        try FileManager.default.createSymbolicLink(
            at: rubble.appendingPathComponent(".git"),
            withDestinationURL: scratch.appendingPathComponent("does-not-exist")
        )

        XCTAssertEqual(ProjectRoot.resolve(cwd: rubble).root, repo)
    }

    func testResolutionIsStableForAPathThatDoesNotExist() throws {
        // A pane can report a cwd that has since been deleted; the rule must answer, not trap.
        let gone = scratch.appendingPathComponent("gone/deeper", isDirectory: true)

        XCTAssertNil(ProjectRoot.resolve(cwd: gone).root)
    }

    // MARK: - The point of the whole task: `cd` inside one repo re-roots nothing

    func testOrdinaryCdInsideOneRepositoryLeavesTheProjectRootUnchanged() throws {
        let repo = try directory("repo")
        try gitDirectory(in: repo)
        let before = try directory("repo/src/app")
        let after = try directory("repo/docs/design")

        let first = ProjectRoot.resolve(cwd: before)
        let second = ProjectRoot.resolve(cwd: after)

        XCTAssertEqual(first.root, second.root)
        XCTAssertFalse(
            ProjectRoot.rerootsPanels(from: first, to: second),
            "panels must not thrash on every cd — that is the whole point of this rule"
        )
    }

    func testCrossingIntoALinkedWorktreeDoesReRootThePanels() throws {
        let main = try directory("main")
        try gitDirectory(in: main)
        let worktree = try directory("agent-worktree")
        try gitFile(
            in: worktree,
            pointingAt: main.appendingPathComponent(".git/worktrees/agent-worktree")
        )

        let before = ProjectRoot.resolve(cwd: try directory("main/Sources"))
        let after = ProjectRoot.resolve(cwd: try directory("agent-worktree/Sources"))

        XCTAssertTrue(ProjectRoot.rerootsPanels(from: before, to: after))
    }

    func testLeavingARepositoryForUnrootedGroundReRootsThePanels() throws {
        let repo = try directory("repo")
        try gitDirectory(in: repo)

        let before = ProjectRoot.resolve(cwd: repo)
        let after = ProjectRoot.resolve(cwd: try directory("loose"))

        XCTAssertTrue(ProjectRoot.rerootsPanels(from: before, to: after))
    }

    // MARK: - Helpers

    private func directory(_ relative: String) throws -> URL {
        let url = scratch.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url.resolvingSymlinksInPath()
    }

    private func gitDirectory(in repo: URL) throws {
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func gitFile(in worktree: URL, pointingAt gitDir: URL) throws {
        try "gitdir: \(gitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
    }
}
