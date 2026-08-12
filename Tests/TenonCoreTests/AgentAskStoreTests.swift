import Foundation
@testable import TenonCore
import TenonIntentCore
import XCTest

final class AgentAskStoreTests: XCTestCase {
    func testADeclaredQuestionReturnsTheTypedValueBehindTheChosenID() async throws {
        let store = AgentAskStore()
        let paneID = UUID()
        let updates = await store.updates(matching: .pane(paneID))
        var iterator = updates.makeAsyncIterator()
        let request = Self.request(paneID: paneID, recipient: .human)
        let asking = Task.detached {
            try await store.ask(request)
        }

        let firstUpdate = await iterator.next()
        let question = try XCTUnwrap(firstUpdate)
        try await store.answer(
            questionID: question.id,
            responder: Self.human,
            choiceID: "approve"
        )
        let result = try await asking.value

        XCTAssertEqual(result.questionID, question.id)
        XCTAssertEqual(result.status, .answered)
        XCTAssertEqual(result.value, .bool(true))
    }

    /// The intent request and the question record have deliberately different lifetimes.
    /// Losing a provider process or compacting its context may cancel the waiter, but it
    /// must not erase the person's evidence or make the card impossible to answer.
    func testKillingTheAskerDetachesItsWaiterButLeavesThePaneRecordAnswerable() async throws {
        let store = AgentAskStore()
        let paneID = UUID()
        let updates = await store.updates(matching: .pane(paneID))
        var iterator = updates.makeAsyncIterator()
        let request = Self.request(paneID: paneID, recipient: .human)
        let asking = Task.detached {
            try await store.ask(request)
        }
        let firstUpdate = await iterator.next()
        let question = try XCTUnwrap(firstUpdate)

        asking.cancel()
        do {
            _ = try await asking.value
            XCTFail("a dead asking process must not keep a live waiter")
        } catch is CancellationError {
            // Expected. The record is host-owned, the waiter is caller-owned.
        }

        let pendingRecord = await store.question(id: question.id)
        XCTAssertEqual(pendingRecord?.state, .pending)
        try await store.answer(
            questionID: question.id,
            responder: Self.human,
            choiceID: "revise"
        )
        let answeredRecord = await store.question(id: question.id)
        XCTAssertEqual(
            answeredRecord?.state,
            .answered(
                choiceID: "revise",
                value: .string("revise"),
                responder: Self.human
            )
        )
    }

    func testAnAgentRecipientUsesTheSameRouteWithoutSchedulingAnything() async throws {
        let store = AgentAskStore()
        let paneID = UUID()
        let recipientPrincipal = IntentPrincipal(
            id: "agent:reviewer:\(UUID().uuidString.lowercased())",
            kind: .agent,
            sessionRevision: 7
        )
        let recipient = AgentQuestionRecipient.agent(recipientPrincipal)
        let updates = await store.updates(matching: .recipient(recipient))
        var iterator = updates.makeAsyncIterator()
        let request = Self.request(paneID: paneID, recipient: recipient)
        let asking = Task.detached {
            try await store.ask(request)
        }

        let firstUpdate = await iterator.next()
        let question = try XCTUnwrap(firstUpdate)
        XCTAssertEqual(question.paneID, paneID)
        XCTAssertEqual(question.recipient, recipient)
        let routedQuestions = await store.pendingQuestions(for: recipient)
        XCTAssertEqual(routedQuestions.map(\.id), [question.id])

        do {
            try await store.answer(
                questionID: question.id,
                responder: Self.human,
                choiceID: "approve"
            )
            XCTFail("the human principal must not answer an agent-addressed question")
        } catch AgentAskStoreError.responderDoesNotMatchRecipient {
            // Exact recipient identity is the route; there is no scheduler fallback.
        }

        try await store.answer(
            questionID: question.id,
            responder: recipientPrincipal,
            choiceID: "approve"
        )
        let result = try await asking.value
        XCTAssertEqual(result.value, .bool(true))
    }

    func testExpirySettlesExactlyOnceWithoutDependingOnWallClockScheduling() async throws {
        let store = AgentAskStore()
        let paneID = UUID()
        let updates = await store.updates(matching: .pane(paneID))
        var iterator = updates.makeAsyncIterator()
        let request = Self.request(
            paneID: paneID,
            recipient: .human,
            timeoutMilliseconds: 55000
        )
        let asking = Task.detached {
            try await store.ask(request)
        }
        let firstUpdate = await iterator.next()
        let question = try XCTUnwrap(firstUpdate)

        await store.expireDue(at: question.expiresAt)
        let result = try await asking.value

        XCTAssertEqual(result.status, .expired)
        XCTAssertNil(result.value)
        let expiredRecord = await store.question(id: question.id)
        XCTAssertEqual(expiredRecord?.state, .expired)
        await store.expireDue(at: question.expiresAt.addingTimeInterval(1))
        let stillExpiredRecord = await store.question(id: question.id)
        XCTAssertEqual(stillExpiredRecord?.state, .expired)
    }

    func testAPaneAdmitsOnlyOnePendingQuestionAndCloseSettlesItsWaiter() async throws {
        let store = AgentAskStore()
        let paneID = UUID()
        let updates = await store.updates(matching: .pane(paneID))
        var iterator = updates.makeAsyncIterator()
        let firstRequest = Self.request(paneID: paneID, recipient: .human)
        let first = Task.detached { try await store.ask(firstRequest) }
        let firstUpdate = await iterator.next()
        _ = try XCTUnwrap(firstUpdate)

        do {
            _ = try await store.ask(
                Self.request(paneID: paneID, recipient: .human)
            )
            XCTFail("one pane must not accumulate competing questions")
        } catch AgentAskStoreError.questionAlreadyPending {
            // Expected boundedness.
        }

        await store.closePane(paneID)
        do {
            _ = try await first.value
            XCTFail("closing the pane must settle its waiter")
        } catch AgentAskStoreError.paneClosed {
            // Expected lifecycle result.
        }
    }
}

private extension AgentAskStoreTests {
    static let human = IntentPrincipal(
        id: "user:local",
        kind: .user,
        sessionRevision: 1
    )

    static func request(
        paneID: UUID,
        recipient: AgentQuestionRecipient,
        timeoutMilliseconds: Int = 30000
    ) -> AgentAskRequest {
        AgentAskRequest(
            paneID: paneID,
            asker: IntentPrincipal(
                id: "agent:asker:\(paneID.uuidString.lowercased())",
                kind: .agent,
                sessionRevision: 3
            ),
            recipient: recipient,
            question: "Ship this change?",
            choices: [
                AgentQuestionChoice(
                    id: "approve",
                    label: "Approve",
                    value: .bool(true)
                ),
                AgentQuestionChoice(
                    id: "revise",
                    label: "Revise",
                    value: .string("revise")
                ),
            ],
            evidence: [
                AgentQuestionEvidence(
                    label: "Patch",
                    url: "file:///tmp/tenon.patch"
                ),
            ],
            timeoutMilliseconds: timeoutMilliseconds
        )
    }
}
