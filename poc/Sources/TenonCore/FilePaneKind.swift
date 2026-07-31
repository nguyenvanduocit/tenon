import Foundation

/// Which renderer a file pane should use.
///
/// The host already owns the file pane — `SlotContent.file(path:)` and its native editor —
/// so showing a PNG as a picture instead of as bytes crosses no ownership boundary and
/// stays same-owner DIRECT. What it does need is one rule about *which* renderer a path
/// gets, and that rule is a pure function, so it lives here where it can be asserted
/// without a window.
///
/// Deciding by extension is a deliberate limit. Sniffing content would be more accurate and
/// would also mean reading every file the moment a pane opens, which is exactly what T-031's
/// lazy panes exist to avoid; a wrong guess degrades to text, which is legible, rather than
/// to a spinner.
public enum FilePaneKind: String, Equatable, Sendable, CaseIterable {
    /// Rendered as a picture.
    case image
    /// Rendered as a page in a web surface.
    case web
    /// The native editor. The default, and the fallback for everything unrecognised.
    case text

    /// Extensions `NSImage` decodes on macOS. SVG is here rather than under `web` because a
    /// person opening `logo.svg` wants to see the logo, not its markup — the editor is one
    /// keystroke away either way.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
        "heic", "heif", "bmp", "tif", "tiff", "ico",
    ]

    private static let webExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// The renderer for `path`.
    ///
    /// `NSString.pathExtension` already answers the two cases that matter, and it was worth
    /// measuring rather than assuming: it reads only the last component, so a directory
    /// named `images.png` decides nothing; and it reports no extension for a leading-dot
    /// name, so `.gitignore` and a file literally named `.png` are both text. An earlier
    /// version of this guarded both by hand, which was dead code where it agreed and wrong
    /// where it did not — it would have forced `.hidden.png`, a real PNG, to the editor.
    public static func kind(forPath path: String) -> FilePaneKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if webExtensions.contains(ext) { return .web }
        return .text
    }
}
