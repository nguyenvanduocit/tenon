import SwiftUI
import XCTest
@testable import TenonApp

/// T-098. The footer's product rules, asserted without a window: which utilities it offers,
/// where each one lands, and the density budget that keeps it quieter than the workspace
/// list it sits under.
final class SidebarFooterTests: XCTestCase {
    // MARK: - The actions survive the restyle

    func testTheFooterOffersExactlyTheThreeHostUtilities() {
        XCTAssertEqual(SidebarFooterAction.allCases, [.help, .feedback, .settings])
    }

    func testEachActionKeepsTheDestinationItAlreadyHad() {
        XCTAssertEqual(
            SidebarFooterAction.help.destination,
            .url(URL(string: "https://github.com/nguyenvanduocit/tenon")!)
        )
        XCTAssertEqual(
            SidebarFooterAction.feedback.destination,
            .url(URL(string: "https://github.com/nguyenvanduocit/tenon/issues/new")!)
        )
        XCTAssertEqual(SidebarFooterAction.settings.destination, .appSettings)
    }

    /// The identifiers are what a UI test and VoiceOver navigation address; a restyle that
    /// renames them silently breaks both.
    func testEachActionKeepsItsAccessibilityIdentifier() {
        XCTAssertEqual(SidebarFooterAction.help.accessibilityIdentifier, "tenon.sidebarHelp")
        XCTAssertEqual(SidebarFooterAction.feedback.accessibilityIdentifier, "tenon.sidebarFeedback")
        XCTAssertEqual(SidebarFooterAction.settings.accessibilityIdentifier, "tenon.sidebarSettings")
    }

    /// Icon-only controls: the title is the tooltip and the spoken label, so every action
    /// needs both a name and a symbol or it reaches a VoiceOver user as an unlabelled button.
    func testEveryActionCarriesANameAndASymbol() {
        for action in SidebarFooterAction.allCases {
            XCTAssertNotEqual(action.title, "", "\(action) has no name to speak or show")
            XCTAssertFalse(action.symbol.isEmpty, "\(action) has no symbol to draw")
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil),
                "\(action) names a symbol this system cannot draw: \(action.symbol)"
            )
        }
    }

    // MARK: - The density budget

    /// `docs/designs.md`: a compact control is 28–32 pt, and that band is also the hit
    /// target. Below it the footer stops being pointable; above it, it stops being compact.
    func testControlsSitInTheCompactBand() {
        XCTAssertGreaterThanOrEqual(SidebarFooterLayout.controlSide, 28)
        XCTAssertLessThanOrEqual(SidebarFooterLayout.controlSide, 32)
        XCTAssertEqual(SidebarFooterLayout.controlRadius, 6, "designs.md: control radius is 6 pt")
    }

    /// The footer is one control tall plus breathing room — never taller than the strip a
    /// pane uses to name itself, which is the densest band in the shell.
    func testTheFooterIsNoTallerThanAPaneHeaderStrip() {
        XCTAssertGreaterThanOrEqual(SidebarFooterLayout.height, SidebarFooterLayout.controlSide)
        XCTAssertLessThanOrEqual(SidebarFooterLayout.height, TenonTheme.slotHeaderHeight)
    }

    /// The rule that answers "usable at the sidebar's minimum width": three controls, their
    /// gaps and the sidebar's own inset must fit inside `SidebarResize.minWidth`, or one of
    /// them is clipped at the width the sidebar is allowed to stay open at.
    func testTheRowFitsTheNarrowestSidebarTheAppAllows() {
        let needed = SidebarFooterLayout.minimumWidth(
            actionCount: SidebarFooterAction.allCases.count
        )
        XCTAssertLessThanOrEqual(needed, SidebarResize.minWidth)
        XCTAssertLessThanOrEqual(needed, SidebarResize.defaultWidth)
    }

    /// The width rule has to actually count the controls, otherwise it answers `true` for a
    /// footer that has outgrown the sidebar.
    func testTheWidthRuleGrowsWithTheNumberOfControls() {
        let three = SidebarFooterLayout.minimumWidth(actionCount: 3)
        let four = SidebarFooterLayout.minimumWidth(actionCount: 4)
        XCTAssertEqual(
            four - three,
            SidebarFooterLayout.controlSide + SidebarFooterLayout.spacing
        )
        XCTAssertGreaterThan(four, SidebarResize.minWidth, "a fourth utility no longer fits")
        XCTAssertEqual(
            SidebarFooterLayout.minimumWidth(actionCount: 0),
            SidebarFooterLayout.horizontalInset * 2
        )
    }

    // MARK: - Version left the sidebar

    func testVersionReadsAsOneSummary() {
        XCTAssertEqual(AppVersion(short: "0.1.0", build: "1").summary, "v0.1.0 (1)")
    }

    /// `swift run tenon` has no `Info.plist`. Reporting that as an empty or zero version
    /// would read as a shipped build; it reads as unknown instead.
    func testABundleWithoutVersionKeysReportsUnknownRatherThanNothing() throws {
        let empty = try emptyBundle()
        let version = AppVersion.read(from: empty)
        XCTAssertEqual(version.short, AppVersion.unknown)
        XCTAssertEqual(version.build, AppVersion.unknown)
        XCTAssertFalse(version.summary.isEmpty)
    }

    func testAVersionedBundleIsReadFromItsOwnKeys() throws {
        let bundle = try bundle(shortVersion: "1.4.2", build: "37")
        XCTAssertEqual(AppVersion.read(from: bundle), AppVersion(short: "1.4.2", build: "37"))
        XCTAssertEqual(AppVersion.read(from: bundle).summary, "v1.4.2 (37)")
    }

    /// Criterion 2 of T-098, and the one a layout constant cannot state: the version no
    /// longer occupies the sidebar at all. It is a source check because "the sidebar draws
    /// no version" is a claim about what is absent, and only the source can be asked that.
    func testTheSidebarDrawsNoVersionOfItsOwn() throws {
        for file in ["Sources/TenonApp/SidebarFooter.swift", "Sources/TenonApp/WorkspaceSidebarView.swift"] {
            let url = packageRoot.appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains("CFBundleShortVersionString") || source.contains("AppVersion"),
                "\(file) reads the app version again — it belongs to Settings now"
            )
        }
    }
}

// MARK: - Fixtures

private extension SidebarFooterTests {
    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A real `Bundle` over a temporary directory: the version reader takes a bundle rather
    /// than reaching for `.main` precisely so this is possible without a window or an app.
    func bundle(shortVersion: String?, build: String?) throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tenon-version-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var info: [String: Any] = ["CFBundleIdentifier": "dev.tenon.test.\(UUID().uuidString)"]
        if let shortVersion { info["CFBundleShortVersionString"] = shortVersion }
        if let build { info["CFBundleVersion"] = build }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: root.appendingPathComponent("Info.plist"))

        return try XCTUnwrap(Bundle(url: root), "no bundle at \(root.path)")
    }

    func emptyBundle() throws -> Bundle {
        try bundle(shortVersion: nil, build: nil)
    }
}
