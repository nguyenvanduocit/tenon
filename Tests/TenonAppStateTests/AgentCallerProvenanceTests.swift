import Darwin
import Foundation
@testable import TenonApp
@testable import TenonCore
import XCTest

/// The kernel half of the agent principal: who is calling, and whose child are they.
///
/// Checked against this very process, because that is the one process whose real answers the
/// test already knows independently — `getpid()` and `getppid()` are the oracle.
final class AgentCallerProvenanceTests: XCTestCase {
    func testTheParentOfThisProcessIsTheOneTheKernelAlreadyAgreesOn() {
        XCTAssertEqual(
            AgentCallerProvenance.parentProcessID(of: getpid()),
            getppid(),
            "the ancestry walk disagreed with getppid() about this very process"
        )
    }

    /// A pid that names no process must answer `nil` rather than a zeroed struct's pid 0.
    /// This is the `didFill` rule, and getting it wrong hands a dead caller an ancestry.
    func testAProcessThatDoesNotExistHasNoParent() {
        // Well above `kern.maxproc` on any Darwin machine, so it names nothing live.
        XCTAssertNil(AgentCallerProvenance.parentProcessID(of: 0x7FFF_FFF0))
    }

    /// The composed walk, against the same oracle: this process, then its parent.
    func testTheWalkStartsAtThisProcessAndReachesItsParent() {
        let chain = AgentCallerAdmission.ancestry(
            of: getpid(),
            parent: AgentCallerProvenance.parentProcessID(of:)
        )
        XCTAssertEqual(chain.first, getpid())
        XCTAssertEqual(chain.dropFirst().first, getppid())
        XCTAssertLessThanOrEqual(chain.count, AgentCallerAdmission.maximumAncestryDepth)
        XCTAssertFalse(chain.contains(1), "the walk reported launchd as an ancestor")
    }

    /// `LOCAL_PEERPID` names the process on the other end of a real connected socket.
    ///
    /// A socketpair is both ends in this process, so the answer is one this test knows:
    /// asking either end who its peer is must name this process. That is exactly the read
    /// the server performs at accept, on a descriptor no client has written to yet.
    func testThePeerOfAConnectedSocketIsTheProcessHoldingIt() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair),
            0,
            "socketpair failed, errno \(errno)"
        )
        defer {
            close(pair[0])
            close(pair[1])
        }
        XCTAssertEqual(AgentCallerProvenance.peerProcessID(of: pair[0]), getpid())
        XCTAssertEqual(AgentCallerProvenance.peerProcessID(of: pair[1]), getpid())
    }

    /// A descriptor that is not a connected local socket proves nothing, and must say so
    /// rather than returning the zero the option left in place.
    func testANonSocketDescriptorNamesNoPeer() {
        XCTAssertNil(AgentCallerProvenance.peerProcessID(of: STDERR_FILENO))
    }
}
