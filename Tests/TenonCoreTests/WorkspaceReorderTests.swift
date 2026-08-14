import XCTest

@testable import TenonCore

final class WorkspaceReorderTests: XCTestCase {
    func testEveryVerticalPointNamesOneInsertionBoundary() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let rows = strip(ids)

        XCTAssertEqual(WorkspaceReorder.insertionIndex(at: -40, rows: rows), 0)
        XCTAssertEqual(WorkspaceReorder.insertionIndex(at: rows[0].midY, rows: rows), 0)
        XCTAssertEqual(WorkspaceReorder.insertionIndex(at: rows[0].midY + 0.1, rows: rows), 1)
        XCTAssertEqual(WorkspaceReorder.insertionIndex(at: rows[2].midY + 0.1, rows: rows), 3)
        XCTAssertEqual(WorkspaceReorder.insertionIndex(at: 4_000, rows: rows), 4)
    }

    func testForwardAndBackwardInsertionsBecomeArrayIndices() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let rows = strip(ids)

        XCTAssertEqual(
            WorkspaceReorder.destination(forWorkspace: ids[0], insertingAt: 4, rows: rows),
            3
        )
        XCTAssertEqual(
            WorkspaceReorder.destination(forWorkspace: ids[3], insertingAt: 0, rows: rows),
            0
        )
    }

    func testDroppingOnEitherSideOfTheCurrentPlaceIsANoOp() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let rows = strip(ids)

        XCTAssertNil(
            WorkspaceReorder.destination(forWorkspace: ids[2], insertingAt: 2, rows: rows)
        )
        XCTAssertNil(
            WorkspaceReorder.destination(forWorkspace: ids[2], insertingAt: 3, rows: rows)
        )
    }

    func testUnknownWorkspaceAndOutOfRangeBoundaryAreRefused() {
        let ids = (0 ..< 3).map { _ in UUID() }
        let rows = strip(ids)

        XCTAssertNil(
            WorkspaceReorder.destination(forWorkspace: UUID(), insertingAt: 1, rows: rows)
        )
        XCTAssertNil(
            WorkspaceReorder.destination(forWorkspace: ids[0], insertingAt: -1, rows: rows)
        )
        XCTAssertNil(
            WorkspaceReorder.destination(forWorkspace: ids[0], insertingAt: 4, rows: rows)
        )
    }

    func testHorizontalSlackAdmitsTheSidebarAndCancelsAimedAwayFromIt() {
        XCTAssertTrue(WorkspaceReorder.admitsDrop(pointerX: 0, minX: 0, maxX: 220))
        XCTAssertTrue(
            WorkspaceReorder.admitsDrop(
                pointerX: 220 + WorkspaceReorder.dropSlack,
                minX: 0,
                maxX: 220
            )
        )
        XCTAssertFalse(
            WorkspaceReorder.admitsDrop(
                pointerX: 220 + WorkspaceReorder.dropSlack + 0.1,
                minX: 0,
                maxX: 220
            )
        )
    }

    func testAccessibilityDescriptionsNamePositionAndSelection() {
        XCTAssertEqual(
            WorkspaceReorder.spokenPosition(1, of: 3, isActive: false),
            "workspace 2 of 3"
        )
        XCTAssertEqual(
            WorkspaceReorder.spokenPosition(1, of: 3, isActive: true),
            "workspace 2 of 3, active"
        )
        XCTAssertEqual(
            WorkspaceReorder.announcement(name: "Tenon", movedTo: 2, of: 4),
            "Moved Tenon to workspace 3 of 4"
        )
    }

    private func strip(_ ids: [UUID]) -> [WorkspaceRowExtent] {
        ids.enumerated().map { index, id in
            let minY = Double(index * 49 + 8)
            return WorkspaceRowExtent(id: id, minY: minY, maxY: minY + 46)
        }
    }
}
