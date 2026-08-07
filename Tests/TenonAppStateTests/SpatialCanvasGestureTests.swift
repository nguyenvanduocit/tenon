import TenonCore
import XCTest
@testable import TenonApp

/// The click-count half of the canvas gesture rules. Geometry lives in `SpatialLayout`
/// and is asserted in `TenonCoreTests`; what a press *means* is asserted here, without
/// a window.
final class SpatialCanvasGestureTests: XCTestCase {
    func testASecondClickOnAPaneHeaderFillsItsWidthInsteadOfMovingItAgain() {
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .header, clickCount: 1),
            .begin(.header)
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .header, clickCount: 2),
            .fillWidth
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .header, clickCount: 3),
            .fillWidth
        )
    }

    func testARightClickOnABorderOffersTheSizesThatBorderDragsTo() {
        for direction in [
            ResizeDirection.north,
            .east,
            .south,
            .west,
            .northEast,
            .northWest,
            .southEast,
            .southWest,
        ] {
            XCTAssertEqual(
                SpatialCanvasInteractionCoordinator.menu(for: .resize(direction)),
                .resize(direction),
                "the \(direction) border must resize the edge it was clicked on"
            )
        }
    }

    func testARightClickOnTheHeaderOffersThePaneMenuAndTheBodyOffersNone() {
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.menu(for: .header),
            .pane
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.menu(for: .body),
            .surface
        )
    }

    func testASecondClickOnABorderStepsThroughThatBordersSizes() {
        for direction in [
            ResizeDirection.north,
            .east,
            .south,
            .west,
            .northEast,
            .northWest,
            .southEast,
            .southWest,
        ] {
            XCTAssertEqual(
                SpatialCanvasInteractionCoordinator.press(
                    region: .resize(direction),
                    clickCount: 1
                ),
                .begin(.resize(direction)),
                "one click on the \(direction) border still starts its drag"
            )
            XCTAssertEqual(
                SpatialCanvasInteractionCoordinator.press(
                    region: .resize(direction),
                    clickCount: 2
                ),
                .cycleExtent(direction),
                "a second click steps the \(direction) border to its next size"
            )
        }
    }

    func testARapidPairOnThePaneBodyKeepsItsOwnGesture() {
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .body, clickCount: 2),
            .begin(.body)
        )
    }
}
