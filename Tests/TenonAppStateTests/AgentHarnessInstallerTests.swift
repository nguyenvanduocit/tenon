import Foundation
@testable import TenonApp
@testable import TenonCore
import XCTest

/// The harness is a briefing Tenon writes into files a person already owns and an agent
/// already reads. Two properties decide whether that is safe to offer as a button:
/// everything outside Tenon's markers survives untouched, and pressing it twice is the same
/// as pressing it once.
final class AgentHarnessInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tenon-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var installer: AgentHarnessInstaller {
        AgentHarnessInstaller(homeDirectory: root)
    }

    func testInstallingWritesTheBriefingIntoBothInstructionFilesAndTheSkill() throws {
        let outcome = try installer.install()

        XCTAssertEqual(outcome.status, .installed)
        for target in AgentHarnessInstaller.Target.allCases {
            let url = target.url(relativeTo: root)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                contents.contains("tenon-cli rename"),
                "\(target) must describe the rename verb"
            )
        }
        let claude = try String(
            contentsOf: AgentHarnessInstaller.Target.claudeInstructions.url(relativeTo: root),
            encoding: .utf8
        )
        XCTAssertTrue(claude.contains(AgentHarnessText.beginMarker))
        XCTAssertTrue(claude.contains(AgentHarnessText.endMarker))

        // A skill file is Tenon's own file end to end, so it carries frontmatter rather
        // than markers — there is nothing of the person's in it to protect.
        let skill = try String(
            contentsOf: AgentHarnessInstaller.Target.claudeSkill.url(relativeTo: root),
            encoding: .utf8
        )
        XCTAssertTrue(skill.hasPrefix("---\nname: tenon\n"))
    }

    func testWhatThePersonWroteAroundTheManagedBlockSurvivesInstallation() throws {
        let target = AgentHarnessInstaller.Target.claudeInstructions
        let url = target.url(relativeTo: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = """
            # My own instructions

            Always answer in Vietnamese.
            """
        try existing.write(to: url, atomically: true, encoding: .utf8)

        _ = try installer.install()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix(existing))
        XCTAssertTrue(contents.contains("Always answer in Vietnamese."))
        XCTAssertTrue(contents.contains(AgentHarnessText.beginMarker))
    }

    func testReinstallingReplacesOnlyTheManagedBlockAndLeavesTheRestExactlyAsFound() throws {
        let target = AgentHarnessInstaller.Target.claudeInstructions
        let url = target.url(relativeTo: root)
        _ = try installer.install()

        // Simulate a person editing on both sides of the block, and an older Tenon having
        // written a different briefing inside it.
        let installed = try String(contentsOf: url, encoding: .utf8)
        let begin = try XCTUnwrap(installed.range(of: AgentHarnessText.beginMarker))
        let end = try XCTUnwrap(installed.range(of: AgentHarnessText.endMarker))
        let stale = installed.replacingCharacters(
            in: begin.upperBound ..< end.lowerBound,
            with: "\nSTALE BRIEFING FROM AN OLDER TENON\n"
        ) + "\n\n## Notes I added afterwards\n"
        try ("# Header I added first\n\n" + stale)
            .write(to: url, atomically: true, encoding: .utf8)

        let outcome = try installer.install()
        XCTAssertEqual(outcome.status, .installed)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("STALE BRIEFING FROM AN OLDER TENON"))
        XCTAssertTrue(contents.hasPrefix("# Header I added first"))
        XCTAssertTrue(contents.hasSuffix("## Notes I added afterwards\n"))
        XCTAssertTrue(contents.contains("tenon-cli rename"))
        XCTAssertEqual(
            contents.components(separatedBy: AgentHarnessText.beginMarker).count - 1,
            1,
            "reinstalling must not stack a second managed block"
        )
    }

    func testInstallingTwiceInARowChangesNothingTheSecondTime() throws {
        _ = try installer.install()
        let after = try AgentHarnessInstaller.Target.allCases.map {
            try Data(contentsOf: $0.url(relativeTo: root))
        }

        let second = try installer.install()
        XCTAssertEqual(second.status, .alreadyCurrent)

        for (target, expected) in zip(AgentHarnessInstaller.Target.allCases, after) {
            XCTAssertEqual(
                try Data(contentsOf: target.url(relativeTo: root)),
                expected,
                "\(target) must be byte-identical after a second install"
            )
        }
    }

    /// The button has to tell the truth before it is pressed, and after Tenon's briefing has
    /// changed under a person who installed an older one.
    func testStatusReportsAbsentThenCurrentThenOutdated() throws {
        XCTAssertEqual(installer.status().state, .absent)

        _ = try installer.install()
        XCTAssertEqual(installer.status().state, .current)

        let url = AgentHarnessInstaller.Target.claudeInstructions.url(relativeTo: root)
        let installed = try String(contentsOf: url, encoding: .utf8)
        let begin = try XCTUnwrap(installed.range(of: AgentHarnessText.beginMarker))
        let end = try XCTUnwrap(installed.range(of: AgentHarnessText.endMarker))
        try installed
            .replacingCharacters(
                in: begin.upperBound ..< end.lowerBound,
                with: "\nolder briefing\n"
            )
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status().state, .outdated)
    }

    /// A person who installed the harness and later changed their mind gets the same
    /// guarantee in reverse: their own text is what is left behind.
    func testRemovingTakesTheManagedBlockAndTheSkillAndNothingElse() throws {
        let url = AgentHarnessInstaller.Target.claudeInstructions.url(relativeTo: root)
        _ = try installer.install()
        let installed = try String(contentsOf: url, encoding: .utf8)
        try (installed + "\n## Mine\n").write(to: url, atomically: true, encoding: .utf8)

        try installer.remove()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains(AgentHarnessText.beginMarker))
        XCTAssertFalse(contents.contains("tenon-cli rename"))
        XCTAssertTrue(contents.contains("## Mine"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: AgentHarnessInstaller.Target.claudeSkill
                    .url(relativeTo: root).path
            )
        )
        XCTAssertEqual(installer.status().state, .absent)
    }
}

/// The briefing is the product here: an agent that reads it must be able to act on it
/// without discovering, one failed command later, that Tenon does not work that way.
final class AgentHarnessTextTests: XCTestCase {
    func testTheBriefingNamesOnlyEnvironmentVariablesTenonActuallyExports() {
        let body = AgentHarnessText.instructions

        for exported in [
            "TENON_PANE_ID",
            "TENON_TAB_ID",
            "TENON_WORKSPACE_ID",
            "TENON_SOCKET_PATH",
        ] {
            XCTAssertTrue(body.contains(exported), "\(exported) is exported and must be named")
        }
        // Named by the operator, never exported by Tenon. If one of these ever appears in
        // the briefing, an agent is being taught to read a variable that is not there.
        for absent in ["TENON_PANEL_ID", "TENON_TAB_UUID", "TENON_SESSION_ID"] {
            XCTAssertFalse(body.contains(absent), "\(absent) does not exist")
        }
    }

    /// Every `tenon-cli` verb and every intent id the briefing prints has to exist. This is
    /// the assertion that keeps the installed instructions honest as the CLI changes.
    func testEveryIntentIDTheBriefingPrintsIsInTheCatalog() throws {
        let known = Set(CoreIntentName.allCases.map(\.rawValue))
        let pattern = try NSRegularExpression(
            pattern: #"\b[a-z][a-z.]*\.v[0-9]+\b"#
        )
        for source in [AgentHarnessText.instructions, AgentHarnessText.skill] {
            let range = NSRange(source.startIndex ..< source.endIndex, in: source)
            let printed = pattern.matches(in: source, range: range).compactMap {
                Range($0.range, in: source).map { String(source[$0]) }
            }
            XCTAssertFalse(printed.isEmpty, "the briefing must cite intents by id")
            for id in printed {
                XCTAssertTrue(known.contains(id), "\(id) is not in the catalog")
            }
        }
    }

    /// The two ids that go stale are the ones a pane carries from where it was born. Saying
    /// so, and naming the live answer, is the difference between a useful shortcut and a
    /// wrong answer an agent has no way to detect.
    func testTheBriefingSaysWhichIdentityIsASnapshotAndWhereTheLiveAnswerIs() {
        let body = AgentHarnessText.instructions
        XCTAssertTrue(body.contains("workspace.pane.owner.v1"))
        XCTAssertTrue(body.lowercased().contains("moved"))
    }

    func testTheSkillCarriesTheFrontmatterClaudeCodeNeedsToLoadIt() {
        let skill = AgentHarnessText.skill
        XCTAssertTrue(skill.hasPrefix("---\nname: tenon\ndescription: "))
        let lines = skill.components(separatedBy: "\n")
        let closing = lines.dropFirst().firstIndex(of: "---")
        XCTAssertNotNil(closing, "frontmatter must be closed")
        // A description that runs onto a second line breaks the frontmatter parse.
        let description = try? XCTUnwrap(lines.first { $0.hasPrefix("description: ") })
        XCTAssertLessThanOrEqual((description ?? "").count, 1_024)
    }

    /// The whole briefing is loaded into every agent session on the machine, so its cost is
    /// paid on every request. It stays a briefing, not a manual.
    func testTheBriefingStaysSmallEnoughToLoadIntoEverySession() {
        XCTAssertLessThan(AgentHarnessText.instructions.utf8.count, 4_096)
        XCTAssertLessThan(AgentHarnessText.skill.utf8.count, 8_192)
    }
}
