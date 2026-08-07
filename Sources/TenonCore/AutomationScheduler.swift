// @domain: automation
import Foundation
import Observation
import TenonIntentCore

/// Host-side wall-clock scheduler for manifest-declared automation schedules (T-046).
///
/// Same-owner DIRECT host state, the T-029 shape: time is always a parameter, `Date()`
/// lives only at the composition root's imperative tick edge, so every rule here is
/// assertable without a window or a real clock. Firings are delivered by the caller as
/// the owner-scoped EVENT `automation.fired` (`PluginHost.automationFired`).
///
/// T-060 adds the visibility half: `listings` for the Automation Canvas operations pane,
/// `manualFiring` for Run now, and a bounded `runHistory` recorded at the same edge that
/// delivers.
@MainActor
@Observable
public final class AutomationScheduler {
    /// One due occurrence for one plugin's schedule.
    public struct Firing: Sendable, Equatable {
        /// What put this firing on the wire. `manual` is a user's Run now; the plugin
        /// sees it only as the payload's reserved `trigger` value — same event, same
        /// emit site (T-060).
        public enum Trigger: String, Sendable {
            case scheduled
            case manual
        }

        public let pluginID: PluginID
        public let scheduleID: String
        public let scheduledFor: Date
        /// The occurrence fired well past its instant (recovered from a sleep or a
        /// missed stretch) — more than `lateThreshold` behind the tick.
        public let late: Bool
        public let trigger: Trigger
    }

    /// One row of the Automation Canvas operations pane: a schedule that is currently
    /// armed, with the instant it will next fire. Pure projection of scheduler state —
    /// the UI renders this DIRECT, no plugin boundary is crossed.
    public struct ScheduleListing: Sendable, Equatable {
        public let pluginID: PluginID
        public let spec: AutomationScheduleSpec
        public let nextDue: Date
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

    /// Host preference overlay for manifest schedules. Pausing never removes the
    /// declaration or shifts manual Run Now; scheduled ticks simply advance without
    /// producing a firing, preventing a catch-up burst after resume.
    public private(set) var pausedScheduleKeys: Set<AutomationScheduleKey> = []

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func setPausedScheduleKeys(_ keys: Set<AutomationScheduleKey>) {
        pausedScheduleKeys = keys
    }

    public func isPaused(pluginID: PluginID, scheduleID: String) -> Bool {
        pausedScheduleKeys.contains(
            AutomationScheduleKey(pluginID: pluginID, scheduleID: scheduleID)
        )
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
            let scheduleKey = AutomationScheduleKey(
                pluginID: key.pluginID,
                scheduleID: key.scheduleID
            )
            if lateBy <= entry.spec.grace,
               !pausedScheduleKeys.contains(scheduleKey) {
                firings.append(
                    Firing(
                        pluginID: key.pluginID,
                        scheduleID: key.scheduleID,
                        scheduledFor: latest,
                        late: lateBy > Self.lateThreshold,
                        trigger: .scheduled
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

    /// Every armed schedule, deterministically ordered like `tick`'s firings.
    public func listings() -> [ScheduleListing] {
        entries
            .map { key, entry in
                ScheduleListing(
                    pluginID: key.pluginID,
                    spec: entry.spec,
                    nextDue: entry.nextDue
                )
            }
            .sorted {
                ($0.pluginID.rawValue, $0.spec.id)
                    < ($1.pluginID.rawValue, $1.spec.id)
            }
    }

    /// Mints a user-directed firing for one armed schedule, or nil when no such
    /// schedule is armed. Deliberately leaves `nextDue` untouched: Run now answers
    /// "did my automation work", it does not shift the schedule's phase.
    public func manualFiring(
        pluginID: PluginID,
        scheduleID: String,
        now: Date
    ) -> Firing? {
        guard entries[Key(pluginID: pluginID, scheduleID: scheduleID)] != nil
        else {
            return nil
        }
        return Firing(
            pluginID: pluginID,
            scheduleID: scheduleID,
            scheduledFor: now,
            late: false,
            trigger: .manual
        )
    }

    /// Recent firings, newest first, bounded by `AutomationRunHistory.capacity`.
    /// Reconcile never touches this — history outlives the hot reload of the plugin
    /// it describes.
    public private(set) var runHistory = AutomationRunHistory()

    /// Records one delivered (or dropped) firing at the edge that delivered it.
    public func recordRun(_ firing: Firing, firedAt: Date, delivered: Bool) {
        runHistory.record(
            AutomationRunRecord(
                pluginID: firing.pluginID,
                scheduleID: firing.scheduleID,
                scheduledFor: firing.scheduledFor,
                firedAt: firedAt,
                trigger: firing.trigger,
                late: firing.late,
                delivered: delivered
            )
        )
    }
}
