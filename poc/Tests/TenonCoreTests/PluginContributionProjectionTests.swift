import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

/// What a live generation puts on screen, asserted without a host.
///
/// These rules used to be computed inline in `PluginHost.publish()`, which meant asserting any
/// of them required loading plugins, starting runtimes and waiting for a publish cycle. They
/// are a pure function of the snapshots, and this is what that buys.
final class PluginContributionProjectionTests: XCTestCase {
    func testStatusItemsAndViewsFollowThePublishOrderTheyWereGiven() throws {
        let projection = PluginContributionProjection.make(
            orderedSnapshots: [
                (PluginID("dev.test.a"), try snapshot(id: "dev.test.a", status: "A")),
                (PluginID("dev.test.b"), try snapshot(id: "dev.test.b", status: "B")),
            ],
            paletteQueryRevision: 0
        )

        XCTAssertEqual(projection.statusItems.map(\.text), ["A", "B"])
        XCTAssertEqual(
            projection.statusItems.map(\.pluginID.rawValue),
            ["dev.test.a", "dev.test.b"],
            "the order the host decided is the order that is published"
        )
    }

    func testAGenerationWithNoStatusTextContributesNoStatusItem() throws {
        let projection = PluginContributionProjection.make(
            orderedSnapshots: [
                (PluginID("dev.test.quiet"), try snapshot(id: "dev.test.quiet", status: nil)),
            ],
            paletteQueryRevision: 0
        )

        XCTAssertTrue(projection.statusItems.isEmpty)
    }

    /// A stale answer under a new question is a wrong answer, so it is shown as pending
    /// instead.
    func testPaletteResultsAreShownOnlyForTheCurrentRevision() throws {
        let current = PluginContributionProjection.make(
            orderedSnapshots: [
                (
                    PluginID("dev.test.p"),
                    try snapshot(id: "dev.test.p", providerRevision: 7, results: ["hit"])
                ),
            ],
            paletteQueryRevision: 7
        )
        XCTAssertEqual(current.paletteSections.first?.results.count, 1)
        XCTAssertEqual(current.paletteSections.first?.isPending, false)

        let stale = PluginContributionProjection.make(
            orderedSnapshots: [
                (
                    PluginID("dev.test.p"),
                    try snapshot(id: "dev.test.p", providerRevision: 6, results: ["hit"])
                ),
            ],
            paletteQueryRevision: 7
        )
        XCTAssertEqual(stale.paletteSections.first?.results, [])
        XCTAssertEqual(stale.paletteSections.first?.isPending, true)
    }

    /// The projection is total: the same snapshots always give the same surfaces, which is what
    /// makes a re-publish safe to run at any time.
    func testTheProjectionIsDeterministic() throws {
        let snapshots = [
            (PluginID("dev.test.a"), try snapshot(id: "dev.test.a", status: "A")),
            (PluginID("dev.test.b"), try snapshot(id: "dev.test.b", status: "B")),
        ]

        XCTAssertEqual(
            PluginContributionProjection.make(
                orderedSnapshots: snapshots,
                paletteQueryRevision: 3
            ),
            PluginContributionProjection.make(
                orderedSnapshots: snapshots,
                paletteQueryRevision: 3
            )
        )
    }

    // MARK: - Fixture

    private func snapshot(
        id: String,
        status: String? = nil,
        providerRevision: Int? = nil,
        results: [String] = []
    ) throws -> PluginRuntimeSnapshot {
        let intentID = try IntentID("dev.test.probe.v1")
        return PluginRuntimeSnapshot(
            revision: 1,
            manifest: try PluginManifest(
                id: PluginID(id),
                name: id,
                version: "1",
                permissions: [],
                intents: PluginIntentManifest(uses: [], provides: [])
            ),
            phase: .active,
            statusBarText: status,
            views: [],
            paletteProviders: providerRevision.map { revision in
                [
                    PaletteProviderInfo(
                        providerID: "results",
                        title: "Results",
                        deliveredRevision: revision,
                        publishedRevision: revision,
                        results: results.map { value in
                            PaletteResultItem(
                                id: value,
                                title: value,
                                intentID: intentID,
                                input: .object([:])
                            )
                        }
                    )
                ]
            } ?? [],
            openViewInstances: [],
            permissionViolations: [],
            runtimeThreadIdentifier: nil,
            pendingNestedIntentCount: 0,
            lateProviderReplyCount: 0
        )
    }
}
