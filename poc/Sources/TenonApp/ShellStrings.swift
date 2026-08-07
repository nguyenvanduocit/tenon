// @domain: workspace-model
import Foundation

/// User-visible text the shell builds outside SwiftUI.
///
/// SwiftUI's `Text("…")` is already a localization key, so those strings were translatable the
/// moment the package gained a `defaultLocalization` and a catalog. The strings that were not:
/// everything handed to AppKit — accessibility labels, menu titles, the words a screen reader
/// speaks — because those take a plain `String` and a plain `String` is whatever was typed.
///
/// This is the one door they go through, so a sentence a person hears is in the catalog for the
/// same reason a sentence they read is.
enum Shell {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    /// Interpolated text — the key keeps its placeholders, so a translation may reorder them.
    static func text(
        _ key: String.LocalizationValue,
        comment: StaticString
    ) -> String {
        String(localized: key, bundle: .module, comment: comment)
    }
}
