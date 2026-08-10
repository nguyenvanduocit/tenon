import Darwin
import Foundation
import TenonCore
import XCTest

@testable import TenonApp

/// Which memory number the native sampler actually reads.
///
/// This is the claim a pure test cannot make: it is about which kernel field the shell layer
/// asks for. Reading resident size makes Tenon disagree with Activity Monitor by a factor that
/// grows with memory pressure — 133.6 MiB against 291.0 MiB was measured on this app — because
/// compression and swap shrink RSS while footprint keeps counting what the process is
/// responsible for. That gap is not cosmetic: the T-091 incident's 11 GB was invisible in RSS,
/// which is exactly why the health journal beside this monitor records footprint.
final class SamplerMemoryFigureTests: XCTestCase {
    /// The sampler's own figure tracks `ri_phys_footprint`, not `pti_resident_size`.
    ///
    /// The two are read a moment apart in a live process, so this asserts proximity rather than
    /// equality — but the tolerance is far tighter than the gap between the two fields, so
    /// reading the wrong one cannot pass.
    func testTheReportedFigureIsPhysicalFootprint() async throws {
        let samples = try await DarwinProcessSampler().sample(panes: [])
        let reported = try XCTUnwrap(samples.hostRecord?.footprintBytes)

        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        XCTAssertEqual(rc, 0, "the test process can always read itself")
        let footprint = usage.ri_phys_footprint
        let resident = usage.ri_resident_size

        let drift = abs(Double(reported) - Double(footprint)) / Double(footprint)
        XCTAssertLessThan(
            drift, 0.20,
            "reported \(reported) should track footprint \(footprint), not resident \(resident)"
        )
    }
}
