import Foundation
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

@MainActor
final class AgentAskIntentProviderTests: XCTestCase {
    func testThePublicBindingBlocksThenReturnsTheChosenTypedValue() async throws {
        let store = AgentAskStore()
        let binding = try XCTUnwrap(
            AgentIntentProvider(questions: store).bindings().first {
                $0.intentID == (try? CoreIntentName.agentAsk.intentID)
            }
        )
        let paneID = UUID()
        let updates = await store.updates(matching: .pane(paneID))
        var iterator = updates.makeAsyncIterator()
        let envelope = try Self.envelope(paneID: paneID)
        let context = Self.context(requestID: envelope.requestID)

        let invocation = Task.detached {
            try await binding.invoke(envelope: envelope, context: context)
        }
        let firstUpdate = await iterator.next()
        let question = try XCTUnwrap(firstUpdate)
        XCTAssertEqual(question.question, "Which release channel?")
        XCTAssertEqual(question.evidence.map(\.label), ["Change review"])

        try await store.answer(
            questionID: question.id,
            responder: IntentPrincipal(
                id: "user:tenon",
                kind: .user,
                sessionRevision: 1
            ),
            choiceID: "canary"
        )

        guard case let .success(value) = try await invocation.value else {
            return XCTFail("expected the provider to settle successfully")
        }
        XCTAssertEqual(
            value,
            .object([
                "questionID": .string(question.id.uuidString),
                "status": .string("answered"),
                "value": .string("canary"),
            ])
        )
    }
}

private extension AgentAskIntentProviderTests {
    static func envelope(paneID: UUID) throws -> IntentEnvelope {
        try IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: CoreIntentName.agentAsk.intentID,
            input: .object([
                "question": .string("Which release channel?"),
                "choices": .array([
                    .object([
                        "id": .string("canary"),
                        "label": .string("Canary"),
                        "value": .string("canary"),
                    ]),
                    .object([
                        "id": .string("stable"),
                        "label": .string("Stable"),
                        "value": .string("stable"),
                    ]),
                ]),
                "evidence": .array([
                    .object([
                        "label": .string("Change review"),
                        "url": .string("file:///tmp/change-review.html"),
                    ]),
                ]),
                "recipient": .object(["kind": .string("human")]),
                "timeoutMs": .integer(30000),
            ]),
            caller: IntentPrincipal(
                id: "agent:pane:\(paneID.uuidString)",
                kind: .agent,
                sessionRevision: 1
            ),
            scope: InvocationScope(paneID: paneID),
            deadline: .now.advanced(by: .seconds(35)),
            target: nil,
            idempotencyKey: nil
        )
    }

    static func context(requestID: UUID) -> IntentProviderContext {
        IntentProviderContext(
            requestID: requestID,
            nestedSend: { _ in
                .failure(
                    error: IntentError(
                        code: .kernel(.internal),
                        details: nil,
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: requestID,
                    providerID: nil
                )
            }
        )
    }
}
