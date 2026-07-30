import Foundation
import Observation
import TenonCore

/// App-wide personalisation, a process-wide shared store persisted to
/// `UserDefaults` as a single JSON blob so adding a setting stays a one-field change on
/// `AppPreferences`. The value type and its resolution rules live in `TenonCore`; this
/// is only the observable persistence shell that the Settings UI binds to.
@MainActor
@Observable
final class AppPreferencesStore {
    static let shared = AppPreferencesStore()

    var preferences: AppPreferences {
        didSet {
            persist()
            ThemeRuntime.setAccent(preferences.accent)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "app.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = AppPreferences()
        }
        ThemeRuntime.setAccent(preferences.accent)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
