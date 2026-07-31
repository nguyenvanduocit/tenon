import XCTest
@testable import TenonApp

/// T-061: the pair-authoring seed — pure rules, no window, no PTY.
///
/// What must never regress: the agent is told the REAL plugins root (not a guess),
/// the load-bearing parts of the plugin contract are taught exactly, and the whole
/// prompt crosses the shell as ONE argument no matter what bytes it contains.
final class AutomationAuthoringTests: XCTestCase {
    /// A root with a space — the quoting rule has to carry it.
    private let root = "/tmp/tenon test/plugins"

    func testPromptEmbedsTheRealPluginsRootAndTeachesTheContract() {
        let prompt = AutomationAuthoring.prompt(pluginsRoot: root)

        XCTAssertTrue(
            prompt.contains(root),
            "the agent must be told the real plugins root verbatim"
        )
        XCTAssertTrue(
            prompt.contains("/* tenon-manifest"),
            "the header opener must be taught exactly as the loader matches it"
        )
        XCTAssertTrue(
            prompt.contains("automation.fired"),
            "the event the script subscribes to must be named"
        )
        XCTAssertTrue(
            prompt.contains("\"every\"") && prompt.contains("\"daily\""),
            "both cadence forms must be taught"
        )
        XCTAssertTrue(
            prompt.contains("\"1m\""),
            "the minimum interval is the mistake agents will make; teach it"
        )
        XCTAssertTrue(
            prompt.contains("tenon-cli intent list")
                && prompt.contains("tenon-cli intent describe"),
            "intent discovery goes through the CLI the pane already has"
        )
        XCTAssertTrue(
            prompt.contains("Run Now") && prompt.contains("\"manual\""),
            "verification rides T-060's surface; the agent must be told to use it"
        )
        XCTAssertTrue(
            prompt.contains("consent"),
            "the first privileged firing prompts the user; the agent must warn them"
        )
    }

    func testCommandIsClaudePlusTheWholePromptAsOneQuotedArgument() {
        let command = AutomationAuthoring.command(pluginsRoot: root)

        XCTAssertEqual(
            command,
            "claude " + AutomationAuthoring.posixQuoted(
                AutomationAuthoring.prompt(pluginsRoot: root)
            ),
            "one binary, one argument — the prompt must never be split by the shell"
        )
        XCTAssertTrue(command.hasPrefix("claude '"))
    }

    func testPosixQuotingNeutralizesHostileBytes() {
        XCTAssertEqual(
            AutomationAuthoring.posixQuoted("a'b"),
            "'a'\\''b'",
            "an embedded single quote must re-enter quoting, not end it"
        )
        XCTAssertEqual(
            AutomationAuthoring.posixQuoted("$(rm -rf /) `id` \"x\" \\n"),
            "'$(rm -rf /) `id` \"x\" \\n'",
            "inside single quotes the shell interprets nothing"
        )
    }
}
