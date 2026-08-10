import XCTest

@testable import TenonCore

/// What a memory number in this app means, and how it is written down.
///
/// Both claims here exist because a supervision surface is read *beside* Activity Monitor, and
/// a figure that disagrees with the operating system's own is a figure the operator has to
/// reconcile by hand before trusting anything else on the panel. Two separate things made
/// Tenon's number disagree: it measured resident size where macOS reports footprint, and it
/// wrote binary units where macOS writes decimal ones.
final class TelemetryMemoryFigureTests: XCTestCase {
    /// The units macOS itself uses everywhere a person can check: Activity Monitor, Finder,
    /// About This Mac. 305.1 MB is what Activity Monitor prints for 305,100,000 bytes.
    func testBytesAreWrittenInTheUnitsMacOSPrints() {
        XCTAssertEqual(TelemetryFormat.bytes(.known(305_100_000)), "305.1 MB")
        XCTAssertEqual(TelemetryFormat.bytes(.known(1_000_000)), "1.0 MB")
        XCTAssertEqual(TelemetryFormat.bytes(.known(2_500_000_000)), "2.5 GB")
    }

    /// Small values stay in bytes rather than rounding to a meaningless "0.0 kB".
    func testSmallValuesStayInBytes() {
        XCTAssertEqual(TelemetryFormat.bytes(.known(0)), "0 B")
        XCTAssertEqual(TelemetryFormat.bytes(.known(999)), "999 B")
        XCTAssertEqual(TelemetryFormat.bytes(.known(1_000)), "1.0 kB")
    }

    /// An unavailable figure is still never a number.
    func testAnUnavailableFigureStaysAnEmDash() {
        XCTAssertEqual(TelemetryFormat.bytes(.unavailable(.unreadable)), TelemetryFormat.missing)
    }
}
