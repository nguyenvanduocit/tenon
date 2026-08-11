import Foundation
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-130: the file that makes "Always allow" mean it.
///
/// The kernel decides consent; this decides where it lives. Both halves are tested because
/// the wiring between them is where a feature like this dies quietly — the engine keeps its
/// promise, the file is never opened, and nobody notices until the next launch asks again.
final class StandingConsentStoreTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tenon-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWhatWasKeptIsWhatComesBack() throws {
        let store = StandingConsentStore(fileURL: file())
        let kept = try Self.snapshot()

        try store.write(kept)

        XCTAssertEqual(store.load(), kept)
    }

    func testAFirstLaunchReadsNothingRatherThanFailing() {
        XCTAssertEqual(StandingConsentStore(fileURL: file()).load(), .empty)
    }

    /// Fail-soft in the direction that costs prompts, never in the direction that grants
    /// authority: an unreadable file is treated as no consent at all.
    func testAFileThisBuildCannotReadGrantsNothing() throws {
        let url = file()
        try Data("{\"contracts\": \"not a set\"}".utf8).write(to: url)

        XCTAssertEqual(StandingConsentStore(fileURL: url).load(), .empty)
    }

    /// Bounded like everything else that crosses a lifetime (invariant 10), and refused
    /// rather than truncated — a silently trimmed file is consent the person gave and the
    /// host dropped without saying so.
    func testMoreRecordsThanTheLimitIsRefused() throws {
        let store = StandingConsentStore(fileURL: file())
        let caller = IntentPrincipal(id: "dev.tenon.example", kind: .plugin, sessionRevision: 1)
        let contracts = try (0 ... StandingConsentStore.recordLimit).map { index in
            CallerConsentKey(
                caller: caller,
                contract: try IntentID("dev.tenon.core.example.n\(index).v1")
            )
        }

        XCTAssertThrowsError(
            try store.write(
                StandingConsentSnapshot(contracts: Set(contracts), callers: [])
            )
        ) { error in
            XCTAssertEqual(
                error as? StandingConsentStoreError,
                .tooManyRecords(
                    count: contracts.count,
                    limit: StandingConsentStore.recordLimit
                )
            )
        }
        XCTAssertEqual(store.load(), .empty)
    }

    // MARK: - The wiring  @domain: intent-bus

    /// The half that is easy to leave undone: a kernel prepared the way the app prepares it
    /// adopts what the last launch kept, so the person is not asked again.
    func testAPreparedKernelAdoptsTheConsentTheLastLaunchKept() async throws {
        let store = StandingConsentStore(fileURL: file())
        let kept = try Self.snapshot()
        try store.write(kept)

        let kernel = try await AppIntentRuntime.prepareKernel(
            stateRoot: directory.appendingPathComponent("runtime", isDirectory: true),
            confirmationAuthorizer: .failClosed,
            standingConsent: store
        )

        let caller = try XCTUnwrap(kept.callers.first)
        let contract = try XCTUnwrap(kept.contracts.first)
        let principal = IntentPrincipal(
            id: caller.callerID,
            kind: caller.callerKind,
            // A different generation of the same installation: consent is the
            // installation's, which is the whole reason it can be kept at all.
            sessionRevision: 97
        )
        let remembered = await kernel.policy.hasStandingConsent(
            contract: contract.contract,
            caller: principal
        )
        XCTAssertTrue(remembered)
    }

    /// And a grant made now is on disk before the next launch, without anyone flushing it.
    func testAGrantMadeThroughThePreparedKernelIsKept() async throws {
        let store = StandingConsentStore(fileURL: file())
        let kernel = try await AppIntentRuntime.prepareKernel(
            stateRoot: directory.appendingPathComponent("runtime", isDirectory: true),
            confirmationAuthorizer: .failClosed,
            standingConsent: store
        )
        let caller = IntentPrincipal(id: "dev.tenon.example", kind: .plugin, sessionRevision: 1)
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")

        try await kernel.policy.grantStandingConsent(contract: contract, caller: caller)

        XCTAssertEqual(
            store.load().contracts,
            [CallerConsentKey(caller: caller, contract: contract)]
        )
    }

    // MARK: - Fixtures  @domain: intent-bus

    private func file() -> URL {
        directory.appendingPathComponent(".standing-consent.json")
    }

    private static func snapshot() throws -> StandingConsentSnapshot {
        let caller = IntentPrincipal(
            id: "dev.tenon.example",
            kind: .plugin,
            sessionRevision: 1
        )
        return StandingConsentSnapshot(
            contracts: [
                CallerConsentKey(
                    caller: caller,
                    contract: try IntentID("dev.tenon.core.filesystem.file.write.v1")
                ),
            ],
            callers: [CallerWideConsentKey(caller: caller)]
        )
    }
}
