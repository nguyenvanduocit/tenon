import AppKit
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

@MainActor
final class WorkspaceRecentMenuTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-recent-menu-\(UUID().uuidString).json")
    }

    private func entries(_ count: Int) -> [RecentWorkspaceStore.Entry] {
        (1...count).map { index in
            RecentWorkspaceStore.Entry(
                name: "Workspace \(index)",
                path: URL(fileURLWithPath: "/tmp/project-\(index)"),
                appearance: WorkspaceAppearance(
                    symbol: WorkspaceSymbol.allCases[index % WorkspaceSymbol.allCases.count],
                    accent: AccentColor.allCases[index % AccentColor.allCases.count]
                )
            )
        }
    }

    func testSearchAppearsOnlyWhenMoreThanTenRowsCouldBeShown() {
        XCTAssertFalse(WorkspaceRecentMenuProjection.showsSearch(for: entries(10)))
        XCTAssertTrue(WorkspaceRecentMenuProjection.showsSearch(for: entries(11)))
    }

    func testProjectionSearchesNameAndPathThenShowsAtMostTen() {
        let all = entries(20)

        XCTAssertEqual(
            WorkspaceRecentMenuProjection.visible(entries: all, query: "").count,
            10
        )
        XCTAssertEqual(
            WorkspaceRecentMenuProjection.visible(entries: all, query: "workspace 17")
                .map(\.name),
            ["Workspace 17"]
        )
        XCTAssertEqual(
            WorkspaceRecentMenuProjection.visible(entries: all, query: "PROJECT-4")
                .map(\.name),
            ["Workspace 4"]
        )
    }

    func testTenRowsAndSearchStayInsideTheFocusedSurfaceHeightBudget() {
        let height = WorkspaceRecentMenuMetrics.actionHeight
            + 2
            + WorkspaceRecentMenuMetrics.searchHeight
            + WorkspaceRecentMenuMetrics.sectionHeight
            + WorkspaceRecentMenuMetrics.listHeight(rowCount: 10)

        XCTAssertLessThanOrEqual(height, 520)
        XCTAssertEqual(WorkspaceRecentMenuMetrics.listHeight(rowCount: 20), 388)
    }

    func testRecentMarkUsesTheRememberedIconAndColour() {
        let entry = RecentWorkspaceStore.Entry(
            name: "Metrics",
            path: URL(fileURLWithPath: "/tmp/metrics"),
            appearance: WorkspaceAppearance(symbol: .metrics, accent: .green)
        )

        XCTAssertEqual(entry.appearance.symbol.systemName, "chart.bar")
        XCTAssertEqual(
            WorkspaceMark.tint(for: entry),
            Color(tintHex: AccentColor.green.hex)
        )
    }

    func testMenuRendersTwentyRememberedWorkspacesAsACompactPopover() throws {
        let fileURL = tempFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recents = RecentWorkspaceStore(fileURL: fileURL)
        for entry in entries(20).reversed() {
            recents.record(
                name: entry.name,
                path: entry.path,
                appearance: entry.appearance
            )
        }
        let store = WorkspaceStore(
            catalog: WorkspaceCatalog(
                name: "Open",
                path: URL(fileURLWithPath: "/tmp/open")
            ),
            recentWorkspaces: recents
        )
        let hosting = NSHostingView(
            rootView: WorkspaceRecentMenu(store: store, dismiss: {})
        )
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: WorkspaceRecentMenuMetrics.width,
                height: hosting.fittingSize.height
            )
        )
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize.width, WorkspaceRecentMenuMetrics.width, accuracy: 1)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, 520)

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["TENON_RECENT_WORKSPACE_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThan(png.count, 1_000, "the recent-workspace menu rendered empty")
    }

    /// `position` returns a view that fills its parent's proposal. A popover attached after
    /// it therefore anchors to the whole sidebar and appears at the middle of the edge.
    /// Attach while the source is still 1×1, then place that source at the secondary click.
    func testContextPopoverAttachesBeforeItsSourceIsPositioned() throws {
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/TenonApp/WorkspaceSidebarView.swift"),
            encoding: .utf8
        )
        let anchorStart = try XCTUnwrap(source.range(of: "Color.clear\n                    .frame(width: 1, height: 1)"))
        let popover = try XCTUnwrap(
            source.range(of: ".popover(isPresented: $isRecentMenuPresented", range: anchorStart.lowerBound..<source.endIndex)
        )
        let position = try XCTUnwrap(
            source.range(of: ".position(contextPoint)", range: anchorStart.lowerBound..<source.endIndex)
        )

        XCTAssertLessThan(popover.lowerBound, position.lowerBound)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
