import XCTest
@testable import TenonIntentCore
@testable import TenonCore

final class CLIProtocolTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testDecodesAWellFormedRequest() {
        let decoding = CLIWireCodec.decodeRequest(
            line(
                #"{"v":3,"id":"abc","action":"intent.describe","params":{"name":"workspace.state.v1"}}"#
            )
        )
        guard case .ok(let request) = decoding else { return XCTFail("expected ok, got \(decoding)") }
        XCTAssertEqual(
            request,
            CLIRequest(
                id: "abc",
                action: "intent.describe",
                params: .object([
                    "name": .string("workspace.state.v1")
                ])
            )
        )
    }

    func testDecodesRequestWithoutParams() {
        let decoding = CLIWireCodec.decodeRequest(
            line(#"{"v":3,"id":"x","action":"ping"}"#)
        )
        guard case .ok(let request) = decoding else { return XCTFail() }
        XCTAssertEqual(request.params, .object([:]))
    }

    func testRejectsMalformedJSON() {
        guard case .rejected(.failure(let id, let error)) = CLIWireCodec.decodeRequest(line("{not json")) else { return XCTFail() }
        XCTAssertNil(id)
        XCTAssertEqual(error.code, .malformedJSON)
    }

    func testRejectsNonObjectJSON() {
        guard case .rejected(.failure(_, let error)) = CLIWireCodec.decodeRequest(line("[1,2,3]")) else { return XCTFail() }
        XCTAssertEqual(error.code, .malformedJSON)
    }

    func testRejectsUnsupportedVersionButKeepsID() {
        guard case .rejected(.failure(let id, let error)) = CLIWireCodec.decodeRequest(line(#"{"v":99,"id":"keep","action":"ping"}"#)) else { return XCTFail() }
        XCTAssertEqual(id, "keep")
        XCTAssertEqual(error.code, .unsupportedVersion)
    }

    func testVersionSkewIsRejectedInBothDirections() throws {
        let oldVersion = CLIProtocol.version - 1
        let oldClientRequest = try CLIWireCodec.encodeRequest(
            CLIRequest(v: oldVersion, id: "old-client", action: "ping")
        )
        guard case let .rejected(.failure(oldID, oldError)) = CLIWireCodec.decodeRequest(
            oldClientRequest
        ) else {
            return XCTFail("the current host must reject an older client")
        }
        XCTAssertEqual(oldID, "old-client")
        XCTAssertEqual(oldError.code, .unsupportedVersion)
        XCTAssertTrue(oldError.message.contains("speaks \(CLIProtocol.version)"))

        let currentClientRequest = try CLIWireCodec.encodeRequest(
            CLIRequest(v: CLIProtocol.version, id: "new-client", action: "ping")
        )
        guard case let .rejected(.failure(newID, newError)) = CLIWireCodec.decodeRequest(
            currentClientRequest,
            supportedVersion: oldVersion
        ) else {
            return XCTFail("an older host fixture must reject a newer client")
        }
        XCTAssertEqual(newID, "new-client")
        XCTAssertEqual(newError.code, .unsupportedVersion)
        XCTAssertTrue(newError.message.contains("speaks \(oldVersion)"))
    }

    func testRejectsMissingActionButKeepsID() {
        guard case .rejected(.failure(let id, let error)) = CLIWireCodec.decodeRequest(line(#"{"v":3,"id":"y"}"#)) else { return XCTFail() }
        XCTAssertEqual(id, "y")
        XCTAssertEqual(error.code, .malformedJSON)
    }

    func testPreservesTypedParamValuesForActionValidation() {
        let decoding = CLIWireCodec.decodeRequest(
            line(
                #"{"v":3,"id":"y","action":"intent.send","params":{"name":"terminal.write.v1","input":{"text":"ls","enter":true,"count":5},"scope":{}}}"#
            )
        )
        guard case let .ok(request) = decoding else {
            return XCTFail("expected typed params")
        }
        XCTAssertEqual(
            request.params,
            .object([
                "name": .string("terminal.write.v1"),
                "input": .object([
                    "text": .string("ls"),
                    "enter": .bool(true),
                    "count": .integer(5),
                ]),
                "scope": .object([:]),
            ])
        )
    }

    func testEncodeSuccessAppendsExactlyOneNewline() throws {
        let data = try CLIWireCodec.encode(
            .success(id: "1", result: .object(["ok": .bool(true)]))
        )
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
    }

    func testEncodeSuccessRoundTripsThroughIntentValue() throws {
        let data = try CLIWireCodec.encode(
            .success(
                id: "req-7",
                result: .array([.string("a"), .integer(2)])
            )
        )
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["v"] as? Int, CLIProtocol.version)
        XCTAssertEqual(object["id"] as? String, "req-7")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(
            try IntentValue(jsonData: data),
            .object([
                "v": .integer(Int64(CLIProtocol.version)),
                "id": .string("req-7"),
                "ok": .bool(true),
                "result": .array([.string("a"), .integer(2)]),
            ])
        )
    }

    func testEncodeFailureWithNilIDSerializesNull() throws {
        let data = try CLIWireCodec.encode(
            .failure(
                id: nil,
                error: CLIError(code: .malformedJSON, message: "bad")
            )
        )
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(object["id"] is NSNull)
        XCTAssertEqual(object["ok"] as? Bool, false)
        let error = object["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? String, "malformed_json")
        XCTAssertEqual(error["message"] as? String, "bad")
    }

    func testPayloadCapAcceptsAtLimitRejectsOver() {
        XCTAssertNil(CLIWireCodec.validate(payloadSize: CLIProtocol.maxPayloadSize))
        XCTAssertEqual(CLIWireCodec.validate(payloadSize: CLIProtocol.maxPayloadSize + 1), .payloadTooLarge)
    }

    func testEncodeRequestRoundTripsThroughDecode() throws {
        let request = CLIRequest(
            id: "r1",
            action: "intent.send",
            params: .object([
                "name": .string("terminal.write.v1"),
                "input": .object(["text": .string("hi")]),
                "scope": .object([:]),
            ])
        )
        let data = try CLIWireCodec.encodeRequest(request)
        XCTAssertEqual(data.last, 0x0A)
        guard case .ok(let decoded) = CLIWireCodec.decodeRequest(data) else { return XCTFail() }
        XCTAssertEqual(decoded, request)
    }

    func testEncodeRequestOmitsEmptyParams() throws {
        let data = try CLIWireCodec.encodeRequest(
            CLIRequest(id: "r2", action: "ping")
        )
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(object["params"])
    }

    func testDecodeResponseSuccess() throws {
        let data = try CLIWireCodec.encode(
            .success(id: "s1", result: .object(["pid": .integer(42)]))
        )
        XCTAssertEqual(
            CLIWireCodec.decodeResponse(data),
            .success(id: "s1", result: .object(["pid": .integer(42)]))
        )
    }

    func testDecodeResponseFailure() throws {
        let data = try CLIWireCodec.encode(
            .failure(
                id: "s2",
                error: CLIError(
                    code: .intentNotFound,
                    message: "not callable"
                )
            )
        )
        XCTAssertEqual(
            CLIWireCodec.decodeResponse(data),
            .failure(
                id: "s2",
                error: CLIError(
                    code: .intentNotFound,
                    message: "not callable"
                )
            )
        )
    }

    func testIntentFailureRoundTripPreservesCanonicalMetadata() throws {
        let requestID = UUID()
        let providerID = try ProviderID("dev.tenon.core")
        let failure = IntentFailure(
            error: IntentError(
                code: .domain(
                    try IntentDomainErrorCode(
                        "dev.tenon.core.terminal-unavailable"
                    )
                ),
                details: .object([
                    "reason": .string("terminal-surface-not-ready")
                ]),
                retryable: true,
                retryAfterMilliseconds: 200,
                outcome: .unknown
            ),
            meta: IntentFailureMetadata(
                requestID: requestID,
                providerID: providerID
            )
        )
        let error = CLIError(intentFailure: failure)
        let data = try CLIWireCodec.encode(
            .failure(id: "intent-1", error: error)
        )

        XCTAssertEqual(
            CLIWireCodec.decodeResponse(data),
            .failure(id: "intent-1", error: error)
        )
        guard case let .object(value) = error.intentValue else {
            return XCTFail("expected structured CLI error")
        }
        XCTAssertEqual(value["source"], .string("intent"))
        XCTAssertEqual(
            value["code"],
            .string("dev.tenon.core.terminal-unavailable")
        )
        XCTAssertEqual(
            value["requestID"],
            .string(requestID.uuidString)
        )
        XCTAssertEqual(
            value["providerID"],
            .string(providerID.rawValue)
        )
    }

    func testDecodeResponseRejectsGarbage() {
        XCTAssertNil(CLIWireCodec.decodeResponse(Data("not json".utf8)))
    }
}
