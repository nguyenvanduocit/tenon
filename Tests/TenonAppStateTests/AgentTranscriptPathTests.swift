import Foundation
@testable import TenonApp
import XCTest

/// T-126 — the one rule for "a transcript this host is allowed to read".
///
/// A recorded-session pane is opened by a PLUGIN naming a path, which is the first time this
/// rule decides something an untrusted caller chose. Every refusal below is therefore asserted
/// against a real file or a real symlink on disk, not against a string that describes one: the
/// bug this rule exists to prevent is a link that looks contained and resolves outside, and a
/// test built from strings cannot tell those apart.
final class AgentTranscriptPathTests: XCTestCase {
    private var home: URL!
    private var claudeRoot: URL!
    private var roots: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-transcript-\(UUID().uuidString)", isDirectory: true)
        claudeRoot = home.appendingPathComponent(".claude/projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeRoot,
            withIntermediateDirectories: true
        )
        roots = AgentTranscriptPath.allowedRoots(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func write(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testTranscriptUnderAnAllowedRootIsAccepted() throws {
        let transcript = try write("session.jsonl", in: claudeRoot)
        let validated = AgentTranscriptPath.validated(transcript.path, roots: roots)
        XCTAssertEqual(
            validated?.resolvingSymlinksInPath().standardizedFileURL,
            transcript.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    /// The whole reason this returns a URL rather than a Bool: on macOS the temporary directory
    /// is reached through `/var`, which is a symlink to `/private/var`. A rule that resolved the
    /// candidate but not the root — which one of the three copies this type replaced did not —
    /// refuses every fixture built here while passing in production, which is the worst
    /// possible split.
    func testAnAllowedRootReachedThroughASymlinkStillContainsItsTranscripts() throws {
        let transcript = try write("session.jsonl", in: claudeRoot)
        let linkedHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-home-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: home)
        defer { try? FileManager.default.removeItem(at: linkedHome) }

        XCTAssertNotNil(
            AgentTranscriptPath.validated(
                transcript.path,
                roots: AgentTranscriptPath.allowedRoots(home: linkedHome)
            ),
            "a root named through a symlink is the same root"
        )
    }

    func testPathOutsideEveryAllowedRootIsRefused() {
        XCTAssertNil(AgentTranscriptPath.validated("/etc/passwd", roots: roots))
        XCTAssertNil(
            AgentTranscriptPath.validated(
                home.appendingPathComponent("elsewhere.jsonl").path,
                roots: roots
            )
        )
    }

    func testRelativePathIsRefused() {
        XCTAssertNil(AgentTranscriptPath.validated(".claude/projects/proj/s.jsonl", roots: roots))
        XCTAssertNil(AgentTranscriptPath.validated("", roots: roots))
    }

    func testTraversalOutOfAnAllowedRootIsRefused() {
        let escape = claudeRoot
            .appendingPathComponent("../../../secret.jsonl")
            .path
        XCTAssertNil(
            AgentTranscriptPath.validated(escape, roots: roots),
            "standardisation happens before containment, so .. cannot walk out"
        )
    }

    func testSymlinkEscapingAnAllowedRootIsRefused() throws {
        let secret = home.appendingPathComponent("secret.jsonl")
        try Data().write(to: secret)
        let link = claudeRoot.appendingPathComponent("looks-contained.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        XCTAssertNil(
            AgentTranscriptPath.validated(link.path, roots: roots),
            "the resolved path is what is checked, not the name that was written"
        )
    }

    func testNonTranscriptExtensionIsRefused() throws {
        let notes = try write("session.txt", in: claudeRoot)
        XCTAssertNil(AgentTranscriptPath.validated(notes.path, roots: roots))
    }

    /// A sibling directory whose name merely starts with the root's name is not inside it.
    func testASiblingSharingTheRootsPrefixIsRefused() throws {
        let sibling = home.appendingPathComponent(".claude/projects-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let transcript = try write("session.jsonl", in: sibling)
        XCTAssertNil(AgentTranscriptPath.validated(transcript.path, roots: roots))
    }

    /// A session states where it will write before it has written. Refusing that would refuse a
    /// real session for being new, which is why existence is a separate question.
    func testAPathThatDoesNotExistYetIsStillAllowed() {
        let unwritten = claudeRoot.appendingPathComponent("not-yet.jsonl")
        XCTAssertNotNil(AgentTranscriptPath.validated(unwritten.path, roots: roots))
        XCTAssertNil(
            AgentTranscriptPath.validatedExisting(unwritten, roots: roots),
            "the existence question is asked separately, and answers differently"
        )
    }

    func testCodexTranscriptsAreAllowedToo() throws {
        let codexRoot = home.appendingPathComponent(".codex/sessions/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let transcript = try write("rollout.jsonl", in: codexRoot)
        XCTAssertNotNil(AgentTranscriptPath.validated(transcript.path, roots: roots))
    }
}
