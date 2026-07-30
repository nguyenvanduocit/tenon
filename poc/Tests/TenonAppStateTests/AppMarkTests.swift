import XCTest
@testable import TenonApp

/// SwiftPM does not run `actool`, so a named asset-catalog lookup returns nothing under
/// `swift build` and the title bar would draw a blank gap where the app's identity goes.
/// This runs in the SwiftPM build, which is the build that used to fail.
final class AppMarkTests: XCTestCase {
    func testTheAppMarkResolvesUnderTheSwiftPMBuild() throws {
        let mark = try XCTUnwrap(
            AppMark.image,
            "The title bar falls back to an SF Symbol when this is nil — the mark itself is missing."
        )

        XCTAssertGreaterThan(mark.size.width, 0)
        XCTAssertGreaterThan(mark.size.height, 0)
    }

    /// The named lookup is the packaged `.app`'s path, not this one — asserting it is
    /// empty here is what keeps the vector branch from quietly becoming dead code.
    func testTheNamedCatalogLookupIsTheOtherBuildsPath() {
        XCTAssertNil(
            NSImage(named: "TenonMark"),
            "SwiftPM compiled an asset catalog — the hand-rolled vector branch can go."
        )
    }
}
