# T-035: Handled input must not trigger the macOS system beep
> Actions such as Backspace work, but macOS also plays the alert sound associated with an
> input event that no responder accepted.

- **priority**: medium
- **effort**: S
- **owner**: term_45fe10d9-19fe-4322-a64a-2fa35f49d401 (Orca worker, dispatch ctx_1164bb12110c)

## Owner / files (agent lock)
RELEASED 23:46 — done. All files free.

## Reproduction
1. Open an app surface that accepts keyboard or button-driven input.
2. Trigger Backspace; check other controls that use the same input path.
3. Observe that the requested action happens and the macOS system alert sound also plays.

## Actual
- The app accepts and performs the action.
- macOS plays an error/unhandled-input sound at the same time.

## Expected
- A handled action produces no system alert sound.
- Backspace and the other affected controls retain their current functional behaviour.

## Criteria
- [x] Record a minimal reliable reproduction and the complete set of controls known to use
      the affected event path
- [x] Identify why the responder/event path still reaches the system beep after Tenon has
      handled the action
- [x] Consume or route only the affected handled events; do not suppress legitimate system
      feedback for truly invalid input
- [x] Add focused regression coverage where the event-routing rule can be tested
- [ ] Verify Backspace and every other reproduced control manually in the running app
      — **human-verify-only** (an audible beep cannot be asserted from a headless shell);
      see "What a human still confirms" below.

## Resolution (worker term_45fe10d9, 23:46)

**Defect type (b) — an `interpretKeyEvents` selector dying unimplemented.**
`GhosttySurface.swift:816`: `GhosttyNSView.keyDown` calls `interpretKeyEvents([event])`
so AppKit can translate dead keys/IME into `insertText`. For Backspace (and cursor
moves, Return, Escape) the input context produces **no text** — it calls
`doCommandBySelector(deleteBackward:)` etc. instead. `GhosttyNSView` conforms to
`NSTextInputClient` "minimal" (`:1123`) and implemented none of those selectors and no
`doCommand(by:)`, so NSResponder's default forwarded each one up the responder chain,
where it died unaccepted → NSBeep. The same press still reached the PTY through the
`accumulated.isEmpty` branch (`:822-825`), so the action worked **and** beeped.
It is defect (b), not (a): `keyDown` never calls `super` when a surface exists, so the
raw event does not travel — only the derived selector did.

**Fix** (`GhosttySurface.swift:838-845`): `override func doCommand(by:) {}` on
`GhosttyNSView` only. This is not a blanket beep-swallow: every press that reaches this
view's `keyDown` is delivered to the PTY, so its input-context selectors are
already-handled input by construction. Every other view keeps NSResponder's default —
`testAPlainViewStillForwardsUnhandledSelectorsUpTheChain` pins exactly that, so truly
unhandled input keeps its system feedback.

**The complete set of controls on this event path**: `interpretKeyEvents` has exactly
one call site in `Sources` (this view). Surveyed the rest and each is clean by a
different mechanism: `SpatialCanvasView.keyDown:349-354` consumes Escape only when a
gesture cancels (early return) and otherwise correctly lets the event travel;
`PaletteOverlay`/`LauncherMenu` use SwiftUI `.onKeyPress` returning `.handled`, a
focused `TextField` (owns Backspace), `.onSubmit`, and Escape via a `.cancelAction`
keyboard shortcut (`PaletteOverlay.swift:61-73`); the source editor is STTextView,
a full text view that implements the standard key-binding selectors; the remaining
`NSEvent` overrides (WindowChrome, DragRouter, PluginRowsView, GhosttySurface mouse
paths) are mouse-only.

**Regression coverage**: NEW `Tests/TenonAppStateTests/TerminalKeyHandlingTests.swift`
(a SwiftPM target `swift test` really builds). The headless seam: a recording parent
view observes whether a command selector escapes the child — escape *is* the beep path.
RED first, for the right reason (all 4 selectors escaped and were recorded), then green
after the one-line override. The companion test proves a plain NSView still forwards,
so the harness cannot pass vacuously and the fix cannot silently widen.

**Evidence**: `swift build` exit 0; full `swift test` **659 tests / 0 failures**
(coordinator baseline 653/0 + these 2 + 4 landed by parallel workers);
`TerminalKeyHandlingTests` 2/2.

**What a human still confirms**: in the running app, press Backspace (and arrows,
Escape, Return) in a focused terminal pane — the shell edits as before with **no**
alert sound; then confirm a key genuinely handled by nothing (e.g. a bare F-key in an
empty non-terminal context) still beeps, proving system feedback survives.
