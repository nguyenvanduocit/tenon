import AppKit
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

/// T-097: the customisation popover. The naming, marking and tinting rules are asserted
/// without a window in `WorkspaceIdentityTests`; what needs AppKit is here — whether the
/// curated marks actually draw on this system, and whether the form fits the budget
/// `docs/designs.md` sets for a compact surface.
@MainActor
final class WorkspaceIdentityFormTests: XCTestCase {
    private let projectPath = URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)

    /// A closed vocabulary is only worth having if every case draws. A misspelled or
    /// unavailable SF Symbol renders as nothing at all, which reads as a missing icon
    /// rather than as a bug — so the vocabulary is checked against the running system.
    func testEveryMarkInTheVocabularyDrawsOnThisSystem() {
        for symbol in WorkspaceSymbol.allCases {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: symbol.systemName,
                    accessibilityDescription: symbol.label
                ),
                """
                WorkspaceSymbol.\(symbol.rawValue) names "\(symbol.systemName)", which does \
                not draw on this system — the picker would show an empty square.
                """
            )
        }
    }

    /// The grid is computed from the popover's width, so this pins what that computation
    /// owes: every mark has a place, no row overflows the content box, and the rows are
    /// even — filling each row to the width instead gives 8 marks then a stub row of 4.
    func testTheMarkGridIsEvenAndFitsInsideThePopoversContentWidth() {
        let metrics = WorkspaceIdentityFormMetrics.self
        let columns = metrics.columns
        let rows = metrics.markRows
        let count = WorkspaceSymbol.allCases.count
        let occupied = CGFloat(columns) * metrics.swatch
            + CGFloat(columns - 1) * metrics.swatchSpacing

        XCTAssertGreaterThan(columns, 1)
        XCTAssertLessThanOrEqual(occupied, metrics.width - metrics.inset * 2)
        XCTAssertGreaterThanOrEqual(
            rows * columns,
            count,
            "the grid must have room for every mark in the vocabulary"
        )
        XCTAssertLessThan(
            (rows * columns) - count,
            rows,
            "the marks are spread evenly, so the last row is never a stub"
        )
    }

    /// Every tint offered, including Automatic, is one control with a name.
    func testTheTintVocabularyOffersAutomaticAndEveryNamedColour() {
        let offered: [AccentColor?] = [nil] + AccentColor.allCases.map { $0 }

        XCTAssertEqual(offered.count, AccentColor.allCases.count + 1)
        XCTAssertTrue(AccentColor.allCases.allSatisfy { !$0.label.isEmpty })
    }

    /// A workspace nobody has tinted is drawn in the colour its own folder derives, so a
    /// catalog that has never been customised still reads as a set of distinct workspaces.
    func testAnUntintedWorkspaceCarriesTheColourItsFolderDerives() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        let plain = try XCTUnwrap(store.catalog.activeWorkspace)

        XCTAssertEqual(
            WorkspaceMark.tint(for: plain),
            Color(tintHex: WorkspaceTint.derived(forPath: projectPath))
        )
        XCTAssertNotEqual(WorkspaceMark.tint(for: plain), TenonTheme.muted)
    }

    /// The mark carries the workspace's colour on every row, selected or not: a colour that
    /// appeared only on selection appeared only once it was no longer needed. Selection is
    /// the row's job — the fill and the text say it, and the counts and the mark's own word
    /// still say what it is without leaning on hue.
    func testEveryRowShowsItsOwnTintWhetherOrNotItIsSelected() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.setWorkspaceAppearance(
            store.catalog.activeWorkspaceID,
            to: WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        let tinted = try XCTUnwrap(store.catalog.activeWorkspace)

        XCTAssertEqual(
            WorkspaceMark.tint(for: tinted),
            Color(tintHex: AccentColor.green.hex),
            "a chosen colour is the colour, wherever the row sits in the selection"
        )
    }

    /// The whole path from a workspace's folder to the colour the mark is drawn in, end to
    /// end: two uncustomised workspaces reach the shell as two different colours. How often
    /// that holds across a full sidebar is the core suite's question; that it holds at all
    /// through the view is this one's.
    func testTwoUncustomisedWorkspacesReachTheShellAsDifferentColours() throws {
        let payments = WorkspaceStore(
            catalog: WorkspaceCatalog(
                path: URL(fileURLWithPath: "/tmp/payments", isDirectory: true)
            )
        )
        let docs = WorkspaceStore(
            catalog: WorkspaceCatalog(
                path: URL(fileURLWithPath: "/tmp/docs-site", isDirectory: true)
            )
        )

        XCTAssertNotEqual(
            WorkspaceMark.tint(for: try XCTUnwrap(payments.catalog.activeWorkspace)),
            WorkspaceMark.tint(for: try XCTUnwrap(docs.catalog.activeWorkspace))
        )
    }

    /// `WorkspaceTintTests` asserts the palette's contrast against a number, because the
    /// core suite imports no AppKit and cannot read `TenonTheme`. This is the other end of
    /// that assumption: if the sidebar's chrome ever changes, the contrast the core suite
    /// proves stops being contrast against anything the shell draws.
    func testTheSidebarChromeTheCoreSuiteAssumesIsTheOneTheShellDraws() {
        XCTAssertEqual(TenonTheme.chromeNS, NSColor(hex: 0x11_14_19))
    }

    /// The whole ordinary form is visible without scrolling: `docs/designs.md` caps a
    /// focused surface at about 520 pt of content-driven height, and this one is a compact
    /// popover, so it should sit well inside that.
    func testTheOrdinaryFormFitsWithoutScrolling() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)
        let host = NSHostingView(
            rootView: WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: {}
            )
        )

        let size = host.fittingSize

        XCTAssertEqual(size.width, WorkspaceIdentityFormMetrics.width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(
            size.height,
            520,
            "the form grew past the height a compact Tenon surface is allowed"
        )
    }

    /// A long name must not push the form wider than its own budget.
    func testALongNameDoesNotWidenTheForm() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.renameWorkspace(
            store.catalog.activeWorkspaceID,
            to: String(repeating: "workspace ", count: 12)
        )
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)
        let host = NSHostingView(
            rootView: WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: {}
            )
        )

        XCTAssertEqual(
            host.fittingSize.width,
            WorkspaceIdentityFormMetrics.width,
            accuracy: 1
        )
    }

    /// The row draws a mark and a tint, neither of which VoiceOver can read. The
    /// announcement carries the mark's word — and must not drop the counts the row was
    /// already reading before it gained an explicit label.
    func testTheRowAnnouncesItsNameMarkAndCounts() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")
        store.setWorkspaceAppearance(
            store.catalog.activeWorkspaceID,
            to: WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)

        XCTAssertEqual(
            WorkspaceRowAnnouncement.text(for: workspace, unseenCount: 0),
            "Payments, Automation, 1 tab"
        )
        XCTAssertEqual(
            WorkspaceRowAnnouncement.text(for: workspace, unseenCount: 3),
            "Payments, Automation, 1 tab, 3 unseen"
        )
    }

    /// A passing layout test says a view tree has the right *shape* and nothing about what
    /// it looks like. This renders the form offscreen — the same `NSHostingView` +
    /// `cacheDisplay` route `PaneViewSnapshotWriter` uses, no window and no permission — so
    /// the picture can be looked at, and fails outright if the form draws nothing at all.
    func testTheFormRendersOffscreen() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")
        store.setWorkspaceAppearance(
            store.catalog.activeWorkspaceID,
            to: WorkspaceAppearance(symbol: .metrics, accent: .green)
        )
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)
        let hosting = NSHostingView(
            rootView: WorkspaceIdentityForm(
                workspace: workspace,
                store: store,
                dismiss: {}
            )
        )
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: WorkspaceIdentityFormMetrics.width,
                height: hosting.fittingSize.height
            )
        )
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        if let path = ProcessInfo.processInfo.environment["TENON_IDENTITY_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThan(png.count, 1_000, "the form rendered as an empty bitmap")
    }

    /// The field starts from what a person chose, never from the derived name — otherwise
    /// an untouched workspace would look named, and Reset would have something to undo.
    func testTheNameFieldStartsEmptyUntilTheWorkspaceIsNamed() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))

        XCTAssertNil(try XCTUnwrap(store.catalog.activeWorkspace).customName)

        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")

        XCTAssertEqual(try XCTUnwrap(store.catalog.activeWorkspace).customName, "Payments")
    }
}
