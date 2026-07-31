import TenonIntentCore
import XCTest
@testable import TenonApp

/// One launcher choice, one settlement rule, shared by every surface that presents the
/// launcher catalog (`+`, a tab's right-click). These pin the rules headlessly: frecency
/// learns only from a command that actually ran, an error is reported where the click
/// happened, and only success closes the launcher.
final class LauncherOutcomeTests: XCTestCase {
    private func success() throws -> IntentResult {
        .success(
            value: .object(["ok": .bool(true)]),
            requestID: UUID(),
            providerID: try ProviderID("dev.tenon.test")
        )
    }

    private func failure(code: IntentKernelErrorCode) -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(code),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: nil
        )
    }

    func testASuccessfulRunRecordsFrecencyAndClosesTheLauncher() throws {
        let outcome = LauncherOutcome(try success())

        XCTAssertEqual(outcome, .ran)
        XCTAssertTrue(outcome.recordsFrecency)
        XCTAssertTrue(outcome.dismisses)
        XCTAssertNil(outcome.errorMessage)
    }

    func testAFailureIsReportedInPlaceAndTeachesTheRankingNothing() {
        let outcome = LauncherOutcome(failure(code: .denied))

        XCTAssertEqual(outcome, .failed(code: "tenon.denied"))
        XCTAssertFalse(outcome.recordsFrecency)
        XCTAssertFalse(outcome.dismisses)
        XCTAssertEqual(outcome.errorMessage, "tenon.denied")
    }

    func testAVanishedIntentSaysSoAndTeachesTheRankingNothing() {
        let outcome = LauncherOutcome(nil)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(outcome.recordsFrecency)
        XCTAssertFalse(outcome.dismisses)
        XCTAssertEqual(outcome.errorMessage, "Intent is no longer available.")
    }
}
