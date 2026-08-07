import AppKit
import XCTest
@testable import TenonApp

/// AppKit plays the system beep when a key event's command selector travels the
/// responder chain and dies unaccepted. The terminal view hands every key press it
/// receives to the PTY (`keyDown` → `ghostty_surface_key`), so the selectors
/// `interpretKeyEvents` derives from those same presses — `deleteBackward:` for
/// Backspace, cursor moves, newline — are already-handled input and must not travel
/// further; letting them escape is what made a working Backspace also beep.
@MainActor
final class TerminalKeyHandlingTests: XCTestCase {
    /// Records any command selector a child view lets escape, and swallows it so the
    /// test process never audibly beeps.
    private final class SelectorRecordingView: NSView {
        var received: [Selector] = []

        override func doCommand(by selector: Selector) {
            received.append(selector)
        }
    }

    func testInputContextSelectorsDieInsideTheTerminalView() {
        let chain = SelectorRecordingView()
        let terminal = GhosttyNSView()
        chain.addSubview(terminal)

        for selector in [
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.cancelOperation(_:)),
        ] {
            terminal.doCommand(by: selector)
        }

        XCTAssertEqual(
            chain.received, [],
            "A selector that escapes the terminal view dies unaccepted at the end of "
                + "the responder chain, where AppKit beeps for a key the PTY already handled."
        )
    }

    /// The rule is the terminal view's, not the responder chain's: a plain view still
    /// forwards what it does not handle, so truly unhandled input keeps its system
    /// feedback — and this proves the recorder would have caught an escape above.
    func testAPlainViewStillForwardsUnhandledSelectorsUpTheChain() {
        let chain = SelectorRecordingView()
        let plain = NSView(frame: .zero)
        chain.addSubview(plain)

        plain.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(chain.received, [#selector(NSResponder.deleteBackward(_:))])
    }
}
