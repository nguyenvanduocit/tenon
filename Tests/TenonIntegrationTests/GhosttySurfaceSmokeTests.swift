import AppKit
import SwiftUI
import XCTest
@testable import TenonApp
import TenonCore

final class GhosttySurfaceSmokeTests: XCTestCase {
    @MainActor
    func testRealSurfaceRendersAcceptsInputResizesAndExits() throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/tenon-ghostty-pwd-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let surface = GhosttySurface(
            command: "/bin/sh",
            workingDirectory: workingDirectory
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: surface.makeView())
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        XCTAssertTrue(waitUntil(timeout: 8) {
            (surface.foregroundPID ?? 0) > 0 &&
                !surface.renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        XCTAssertFalse(surface.renderedCells.isEmpty)

        let pwdStart = "__TENON_PWD_START_\(UUID().uuidString)__"
        let pwdEnd = "__TENON_PWD_END_\(UUID().uuidString)__"
        surface.sendText(
            "printf '\\n\(pwdStart)\\n'; pwd -P; printf '\(pwdEnd)\\n'\n"
        )
        let expectedPWD = workingDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(waitUntil(timeout: 8) {
            guard let pwdOutput = text(
                between: pwdStart,
                and: pwdEnd,
                in: surface.renderedText
            ) else { return false }
            return pwdOutput.contains(expectedPWD)
        }, "expected real PTY pwd \(expectedPWD), rendered: \(surface.renderedText)")

        let initialSize = try XCTUnwrap(surface.surfaceSize)
        XCTAssertGreaterThan(initialSize.columns, 0)
        XCTAssertGreaterThan(initialSize.rows, 0)
        XCTAssertEqual(surface.appliedDisplayID, displayID(for: window.screen))

        let marker = "TENON_GHOSTTY_SMOKE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        surface.sendText("printf '\\n\(marker)\\n'\n")
        XCTAssertTrue(waitUntil(timeout: 8) {
            surface.renderedText.contains(marker)
        })

        window.setContentSize(NSSize(width: 880, height: 520))
        XCTAssertTrue(waitUntil(timeout: 5) {
            guard let current = surface.surfaceSize else { return false }
            return current.widthPixels > initialSize.widthPixels &&
                current.heightPixels > initialSize.heightPixels &&
                current.columns >= initialSize.columns &&
                current.rows >= initialSize.rows
        })

        let resizedSurface = try XCTUnwrap(surface.surfaceSize)
        XCTAssertTrue(waitForTTYSize(
            rows: resizedSurface.rows,
            columns: resizedSurface.columns,
            surface: surface,
            timeout: 5
        ))

        // Ghostty intentionally keeps very short-lived commands on an error
        // surface. Let this real shell pass that threshold so Ctrl-D exercises
        // the normal close callback used by SurfacePool.
        pumpRunLoop(for: 1)

        surface.focus()
        let controlD = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{4}",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))
        XCTAssertFalse(surface.nativeView.performKeyEquivalent(with: controlD))
        surface.nativeView.keyDown(with: controlD)
        XCTAssertTrue(waitUntil(timeout: 8) {
            surface.processExited
        }, "processExited=\(surface.processExited)")
    }

    @MainActor
    func testClipboardConfirmationHasANonBlockingDecisionSeam() {
        var requestedKind: GhosttyClipboardConfirmationKind?
        var requestedContents: String?
        var decision: Bool?
        GhosttyClipboardConfirmationPresenter.decisionHandler = { kind, contents, completion in
            requestedKind = kind
            requestedContents = contents
            completion(false)
        }
        defer {
            GhosttyClipboardConfirmationPresenter.decisionHandler = nil
        }

        GhosttyClipboardConfirmationPresenter.request(
            kind: .unsafePaste,
            contents: "dangerous\npaste",
            window: nil
        ) {
            decision = $0
        }

        XCTAssertEqual(requestedKind, .unsafePaste)
        XCTAssertEqual(requestedContents, "dangerous\npaste")
        XCTAssertEqual(decision, false)
        XCTAssertEqual(
            GhosttyClipboardConfirmationPresenter.resolution(
                approved: false,
                contents: "dangerous\npaste"
            ),
            GhosttyClipboardConfirmationResolution(contents: "", confirmed: false)
        )
    }

    @MainActor
    func testOSC52WriteDenialDoesNotChangeClipboard() {
        var requestedKind: GhosttyClipboardConfirmationKind?
        var writtenContents: String?
        GhosttyClipboardConfirmationPresenter.decisionHandler = { kind, _, completion in
            requestedKind = kind
            completion(false)
        }
        GhosttyClipboardWriter.writeHandler = {
            writtenContents = $0
        }
        defer {
            GhosttyClipboardConfirmationPresenter.decisionHandler = nil
            GhosttyClipboardWriter.writeHandler = nil
        }

        GhosttyClipboardWriter.request(
            contents: "untrusted OSC 52 text",
            requiresConfirmation: true,
            window: nil
        )

        XCTAssertEqual(requestedKind, .osc52Write)
        XCTAssertNil(writtenContents)
    }

    @MainActor
    func testSurfacePoolCreatesEachStableSlotInItsOwningWorkspace() {
        let firstID = UUID()
        let secondID = UUID()
        let firstPath = URL(fileURLWithPath: "/tmp/one", isDirectory: true)
        let secondPath = URL(fileURLWithPath: "/tmp/two", isDirectory: true)
        var requestedPaths: [URL] = []
        let pool = SurfacePool(backendName: "Test") { _, workspacePath in
            requestedPaths.append(workspacePath)
            return TestTerminalSurface(workingDirectory: workspacePath)
        }
        let first = pool.surface(for: firstID, workspacePath: firstPath)
        let second = pool.surface(for: secondID, workspacePath: secondPath)

        pool.retainOnly(Set([firstID, secondID]))

        XCTAssertTrue(first === pool.surface(
            for: firstID,
            workspacePath: secondPath
        ))
        XCTAssertTrue(second === pool.surface(
            for: secondID,
            workspacePath: firstPath
        ))
        XCTAssertEqual(
            (first as? TestTerminalSurface)?.workingDirectory,
            firstPath
        )
        XCTAssertEqual(
            (second as? TestTerminalSurface)?.workingDirectory,
            secondPath
        )
        XCTAssertEqual(requestedPaths, [firstPath, secondPath])
    }

    func testInitialWorkspacePathUsesOverrideThenMeaningfulLaunchCWDThenHome() {
        let home = URL(fileURLWithPath: "/Users/tenon", isDirectory: true)

        XCTAssertEqual(
            resolvedInitialWorkspacePath(
                environment: ["TENON_WORKSPACE_PATH": "/tmp/explicit"],
                currentDirectoryPath: "/tmp/launch",
                homeDirectory: home
            ).path,
            "/tmp/explicit"
        )
        XCTAssertEqual(
            resolvedInitialWorkspacePath(
                environment: [:],
                currentDirectoryPath: "/tmp/launch",
                homeDirectory: home
            ).path,
            "/tmp/launch"
        )
        XCTAssertEqual(
            resolvedInitialWorkspacePath(
                environment: [:],
                currentDirectoryPath: "/",
                homeDirectory: home
            ).path,
            "/Users/tenon"
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if condition() {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func waitForTTYSize(
        rows: Int,
        columns: Int,
        surface: GhosttySurface,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var attempt = 0
        repeat {
            attempt += 1
            let marker = "__TENON_SIZE_END_\(attempt)_\(UUID().uuidString)__"
            surface.sendText("stty size; printf '\(marker)\\n'\n")
            _ = waitUntil(timeout: min(0.5, deadline.timeIntervalSinceNow)) {
                ttySize(before: marker, in: surface.renderedText) != nil
            }
            if let reported = ttySize(before: marker, in: surface.renderedText),
               reported.rows == rows,
               reported.columns == columns {
                return true
            }
            pumpRunLoop(for: 0.05)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: duration)
        repeat {
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.01))
            )
        } while Date() < deadline
    }

    private func displayID(for screen: NSScreen?) -> UInt32? {
        guard let value = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] else { return nil }
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        return value as? UInt32
    }

    private func ttySize(
        before marker: String,
        in renderedText: String
    ) -> (rows: Int, columns: Int)? {
        let lines = renderedText.components(separatedBy: .newlines)
        guard let markerIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }) else { return nil }

        for line in lines[..<markerIndex].reversed() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let rows = Int(fields[0]),
                  let columns = Int(fields[1])
            else { continue }
            return (rows, columns)
        }
        return nil
    }

    private func text(
        between start: String,
        and end: String,
        in renderedText: String
    ) -> String? {
        guard let startRange = renderedText.range(of: start, options: .backwards),
              let endRange = renderedText.range(
                of: end,
                options: [],
                range: startRange.upperBound..<renderedText.endIndex
              )
        else { return nil }
        return String(renderedText[startRange.upperBound..<endRange.lowerBound])
    }
}

private final class TestTerminalSurface: TerminalSurface {
    let backendName = "Test"
    let workingDirectory: URL
    var onTitleChange: ((String) -> Void)?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func makeView() -> AnyView {
        AnyView(EmptyView())
    }
}
