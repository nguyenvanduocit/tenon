import Foundation
import XCTest
@testable import TenonCore

/// T-046: the manifest `automation.schedules` CONTRIBUTION block — strict decode,
/// fail-closed validation, and pure occurrence math, all without a window.
final class AutomationScheduleTests: XCTestCase {
    // MARK: - Duration and cadence parsing

    func testEveryDurationParsesWithIntervalDefaultGrace() throws {
        let spec = try decodeSpec(#"{"id":"t","every":"5m"}"#)
        XCTAssertEqual(spec.id, "t")
        XCTAssertEqual(spec.cadence, .every(300))
        XCTAssertEqual(
            spec.grace,
            300,
            "an every-schedule's default grace is one interval"
        )
    }

    func testEveryUnitsParse() throws {
        XCTAssertEqual(
            try decodeSpec(#"{"id":"t","every":"90s"}"#).cadence,
            .every(90)
        )
        XCTAssertEqual(
            try decodeSpec(#"{"id":"t","every":"2h"}"#).cadence,
            .every(7200)
        )
        XCTAssertEqual(
            try decodeSpec(#"{"id":"t","every":"1d"}"#).cadence,
            .every(86400)
        )
    }

    func testDailyParsesWithSixHourDefaultGrace() throws {
        let spec = try decodeSpec(#"{"id":"m","daily":"09:05"}"#)
        XCTAssertEqual(spec.cadence, .daily(hour: 9, minute: 5))
        XCTAssertEqual(
            spec.grace,
            AutomationScheduleSpec.defaultDailyGrace
        )
    }

    func testExplicitGraceParses() throws {
        let spec = try decodeSpec(#"{"id":"t","every":"5m","grace":"2h"}"#)
        XCTAssertEqual(spec.grace, 7200)
    }

    // MARK: - Fail-closed validation

    func testSubMinuteEveryIsRejected() {
        XCTAssertThrowsError(
            try decodeSpec(#"{"id":"t","every":"30s"}"#),
            "sub-minute cadence belongs to tenon.timers.every, not schedules"
        )
        XCTAssertThrowsError(
            try decodeSpec(#"{"id":"t","every":"5m","grace":"30s"}"#)
        )
    }

    func testMalformedDurationsAreRejected() {
        for bad in ["5x", "m5", "", "0m", "-5m", "5 m", "1.5h"] {
            XCTAssertThrowsError(
                try decodeSpec(
                    #"{"id":"t","every":"\#(bad)"}"#
                ),
                "duration \"\(bad)\" must be rejected"
            )
        }
    }

    func testIntervalAboveSevenDaysIsRejected() {
        XCTAssertThrowsError(try decodeSpec(#"{"id":"t","every":"8d"}"#))
        XCTAssertThrowsError(try decodeSpec(#"{"id":"t","every":"169h"}"#))
    }

    func testDailyTimeParsesStrictly() throws {
        XCTAssertEqual(
            try decodeSpec(#"{"id":"m","daily":"00:00"}"#).cadence,
            .daily(hour: 0, minute: 0)
        )
        XCTAssertEqual(
            try decodeSpec(#"{"id":"m","daily":"23:59"}"#).cadence,
            .daily(hour: 23, minute: 59)
        )
        for bad in ["9:00", "24:00", "09:60", "0900", "09-00", "aa:bb"] {
            XCTAssertThrowsError(
                try decodeSpec(#"{"id":"m","daily":"\#(bad)"}"#),
                "daily \"\(bad)\" must be rejected"
            )
        }
    }

    func testBothOrNeitherCadenceIsRejected() {
        XCTAssertThrowsError(
            try decodeSpec(#"{"id":"t","every":"5m","daily":"09:00"}"#)
        )
        XCTAssertThrowsError(try decodeSpec(#"{"id":"t"}"#))
    }

    func testUnknownFieldIsRejected() {
        XCTAssertThrowsError(
            try decodeSpec(#"{"id":"t","every":"5m","cron":"* * * * *"}"#),
            "unknown schedule fields fail closed, the palette-block precedent"
        )
    }

    func testScheduleIDBoundsAreEnforced() throws {
        XCTAssertThrowsError(try decodeSpec(#"{"id":"","every":"5m"}"#))
        let longest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try decodeSpec(#"{"id":"\#(longest)","every":"5m"}"#).id,
            longest
        )
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertThrowsError(
            try decodeSpec(#"{"id":"\#(tooLong)","every":"5m"}"#)
        )
    }

    func testDuplicateScheduleIDsAreRejected() {
        XCTAssertThrowsError(
            try decodeBlock(
                #"{"schedules":[{"id":"t","every":"5m"},{"id":"t","daily":"09:00"}]}"#
            )
        )
    }

    func testMoreThanEightSchedulesAreRejected() throws {
        let nine = (1 ... 9)
            .map { #"{"id":"s\#($0)","every":"5m"}"# }
            .joined(separator: ",")
        XCTAssertThrowsError(
            try decodeBlock(#"{"schedules":[\#(nine)]}"#)
        )
        let eight = (1 ... 8)
            .map { #"{"id":"s\#($0)","every":"5m"}"# }
            .joined(separator: ",")
        XCTAssertEqual(
            try decodeBlock(#"{"schedules":[\#(eight)]}"#).schedules.count,
            8
        )
    }

    // MARK: - Occurrence math

    func testEveryNextOccurrenceAdvancesByInterval() throws {
        let spec = try AutomationScheduleSpec(id: "t", cadence: .every(300))
        let base = date(2026, 7, 31, 8, 0, calendar: saigon)
        XCTAssertEqual(
            spec.nextOccurrence(after: base, calendar: saigon),
            base.addingTimeInterval(300)
        )
    }

    func testDailyNextOccurrenceFindsNextLocalTime() throws {
        let spec = try AutomationScheduleSpec(
            id: "m",
            cadence: .daily(hour: 9, minute: 0)
        )
        let beforeNine = date(2026, 7, 31, 8, 0, calendar: saigon)
        XCTAssertEqual(
            spec.nextOccurrence(after: beforeNine, calendar: saigon),
            date(2026, 7, 31, 9, 0, calendar: saigon)
        )
        let afterNine = date(2026, 7, 31, 9, 30, calendar: saigon)
        XCTAssertEqual(
            spec.nextOccurrence(after: afterNine, calendar: saigon),
            date(2026, 8, 1, 9, 0, calendar: saigon)
        )
        let exactlyNine = date(2026, 7, 31, 9, 0, calendar: saigon)
        XCTAssertEqual(
            spec.nextOccurrence(after: exactlyNine, calendar: saigon),
            date(2026, 8, 1, 9, 0, calendar: saigon),
            "an occurrence is strictly after the reference instant"
        )
    }

    func testDailySurvivesDSTTransition() throws {
        // US spring-forward: 2026-03-08 02:00 EST jumps to 03:00 EDT. A 09:00
        // schedule still means 09:00 local wall clock on the shortened day.
        let spec = try AutomationScheduleSpec(
            id: "m",
            cadence: .daily(hour: 9, minute: 0)
        )
        let saturday = date(2026, 3, 7, 10, 0, calendar: newYork)
        let next = spec.nextOccurrence(after: saturday, calendar: newYork)
        let parts = newYork.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: next
        )
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 0)
    }

    // MARK: - Manifest integration

    func testAutomationBlockRoundTripsThroughCodable() throws {
        let block = try decodeBlock(
            #"{"schedules":[{"id":"t","every":"5m","grace":"2h"},{"id":"m","daily":"09:00"}]}"#
        )
        let encoded = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(
            PluginAutomationManifest.self,
            from: encoded
        )
        XCTAssertEqual(decoded, block)
    }

    func testManifestCarriesAutomationBlock() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(
                #"""
                {
                  "id": "dev.test.automated",
                  "name": "automated",
                  "version": "1",
                  "intents": { "uses": [], "provides": [] },
                  "automation": { "schedules": [ { "id": "tick", "every": "1m" } ] }
                }
                """#.utf8
            )
        )
        XCTAssertEqual(
            manifest.automation?.schedules,
            [
                try AutomationScheduleSpec(
                    id: "tick",
                    cadence: .every(60)
                ),
            ]
        )
    }

    func testManifestWithoutAutomationBlockDecodesUnchanged() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(
                #"""
                {
                  "id": "dev.tenon.clock",
                  "name": "clock",
                  "version": "0.1.0",
                  "permissions": [],
                  "intents": { "uses": [], "provides": [] }
                }
                """#.utf8
            )
        )
        XCTAssertNil(manifest.automation)
    }

    func testUnknownBlockFieldIsRejected() {
        XCTAssertThrowsError(
            try decodeBlock(#"{"schedules":[],"timezone":"UTC"}"#),
            "no stored timezone, deliberately — Orca's is dead metadata"
        )
    }

    // MARK: - Helpers

    private func decodeSpec(_ json: String) throws -> AutomationScheduleSpec {
        try JSONDecoder().decode(
            AutomationScheduleSpec.self,
            from: Data(json.utf8)
        )
    }

    private func decodeBlock(_ json: String) throws -> PluginAutomationManifest {
        try JSONDecoder().decode(
            PluginAutomationManifest.self,
            from: Data(json.utf8)
        )
    }

    private var saigon: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
