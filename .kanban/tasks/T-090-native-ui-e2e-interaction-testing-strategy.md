# T-090: Know exactly which test proves each native interaction
> Research and falsify the available ways to test a Swift/SwiftUI macOS app, then give Tenon a concrete strategy for E2E flows, rendered UI, Accessibility, and gesture-to-domain wiring—without turning every rule into a slow XCUITest.

- **priority**: high
- **effort**: L

## This is a research-and-spike task
The result is not a link collection or a generic “test pyramid” essay. It must inspect Tenon's
live harnesses, run representative experiments, measure reliability and cost, and end with a
decision that tells a future feature author exactly where each kind of assertion belongs.

## Current baseline to audit
- `docs/tdd.md`: Functional Core / Imperative Shell and the “can this be asserted without a window?” placement rule.
- SwiftPM's three headless targets: `TenonIntentCoreTests`, `TenonCoreTests`, and `TenonAppStateTests`.
- Xcode-only `TenonIntegrationTests`, including a real hosted Ghostty surface.
- Xcode-only `TenonUITests`, which launches `Tenon.app` and currently covers shortcuts, launcher/palette focus, slot counts, and one pointer drag through the Accessibility tree.
- Hosted AppKit/SwiftUI interaction tests in `SpatialCanvasInteractionTests`: `NSWindow` / `NSHostingView`, synthetic `NSEvent`, first-responder assertions, context-menu construction, pointer routing, and drag lifecycle.
- Offscreen rendering through `NSHostingView.cacheDisplay` in `DiffSnapshot.swift`, which produces images but is not yet a general visual-regression harness.
- Existing Accessibility identifiers and values, including the documented XCUITest identity contract in `Tests/TenonUITests/README.md`.
- The runner manifests and docs themselves: verify `Package.swift`, `project.yml`, the generated scheme, `docs/development.md`, and `docs/operations.md` agree about every test target and command; stale or unreachable tests count as a defect, not coverage.

## Techniques that must be compared
1. Pure domain/state-machine and projection tests with Swift Testing versus XCTest.
2. Hosted component tests using real SwiftUI/AppKit views in an offscreen or borderless `NSWindow`.
3. Direct AppKit event injection and responder-chain testing (`NSEvent`, `NSApp.sendEvent`, `makeFirstResponder`, `NSMenu`) for native interaction adapters.
4. Black-box XCUITest/XCUIAutomation against the built app and its Accessibility tree.
5. Automated Accessibility audits plus manual Accessibility Inspector / VoiceOver verification where automation is insufficient.
6. Visual regression: Tenon's current offscreen renderer, XCTest screenshot attachments, and a maintained snapshot library such as `swift-snapshot-testing`; distinguish a review artifact from a pixel-diff gate.
7. SwiftUI hierarchy inspection tools such as ViewInspector: current macOS/API coverage, maintenance risk, coupling to SwiftUI internals, and what signal they add beyond testing the projection/state directly.
8. Real-service integration tests for boundaries a stub hides: Ghostty/PTY, WebKit, filesystem watching, plugin JavaScript runtimes, persistence/relaunch, and OS dialogs.
9. Performance receipts for critical UI paths: launch metrics, hitches/signposts, and Instruments traces; do not confuse a correctness E2E test with a performance budget.
10. Manual exploratory verification and recordings: define the narrow set of truths automation genuinely cannot establish, rather than using “human verify” as an unbounded escape hatch.

## Interaction case-study matrix
For every row below, identify the lowest-cost test that can prove the rule, the smallest real
adapter receipt above it, required fixtures, observable output, failure diagnostics, and what
the test still cannot prove:

- Button/click actions and selection routing.
- Keyboard shortcuts, key equivalents, text entry, and the terminal/WebView intercepting input.
- Focus, `firstResponder`, `@FocusState`, focus restoration, and a self-sustaining focus loop such as T-088.
- Right-click hit testing, context-menu presentation, enabled state, and selecting the resulting command.
- Hover and pointer-region behavior.
- Custom mouse drags/resizes versus native drag-and-drop sessions.
- Popovers, sheets, modals, alerts, and window-level dismissal.
- Accessibility labels, values, actions, hierarchy integrity, keyboard traversal, and VoiceOver reading order.
- Layout and appearance across narrow/wide windows, light/dark mode, increased contrast, localization/pseudolocalization, and reduced motion.
- Relaunch, restoration, multi-window state, filesystem/plugin effects, and embedded Ghostty/WebKit surfaces.

## Determinism and operations questions
- Define per-test isolated state: temporary workspace, preferences/Application Support root, plugin inventory, fixtures, clock/random seed, and whether terminal/WebKit/network are stubbed or real.
- Replace fixed sleeps with expectations or state predicates; document when polling the Accessibility tree is unavoidable and how it is bounded.
- Establish which UI suites may run in parallel, which require serial execution, and how app/process cleanup is proven after failure.
- Specify the macOS GUI runner contract: logged-in WindowServer session, Accessibility/Automation permissions, architecture and OS matrix, code signing, screen lock/sleep policy, and behavior on developer machines versus CI.
- Define artifacts for a failure: `.xcresult`, activity steps, app/window screenshots, Accessibility hierarchy, logs, launch environment, and relevant state snapshots.
- Measure cold-launch cost and repeat representative candidates enough times to expose flakes. Retries may diagnose a flaky test; they must not turn a flaky gate green.
- Separate presubmit, full-GUI, nightly/stress, performance, and manual-release suites using schemes/test plans or an equally explicit runner contract.

## Required spikes
- [ ] A hosted SwiftUI/AppKit spike proves a context-menu or focus/first-responder interaction using the real adapter and records exactly which OS behavior it bypasses.
- [ ] A black-box XCUITest spike drives the corresponding user path in `Tenon.app`, including an observable postcondition stronger than “the element exists”. T-088 is the required focus-loop case study even if its fix remains a separate task.
- [ ] An Accessibility audit spike runs on at least the main canvas and one overlay/modal, with explicit handling for justified findings rather than a blanket ignore closure.
- [ ] A visual-regression spike renders at least one representative SwiftUI view in controlled light/dark and narrow/wide configurations, compares Tenon's renderer with the leading external option, and records pixel/font/OS reproducibility limits.
- [ ] Each spike is repeated enough times to report runtime and observed flake rate. Experimental code that is not chosen is removed; chosen code is either landed with ownership and docs or captured in a follow-up task.

## Deliverables and criteria
- [ ] Add `docs/design-native-ui-testing.md` with a decision matrix covering fidelity, speed, determinism, diagnostics, macOS GUI requirements, maintenance cost, and the failures each technique can and cannot catch.
- [ ] Cite current primary sources and record the exact Xcode/macOS/tool versions tested; separate Apple-supported behavior from third-party claims and local inference.
- [ ] Inventory every current Tenon test target and special harness, identify unreachable/stale commands or coverage gaps, and reconcile the durable runner documentation.
- [ ] Produce a feature-author routing guide: given an interaction rule, it selects the lowest valid layer and names when a hosted or black-box adapter receipt is mandatory.
- [ ] Decide, with spike evidence, whether to adopt Swift Testing for new headless tests, a snapshot library, ViewInspector, Xcode test plans, automated Accessibility audits, and a GUI CI lane. “Do not adopt” is valid when its tradeoff is explicit.
- [ ] Define a bounded Accessibility-identifier policy: host-owned stable identity only, semantic label/value/action kept separate, no plugin/contributor-controlled test selectors, and no production behavior gated on test IDs.
- [ ] Update `docs/tdd.md`, `Tests/TenonUITests/README.md`, and `docs/operations.md` with the accepted layer/runner/artifact contract; add focused implementation follow-ups for work intentionally not landed in this research task.
- [ ] Demonstrate the recommended commands from a clean generated Xcode project and from the fast SwiftPM path, preserving command output as the verification receipt.

## Primary starting sources
- [Apple: Testing](https://developer.apple.com/documentation/xcode/testing)
- [Apple: XCTest and XCUIAutomation](https://developer.apple.com/documentation/xctest/)
- [Apple: Swift Testing](https://developer.apple.com/documentation/testing)
- [WWDC25: Record, replay, and review—UI automation with Xcode](https://developer.apple.com/videos/play/wwdc2025/344/)
- [Apple: Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [Apple: Organizing tests into test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)
- [Apple: XCTest attachments](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues)
- [Point-Free: swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
- [ViewInspector](https://github.com/nalexn/ViewInspector)

These are starting points, not preselected answers. The decision must follow the Tenon spikes.
