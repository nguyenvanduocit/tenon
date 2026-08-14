import Foundation
@testable import TenonApp
import XCTest

final class AgentLensReadModelTests: XCTestCase {
    func testConversationFoldsCompletedWorkWithoutDiscardingFactIdentity() throws {
        let turnID = AgentTurnID("provider-turn-1")
        var snapshot = AgentLensSnapshot.empty
        snapshot.messages = [
            message(id: "user", role: .user, turnID: turnID, at: 1),
            message(id: "assistant", role: .assistant, turnID: turnID, at: 8),
        ]
        snapshot.tools = [
            tool(id: "command", kind: .command, turnID: turnID, at: 2),
            tool(
                id: "spawn",
                kind: .subagent,
                turnID: turnID,
                taskID: AgentTaskID("review"),
                at: 3
            ),
            tool(
                id: "wait",
                kind: .subagent,
                turnID: turnID,
                taskID: AgentTaskID("review"),
                at: 4
            ),
        ]
        snapshot.plans = [
            AgentPlanUpdate(
                id: "turn:provider-turn-1",
                turnID: turnID,
                explanation: "Implement and verify",
                steps: [
                    AgentPlanStep(id: "step-1", text: "Implement", state: .completed),
                    AgentPlanStep(id: "step-2", text: "Verify", state: .running),
                ],
                evidence: evidence(at: 5)
            ),
        ]
        snapshot.changeSets = [
            AgentChangeSet(
                id: "turn:provider-turn-1",
                turnID: turnID,
                unifiedDiff: "+read model",
                changedPaths: ["AgentLensReadModel.swift"],
                evidence: evidence(at: 6)
            ),
        ]

        let readModel = snapshot.readModel

        XCTAssertEqual(readModel.conversation.count, 3)
        guard case .work(let work) = readModel.conversation[1].content else {
            return XCTFail("execution was not folded between the two messages")
        }
        XCTAssertEqual(work.entries.map(\.id), [
            "tool-command",
            "tool-spawn",
            "tool-wait",
            "plan-turn:provider-turn-1",
            "changes-turn:provider-turn-1",
        ])
        XCTAssertEqual(work.state, .running)
        XCTAssertEqual(readModel.plans.count, 1)
        XCTAssertEqual(readModel.changes.count, 1)
        XCTAssertEqual(readModel.agents.count, 1)
        XCTAssertEqual(readModel.agents.first?.operations.map(\.id), ["spawn", "wait"])

        for factID in work.entries.map(\.id) {
            XCTAssertEqual(
                readModel.conversationAnchor(forFactID: factID),
                work.id,
                "each source fact must return to the stable fold that contains it"
            )
        }
    }

    func testTranscriptFactsReceiveAnExplicitlyDerivedTurnWhileProviderIDsWin() throws {
        var snapshot = AgentLensSnapshot.empty
        snapshot.messages = [
            message(id: "user-derived", role: .user, turnID: nil, at: 1),
            message(id: "assistant-derived", role: .assistant, turnID: nil, at: 4),
            message(
                id: "assistant-native",
                role: .assistant,
                turnID: AgentTurnID("provider-turn-2"),
                at: 6
            ),
        ]
        snapshot.tools = [
            tool(id: "derived-tool", kind: .command, turnID: nil, at: 2),
            tool(
                id: "native-tool",
                kind: .fileChange,
                turnID: AgentTurnID("provider-turn-2"),
                at: 5
            ),
        ]

        let items = snapshot.timelineItems
        XCTAssertEqual(items.first?.turnID, .derived(from: "user-derived"))
        XCTAssertEqual(
            items.first(where: { $0.id == "tool-derived-tool" })?.turnID,
            .derived(from: "user-derived")
        )
        XCTAssertEqual(
            items.first(where: { $0.id == "tool-native-tool" })?.turnID,
            AgentTurnID("provider-turn-2")
        )
        XCTAssertEqual(
            items.first(where: { $0.id == "message-assistant-native" })?.turnID,
            AgentTurnID("provider-turn-2")
        )
    }

    func testReducerReplacesPlanDiffAndContextStateByStableIdentity() {
        let turnID = AgentTurnID("turn-1")
        var reducer = AgentLensReducer()
        reducer.apply(
            .planUpdated(
                AgentPlanUpdate(
                    id: "turn:turn-1",
                    turnID: turnID,
                    explanation: "first",
                    steps: [AgentPlanStep(id: "one", text: "One", state: .running)],
                    evidence: evidence(at: 1)
                )
            )
        )
        reducer.apply(
            .planUpdated(
                AgentPlanUpdate(
                    id: "turn:turn-1",
                    turnID: turnID,
                    explanation: "latest",
                    steps: [AgentPlanStep(id: "one", text: "One", state: .completed)],
                    evidence: evidence(at: 2)
                )
            )
        )
        reducer.apply(
            .changeSetUpdated(
                AgentChangeSet(
                    id: "turn:turn-1",
                    turnID: turnID,
                    unifiedDiff: "+latest",
                    changedPaths: ["A.swift"],
                    evidence: evidence(at: 3)
                )
            )
        )
        let usage = AgentContextUsage(
            turnID: turnID,
            last: tokens(20),
            total: tokens(40),
            modelContextWindow: 100,
            evidence: evidence(at: 4)
        )
        reducer.apply(.contextUsageUpdated(usage))

        XCTAssertEqual(reducer.snapshot.plans.count, 1)
        XCTAssertEqual(reducer.snapshot.plans.first?.explanation, "latest")
        XCTAssertEqual(reducer.snapshot.plans.first?.steps.first?.state, .completed)
        XCTAssertEqual(reducer.snapshot.changeSets.first?.changedPaths, ["A.swift"])
        XCTAssertEqual(reducer.snapshot.contextUsage, usage)
    }

    private func message(
        id: String,
        role: AgentMessageRole,
        turnID: AgentTurnID?,
        at offset: UInt64
    ) -> AgentLensMessage {
        AgentLensMessage(
            id: id,
            turnID: turnID,
            role: role,
            text: id,
            isStreaming: false,
            evidence: evidence(at: offset)
        )
    }

    private func tool(
        id: String,
        kind: AgentToolKind,
        turnID: AgentTurnID?,
        taskID: AgentTaskID? = nil,
        at offset: UInt64
    ) -> AgentToolRun {
        AgentToolRun(
            id: id,
            turnID: turnID,
            taskID: taskID,
            name: id,
            kind: kind,
            summary: id,
            detail: "",
            state: .succeeded,
            exitCode: nil,
            evidence: evidence(at: offset)
        )
    }

    private func tokens(_ total: Int) -> AgentTokenUsage {
        AgentTokenUsage(
            inputTokens: total,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: total
        )
    }

    private func evidence(at offset: UInt64) -> AgentEvidence {
        AgentEvidence(
            source: .nativeProtocol,
            authority: .reported,
            location: "test:\(offset)",
            byteOffset: offset,
            fingerprint: "fingerprint-\(offset)",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(offset)),
            freshness: .current
        )
    }
}
