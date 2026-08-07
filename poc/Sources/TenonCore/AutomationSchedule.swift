import Foundation
import TenonIntentCore

/// Stable host identity for one manifest-declared schedule. The pair is persisted in
/// preferences when a person pauses a schedule, so a hot reload or temporary plugin
/// disable does not forget that choice.
public struct AutomationScheduleKey: Sendable, Hashable, Codable {
    public let pluginID: PluginID
    public let scheduleID: String

    public init(pluginID: PluginID, scheduleID: String) {
        self.pluginID = pluginID
        self.scheduleID = scheduleID
    }
}

/// One wall-clock schedule declared in a plugin manifest's `automation.schedules` block.
///
/// Boundary-law classification (T-046): the declaration is a CONTRIBUTION — the plugin
/// owns the snapshot, the host owns validation, reconciliation, and firing. The firing
/// itself is the owner-scoped EVENT `automation.fired`; whatever the plugin does in
/// response uses its ordinary declared intents. Sub-minute cadence is deliberately not
/// expressible here — that is `tenon.timers.every` (RESOURCE), which already exists.
/// A schedule is a wall-clock automation, not a tick source.
public struct AutomationScheduleSpec: Sendable, Equatable, Codable {
    public enum Cadence: Sendable, Equatable {
        /// A fixed interval measured from the previous computation point. Interval
        /// semantics, not a fixed epoch grid: a missed stretch re-anchors on recovery.
        case every(TimeInterval)
        /// A local wall-clock time of day, resolved against the scheduler's calendar
        /// at computation time. Deliberately no stored timezone: Orca stores one and
        /// then ignores it, which is worse than honestly using the machine's clock.
        case daily(hour: Int, minute: Int)
    }

    public static let maximumSchedulesPerPlugin = 8
    public static let minimumInterval: TimeInterval = 60
    public static let maximumInterval: TimeInterval = 7 * 24 * 3600
    public static let defaultDailyGrace: TimeInterval = 6 * 3600
    public static let maximumIDBytes = 64

    public let id: String
    public let cadence: Cadence
    /// How stale a missed occurrence may be and still fire. On recovery at most the
    /// latest missed occurrence fires; anything staler is skipped and the schedule
    /// advances. Defaults to one interval for `every` and 6 hours for `daily`.
    public let grace: TimeInterval

    public init(id: String, cadence: Cadence, grace: TimeInterval? = nil) throws {
        guard !id.isEmpty, id.utf8.count <= Self.maximumIDBytes else {
            throw AutomationManifestError.invalidScheduleID(id)
        }
        let resolvedGrace: TimeInterval
        switch cadence {
        case .every(let interval):
            guard interval >= Self.minimumInterval,
                  interval <= Self.maximumInterval
            else {
                throw AutomationManifestError.intervalOutOfRange(
                    field: "every",
                    value: "\(Int(interval))s",
                    scheduleID: id
                )
            }
            resolvedGrace = grace ?? interval
        case .daily(let hour, let minute):
            guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
                throw AutomationManifestError.invalidDailyTime(
                    value: String(format: "%02d:%02d", hour, minute),
                    scheduleID: id
                )
            }
            resolvedGrace = grace ?? Self.defaultDailyGrace
        }
        guard resolvedGrace >= Self.minimumInterval,
              resolvedGrace <= Self.maximumInterval
        else {
            throw AutomationManifestError.intervalOutOfRange(
                field: "grace",
                value: "\(Int(resolvedGrace))s",
                scheduleID: id
            )
        }
        self.id = id
        self.cadence = cadence
        self.grace = resolvedGrace
    }

    /// The first occurrence strictly after `date`.
    public func nextOccurrence(after date: Date, calendar: Calendar) -> Date {
        switch cadence {
        case .every(let interval):
            return date.addingTimeInterval(interval)
        case .daily(let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime,
                direction: .forward
            ) ?? date.addingTimeInterval(24 * 3600)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case every
        case daily
        case grace
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedFields = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = allFields.allKeys.first(
            where: { !allowedFields.contains($0.stringValue) }
        ) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription: AutomationManifestError
                        .unknownScheduleField(unknown.stringValue)
                        .description
                )
            )
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let every = try c.decodeIfPresent(String.self, forKey: .every)
        let daily = try c.decodeIfPresent(String.self, forKey: .daily)
        let grace = try c.decodeIfPresent(String.self, forKey: .grace)

        let cadence: Cadence
        switch (every, daily) {
        case (nil, nil):
            throw AutomationManifestError.missingCadence(scheduleID: id)
        case (.some, .some):
            throw AutomationManifestError.conflictingCadence(scheduleID: id)
        case (.some(let raw), nil):
            cadence = .every(
                try Self.duration(raw, field: "every", scheduleID: id)
            )
        case (nil, .some(let raw)):
            cadence = try Self.dailyTime(raw, scheduleID: id)
        }
        try self.init(
            id: id,
            cadence: cadence,
            grace: grace.map {
                try Self.duration($0, field: "grace", scheduleID: id)
            }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch cadence {
        case .every(let interval):
            try c.encode("\(Int(interval))s", forKey: .every)
        case .daily(let hour, let minute):
            try c.encode(
                String(format: "%02d:%02d", hour, minute),
                forKey: .daily
            )
        }
        try c.encode("\(Int(grace))s", forKey: .grace)
    }

    /// `"<positive integer><s|m|h|d>"`, bounds-checked by the memberwise initializer.
    private static func duration(
        _ raw: String,
        field: String,
        scheduleID: String
    ) throws -> TimeInterval {
        let multipliers: [Character: TimeInterval] = [
            "s": 1, "m": 60, "h": 3600, "d": 86400,
        ]
        guard raw.count >= 2,
              let unit = raw.last,
              let multiplier = multipliers[unit]
        else {
            throw AutomationManifestError.invalidDuration(
                field: field,
                value: raw,
                scheduleID: scheduleID
            )
        }
        let digits = raw.dropLast()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits),
              value > 0
        else {
            throw AutomationManifestError.invalidDuration(
                field: field,
                value: raw,
                scheduleID: scheduleID
            )
        }
        let interval = TimeInterval(value) * multiplier
        guard interval >= minimumInterval, interval <= maximumInterval else {
            throw AutomationManifestError.intervalOutOfRange(
                field: field,
                value: raw,
                scheduleID: scheduleID
            )
        }
        return interval
    }

    /// Zero-padded 24-hour `"HH:mm"`, nothing looser.
    private static func dailyTime(
        _ raw: String,
        scheduleID: String
    ) throws -> Cadence {
        let characters = Array(raw)
        guard characters.count == 5,
              characters[2] == ":",
              characters[0].isASCII, characters[0].isNumber,
              characters[1].isASCII, characters[1].isNumber,
              characters[3].isASCII, characters[3].isNumber,
              characters[4].isASCII, characters[4].isNumber,
              let hour = Int(String(characters[0 ... 1])),
              let minute = Int(String(characters[3 ... 4])),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute)
        else {
            throw AutomationManifestError.invalidDailyTime(
                value: raw,
                scheduleID: scheduleID
            )
        }
        return .daily(hour: hour, minute: minute)
    }
}

/// The manifest's optional `automation` block.
public struct PluginAutomationManifest: Sendable, Equatable, Codable {
    public let schedules: [AutomationScheduleSpec]

    public init(schedules: [AutomationScheduleSpec]) throws {
        guard schedules.count <= AutomationScheduleSpec.maximumSchedulesPerPlugin
        else {
            throw AutomationManifestError.tooManySchedules(
                count: schedules.count
            )
        }
        var seen: Set<String> = []
        for schedule in schedules {
            guard seen.insert(schedule.id).inserted else {
                throw AutomationManifestError.duplicateScheduleID(schedule.id)
            }
        }
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schedules
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedFields = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = allFields.allKeys.first(
            where: { !allowedFields.contains($0.stringValue) }
        ) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription: "unknown automation field \(unknown.stringValue); known fields are schedules"
                )
            )
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schedules: c.decodeIfPresent(
                [AutomationScheduleSpec].self,
                forKey: .schedules
            ) ?? []
        )
    }
}

/// Manifest `automation` block failures, each carrying enough to fix the manifest.
public enum AutomationManifestError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidScheduleID(String)
    case duplicateScheduleID(String)
    case missingCadence(scheduleID: String)
    case conflictingCadence(scheduleID: String)
    case invalidDuration(field: String, value: String, scheduleID: String)
    case intervalOutOfRange(field: String, value: String, scheduleID: String)
    case invalidDailyTime(value: String, scheduleID: String)
    case tooManySchedules(count: Int)
    case unknownScheduleField(String)

    public var description: String {
        switch self {
        case .invalidScheduleID(let id):
            return "schedule id \"\(id)\" must be 1...\(AutomationScheduleSpec.maximumIDBytes) bytes"
        case .duplicateScheduleID(let id):
            return "schedule id \"\(id)\" appears more than once"
        case .missingCadence(let id):
            return "schedule \"\(id)\" needs exactly one of \"every\" or \"daily\""
        case .conflictingCadence(let id):
            return "schedule \"\(id)\" declares both \"every\" and \"daily\"; pick one"
        case .invalidDuration(let field, let value, let id):
            return "schedule \"\(id)\" \(field) \"\(value)\" is not a duration like \"5m\", \"2h\", \"1d\""
        case .intervalOutOfRange(let field, let value, let id):
            return "schedule \"\(id)\" \(field) \"\(value)\" must be between 1m and 7d; for sub-minute work use tenon.timers.every"
        case .invalidDailyTime(let value, let id):
            return "schedule \"\(id)\" daily \"\(value)\" must be zero-padded 24h \"HH:mm\""
        case .tooManySchedules(let count):
            return "\(count) schedules declared; the maximum is \(AutomationScheduleSpec.maximumSchedulesPerPlugin)"
        case .unknownScheduleField(let field):
            return "unknown schedule field \"\(field)\"; known fields are id, every, daily, grace"
        }
    }
}
