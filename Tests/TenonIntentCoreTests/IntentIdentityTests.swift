import XCTest
@testable import TenonIntentCore

final class IntentIdentityTests: XCTestCase {
    func testAcceptsCanonicalVersionedIntentNames() throws {
        XCTAssertEqual(try IntentID("terminal.run.v1").rawValue, "terminal.run.v1")
        XCTAssertEqual(
            try IntentID("dev.tenon.git.stage.v12").majorVersion,
            12
        )
    }

    func testRejectsIntentNamesOutsideCanonicalGrammar() {
        let invalidNames = [
            "",
            "Terminal.run.v1",
            ".terminal.run.v1",
            "terminal..run.v1",
            "terminal.-run.v1",
            "terminal.run-.v1",
            "terminal_run.v1",
            "terminal.run",
            "terminal.run.v0",
            "terminal.run.v01",
            String(repeating: "a", count: 126) + ".v1",
        ]

        for name in invalidNames {
            XCTAssertThrowsError(try IntentID(name), "Expected \(name) to be rejected")
        }
    }

    func testPluginIDUsesLowercaseDotSeparatedDNSLabels() throws {
        XCTAssertEqual(PluginID("dev.tenon.git").rawValue, "dev.tenon.git")

        for value in [
            "browser",
            "Dev.tenon.git",
            "dev..git",
            "-dev.tenon",
            "dev.tenon-",
            "dev_tenon.git",
        ] {
            XCTAssertThrowsError(try PluginID(value), "Expected \(value) to be rejected")
        }
    }

    func testDomainErrorCodeCannotClaimClosedKernelNamespace() throws {
        XCTAssertEqual(
            try IntentDomainErrorCode("dev.tenon.git.index-locked").rawValue,
            "dev.tenon.git.index-locked"
        )
        XCTAssertThrowsError(try IntentDomainErrorCode("tenon.invented"))
    }
}
