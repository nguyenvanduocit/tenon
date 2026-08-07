import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

/// A handler sees every address and every path the person opens through it. Approval is
/// therefore explicit, per plugin, and revocable — never a consequence of installing.
/// See `docs/design-open-handlers.md`.
final class OpenHandlerApprovalsTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-handler-approvals-\(UUID().uuidString)")
            .appendingPathComponent("approvals.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testNothingIsApprovedByDefault() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)

        let approvals = await store.approvals
        let forBrowser = await store.approvedIntentIDs(for: "dev.tenon.browser")

        XCTAssertTrue(approvals.isEmpty)
        XCTAssertTrue(forBrowser.isEmpty)
    }

    func testAGrantNamesOnePluginAndOneContract() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)
        let urlOpen = try IntentID("url.open.v1")
        let fileOpen = try IntentID("file.open.v1")

        await store.approve(pluginID: "dev.tenon.browser", intentID: urlOpen)

        let granted = await store.approvedIntentIDs(for: "dev.tenon.browser")
        let otherContract = await store.isApproved(
            pluginID: "dev.tenon.browser",
            intentID: fileOpen
        )
        let otherPlugin = await store.approvedIntentIDs(for: "dev.tenon.file-explorer")

        XCTAssertEqual(granted, [urlOpen])
        // Says nothing about another contract...
        XCTAssertFalse(otherContract)
        // ...nor about another plugin.
        XCTAssertTrue(otherPlugin.isEmpty)
    }

    func testAGrantSurvivesRelaunch() async throws {
        let urlOpen = try IntentID("url.open.v1")
        await OpenHandlerApprovals(fileURL: fileURL)
            .approve(pluginID: "dev.tenon.browser", intentID: urlOpen)

        let reopened = OpenHandlerApprovals(fileURL: fileURL)
        let survived = await reopened.isApproved(
            pluginID: "dev.tenon.browser",
            intentID: urlOpen
        )

        XCTAssertTrue(survived)
    }

    func testRevokingIsImmediateAndDoesNotTouchOtherGrants() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)
        let urlOpen = try IntentID("url.open.v1")
        let fileOpen = try IntentID("file.open.v1")
        await store.approve(pluginID: "dev.tenon.browser", intentID: urlOpen)
        await store.approve(pluginID: "dev.tenon.browser", intentID: fileOpen)

        await store.revoke(pluginID: "dev.tenon.browser", intentID: urlOpen)

        let remaining = await store.approvedIntentIDs(for: "dev.tenon.browser")
        let reloaded = await OpenHandlerApprovals(fileURL: fileURL)
            .approvedIntentIDs(for: "dev.tenon.browser")

        XCTAssertEqual(remaining, [fileOpen])
        XCTAssertEqual(reloaded, [fileOpen])
    }

    /// A grant must not outlive the plugin that earned it. Otherwise a later plugin
    /// claiming the same id inherits permission nobody gave it.
    func testUninstallingAPluginDropsEveryGrantItHeld() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)
        let urlOpen = try IntentID("url.open.v1")
        let fileOpen = try IntentID("file.open.v1")
        await store.approve(pluginID: "dev.tenon.browser", intentID: urlOpen)
        await store.approve(pluginID: "dev.tenon.browser", intentID: fileOpen)
        await store.approve(pluginID: "dev.tenon.file-explorer", intentID: fileOpen)

        await store.revokeAll(for: "dev.tenon.browser")

        let dropped = await store.approvedIntentIDs(for: "dev.tenon.browser")
        let untouched = await store.approvedIntentIDs(for: "dev.tenon.file-explorer")

        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(untouched, [fileOpen])
    }

    /// The grants a person sees and the set the kernel enforces are one value — the store
    /// hands `ProviderActivationCoordinator` exactly what settings displayed.
    func testTheApprovedSetIsWhatTheCoordinatorTakes() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)
        let urlOpen = try IntentID("url.open.v1")
        await store.approve(pluginID: "dev.tenon.browser", intentID: urlOpen)

        let approved = await store.approvedIntentIDs(for: "dev.tenon.browser")
        let candidacy = PluginOpenHandlerCandidacy.partition(
            declared: [urlOpen],
            delegable: [urlOpen],
            approved: approved
        )

        XCTAssertEqual(candidacy.binds, [urlOpen])
        XCTAssertTrue(candidacy.awaitingApproval.isEmpty)
    }

    /// Shipping with the app is consent to run a plugin, not consent to let it see every
    /// address a person opens. A bundled plugin starts with no handler approval either.
    func testShippingWithTheAppGrantsNoHandlerApproval() async throws {
        let store = OpenHandlerApprovals(fileURL: fileURL)

        let bundled = await store.approvedIntentIDs(for: "dev.tenon.browser")

        XCTAssertTrue(bundled.isEmpty)
    }

    /// An offer carries the plugin's own identity, because "let this open your links?" is
    /// unanswerable without knowing who "this" is.
    func testAnOfferCarriesTheIdentityAPersonNeedsToAnswer() throws {
        let offer = OpenHandlerOffer(
            pluginID: "dev.tenon.browser",
            pluginName: "Browser",
            intentID: try IntentID("url.open.v1"),
            contractTitle: "Open address",
            isApproved: false
        )

        XCTAssertEqual(offer.pluginName, "Browser")
        XCTAssertEqual(offer.id, "dev.tenon.browser|url.open.v1")
    }
}
