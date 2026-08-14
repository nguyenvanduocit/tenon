import XCTest
@testable import TenonCore

final class PaneArrangementTests: XCTestCase {
    func testTiledLayoutBalancesRowsAndFillsTheCanvas() throws {
        let ids = (0..<5).map { _ in UUID() }
        let proposal = try proposal(
            ids: ids,
            preset: .tiled,
            mainSlotID: ids[0]
        )

        XCTAssertEqual(proposal.map(\.rect), [
            GridRect(x: 0, y: 0, width: 4, height: 6),
            GridRect(x: 4, y: 0, width: 4, height: 6),
            GridRect(x: 8, y: 0, width: 4, height: 6),
            GridRect(x: 0, y: 6, width: 6, height: 6),
            GridRect(x: 6, y: 6, width: 6, height: 6),
        ])
        XCTAssertTrue(SpatialLayout.isValid(proposal))
    }

    func testEvenColumnsAndRowsUseTheCurrentVisualOrder() throws {
        let topRight = UUID()
        let bottom = UUID()
        let topLeft = UUID()
        let slots = [
            SpatialSlot(id: topRight, rect: GridRect(x: 6, y: 0, width: 6, height: 6)),
            SpatialSlot(id: bottom, rect: GridRect(x: 0, y: 6, width: 12, height: 6)),
            SpatialSlot(id: topLeft, rect: GridRect(x: 0, y: 0, width: 6, height: 6)),
        ]

        let columns = PaneArrangement.transaction(
            slots,
            mainSlotID: topRight,
            preset: .evenColumns
        )
        let rows = PaneArrangement.transaction(
            slots,
            mainSlotID: topRight,
            preset: .evenRows
        )

        XCTAssertTrue(columns.isValid)
        XCTAssertEqual(columns.proposal.map(\.id), [topLeft, topRight, bottom])
        XCTAssertEqual(columns.proposal.map(\.rect), [
            GridRect(x: 0, y: 0, width: 4, height: 12),
            GridRect(x: 4, y: 0, width: 4, height: 12),
            GridRect(x: 8, y: 0, width: 4, height: 12),
        ])
        XCTAssertTrue(rows.isValid)
        XCTAssertEqual(rows.proposal.map(\.rect), [
            GridRect(x: 0, y: 0, width: 12, height: 4),
            GridRect(x: 0, y: 4, width: 12, height: 4),
            GridRect(x: 0, y: 8, width: 12, height: 4),
        ])
    }

    func testMainPresetsGiveTheFocusedPaneTwoThirds() throws {
        let main = UUID()
        let otherA = UUID()
        let otherB = UUID()
        let expectations: [(PaneArrangementPreset, [GridRect])] = [
            (.mainLeft, [
                GridRect(x: 0, y: 0, width: 8, height: 12),
                GridRect(x: 8, y: 0, width: 4, height: 6),
                GridRect(x: 8, y: 6, width: 4, height: 6),
            ]),
            (.mainRight, [
                GridRect(x: 4, y: 0, width: 8, height: 12),
                GridRect(x: 0, y: 0, width: 4, height: 6),
                GridRect(x: 0, y: 6, width: 4, height: 6),
            ]),
            (.mainTop, [
                GridRect(x: 0, y: 0, width: 12, height: 8),
                GridRect(x: 0, y: 8, width: 6, height: 4),
                GridRect(x: 6, y: 8, width: 6, height: 4),
            ]),
            (.mainBottom, [
                GridRect(x: 0, y: 4, width: 12, height: 8),
                GridRect(x: 0, y: 0, width: 6, height: 4),
                GridRect(x: 6, y: 0, width: 6, height: 4),
            ]),
        ]

        for (preset, rects) in expectations {
            let arranged = try proposal(
                ids: [otherA, main, otherB],
                preset: preset,
                mainSlotID: main
            )
            XCTAssertEqual(arranged.map(\.id), [main, otherA, otherB], "\(preset)")
            XCTAssertEqual(arranged.map(\.rect), rects, "\(preset)")
            XCTAssertTrue(SpatialLayout.isValid(arranged), "\(preset)")
        }
    }

    func testPresetsDisappearWhenThePaneCountCannotMeetMinimumSize() {
        let five = slots(count: 5)
        XCTAssertEqual(
            PaneArrangement.availablePresets(for: five, mainSlotID: five[0].id),
            [.tiled, .mainLeft, .mainRight, .mainTop, .mainBottom]
        )

        let six = slots(count: 6)
        XCTAssertEqual(
            PaneArrangement.availablePresets(for: six, mainSlotID: six[0].id),
            [.tiled]
        )

        let sixteen = slots(count: 16)
        XCTAssertEqual(
            PaneArrangement.availablePresets(for: sixteen, mainSlotID: sixteen[0].id),
            [.tiled]
        )
    }

    func testStoreCommitsOneAtomicResizeWithoutChangingFocusOrContent() throws {
        let store = WorkspaceStore()
        let first = try XCTUnwrap(store.catalog.activeSlotID)
        store.splitActiveSlot(.horizontal, content: .changes)
        let focused = try XCTUnwrap(store.catalog.activeSlotID)
        store.splitActiveSlot(.vertical, content: .automation)
        let last = try XCTUnwrap(store.catalog.activeSlotID)
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published.append(contentsOf: events) }

        store.arrangeActiveTab(.mainLeft)

        XCTAssertEqual(store.catalog.activeSlotID, last)
        XCTAssertEqual(store.catalog.slot(id: first)?.content, .terminal)
        XCTAssertEqual(store.catalog.slot(id: focused)?.content, .changes)
        XCTAssertEqual(store.catalog.slot(id: last)?.content, .automation)
        XCTAssertEqual(store.catalog.slot(id: last)?.rect, GridRect(
            x: 0, y: 0, width: 8, height: 12
        ))
        XCTAssertEqual(published.count, 1)
        guard case .slotsResized(let ids, let detached, _, _) = published[0] else {
            return XCTFail("arrangement must publish the existing resize fact")
        }
        XCTAssertEqual(Set(ids), Set([first, focused, last]))
        XCTAssertFalse(detached)
    }

    private func proposal(
        ids: [UUID],
        preset: PaneArrangementPreset,
        mainSlotID: UUID
    ) throws -> [SpatialSlot] {
        let transaction = PaneArrangement.transaction(
            slots(ids: ids),
            mainSlotID: mainSlotID,
            preset: preset
        )
        XCTAssertTrue(transaction.isValid)
        return transaction.proposal
    }

    private func slots(ids: [UUID]) -> [SpatialSlot] {
        let divisions = min(ids.count, 4)
        return ids.enumerated().map { index, id in
            SpatialSlot(
                id: id,
                rect: GridRect(
                    x: (index % divisions) * 3,
                    y: (index / divisions) * 3,
                    width: 3,
                    height: 3
                )
            )
        }
    }

    private func slots(count: Int) -> [SpatialSlot] {
        let divisions = min(count, 4)
        return (0..<count).map { index in
            SpatialSlot(
                id: UUID(),
                rect: GridRect(
                    x: (index % divisions) * 3,
                    y: (index / divisions) * 3,
                    width: 3,
                    height: 3
                )
            )
        }
    }
}
