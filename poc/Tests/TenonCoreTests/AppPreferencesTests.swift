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
        XCTAssertEqual(DefaultPaneContent.docs.slotContent(), .docs)
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
        XCTAssertTrue(prefs.sidebarVisibleOnLaunch)
        XCTAssertEqual(prefs.accent, .amber)
        XCTAssertTrue(prefs.automationSchedulesEnabled)
        XCTAssertTrue(prefs.pausedAutomationSchedules.isEmpty)
    }

    func testPreferencesSurviveACodableRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.newTabContent = .files
        prefs.newSplitContent = .empty
        prefs.newWorkspaceContent = .docs
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
    }

    func testEveryAccentColorHasALabelAndHex() {
        for accent in AccentColor.allCases {
            XCTAssertFalse(accent.label.isEmpty)
            XCTAssertLessThanOrEqual(accent.hex, 0xFFFFFF)
        }
    }
}
