// @domain: plugin-contributions, repository-read
import TenonCore

/// Pure tree projection helpers for the file-explorer's instance-local state.
///
/// Directory enumeration remains in the plugin actor because it crosses the intent bus and
/// must be generation-checked there. This type owns only deterministic projection rules.
enum FileExplorerTree {
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
    }

    static func orderedEntries(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.isDirectory && $0.name != ".git" }
            + entries.filter { !$0.isDirectory }
    }

    static func row(
        for entry: Entry,
        path: String,
        depth: Int,
        expanded: Bool,
        menu: [RowMenuItem],
        editing: Bool,
        selected: Bool
    ) -> TreeRowItem {
        TreeRowItem(
            id: path,
            label: entry.name,
            depth: depth,
            icon: entry.isDirectory ? "folder.fill" : "doc.text",
            expanded: entry.isDirectory ? expanded : nil,
            menu: menu,
            editing: editing,
            placeholder: editing ? "Name" : nil,
            selected: selected,
            path: path
        )
    }
}
