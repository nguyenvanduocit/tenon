import Foundation
import TenonIntentCore
import XCTest

final class InteractionBoundaryFitnessTests: XCTestCase {
    func testInstallChannelsKeepSingletonAndDurableStateIsolationClosed() throws {
        let channel = try source("TenonApp/AppInstanceChannel.swift")
        let paths = try source("TenonApp/AppStatePaths.swift")
        let app = try source("TenonApp/TenonApp.swift")
        let socket = try source("TenonApp/CLISocketServer.swift")
        let hooks = try source("TenonApp/AgentSessionHooks.swift")
        let cliInstaller = try source("TenonApp/CLICommandInstaller.swift")
        let installer = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/install.sh"),
            encoding: .utf8
        )

        assertContains(
            channel,
            [
                "enum AppInstanceChannel: String, CaseIterable, Sendable",
                "case production",
                "case staging",
                "static let stagingBundleIdentifier = \"dev.tenon.app.staging\"",
                "case Self.stagingBundleIdentifier: .staging",
                "unrecognizedInstalledBundleIdentifier(identifier",
                "case .production: \"tenon-",
                "case .staging: \"tenon-staging-",
                "case .production: \"Tenon\"",
                "case .staging: \"Tenon Staging\"",
            ],
            file: "AppInstanceChannel.swift"
        )
        assertContains(
            paths,
            [
                "let instanceChannel: AppInstanceChannel",
                "instanceChannel.applicationSupportDirectoryName",
            ],
            file: "AppStatePaths.swift"
        )
        assertContains(
            socket,
            [
                "instanceChannel: AppInstanceChannel = .production",
                "Self.wellKnownPath(for: instanceChannel)",
                "case unavailable",
                "guard isSocketNode(at: path) else { return false }",
            ],
            file: "CLISocketServer.swift"
        )
        assertContains(
            app,
            [
                "instanceChannel: paths.instanceChannel",
                "case .unavailable:",
                "CommandPaletteState(storeURL: paths.commandFrecencyFile)",
                "prepared.cliServer.clientSocketPath",
                "agentHookScriptPath: prepared.agentHookScriptURL.path",
            ],
            file: "TenonApp.swift"
        )
        assertContains(
            hooks,
            ["TENON_AGENT_HOOK_SCRIPT", "hookCommand(provider: provider)"],
            file: "AgentSessionHooks.swift"
        )
        assertContains(
            cliInstaller,
            ["instanceChannel == .production", "InstallError.productionOnly"],
            file: "CLICommandInstaller.swift"
        )
        // One installer, two channels: the `--staging` flag selects the identity, so the two
        // bundle identifiers cannot drift apart the way two installer scripts could.
        assertContains(
            installer,
            [
                "--staging) STAGING=1 ;;",
                "if [ \"$STAGING\" -eq 1 ]; then",
                "BUNDLE_ID=\"${INSTALL_BUNDLE_ID:-dev.tenon.app.staging}\"",
                "BUNDLE_ID=\"${INSTALL_BUNDLE_ID:-dev.tenon.app}\"",
                "dev.tenon.app|dev.tenon.app.staging",
            ],
            file: "scripts/install.sh"
        )
    }

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

    func testRegisteredProductBindingsFollowManifestProjectionAndSharedInvoker() throws {
        let manifest = try source("TenonCore/PluginManifest.swift")
        let host = try source("TenonCore/PluginHost.swift")
        let keyBindingIndex = try source(
            "TenonCore/KeyBindingIndex.swift"
        )
        let invoker = try source("TenonApp/PaletteIntentInvoker.swift")
        let keyBindingCommands = try source(
            "TenonApp/PluginKeyBindingCommands.swift"
        )
        let palette = try source("TenonApp/PaletteOverlay.swift")
        let app = try source("TenonApp/TenonApp.swift")

        assertContains(
            manifest,
            [
                "public let palette: PluginPalettePresentation?",
                "public let key: String?",
                "case key",
            ],
            file: "PluginManifest.swift"
        )
        let hostModels = try source("TenonCore/PluginHostModels.swift")
        assertContains(
            hostModels,
            ["public struct PluginIntentPresentation"],
            file: "PluginHostModels.swift"
        )
        // The projection moved out of the coordinator, so the anchors follow it: what a
        // manifest's declared intent becomes, and the index built from it, are one pure
        // transformation now — the host only decides the order and publishes the result.
        let contributions = try source("TenonCore/PluginContributionProjection.swift")
        assertContains(
            contributions,
            [
                "PluginIntentPresentation.projected(",
                "let keyBindingIndex = KeyBindingIndex(",
                "reserved: KeyBindingIndex.shellReserved",
            ],
            file: "PluginContributionProjection.swift"
        )
        assertContains(
            hostModels,
            ["key: palette.key"],
            file: "PluginHostModels.swift"
        )
        assertContains(
            host,
            [
                "PluginContributionProjection.make(",
                "intentPresentations = contributions.intentPresentations",
                "keyBindingIndex = contributions.keyBindingIndex",
            ],
            file: "PluginHost.swift"
        )
        assertContains(
            keyBindingIndex,
            [
                "public struct KeyBindingIndex",
                "let ordered = requests.sorted",
                "return $0.target < $1.target",
            ],
            file: "KeyBindingIndex.swift"
        )
        assertContains(
            keyBindingCommands,
            [
                "struct PluginKeyBindingCommands: Commands",
                "ForEach(host.keyBindingIndex.bindings)",
                "PaletteIntentInvoker.send(",
            ],
            file: "PluginKeyBindingCommands.swift"
        )
        assertContains(
            palette,
            [
                "PaletteIntentInvoker.send(",
                // The assigned chord is displayed on the ranked row, handed to the shared
                // chrome as its trailing accessory.
                "trailing: match.command.key?.display",
            ],
            file: "PaletteOverlay.swift"
        )
        let paletteCommandRun = try sourceSlice(
            palette,
            from: "private func run(_ match: CommandMatch)",
            before: "/// Run a dynamic result"
        )
        let palettePrepareOffset = try XCTUnwrap(
            paletteCommandRun.range(of: "PaletteIntentInvoker.prepare(")?.lowerBound
        )
        let paletteTaskOffset = try XCTUnwrap(
            paletteCommandRun.range(of: "Task { @MainActor in")?.lowerBound
        )
        XCTAssertLessThan(
            palettePrepareOffset,
            paletteTaskOffset,
            "a palette click must bind its provider before async lifecycle work can invalidate the accepted row"
        )
        assertContains(
            invoker,
            [
                "return await runtime.send(",
                "as: AppIntentRuntime.userPrincipal",
            ],
            file: "PaletteIntentInvoker.swift"
        )
        assertContains(
            app,
            ["PluginKeyBindingCommands("],
            file: "TenonApp.swift"
        )
        XCTAssertFalse(keyBindingCommands.contains("intentRuntime.send("))
        XCTAssertFalse(palette.contains("intentRuntime.send("))

        let commandsScene = try sourceSlice(
            app,
            from: ".commands {",
            before: "Settings {"
        )
        XCTAssertEqual(
            commandsScene.components(
                separatedBy: ".keyboardShortcut("
            ).count - 1,
            1,
            "the Commands scene owns exactly one static chord: Command Palette"
        )
        XCTAssertFalse(
            commandsScene.contains("WorkspaceStore"),
            "the Commands scene must not reach the workspace directly"
        )
        XCTAssertFalse(
            commandsScene.contains("store."),
            "the Commands scene must not reach the workspace directly"
        )
    }

    func testFocusedEditorGhosttyAndPaletteControlsStayDirect() throws {
        let editor = try source("TenonApp/FileSlotView.swift")
        let ghostty = try source("TenonApp/GhosttySurface.swift")
        let palette = try source("TenonApp/PaletteOverlay.swift")
        let app = try source("TenonApp/TenonApp.swift")

        assertContains(
            editor,
            [
                "await model.save()",
                #".keyboardShortcut("s", modifiers: .command)"#,
            ],
            file: "FileSlotView.swift"
        )
        assertDirect(editor, file: "FileSlotView.swift")

        assertContains(
            ghostty,
            [
                "override func keyDown(with event: NSEvent)",
                "ghostty_surface_key(surface, key)",
                "ghostty_surface_key_is_binding(surface, key, nil)",
            ],
            file: "GhosttySurface.swift"
        )
        assertDirect(ghostty, file: "GhosttySurface.swift")

        let paletteControls = try sourceSlice(
            palette,
            from: "// Escape closes the palette",
            before: "private var searchField"
        )
        assertContains(
            paletteControls,
            [
                "palette.dismiss()",
                ".keyboardShortcut(.cancelAction)",
                ".onKeyPress(.downArrow)",
                ".onKeyPress(.upArrow)",
            ],
            file: "PaletteOverlay.swift control region"
        )
        assertDirect(
            paletteControls,
            file: "PaletteOverlay.swift control region"
        )

        let selectionMovement = try sourceSlice(
            palette,
            from: "private func move(",
            before: "private func runSelected()"
        )
        assertContains(
            selectionMovement,
            ["palette.selection"],
            file: "PaletteOverlay.swift selection movement"
        )
        assertDirect(
            selectionMovement,
            file: "PaletteOverlay.swift selection movement"
        )

        let paletteToggle = try sourceSlice(
            app,
            from: #"Button("Command Palette")"#,
            before: "PluginKeyBindingCommands("
        )
        assertContains(
            paletteToggle,
            [
                "composition.palette.toggle()",
                #".keyboardShortcut("#,
            ],
            file: "TenonApp.swift palette toggle"
        )
        assertDirect(
            paletteToggle,
            file: "TenonApp.swift palette toggle"
        )
    }

    func testAgentLensStaysHostInternalDirectAndUsesBoundedResourceStreams() throws {
        let view = try source("TenonApp/AgentLensView.swift")
        let declaredQuestion = try source(
            "TenonApp/AgentDeclaredQuestionCard.swift"
        )
        let session = try source("TenonApp/AgentLensSession.swift")
        let sources = try source("TenonApp/AgentLensSources.swift")
        let hooks = try source("TenonApp/AgentSessionHooks.swift")
        let surfacePool = try source("TenonApp/SurfacePool.swift")
        let slots = try source("TenonApp/BuiltInSlotViews.swift")

        assertContains(
            view,
            [
                "AgentLensSlotView",
                "model.sendDraft()",
                "model.mode",
                // A file the agent cited opens the host's own pane, so the click carries a
                // typed callback out to the composition root rather than a public boundary.
                "var openFile: (@MainActor @Sendable (String) -> Void)?",
            ],
            file: "AgentLensView.swift"
        )
        assertContains(
            declaredQuestion,
            [
                "struct AgentDeclaredQuestionCard: View",
                "Text(\"Declared question\")",
                "Text(verbatim: choice.label)",
                "Link(destination: destination)",
                "seconds remaining",
                "tenon.agentQuestion",
                "tenon.agentQuestion.choice.",
                "AgentQuestionAccessibilityControl",
                "view.setAccessibilityLabel(label)",
                "view.setAccessibilityTitle(label)",
                "override func hitTest(_: NSPoint) -> NSView?",
                "override func accessibilityPerformPress() -> Bool",
            ],
            file: "AgentDeclaredQuestionCard.swift"
        )
        assertContains(
            view,
            [
                "Provider inference • lower authority",
                "Answer in Terminal (inferred)",
            ],
            file: "AgentLensView.swift"
        )
        assertContains(
            slots,
            ["store.openContent(.file(path: path))"],
            file: "BuiltInSlotViews.swift"
        )
        assertContains(
            session,
            [
                "actor AgentLensInputQueue",
                "actor AgentLensSessionCoordinator",
                "AgentLensReducer",
                "func retainOnly(_ slotIDs: Set<UUID>)",
            ],
            file: "AgentLensSession.swift"
        )
        assertContains(
            sources,
            [
                "AsyncThrowingStream(bufferingPolicy: .bufferingOldest(",
                "continuation.onTermination = { @Sendable _ in task.cancel() }",
                "continuation.finish(throwing: AgentLensSourceError.overflow)",
                "actor AgentTranscriptTailer",
                "struct CodexProtocolIngress",
            ],
            file: "AgentLensSources.swift"
        )
        assertContains(
            hooks,
            [
                "struct AgentHookEvent",
                "actor AgentSessionRegistry",
                "final class AgentHookServer",
                "AgentHookRequestDecoder.maxBodyBytes",
                "event.agentID == nil",
                "surfaceToken",
                "X-Tenon-Agent-Provider",
                "TENON_AGENT_PROVIDER",
                "agent_pgid",
                "-o ppid=",
            ],
            file: "AgentSessionHooks.swift"
        )
        assertContains(
            surfacePool,
            [
                "func agentTerminalIdentity(for slotID: UUID)",
                "func sendAgentInputFrame(",
                "surface.foregroundPID == expectedForegroundPID",
                "surfaceTokens[slotID] = surfaceToken",
            ],
            file: "SurfacePool.swift"
        )

        for (name, implementation) in [
            ("AgentLensView.swift", view),
            ("AgentLensSession.swift", session),
            ("AgentLensSources.swift", sources),
            ("AgentSessionHooks.swift", hooks),
            ("SurfacePool.swift", surfacePool),
            ("BuiltInSlotViews.swift", slots),
        ] {
            XCTAssertFalse(implementation.contains("tenon.intents"), "\(name) opened a public intent path")
            XCTAssertFalse(implementation.contains("intentRuntime.send("), "\(name) bypassed DIRECT ownership")
            XCTAssertFalse(implementation.contains("dispatcher.send("), "\(name) bypassed DIRECT ownership")
        }
    }

    func testEveryLauncherSurfaceReusesOnePresentationAndCommandProjection() throws {
        let launcher = try source("TenonApp/LauncherMenu.swift")
        let titleBar = try source("TenonApp/ShellTitleBar.swift")
        // The canvas is a folder now: the pure rule that decides where an empty-grid launcher
        // is anchored lives beside the view that presents it, and this surface is both.
        let canvas = try source("TenonApp/Canvas/SpatialInteraction.swift")
            + source("TenonApp/Canvas/SpatialCanvasNSView.swift")
        let workspaceProvider = try source("TenonApp/WorkspaceIntentProvider.swift")

        assertContains(
            launcher,
            [
                "case .open: host.commandIndex.launcherOnly",
                "case .fillEmptyGrid: host.commandIndex.paneFillersOnly",
                "var agentSuggestions: [AgentLaunchSuggestion]",
                "var launchAgent: ((AgentLaunchSuggestion) -> LauncherOutcome)?",
                "var copyTabID: (() -> Void)?",
                "var paneArrangements: [PaneArrangementPreset]",
                "var arrangePanes: ((PaneArrangementPreset) -> Void)?",
                // The footer's presentation is the shared chrome every other row in the
                // popover draws, so its geometry and hover come from one place
                // (`CMD-NFR-008`); its behaviour is pinned by the chrome test below.
                "title: Text(\"Copy Tab ID\")",
                "tenon.launcher.copyTabID",
            ],
            file: "LauncherMenu.swift"
        )
        let launcherCommandRun = try sourceSlice(
            launcher,
            from: "private func run(_ match: CommandMatch)",
            before: "\n    }\n}"
        )
        let prepareOffset = try XCTUnwrap(
            launcherCommandRun.range(of: "PaletteIntentInvoker.prepare(")?.lowerBound
        )
        let taskOffset = try XCTUnwrap(
            launcherCommandRun.range(of: "Task { @MainActor in")?.lowerBound
        )
        XCTAssertLessThan(
            prepareOffset,
            taskOffset,
            "a visible launcher row must bind its exact provider and gesture at the accepted click, before async lifecycle work can invalidate the lookup"
        )
        assertContains(
            launcherCommandRun,
            [
                "send(invocation)",
                "PaletteIntentInvoker.send(",
                "invocation,",
            ],
            file: "LauncherMenu.swift command dispatch"
        )
        let tabChipLauncher = try sourceSlice(
            titleBar,
            from: "openLauncher: { contextLauncherTab = tab.id }",
            before: "ShellIconButton(symbol: \"plus\", help: \"Open something new\")"
        )
        assertContains(
            tabChipLauncher,
            ["tabLauncher(for: tab)"],
            file: "ShellTitleBar.swift tab-chip launcher anchor"
        )
        let tabLauncher = try sourceSlice(
            titleBar,
            from: "private func tabLauncher(for tab: TenonCore.Tab) -> LauncherMenu",
            before: "private var rightZone: some View"
        )
        assertContains(
            tabLauncher,
            [
                "LauncherMenu(",
                "placement: .tab(tab.id)",
                "await send(invocation, onTab: tab.id)",
                "copyTabID: { WorkspaceIdentifierClipboard.copy(tab.id) }",
                "paneArrangements: arrangements(for: tab)",
                "store.arrangeActiveTab(preset)",
            ],
            file: "ShellTitleBar.swift tab-chip launcher content"
        )
        XCTAssertFalse(
            tabLauncher.contains("sendInNewTab"),
            "the tab-chip anchor must keep targeting the clicked tab"
        )
        let tabChip = try sourceSlice(
            titleBar,
            from: "struct TabChip: View",
            before: "struct TabStripSurface"
        )
        assertContains(
            tabChip,
            [
                "let openLauncher: () -> Void",
                ".overlay(RightClickCatcher(action: openLauncher))",
                "struct RightClickCatcher: NSViewRepresentable",
                "NSEvent.addLocalMonitorForEvents",
                "override func hitTest(_ point: NSPoint) -> NSView? { nil }",
            ],
            file: "ShellTitleBar.swift tab-chip right-click"
        )
        XCTAssertFalse(
            tabChip.contains("NSApp.currentEvent"),
            "the right-click observer must never enter hit-testing or steal a tab drag"
        )
        XCTAssertTrue(
            titleBar.contains("TabStripSurface("),
            "the shared launcher seam must preserve the strip's own pointer surface"
        )
        // The strip is drawn inside the title-bar band, and AppKit builds a drag region for
        // that band which the window server moves the window from. A view leaves the region
        // by answering `mouseDownCanMoveWindow` with `false`, being an `NSControl`, **and
        // accepting first responder** — the region builder ignores a plain NSView saying it,
        // and puts a control that refuses first responder back inside. Three fixes shipped
        // against the first half of that rule, and a fourth shipped against the second: this
        // file used to require `acceptsFirstResponder = false` here, which is precisely what
        // handed every chip back to the window server.
        XCTAssertTrue(
            titleBar.contains("override var mouseDownCanMoveWindow: Bool { false }"),
            "a tab drag must stay in the app instead of becoming a window move"
        )
        XCTAssertTrue(
            titleBar.contains("final class SurfaceView: NSControl"),
            "only an NSControl descendant is honoured by the window's drag-region builder"
        )
        XCTAssertFalse(
            titleBar.contains("override var acceptsFirstResponder"),
            """
            answering acceptsFirstResponder at all puts the chips back inside the drag \
            region; the keyboard is kept by never calling super in the mouse path, and \
            TabStripReorderTests drives that consequence rather than asserting the property
            """
        )
        XCTAssertTrue(
            titleBar.contains("override var canBecomeKeyView: Bool { false }"),
            "the strip still stays out of the Tab key-view loop, which the region tolerates"
        )
        // T-105: a chip's fallback name is the tab's own number. Deriving it from the tab's
        // place made a working reorder invisible — the chips swapped and the labels swapped
        // back — so the strip is held to reading the number off the tab.
        XCTAssertTrue(
            titleBar.contains(#""Terminal \(tab.number)""#),
            "a chip's fallback name must come from the tab, not from where the tab stands"
        )
        XCTAssertFalse(
            titleBar.contains("index + 1"),
            "numbering a tab by its position renames it every time the strip is reordered"
        )
        XCTAssertTrue(
            titleBar.contains("pressed: pressStrip") && titleBar.contains("hovered: hoverStrip"),
            "owning the strip's pointer means owning the click and the hover it took"
        )
        // A surface that claims the point only sometimes leaves the window server holding it
        // the rest of the time, which is how the first fix for this failed.
        XCTAssertFalse(
            titleBar.contains("NSApplication.shared.currentEvent")
                || titleBar.contains("claimsPointer"),
            "the strip's surface must claim its region unconditionally, not per event"
        )
        XCTAssertTrue(
            try source("TenonApp/WindowChrome.swift").contains("isMovableByWindowBackground = false")
                && titleBar.contains("WindowDragArea(color: TenonTheme.chromeNS)"),
            "only the empty title bar asks for a window drag, and it asks explicitly"
        )
        XCTAssertFalse(
            tabChip.contains(".contextMenu"),
            "a tab right-click must open LauncherMenu directly, not a native menu first"
        )
        XCTAssertFalse(
            titleBar.contains("Open Something New…"),
            "the tab launcher must not add an intermediate Open Something New item"
        )
        let plusLauncher = try sourceSlice(
            titleBar,
            from: "ShellIconButton(symbol: \"plus\", help: \"Open something new\")",
            before: "GeometryReader { proxy in"
        )
        assertContains(
            plusLauncher,
            [
                "LauncherMenu(",
                "placement: .newTab",
                "await sendInNewTab(invocation)",
            ],
            file: "ShellTitleBar.swift plus launcher"
        )
        XCTAssertFalse(
            plusLauncher.contains("send(invocation, onTab:"),
            "the plus anchor must never inherit an existing tab"
        )
        let newTabDispatch = try sourceSlice(
            titleBar,
            from: "private func sendInNewTab(",
            before: "/// Width the tab chips actually need"
        )
        assertContains(
            newTabDispatch,
            [
                "userGestureID: invocation.userGestureID",
                "PaletteIntentInvoker.send(",
            ],
            file: "ShellTitleBar.swift plus dispatch"
        )
        XCTAssertFalse(
            newTabDispatch.contains("PaletteIntentInvoker.prepare("),
            "an anchor must carry the click-bound invocation instead of resolving the row again"
        )
        assertContains(
            workspaceProvider,
            ["NewTabLauncherPlacement.consumeReservedTabCreation("],
            file: "WorkspaceIntentProvider.swift tab-create reservation"
        )
        assertContains(
            canvas,
            [
                "emptyGridLauncherAnchor(",
                "emptyGridLauncherTarget(",
                "accessibilityCustomActions()",
                "requestBestEmptyGridLauncher()",
                "LauncherMenu(",
            ],
            file: "Canvas/*.swift"
        )
        let emptyGridLauncher = try sourceSlice(
            canvas,
            from: "NSHostingController(rootView: LauncherMenu(",
            before: "))\n        launcherPopover"
        )
        assertContains(
            emptyGridLauncher,
            [
                "purpose: .fillEmptyGrid",
                "send:",
                "placement: .emptyGrid(targetRect)",
                "EmptyGridLauncherPlacement.invoke(",
                "targetRect: targetRect",
            ],
            file: "Canvas empty-grid launcher"
        )
        let appRoot = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TenonApp")
        let projectionOwners = try swiftFiles(under: appRoot).compactMap { file in
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

        let manifest = try source("TenonCore/PluginManifest.swift")
        let commandIndex = try source("TenonCore/CommandIndex.swift")
        assertContains(
            manifest,
            ["public let fillsPane: Bool", "case fillsPane"],
            file: "PluginManifest.swift"
        )
        assertContains(
            commandIndex,
            ["public var paneFillersOnly: CommandIndex", "$0.isLauncher && $0.fillsPane"],
            file: "CommandIndex.swift"
        )
    }

    func testWorkspaceReorderStaysOnOneLocalTypedPath() throws {
        let rule = try source("TenonCore/WorkspaceReorder.swift")
        let workspace = try source("TenonCore/Workspace.swift")
        let store = try source("TenonCore/WorkspaceStore.swift")
        let sidebar = try source("TenonApp/WorkspaceSidebarView.swift")

        assertContains(
            rule,
            [
                "public enum WorkspaceReorder",
                "public static func insertionIndex(",
                "public static func destination(",
                "public static func spokenPosition(",
            ],
            file: "WorkspaceReorder.swift"
        )
        assertContains(
            workspace,
            [
                "case workspaceMoved(workspace: UUID, from: Int, to: Int)",
                "public mutating func moveWorkspace(_ id: UUID, to index: Int)",
                ".workspaceMoved(workspace: id, from: from, to: index)",
            ],
            file: "Workspace.swift"
        )
        assertContains(
            store,
            [
                "public func moveWorkspace(_ id: UUID, to index: Int)",
                "apply { $0.moveWorkspace(id, to: index) }",
                "case let .workspaceMoved(workspace, from, to)",
                #""workspace.moved""#,
            ],
            file: "WorkspaceStore.swift"
        )
        assertContains(
            sidebar,
            [
                ".simultaneousGesture(reorderGesture(for: workspace.id))",
                "DragGesture(",
                "WorkspaceSidebarLayout.reorderThreshold",
                "store.moveWorkspace(workspaceID, to: destination)",
                "private func restore(_ drag: WorkspaceSidebarDrag)",
                #"Button("Move workspace up")"#,
                #"Button("Move workspace down")"#,
            ],
            file: "WorkspaceSidebarView.swift"
        )
        for (name, implementation) in [
            ("WorkspaceReorder.swift", rule),
            ("WorkspaceSidebarView.swift", sidebar),
        ] {
            XCTAssertFalse(implementation.contains("NSPasteboard"), "\(name) opened a pasteboard route")
            XCTAssertFalse(implementation.contains(".draggable("), "\(name) opened a Transferable route")
            XCTAssertFalse(implementation.contains(".onDrag("), "\(name) opened a pasteboard drag route")
            XCTAssertFalse(implementation.contains("dispatcher.send("), "\(name) bypassed DIRECT ownership")
            XCTAssertFalse(implementation.contains("intentRuntime.send("), "\(name) bypassed DIRECT ownership")
        }
    }

    func testPaneArrangementStaysOnOneHostNativeDirectPath() throws {
        let rule = try source("TenonCore/PaneArrangement.swift")
        let menu = try source("TenonApp/PaneArrangementMenu.swift")
        let launcher = try source("TenonApp/LauncherMenu.swift")
        let titleBar = try source("TenonApp/ShellTitleBar.swift")

        assertContains(
            rule,
            [
                "public enum PaneArrangementPreset",
                "public static func availablePresets(",
                "public static func transaction(",
                "func arrangeActiveTab(_ preset: PaneArrangementPreset)",
                "applyResize(transaction)",
            ],
            file: "PaneArrangement.swift"
        )
        assertContains(
            menu,
            [
                "struct PaneArrangementMenu: View",
                "Button {",
                ".onHover(perform: hoverChanged)",
                "Task.sleep(for: .milliseconds(220))",
                "tenon.launcher.arrangePanes",
            ],
            file: "PaneArrangementMenu.swift"
        )
        assertContains(
            launcher,
            [
                "PaneArrangementMenu(",
                "presets: paneArrangements",
                "arrange: arrangePanes",
            ],
            file: "LauncherMenu.swift arrangement utility"
        )
        assertContains(
            titleBar,
            [
                "paneArrangements: arrangements(for: tab)",
                "store.selectTab(tab.id)",
                "store.arrangeActiveTab(preset)",
                "PaneArrangement.availablePresets(",
            ],
            file: "ShellTitleBar.swift arrangement target"
        )

        for (name, implementation) in [
            ("PaneArrangement.swift", rule),
            ("PaneArrangementMenu.swift", menu),
        ] {
            for forbidden in ["tenon.intents", "intentRuntime.send(", "dispatcher.send(", "PaletteIntentInvoker"] {
                XCTAssertFalse(
                    implementation.contains(forbidden),
                    "\(name) opened a second public path through \(forbidden)"
                )
            }
        }
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

        assertContains(
            chrome,
            [
                "struct PaletteRowChrome: View",
                "enum Density",
                "@State private var isHovered",
                ".onHover { isHovered = $0 }",
            ],
            file: "PaletteRowChrome.swift"
        )
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

        // The fixed tab utility draws through the same chrome and stays the one row that can
        // never carry the selected accent, because it never enters the ranked order at all.
        let footer = try sourceSlice(
            launcher,
            from: "if let copyTabID {",
            before: ".frame(width: 300)"
        )
        assertContains(
            footer,
            [
                "PaletteRowChrome(",
                "isSelected: false",
                "density: .compact",
                "tenon.launcher.copyTabID",
            ],
            file: "LauncherMenu.swift Copy Tab ID footer"
        )
        XCTAssertTrue(
            try source("TenonApp/LauncherListHeight.swift")
                .contains("PaletteRowChrome.Density.compact.height"),
            "the launcher's height arithmetic must read the same metrics the rows draw with"
        )
    }

    func testPersonalRunbooksStayOnTheHostNativeDirectPath() throws {
        let model = try source("TenonApp/QuickCommands.swift")
        let views = try source("TenonApp/QuickCommandViews.swift")
        let titleBar = try source("TenonApp/ShellTitleBar.swift")
        let terminalProvider = try source("TenonApp/TerminalIntentProvider.swift")

        assertContains(
            model,
            [
                "enum QuickCommandRunner",
                "enum QuickCommandDestination",
                "static let maximumCount = 40",
                "static let maximumBodyLength = 6_000",
                "workspaceStore.newTab(content: .terminal)",
                "terminalPool.sendTextWhenReady(",
                "AutomationAuthoring.posixQuoted(command.body)",
            ],
            file: "QuickCommands.swift"
        )
        assertContains(
            views,
            [
                "Text(\"Runbooks\")",
                "QuickCommandExecutor.run(",
                "QuickCommandRunner.allCases",
                "QuickCommandDestination.focusedTerminal",
                "QuickCommandDestination.newTab",
            ],
            file: "QuickCommandViews.swift"
        )
        assertContains(
            titleBar,
            ["QuickCommandControl(", "commands: quickCommands"],
            file: "ShellTitleBar.swift"
        )
        assertContains(
            terminalProvider,
            ["surfaces.sendTextWhenReady("],
            file: "TerminalIntentProvider.swift"
        )

        for (name, implementation) in [
            ("QuickCommands.swift", model),
            ("QuickCommandViews.swift", views),
        ] {
            XCTAssertFalse(implementation.contains("tenon.intents"), "\(name) opened a public path")
            XCTAssertFalse(implementation.contains("PaletteIntentInvoker"), "\(name) entered the palette adapter")
            XCTAssertFalse(implementation.contains("intentRuntime.send("), "\(name) bypassed DIRECT ownership")
            XCTAssertFalse(implementation.contains("dispatcher.send("), "\(name) bypassed DIRECT ownership")
        }
    }

    func testAutomationOperationsStayOnCanvasAndItsPublicOpenerUsesExistingBoundaries() throws {
        let automationView = try source("TenonApp/AutomationSlotView.swift")
        let composition = try source("TenonApp/TenonApp.swift")
        let settings = try source("TenonApp/SettingsView.swift")
        let coreCatalog = try source("TenonCore/CoreIntentCatalog.swift")
        let envelope = try source("TenonIntentCore/IntentEnvelope.swift")
        let bootstrap = try source("TenonCore/PluginRuntimeBootstrap.swift")
        let pluginRoot = packageRoot
            .appendingPathComponent("plugins")
            .appendingPathComponent("core-commands")
        let manifest = try String(
            contentsOf: pluginRoot.appendingPathComponent("manifest.json"),
            encoding: .utf8
        )
        let implementation = try source(
            "TenonBundledPlugins/CoreCommandsPlugin.swift"
        )

        assertContains(
            automationView,
            [
                "struct AutomationPaneActions",
                "let runNow: (PluginID, String) async -> Void",
                "let setPaused: (PluginID, String, Bool) -> Void",
                "let createWithAI: () -> Void",
                "let summaries = AutomationPanePresentation.summaries(",
                "listings: automation.listings()",
                "automation.runHistory.records",
                "AutomationScheduleNavigator(",
                "AutomationScheduleDetail(",
                "actions.setPaused(",
                "await actions.runNow(summary.pluginID, summary.scheduleID)",
            ],
            file: "AutomationSlotView.swift"
        )
        for publicAdapter in [
            "AppIntentRuntime",
            "PaletteIntentInvoker",
            "IntentValue",
            "intentRuntime.send(",
            "dispatcher.send(",
            "tenon.intents",
        ] {
            XCTAssertFalse(
                automationView.contains(publicAdapter),
                "AutomationSlotView.swift must invoke typed host actions DIRECT; found \(publicAdapter)"
            )
        }
        assertContains(
            composition,
            [
                "func setAutomationSchedulePaused(",
                "prefs.preferences.pausedAutomationSchedules.insert(key)",
                "prefs.preferences.pausedAutomationSchedules.remove(key)",
                "automationScheduler.setPausedScheduleKeys(",
            ],
            file: "TenonApp.swift Automation preference wiring"
        )
        let stopLifecycle = try sourceSlice(
            composition,
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

        let automationSettings = try sourceSlice(
            settings,
            from: "private struct AutomationSettingsDetail: View",
            before: "// MARK: - CLI"
        )
        assertContains(
            automationSettings,
            [
                "Toggle(",
                "isOn: $prefs.preferences.automationSchedulesEnabled",
                "Run Now remains",
                "Automation view on the Canvas",
            ],
            file: "SettingsView.swift Automation settings"
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

        assertContains(
            manifest,
            [
                #""id": "dev.tenon.core-commands""#,
                #""runtime": "bundled-swift""#,
            ],
            file: "core-commands/manifest.json"
        )
        let automationContribution = try sourceSlice(
            manifest,
            from: #""name": "dev.tenon.core-commands.automation.open.v1""#,
            before: #""name": "dev.tenon.core-commands.tab.next.v1""#
        )
        assertContains(
            automationContribution,
            [
                #""audiences": ["plugin", "user"]"#,
                #""palette": { "category": "Open""#,
                #""launcher": true"#,
                #""fillsPane": true"#,
            ],
            file: "core-commands/manifest.json Automation contribution"
        )
        XCTAssertEqual(
            manifest.components(
                separatedBy: "dev.tenon.core-commands.automation.open.v1"
            ).count - 1,
            1,
            "the plugin owns exactly one Automation opener contract"
        )

        let automationHandler = try sourceSlice(
            implementation,
            from: #"case "dev.tenon.core-commands.automation.open.v1":"#,
            before: #"case "dev.tenon.core-commands.tab.next.v1":"#
        )
        assertContains(
            automationHandler,
            [
                #"return await send("#,
                #""workspace.tab.create.v1""#,
                #""kind": .string("automation")"#,
            ],
            file: "CoreCommandsPlugin.swift Automation handler"
        )
        assertContains(
            implementation,
            [
                "let result = await context.send(",
                "IntentProviderSendRequest(",
            ],
            file: "CoreCommandsPlugin.swift causal nested-send adapter"
        )
        XCTAssertFalse(
            automationHandler.contains("dev.tenon.core.workspace.tab.create.v1"),
            "the nested send must use the existing canonical core intent name"
        )

        let coreIntentInventory = try sourceSlice(
            coreCatalog,
            from: "public enum CoreIntentName: String",
            before: "/// The only audience profiles available"
        )
        let laneInventory = try sourceSlice(
            coreCatalog,
            from: "public enum CoreIntentExecutionLane: String",
            before: "public var maxConcurrentRequests: Int {"
        )
        let audienceInventory = try sourceSlice(
            envelope,
            from: "public enum IntentAudience: String",
            before: "public struct IntentPrincipal"
        )
        for (name, inventory, expectedCases) in [
            // 48 → 49 and 12 → 13 (T-139). The addition is one finite agent question and
            // its bounded wait lane; the `contains("automation")` assertion below is what
            // continues to hold the automation boundary.
            // 49 → 50 (T-147): one pane title an agent may set on its own pane, on the
            // existing workspace lane — no new lane, no new audience.
            // 50 → 51 (T-154): workspace identity is one finite request/reply on the
            // existing workspace lane — no new lane, audience, capability, or control op.
            ("CoreIntentName", coreIntentInventory, 51),
            ("CoreIntentExecutionLane", laneInventory, 13),
            ("IntentAudience", audienceInventory, 5),
        ] {
            XCTAssertEqual(
                inventory.components(separatedBy: "    case ").count - 1,
                expectedCases,
                "Automation must not expand the closed \(name) inventory"
            )
            XCTAssertFalse(
                inventory.lowercased().contains("automation"),
                "Automation must not introduce a \(name)"
            )
        }

        let tenonSurface = try sourceSlice(
            bootstrap,
            from: "globalThis.tenon = Object.freeze({",
            before: "Object.defineProperty(globalThis, \"__tenonActivate\""
        )
        let topLevelMembers = Set(
            tenonSurface.split(separator: "\n").compactMap { line -> String? in
                let text = String(line)
                guard text.hasPrefix("            "),
                      !text.hasPrefix("             ")
                else { return nil }
                let member = text.trimmingCharacters(in: .whitespaces)
                if member.hasPrefix("log(") { return "log" }
                guard member.hasSuffix(",") else { return nil }
                return member
                    .dropLast()
                    .split(separator: ":", maxSplits: 1)
                    .first
                    .map(String.init)
            }
        )
        XCTAssertEqual(
            topLevelMembers,
            [
                "apiVersion", "intents", "agents", "settings", "storage",
                "path", "events", "timers", "process", "fs", "statusBar",
                "views", "palette", "log",
            ],
            "Automation must not add a public tenon member"
        )
        XCTAssertFalse(tenonSurface.lowercased().contains("automation"))
    }

    func testDetectedAgentLaunchSuggestionsStayBoundedAndHostNative() throws {
        let implementation = try source("TenonApp/AgentLaunchSuggestions.swift")
        let content = try source("TenonApp/ContentView.swift")
        let launcher = try source("TenonApp/LauncherMenu.swift")
        let emptyState = try source("TenonApp/EmptyStateCard.swift")
        let workspaceStage = try source("TenonApp/WorkspaceStageView.swift")
        let slots = try source("TenonApp/BuiltInSlotViews.swift")

        assertContains(
            implementation,
            [
                "static let maximumHistoryBytesPerFile = 512 * 1_024",
                "return await Task.detached(priority: .utility)",
                "AgentCLI.allCases.compactMap",
                "--dangerously-bypass-approvals-and-sandbox",
                "--dangerously-skip-permissions",
                "enum AgentLaunchExecutor",
                "workspaceStore.newTab(content: .terminal)",
                "workspaceStore.addSlot(content: .terminal, at: rect)",
                "terminalPool.sendTextWhenReady(",
            ],
            file: "AgentLaunchSuggestions.swift"
        )
        assertContains(
            content,
            [
                "@State private var agentSuggestions: [AgentLaunchSuggestion] = []",
                "agentSuggestions = await AgentLaunchDetector.scanLive()",
            ],
            file: "ContentView.swift"
        )
        assertContains(
            launcher,
            [
                "agentSuggestions: [AgentLaunchSuggestion]",
                "run(agent.suggestion)",
                "let outcome = launchAgent(suggestion)",
            ],
            file: "LauncherMenu.swift"
        )
        assertContains(
            emptyState,
            [
                "SectionLabel(\"Start an agent\")",
                "ForEach(agentSuggestions)",
                "Button(action: action)",
            ],
            file: "EmptyStateCard.swift"
        )
        assertContains(
            workspaceStage,
            ["placement: .emptyTab"],
            file: "WorkspaceStageView.swift"
        )
        assertContains(
            slots,
            ["placement: .emptySlot(slotID)"],
            file: "BuiltInSlotViews.swift"
        )

        for forbidden in [
            "tenon.intents",
            "PaletteIntentInvoker",
            "intentRuntime.send(",
            "dispatcher.send(",
        ] {
            XCTAssertFalse(
                implementation.contains(forbidden),
                "detected agent launch opened a public path through \(forbidden)"
            )
        }
    }

    func testCommandPaletteDocumentStatesCurrentKeyBindingContract() throws {
        let documentURL = packageRoot
            .appendingPathComponent("docs/design-command-palette.md")
        let document = try String(contentsOf: documentURL, encoding: .utf8)
        let keybindings = try sourceSlice(
            document,
            from: "## Keybindings",
            before: "## Dynamic results"
        )
        let normalizedKeybindings = keybindings
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        assertContains(
            document,
            [
                "**Status:** complete",
                #""key": "cmd+d""#,
            ],
            file: "design-command-palette.md"
        )
        assertContains(
            normalizedKeybindings,
            [
                "The closed shell reservation set is exactly",
                "`cmd+shift+p`",
                "`cmd+,`",
                "`cmd+q`",
                "`cmd+h`",
                "`cmd+option+h`",
                "`cmd+m`",
                "lexicographically smallest `(pluginID, intentID)`",
            ],
            file: "design-command-palette.md Keybindings"
        )
        for staleTerm in [
            #""shortcut""#,
            "migration in progress",
            "user override",
            "first stable provider order",
        ] {
            XCTAssertFalse(
                document.contains(staleTerm),
                "design-command-palette.md still contains \(staleTerm)"
            )
        }
    }

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

    /// The pane header is CONTRIBUTION (plugin) and DIRECT (host-native), and stays there.
    ///
    /// A header carries no result cardinality and exercises no cross-principal authority, so
    /// the interaction law stops long before INTENT. Nothing asserts that by itself — the
    /// classification is only as durable as the code that honours it — so the vocabulary's own
    /// files are swept for the three ways a Swift file reaches the intent path and for the
    /// minting of a principal.
    func testPaneHeaderCodeStaysContributionAndDirect() throws {
        let paneHeaderSources = [
            "TenonCore/PaneHeader.swift",
            "TenonCore/PaneHeaderItem.swift",
            "TenonApp/PaneHeaderStore.swift",
            "TenonApp/PaneHeaderCommand.swift",
            "TenonApp/PaneHeaderLayout.swift",
            "TenonApp/PaneHeaderBar.swift",
            "TenonApp/PaneHeaderProjection.swift",
        ]
        for relativePath in paneHeaderSources {
            let implementation = try source(relativePath)
            for forbidden in [
                "tenon.intents",
                "intentRuntime.send(",
                "dispatcher.send(",
                "IntentPrincipal(",
            ] {
                XCTAssertFalse(
                    implementation.contains(forbidden),
                    "\(relativePath) put the pane header on the intent path through \(forbidden)"
                )
            }
        }
    }

    /// A header control that has words for the pointer has words for a screen reader too.
    ///
    /// On macOS `.help()` becomes an accessibility HELP — a hint — and never a label. So a
    /// control whose only words are its tooltip reaches VoiceOver named after its SF Symbol
    /// string rather than after the sentence its author wrote. That is not hypothetical: the
    /// The Agent Lens migration exposed the same failure shape on its diagnostics warning and
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

        for producer in ["TenonApp/DiffSlotView.swift", "TenonApp/ChangesPanelView.swift"] {
            assertContains(
                try source(producer),
                ["PaneHeaderCommand."],
                file: producer
            )
        }
    }

    func testPaneHeaderDocumentStatesCurrentSchema() throws {
        let documentURL = packageRoot
            .appendingPathComponent("docs/design-pane-header.md")
        let document = try String(contentsOf: documentURL, encoding: .utf8)

        assertContains(
            document,
            [
                "**Status:** implemented",
                "A pane draws exactly ONE header",
                "`leading`",
                "`trailing`",
                "**Two slots, not three.**",
                "PaneHeader.admitting",
                "case duplicateID",
                "case slotIsFull",
                "tenon.paneHeader.overflow",
                "refuse what cannot be DRAWN, degrade what cannot be READ",
                "rung 1, CONTRIBUTION",
                "rung 4, DIRECT",
                "`tenon.views.set`",
                "onSelect",
                "onSubmit",
                "Omitting `header` clears the previous one",
                "`accessibilityID` is not decodable from plugin JSON",
                "never a scroll",
                "There is no priority or pinning token",
                "PaneHeaderCommand",
                "WorkspaceStageView.body` reads `paneHeaders.headers",
            ],
            file: "design-pane-header.md"
        )

        let vocabulary = try sourceSlice(
            document,
            from: "### `PaneHeaderItem`",
            before: "### Bounds"
        )
        for itemType in [
            "`dot`",
            "`label`",
            "`badge`",
            "`image`",
            "`spinner`",
            "`iconButton`",
            "`toggle`",
            "`segmented`",
            "`menu`",
            "`textfield`",
        ] {
            XCTAssertTrue(
                vocabulary.contains(itemType),
                "design-pane-header.md omits the \(itemType) item from its vocabulary"
            )
        }

        for supersededPath in [
            "browserBar",
            "ViewAction",
            "BrowserBarView",
            "subtitle",
            "AgentLensModeBar",
        ] {
            XCTAssertFalse(
                document.contains(supersededPath),
                "design-pane-header.md teaches the superseded \(supersededPath)"
            )
        }
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

    func assertContains(
        _ source: String,
        _ anchors: [String],
        file: String,
        filePath: StaticString = #filePath,
        line: UInt = #line
    ) {
        for anchor in anchors {
            XCTAssertTrue(
                source.contains(anchor),
                "\(file) is missing semantic anchor: \(anchor)",
                file: filePath,
                line: line
            )
        }
    }

    func assertDirect(
        _ source: String,
        file: String,
        filePath: StaticString = #filePath,
        line: UInt = #line
    ) {
        for crossOwnerEntry in [
            "PaletteIntentInvoker",
            "IntentDispatcher",
            "IntentRequest",
            "intentRuntime",
            "dispatcher.send(",
            "runtime.send(",
        ] {
            XCTAssertFalse(
                source.contains(crossOwnerEntry),
                "\(file) must stay DIRECT; found \(crossOwnerEntry)",
                file: filePath,
                line: line
            )
        }
    }
}
