import AppKit
import Foundation

/// The Tenon mark, resolved from whichever build produced this binary.
///
/// A plain `Image("TenonMark")` is only half true here. The packaged `.app` compiles
/// `Assets.xcassets` with `actool`, so `Bundle.main` answers a named lookup. `swift build`
/// — the launch path `CLAUDE.md` documents — copies the catalog into the target's resource
/// bundle *verbatim*, because SwiftPM does not run `actool`; there the named lookup finds
/// nothing and the same vector has to be read out of that bundle by hand.
///
/// Both paths draw the mark, so the dev run and the shipped app show one identity. `nil`
/// means neither bundle carried it, and the caller substitutes a glyph — a title bar is
/// never allowed to draw nothing where the app's identity goes.
enum AppMark {
    static let image: NSImage? = resolve()

    private static func resolve() -> NSImage? {
        if let compiled = NSImage(named: "TenonMark") {
            return compiled
        }
        #if SWIFT_PACKAGE
        // `Bundle.module` exists only under SwiftPM; the Xcode target has no such accessor
        // and no need for one, having reached the catalog through `actool` above.
        if let vector = Bundle.module.url(
            forResource: "TenonMark",
            withExtension: "svg",
            subdirectory: "Assets.xcassets/TenonMark.imageset"
        ) {
            return NSImage(contentsOf: vector)
        }
        #endif
        return nil
    }
}
