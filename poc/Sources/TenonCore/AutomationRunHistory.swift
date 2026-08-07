import Foundation
import TenonIntentCore

/// One automation firing as it was actually delivered (T-060).
///
/// The record carries exactly the facts the plugin received — schedule, scheduled
/// instant, trigger, lateness — plus the host-side delivery outcome. That is the
/// evidence a history row links back to: what was put on the wire, and whether a
/// live generation took it.
public struct AutomationRunRecord: Identifiable, Sendable, Equatable {
    /// Stable row identity for newest-first UI projections. Evidence fields are not a
    /// safe identity: two manual firings may carry identical schedule and time values.
    public let id: UUID
    public let pluginID: PluginID
    public let scheduleID: String
    public let scheduledFor: Date
    public let firedAt: Date
    public let trigger: AutomationScheduler.Firing.Trigger
    public let late: Bool
    public let delivered: Bool

    public init(
        id: UUID = UUID(),
        pluginID: PluginID,
        scheduleID: String,
        scheduledFor: Date,
        firedAt: Date,
        trigger: AutomationScheduler.Firing.Trigger,
        late: Bool,
        delivered: Bool
    ) {
        self.id = id
        self.pluginID = pluginID
        self.scheduleID = scheduleID
        self.scheduledFor = scheduledFor
        self.firedAt = firedAt
        self.trigger = trigger
        self.late = late
        self.delivered = delivered
    }
}

/// Bounded, newest-first buffer of automation runs (invariant 10). A value type on
/// purpose: the scheduler owns the one live copy, tests assert on plain values.
public struct AutomationRunHistory: Sendable, Equatable {
    public static let capacity = 128

    public private(set) var records: [AutomationRunRecord] = []

    public init() {}

    public mutating func record(_ record: AutomationRunRecord) {
        records.insert(record, at: 0)
        if records.count > Self.capacity {
            records.removeLast(records.count - Self.capacity)
        }
    }
}
