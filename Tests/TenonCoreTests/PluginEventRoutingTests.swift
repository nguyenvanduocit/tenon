import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// The two gates that decide who hears a fact, asserted without a host.
///
/// They used to be written three times inside `PluginHost` — once in the broadcast loop, once
/// in the targeted send, once in the plugin-published fan-out. One of those copies is what a
/// terminal-privacy rule is one edit away from losing.
final class PluginEventRoutingTests: XCTestCase {
    func testTerminalEventsReachOnlyPluginsThatAskedForTerminalAccess() throws {
        let reader = try manifest(id: "dev.test.reader", permissions: ["terminal.read"])
        let bystander = try manifest(id: "dev.test.bystander", permissions: [])

        XCTAssertTrue(
            PluginEventRouting.permits(event: "terminal.title-changed", manifest: reader)
        )
        XCTAssertFalse(
            PluginEventRouting.permits(event: "terminal.title-changed", manifest: bystander),
            "a plugin without terminal.read must never be told what is in a terminal"
        )
    }

    func testNonTerminalEventsNeedNoPermission() throws {
        let bystander = try manifest(id: "dev.test.bystander", permissions: [])

        XCTAssertTrue(
            PluginEventRouting.permits(event: "workspace.changed", manifest: bystander)
        )
        // The prefix is a prefix, not a substring: a channel that merely mentions terminals is
        // not a terminal event.
        XCTAssertTrue(
            PluginEventRouting.permits(event: "notes.terminal.tips", manifest: bystander)
        )
    }

    func testPublishingRequiresTheManifestDeclaration() throws {
        let publisher = try manifest(
            id: "dev.test.publisher",
            publishes: ["board.changed"]
        )

        XCTAssertTrue(
            PluginEventRouting.mayPublish(local: "board.changed", manifest: publisher)
        )
        XCTAssertFalse(
            PluginEventRouting.mayPublish(local: "board.deleted", manifest: publisher),
            "a plugin publishes the channels it declared and no others"
        )
    }

    func testObserversAreTheDeclaringPluginsInAStableOrder() throws {
        let manifests: [PluginID: PluginManifest] = [
            PluginID("dev.test.zeta"): try manifest(
                id: "dev.test.zeta",
                observes: ["dev.test.publisher/board.changed"]
            ),
            PluginID("dev.test.alpha"): try manifest(
                id: "dev.test.alpha",
                observes: ["dev.test.publisher/board.changed"]
            ),
            PluginID("dev.test.other"): try manifest(
                id: "dev.test.other",
                observes: ["dev.test.publisher/board.deleted"]
            ),
        ]

        let observers = PluginEventRouting.observers(
            of: "dev.test.publisher/board.changed",
            among: manifests
        )

        XCTAssertEqual(
            observers.map(\.rawValue),
            ["dev.test.alpha", "dev.test.zeta"],
            "the fan-out order must not depend on dictionary iteration"
        )
    }

    // MARK: - Fixture

    private func manifest(
        id: String,
        permissions: [String] = [],
        publishes: [String] = [],
        observes: [String] = []
    ) throws -> PluginManifest {
        try PluginManifest(
            id: PluginID(id),
            name: id,
            version: "1",
            permissions: permissions,
            intents: PluginIntentManifest(uses: [], provides: []),
            events: try PluginEventManifest(
                publishes: publishes,
                observes: observes
            )
        )
    }
}
