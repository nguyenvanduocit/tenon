import Foundation
import TenonCore
import TenonIntentCore
import XCTest

/// The boundary rules that only a sweep of the tree can hold.
///
/// T-020 built this file for one job: prove that internal app code has **no** generic app
/// intent principal and **no** dispatcher shortcut. Every rule here is that shape — an
/// absence, a count, an ordering, or a single-owner sweep — because those are the claims a
/// test cannot make by calling code. Nothing in the tree can be asked "are you the only
/// renderer?"; only a sweep can answer it.
///
/// **What does not belong here.** For a long time this file also pinned 398 exact source
/// lines — `"return $0.target < $1.target"`, `"case .production: \"Tenon\""`,
/// `"Text(\"Declared question\")"`. Text matching cannot fail on wrong behaviour, only on
/// changed spelling, so those anchors turned every rename red while catching no defect.
/// T-170 removed them, keeping the rule and dropping the transcript of the code. When a
/// behaviour needs proving, prove it where it runs: the two install channels are settled by
/// `CLISocketServerTests.testInstalledBundleIdentifiersResolveTheClosedInstanceChannels`
/// and `testProductionAndStagingCanBothOwnTheirSingletonChannels`, and the public plugin
/// surface by `PluginBuiltinsTests.testRuntimeExportsOnlyTheClassifiedPublicSurface`.
///
/// The test for a new rule here: *could this be asserted by running the code?* If yes, it
/// belongs in the suite that runs it.
final class InteractionBoundaryFitnessTests: XCTestCase {
    // MARK: - The closed vocabularies

    func testPrincipalKindsAndAudiencesHaveNoGenericAppIdentity() {
        XCTAssertEqual(
            Set(IntentPrincipal.Kind.allCases.map(\.rawValue)),
            ["core", "plugin", "user", "cli", "agent"]
        )
        XCTAssertEqual(
            Set(IntentAudience.allCases.map(\.rawValue)),
            ["core", "plugin", "user", "cli", "agent"]
        )
    }

    /// A capability that arrives as a new intent name, lane, or audience has enlarged a
    /// closed inventory, and the enlargement is the thing to notice — not the feature that
    /// prompted it. The counts are read from the enums themselves, so a case added anywhere
    /// trips this regardless of how the file is formatted.
    func testTheClosedIntentInventoriesStayClosed() {
        // 48 → 49 (T-139): one finite agent question and its bounded wait lane.
        // 49 → 50 (T-147): one pane title an agent may set, on the existing workspace lane.
        // 50 → 51 (T-154): workspace identity, one request/reply on that same lane.
        XCTAssertEqual(CoreIntentName.allCases.count, 51)
        XCTAssertEqual(CoreIntentExecutionLane.allCases.count, 13)
        XCTAssertEqual(IntentAudience.allCases.count, 5)

        // Automation is a host-native operation on the canvas. It reaches the public
        // boundary only through intents that already existed, so no inventory may carry it.
        for name in CoreIntentName.allCases {
            XCTAssertFalse(
                name.rawValue.lowercased().contains("automation"),
                "Automation must not mint a core intent: \(name.rawValue)"
            )
        }
        for lane in CoreIntentExecutionLane.allCases {
            XCTAssertFalse(
                lane.rawValue.lowercased().contains("automation"),
                "Automation must not mint an execution lane: \(lane.rawValue)"
            )
        }
    }

    // MARK: - Cross-owner entry points stay at the adapters

    func testNativeDispatcherEntryPointsRemainAtCrossOwnerAdapters() throws {
        let sourceRoot = packageRoot.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        let allowedDispatcherFiles: Set<String> = [
            "TenonApp/AppIntentRuntime.swift",
            "TenonCore/PluginHost.swift",
        ]
        let allowedPrincipalConstructionFiles: Set<String> = [
            "TenonApp/AppIntentRuntime.swift",
            "TenonIntentCore/IntentProvider.swift",
        ]

        var unexpectedDispatcherFiles: [String] = []
        var unexpectedPrincipalFiles: [String] = []
        for file in try swiftFiles(under: sourceRoot) {
            let relative = file.path.replacingOccurrences(
                of: sourceRoot.path + "/",
                with: ""
            )
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.range(
                of: #"\b(?:kernel\.)?dispatcher\s*\.\s*send\s*\("#,
                options: .regularExpression
            ) != nil,
               !allowedDispatcherFiles.contains(relative)
            {
                unexpectedDispatcherFiles.append(relative)
            }
            if source.contains("IntentPrincipal("),
               !allowedPrincipalConstructionFiles.contains(relative)
            {
                unexpectedPrincipalFiles.append(relative)
            }
        }

        XCTAssertEqual(unexpectedDispatcherFiles.sorted(), [])
        XCTAssertEqual(unexpectedPrincipalFiles.sorted(), [])
    }

    func testRemovedHandwrittenProductAPIsCannotReturnToShippedCode() throws {
        let roots = [
            packageRoot.appendingPathComponent("Sources", isDirectory: true),
            packageRoot.appendingPathComponent("plugins", isDirectory: true),
        ]
        let removedAPIs = [
            "tenon.commands",
            "tenon.workspace.",
            "tenon.terminal.",
            "tenon.web.",
            "tenon.net.",
            "tenon.sidebar.",
            "tenon.clipboard",
            "tenon.secrets",
        ]
        let ignoredFiles: Set<String> = [
            // Stable accessibility identifiers, not JavaScript APIs.
            "Sources/TenonApp/PluginUIPrompt.swift",
        ]

        var violations: [String] = []
        for root in roots {
            for file in try implementationFiles(under: root) {
                let relative = file.path.replacingOccurrences(
                    of: packageRoot.path + "/",
                    with: ""
                )
                guard !ignoredFiles.contains(relative) else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for api in removedAPIs where source.contains(api) {
                    violations.append("\(relative): \(api)")
                }
            }
        }

        XCTAssertEqual(violations.sorted(), [])
    }

    func testShippedPluginsSelectOneSenderShape() throws {
        // One async API shape on every surface: a function that sends takes the sender
        // last, defaulting to `tenon.intents`. Selecting a sender at the call site is
        // the kernel's plumbing leaking into plugin source.
        let roots = [
            packageRoot.appendingPathComponent("Sources", isDirectory: true),
            packageRoot.appendingPathComponent("plugins", isDirectory: true),
        ]
        // The rule is "no line CHOOSES a sender", not "these two spellings are absent".
        // Pinning the exact literals this codebase happened to delete would test the diff:
        // `var send = call ? call.send : tenon.intents.send` reintroduces the whole defect
        // and matches neither. So classify structurally — a line is a violation when a
        // sender token sits inside a conditional, in any of the three shapes JavaScript
        // offers for picking one.
        var violations: [String] = []
        for root in roots {
            for file in try implementationFiles(under: root) where file.pathExtension == "js"
                || file.pathExtension == "swift"
            {
                let relative = file.path.replacingOccurrences(
                    of: packageRoot.path + "/",
                    with: ""
                )
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).enumerated() where Self.selectsASenderConditionally(line) {
                    violations.append("\(relative):\(index + 1)")
                }
            }
        }

        XCTAssertEqual(violations.sorted(), [])
    }

    /// The test above sweeps real source, and real source is clean — so it reports green
    /// without the rule ever having rejected anything. That is the same weakness the rule
    /// replaced: a check nobody has watched fire is a hope. These fixtures make the rule
    /// itself the subject, including the guard shape that a first, broader version of it
    /// wrongly flagged.
    func testTheSenderShapeRuleSeparatesChoosingASenderFromValidatingOne() {
        let choices = [
            #"  return call ? await call.send(name, input) : await tenon.intents.send(name, input);"#,
            #"  var send = call ? call.send : tenon.intents.send;"#,
            #"  const sender = call || tenon.intents;"#,
            #"  return (call && call.send) || tenon.intents.send;"#,
            #"    else await tenon.intents.send("ui.toast.v1", input);"#,
        ]
        for line in choices {
            XCTAssertTrue(
                Self.selectsASenderConditionally(Substring(line)),
                "Choosing a sender at the call site must be a violation: \(line)"
            )
        }

        let notChoices = [
            // Validating the one sender you were handed — the shape `tenon.agents.run` uses.
            #"          if (call === null || typeof call !== "object""#,
            #"              || typeof call.send !== "function") {"#,
            // An ordinary send, and an ordinary object literal that merely contains a colon.
            #"  var result = await call.send("workspace.state.v1", { limit: 256 });"#,
            #"  await tenon.intents.send("ui.toast.v1", { message: title, tone: "info" });"#,
            // A default parameter is how the one shape is spelled, not a choice.
            #"async function refresh(st, call = tenon.intents) {"#,
        ]
        for line in notChoices {
            XCTAssertFalse(
                Self.selectsASenderConditionally(Substring(line)),
                "Validating or simply using a sender is not choosing one: \(line)"
            )
        }
    }

    /// A line is a violation when it picks BETWEEN senders, not when it names one.
    fileprivate static func selectsASenderConditionally(_ line: Substring) -> Bool {
        let namesASender = line.contains("call.send")
            || line.contains("tenon.intents")
            || line.contains(".send(")
        guard namesASender else { return false }

        // A ternary needs both halves; `{ key: value }` and `a?.b` have only one, so
        // requiring the spaced spelling of each keeps object literals out.
        if line.contains(" ? "), line.contains(" : ") { return true }

        // The statement form, `if (call) ... else await tenon.intents.send(...)`.
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("else") { return true }

        // A boolean operator only selects a sender when TWO senders meet across it —
        // `call || tenon.intents`, `(call && call.send) || tenon.intents.send`. One sender
        // beside a boolean operator is a type guard, not a choice: `if (call === null ||
        // typeof call.send !== "function") throw` validates the single sender it was
        // handed, which is the opposite of picking between two.
        if line.contains("||") || line.contains("&&") {
            let namesTheGlobalSender = line.contains("tenon.intents")
            let namesAPassedSender = line.contains("call.send") || line.contains("call ")
            return namesTheGlobalSender && namesAPassedSender
        }
        return false
    }

    // MARK: - DIRECT ownership

    /// A host-native surface and the service it calls share one semantic owner, so the call
    /// is DIRECT and typed (invariant 6). The failure this catches is a surface reaching for
    /// the public boundary anyway, which mints a second protocol for one operation.
    ///
    /// The table is the rule: every file listed is swept for every way a Swift file can
    /// leave DIRECT. Adding a host-native surface means adding its file here.
    func testHostNativeSurfacesStayOffThePublicIntentPath() throws {
        // The three ways a Swift file reaches the intent path. Every host-native surface is
        // held to at least these.
        let intentPath = [
            "tenon.intents",
            "intentRuntime.send(",
            "dispatcher.send(",
        ]
        // A surface with no ranked row of its own has no business in the palette adapter
        // either — reaching it is how a second way to run one command appears.
        let paletteAdapter = intentPath + ["PaletteIntentInvoker"]

        let sweeps: [(files: [String], forbidden: [String])] = [
            (
                [
                    "TenonApp/AgentLensView.swift",
                    "TenonApp/AgentLensSession.swift",
                    "TenonApp/AgentLensSources.swift",
                    "TenonApp/AgentSessionHooks.swift",
                    "TenonApp/SurfacePool.swift",
                    "TenonApp/BuiltInSlotViews.swift",
                    "TenonApp/FileSlotView.swift",
                    "TenonApp/GhosttySurface.swift",
                    "TenonCore/WorkspaceReorder.swift",
                    "TenonApp/WorkspaceSidebarView.swift",
                ],
                intentPath
            ),
            (
                [
                    "TenonApp/QuickCommands.swift",
                    "TenonApp/QuickCommandViews.swift",
                    "TenonApp/AgentLaunchSuggestions.swift",
                    "TenonCore/PaneArrangement.swift",
                    "TenonApp/PaneArrangementMenu.swift",
                ],
                paletteAdapter
            ),
            // A header carries no result cardinality and exercises no cross-principal
            // authority, so the law stops long before INTENT — and minting a principal is
            // the fourth way out.
            (
                [
                    "TenonCore/PaneHeader.swift",
                    "TenonCore/PaneHeaderItem.swift",
                    "TenonApp/PaneHeaderStore.swift",
                    "TenonApp/PaneHeaderCommand.swift",
                    "TenonApp/PaneHeaderLayout.swift",
                    "TenonApp/PaneHeaderBar.swift",
                    "TenonApp/PaneHeaderProjection.swift",
                ],
                intentPath + ["IntentPrincipal("]
            ),
            // Automation is operated on the canvas through typed host actions, so its view
            // may not name the public adapters at all.
            (
                ["TenonApp/AutomationSlotView.swift"],
                paletteAdapter + ["AppIntentRuntime", "IntentValue"]
            ),
        ]

        for sweep in sweeps {
            for relativePath in sweep.files {
                let implementation = try source(relativePath)
                for forbidden in sweep.forbidden {
                    XCTAssertFalse(
                        implementation.contains(forbidden),
                        "\(relativePath) left DIRECT ownership through \(forbidden)"
                    )
                }
            }
        }
    }

    /// Reordering a workspace is a local typed mutation. A pasteboard or `Transferable`
    /// route would make it a system drag with a serialisation format to keep compatible.
    func testWorkspaceReorderNeverBecomesASystemDrag() throws {
        for relativePath in [
            "TenonCore/WorkspaceReorder.swift",
            "TenonApp/WorkspaceSidebarView.swift",
        ] {
            let implementation = try source(relativePath)
            for forbidden in ["NSPasteboard", ".draggable(", ".onDrag("] {
                XCTAssertFalse(
                    implementation.contains(forbidden),
                    "\(relativePath) opened a system drag route through \(forbidden)"
                )
            }
        }
    }

    // MARK: - One implementation per operation

    /// One header per pane, held as a property of the tree rather than of a review.
    ///
    /// **Half (a)** — the header vocabulary has ONE renderer, and it is mounted in exactly two
    /// places: the AppKit host the pane card owns, and the offscreen snapshot frame. A third
    /// mount is a second implementation of one operation, which invariant 6 forbids.
    ///
    /// **Half (b)** — a pane may not draw a fixed-height chrome strip of its own inside its
    /// body. The three signatures swept for are the ones the in-body bars were built from, and
    /// unlike a colour-token sweep they name no pane in particular, so a new bar written to a
    /// new design still trips them.
    ///
    /// There is no exception set. `AgentLensModeBar` was the last in-body strip and T-076
    /// step 5 deleted it, which is what let the carve-out that named it go with it —
    /// a carve-out that can quietly outlive its reason is worse than no test, because it reads
    /// as a rule while permitting the thing the rule exists to prevent.
    func testExactlyOneImplementationDrawsAPaneHeader() throws {
        let appRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TenonApp")
        let appFiles = try swiftFiles(under: appRoot)

        let renderers = try appFiles.compactMap { file -> String? in
            try String(contentsOf: file, encoding: .utf8).contains("PaneHeaderBar(")
                ? file.lastPathComponent
                : nil
        }
        XCTAssertEqual(
            renderers.sorted(),
            ["DiffSnapshot.swift", "PaneHeaderBar.swift"],
            "the header vocabulary must have one renderer with exactly two mounts"
        )

        let inBodyChromeStrip = [
            ".frame(height: 31)",
            ".frame(height: 27)",
            ".frame(minHeight: 36)",
        ]
        let strips = try appFiles.compactMap { file -> String? in
            let source = try String(contentsOf: file, encoding: .utf8)
            return inBodyChromeStrip.contains(where: source.contains)
                ? file.lastPathComponent
                : nil
        }

        XCTAssertEqual(
            strips.sorted(),
            [],
            """
            A pane draws ONE header. \(strips.sorted()) draws a fixed-height chrome strip \
            inside a pane body; publish it into that pane's `PaneHeader` instead.
            """
        )
    }

    /// The superseded ways to draw a pane's chrome cannot come back.
    ///
    /// Deleting a public path and leaving nothing to stop its return is how two protocols for
    /// one operation reappear a quarter later.
    func testSupersededPaneHeaderPathsAreGoneFromShippedCode() throws {
        let roots = [
            packageRoot.appendingPathComponent("Sources", isDirectory: true),
            packageRoot.appendingPathComponent("plugins", isDirectory: true),
        ]
        let supersededPaths = [
            "ViewAction",
            "browserBar",
            "BrowserBarView",
            "ChangesSlotView",
            "GitChangesModel",
            "AgentLensModeBar",
        ]

        var violations: [String] = []
        for root in roots {
            for file in try implementationFiles(under: root) {
                let relative = file.path.replacingOccurrences(
                    of: packageRoot.path + "/",
                    with: ""
                )
                let source = try String(contentsOf: file, encoding: .utf8)
                for path in supersededPaths where source.contains(path) {
                    violations.append("\(relative): \(path)")
                }
            }
        }

        XCTAssertEqual(violations.sorted(), [])
    }

    /// Which commands a launcher offers is one projection. An anchor that restates the
    /// membership rule is a second copy that drifts the first time one of them changes.
    func testLauncherMembershipIsProjectedInOnePlace() throws {
        let appRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TenonApp")
        let projectionOwners = try swiftFiles(under: appRoot).compactMap { file -> String? in
            let contents = try String(contentsOf: file, encoding: .utf8)
            return contents.contains("commandIndex.launcherOnly")
                || contents.contains("commandIndex.paneFillersOnly")
                ? file.lastPathComponent
                : nil
        }
        XCTAssertEqual(
            projectionOwners,
            ["LauncherMenu.swift"],
            "launcher membership must be projected in LauncherMenu, never copied by an anchor"
        )
    }

    /// Three kinds of row share one popover: a ranked command, a dynamic provider result,
    /// and the tab's own Copy Tab ID utility. Only the first is a ranking answer, and for a
    /// long time the row presentation took nothing else — it was typed on `CommandMatch`,
    /// which carries `score` and `titleMatch`. Both other callers paid for that: the palette
    /// fabricated a `CommandMatch(score: 0)` to obtain a row, and the launcher's footer
    /// refused to and hand-rolled a `Button`, losing hover and selection entirely. `CMD-NFR-005`
    /// had promised row hover the whole time with `source/design review` as its only evidence.
    /// The chrome is now the presentation and the ranking is a separate question, so this
    /// stands where the eye did.
    func testEveryLauncherRowDrawsOneSharedChromeWhateverItsSemantics() throws {
        let chrome = try source("TenonApp/PaletteRowChrome.swift")
        let overlay = try source("TenonApp/PaletteOverlay.swift")
        let launcher = try source("TenonApp/LauncherMenu.swift")

        // Drawing a row must not require having won a ranking, which is the whole reason a
        // local utility can reuse this. Prose is not a dependency, and the one place that
        // must be free to name the ranking type is the rationale explaining why this type
        // refuses it — so the ban is on code, with every comment tail dropped first.
        let chromeCode = chrome
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: "\n")
        for forbidden in ["CommandMatch", "Command(", "titleMatch", "score"] {
            XCTAssertFalse(
                chromeCode.contains(forbidden),
                "PaletteRowChrome must stay ignorant of ranking, but names \(forbidden)"
            )
        }

        // One implementation of the highlight. A second call site restating it is exactly how
        // the footer came to have none.
        for (name, implementation) in [
            ("PaletteOverlay.swift", overlay),
            ("LauncherMenu.swift", launcher),
        ] {
            XCTAssertFalse(
                implementation.contains("isHovered") || implementation.contains(".onHover"),
                "\(name) restates the row highlight instead of composing PaletteRowChrome"
            )
        }

        // A dynamic provider result is appended, never ranked (`CMD-FR-003`), and no longer
        // impersonates a ranked command to be drawn.
        XCTAssertFalse(
            overlay.contains("score: 0"),
            "the palette still fabricates a CommandMatch to reuse the row presentation"
        )

        // The launcher's height arithmetic must read the same metrics the rows draw with,
        // or the popover sizes itself against a row height nothing renders.
        XCTAssertTrue(
            try source("TenonApp/LauncherListHeight.swift")
                .contains("PaletteRowChrome.Density.compact.height"),
            "the launcher's height arithmetic must read the same metrics the rows draw with"
        )
    }

    /// `CMD-FR-024`: the `+` anchor creates a destination — it names no existing tab — while
    /// a tab's secondary click names the exact tab that was clicked. A utility whose meaning
    /// depends on an existing tab's current pane layout (Arrange Panes, same as Copy Tab ID
    /// under `CMD-FR-007`) is therefore a tab-launcher-only offer. T-189: the `+` popover once
    /// drew "Arrange Panes" anyway, wired straight to whatever tab happened to be active —
    /// rearranging a tab the click never named, which is what an operator reported as
    /// confusing across screenshots more than once. Both call sites share one type
    /// (`LauncherMenu`), so only their own construction can tell them apart; a sweep of the
    /// two argument lists is the whole test.
    func testPlusAnchorNeverOffersTheTabLaunchersExistingTabUtilities() throws {
        let strip = try source("TenonApp/ShellTabStrip.swift")

        let plusLauncher = try sourceSlice(
            strip,
            from: "private var newTabButton: some View {",
            before: "// MARK: - Derived state"
        )
        for forbidden in ["arrangePanes:", "paneArrangements:", "copyTabID:"] {
            XCTAssertFalse(
                plusLauncher.contains(forbidden),
                "the `+` anchor wires \(forbidden) — it creates a destination tab, " +
                    "it does not name an existing one to mutate"
            )
        }

        let tabLauncher = try sourceSlice(
            strip,
            from: "private func tabLauncher(for tab: TenonCore.Tab) -> LauncherMenu {",
            before: "/// One chip, with everything the strip needs back from it"
        )
        for expected in ["arrangePanes:", "paneArrangements:", "copyTabID:"] {
            XCTAssertTrue(
                tabLauncher.contains(expected),
                "the tab launcher must keep offering \(expected) — " +
                    "it is the anchor that names an existing tab"
            )
        }
    }

    /// The built-in half of the header stays typed.
    ///
    /// A DIRECT call must use typed Swift interfaces, and a header action travels as a bare
    /// `itemID` string — so the only thing keeping the built-in half honest is that every such
    /// id is minted from a `PaneHeaderCommand` case and resolved back into one. Two properties
    /// carry that: the router is the single place that turns a string back into a case, and no
    /// other file spells a command's token as a literal. The tokens are read out of the enum
    /// rather than restated here, so a new case is swept automatically.
    func testBuiltInHeaderItemsNeverMintRawActionStrings() throws {
        let appRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TenonApp")
        let appFiles = try swiftFiles(under: appRoot)

        let routers = try appFiles.compactMap { file -> String? in
            try String(contentsOf: file, encoding: .utf8)
                .contains("PaneHeaderCommand(rawValue:")
                ? file.lastPathComponent
                : nil
        }
        XCTAssertEqual(
            routers.sorted(),
            ["SpatialCanvasNSView.swift"],
            "a header item id may be resolved back into a command at the router only"
        )

        let commandSource = try source("TenonApp/PaneHeaderCommand.swift")
        let tokens = commandSource
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains("case "), let assignment = line.range(of: "= \"") else {
                    return nil
                }
                let rest = line[assignment.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<close])
            }
        XCTAssertFalse(tokens.isEmpty, "no PaneHeaderCommand tokens were found to sweep for")

        for token in tokens {
            let spellers = try appFiles.compactMap { file -> String? in
                try String(contentsOf: file, encoding: .utf8).contains("\"\(token)\"")
                    ? file.lastPathComponent
                    : nil
            }
            XCTAssertEqual(
                spellers.sorted(),
                ["PaneHeaderCommand.swift"],
                """
                "\(token)" is a PaneHeaderCommand token and must be spelled only by the enum; \
                a projection references it as PaneHeaderCommand.<case>.rawValue
                """
            )
        }
    }

    /// A header control that has words for the pointer has words for a screen reader too.
    ///
    /// On macOS `.help()` becomes an accessibility HELP — a hint — and never a label. So a
    /// control whose only words are its tooltip reaches VoiceOver named after its SF Symbol
    /// string rather than after the sentence its author wrote. That is not hypothetical: the
    /// Agent Lens migration exposed the same failure shape on its diagnostics warning and
    /// inspector toggle. Its most time-sensitive fact, `currentActionSummary`, now lives in a
    /// dedicated spoken Session status line rather than in pane chrome.
    ///
    /// `paneHeaderHelp` is the one place the renderer turns a tooltip into anything, so the
    /// invariant is checkable as a shape: every `help(` in the file sits on a line that also
    /// names the accessibility half. A new item kind reaching for a bare `.help(…)` fails here.
    ///
    /// What this does NOT prove is delivery — whether AppKit then speaks it. That needs a real
    /// assistive client: an `NSHostingView` in an offscreen borderless window builds no
    /// accessibility tree at all, measured by walking it after `display()`, a runloop turn, and
    /// `NSAccessibilityUnignoredDescendant`, all of which returned empty. The shape is what a
    /// headless suite can hold; delivery is a launch smoke check with VoiceOver.
    func testEveryHeaderTooltipAlsoCarriesASpokenName() throws {
        let renderer = try source("TenonApp/PaneHeaderBar.swift")
        let offenders = renderer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("///"), !text.hasPrefix("//") else { return false }
                guard text.contains("help(") else { return false }
                return !text.contains("accessibilityLabel(")
                    && !text.contains("accessibilityValue(")
            }
            .map { index, line in
                "PaneHeaderBar.swift:\(index + 1): \(line.trimmingCharacters(in: .whitespaces))"
            }

        XCTAssertEqual(
            offenders,
            [],
            """
            a tooltip is being applied with no spoken name beside it. On macOS `.help()` is a \
            hint, never a label, so this control will be read aloud as its SF Symbol string. \
            Route it through `paneHeaderHelp(_:spokenAs:)` — `.name` when the item draws no \
            text of its own, `.value` when it does.
            """
        )
    }

    // MARK: - Orderings that guard a race

    /// A click accepts one visible row. Resolving that row again inside the async task lets
    /// lifecycle work between the two lookups answer with a different provider — so the
    /// binding happens at the gesture, and only the send is deferred.
    func testAnAcceptedRowBindsItsProviderBeforeAnyAsyncWork() throws {
        let surfaces = [
            (
                "PaletteOverlay.swift",
                try sourceSlice(
                    try source("TenonApp/PaletteOverlay.swift"),
                    from: "private func run(_ match: CommandMatch)",
                    before: "/// Run a dynamic result"
                )
            ),
            (
                "LauncherMenu.swift",
                try sourceSlice(
                    try source("TenonApp/LauncherMenu.swift"),
                    from: "private func run(_ match: CommandMatch)",
                    before: "\n    }\n}"
                )
            ),
        ]

        for (name, commandRun) in surfaces {
            let prepare = try XCTUnwrap(
                commandRun.range(of: "PaletteIntentInvoker.prepare(")?.lowerBound,
                "\(name) no longer binds its provider at the accepted click"
            )
            let asyncWork = try XCTUnwrap(
                commandRun.range(of: "Task { @MainActor in")?.lowerBound,
                "\(name) no longer defers the send"
            )
            XCTAssertLessThan(
                prepare,
                asyncWork,
                "\(name) must bind its exact provider at the accepted click, before async lifecycle work can invalidate the lookup"
            )
        }
    }

    /// The automation tick owns a task and the host owns the plugins it fires into. Shutting
    /// the host down first leaves a tick running against a retired generation.
    func testAutomationTickingIsDrainedBeforeTheHostShutsDown() throws {
        let stopLifecycle = try sourceSlice(
            try source("TenonApp/TenonApp.swift"),
            from: "func stop() async",
            before: "@MainActor\nfinal class AppLifecycleDelegate"
        )
        let cancelTick = try XCTUnwrap(
            stopLifecycle.range(of: "automationTicking?.cancel()")
        )
        let awaitTick = try XCTUnwrap(
            stopLifecycle.range(of: "await automationTicking?.value")
        )
        let clearTick = try XCTUnwrap(
            stopLifecycle.range(of: "automationTickTask = nil")
        )
        let shutdownHost = try XCTUnwrap(
            stopLifecycle.range(of: "await host.shutdown()")
        )
        XCTAssertLessThan(cancelTick.lowerBound, awaitTick.lowerBound)
        XCTAssertLessThan(awaitTick.lowerBound, clearTick.lowerBound)
        XCTAssertLessThan(clearTick.lowerBound, shutdownHost.lowerBound)
    }

    // MARK: - AppKit rules no headless test can reach

    /// The strip is drawn inside the title-bar band, and AppKit builds a drag region for
    /// that band which the window server moves the window from. A view leaves the region
    /// by answering `mouseDownCanMoveWindow` with `false`, being an `NSControl`, **and
    /// accepting first responder** — the region builder ignores a plain NSView saying it,
    /// and puts a control that refuses first responder back inside. Three fixes shipped
    /// against the first half of that rule, and a fourth shipped against the second: this
    /// file used to require `acceptsFirstResponder = false` here, which is precisely what
    /// handed every chip back to the window server.
    ///
    /// `NSWindow.sendEvent` injects below the window server, so a test can drive a whole
    /// press-drag-release successfully while a hardware drag still moves the window. These
    /// are the properties the region builder reads; `scripts/internal/drag-region-probe.swift`
    /// checks the consequence on-screen.
    func testTheTabStripStaysOutOfTheWindowDragRegion() throws {
        // The strip, wherever it is drawn. These assertions follow it into `ShellTabStrip`
        // rather than staying on the row it used to live in: a negative left behind on an
        // emptied file passes for the wrong reason and reads as a rule while permitting
        // exactly what the rule prevents.
        let strip = try source("TenonApp/ShellTabStrip.swift")

        XCTAssertTrue(
            strip.contains("override var mouseDownCanMoveWindow: Bool { false }"),
            "a tab drag must stay in the app instead of becoming a window move"
        )
        XCTAssertTrue(
            strip.contains("final class SurfaceView: NSControl"),
            "only an NSControl descendant is honoured by the window's drag-region builder"
        )
        XCTAssertFalse(
            strip.contains("override var acceptsFirstResponder"),
            """
            answering acceptsFirstResponder at all puts the chips back inside the drag \
            region; the keyboard is kept by never calling super in the mouse path, and \
            TabStripReorderTests drives that consequence rather than asserting the property
            """
        )
        XCTAssertTrue(
            strip.contains("override var canBecomeKeyView: Bool { false }"),
            "the strip still stays out of the Tab key-view loop, which the region tolerates"
        )
        // A surface that claims the point only sometimes leaves the window server holding it
        // the rest of the time, which is how the first fix for this failed.
        XCTAssertFalse(
            strip.contains("NSApplication.shared.currentEvent")
                || strip.contains("claimsPointer"),
            "the strip's surface must claim its region unconditionally, not per event"
        )
        // …and the carve-out is unconditional in the other sense too: the strip must not
        // decide whether to take the pointer from the edge its row happens to be at. It is
        // one behaviour at both ends, or it is two behaviours to keep in step.
        XCTAssertFalse(
            strip.contains("edge == .top ? TabStripSurface")
                || strip.contains("if edge == .top {\n            TabStripSurface"),
            "the strip owns its pointer at both edges, not only in the title-bar band"
        )

        let windowChrome = try source("TenonApp/WindowChrome.swift")
        let titleBar = try source("TenonApp/ShellTitleBar.swift")
        XCTAssertTrue(
            windowChrome.contains("isMovableByWindowBackground = false")
                && titleBar.contains("WindowDragArea(color: TenonTheme.chromeNS)"),
            "only the title-bar row asks for a window drag, and it asks explicitly"
        )
        XCTAssertFalse(
            try source("TenonApp/ShellFootBar.swift").contains("WindowDragArea("),
            """
            the foot row is not the title-bar band: a drag there would move the window from \
            the bottom edge and run a double-click handler about title bars
            """
        )

        // The right-click observer must never enter hit-testing or steal a tab drag.
        let tabChip = try sourceSlice(
            strip,
            from: "struct TabChip: View",
            before: "struct RightClickCatcher"
        )
        XCTAssertFalse(
            tabChip.contains("NSApp.currentEvent"),
            "the right-click observer must never enter hit-testing or steal a tab drag"
        )
        XCTAssertFalse(
            tabChip.contains(".contextMenu"),
            "a tab right-click must open LauncherMenu directly, not a native menu first"
        )
    }

    /// T-105: a chip's fallback name is the tab's own number. Deriving it from the tab's
    /// place made a working reorder invisible — the chips swapped and the labels swapped
    /// back — so the strip is held to reading the number off the tab.
    func testATabChipIsNamedAfterTheTabRatherThanItsPosition() throws {
        let strip = try source("TenonApp/ShellTabStrip.swift")
        XCTAssertFalse(
            strip.contains("index + 1"),
            "numbering a tab by its position renames it every time the strip is reordered"
        )
    }

    // MARK: - Settings holds preferences, the canvas holds operations

    /// Automation is operated on the canvas. Settings may turn the whole schedule surface on
    /// or off and say so in prose; the moment it grows a button, a list, or a scheduler type
    /// there are two places to operate one feature.
    func testSettingsCarriesNoOperationalAutomationWiring() throws {
        let automationSettings = try sourceSlice(
            try source("TenonApp/SettingsView.swift"),
            from: "private struct AutomationSettingsDetail: View",
            before: "// MARK: - CLI"
        )
        for operationalWiring in [
            "Button(",
            "ForEach(",
            "AutomationScheduler",
            "AutomationRunHistory",
            "AutomationRunRecord",
            "AutomationPaneActions",
            "AutomationAuthoring",
            "pausedAutomationSchedules",
            ".manualFiring(",
            ".listings(",
            ".runHistory",
            "createWithAI",
            "runNow:",
            "ScheduledAutomationDelivery",
            "automationFired(",
            "PaletteIntentInvoker",
            "AppIntentRuntime",
            "IntentValue",
            "Task {",
        ] {
            XCTAssertFalse(
                automationSettings.contains(operationalWiring),
                "Settings must remain preference-only; found operational wiring \(operationalWiring)"
            )
        }
    }

    // MARK: - Two identities that cannot drift apart

    /// The app declares its two bundle identities in Swift and the installer writes them into
    /// the bundle it builds. Two spellings of one identity is how a staging build comes to
    /// answer on production's socket, so the installer is checked against what the app
    /// declares rather than against a copy of the string kept here.
    func testTheInstallerShipsTheBundleIdentitiesTheAppDeclares() throws {
        let channel = try source("TenonApp/AppInstanceChannel.swift")
        let installer = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/install.sh"),
            encoding: .utf8
        )

        let declared = try XCTUnwrap(
            Self.stringLiteral(
                after: "stagingBundleIdentifier",
                in: channel
            ),
            "AppInstanceChannel no longer declares a staging bundle identifier"
        )
        XCTAssertTrue(
            installer.contains(declared),
            "scripts/install.sh does not install the staging identity the app declares (\(declared))"
        )
        // The production identity is the staging one without its suffix, and the installer
        // must know both — a single-identity installer cannot place a staging build.
        let production = declared.replacingOccurrences(of: ".staging", with: "")
        XCTAssertTrue(
            installer.contains(production),
            "scripts/install.sh does not install the production identity (\(production))"
        )
        XCTAssertTrue(
            installer.contains("STAGING"),
            "one installer selects the identity with a flag; two installers drift apart"
        )
    }

    /// The first double-quoted literal after `needle`, or nil.
    fileprivate static func stringLiteral(
        after needle: String,
        in source: String
    ) -> String? {
        guard let start = source.range(of: needle) else { return nil }
        let rest = source[start.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest[rest.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: "\"") else { return nil }
        return String(afterOpen[..<close])
    }
}

private extension InteractionBoundaryFitnessTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func swiftFiles(under root: URL) throws -> [URL] {
        try implementationFiles(under: root).filter {
            $0.pathExtension == "swift"
        }
    }

    func implementationFiles(under root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true,
               ["swift", "js", "json"].contains(file.pathExtension)
            {
                result.append(file)
            }
        }
        return result
    }

    func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func sourceSlice(
        _ source: String,
        from startAnchor: String,
        before endAnchor: String
    ) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: startAnchor),
            "missing start anchor \(startAnchor)"
        )
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(
            suffix.range(of: endAnchor),
            "missing end anchor \(endAnchor)"
        )
        return String(suffix[..<end.lowerBound])
    }
}
