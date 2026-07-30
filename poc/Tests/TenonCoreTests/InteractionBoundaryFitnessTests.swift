import Foundation
import TenonIntentCore
import XCTest

final class InteractionBoundaryFitnessTests: XCTestCase {
    func testPrincipalKindsAndAudiencesHaveNoGenericAppIdentity() {
        XCTAssertEqual(
            Set(IntentPrincipal.Kind.allCases.map(\.rawValue)),
            ["core", "plugin", "palette", "cli", "agent"]
        )
        XCTAssertEqual(
            Set(IntentAudience.allCases.map(\.rawValue)),
            ["core", "plugin", "palette", "cli", "agent"]
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
        assertContains(
            host,
            [
                "public struct PluginIntentPresentation",
                "let keyBindingRequests = nextIntentPresentations.compactMap",
                "let nextKeyBindingIndex = KeyBindingIndex(",
                "reserved: KeyBindingIndex.shellReserved",
                "key: palette.key",
                "intentPresentations = nextIntentPresentations",
                "keyBindingIndex = nextKeyBindingIndex",
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
            ["PaletteIntentInvoker.send("],
            file: "PaletteOverlay.swift"
        )
        assertContains(
            invoker,
            [
                "return await runtime.send(",
                "as: AppIntentRuntime.palettePrincipal",
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

    func testCommandPaletteDocumentStatesCurrentKeyBindingContract() throws {
        let documentURL = packageRoot
            .deletingLastPathComponent()
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
