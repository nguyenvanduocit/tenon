import AppKit
import Foundation
import TenonCore
import XCTest
@testable import TenonApp

/// T-178 (`WS-FR-036`): the rules behind the line under a workspace's name and the list its
/// hover opens. Every one of them is a value-level join over a workspace, the agent roster,
/// the title registry and the one attention machine — so which panes are named, what each is
/// called, and what each is doing are all settled here, without a window.
final class WorkspaceAgentTaglineTests: XCTestCase {
    /// What a pane is, before it is given somewhere to sit. Geometry is the tab's problem —
    /// `SpatialLayout.isValid` refuses overlapping slots, and none of these rules is about
    /// where a pane sits.
    private struct Pane {
        let id: UUID
        var content: SlotContent = .terminal
        var customTitle: String?
    }

    private func slot(
        _ id: UUID,
        content: SlotContent = .terminal,
        customTitle: String? = nil
    ) -> Pane {
        Pane(id: id, content: content, customTitle: customTitle)
    }

    /// Tiles each tab's panes across the 12×12 grid in 3×3 cells, four to a row, which is the
    /// densest arrangement the layout rule accepts and more panes than any of these tests need.
    private func workspace(tabs paneGroups: [[Pane]]) -> Workspace {
        let tabs = paneGroups.enumerated().map { tabIndex, panes in
            let slots = panes.enumerated().map { index, pane in
                WorkspaceSlot(
                    id: pane.id,
                    rect: GridRect(
                        x: (index % 4) * 3,
                        y: (index / 4) * 3,
                        width: 3,
                        height: 3
                    ),
                    content: pane.content,
                    customTitle: pane.customTitle
                )
            }
            return Tab(slots: slots, activeSlotID: slots.first?.id, number: tabIndex + 1)
        }
        return Workspace(
            name: "tenon",
            path: URL(fileURLWithPath: "/tmp/tenon", isDirectory: true),
            tabs: tabs,
            activeTabID: tabs[0].id
        )
    }

    /// Drives the real machine to the state it is asked for, rather than constructing one.
    /// There is no other way in, and a fixture that faked a state would stop proving that the
    /// line reads the machine at all. Two stable samples, so "the screen stopped changing"
    /// stays an event instead of being true on the first observation.
    private func activity(_ state: PaneActivityState) -> PaneActivity {
        var machine = PaneActivity(
            stableSamples: 2,
            viewed: false,
            at: Date(timeIntervalSince1970: 0)
        )
        func observe(screen: Int, exited: Bool = false, finishes: Int = 0, at tick: Int) {
            _ = machine.observe(
                .init(screen: screen, processExited: exited, commandFinishedCount: finishes),
                at: Date(timeIntervalSince1970: TimeInterval(tick))
            )
        }
        switch state {
        case .working:
            // A screen that keeps changing never reaches the detector's stable streak.
            observe(screen: 1, at: 1)
            observe(screen: 2, at: 2)
        case .idle:
            observe(screen: 7, at: 1)
            observe(screen: 7, at: 2)
        case .finishedUnseen:
            observe(screen: 7, at: 1)
            observe(screen: 7, at: 2)
            observe(screen: 7, finishes: 1, at: 3)
        case .seen:
            observe(screen: 7, at: 1)
            observe(screen: 7, at: 2)
            observe(screen: 7, finishes: 1, at: 3)
            _ = machine.setViewed(true, at: Date(timeIntervalSince1970: 4))
        case .exited:
            observe(screen: 7, exited: true, at: 1)
        }
        XCTAssertEqual(machine.state, state, "fixture did not reach the state it claims")
        return machine
    }

    // MARK: - Which panes the line names

    func testOnlyPanesTheRosterHoldsAreNamed() {
        let agent = UUID()
        let plainShell = UUID()
        let space = workspace(tabs: [[slot(agent), slot(plainShell)]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [agent],
            titles: [agent: "Fixing the token refresh race", plainShell: "fish"],
            attention: [:]
        )

        XCTAssertEqual(entries.map(\.slotID), [agent])
        XCTAssertEqual(entries.map(\.title), ["Fixing the token refresh race"])
    }

    func testAPaneThatStoppedBeingATerminalIsNotNamedHoweverStaleTheRosterIs() {
        let moved = UUID()
        let space = workspace(tabs: [[slot(moved, content: .file(path: "/tmp/notes.md"))]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [moved],
            titles: [moved: "notes.md"],
            attention: [:]
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testEntriesFollowCatalogOrderAcrossTabsSoTheNamedPaneIsStable() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let space = workspace(tabs: [[slot(first), slot(second)], [slot(third)]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [third, first, second],
            titles: [:],
            attention: [:]
        )

        XCTAssertEqual(entries.map(\.slotID), [first, second, third])
    }

    // MARK: - What each pane is called

    func testAPinnedNameWinsOverTheTerminalsOwnTitle() {
        let pane = UUID()
        let space = workspace(tabs: [[slot(pane, customTitle: "Auditing the intent catalog")]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [pane],
            titles: [pane: "claude"],
            attention: [:]
        )

        XCTAssertEqual(entries.map(\.title), ["Auditing the intent catalog"])
    }

    func testAPaneThatHasSaidNothingStillReadsAsSomething() {
        let pane = UUID()
        let space = workspace(tabs: [[slot(pane)]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [pane],
            titles: [pane: "   "],
            attention: [:]
        )

        XCTAssertEqual(entries.map(\.title), [WorkspaceAgentTagline.unnamed])
    }

    // MARK: - What each pane's state is

    func testEveryStateIsCopiedFromTheAttentionMachineAndNoneIsRecomputed() {
        let states: [PaneActivityState] = [.working, .idle, .finishedUnseen, .seen, .exited]
        let ids = states.map { _ in UUID() }
        let space = workspace(tabs: [ids.map { slot($0) }])
        let attention = Dictionary(
            uniqueKeysWithValues: zip(ids, states).map { ($0, activity($1)) }
        )

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: Set(ids),
            titles: [:],
            attention: attention
        )

        XCTAssertEqual(entries.map(\.state), states)
    }

    func testAPaneWithNoMachineYetReadsAsWorkingBecauseThatIsHowItGotHere() {
        let pane = UUID()
        let space = workspace(tabs: [[slot(pane)]])

        let entries = WorkspaceAgentTagline.entries(
            in: space,
            agentPanes: [pane],
            titles: [:],
            attention: [:]
        )

        XCTAssertEqual(entries.map(\.state), [.working])
    }

    // MARK: - How a state is drawn

    func testOnlyTheStateWhereSomethingIsStillHappeningMoves() {
        XCTAssertEqual(WorkspaceAgentTagline.indicator(for: .working), .pulse)
        for settled in [PaneActivityState.idle, .finishedUnseen, .seen, .exited] {
            guard case .symbol = WorkspaceAgentTagline.indicator(for: settled) else {
                return XCTFail("\(settled) moves, and nothing is happening in it")
            }
        }
    }

    func testEveryDrawnStateNamesASymbolThisPlatformActuallyHas() {
        for state in [PaneActivityState.idle, .finishedUnseen, .seen, .exited] {
            guard case let .symbol(name) = WorkspaceAgentTagline.indicator(for: state) else {
                continue
            }
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(state) draws \(name), which this macOS does not have"
            )
        }
    }
}
