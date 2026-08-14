import XCTest
@testable import TenonCore

final class AppPreferencesTests: XCTestCase {
    // MARK: - DefaultPaneContent → SlotContent

    func testDefaultPaneContentMapsToSlotContent() {
        XCTAssertEqual(DefaultPaneContent.terminal.slotContent(), .terminal)
        XCTAssertEqual(
            DefaultPaneContent.files.slotContent(),
            .pluginView(pluginID: "dev.tenon.file-explorer", viewID: "tree")
        )
        XCTAssertEqual(DefaultPaneContent.changes.slotContent(), .changes)
        XCTAssertEqual(DefaultPaneContent.empty.slotContent(), .empty)
    }

    func testBrowserDefaultOpensTheBrowserPluginPane() {
        XCTAssertEqual(
            DefaultPaneContent.browser.slotContent(),
            .pluginView(pluginID: "dev.tenon.browser", viewID: "browser")
        )
    }

    func testEveryDefaultPaneContentHasANonEmptyLabel() {
        for content in DefaultPaneContent.allCases {
            XCTAssertFalse(content.label.isEmpty)
        }
    }

    // MARK: - AppPreferences value

    func testDefaultPreferencesOpenTerminalEverywhereWithSidebarShown() {
        let prefs = AppPreferences()
        XCTAssertEqual(prefs.newTabContent, .terminal)
        XCTAssertEqual(prefs.newSplitContent, .terminal)
        XCTAssertEqual(prefs.newWorkspaceContent, .terminal)
        XCTAssertNil(
            prefs.newPaneMaximumWidth,
            "with no maximum chosen, pane creation is bounded only by the layout"
        )
        XCTAssertTrue(prefs.sidebarVisibleOnLaunch)
        XCTAssertEqual(prefs.accent, .amber)
        XCTAssertTrue(prefs.automationSchedulesEnabled)
        XCTAssertTrue(prefs.pausedAutomationSchedules.isEmpty)
        XCTAssertEqual(prefs.companion.agent, .claude)
        XCTAssertEqual(prefs.companion.model, "haiku")
        XCTAssertTrue(prefs.companion.customPrompt.isEmpty)
        XCTAssertTrue(prefs.companion.workingDirectory.isEmpty)
    }

    func testPreferencesSurviveACodableRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.newTabContent = .files
        prefs.newSplitContent = .empty
        prefs.newWorkspaceContent = .changes
        prefs.newPaneMaximumWidth = .oneThird
        prefs.sidebarVisibleOnLaunch = false
        prefs.sidebarWidth = 300
        prefs.accent = .blue
        prefs.automationSchedulesEnabled = false
        prefs.pausedAutomationSchedules = [
            AutomationScheduleKey(
                pluginID: "dev.example.audit",
                scheduleID: "morning"
            ),
        ]
        prefs.companion = CompanionProfile(
            agent: .codex,
            model: "gpt-5.4",
            customPrompt: "Answer in Vietnamese",
            workingDirectory: "/tmp/tenon"
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(decoded, prefs)
    }

    func testPreferencesDecodeLenientlyWhenKeysAreMissing() throws {
        // A file written by an older build that only knew `newTabContent` must still
        // load, filling every absent field from the current defaults.
        let json = Data(#"{"newTabContent":"files"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(decoded.newTabContent, .files)
        XCTAssertEqual(decoded.newSplitContent, .terminal)
        XCTAssertEqual(decoded.newWorkspaceContent, .terminal)
        XCTAssertTrue(decoded.sidebarVisibleOnLaunch)
        XCTAssertEqual(decoded.accent, .amber)
        XCTAssertTrue(
            decoded.automationSchedulesEnabled,
            "older preference documents default scheduled delivery to enabled"
        )
        XCTAssertTrue(
            decoded.pausedAutomationSchedules.isEmpty,
            "older preference documents start with no per-schedule pauses"
        )
        XCTAssertEqual(
            decoded.companion,
            CompanionProfile(),
            "older preference documents gain the current Companion defaults"
        )
    }

    func testAnUnknownCompanionAgentCostsOnlyTheCompanionField() throws {
        let json = Data(
            #"{"newTabContent":"files","accent":"purple","companion":{"agent":"future-agent","model":"future-model","customPrompt":"keep","workingDirectory":"/tmp"}}"#
                .utf8
        )

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(decoded.newTabContent, .files)
        XCTAssertEqual(decoded.accent, .purple)
        XCTAssertEqual(decoded.companion.agent, .claude)
        XCTAssertEqual(
            decoded.companion.model,
            "haiku",
            "falling back to Claude must also restore a Claude-compatible model"
        )
        XCTAssertEqual(decoded.companion.customPrompt, "keep")
        XCTAssertEqual(decoded.companion.workingDirectory, "/tmp")
    }

    func testSwitchingCompanionAgentRestoresThatProvidersDefaultModel() {
        var profile = CompanionProfile()

        profile.agent = .codex
        XCTAssertEqual(
            profile.model,
            "",
            "Codex should use its configured default instead of inheriting Claude's Haiku"
        )

        profile.model = "gpt-5.4"
        profile.agent = .claude
        XCTAssertEqual(profile.model, "haiku")
    }

    func testBuggyPersistedCodexHaikuPairMigratesToProviderDefault() throws {
        let profile = try JSONDecoder().decode(
            CompanionProfile.self,
            from: Data(#"{"agent":"codex","model":"haiku"}"#.utf8)
        )

        XCTAssertEqual(profile.agent, .codex)
        XCTAssertTrue(profile.model.isEmpty)
        XCTAssertNil(profile.modelArgument)
    }

    func testCompanionProfileBoundsPersistedFreeText() throws {
        var profile = CompanionProfile()
        profile.model = String(repeating: "m", count: CompanionProfile.maximumModelBytes * 2)
        profile.customPrompt = String(
            repeating: "instruction ",
            count: CompanionProfile.maximumPromptBytes
        )
        profile.workingDirectory = "/" + String(
            repeating: "folder/",
            count: CompanionProfile.maximumWorkingDirectoryBytes
        )

        XCTAssertLessThanOrEqual(
            profile.model.utf8.count,
            CompanionProfile.maximumModelBytes
        )
        XCTAssertLessThanOrEqual(
            profile.customPrompt.utf8.count,
            CompanionProfile.maximumPromptBytes
        )
        XCTAssertLessThanOrEqual(
            profile.workingDirectory.utf8.count,
            CompanionProfile.maximumWorkingDirectoryBytes
        )
    }

    func testEveryPaneMaximumSurvivesTheRoundTripThatRestoresItAtLaunch() throws {
        for width in SpatialExtentFraction.allCases {
            var prefs = AppPreferences()
            prefs.newPaneMaximumWidth = width

            let data = try JSONEncoder().encode(prefs)
            let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

            XCTAssertEqual(decoded.newPaneMaximumWidth, width)
        }
    }

    func testAWidthThisBuildCannotNameLoadsAsNoMaximumRatherThanFailingTheFile() throws {
        // A newer Tenon's value, or a hand-edited file. The rest of the document must
        // still load, and an unreadable maximum must mean "let the layout decide" —
        // never a pane too narrow to use.
        let json = Data(#"{"newTabContent":"files","newPaneMaximumWidth":"oneSeventh"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertNil(decoded.newPaneMaximumWidth)
        XCTAssertEqual(decoded.newTabContent, .files)
    }

    /// The same rule as the width above, applied to the three pane-content keys — and it is
    /// the one that costs the most if it is missing. These keys are named in a document that
    /// also carries the accent, the sidebar width and every paused schedule, so a single word
    /// this build cannot read must cost that one key its value and nothing else. A retired
    /// pane content is the ordinary way to arrive here: the word was valid when it was
    /// written.
    func testAPaneContentThisBuildCannotNameCostsThatKeyOnlyAndNotTheDocument() throws {
        let json = Data(
            #"{"newTabContent":"docs","newSplitContent":"changes","accent":"purple","sidebarWidth":180}"#
                .utf8
        )

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertEqual(
            decoded.newTabContent,
            AppPreferences().newTabContent,
            "the unreadable key falls back to its default"
        )
        XCTAssertEqual(decoded.newSplitContent, .changes, "and its neighbour is untouched")
        XCTAssertEqual(decoded.accent, .purple)
        XCTAssertEqual(decoded.sidebarWidth, 180)
    }

    func testAPreferenceFileWrittenBeforeTheMaximumExistedStillLoads() throws {
        let json = Data(#"{"newTabContent":"files"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: json)

        XCTAssertNil(decoded.newPaneMaximumWidth)
    }

    func testEveryAccentColorHasALabelAndHex() {
        for accent in AccentColor.allCases {
            XCTAssertFalse(accent.label.isEmpty)
            XCTAssertLessThanOrEqual(accent.hex, 0xFFFFFF)
        }
    }
}
