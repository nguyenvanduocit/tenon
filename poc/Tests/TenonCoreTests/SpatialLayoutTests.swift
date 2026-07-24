import XCTest
@testable import TenonCore

final class SpatialLayoutTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    func testValidationAcceptsAFullGridSlot() {
        let slots = [slot(a, 0, 0, 12, 12)]

        XCTAssertTrue(SpatialLayout.isValid(slots))
    }

    func testValidationRejectsOutOfBoundsUndersizedAndOverlappingSlots() {
        XCTAssertFalse(SpatialLayout.isValid([slot(a, 10, 0, 3, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([slot(a, 0, 0, 2, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([
            slot(a, 0, 0, 6, 6),
            slot(b, 3, 3, 6, 6),
        ]))
    }

    func testValidationRejectsDuplicateSlotIdentities() {
        XCTAssertFalse(SpatialLayout.isValid([
            slot(a, 0, 0, 3, 3),
            slot(a, 9, 9, 3, 3),
        ]))
    }

    func testValidationRejectsOverflowingCoordinatesAndSizesWithoutTrapping() {
        XCTAssertFalse(SpatialLayout.isValid([slot(a, Int.max, 0, 3, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([slot(a, 1, 0, Int.max, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([slot(a, 0, Int.max, 3, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([slot(a, 0, 1, 3, Int.max)]))
        XCTAssertFalse(SpatialLayout.isValid([slot(a, Int.min, Int.min, 3, 3)]))
        XCTAssertFalse(SpatialLayout.isValid([
            slot(a, 0, 0, 3, 3),
            slot(b, Int.max, 0, 3, 3),
        ]))
    }

    func testBestEmptyRectReturnsTheWholeGridWhenTheTabIsEmpty() {
        XCTAssertEqual(
            SpatialLayout.bestEmptyRect(in: [], near: nil),
            GridRect(x: 0, y: 0, width: 12, height: 12)
        )
    }

    func testBestEmptyRectUsesTheLargestAvailableRegionFromTheStructuralPrototype() {
        let slots = [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 5),
        ]

        XCTAssertEqual(
            SpatialLayout.bestEmptyRect(in: slots, near: a),
            GridRect(x: 7, y: 5, width: 5, height: 7)
        )
    }

    func testBestEmptyRectUsesActiveDistanceBeforeTopLeftOrder() {
        let leftBarrier = slot(a, 3, 0, 3, 12)
        let rightBarrier = slot(b, 6, 0, 3, 12)

        XCTAssertEqual(
            SpatialLayout.bestEmptyRect(in: [leftBarrier, rightBarrier], near: rightBarrier.id),
            GridRect(x: 9, y: 0, width: 3, height: 12)
        )
    }

    func testBestEmptyRectUsesShortSideBeforeTopLeftOrder() {
        let slots = [
            slot(a, 0, 8, 3, 4),
            slot(b, 3, 0, 5, 12),
            slot(c, 8, 6, 4, 6),
        ]

        XCTAssertEqual(
            SpatialLayout.bestEmptyRect(in: slots, near: nil),
            GridRect(x: 8, y: 0, width: 4, height: 6)
        )
    }

    func testBestEmptyRectUsesTopThenLeftForAnOtherwiseExactTie() {
        let slots = [
            slot(a, 3, 0, 3, 12),
            slot(b, 6, 0, 3, 12),
        ]

        XCTAssertEqual(
            SpatialLayout.bestEmptyRect(in: slots, near: nil),
            GridRect(x: 0, y: 0, width: 3, height: 12)
        )
    }

    func testHorizontalSplitUsesCeilingForTheOriginalAndRemainderForTheNewSlot() {
        let original = [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 12),
        ]

        let transaction = SpatialLayout.split(
            original,
            slotID: a,
            newSlotID: c,
            axis: .horizontal
        )

        XCTAssertEqual(transaction?.proposal, [
            slot(a, 0, 0, 4, 12),
            slot(b, 7, 0, 5, 12),
            slot(c, 4, 0, 3, 12),
        ])
        XCTAssertEqual(transaction?.kind, .split)
        XCTAssertEqual(transaction?.baseline, original)
        XCTAssertEqual(transaction?.affectedSlotIDs, [a, c])
        XCTAssertEqual(original[0].rect, GridRect(x: 0, y: 0, width: 7, height: 12))
    }

    func testVerticalSplitPlacesTheNewSlotBelowTheOriginal() {
        let transaction = SpatialLayout.split(
            [slot(a, 0, 0, 12, 7)],
            slotID: a,
            newSlotID: b,
            axis: .vertical
        )

        XCTAssertEqual(transaction?.proposal, [
            slot(a, 0, 0, 12, 4),
            slot(b, 0, 4, 12, 3),
        ])
    }

    func testSplitRejectsASlotThatCannotProvideBothMinimumSizes() {
        let original = [slot(a, 0, 0, 5, 12)]

        XCTAssertNil(SpatialLayout.split(
            original,
            slotID: a,
            newSlotID: b,
            axis: .horizontal
        ))
        XCTAssertEqual(original, [slot(a, 0, 0, 5, 12)])
    }

    func testCloseAbsorbsMultipleNeighborsThatExactlyTileTheVacancy() {
        let original = [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 5),
            slot(c, 7, 5, 5, 7),
        ]

        let transaction = SpatialLayout.close(original, slotID: a)

        XCTAssertEqual(transaction?.proposal, [
            slot(b, 0, 0, 12, 5),
            slot(c, 0, 5, 12, 7),
        ])
        XCTAssertEqual(transaction?.absorbedSlotIDs, [b, c])
        XCTAssertEqual(transaction?.direction, .right)
        XCTAssertEqual(original[0].rect, GridRect(x: 0, y: 0, width: 7, height: 12))
    }

    func testCloseAbsorptionPrefersLeftBeforeTop() {
        let original = [
            slot(a, 3, 3, 3, 3),
            slot(b, 0, 3, 3, 3),
            slot(c, 3, 0, 3, 3),
        ]

        let transaction = SpatialLayout.close(original, slotID: a)

        XCTAssertEqual(transaction?.direction, .left)
        XCTAssertEqual(transaction?.absorbedSlotIDs, [b])
        XCTAssertEqual(transaction?.proposal, [
            slot(b, 0, 3, 6, 3),
            slot(c, 3, 0, 3, 3),
        ])
    }

    func testCloseAbsorptionUsesTopThenRightThenBottomPriority() {
        XCTAssertEqual(SpatialLayout.close([
            slot(a, 3, 3, 3, 3),
            slot(b, 3, 0, 3, 3),
            slot(c, 6, 3, 3, 3),
            slot(d, 3, 6, 3, 3),
        ], slotID: a)?.direction, .top)

        XCTAssertEqual(SpatialLayout.close([
            slot(a, 3, 3, 3, 3),
            slot(c, 6, 3, 3, 3),
            slot(d, 3, 6, 3, 3),
        ], slotID: a)?.direction, .right)

        XCTAssertEqual(SpatialLayout.close([
            slot(a, 3, 3, 3, 3),
            slot(d, 3, 6, 3, 3),
        ], slotID: a)?.direction, .bottom)
    }

    func testCloseLeavesAHoleWhenNoEdgeIsExactlyTiled() {
        let transaction = SpatialLayout.close([
            slot(a, 0, 0, 6, 6),
            slot(b, 6, 0, 3, 3),
        ], slotID: a)

        XCTAssertEqual(transaction?.proposal, [slot(b, 6, 0, 3, 3)])
        XCTAssertEqual(transaction?.absorbedSlotIDs, [])
        XCTAssertNil(transaction?.direction)
    }

    func testClosingTheLastSlotReturnsAValidEmptyLayout() {
        let transaction = SpatialLayout.close([slot(a, 0, 0, 12, 12)], slotID: a)

        XCTAssertEqual(transaction?.proposal, [])
        XCTAssertEqual(transaction?.absorbedSlotIDs, [])
        XCTAssertNil(transaction?.direction)
        XCTAssertTrue(SpatialLayout.isValid(transaction?.proposal ?? []))
    }

    func testResizeMovesAFullSharedEdgeAndAllTiledNeighbors() {
        let original = [
            slot(a, 0, 0, 6, 12),
            slot(b, 6, 0, 6, 5),
            slot(c, 6, 5, 6, 7),
        ]

        let transaction = SpatialLayout.resize(
            original,
            slotID: a,
            direction: .east,
            deltaColumns: 2,
            deltaRows: 0
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertFalse(transaction.isDetached)
        XCTAssertEqual(transaction.baseline, original)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 0, 0, 8, 12),
            slot(b, 8, 0, 4, 5),
            slot(c, 8, 5, 4, 7),
        ])
        XCTAssertEqual(transaction.affectedSlotIDs, [a, b, c])
        XCTAssertEqual(original[0].rect, GridRect(x: 0, y: 0, width: 6, height: 12))
    }

    func testCornerResizeCouplesNeighborsOnBothEdges() {
        let transaction = SpatialLayout.resize(
            [
                slot(a, 0, 0, 6, 6),
                slot(b, 6, 0, 6, 6),
                slot(c, 0, 6, 6, 6),
            ],
            slotID: a,
            direction: .southEast,
            deltaColumns: 2,
            deltaRows: 2
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertFalse(transaction.isDetached)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 0, 0, 8, 8),
            slot(b, 8, 0, 4, 6),
            slot(c, 0, 8, 6, 4),
        ])
        XCTAssertEqual(transaction.affectedSlotIDs, [a, b, c])
    }

    func testResizeDetachesWhenCoupledNeighborsWouldOverlapButActiveOnlyIsValid() {
        let original = [
            slot(a, 0, 0, 6, 6),
            slot(b, 6, 0, 6, 6),
            slot(c, 0, 6, 6, 6),
        ]

        let transaction = SpatialLayout.resize(
            original,
            slotID: a,
            direction: .southEast,
            deltaColumns: -3,
            deltaRows: -3
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertTrue(transaction.isDetached)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 0, 0, 3, 3),
            slot(b, 6, 0, 6, 6),
            slot(c, 0, 6, 6, 6),
        ])
        XCTAssertEqual(transaction.affectedSlotIDs, [a])
    }

    func testWestResizeFromTheStructuralPrototypeDetachesWhenNeighborWouldOverlap() {
        let original = [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 5),
            slot(c, 7, 5, 5, 7),
        ]

        let transaction = SpatialLayout.resize(
            original,
            slotID: b,
            direction: .west,
            deltaColumns: 2,
            deltaRows: 0
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertTrue(transaction.isDetached)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 0, 0, 7, 12),
            slot(b, 9, 0, 3, 5),
            slot(c, 7, 5, 5, 7),
        ])
        XCTAssertEqual(transaction.affectedSlotIDs, [b])
        XCTAssertEqual(original, [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 5),
            slot(c, 7, 5, 5, 7),
        ])
    }

    func testResizeIsInvalidWhenCoupledAndDetachedProposalsBothFail() {
        let transaction = SpatialLayout.resize(
            [
                slot(a, 0, 0, 6, 12),
                slot(b, 6, 0, 3, 12),
            ],
            slotID: a,
            direction: .east,
            deltaColumns: 2,
            deltaRows: 0
        )

        XCTAssertFalse(transaction.isValid)
        XCTAssertFalse(transaction.isDetached)
        XCTAssertEqual(transaction.proposal[0].rect, GridRect(x: 0, y: 0, width: 8, height: 12))
        XCTAssertEqual(transaction.affectedSlotIDs, [a])
    }

    func testResizeClampsAtMinimumSizeAndGridBounds() {
        let transaction = SpatialLayout.resize(
            [
                slot(a, 0, 0, 6, 12),
                slot(b, 6, 0, 6, 12),
            ],
            slotID: a,
            direction: .east,
            deltaColumns: -99,
            deltaRows: 0
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 0, 0, 3, 12),
            slot(b, 3, 0, 9, 12),
        ])
    }

    func testResizeClampsExtremeDeltasBeforeAllFourEdgeCalculations() {
        let original = [slot(a, 3, 3, 6, 6)]

        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .west,
                deltaColumns: Int.min,
                deltaRows: 0
            ).proposal,
            [slot(a, 0, 3, 9, 6)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .west,
                deltaColumns: Int.max,
                deltaRows: 0
            ).proposal,
            [slot(a, 6, 3, 3, 6)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .east,
                deltaColumns: Int.max,
                deltaRows: 0
            ).proposal,
            [slot(a, 3, 3, 9, 6)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .east,
                deltaColumns: Int.min,
                deltaRows: 0
            ).proposal,
            [slot(a, 3, 3, 3, 6)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .north,
                deltaColumns: 0,
                deltaRows: Int.min
            ).proposal,
            [slot(a, 3, 0, 6, 9)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .north,
                deltaColumns: 0,
                deltaRows: Int.max
            ).proposal,
            [slot(a, 3, 6, 6, 3)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .south,
                deltaColumns: 0,
                deltaRows: Int.max
            ).proposal,
            [slot(a, 3, 3, 6, 9)]
        )
        XCTAssertEqual(
            SpatialLayout.resize(
                original,
                slotID: a,
                direction: .south,
                deltaColumns: 0,
                deltaRows: Int.min
            ).proposal,
            [slot(a, 3, 3, 6, 3)]
        )
    }

    func testNorthAndSouthResizeSharedEdgesSymmetrically() {
        let slots = [
            slot(a, 0, 0, 12, 6),
            slot(b, 0, 6, 12, 6),
        ]

        let south = SpatialLayout.resize(
            slots,
            slotID: a,
            direction: .south,
            deltaColumns: 0,
            deltaRows: 2
        )
        XCTAssertEqual(south.proposal, [
            slot(a, 0, 0, 12, 8),
            slot(b, 0, 8, 12, 4),
        ])

        let north = SpatialLayout.resize(
            slots,
            slotID: b,
            direction: .north,
            deltaColumns: 0,
            deltaRows: -2
        )
        XCTAssertEqual(north.proposal, [
            slot(a, 0, 0, 12, 4),
            slot(b, 0, 4, 12, 8),
        ])
    }

    func testMoveSnapsToGridAndClampsInsideTheCanvas() {
        let original = [slot(a, 0, 0, 3, 3)]

        let transaction = SpatialLayout.move(
            original,
            slotID: a,
            toColumn: 99,
            row: 99
        )

        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(transaction.kind, .move)
        XCTAssertEqual(transaction.baseline, original)
        XCTAssertEqual(transaction.proposal, [slot(a, 9, 9, 3, 3)])
        XCTAssertEqual(transaction.affectedSlotIDs, [a])
        XCTAssertEqual(original, [slot(a, 0, 0, 3, 3)])
    }

    func testMoveReturnsAnInvalidCandidateWhenItWouldOverlap() {
        let transaction = SpatialLayout.move(
            [
                slot(a, 0, 0, 3, 3),
                slot(b, 3, 0, 3, 3),
            ],
            slotID: a,
            toColumn: 3,
            row: 0
        )

        XCTAssertFalse(transaction.isValid)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 3, 0, 3, 3),
            slot(b, 3, 0, 3, 3),
        ])
    }

    func testSwapExchangesGeometryWithoutChangingInputOrOrdering() {
        let original = [
            slot(a, 0, 0, 7, 12),
            slot(b, 7, 0, 5, 5),
            slot(c, 7, 5, 5, 7),
        ]

        let transaction = SpatialLayout.swap(original, firstSlotID: a, secondSlotID: b)

        XCTAssertTrue(transaction.isValid)
        XCTAssertEqual(transaction.kind, .swap)
        XCTAssertEqual(transaction.baseline, original)
        XCTAssertEqual(transaction.proposal, [
            slot(a, 7, 0, 5, 5),
            slot(b, 0, 0, 7, 12),
            slot(c, 7, 5, 5, 7),
        ])
        XCTAssertEqual(transaction.affectedSlotIDs, [a, b])
        XCTAssertEqual(original[0].rect, GridRect(x: 0, y: 0, width: 7, height: 12))
    }

    func testUnknownIdentitiesProduceNoTransactionOrInvalidTransaction() {
        let unknown = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let slots = [slot(a, 0, 0, 12, 12)]

        XCTAssertNil(SpatialLayout.split(slots, slotID: unknown, newSlotID: b, axis: .horizontal))
        XCTAssertNil(SpatialLayout.close(slots, slotID: unknown))
        XCTAssertFalse(SpatialLayout.move(slots, slotID: unknown, toColumn: 0, row: 0).isValid)
        XCTAssertFalse(SpatialLayout.swap(slots, firstSlotID: a, secondSlotID: unknown).isValid)
        XCTAssertFalse(SpatialLayout.resize(
            slots,
            slotID: unknown,
            direction: .east,
            deltaColumns: 1,
            deltaRows: 0
        ).isValid)
    }

    func testMutationsRejectDuplicateIdentityLayoutsWithoutChangingInput() {
        let duplicateIDs = [
            slot(a, 0, 0, 3, 3),
            slot(a, 9, 9, 3, 3),
            slot(b, 3, 0, 3, 3),
        ]

        XCTAssertNil(SpatialLayout.bestEmptyRect(in: duplicateIDs, near: a))
        XCTAssertNil(SpatialLayout.split(
            duplicateIDs,
            slotID: a,
            newSlotID: c,
            axis: .horizontal
        ))
        XCTAssertNil(SpatialLayout.close(duplicateIDs, slotID: a))

        let move = SpatialLayout.move(duplicateIDs, slotID: a, toColumn: 6, row: 6)
        XCTAssertFalse(move.isValid)
        XCTAssertEqual(move.proposal, duplicateIDs)
        XCTAssertEqual(move.affectedSlotIDs, [])

        let swap = SpatialLayout.swap(duplicateIDs, firstSlotID: a, secondSlotID: b)
        XCTAssertFalse(swap.isValid)
        XCTAssertEqual(swap.proposal, duplicateIDs)
        XCTAssertEqual(swap.affectedSlotIDs, [])

        let resize = SpatialLayout.resize(
            duplicateIDs,
            slotID: a,
            direction: .east,
            deltaColumns: 1,
            deltaRows: 0
        )
        XCTAssertFalse(resize.isValid)
        XCTAssertEqual(resize.proposal, duplicateIDs)
        XCTAssertEqual(resize.affectedSlotIDs, [])
    }

    func testMutationsRejectOverflowingLayoutsWithoutChangingInput() {
        let overflowing = [
            slot(a, Int.max, 0, 3, 3),
            slot(b, 0, 0, 3, 3),
        ]

        XCTAssertNil(SpatialLayout.bestEmptyRect(in: overflowing, near: a))
        XCTAssertNil(SpatialLayout.split(
            overflowing,
            slotID: a,
            newSlotID: c,
            axis: .horizontal
        ))
        XCTAssertNil(SpatialLayout.close(overflowing, slotID: a))

        let move = SpatialLayout.move(overflowing, slotID: a, toColumn: 0, row: 0)
        XCTAssertFalse(move.isValid)
        XCTAssertEqual(move.proposal, overflowing)
        XCTAssertEqual(move.affectedSlotIDs, [])

        let swap = SpatialLayout.swap(overflowing, firstSlotID: a, secondSlotID: b)
        XCTAssertFalse(swap.isValid)
        XCTAssertEqual(swap.proposal, overflowing)
        XCTAssertEqual(swap.affectedSlotIDs, [])

        let resize = SpatialLayout.resize(
            overflowing,
            slotID: a,
            direction: .east,
            deltaColumns: 1,
            deltaRows: 0
        )
        XCTAssertFalse(resize.isValid)
        XCTAssertEqual(resize.proposal, overflowing)
        XCTAssertEqual(resize.affectedSlotIDs, [])
    }

    private func slot(
        _ id: UUID,
        _ x: Int,
        _ y: Int,
        _ width: Int,
        _ height: Int
    ) -> SpatialSlot {
        SpatialSlot(id: id, rect: GridRect(
            x: x,
            y: y,
            width: width,
            height: height
        ))
    }
}
