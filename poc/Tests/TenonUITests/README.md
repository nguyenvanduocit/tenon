# TenonUITests — end-to-end (XCUITest) contract

Black-box tests that launch the real `Tenon.app` and drive it like a user: keyboard
shortcuts (`⌘T` / `⌘D` / `⌘W`) and a pointer drag on the spatial canvas. They are the only
tests that cover the **gesture → core wiring** a headless `TenonCoreTests` can't reach.
Everything about *what* a split/move does stays unit-tested in the core; these prove the
shell is plugged into it.

## Runtime requirement

The app and accessibility contract are wired into the default `Tenon` scheme. XCUITest
requires a logged-in macOS GUI session with Accessibility automation available; a pure
headless shell can still run the three unit-test bundles.

## The identifier contract

The shell publishes these identifiers from the SwiftUI/AppKit views in `Sources/TenonApp`.
`TenonWorkspaceFlowUITests.A11y` is the machine-readable copy — keep both in sync.

| Identifier      | Put it on…                                   | Why the test needs it |
|-----------------|----------------------------------------------|-----------------------|
| `tenon.tab`     | each tab chip in the tab bar (same id on all)| counts tabs — `⌘T` / the `+` launcher must raise the count |
| `tenon.newTab`  | the `+` launcher button                      | mouse-driven "create" path, distinct from the shortcut |
| `tenon.launcher.row.<commandID>` | each row in the `+` launcher popover | proves the popover projects plugin-declared launcher intents, and that clicking one invokes that plugin |
| `tenon.canvas`  | the active tab's spatial-canvas container    | launch/readiness anchor; scopes slot lookups |
| `tenon.slot`    | each slot view on the canvas (same id on all)| counts slots — split/close change the count; drag reorders them |

### Two extra requirements for `tenon.slot`

- **Addressable as one element.** A slot wraps a terminal `NSView`; wrap the slot in a
  container that is an accessibility element, e.g. `.accessibilityElement(children: .contain)`
  alongside the identifier, so `slots.element(boundBy:)` resolves to the slot, not its guts.
- **Expose order/identity via `accessibilityValue`.** Each value contains the stable slot UUID
  and its current `x,y,width,height` grid rectangle, so a move or swap is observable from the
  accessibility tree.

## Running

```bash
cd poc
xcodegen generate                       # regenerates Tenon.xcodeproj from project.yml
xcodebuild test -project Tenon.xcodeproj -scheme Tenon \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TenonUITests
```

`-only-testing:TenonUITests` runs just this bundle. Drop it to run the whole suite
(`TenonCoreTests` + `TenonAppTests` + `TenonIntegrationTests` + `TenonUITests`).

UI tests need a real GUI login session (a window server) — they cannot run from a pure
headless shell. That is the boundary the CLAUDE.md verification note draws: `swift test`
stays the fast headless bar; XCUITest is the deliberately-small layer for what only a window
can prove.

## The drag test, specifically

`testDraggingASlotOntoAnotherRearrangesTheCanvas` is the flakiest by nature. Good news: the
canvas uses a **custom pointer drag** (`SpatialCanvasInteractionCoordinator`: beginMove →
update → finish), not SwiftUI `.draggable`/`.dropDestination`, and a plain mouse-down/move/up
drives that far more reliably than a native drag session. The test grabs the moving slot at
an absolute 10-point offset from its top edge — safely inside the 28-point header where
`hitRegion == .header` — and press-drags onto the target's centre. If it's unstable, lengthen
the press and add intermediate `press(forDuration:thenDragTo:)` hops so the pointer path
crosses the coordinator's move threshold.
