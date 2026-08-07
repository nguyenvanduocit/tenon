// @domain: command-surface
import Foundation

public extension PluginIntentPresentation {
    /// Palette metadata is projected from the static manifest declaration. The command ID
    /// is the canonical intent ID; invocation still enters the shared dispatcher.
    func command(assignedKey: KeyChord?) -> Command {
        Command(
            id: intentID.rawValue,
            title: title,
            subtitle: description,
            category: category,
            icon: icon,
            keywords: keywords,
            key: assignedKey,
            when: when,
            isLauncher: launcher,
            fillsPane: fillsPane
        )
    }
}
