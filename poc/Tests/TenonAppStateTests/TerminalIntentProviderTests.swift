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

    /// The whole reason this intent exists. `terminal.run.v1` reuses a terminal in scope,
    /// so a plugin wanting a pane of its own had no way to ask for one. If this ever
    /// starts reusing, the feature is gone and nothing else would notice.
    func testOpenAlwaysCreatesANewPaneEvenWhenAUsableTerminalIsInScope() async throws {
        let fixture = try makeMultiPaneFixture()
        let tabsBefore = fixture.store.catalog.activeWorkspace?.tabs.count

        let reply = try await invoke(
            .terminalOpen,
            input: .object([:]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        guard case let .object(fields) = try successValue(reply),
              case let .string(rawPaneID)? = fields["paneID"]
        else {
            return XCTFail("expected a paneID in the reply")
        }
        let created = try XCTUnwrap(UUID(uuidString: rawPaneID))

        XCTAssertNotEqual(
            created,
            fixture.paneID,
            "opened into the pane that was already in scope instead of a new one"
        )
        XCTAssertEqual(
            fixture.store.catalog.activeWorkspace?.tabs.count,
            (tabsBefore ?? 0) + 1
        )
        XCTAssertEqual(
            fixture.store.catalog.slot(id: created)?.content,
            .terminal
        )
    }

    /// The command has to reach the pane that was created, and it has to survive the gap
    /// before that pane has a surface — a tab opened this instant materialises on the next
    /// render, so a direct write would land in nothing.
    func testOpenDeliversItsCommandToTheNewPaneOnceThatPaneMaterialises() async throws {
        let fixture = try makeMultiPaneFixture()

        let reply = try await invoke(
            .terminalOpen,
            input: .object(["command": .string("claude \"do T-040\"")]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )
        guard case let .object(fields) = try successValue(reply),
              case let .string(rawPaneID)? = fields["paneID"],
              let created = UUID(uuidString: rawPaneID)
        else {
            return XCTFail("expected a paneID in the reply")
        }

        // Nothing has rendered yet, so the new pane has no surface and the text is queued.
        XCTAssertNil(fixture.registry.bySlot[created])

        _ = fixture.pool.surface(
            for: created,
            workspacePath: fixture.workspacePath
        )

        XCTAssertEqual(
            fixture.registry.bySlot[created]?.sentText,
            "claude \"do T-040\"\n"
        )
        XCTAssertEqual(
            fixture.registry.bySlot[fixture.paneID]?.sentText,
            "",
            "the pane that was in scope must not receive the command"
        )
    }

    func testOpenWithoutACommandJustOpensAShell() async throws {
        let fixture = try makeMultiPaneFixture()

        let reply = try await invoke(
            .terminalOpen,
            input: .object([:]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )
        guard case let .object(fields) = try successValue(reply),
              case let .string(rawPaneID)? = fields["paneID"],
              let created = UUID(uuidString: rawPaneID)
        else {
            return XCTFail("expected a paneID in the reply")
        }
        _ = fixture.pool.surface(
            for: created,
            workspacePath: fixture.workspacePath
        )

        XCTAssertEqual(fixture.registry.bySlot[created]?.sentText, "")
    }

    /// The shell starts where the caller said, decided before the pane has a surface —
    /// there is no moving a shell that is already running.
    func testOpenStartsTheShellInTheRequestedDirectory() async throws {
        let fixture = try makeMultiPaneFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let reply = try await invoke(
            .terminalOpen,
            input: .object(["workingDirectory": .string(directory.path)]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )
        guard case let .object(fields) = try successValue(reply),
              case let .string(rawPaneID)? = fields["paneID"],
              let created = UUID(uuidString: rawPaneID)
        else {
            return XCTFail("expected a paneID in the reply")
        }

        XCTAssertEqual(
            fixture.pool.paneDirectory(for: created)?.cwd.standardizedFileURL,
            directory.standardizedFileURL
        )
    }

    /// Accepting a directory that does not exist would start the shell somewhere else and
    /// never tell the caller its command ran in the wrong place.
    func testOpenRefusesAWorkingDirectoryThatIsNotAnExistingDirectory() async throws {
        let fixture = try makeMultiPaneFixture()
        let tabsBefore = fixture.store.catalog.activeWorkspace?.tabs.count

        for candidate in [
            "/definitely/not/here-\(UUID().uuidString)",
            "relative/path",
            FileManager.default.temporaryDirectory
                .appendingPathComponent("a-file-\(UUID().uuidString)").path,
        ] {
            let reply = try await invoke(
                .terminalOpen,
                input: .object(["workingDirectory": .string(candidate)]),
                paneID: fixture.paneID,
                bindings: fixture.bindings
            )
            guard case .failure = reply else {
                return XCTFail("accepted \(candidate)")
            }
        }

        XCTAssertEqual(
            fixture.store.catalog.activeWorkspace?.tabs.count,
            tabsBefore,
            "a refused request must not leave a tab behind"
        )
    }

    /// The point of the intent: an agent reaches output that scrolled off the screen.
    /// `terminal.viewport.read.v1` can only ever answer with the visible rows, so a
    /// command that printed more than a window's worth was previously unreachable.
    func testScrollbackReadReturnsHistoryTheViewportCannotShow() async throws {
        let fixture = try makeFixture()
        fixture.surface.renderedText = "line-8\nline-9"
        fixture.surface.scrollbackLines = (0 ..< 10).map { "line-\($0)" }

        let reply = try await invoke(
            .terminalScrollbackRead,
            input: .object(["maxLines": .integer(4)]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        XCTAssertEqual(
            try successValue(reply),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "text": .string("line-0\nline-1\nline-2\nline-3"),
                "cursor": .string("4:10"),
                "invalidated": .bool(false),
                "totalRows": .integer(10),
            ])
        )
    }

    /// Walking the whole buffer, which is what "paging" has to actually deliver: every
    /// row once, in order, ending with a null cursor rather than by the caller giving up.
    func testPagingWalksTheEntireScrollbackAndThenReportsTheEnd() async throws {
        let fixture = try makeFixture()
        fixture.surface.scrollbackLines = (0 ..< 10).map { "line-\($0)" }

        var collected: [String] = []
        var cursor: IntentValue = .null
        var pages = 0

        while pages < 10 {
            pages += 1
            var input: [String: IntentValue] = ["maxLines": .integer(4)]
            if case let .string(raw) = cursor {
                input["cursor"] = .string(raw)
            }
            let value = try successValue(
                try await invoke(
                    .terminalScrollbackRead,
                    input: .object(input),
                    paneID: fixture.paneID,
                    bindings: fixture.bindings
                )
            )
            guard case let .object(fields) = value,
                  case let .string(text)? = fields["text"]
            else {
                return XCTFail("unexpected reply shape: \(value)")
            }
            if !text.isEmpty {
                collected.append(contentsOf: text.components(separatedBy: "\n"))
            }
            cursor = fields["cursor"] ?? .null
            if cursor == .null { break }
        }

        XCTAssertEqual(collected, (0 ..< 10).map { "line-\($0)" })
        XCTAssertEqual(pages, 3)
    }

    /// The honest half of the contract. The emulator gives no stable row identity, so a
    /// cursor whose scrollback has changed size is refused rather than answered with rows
    /// that have shifted underneath it.
    func testACursorIsRefusedOnceTheScrollbackHasChangedSize() async throws {
        let fixture = try makeFixture()
        fixture.surface.scrollbackLines = (0 ..< 10).map { "line-\($0)" }

        let first = try successValue(
            try await invoke(
                .terminalScrollbackRead,
                input: .object(["maxLines": .integer(4)]),
                paneID: fixture.paneID,
                bindings: fixture.bindings
            )
        )
        guard case let .object(fields) = first,
              case let .string(cursor)? = fields["cursor"]
        else {
            return XCTFail("expected a continuation cursor")
        }

        // The shell writes two more lines before the caller asks for page two.
        fixture.surface.scrollbackLines = (0 ..< 12).map { "line-\($0)" }

        let second = try await invoke(
            .terminalScrollbackRead,
            input: .object([
                "maxLines": .integer(4),
                "cursor": .string(cursor),
            ]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        XCTAssertEqual(
            try successValue(second),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "text": .string(""),
                "cursor": .null,
                "invalidated": .bool(true),
                "totalRows": .integer(12),
            ]),
            "a moved scrollback must say so, not hand back rows from another position"
        )
    }

    func testScrollbackReadRefusesACursorItDidNotIssue() async throws {
        let fixture = try makeFixture()
        fixture.surface.scrollbackLines = ["only-line"]

        let reply = try await invoke(
            .terminalScrollbackRead,
            input: .object(["cursor": .string("not-a-cursor")]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        guard case .failure = reply else {
            return XCTFail("expected a typed refusal, got \(reply)")
        }
    }

    func testScrollbackPageSizeIsBoundedByTheContract() async throws {
        let fixture = try makeFixture()
        fixture.surface.scrollbackLines = ["a", "b"]

        let reply = try await invoke(
            .terminalScrollbackRead,
            input: .object([
                "maxLines": .integer(
                    Int64(
                        CoreIntentPayloadPolicy.maximumScrollbackPageLines + 1
                    )
                ),
            ]),
            paneID: fixture.paneID,
            bindings: fixture.bindings
        )

        guard case .failure = reply else {
            return XCTFail("expected the page bound to refuse, got \(reply)")
        }
    }

    /// `--for command-finished` is the OSC 133 condition: the shell's semantic-prompt
    /// marker (`GhosttySurface.swift:396`) bumps a count, and the wait is met when that
    /// count rises above the one read when the wait started. Baseline-relative is the
    /// whole point — an agent asking "tell me when the next command finishes" must not be
    /// answered by a command that finished before it asked.
    func testWaitForCommandFinishedIsMetWhenTheShellReportsAFinishedCommand() async throws {
        let fixture = try makeFixture()
        let surface = fixture.surface
        surface.commandFinishedCount = 7
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            surface.commandFinishedCount = 8
        }

        let reply = try await invoke(
            .terminalWait,
            input: .object([
                "condition": .string("command-finished"),
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
                "condition": .string("command-finished"),
                "met": .bool(true),
            ])
        )
    }

    /// The companion to the test above, and the one that actually pins *baseline-relative*:
    /// a pane that has already run six commands must not satisfy a wait that arrived after
    /// them. Without this, reading the count against zero instead of against the count at
    /// wait time would still pass the positive case, and every `wait --for command-finished`
    /// would return instantly on any pane with history.
    func testWaitForCommandFinishedIgnoresCommandsThatFinishedBeforeTheWaitBegan() async throws {
        let fixture = try makeFixture()
        fixture.surface.commandFinishedCount = 6

        let reply = try await invoke(
            .terminalWait,
            input: .object([
                "condition": .string("command-finished"),
                "timeoutMs": .integer(500),
            ]),
            paneID: fixture.paneID,
            bindings: fixture.bindings,
            deadline: .now.advanced(by: .seconds(3))
        )

        XCTAssertEqual(
            try successValue(reply),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "condition": .string("command-finished"),
                "met": .bool(false),
            ])
        )
    }

    /// A shell that dies mid-command emits no finish marker, so the count never rises.
    /// Without the `processExited` escape (`TerminalIntentProvider.swift:262-270`) the
    /// caller would block for the whole timeout on a pane that can no longer answer.
    /// The assertion that makes this test load-bearing is the elapsed time: it separates
    /// "gave up because the process died" from "gave up because the timeout expired".
    func testWaitForCommandFinishedStopsWhenTheShellDiesWithoutFinishingTheCommand() async throws {
        let fixture = try makeFixture()
        let surface = fixture.surface
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            surface.processExited = true
        }

        let clock = ContinuousClock()
        let started = clock.now
        let reply = try await invoke(
            .terminalWait,
            input: .object([
                "condition": .string("command-finished"),
                "timeoutMs": .integer(30_000),
            ]),
            paneID: fixture.paneID,
            bindings: fixture.bindings,
            deadline: .now.advanced(by: .seconds(31))
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(
            try successValue(reply),
            .object([
                "paneID": .string(fixture.paneID.uuidString),
                "condition": .string("command-finished"),
                "met": .bool(false),
            ])
        )
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "the exit escape must answer immediately, not sit out the 30 s timeout"
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

    struct MultiPaneFixture {
        let paneID: UUID
        let store: WorkspaceStore
        let pool: SurfacePool
        let registry: SurfaceRegistry
        let workspacePath: URL
        let bindings: [IntentProviderBinding]
    }

    func makeMultiPaneFixture() throws -> MultiPaneFixture {
        let store = WorkspaceStore()
        let registry = SurfaceRegistry()
        let pool = SurfacePool(backendName: "Test") { slotID, _ in
            registry.surface(for: slotID)
        }
        let paneID = try XCTUnwrap(store.catalog.activeSlotID)
        let workspacePath = try XCTUnwrap(store.catalog.activeWorkspace?.path)
        // The starting pane is materialised, so it is a terminal that `terminal.run.v1`
        // would happily reuse — which is exactly the condition `terminal.open.v1` must
        // refuse to reuse.
        _ = pool.surface(for: paneID, workspacePath: workspacePath)
        let bindings = try TerminalIntentProvider(
            store: store,
            surfaces: pool
        ).bindings()
        return MultiPaneFixture(
            paneID: paneID,
            store: store,
            pool: pool,
            registry: registry,
            workspacePath: workspacePath,
            bindings: bindings
        )
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
    var scrollbackLines: [String] = []
    var processExited = false
    var commandFinishedCount = 0
    /// Everything the host delivered to this pane's PTY. The protocol's default discards,
    /// which would let a test asserting delivery pass without anything being delivered.
    var sentText = ""

    func makeView() -> AnyView {
        AnyView(EmptyView())
    }

    func sendText(_ text: String) {
        sentText += text
    }
}

/// Hands out a distinct surface per slot and remembers them, so a test can say *which*
/// pane received a command — the single shared stub the other fixture uses cannot.
@MainActor
private final class SurfaceRegistry {
    var bySlot: [UUID: TestTerminalSurface] = [:]

    func surface(for slotID: UUID) -> TestTerminalSurface {
        if let existing = bySlot[slotID] { return existing }
        let created = TestTerminalSurface()
        bySlot[slotID] = created
        return created
    }
}
