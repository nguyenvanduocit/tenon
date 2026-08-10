import Foundation
import TenonIntentCore
@testable import TenonCore
import XCTest

final class CLIActionParserTests: XCTestCase {
    func testClosedControlActions() {
        XCTAssertEqual(action("ping"), .ping)
        XCTAssertEqual(action("app.focus"), .appFocus)
        XCTAssertEqual(action("intent.list"), .intentList)
    }

    func testDescribeRequiresAValidVersionedIntentID() throws {
        let intentID = try IntentID("workspace.state.v1")
        XCTAssertEqual(
            action(
                "intent.describe",
                ["name": .string(intentID.rawValue)]
            ),
            .intentDescribe(intentID)
        )
        XCTAssertEqual(errorCode("intent.describe"), .invalidParams)
        XCTAssertEqual(
            errorCode(
                "intent.describe",
                ["name": .string("workspace.state")]
            ),
            .invalidParams
        )
    }

    func testIntentSendPreservesTypedInputAndCallerSelectableScope() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let paneID = UUID()
        let intentID = try IntentID("terminal.wait.v1")
        let providerID = try ProviderID("dev.tenon.core")
        let input = IntentValue.object([
            "condition": .string("exit"),
            "timeoutMs": .integer(5_000),
        ])
        XCTAssertEqual(
            action(
                "intent.send",
                [
                    "name": .string(intentID.rawValue),
                    "input": input,
                    "scope": .object([
                        "workspaceID": .string(workspaceID.uuidString),
                        "tabID": .string(tabID.uuidString),
                        "paneID": .string(paneID.uuidString),
                    ]),
                    "target": .string(providerID.rawValue),
                    "idempotencyKey": .string("request-1"),
                    "timeoutMs": .integer(6_000),
                ]
            ),
            .intentSend(
                CLIIntentInvocation(
                    intentID: intentID,
                    input: input,
                    scope: InvocationScope(
                        workspaceID: workspaceID,
                        tabID: tabID,
                        paneID: paneID
                    ),
                    target: providerID,
                    idempotencyKey: "request-1",
                    timeoutMilliseconds: 6_000
                )
            )
        )
    }

    func testIntentSendRejectsCallerSuppliedUserGestureProof() {
        let result = CLIActionParser.parse(
            CLIRequest(
                id: "test",
                action: "intent.send",
                params: .object([
                    "name": .string("workspace.state.v1"),
                    "input": .object([:]),
                    "scope": .object([
                        "userGestureID": .string(UUID().uuidString)
                    ]),
                ])
            )
        )

        XCTAssertEqual(
            result,
            .failure(
                CLIError(
                    code: .invalidParams,
                    message: "param 'scope.userGestureID' is host-owned"
                )
            )
        )
    }

    func testIntentSendRequiresInputAndScope() {
        XCTAssertEqual(
            errorCode(
                "intent.send",
                [
                    "name": .string("workspace.state.v1"),
                    "scope": .object([:]),
                ]
            ),
            .invalidParams
        )
        XCTAssertEqual(
            errorCode(
                "intent.send",
                [
                    "name": .string("workspace.state.v1"),
                    "input": .object([:]),
                ]
            ),
            .invalidParams
        )
    }

    func testIntentSendRejectsImplicitOrMalformedAuthority() {
        XCTAssertEqual(
            errorCode(
                "intent.send",
                [
                    "name": .string("workspace.state.v1"),
                    "input": .object([:]),
                    "scope": .string("active"),
                ]
            ),
            .invalidParams
        )
        XCTAssertEqual(
            errorCode(
                "intent.send",
                [
                    "name": .string("workspace.state.v1"),
                    "input": .object([:]),
                    "scope": .object([
                        "paneID": .string("not-a-uuid")
                    ]),
                ]
            ),
            .invalidParams
        )
        XCTAssertEqual(
            errorCode(
                "intent.send",
                [
                    "name": .string("workspace.state.v1"),
                    "input": .object([:]),
                    "scope": .object([
                        "implicitActivePane": .bool(true)
                    ]),
                ]
            ),
            .invalidParams
        )
    }

    func testIntentSendTimeoutIsStrictlyBoundedAndTyped() {
        let base: [String: IntentValue] = [
            "name": .string("workspace.state.v1"),
            "input": .object([:]),
            "scope": .object([:]),
        ]
        XCTAssertEqual(
            errorCode(
                "intent.send",
                base.merging(["timeoutMs": .integer(0)]) { _, new in new }
            ),
            .invalidParams
        )
        XCTAssertEqual(
            errorCode(
                "intent.send",
                base.merging(["timeoutMs": .integer(60_001)]) {
                    _, new in new
                }
            ),
            .invalidParams
        )
        XCTAssertEqual(
            errorCode(
                "intent.send",
                base.merging(["timeoutMs": .string("5000")]) {
                    _, new in new
                }
            ),
            .invalidParams
        )
    }

    func testLegacyWireActionsAreAllRejected() {
        for legacy in [
            "command.list",
            "command.run",
            "workspace.state",
            "pane.send",
            "pane.read",
            "pane.wait",
            "pane.focus",
        ] {
            XCTAssertEqual(
                errorCode(legacy),
                .unknownAction,
                legacy
            )
        }
    }

    func testParamsMustBeObjectAndUnknownFieldsAreRejected() {
        let nonObject = CLIActionParser.parse(
            CLIRequest(
                id: "1",
                action: "ping",
                params: .array([])
            )
        )
        guard case let .failure(error) = nonObject else {
            return XCTFail("expected invalid params")
        }
        XCTAssertEqual(error.code, .invalidParams)
        XCTAssertEqual(
            errorCode("ping", ["typo": .bool(true)]),
            .invalidParams
        )
    }
}

private extension CLIActionParserTests {
    func action(
        _ name: String,
        _ params: [String: IntentValue] = [:]
    ) -> CLIAction? {
        guard case let .success(action) = CLIActionParser.parse(
            CLIRequest(
                id: "test",
                action: name,
                params: .object(params)
            )
        ) else {
            return nil
        }
        return action
    }

    func errorCode(
        _ name: String,
        _ params: [String: IntentValue] = [:]
    ) -> CLIErrorCode? {
        guard case let .failure(error) = CLIActionParser.parse(
            CLIRequest(
                id: "test",
                action: name,
                params: .object(params)
            )
        ) else {
            return nil
        }
        return error.code
    }
}
