import Foundation
@testable import TenonApp
import XCTest

/// T-093. Tenon is a one-window app, and the scene declaration has to say so.
///
/// This is a source fitness test rather than a hosted-window test on purpose: the defect it
/// guards is a *declaration*, not a runtime state. A `WindowGroup` puts `New Window` in the File
/// menu, and every resource behind that menu item is single-instance — one `AppComposition`, one
/// surface per slot, and a Ghostty surface that returns the same `NSView` to whoever asks. The
/// second window could therefore only be furnished by moving the first window's terminal into it.
/// Opening a real second window to prove that would mean shipping the bug to observe it.
final class MainWindowSingletonTests: XCTestCase {
    func testTheWorkspaceSceneIsASingletonWindow() throws {
        let source = try appSource(named: "TenonApp.swift")

        XCTAssertTrue(
            source.contains("Window(\"Tenon\", id: Self.mainWindowID)"),
            "the workspace scene must be a singleton Window with a stable id"
        )
        XCTAssertFalse(
            source.contains("WindowGroup"),
            """
            WindowGroup offers New Window, and a second window can only be filled by \
            reparenting the single terminal surface out of the first one
            """
        )
    }

    /// The other half: nothing may quietly re-open the multi-window door through `openWindow`
    /// on a group that does not exist.
    func testNoSceneOpensAdditionalWorkspaceWindows() throws {
        let sources = try appSourceFiles()
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                text.contains("WindowGroup"),
                "\(url.lastPathComponent) declares a WindowGroup"
            )
        }
    }

    // MARK: - Fixture

    private func appSourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TenonApp")
    }

    private func appSource(named name: String) throws -> String {
        try String(
            contentsOf: appSourceRoot().appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func appSourceFiles() throws -> [URL] {
        let root = appSourceRoot()
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(
            swiftFiles.count,
            10,
            "fixture failed to enumerate TenonApp sources — an empty scan passes vacuously"
        )
        return swiftFiles
    }
}
