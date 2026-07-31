import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-060: the bounded, newest-first run buffer. Pure value rules — no scheduler,
/// no host, no clock.
final class AutomationRunHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    func testRecordsAreNewestFirst() {
        var history = AutomationRunHistory()
        history.record(record(schedule: "first", firedAt: t0))
        history.record(record(schedule: "second", firedAt: t0.addingTimeInterval(60)))

        XCTAssertEqual(
            history.records.map(\.scheduleID),
            ["second", "first"],
            "the surface reads the latest run first"
        )
    }

    func testCapacityDropsTheOldestRecord() {
        var history = AutomationRunHistory()
        for index in 0 ..< (AutomationRunHistory.capacity + 5) {
            history.record(
                record(
                    schedule: "run-\(index)",
                    firedAt: t0.addingTimeInterval(TimeInterval(index))
                )
            )
        }

        XCTAssertEqual(history.records.count, AutomationRunHistory.capacity)
        XCTAssertEqual(
            history.records.first?.scheduleID,
            "run-\(AutomationRunHistory.capacity + 4)",
            "the newest record survives"
        )
        XCTAssertEqual(
            history.records.last?.scheduleID,
            "run-5",
            "overflow drops from the old end, never the new"
        )
    }

    // MARK: - Helpers

    private func record(
        schedule: String,
        firedAt: Date
    ) -> AutomationRunRecord {
        AutomationRunRecord(
            pluginID: "dev.test.a",
            scheduleID: schedule,
            scheduledFor: firedAt,
            firedAt: firedAt,
            trigger: .scheduled,
            late: false,
            delivered: true
        )
    }
}
