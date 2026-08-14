// @domain: companion
import SwiftUI
import TenonCore

/// Dev-only offscreen capture of the shipping Companion settings detail.
///
///     TENON_COMPANION_SETTINGS_SNAPSHOT=/tmp/companion-settings.png swift run tenon
enum CompanionSettingsSnapshot {
    @MainActor
    static func renderIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TENON_COMPANION_SETTINGS_SNAPSHOT"], !path.isEmpty
        else { return }

        let suite = "dev.tenon.companion-snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferencesStore(defaults: defaults)
        prefs.preferences.companion = CompanionProfile(
            agent: .claude,
            model: "haiku",
            customPrompt: "Use concise Vietnamese names and preserve technical terms.",
            workingDirectory: "/Users/example/Projects/tenon"
        )

        PaneViewSnapshotWriter.write(
            bare: CompanionSettingsDetail(prefs: prefs)
                .frame(width: 540, height: 660)
                .background(TenonTheme.ink),
            size: CGSize(width: 540, height: 660),
            to: path
        )
    }
}
