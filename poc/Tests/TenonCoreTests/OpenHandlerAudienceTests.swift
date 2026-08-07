import TenonIntentCore
@testable import TenonCore
import XCTest

/// Open contracts remain public adapter contracts. Built-in host UI is the same semantic
/// owner as the application services it uses and therefore never receives a public intent
/// principal merely to reuse their implementation. See `docs/design-open-handlers.md`.
final class OpenHandlerAudienceTests: XCTestCase {
    func testOpenContractsKeepTheProgrammaticAudienceProfile() throws {
        let open = try CoreIntentCatalog.definitions().filter {
            $0.declaration.contractClass == .open
        }
        XCTAssertFalse(open.isEmpty)
        for definition in open {
            XCTAssertEqual(definition.declaration.audiences, [.plugin, .cli, .agent])
            XCTAssertEqual(
                definition.dispatchRule.exposure.discoverableBy,
                definition.declaration.audiences
            )
            XCTAssertEqual(
                definition.dispatchRule.exposure.invocableBy,
                definition.declaration.audiences
            )
        }
    }

    /// At least one open contract must exist, or the test above passes vacuously and the
    /// derivation could be silently dead.
    func testTheCatalogStillHasAnOpenContract() throws {
        let open = try CoreIntentCatalog.definitions()
            .filter { $0.declaration.contractClass == .open }
            .map(\.declaration.name.rawValue)
            .sorted()

        XCTAssertEqual(open, ["file.open.v1", "url.open.v1"])
    }

    func testPluginAudienceAllowlistRemainsClosed() {
        XCTAssertEqual(
            PluginIntentProvision.allowedAudiences,
            [.plugin, .user, .cli, .agent]
        )
    }

    func testAudienceRemainsAConsequenceOfPrincipalKind() {
        for kind in IntentPrincipal.Kind.allCases {
            let principal = IntentPrincipal(id: "test:\(kind)", kind: kind, sessionRevision: 1)
            XCTAssertEqual(principal.audience.rawValue, kind.rawValue)
        }
    }
}
