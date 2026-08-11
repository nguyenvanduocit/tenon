import Foundation
import XCTest
@testable import TenonIntentCore

/// T-130: consent that outlives the process that was given it.
///
/// `CallerConsentKey` has always said consent belongs to an installation rather than to a
/// runtime generation — it omits the session revision to say so. Until this landed, the
/// engine still held every grant in memory alone, so the promise held for exactly as long
/// as the app stayed open. These cases pin the two halves that make the code mean it:
/// durable before remembered, and remembered again on the next launch.
final class StandingConsentPersistenceTests: XCTestCase {
    private let caller = IntentPrincipal(
        id: "dev.tenon.example",
        kind: .plugin,
        sessionRevision: 1
    )

    func testAGrantIsWrittenBeforeItIsRemembered() async throws {
        let writer = ConsentWriterProbe()
        let policy = PolicyEngine(standingConsentWriter: writer.writer())
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")

        try await policy.grantStandingConsent(contract: contract, caller: caller)

        let written = writer.snapshots
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(
            written.last?.contracts,
            [CallerConsentKey(caller: caller, contract: contract)]
        )
        let remembered = await policy.hasStandingConsent(
            contract: contract,
            caller: caller
        )
        XCTAssertTrue(remembered)
    }

    /// Fail closed: what could not be kept was never granted. `PRT-FR-023`.
    func testAGrantThatCannotBeWrittenIsNotRemembered() async throws {
        let writer = ConsentWriterProbe(failing: true)
        let policy = PolicyEngine(standingConsentWriter: writer.writer())
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")

        do {
            try await policy.grantStandingConsent(contract: contract, caller: caller)
            XCTFail("a consent that could not be written must not be granted")
        } catch is ConsentWriterFailure {
            // expected
        }

        let remembered = await policy.hasStandingConsent(
            contract: contract,
            caller: caller
        )
        XCTAssertFalse(remembered)
    }

    func testACallerWideGrantIsWrittenToo() async throws {
        let writer = ConsentWriterProbe()
        let policy = PolicyEngine(standingConsentWriter: writer.writer())

        try await policy.grantStandingConsent(for: caller)

        let written = writer.snapshots
        XCTAssertEqual(written.last?.callers, [CallerWideConsentKey(caller: caller)])
        let remembered = await policy.hasStandingConsent(for: caller)
        XCTAssertTrue(remembered)
    }

    /// The next launch: a fresh engine adopts what the last one kept, and asks nothing.
    func testRestoredConsentIsHonouredWithoutBeingWrittenBack() async throws {
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")
        let kept = StandingConsentSnapshot(
            contracts: [CallerConsentKey(caller: caller, contract: contract)],
            callers: [CallerWideConsentKey(caller: caller)]
        )
        let writer = ConsentWriterProbe()
        let policy = PolicyEngine(standingConsentWriter: writer.writer())

        try await policy.restoreStandingConsents(kept)

        let byContract = await policy.hasStandingConsent(
            contract: contract,
            caller: caller
        )
        let byCaller = await policy.hasStandingConsent(for: caller)
        XCTAssertTrue(byContract)
        XCTAssertTrue(byCaller)
        let written = writer.snapshots
        XCTAssertTrue(
            written.isEmpty,
            "restoring is reading, and reading must not write the file back"
        )
    }

    /// Revocation goes through the same door, or a plugin disabled while the app was closed
    /// would be restored consented on the next launch.
    func testWithdrawingACallerRewritesTheKeptStateWithoutIt() async throws {
        let writer = ConsentWriterProbe()
        let policy = PolicyEngine(standingConsentWriter: writer.writer())
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")
        try await policy.grantStandingConsent(contract: contract, caller: caller)
        try await policy.grantStandingConsent(for: caller)

        try await policy.revokeStandingConsents(for: caller)

        let written = writer.snapshots
        XCTAssertEqual(written.last, .empty)
        let byContract = await policy.hasStandingConsent(
            contract: contract,
            caller: caller
        )
        let byCaller = await policy.hasStandingConsent(for: caller)
        XCTAssertFalse(byContract)
        XCTAssertFalse(byCaller)
    }

    func testAnEngineWithNoWriterStillGrants() async throws {
        let policy = PolicyEngine()
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")

        try await policy.grantStandingConsent(contract: contract, caller: caller)

        let remembered = await policy.hasStandingConsent(
            contract: contract,
            caller: caller
        )
        XCTAssertTrue(remembered)
    }

    func testTheKeptStateSurvivesItsOwnEncoding() throws {
        let contract = try IntentID("dev.tenon.core.filesystem.file.write.v1")
        let snapshot = StandingConsentSnapshot(
            contracts: [CallerConsentKey(caller: caller, contract: contract)],
            callers: [CallerWideConsentKey(caller: caller)]
        )

        let restored = try JSONDecoder().decode(
            StandingConsentSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored, snapshot)
    }
}

private struct ConsentWriterFailure: Error {}

/// Records what the engine tried to keep.
///
/// A lock and not an actor: the writer's contract is synchronous because the engine calls
/// it *before* it commits a grant, and an `await` there would let the state it is about to
/// write change under it.
private final class ConsentWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StandingConsentSnapshot] = []
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var snapshots: [StandingConsentSnapshot] {
        lock.withLock { recorded }
    }

    func writer() -> StandingConsentWriter {
        { [self] snapshot in
            if failing {
                throw ConsentWriterFailure()
            }
            lock.withLock { recorded.append(snapshot) }
        }
    }
}
