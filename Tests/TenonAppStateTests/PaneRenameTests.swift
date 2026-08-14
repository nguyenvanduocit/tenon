import Darwin
import Foundation
import XCTest
@testable import TenonApp
import TenonCore

@MainActor
final class PaneRenameTests: XCTestCase {
    func testClaudeInvocationIsOneTurnHaikuAndRequiresStructuredJSON() {
        let arguments = CompanionClaudeAdapter.arguments(
            model: "haiku",
            outputSchema: PaneTitleCompanionTask.outputSchema
        )

        XCTAssertEqual(arguments.first, "-p")
        XCTAssertEqual(value(after: "--model", in: arguments), "haiku")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "json")
        XCTAssertEqual(value(after: "--max-turns", in: arguments), "1")
        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(value(after: "--tools", in: arguments), "")
        XCTAssertNotNil(value(after: "--json-schema", in: arguments))
    }

    func testClaudeJSONParserAcceptsSchemaOutputAndRejectsProse() throws {
        let output = try CompanionClaudeAdapter.structuredOutput(
            from: Data(#"{"structured_output":{"title":"API failures"}}"#.utf8)
        )
        XCTAssertEqual(
            try PaneTitleCompanionTask.parseTitle(from: output),
            "API failures"
        )
        XCTAssertThrowsError(
            try CompanionClaudeAdapter.structuredOutput(from: Data("API failures".utf8))
        )
    }

    func testCodexUsesJSONEventsAndAcceptsOnlyTheAgentMessageChannel() throws {
        let schemaURL = URL(fileURLWithPath: "/tmp/schema.json")
        let arguments = CompanionCodexAdapter.arguments(
            model: "gpt-5.4",
            schemaURL: schemaURL
        )
        XCTAssertEqual(arguments.first, "exec")
        XCTAssertTrue(arguments.contains("--json"))
        XCTAssertEqual(value(after: "--output-schema", in: arguments), schemaURL.path)
        XCTAssertFalse(arguments.contains("--output-last-message"))

        let events = Data(
            """
            {"type":"thread.started","thread_id":"one"}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"title\\":\\"API failures\\"}"}}
            """.utf8
        )
        let output = try CompanionCodexAdapter.structuredOutput(from: events)
        XCTAssertEqual(try PaneTitleCompanionTask.parseTitle(from: output), "API failures")
        XCTAssertThrowsError(
            try CompanionCodexAdapter.structuredOutput(
                from: Data(#"{"title":"terminal-looking text is not an event"}"#.utf8)
            )
        )
    }

    func testCodexGeneratorReadsItsJSONLEventChannelEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-codex-pane-title-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"title\\":\\"JSON channel title\\"}"}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let processOutput = try await CompanionCodexAdapter.run(
            executableURL: executable,
            model: nil,
            prompt: PaneTitleCompanionTask.prompt(for: PaneRenameBrief(
                currentTitle: "Shell",
                kind: "terminal",
                location: directory.path,
                excerpt: "swift test"
            )),
            outputSchema: PaneTitleCompanionTask.outputSchema,
            workingDirectoryURL: directory
        )
        let structured = try CompanionCodexAdapter.structuredOutput(from: processOutput.stdout)
        let title = try PaneTitleCompanionTask.parseTitle(from: structured)

        XCTAssertEqual(title, "JSON channel title")
    }

    func testPromptMarksPaneContentUntrustedAndBoundsTheBrief() async {
        let longContent = String(repeating: "x", count: PaneRenameBrief.maximumExcerptBytes * 2)
        let slot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let brief = await PaneRenameBrief.make(
            slot: slot,
            currentTitle: "Shell",
            workspacePath: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            terminalExcerpt: longContent
        )
        let prompt = LiveCompanionStructuredOutputRunner.composedPrompt(
            taskPrompt: PaneTitleCompanionTask.prompt(for: brief),
            customPrompt: "Prefer Vietnamese names"
        )

        XCTAssertLessThanOrEqual(brief.excerpt.utf8.count, PaneRenameBrief.maximumExcerptBytes)
        XCTAssertTrue(prompt.contains("untrusted data"))
        XCTAssertTrue(prompt.contains("BEGIN UNTRUSTED PANE CONTENT"))
        XCTAssertTrue(prompt.contains("Prefer Vietnamese names"))
        XCTAssertTrue(prompt.contains("BEGIN COMPANION PREFERENCES"))
    }

    func testRemovingPaneCancelsGenerationAndClearsThatPanesTitleState() async throws {
        let probe = PaneRenameCancellationProbe()
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let coordinator = PaneRenameCoordinator(
            store: store,
            pool: pool,
            generator: HangingPaneTitleGenerator(probe: probe)
        )
        let slotID = try XCTUnwrap(store.catalog.activeSlotID)

        coordinator.beginAI(slotID: slotID, currentTitle: "Shell")
        XCTAssertEqual(coordinator.phase(for: slotID), .generating)
        for _ in 0..<100 {
            if await probe.didStart { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let didStart = await probe.didStart
        XCTAssertTrue(didStart, "the test must observe the fake generator before cancelling it")
        coordinator.retainOnly([])

        for _ in 0..<100 {
            if await probe.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let wasCancelled = await probe.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertNil(coordinator.phase(for: slotID))
        XCTAssertNil(store.catalog.slot(id: slotID)?.customTitle)
    }

    /// The whole point of the change: an AI rename is reported by the pane that is being
    /// renamed, so nothing above the pane is presented and the pane keeps its own chrome.
    func testGeneratingIsReportedOnThePaneTitleInsteadOfAModal() throws {
        let generating = PaneRenameChrome.make(
            phase: .generating,
            contentTitle: "Ghostty — shell",
            contentGlyph: ">_"
        )

        XCTAssertEqual(generating.title, PaneRenameChrome.generatingTitle)
        XCTAssertFalse(generating.isEditable)
        XCTAssertEqual(generating.emphasis, .amber)
        // The pane keeps saying what it IS while it is being named; the state is carried by
        // the words and their colour, not by a 9-point symbol nobody can resolve.
        XCTAssertEqual(generating.glyph, ">_")
        // Static and single-width, so reporting a state never re-solves the header strip.
        XCTAssertEqual(PaneRenameChrome.failedGlyph.count, 1)

        let idle = PaneRenameChrome.make(
            phase: nil,
            contentTitle: "Ghostty — shell",
            contentGlyph: ">_"
        )
        XCTAssertEqual(idle.title, "Ghostty — shell")
        XCTAssertEqual(idle.glyph, ">_")
        XCTAssertNil(idle.tooltip)
    }

    func testAFailedGenerationSaysSoOnTheTitleAndThenClearsItself() async throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let coordinator = PaneRenameCoordinator(
            store: store,
            pool: pool,
            generator: FailingPaneTitleGenerator(),
            failureLinger: .milliseconds(40)
        )
        let slotID = try XCTUnwrap(store.catalog.activeSlotID)

        coordinator.beginAI(slotID: slotID, currentTitle: "Shell")
        var failure: PaneRenamePhase?
        for _ in 0..<200 {
            if case .failed = coordinator.phase(for: slotID) {
                failure = coordinator.phase(for: slotID)
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let reason = try XCTUnwrap(
            {
                if case .failed(let reason) = failure { return reason }
                return nil
            }() as String?
        )
        let chrome = PaneRenameChrome.make(
            phase: .failed(reason: reason),
            contentTitle: "Ghostty — shell",
            contentGlyph: ">_"
        )
        XCTAssertEqual(chrome.title, PaneRenameChrome.failedTitle)
        XCTAssertEqual(chrome.tooltip, reason)
        XCTAssertEqual(chrome.emphasis, .red)
        XCTAssertFalse(chrome.isEditable)

        for _ in 0..<200 {
            if coordinator.phase(for: slotID) == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(
            coordinator.phase(for: slotID),
            "a failure clears itself; nothing is left for the operator to dismiss"
        )
        XCTAssertNil(store.catalog.slot(id: slotID)?.customTitle)
    }

    func testManualRenameIsEditedOnTheTitleAndCommitsThroughTheOneMutation() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let coordinator = PaneRenameCoordinator(store: store, pool: pool, generator: nil)
        let slotID = try XCTUnwrap(store.catalog.activeSlotID)

        coordinator.beginManual(slotID: slotID, currentTitle: "Ghostty — shell")
        XCTAssertEqual(coordinator.phase(for: slotID), .editing(draft: "Ghostty — shell"))
        let editing = PaneRenameChrome.make(
            phase: .editing(draft: "Ghostty — shell"),
            contentTitle: "Ghostty — shell",
            contentGlyph: ">_"
        )
        XCTAssertTrue(editing.isEditable)
        XCTAssertEqual(editing.title, "Ghostty — shell")

        coordinator.commitManual(slotID: slotID, to: "  API failures  ")
        XCTAssertEqual(store.catalog.slot(id: slotID)?.customTitle, "API failures")
        XCTAssertNil(coordinator.phase(for: slotID))

        coordinator.beginManual(slotID: slotID, currentTitle: "API failures")
        coordinator.commitManual(slotID: slotID, to: "   ")
        XCTAssertNil(
            store.catalog.slot(id: slotID)?.customTitle,
            "an emptied field restores the automatic content title"
        )
        XCTAssertNil(coordinator.phase(for: slotID))

        coordinator.beginManual(slotID: slotID, currentTitle: "Ghostty — shell")
        coordinator.cancel(slotID: slotID)
        XCTAssertNil(coordinator.phase(for: slotID))
        XCTAssertNil(store.catalog.slot(id: slotID)?.customTitle)
    }

    /// Two panes may be naming themselves at once, and one pane's teardown is not the
    /// other's: without a modal there is no single "current" rename to be stolen.
    func testEachPaneOwnsItsOwnRenameState() async throws {
        let probe = PaneRenameCancellationProbe()
        let store = WorkspaceStore(catalog: WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        let pool = SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
        let coordinator = PaneRenameCoordinator(
            store: store,
            pool: pool,
            generator: HangingPaneTitleGenerator(probe: probe)
        )
        let first = try XCTUnwrap(store.catalog.activeSlotID)
        store.splitSlot(first, .horizontal)
        let second = try XCTUnwrap(
            store.catalog.activeWorkspace?.activeTab?.slots.map(\.id).first { $0 != first }
        )

        coordinator.beginAI(slotID: first, currentTitle: "Shell")
        coordinator.beginAI(slotID: second, currentTitle: "Tests")
        XCTAssertEqual(coordinator.phase(for: first), .generating)
        XCTAssertEqual(coordinator.phase(for: second), .generating)

        coordinator.retainOnly([second])
        XCTAssertNil(coordinator.phase(for: first))
        XCTAssertEqual(
            coordinator.phase(for: second),
            .generating,
            "a live pane keeps naming itself when another pane dies"
        )
    }

    func testCancellingGeneratorTerminatesARealSubprocess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-pane-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let brief = PaneRenameBrief(
            currentTitle: "Shell",
            kind: "terminal",
            location: "/tmp/project",
            excerpt: "swift test"
        )

        let task = Task {
            try await CompanionClaudeAdapter.run(
                executableURL: executable,
                model: "haiku",
                prompt: PaneTitleCompanionTask.prompt(for: brief),
                outputSchema: PaneTitleCompanionTask.outputSchema,
                workingDirectoryURL: directory
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled rename must not wait for or accept subprocess output")
        } catch is CancellationError {
            // The subprocess termination is observed through the generator's cancellation result.
        }
    }

    func testCompanionRunnerSurvivesAChildClosingStandardInput() async throws {
        let output = try await CompanionProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 0<&-; sleep 0.05; exit 0"],
            prompt: String(repeating: "x", count: 64 << 10),
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )

        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testCancellingCompanionKillsAProcessGroupThatIgnoresTerm() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-stubborn-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentPIDFile = directory.appendingPathComponent("parent-pid")
        let childPIDFile = directory.appendingPathComponent("child-pid")
        let script = """
        trap '' TERM
        (trap '' TERM; while :; do sleep 1; done) &
        echo $$ > "$1"
        echo $! > "$2"
        while :; do sleep 1; done
        """
        let task = Task {
            try await CompanionProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", script, "tenon-stubborn-companion",
                    parentPIDFile.path, childPIDFile.path,
                ],
                prompt: "",
                workingDirectoryURL: directory
            )
        }

        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: childPIDFile.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let parentPID = try processID(from: parentPIDFile)
        let childPID = try processID(from: childPIDFile)
        let cancelledAt = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled Companion process must not produce output")
        } catch is CancellationError {
            // Expected after the whole process group has been retired.
        }

        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(1))
        let parentDisappeared = await processDisappeared(parentPID)
        let childDisappeared = await processDisappeared(childPID)
        XCTAssertTrue(parentDisappeared)
        XCTAssertTrue(childDisappeared)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func processID(from file: URL) throws -> pid_t {
        let value = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    private func processDisappeared(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) < 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor PaneRenameCancellationProbe {
    private(set) var didStart = false
    private(set) var wasCancelled = false
    func recordStart() { didStart = true }
    func recordCancellation() { wasCancelled = true }
}

private struct FailingPaneTitleGenerator: PaneTitleGenerating {
    func generateTitle(from brief: PaneRenameBrief) async throws -> String {
        throw CompanionTaskFailure.unavailable
    }
}

private struct HangingPaneTitleGenerator: PaneTitleGenerating {
    let probe: PaneRenameCancellationProbe

    func generateTitle(from brief: PaneRenameBrief) async throws -> String {
        await probe.recordStart()
        do {
            try await Task.sleep(for: .seconds(30))
            return "Unexpected"
        } catch {
            await probe.recordCancellation()
            throw error
        }
    }
}
