// @domain: pane-chrome
import Foundation
import TenonCore

/// What a pane is doing to its own name right now.
///
/// One pane, one phase. Renaming is pane state — it belongs beside the pane's attention dot
/// and its header contributions, not in a window-wide modal that dims the work the operator
/// is renaming.
enum PaneRenamePhase: Equatable, Sendable {
    /// The operator is typing the name on the title itself.
    case editing(draft: String)
    /// The Companion task is running for this pane.
    case generating
    /// The last generation failed. Self-clearing: `reason` is what the pane can say about it
    /// while it lasts, not a state anyone has to dismiss.
    case failed(reason: String)

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }
}

/// How a pane's header reads while its name is being changed.
///
/// A pure value over `(phase, content title, content glyph)`, so what the title says in each
/// phase is asserted without a window — the card only draws what this decides.
struct PaneRenameChrome: Equatable {
    let title: String
    let glyph: String
    /// `nil` leaves the card's own active/inactive text colour alone.
    let emphasis: ColorToken?
    let tooltip: String?
    let isEditable: Bool

    static let generatingTitle = "Naming…"
    static let failedTitle = "Rename failed"
    /// The one glyph a rename state claims, and only for the state the operator has to act on.
    ///
    /// STATIC and single-width on purpose: an animated glyph would set `stringValue` ten times
    /// a second, and every one of those writes invalidates an `NSTextField`'s intrinsic size
    /// and re-solves the header strip on the main thread — the exact shape of churn T-141 and
    /// T-091 were opened for.
    ///
    /// A generating pane keeps its content glyph and says what it is doing in amber instead.
    /// Measured, not assumed: the first form of this used `⟳`, and the offscreen render showed
    /// it as an unreadable smudge at the glyph column's 9 points while `Naming…` beside it was
    /// perfectly legible. A symbol nobody can resolve is not a status.
    static let failedGlyph = "!"

    static func make(
        phase: PaneRenamePhase?,
        contentTitle: String,
        contentGlyph: String
    ) -> PaneRenameChrome {
        switch phase {
        case nil:
            return PaneRenameChrome(
                title: contentTitle,
                glyph: contentGlyph,
                emphasis: nil,
                tooltip: nil,
                isEditable: false
            )
        case .editing(let draft):
            // The pane keeps its own glyph while it is being named: the operator is looking
            // at the field, and a terminal that stops reading `>_` mid-edit has changed the
            // one thing the header was saying about what it IS.
            return PaneRenameChrome(
                title: draft,
                glyph: contentGlyph,
                emphasis: nil,
                tooltip: nil,
                isEditable: true
            )
        case .generating:
            return PaneRenameChrome(
                title: generatingTitle,
                glyph: contentGlyph,
                emphasis: .amber,
                tooltip: nil,
                isEditable: false
            )
        case .failed(let reason):
            // The words on the strip stay short and the provider's sentence rides the
            // tooltip: a 34-point header is not where a CLI error message is read, but it is
            // where the operator is looking when one happens.
            return PaneRenameChrome(
                title: failedTitle,
                glyph: failedGlyph,
                emphasis: .red,
                tooltip: reason,
                isEditable: false
            )
        }
    }
}
