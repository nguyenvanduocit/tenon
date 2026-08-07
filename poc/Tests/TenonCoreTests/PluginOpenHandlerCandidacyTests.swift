import TenonIntentCore
@testable import TenonCore
import XCTest

/// Offering to handle something must never be able to break the plugin that offered.
/// See `docs/design-open-handlers.md`.
final class PluginOpenHandlerCandidacyTests: XCTestCase {
    func testDeclaringADelegableContractIsAnOfferRatherThanABinding() throws {
        let urlOpen = try IntentID("url.open.v1")
        let ownContract = try IntentID("dev.tenon.browser.open.v1")

        let candidacy = PluginOpenHandlerCandidacy.partition(
            declared: [urlOpen, ownContract],
            delegable: [urlOpen],
            approved: []
        )

        // The plugin still works: everything it owns binds immediately.
        XCTAssertEqual(candidacy.binds, [ownContract])
        // And the offer is recorded rather than thrown away or fatal.
        XCTAssertEqual(candidacy.awaitingApproval, [urlOpen])
    }

    func testApprovalIsWhatTurnsTheOfferIntoAHandler() throws {
        let urlOpen = try IntentID("url.open.v1")
        let ownContract = try IntentID("dev.tenon.browser.open.v1")

        let candidacy = PluginOpenHandlerCandidacy.partition(
            declared: [urlOpen, ownContract],
            delegable: [urlOpen],
            approved: [urlOpen]
        )

        XCTAssertEqual(candidacy.binds, [ownContract, urlOpen])
        XCTAssertTrue(candidacy.awaitingApproval.isEmpty)
    }

    /// A plugin's own contracts need nobody's permission — only the delegable ones are the
    /// person's to hand out.
    func testAPluginsOwnContractsNeverWaitOnAnybody() throws {
        let own = [
            try IntentID("dev.tenon.git.stage.v1"),
            try IntentID("dev.tenon.git.commit.v1"),
        ]

        let candidacy = PluginOpenHandlerCandidacy.partition(
            declared: own,
            delegable: [try IntentID("url.open.v1")],
            approved: []
        )

        XCTAssertEqual(candidacy.binds, own.sorted { $0.rawValue < $1.rawValue })
        XCTAssertTrue(candidacy.awaitingApproval.isEmpty)
    }

    /// An approval for something the plugin never offered widens nothing. The activation
    /// coordinator refuses that combination outright, so constructing it would take the
    /// plugin down for a reason the person could not see.
    func testAnApprovalForSomethingNeverDeclaredIsDiscarded() throws {
        let declared = [try IntentID("url.open.v1")]
        let strayApproval = try IntentID("file.open.v1")

        XCTAssertEqual(
            PluginOpenHandlerCandidacy.effectiveApprovals(
                declared: declared,
                approved: [strayApproval, try IntentID("url.open.v1")]
            ),
            [try IntentID("url.open.v1")]
        )
    }

    /// Order is stable so a settings list and a chooser do not shuffle between reads.
    func testBothSidesComeBackInAStableOrder() throws {
        let candidacy = PluginOpenHandlerCandidacy.partition(
            declared: [
                try IntentID("url.open.v1"),
                try IntentID("file.open.v1"),
                try IntentID("dev.tenon.browser.open.v1"),
            ],
            delegable: [try IntentID("url.open.v1"), try IntentID("file.open.v1")],
            approved: []
        )

        XCTAssertEqual(
            candidacy.awaitingApproval.map(\.rawValue),
            ["file.open.v1", "url.open.v1"]
        )
        XCTAssertEqual(candidacy.binds.map(\.rawValue), ["dev.tenon.browser.open.v1"])
    }
}
