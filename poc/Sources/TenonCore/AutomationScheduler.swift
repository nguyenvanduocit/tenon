import Foundation
import TenonIntentCore

/// Host-side wall-clock scheduler for manifest-declared automation schedules (T-046).
///
/// Same-owner DIRECT host state, the T-029 shape: time is always a parameter, `Date()`
/// lives only at the composition root's imperative tick edge, so every rule here is
/// assertable without a window or a real clock. Firings are delivered by the caller as
/// the owner-scoped EVENT `automation.fired` (`PluginHost.automationFired`).
@MainActor
public final class AutomationScheduler {
    /// One due occurrence for one plugin's schedule.
    public struct Firing: Sendable, Equatable {
        public let pluginID: PluginID
        public let scheduleID: String
        public let scheduledFor: Date
        /// The occurrence fired well past its instant (recovered from a sleep or a
        /// missed stretch) — more than `lateThreshold` behind the tick.
        public let late: Bool
    }

    /// A firing further behind than the tick cadence explains is marked late.
    public static let lateThreshold: TimeInterval = 120

    private struct Key: Hashable {
        let pluginID: PluginID
        let scheduleID: String
    }

    private struct Entry {
        let spec: AutomationScheduleSpec
        var nextDue: Date
    }

    private var entries: [Key: Entry] = [:]
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Aligns the schedule table with the currently active plugins. An unchanged spec
    /// keeps its phase (`nextDue`); a changed spec recomputes from `now`; a vanished
    /// spec drops. Only loaded, enabled plugins schedule anything.
    public func reconcile(_ plugins: [PluginSnapshot], now: Date) {
        var desired: [Key: AutomationScheduleSpec] = [:]
        for plugin in plugins where plugin.isLoaded && plugin.isEnabled {
            for spec in plugin.automationSchedules {
                desired[Key(pluginID: plugin.id, scheduleID: spec.id)] = spec
            }
        }
        var next: [Key: Entry] = [:]
        next.reserveCapacity(desired.count)
        for (key, spec) in desired {
            if let existing = entries[key], existing.spec == spec {
                next[key] = existing
            } else {
                next[key] = Entry(
                    spec: spec,
                    nextDue: spec.nextOccurrence(after: now, calendar: calendar)
                )
            }
        }
        entries = next
    }

    /// Returns every schedule due at `now` — at most the latest missed occurrence per
    /// schedule, and only within its grace; staler misses skip silently. Idempotent:
    /// a second tick at the same instant fires nothing new.
    public func tick(now: Date) -> [Firing] {
        var firings: [Firing] = []
        let dueKeys = entries
            .filter { $0.value.nextDue <= now }
            .keys
            .sorted {
                ($0.pluginID.rawValue, $0.scheduleID)
                    < ($1.pluginID.rawValue, $1.scheduleID)
            }
        for key in dueKeys {
            guard var entry = entries[key] else { continue }
            var latest = entry.nextDue
            while true {
                let next = entry.spec.nextOccurrence(
                    after: latest,
                    calendar: calendar
                )
                guard next <= now else { break }
                latest = next
            }
            let lateBy = now.timeIntervalSince(latest)
            if lateBy <= entry.spec.grace {
                firings.append(
                    Firing(
                        pluginID: key.pluginID,
                        scheduleID: key.scheduleID,
                        scheduledFor: latest,
                        late: lateBy > Self.lateThreshold
                    )
                )
            }
            entry.nextDue = entry.spec.nextOccurrence(
                after: now,
                calendar: calendar
            )
            entries[key] = entry
        }
        return firings
    }
}
