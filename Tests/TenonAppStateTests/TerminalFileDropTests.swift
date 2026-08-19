import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// FC-FR-040: a row dragged out of Files and dropped on a Tenon terminal pane inserts its
/// absolute path into that pane's PTY, quoted the same way `agent.command.v1` already quotes
/// a composed command line, and never submits the line itself. These tests exercise the
/// backend-agnostic wiring `SurfacePool.surface(for:workspacePath:)` installs on every
/// materialized surface — the real AppKit drag registration on `GhosttyNSView` is not
/// constructed here, matching this file's existing practice of never building a real Ghostty
/// surface in the fast shared suite (T-135).
@MainActor
final class TerminalFileDropTests: XCTestCase {
    private var scratch: URL!
    private var slot: UUID!

    override func setUp() async throws {
        try await super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tenon-terminal-drop-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        slot = UUID()
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    func testDroppedFileArrivesAsAQuotedPathWithoutSubmitting() throws {
        let pool = makePool()
        let surface = pool.surface(for: slot, workspacePath: scratch)
        let dropped = URL(fileURLWithPath: "/tmp/needs quoting/it's here.txt")

        surface.onFileDrop?([dropped])

        XCTAssertEqual(
            (surface as? StubTerminalSurface)?.sentText,
            ["'/tmp/needs quoting/it'\\''s here.txt'"],
            "the path must be posix-quoted and carry no trailing newline"
        )
    }

    func testMultipleDroppedFilesArriveSpaceSeparatedInDropOrder() throws {
        let pool = makePool()
        let surface = pool.surface(for: slot, workspacePath: scratch)
        let first = URL(fileURLWithPath: "/tmp/a.txt")
        let second = URL(fileURLWithPath: "/tmp/b.txt")

        surface.onFileDrop?([first, second])

        XCTAssertEqual(
            (surface as? StubTerminalSurface)?.sentText,
            ["'/tmp/a.txt' '/tmp/b.txt'"]
        )
    }

    private func makePool() -> SurfacePool {
        SurfacePool(backendName: "Stub") { _, _ in StubTerminalSurface() }
    }
}
