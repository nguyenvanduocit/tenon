import Foundation
@testable import TenonIntentCore
import XCTest

final class IntentProviderTests: XCTestCase {
    func testPluginProviderPrincipalIsBoundToInstallationAndGeneration() throws {
        let pluginID = PluginID("dev.tenon.git")
        let firstInstallation = UUID()
        let secondInstallation = UUID()

        let first = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: firstInstallation
        ).principal(sessionRevision: 4)
        let reloaded = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: firstInstallation
        ).principal(sessionRevision: 5)
        let reinstalled = IntentProviderOwner.plugin(
            id: pluginID,
            installationID: secondInstallation
        ).principal(sessionRevision: 1)

        XCTAssertEqual(first.kind, .plugin)
        XCTAssertEqual(first.audience, .plugin)
        XCTAssertEqual(first.sessionRevision, 4)
        XCTAssertEqual(first.id, reloaded.id)
        XCTAssertNotEqual(first.id, reinstalled.id)
    }

    func testPluginPrincipalRoundTripsToInstallationOwner() throws {
        let owner = IntentProviderOwner.plugin(
            id: PluginID("dev.tenon.browser"),
            installationID: UUID()
        )
        let principal = owner.principal(sessionRevision: 42)

        XCTAssertEqual(
            try IntentProviderOwner.pluginOwner(from: principal),
            owner
        )
    }

    func testPluginPrincipalParserRejectsWrongKindAndNonCanonicalID() throws {
        let cli = IntentPrincipal(
            id: "cli:tenon",
            kind: .cli,
            sessionRevision: 1
        )
        XCTAssertThrowsError(
            try IntentProviderOwner.pluginOwner(from: cli)
        ) {
            XCTAssertEqual(
                $0 as? IntentPrincipalIdentityError,
                .pluginPrincipalRequired
            )
        }

        let malformed = IntentPrincipal(
            id: "plugin:dev.tenon.browser:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            kind: .plugin,
            sessionRevision: 1
        )
        XCTAssertThrowsError(
            try IntentProviderOwner.pluginOwner(from: malformed)
        ) {
            XCTAssertEqual(
                $0 as? IntentPrincipalIdentityError,
                .malformedPluginPrincipal
            )
        }
    }

    func testProviderSendRequestCannotCarryCallerOrCausalMetadata() throws {
        let request = IntentProviderSendRequest(
            intentID: try IntentID("workspace.snapshot.v1"),
            input: .object([:]),
            target: try ProviderID("dev.tenon.workspace"),
            idempotencyKey: "snapshot-1",
            requestedTimeout: .seconds(1)
        )

        XCTAssertEqual(request.intentID.rawValue, "workspace.snapshot.v1")
        XCTAssertEqual(request.input, .object([:]))
        XCTAssertEqual(request.target?.rawValue, "dev.tenon.workspace")
        XCTAssertEqual(request.idempotencyKey, "snapshot-1")
        XCTAssertEqual(request.requestedTimeout, .seconds(1))
    }
}
