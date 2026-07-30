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

    func testARapidPairOnAResizeEdgeOrTheBodyKeepsItsOwnGesture() {
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .resize(.east), clickCount: 2),
            .begin(.resize(.east))
        )
        XCTAssertEqual(
            SpatialCanvasInteractionCoordinator.press(region: .body, clickCount: 2),
            .begin(.body)
        )
    }
}
