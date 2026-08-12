import Foundation
@testable import TenonCore
import XCTest

/// The rule that decides whether a control-socket caller is an agent.
///
/// Asserted without a window, per `CLAUDE.md`'s fitness test: the whole rule is a function
/// of the caller's process ancestry and what the host already knows about its panes.
final class AgentCallerAdmissionTests: XCTestCase {
    private let paneA = UUID()
    private let paneB = UUID()

    private func candidate(_ slotID: UUID, agent: Int32?) -> AgentPaneCandidate {
        AgentPaneCandidate(slotID: slotID, agentPID: agent)
    }

    /// The one case that mints, and the exact shape measured on this machine: a tool
    /// subprocess whose parent is the `claude` process the host resolved into a pane.
    func testACallFromInsideAnAgentSubtreeResolvesToThatPane() {
        XCTAssertEqual(
            AgentCallerAdmission.admit(
                peerAncestry: [73_696, 18_432, 18_347, 18_343],
                candidates: [
                    candidate(paneA, agent: 25_461),
                    candidate(paneB, agent: 18_432),
                ]
            ),
            paneB
        )
    }

    /// The agent need not be the immediate parent. A tool command that runs through a
    /// wrapper script is still the agent's call.
    func testAnAgentFurtherUpTheChainStillResolves() {
        XCTAssertEqual(
            AgentCallerAdmission.admit(
                peerAncestry: [900, 800, 700, 18_432],
                candidates: [candidate(paneA, agent: 18_432)]
            ),
            paneA
        )
    }

    /// A human typing at a pane's shell prompt is a child of the *shell*, not of the agent.
    /// This is the distinction the whole task exists to draw, so it gets its own assertion:
    /// provenance inside a pane is not, by itself, agency.
    func testAHumanAtTheShellPromptInAnAgentPaneStaysCLI() {
        // The pane runs an agent (18432), but this caller descends from the pane's shell
        // (18347) without passing through the agent.
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [91_000, 18_347, 18_343],
                candidates: [candidate(paneA, agent: 18_432)]
            )
        )
    }

    /// A daemon, a launchd job, or a process whose parent already exited has been reparented
    /// to `launchd` and can prove nothing. `pid <= 1` must never name a pane, including the
    /// pid 0 a zeroed struct reads as.
    func testAChainThatReachesLaunchdIsRefused() {
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [55_000, 1],
                candidates: [candidate(paneA, agent: 1), candidate(paneB, agent: 0)]
            ),
            "an orphaned caller named a pane through launchd"
        )
    }

    /// An empty walk — the peer exited before its ancestry could be read — keeps the
    /// identity the caller has today.
    func testAnEmptyAncestryIsRefused() {
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [],
                candidates: [candidate(paneA, agent: 18_432)]
            )
        )
    }

    /// Provenance alone is not enough, from the other side: a pane the host resolved no
    /// agent into never matches, however the caller is related to it.
    func testAPaneWithNoAgentInItIsRefused() {
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [73_696, 18_432],
                candidates: [candidate(paneA, agent: nil)]
            )
        )
    }

    /// A caller outside every agent subtree keeps the identity it has today.
    func testAnAncestryThatMatchesNoPaneIsRefused() {
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [999, 998],
                candidates: [candidate(paneA, agent: 18_432)]
            )
        )
    }

    /// Two panes claiming one agent process is a state the host should never reach. If it
    /// ever does, picking either attributes a call to a pane at random — so neither is
    /// picked.
    func testAnAmbiguousMatchIsRefusedRatherThanGuessed() {
        XCTAssertNil(
            AgentCallerAdmission.admit(
                peerAncestry: [73_696, 18_432],
                candidates: [
                    candidate(paneA, agent: 18_432),
                    candidate(paneB, agent: 18_432),
                ]
            )
        )
    }

    // MARK: - The walk that feeds the rule  @domain: process-telemetry

    /// The measured shape: a tool subprocess, its agent, the pane's shell, `login`.
    func testTheWalkReportsTheCallerFirstThenEachParentOutward() {
        let tree: [Int32: Int32] = [73_696: 18_432, 18_432: 18_347, 18_347: 18_343]
        XCTAssertEqual(
            AgentCallerAdmission.ancestry(of: 73_696) { tree[$0] },
            [73_696, 18_432, 18_347, 18_343]
        )
    }

    /// The walk is bounded, because invariant 10 admits no unbounded loop on a request path.
    func testTheWalkStopsAtItsBound() {
        // Every process is its own grandparent's child in an infinite ascending chain.
        let chain = AgentCallerAdmission.ancestry(of: 1000, limit: 4) { $0 + 1 }
        XCTAssertEqual(chain, [1000, 1001, 1002, 1003])
    }

    /// A pid whose parent lookup fails — the process exited mid-walk — ends the chain with
    /// what was actually read, rather than inventing the rest of it.
    func testTheWalkEndsWhereTheProcessTreeDoes() {
        XCTAssertEqual(
            AgentCallerAdmission.ancestry(of: 500) { $0 == 500 ? 400 : nil },
            [500, 400]
        )
    }

    /// Pid reuse can make a chain appear to loop. The walk must terminate on it rather than
    /// spinning to its bound, and must never report the same pid twice.
    func testTheWalkTerminatesOnAReusedPID() {
        let tree: [Int32: Int32] = [10: 20, 20: 30, 30: 10]
        XCTAssertEqual(
            AgentCallerAdmission.ancestry(of: 10, limit: 64) { tree[$0] },
            [10, 20, 30]
        )
    }

    /// `launchd` and the zero a cleared struct reads as are not processes the walk reports.
    func testTheWalkNeverReportsLaunchdOrZero() {
        XCTAssertEqual(AgentCallerAdmission.ancestry(of: 1) { _ in nil }, [])
        XCTAssertEqual(AgentCallerAdmission.ancestry(of: 0) { _ in nil }, [])
        XCTAssertEqual(
            AgentCallerAdmission.ancestry(of: 44) { $0 == 44 ? 1 : nil },
            [44]
        )
    }

    /// Nearest-first is the meaningful order. An agent running inside another agent's
    /// subtree owns its own calls; the outer one does not inherit them.
    func testTheNearestAgentInTheChainWins() {
        XCTAssertEqual(
            AgentCallerAdmission.admit(
                peerAncestry: [500, 400, 300],
                candidates: [
                    candidate(paneA, agent: 300),
                    candidate(paneB, agent: 400),
                ]
            ),
            paneB
        )
    }

    // MARK: - Occupancy: turning what the host sees into a candidate

    private func occupancy(
        declared: UInt64?,
        foreground: UInt64?,
        group: UInt64?
    ) -> AgentPaneOccupancy {
        AgentPaneOccupancy(
            slotID: paneA,
            declaredProcessGroupID: declared,
            observedForegroundPID: foreground,
            observedProcessGroupID: group
        )
    }

    /// The measured shape: `claude` leads its own process group, so the hook's declared
    /// group and the host's reading of its PTY name the same number.
    func testAnAgreedProcessGroupYieldsTheHostsOwnForegroundPID() {
        XCTAssertEqual(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: 18_432, foreground: 18_432, group: 18_432)
            ),
            AgentPaneCandidate(slotID: paneA, agentPID: 18_432)
        )
    }

    /// The agent need not lead the group it runs in. What identity is matched on is the
    /// host's own foreground read either way, never the declared group.
    func testTheCandidatePIDIsTheObservedForegroundNotTheDeclaredGroup() {
        XCTAssertEqual(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: 900, foreground: 950, group: 900)
            ),
            AgentPaneCandidate(slotID: paneA, agentPID: 950)
        )
    }

    /// The guard that carries ordinary use: the agent exited, its binding outlived it, and
    /// the human got their shell prompt back. The host now reads a different group than the
    /// hook declared, so the pane identifies nobody and the caller stays `.cli`.
    func testADeadAgentsBindingCannotIdentifyThePanesNewForegroundProcess() {
        XCTAssertNil(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: 18_432, foreground: 40_100, group: 40_100)
            )
        )
    }

    /// A binding with no declared group was written by no hook of ours — the ingress
    /// refuses a non-positive group before an event exists — so there is nothing to
    /// cross-check and it is refused rather than trusted.
    func testAnUndeclaredProcessGroupIdentifiesNothing() {
        XCTAssertNil(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: nil, foreground: 18_432, group: 18_432)
            )
        )
    }

    /// A pane whose surface never materialised, or whose process is gone, has no foreground
    /// process for a caller to descend from.
    func testAPaneWithNoObservedForegroundIdentifiesNothing() {
        XCTAssertNil(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: 18_432, foreground: nil, group: nil)
            )
        )
        XCTAssertNil(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: 1, foreground: 1, group: 1)
            )
        )
    }

    /// Ancestry is `Int32` because `proc_bsdinfo` answers in it. A foreground pid that does
    /// not survive the conversion is refused rather than truncated into another process.
    func testAForegroundPIDThatNoInt32CanHoldIsRefused() {
        let tooLarge = UInt64(Int32.max) + 1
        XCTAssertNil(
            AgentCallerAdmission.candidate(
                for: occupancy(declared: tooLarge, foreground: tooLarge, group: tooLarge)
            )
        )
    }
}
