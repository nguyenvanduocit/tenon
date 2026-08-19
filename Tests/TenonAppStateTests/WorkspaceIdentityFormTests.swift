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
    /// owes: every mark has a place, the rows are even — filling each row to the width
    /// instead gives 8 marks then a stub row of 4 — and a row never asks for more columns
    /// than the width can carry at the density the rest of the form is drawn at.
    func testTheMarkGridIsEvenAndKeepsItsDensityAcrossThePopoversWidth() {
        let metrics = WorkspaceIdentityFormMetrics.self
        let columns = metrics.columns
        let rows = metrics.markRows
        let count = WorkspaceSymbol.allCases.count

        XCTAssertGreaterThan(columns, 1)
        XCTAssertGreaterThanOrEqual(
            metrics.columnSpacing(for: columns),
            metrics.swatchSpacing,
            "\(columns) columns pack the marks tighter than a row of them is ever drawn"
        )
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

    func testTheExpandedTintGridIsBalancedAndKeepsItsDensity() {
        let metrics = WorkspaceIdentityFormMetrics.self
        let count = AccentColor.allCases.count + 1

        XCTAssertEqual(metrics.tintRows, 2)
        XCTAssertGreaterThanOrEqual(
            metrics.columnSpacing(for: metrics.tintColumns),
            metrics.swatchSpacing,
            "the tints are packed tighter than a row of swatches is ever drawn"
        )
        XCTAssertGreaterThanOrEqual(metrics.tintRows * metrics.tintColumns, count)
        XCTAssertLessThan(metrics.tintRows * metrics.tintColumns - count, metrics.tintRows)
    }

    func testCustomIconImportNormalizesToABoundedPNG() async throws {
        let source = try XCTUnwrap(
            Data(base64Encoded: """
                iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A
                AQUBAScY42YAAAAASUVORK5CYII=
                """.filter { !$0.isWhitespace })
        )

        let icon = try await WorkspaceCustomIconImport.icon(from: source)

        XCTAssertLessThanOrEqual(icon.pngData.count, WorkspaceCustomIcon.maximumPNGBytes)
        XCTAssertEqual(Array(icon.pngData.prefix(8)), [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ])
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: icon.pngData))
        XCTAssertLessThanOrEqual(decoded.pixelsWide, WorkspaceCustomIconImport.renderedPixelSize)
        XCTAssertLessThanOrEqual(decoded.pixelsHigh, WorkspaceCustomIconImport.renderedPixelSize)
    }

    func testCustomIconImportRejectsInvalidAndOversizedSources() async {
        do {
            _ = try await WorkspaceCustomIconImport.icon(from: Data("not an image".utf8))
            XCTFail("invalid image bytes must be rejected")
        } catch let error as WorkspaceCustomIconImportError {
            XCTAssertEqual(error, .unsupportedImage)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await WorkspaceCustomIconImport.icon(
                from: Data(
                    repeating: 0,
                    count: WorkspaceCustomIconImport.maximumSourceBytes + 1
                )
            )
            XCTFail("oversized image bytes must be rejected")
        } catch let error as WorkspaceCustomIconImportError {
            XCTAssertEqual(error, .sourceTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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

    /// T-178 (`WS-FR-036`): the visible line has room for one agent and a count of the rest,
    /// and the rest are behind a pointer hover — which a screen reader does not have. So the
    /// row speaks every pane it holds, in the order the hovered list shows them.
    func testARowNamingAgentsSpeaksEveryOneOfThemInTheOrderTheListHoldsThem() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")
        store.setWorkspaceAppearance(
            store.catalog.activeWorkspaceID,
            to: WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)
        let entries = [
            WorkspaceAgentTagline.Entry(
                slotID: UUID(),
                title: "Fixing the token refresh race",
                state: .working
            ),
            WorkspaceAgentTagline.Entry(
                slotID: UUID(),
                title: "Auditing the intent catalog",
                state: .finishedUnseen
            ),
        ]

        XCTAssertEqual(
            WorkspaceRowAnnouncement.text(
                for: workspace,
                unseenCount: 1,
                agentEntries: entries
            ),
            """
            Payments, Automation, 1 tab, 2 agents, \
            Fixing the token refresh race, working, \
            Auditing the intent catalog, finished, unseen, 1 unseen
            """
        )
    }

    func testARowWithNoAgentSpeaksExactlyWhatItSpokeBefore() throws {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
        store.renameWorkspace(store.catalog.activeWorkspaceID, to: "Payments")
        store.setWorkspaceAppearance(
            store.catalog.activeWorkspaceID,
            to: WorkspaceAppearance(symbol: .bolt, accent: .green)
        )
        let workspace = try XCTUnwrap(store.catalog.activeWorkspace)

        XCTAssertEqual(
            WorkspaceRowAnnouncement.text(
                for: workspace,
                unseenCount: 0,
                agentEntries: []
            ),
            "Payments, Automation, 1 tab"
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

    /// A row of swatches is laid out from the popover's width, so it owes that width back:
    /// the space before the first swatch and the space after the last are the same, and
    /// neither is wide enough to have held another swatch. Columns that cannot grow break
    /// exactly this and nothing else — the tints ended 60 pt short of their own edge while
    /// every metrics assertion stayed green, because those only forbid overflow.
    ///
    /// This measures the drawn pixels rather than recomputing the layout from the metrics
    /// the view lays out from, which would agree with any mistake it makes. The tints are
    /// the one place in the form where saturated marks repeat across a row, which is what
    /// makes the row findable without pinning where it sits.
    func testASwatchRowIsSpreadEvenlyAcrossThePopoversContentWidth() throws {
        let form = try renderIdentityForm()
        let row = try XCTUnwrap(
            form.widestRowOfRepeatedSwatches(),
            "no row of tint swatches was found in the rendered form"
        )
        let inset = WorkspaceIdentityFormMetrics.inset
        let contentRight = WorkspaceIdentityFormMetrics.width - inset
        let leading = row.first - inset
        let trailing = contentRight - row.last

        XCTAssertEqual(
            trailing,
            leading,
            accuracy: 1.5,
            """
            the row is not centred in its own width: it starts \(leading) pt after the \
            content edge and stops \(trailing) pt before it
            """
        )
        XCTAssertLessThanOrEqual(
            trailing,
            WorkspaceIdentityFormMetrics.swatch,
            """
            \(trailing) pt is left after the last swatch — room enough for another one, \
            so the row stopped short of the width it was laid out from
            """
        )
    }

    /// (`WS-FR-036`): the row's own disclosure toggle grows this list in place under the
    /// line it belongs to — a test cannot click the toggle, but it can mount the list and
    /// measure it: one row per pane at the density the row states, which is what fails if a
    /// row's content outgrows the height a row is given.
    func testTheAgentListDrawsOneRowPerPaneAtItsStatedDensity() {
        for count in [1, 3, 6] {
            let entries = (0 ..< count).map { index in
                WorkspaceAgentTagline.Entry(
                    slotID: UUID(),
                    title: "Pane \(index): a title long enough that the row has to truncate it",
                    state: index.isMultiple(of: 2) ? .working : .finishedUnseen
                )
            }
            let hosting = NSHostingView(
                rootView: WorkspaceAgentList(entries: entries, focus: { _ in })
            )

            XCTAssertEqual(
                hosting.fittingSize.height,
                WorkspaceAgentListLayout.height(rows: count),
                accuracy: 0.5,
                """
                \(count) agents drew \(hosting.fittingSize.height) pt, and the stated budget \
                is \(WorkspaceAgentListLayout.height(rows: count)) pt.
                """
            )
        }
    }

    /// The list grows in place under the row it belongs to, and the row itself bounds the
    /// width — nothing pins it to a fixed width the way a popover once did, so a short entry
    /// must size to its own content rather than pad out to some stated minimum.
    func testTheAgentListSizesToItsOwnContentNotAFixedWidth() {
        func hosted(_ title: String) -> NSHostingView<WorkspaceAgentList> {
            NSHostingView(
                rootView: WorkspaceAgentList(
                    entries: [
                        WorkspaceAgentTagline.Entry(slotID: UUID(), title: title, state: .working),
                    ],
                    focus: { _ in }
                )
            )
        }

        let short = hosted("short")
        let long = hosted("a title long enough to widen the list well past a short one")

        XCTAssertLessThan(
            short.fittingSize.width,
            long.fittingSize.width,
            "A short entry sized to a fixed width instead of its own content."
        )
    }

    /// One rendered form, as pixels in the form's own points. The route is the offscreen
    /// `NSHostingView` + `cacheDisplay` one `PaneViewSnapshotWriter` uses: no window, no
    /// screen-recording grant.
    private func renderIdentityForm() throws -> RenderedIdentityForm {
        let store = WorkspaceStore(catalog: WorkspaceCatalog(path: projectPath))
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
        let image = try XCTUnwrap(rep.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return RenderedIdentityForm(
            pixels: pixels,
            width: width,
            height: height,
            scale: CGFloat(width) / WorkspaceIdentityFormMetrics.width
        )
    }
}

/// The pixels one rendered identity form drew, read back in the form's own points.
private struct RenderedIdentityForm {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat

    /// The horizontal extent of the swatch row that reaches furthest right. A swatch row is
    /// recognised by shape alone: at least six saturated marks, each about the size of a
    /// swatch, standing at least a third of a swatch apart. That is what separates it from
    /// the two other saturated things the form draws — the selection ring, whose hairlines
    /// are far too thin, and the amber Done button, whose black lettering cuts its fill into
    /// pieces that sit almost touching.
    func widestRowOfRepeatedSwatches() -> (first: CGFloat, last: CGFloat)? {
        var widest: (first: CGFloat, last: CGFloat)?
        for y in 0..<height {
            guard let runs = swatchRuns(inRow: y), runs.count >= 6 else { continue }
            guard let first = runs.first, let last = runs.last else { continue }
            let extent = (
                first: CGFloat(first.lowerBound) / scale,
                last: CGFloat(last.upperBound + 1) / scale
            )
            if widest == nil || extent.last > widest!.last { widest = extent }
        }
        return widest
    }

    /// The runs of saturated pixels in one row when every one of them is swatch-shaped and
    /// swatch-spaced, and nothing when any is not — a row is read whole, so one stray mark
    /// disqualifies it rather than quietly passing the rest through.
    private func swatchRuns(inRow y: Int) -> [ClosedRange<Int>]? {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0..<width {
            if isSaturated(x: x, y: y) {
                if start == nil { start = x }
            } else if let began = start {
                runs.append(began...(x - 1))
                start = nil
            }
        }
        if let began = start { runs.append(began...(width - 1)) }

        let swatch = WorkspaceIdentityFormMetrics.swatch * scale
        let separation = swatch / 3
        guard runs.allSatisfy({ CGFloat($0.count) >= separation && CGFloat($0.count) <= swatch })
        else { return nil }
        for (left, right) in zip(runs, runs.dropFirst())
        where CGFloat(right.lowerBound - left.upperBound) < separation {
            return nil
        }
        return runs
    }

    /// A pixel carrying real hue: the chrome, the panel fills and every grey the form draws
    /// are near-neutral, so a wide gap between the strongest and weakest channel is a mark.
    private func isSaturated(x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        return highest > 100 && highest - lowest > 60
    }
}
