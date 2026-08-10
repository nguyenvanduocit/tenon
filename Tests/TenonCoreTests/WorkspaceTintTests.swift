import TenonCore
import XCTest

/// T-112: the colour a workspace carries when nobody has chosen one.
///
/// Every rule here is pure — a path in, a colour out — which is why it lives in the core
/// suite and not beside the view that draws it. What the view owes on top of this is only
/// *where* the colour appears; what colour it is, is settled here.
final class WorkspaceTintTests: XCTestCase {
    /// The sidebar's own background, `NSColor.tenonChrome`. Repeated here as a number
    /// because `TenonTheme` lives in `TenonApp` and this suite imports no AppKit;
    /// `testTheSidebarChromeThisSuiteAssumesIsTheOneTheShellDraws` in the app suite fails
    /// if the two ever drift apart.
    private let sidebarChrome: UInt32 = 0x11_14_19

    /// A derived colour must be the same colour tomorrow. `String.hashValue` is seeded per
    /// process, so a rule built on it would repaint the whole sidebar on every launch and
    /// destroy exactly the recognition it was added to create — these pinned values are
    /// what stops someone reaching for it.
    func testTheDerivedTintIsPinnedSoItSurvivesRelaunch() {
        let expected: [String: UInt32] = [
            "/tmp/tenon-project": 0xE1_70_E1,
            "/tmp/payments": 0x70_C3_E1,
            "/tmp/docs-site": 0xE1_9F_70,
            "/tmp/infra": 0xE1_70_E1,
        ]

        for (path, hex) in expected {
            XCTAssertEqual(
                WorkspaceTint.derived(forPath: URL(fileURLWithPath: path, isDirectory: true)),
                hex,
                """
                \(path) changed colour. If the hash or the palette moved deliberately, \
                repin these — but every workspace a person had already learned has just \
                been repainted.
                """
            )
        }
    }

    /// Two URLs naming one folder must not be two workspaces' worth of colour. This is the
    /// same normalization `RecentWorkspaceStore.folderKey` already matches paths by, so a
    /// workspace opened from the panel and one rehydrated from disk agree.
    func testPathsNamingTheSameFolderDeriveTheSameTint() {
        let canonical = WorkspaceTint.derived(
            forPath: URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)
        )

        for spelling in [
            "/tmp/tenon-project/",
            "/tmp/./tenon-project",
            "/tmp/elsewhere/../tenon-project",
        ] {
            XCTAssertEqual(
                WorkspaceTint.derived(forPath: URL(fileURLWithPath: spelling)),
                canonical,
                "\(spelling) names the same folder and must carry the same colour"
            )
        }
    }

    /// A chosen colour is a choice, and the derived one is only what stands in until the
    /// choice is made. One resolver, so no surface spells this precedence its own way.
    func testAnExplicitAccentBeatsTheDerivedTint() {
        let path = URL(fileURLWithPath: "/tmp/tenon-project", isDirectory: true)
        let derived = WorkspaceTint.derived(forPath: path)

        XCTAssertEqual(WorkspaceTint.hex(for: .green, at: path), AccentColor.green.hex)
        XCTAssertEqual(
            WorkspaceTint.hex(for: WorkspaceAppearance.default.accent, at: path),
            derived,
            "an uncustomised workspace carries the colour its path derives"
        )
    }

    /// The mark is a graphical object on the sidebar's chrome, so WCAG 1.4.11 asks 3:1 of
    /// it. A palette entry that fails this is not a quiet colour — it is an icon that
    /// disappears, which is worse than the muted grey it replaced.
    func testEveryPaletteEntryIsLegibleAgainstTheSidebarChrome() {
        XCTAssertFalse(WorkspaceTint.palette.isEmpty)

        for hex in WorkspaceTint.palette {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(hex, sidebarChrome),
                3.0,
                String(format: "0x%06X is not legible on the sidebar", hex)
            )
        }
    }

    /// A hash that reaches only half its palette is a palette half that size. This sweeps
    /// far more paths than a sidebar holds precisely so a bias shows up as absence.
    func testTheDerivedRuleReachesEveryColourInThePalette() {
        let reached = Set(
            (0..<2_000).map {
                WorkspaceTint.derived(forPath: URL(fileURLWithPath: "/w/\($0)", isDirectory: true))
            }
        )

        XCTAssertEqual(
            reached,
            Set(WorkspaceTint.palette),
            "the derived rule never produces some of the colours it is allowed to"
        )
    }

    /// Two colours the eye reads as one colour are one colour. This is the assertion the
    /// palette's own shape came from: an evenly spaced wheel scored 16.7 here and drew a
    /// sidebar whose three greens were indistinguishable in the snapshot, which no test
    /// asserting counts or contrast could see. CIELAB ΔE around 20 is where a difference
    /// stops needing to be looked for.
    func testNoTwoColoursInThePaletteAreTooCloseToTellApart() {
        for (index, first) in WorkspaceTint.palette.enumerated() {
            for second in WorkspaceTint.palette[(index + 1)...] {
                XCTAssertGreaterThanOrEqual(
                    Self.perceptualDistance(first, second),
                    20,
                    String(format: "0x%06X and 0x%06X read as one colour", first, second)
                )
            }
        }
    }

    /// What the rule actually buys, and what it does not.
    ///
    /// A pure path→colour function cannot promise a whole sidebar is distinct — with ten
    /// colours, eight workspaces collide about once by birthday alone (this set collides
    /// exactly once, giving seven), and widening the palette buys hues too close to tell
    /// apart. So this records the real floor rather than a wish: most rows differ, some
    /// share, and the popover is how a person settles a clash they care about. It still
    /// fails loudly if the rule ever collapses toward one colour.
    func testATypicalSidebarGetsMostlyDistinctTintsAndSomeCollisions() {
        let sidebar = [
            "/Users/me/projects/tenon",
            "/Users/me/projects/famefarm",
            "/Users/me/projects/clik",
            "/Users/me/projects/carlens",
            "/Users/me/projects/just-read",
            "/Users/me/projects/mymo",
            "/Users/me/projects/invest",
            "/Users/me/projects/goscrape",
        ]
        let tints = sidebar.map {
            WorkspaceTint.derived(forPath: URL(fileURLWithPath: $0, isDirectory: true))
        }

        XCTAssertGreaterThanOrEqual(
            Set(tints).count,
            5,
            "eight workspaces collapsed into fewer than five colours — the rule is biased"
        )
    }

    // MARK: - Colour arithmetic

    /// CIE76 ΔE — how far apart two colours are to look at, which is not how far apart
    /// their hues are on a wheel.
    private static func perceptualDistance(_ a: UInt32, _ b: UInt32) -> Double {
        let first = lab(a)
        let second = lab(b)
        return ((first.0 - second.0) * (first.0 - second.0)
            + (first.1 - second.1) * (first.1 - second.1)
            + (first.2 - second.2) * (first.2 - second.2)).squareRoot()
    }

    private static func lab(_ hex: UInt32) -> (Double, Double, Double) {
        func linear(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func pivot(_ value: Double) -> Double {
            value > 0.008856 ? cbrt(value) : 7.787 * value + 16 / 116
        }

        let red = linear((hex >> 16) & 0xFF)
        let green = linear((hex >> 8) & 0xFF)
        let blue = linear(hex & 0xFF)
        let x = pivot((0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047)
        let y = pivot(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        let z = pivot((0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883)

        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance and contrast ratio. Written out because this suite is
    /// deliberately AppKit-free and `NSColor` would drag a colour space in with it.
    private static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let lighter = max(relativeLuminance(a), relativeLuminance(b))
        let darker = min(relativeLuminance(a), relativeLuminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }
}
