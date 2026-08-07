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
            if oldValue.automationSchedulesEnabled
                != preferences.automationSchedulesEnabled {
                automationSchedulesRevision += 1
            }
            let changedScheduleKeys = oldValue.pausedAutomationSchedules
                .symmetricDifference(preferences.pausedAutomationSchedules)
            for key in changedScheduleKeys {
                automationScheduleRevisions[key, default: 0] &+= 1
            }
            persist()
            ThemeRuntime.setAccent(preferences.accent)
        }
    }

    /// Monotonic, process-local identity for the current scheduled-delivery epoch.
    /// It is deliberately not persisted or observed: a batch uses it only to prove
    /// that no global delivery transition occurred while an earlier firing was suspended.
    @ObservationIgnored
    private(set) var automationSchedulesRevision: UInt64 = 0

    /// Owner-scoped policy epochs keep one schedule's pause/resume cycle from invalidating
    /// unrelated firings in the same already-advanced scheduler batch.
    @ObservationIgnored
    private var automationScheduleRevisions: [AutomationScheduleKey: UInt64] = [:]

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

    func automationScheduleRevision(for key: AutomationScheduleKey) -> UInt64 {
        automationScheduleRevisions[key, default: 0]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
