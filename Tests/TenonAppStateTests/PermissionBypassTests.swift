import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-130: the switch that answers every permission confirmation.
///
/// The property under test is an *absence* — that nothing was presented — which is the
/// shape T-120 shows can pass for the wrong reason. So each case here also drives the
/// opposite direction on the same request: with the switch off, the very same call has to
/// reach `pending`. A bypass that silently broke the prompt entirely would fail that half.
@MainActor
final class PermissionBypassTests: XCTestCase {
    func testTheSwitchIsOnByDefault() {
        XCTAssertTrue(AppPreferences().bypassAllPermissionPrompts)
    }

    /// A preferences blob written before the switch existed has no key for it, and the
    /// person who wrote it never chose. They get the default, like every other key here.
    func testPreferencesWrittenBeforeTheSwitchArriveWithItOn() throws {
        let decoded = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(#"{"sidebarWidth":300}"#.utf8)
        )

        XCTAssertTrue(decoded.bypassAllPermissionPrompts)
        XCTAssertEqual(decoded.sidebarWidth, 300)
    }

    /// Turning it off is a choice, and a choice survives the round trip.
    func testTurningItOffIsRemembered() throws {
        var preferences = AppPreferences()
        preferences.bypassAllPermissionPrompts = false

        let restored = try JSONDecoder().decode(
            AppPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertFalse(restored.bypassAllPermissionPrompts)
    }

    func testAnUnwiredStateAsks() {
        XCTAssertNil(
            PluginUIState().standingPermissionAnswer(),
            "an unwired state must ask, because a prompt nobody wanted is visible and an "
                + "approval nobody saw is not"
        )
    }

    /// The answer is read from the store when a confirmation arrives, never copied into the
    /// state — so turning the switch off in Settings governs the very next request. A cached
    /// copy is the drift this test exists to make impossible.
    func testTheAnswerFollowsTheLiveStoreRatherThanACopy() {
        let store = Self.preferencesStore()
        let state = PluginUIState()
        state.adopt(store)

        XCTAssertEqual(state.standingPermissionAnswer(), .allowOnce)

        store.preferences.bypassAllPermissionPrompts = false

        XCTAssertNil(state.standingPermissionAnswer())
    }

    // MARK: - What the authorizer does with it

    func testAPolicyConfirmationIsApprovedWithoutPresentingAnything() async throws {
        let state = PluginUIState()
        state.adopt(Self.preferencesStore())
        let request = try await Self.request(confirmation: .policy)

        let decision = await state.confirmationAuthorizer().authorize(request)

        XCTAssertEqual(decision, .allowOnce)
        XCTAssertTrue(state.pending.isEmpty)
    }

    /// The product owner chose "every permission request", and `.always` is the mode whose
    /// whole point is asking each time — `secrets.delete.v1` is the contract that carries
    /// it today. The switch covers it, on the record.
    func testAContractThatAsksEveryTimeIsApprovedToo() async throws {
        let state = PluginUIState()
        state.adopt(Self.preferencesStore())
        let request = try await Self.request(confirmation: .always)

        let decision = await state.confirmationAuthorizer().authorize(request)

        XCTAssertEqual(decision, .allowOnce)
        XCTAssertTrue(state.pending.isEmpty)
    }

    /// `.allowOnce` and never `.alwaysAllow`: the switch must leave no standing consent
    /// behind, or turning it off would keep approving through records it wrote while on.
    func testApprovalIsWaveLocalAndRemembersNothing() async throws {
        let state = PluginUIState()
        state.adopt(Self.preferencesStore())
        let request = try await Self.request(confirmation: .policy)

        let decision = await state.confirmationAuthorizer().authorize(request)

        XCTAssertNotEqual(decision, .alwaysAllow)
        XCTAssertNotEqual(decision, .alwaysAllowForCaller)
    }

    func testWithTheSwitchOffTheSameRequestIsPresented() async throws {
        let state = PluginUIState()
        let request = try await Self.request(confirmation: .policy)

        let authorizing = Task { await state.confirmationAuthorizer().authorize(request) }
        try await Self.waitForPending(on: state)

        guard case .permission = try XCTUnwrap(state.current?.kind) else {
            return XCTFail("a `.policy` contract must be presented as a permission choice")
        }
        state.resolvePermission(.alwaysAllow)

        let decision = await authorizing.value
        XCTAssertEqual(decision, .alwaysAllow)
    }

    /// The switch answers permission. A plugin's own "Delete 12 files?" dialog is that
    /// plugin's product interaction, not an authority question the host is entitled to
    /// answer, so it is still presented with the switch on.
    func testAPluginsOwnConfirmDialogIsStillPresented() async throws {
        let state = PluginUIState()
        state.adopt(Self.preferencesStore())

        let asking = Task {
            try await state.request(
                kind: .confirm(title: "Delete 12 files?", detail: nil, destructive: true)
            )
        }
        try await Self.waitForPending(on: state)

        guard case .confirm = try XCTUnwrap(state.current?.kind) else {
            return XCTFail("a plugin's own confirmation must still reach the person")
        }
        state.confirmCurrent()

        let response = try await asking.value
        XCTAssertEqual(response, .confirmed(true))
    }

    // MARK: - Fixtures

    /// A store of its own per test, so one case flipping the switch cannot reach another
    /// and the process-wide `standard` defaults are left alone.
    private static func preferencesStore() -> AppPreferencesStore {
        AppPreferencesStore(
            defaults: UserDefaults(suiteName: "tenon.test.\(UUID().uuidString)")!
        )
    }

    /// A real shipped contract in each confirmation mode, compiled by the real compiler,
    /// so the request under test is the one the dispatcher would hand the authorizer.
    private static func request(
        confirmation: IntentConfirmation
    ) async throws -> IntentConfirmationRequest {
        let definitions = try CoreIntentCatalog.definitions()
        let declaration = try XCTUnwrap(
            definitions.first { $0.declaration.effects.confirmation == confirmation }
        ).declaration
        let catalog = ContractCatalog()
        let snapshot = try await catalog.register(declaration)
        let contract = try XCTUnwrap(snapshot.contract(named: declaration.name))

        return IntentConfirmationRequest(
            envelope: IntentEnvelope(
                requestID: UUID(),
                traceID: UUID(),
                parentRequestID: nil,
                name: declaration.name,
                input: .object([:]),
                caller: IntentPrincipal(
                    id: "dev.tenon.test",
                    kind: .plugin,
                    sessionRevision: 1
                ),
                scope: InvocationScope(),
                deadline: .now.advanced(by: .seconds(10)),
                target: nil,
                idempotencyKey: nil
            ),
            contract: contract,
            providerID: try ProviderID("dev.tenon.core"),
            confirmation: confirmation
        )
    }

    private static func waitForPending(
        on state: PluginUIState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 200 {
            if !state.pending.isEmpty {
                return
            }
            await Task.yield()
        }
        XCTFail("nothing was ever presented", file: file, line: line)
    }
}
