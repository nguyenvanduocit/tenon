// @domain: command-surface
import Foundation
import TenonCore
import TenonIntentCore

/// One row of the palette overlay's single flattened order.
///
/// The overlay renders exactly this list and the arrow keys move through exactly its
/// selectable subset, so "row N" means one thing (the LauncherSections rule, restated
/// for a surface that appends provider sections below the static ranking).
enum PaletteDisplayRow: Equatable, Identifiable {
    case command(CommandMatch)
    case sectionHeader(sectionID: String, title: String)
    case result(pluginID: PluginID, result: PaletteResultItem)
    case pending(sectionID: String, title: String)

    var id: String {
        switch self {
        case let .command(match):
            "command.\(match.id)"
        case let .sectionHeader(sectionID, _):
            "header.\(sectionID)"
        case let .result(pluginID, result):
            "result.\(pluginID.rawValue).\(result.id)"
        case let .pending(sectionID, _):
            "pending.\(sectionID)"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .command, .result: true
        case .sectionHeader, .pending: false
        }
    }
}

/// The pure projection behind `PaletteOverlay`: static ranked rows first — never
/// delayed, never reordered by a provider — then each provider section that has
/// something to say (results for the current query revision, or a pending marker while
/// its answer is in flight). A provider with neither contributes nothing.
struct PaletteDisplay: Equatable {
    let rows: [PaletteDisplayRow]
    /// Indices into `rows` that ↑/↓/Enter address, in display order.
    let selectableIndices: [Int]

    init(
        matches: [CommandMatch],
        sections: [PaletteProviderSection] = []
    ) {
        var rows: [PaletteDisplayRow] = matches.map { .command($0) }
        for section in sections where section.isPending || !section.results.isEmpty {
            rows.append(
                .sectionHeader(sectionID: section.id, title: section.title)
            )
            if section.results.isEmpty {
                rows.append(
                    .pending(sectionID: section.id, title: section.title)
                )
            } else {
                rows.append(
                    contentsOf: section.results.map {
                        .result(pluginID: section.pluginID, result: $0)
                    }
                )
            }
        }
        self.rows = rows
        selectableIndices = rows.indices.filter { rows[$0].isSelectable }
    }

    var selectableCount: Int { selectableIndices.count }

    func selectableRow(at selection: Int) -> PaletteDisplayRow? {
        guard selectableIndices.indices.contains(selection) else { return nil }
        return rows[selectableIndices[selection]]
    }

    /// The ⌘K submenu content for the selected row. Static command rows carry no
    /// secondary actions; dynamic results carry the plugin-declared intent list.
    func actions(forSelection selection: Int) -> [PaletteResultAction] {
        guard case let .result(_, result) = selectableRow(at: selection) else {
            return []
        }
        return result.actions
    }
}
