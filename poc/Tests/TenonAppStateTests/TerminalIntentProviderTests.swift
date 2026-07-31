import Foundation
import SwiftUI
@testable import TenonApp
@testable import TenonCore
@testable import TenonIntentCore
import XCTest

@MainActor
final class TerminalIntentProviderTests: XCTestCase {
    func testViewportReadReturnsOneTypedLiveObservation() async throws {
        let fixture = try makeFixture()
        fixture.surface.renderedText = "prompt"
        fixture.surface.processExited = false

        let reply = try await invoke(
            .terminalViewportRead,
            input: .object([:]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        XCTAssertEqual(
            try successValue(reply),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "text": .string("prompt"),
                "exited": .bool(false),
                "columns": .null,
                "rows": .null,
            ])
        )
    }

    func testWaitReturnsOneResultWhenConditionIsMet() async throws {
        let fixture = try makeFixture()
        let surface = fixture.surface
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            surface.processExited = true
        }

        let reply = try await invoke(
            .terminalWait,
            input: .object([
                "condition": .string("exit"),
                "timeoutMs": .integer(2_000),
            ]),
            paneID: fixture.paneID,
            bindings: fixture.bindings,
            deadline: .now.advanced(by: .seconds(3))
        )

        XCTAssertEqual(
            try successValue(reply),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "condition": .string("exit"),
                "met": .bool(true),
            ])
        )
    }

    func testWaitIsCancellationAware() async throws {
        let fixture = try makeFixture()
        let task = Task { @MainActor in
            try await self.invoke(
                .terminalWait,
                input: .object([
                    "condition": .string("exit"),
                    "timeoutMs": .integer(5_000),
                ]),
                paneID: fixture.paneID,
                bindings: fixture.bindings,
                deadline: .now.advanced(by: .seconds(6))
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled wait unexpectedly completed")
        } catch is CancellationError {
            // Expected: provider polling is structured and cancellation-aware.
        }
    }
}

private extension TerminalIntentProviderTests {
    struct Fixture {
        let paneID: UUID
        let surface: TestTerminalSurface
        let bindings: [IntentProviderBinding]
    }

    func makeFixture() throws -> Fixture {
        let store = WorkspaceStore()
        let surface = TestTerminalSurface()
        let pool = SurfacePool(backendName: "Test") { _, _ in
            surface
        }
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        let workspacePath = try XCTUnwrap(
            store.catalog.activeWorkspace?.path
        )
        _ = pool.surface(for: paneID, workspacePath: workspacePath)
        let bindings = try TerminalIntentProvider(
            store: store,
            surfaces: pool
        ).bindings()
        return Fixture(
            paneID: paneID,
            surface: surface,
            bindings: bindings
        )
    }

    func invoke(
        _ name: CoreIntentName,
        input: IntentValue,
        paneID: UUID,
        bindings: [IntentProviderBinding],
        deadline: ContinuousClock.Instant = .now.advanced(
            by: .seconds(5)
        )
    ) async throws -> IntentProviderReply {
        let intentID = try name.intentID
        let binding = try XCTUnwrap(
            bindings.first { $0.intentID == intentID }
        )
        let envelope = IntentEnvelope(
            requestID: UUID(),
            traceID: UUID(),
            parentRequestID: nil,
            name: intentID,
            input: input,
            caller: IntentPrincipal(
                id: "test:terminal-provider",
                kind: .cli,
                sessionRevision: 1
            ),
            scope: InvocationScope(paneID: paneID),
            deadline: deadline,
            target: nil,
            idempotencyKey: nil
        )
        let context = IntentProviderContext(
            requestID: envelope.requestID,
            nestedSend: { request in
                .failure(
                    error: IntentError(
                        code: .kernel(.internal),
                        details: .string(request.intentID.rawValue),
                        retryable: false,
                        retryAfterMilliseconds: nil,
                        outcome: .notStarted
                    ),
                    requestID: UUID(),
                    providerID: nil
                )
            }
        )
        return try await binding.invoke(
            envelope: envelope,
            context: context
        )
    }

    func successValue(_ reply: IntentProviderReply) throws -> IntentValue {
        guard case let .success(value) = reply else {
            XCTFail("expected success, got \(reply)")
            throw TestError.expectedSuccess
        }
        return value
    }

    enum TestError: Error {
        case expectedSuccess
    }
}

@MainActor
private final class TestTerminalSurface: TerminalSurface {
    let backendName = "Test"
    var onTitleChange: ((String) -> Void)?
    var renderedText = ""
    var processExited = false
    var commandFinishedCount = 0

    func makeView() -> AnyView {
        AnyView(EmptyView())
    }
}
