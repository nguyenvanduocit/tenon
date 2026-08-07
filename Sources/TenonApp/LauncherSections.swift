// @domain: command-surface
import TenonCore

/// The launcher popover's one authoritative order.
///
/// With nothing typed, the ranked list is regrouped by the category each plugin declared —
/// first appearance in the ranking decides which group leads — so the `+` menu reads as a
/// menu rather than as a scoreboard. A typed query drops the grouping: relevance is the
/// only order that reads then.
///
/// `displayed` is that same order flattened, so `displayed[n]` is the n-th visible row.
/// Keyboard selection indexes *this* array and never the ranking behind it, which is what
/// keeps ↓/↑ on the row the eye is on. `PaletteOverlay` gets the same property for free by
/// never grouping (`ForEach(Array(matches.enumerated()))`, `isSelected: index == selected`);
/// a surface that does group has to state it.
struct LauncherSections: Equatable {
    struct Section: Equatable, Identifiable {
        let category: String
        /// Where this section's first row sits in `displayed`.
        let startIndex: Int
        let matches: [CommandMatch]

        var id: String { category }
    }

    let sections: [Section]
    let displayed: [CommandMatch]

    init(ranked: [CommandMatch], query: String) {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            sections = ranked.isEmpty ? [] : [Section(category: "", startIndex: 0, matches: ranked)]
            displayed = ranked
            return
        }

        var order: [String] = []
        var grouped: [String: [CommandMatch]] = [:]
        for match in ranked {
            let category = match.command.category ?? ""
            if grouped[category] == nil {
                order.append(category)
                grouped[category] = []
            }
            grouped[category]?.append(match)
        }

        var sections: [Section] = []
        var displayed: [CommandMatch] = []
        for category in order {
            let matches = grouped[category] ?? []
            sections.append(
                Section(category: category, startIndex: displayed.count, matches: matches)
            )
            displayed.append(contentsOf: matches)
        }
        self.sections = sections
        self.displayed = displayed
    }
}
