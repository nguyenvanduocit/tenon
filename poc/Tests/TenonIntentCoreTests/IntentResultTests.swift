import Foundation
import XCTest
@testable import TenonIntentCore

final class IntentResultTests: XCTestCase {
    func testKernelErrorVocabularyIsClosedAndComplete() {
        XCTAssertEqual(
            Set(IntentKernelErrorCode.allCases.map(\.rawValue)),
            Set([
                "tenon.unknown-intent",
                "tenon.undeclared-use",
                "tenon.invalid-input",
                "tenon.denied",
                "tenon.no-provider",
                "tenon.ambiguous-provider",
                "tenon.provider-unavailable",
                "tenon.overloaded",
                "tenon.idempotency-conflict",
                "tenon.cycle-detected",
                "tenon.deadline-exceeded",
                "tenon.cancelled",
                "tenon.provider-retired",
                "tenon.handler-failed",
                "tenon.invalid-output",
                "tenon.internal",
            ])
        )
    }

    func testSuccessHasValidatedValueAndRequiredProviderMetadata() throws {
        let requestID = UUID()
        let providerID = try ProviderID("core.terminal")
        let result = IntentResult.success(
            value: .object(["accepted": .bool(true)]),
            requestID: requestID,
            providerID: providerID
        )

        XCTAssertEqual(
            result,
            .success(
                IntentSuccess(
                    value: .object(["accepted": .bool(true)]),
                    meta: IntentSuccessMetadata(requestID: requestID, providerID: providerID)
                )
            )
        )
    }

    func testFailureKeepsErrorOutsideSuccessPayloadAndAllowsMissingProvider() {
        let requestID = UUID()
        let result = IntentResult.failure(
            error: IntentError(
                code: .kernel(.noProvider),
                details: .object(["intent": .string("terminal.run.v1")]),
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: requestID,
            providerID: nil
        )

        XCTAssertEqual(
            result,
            .failure(
                IntentFailure(
                    error: IntentError(
                        code: .kernel(.noProvider),
                        details: .object(["intent": .string("terminal.run.v1")]),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    meta: IntentFailureMetadata(requestID: requestID, providerID: nil)
                )
            )
        )
    }

    func testErrorCodeEncodesAsLocaleNeutralWireString() throws {
        let kernelData = try JSONEncoder().encode(IntentErrorCode.kernel(.overloaded))
        let domainData = try JSONEncoder().encode(
            IntentErrorCode.domain(IntentDomainErrorCode("dev.tenon.git.index-locked"))
        )

        XCTAssertEqual(String(decoding: kernelData, as: UTF8.self), #""tenon.overloaded""#)
        XCTAssertEqual(
            String(decoding: domainData, as: UTF8.self),
            #""dev.tenon.git.index-locked""#
        )
    }

    func testTerminalResultUsesStructuredWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let providerID = try ProviderID("core.terminal")
        let result = IntentResult.success(
            value: .integer(42),
            requestID: requestID,
            providerID: providerID
        )

        let data = try encoder.encode(result)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"meta":{"providerID":"core.terminal","requestID":"00000000-0000-0000-0000-000000000001"},"ok":true,"value":42}"#
        )
    }
}
