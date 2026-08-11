// @domain: agent-lens
import Foundation

/// The time range a milestone covers, written the way a person reads a clock.
///
/// It exists as a type because of what building a `DateFormatter` costs: measured against the
/// `string(from:)` call it exists to make, construction dominates by roughly sixty to one, and
/// it takes ICU and locale locks on the way. A milestone row reads its span twice — once to
/// draw and once for the accessibility label — inside a `ViewThatFits`, which evaluates its
/// candidates, so a formatter built inside that computed property was built several times per
/// row per body pass to produce nine characters.
enum AgentMilestoneSpan {
    /// One formatter for every milestone in the app. `DateFormatter` is not `Sendable`, and
    /// every reader of this one is a SwiftUI view body, which is already main-actor isolated.
    @MainActor
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// A range inside one minute is one time: a clock that says `09:24–09:24` is asking the
    /// reader to check whether the two halves differ, which they never do.
    @MainActor
    static func text(from start: Date, to end: Date) -> String {
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        return startText == endText ? startText : "\(startText)–\(endText)"
    }
}
