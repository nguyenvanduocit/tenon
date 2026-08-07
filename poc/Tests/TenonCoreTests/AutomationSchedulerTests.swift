import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// T-046: the host-side scheduler — due computation with time as a parameter.
/// Every rule here is a mutation target: firing exactly once, grace skipping,
/// phase preservation across reconciles, and the loaded/enabled gate.
@MainActor
final class AutomationSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    func testTickBeforeDueFiresNothing() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        XCTAssertEqual(scheduler.tick(now: t0.addingTimeInterval(59)), [])
    }

    func testDueScheduleFiresExactlyOnceAndAdvances() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )

        let due = t0.addingTimeInterval(60)
        XCTAssertEqual(
            scheduler.tick(now: due),
            [
                AutomationScheduler.Firing(
                    pluginID: "dev.test.a",
                    scheduleID: "tick",
                    scheduledFor: due,
                    late: false,
                    trigger: .scheduled
                ),
            ]
        )
        XCTAssertEqual(
            scheduler.tick(now: due.addingTimeInterval(1)),
            [],
            "a fired occurrence must not fire again"
        )
        XCTAssertEqual(
            scheduler.tick(now: due.addingTimeInterval(60)).map(\.scheduledFor),
            [due.addingTimeInterval(60)],
            "the next interval anchors on the firing tick"
        )
    }

    func testDoubleTickAtTheSameInstantFiresOnce() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        let due = t0.addingTimeInterval(60)
        XCTAssertEqual(scheduler.tick(now: due).count, 1)
        XCTAssertEqual(scheduler.tick(now: due), [])
    }

    func testTickSkipsBeyondGraceAndAdvances() throws {
        // One hour cadence with a one-minute grace: recovering 5 minutes late is
        // beyond grace, so the miss skips silently and the schedule re-arms.
        let hourly = try AutomationScheduleSpec(
            id: "hourly",
            cadence: .every(3600),
            grace: 60
        )
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [hourly])],
            now: t0
        )

        let staleRecovery = t0.addingTimeInterval(3600 + 300)
        XCTAssertEqual(
            scheduler.tick(now: staleRecovery),
            [],
            "a miss staler than its grace must skip, not fire"
        )
        XCTAssertEqual(
            scheduler.tick(now: staleRecovery.addingTimeInterval(3600)).count,
            1,
            "the skipped schedule must re-arm from the recovery tick"
        )
    }

    func testLatestMissedDailyOccurrenceFiresOnceLate() throws {
        let daily = try AutomationScheduleSpec(
            id: "morning",
            cadence: .daily(hour: 9, minute: 0)
        )
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [daily])],
            now: date(2026, 7, 30, 10, 0)
        )

        // Two mornings pass unobserved; recovery at 09:30 on the third day fires
        // exactly the latest occurrence, marked late, and never the stale ones.
        let firings = scheduler.tick(now: date(2026, 8, 2, 9, 30))
        XCTAssertEqual(
            firings,
            [
                AutomationScheduler.Firing(
                    pluginID: "dev.test.a",
                    scheduleID: "morning",
                    scheduledFor: date(2026, 8, 2, 9, 0),
                    late: true,
                    trigger: .scheduled
                ),
            ]
        )
        XCTAssertEqual(
            scheduler.tick(now: date(2026, 8, 3, 9, 0)).map(\.scheduledFor),
            [date(2026, 8, 3, 9, 0)]
        )
    }

    func testDisabledOrUnloadedPluginNeverSchedules() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [
                snapshot(
                    id: "dev.test.unloaded",
                    schedules: [try every60()],
                    isLoaded: false
                ),
                snapshot(
                    id: "dev.test.disabled",
                    schedules: [try every60()],
                    isEnabled: false
                ),
            ],
            now: t0
        )
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(86400)),
            []
        )
    }

    func testReconcilePreservesPhaseAcrossUnchangedReload() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        let plugins = [snapshot(id: "dev.test.a", schedules: [try every60()])]
        scheduler.reconcile(plugins, now: t0)
        scheduler.reconcile(plugins, now: t0.addingTimeInterval(30))

        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(60)).count,
            1,
            "an unchanged spec keeps its phase; reconcile must not reset nextDue"
        )
    }

    func testChangedSpecRecomputesFromReconcileTime() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        let slower = try AutomationScheduleSpec(
            id: "tick",
            cadence: .every(120)
        )
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [slower])],
            now: t0.addingTimeInterval(30)
        )

        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(60)),
            [],
            "the old 60s phase must be gone after the spec changed"
        )
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(150)).map(\.scheduledFor),
            [t0.addingTimeInterval(150)]
        )
    }

    func testVanishedPluginDropsItsSchedules() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        scheduler.reconcile([], now: t0.addingTimeInterval(10))
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(86400)),
            []
        )
    }

    func testFiringsAreDeterministicallyOrdered() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [
                snapshot(id: "dev.test.b", schedules: [try every60()]),
                snapshot(id: "dev.test.a", schedules: [try every60()]),
            ],
            now: t0
        )
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(60)).map(\.pluginID),
            ["dev.test.a", "dev.test.b"]
        )
    }

    // MARK: - T-060: listings, Run now, run history

    func testListingsExposeActiveSchedulesSortedWithNextDue() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        let daily = try AutomationScheduleSpec(
            id: "morning",
            cadence: .daily(hour: 9, minute: 0)
        )
        scheduler.reconcile(
            [
                snapshot(id: "dev.test.b", schedules: [try every60()]),
                snapshot(id: "dev.test.a", schedules: [daily, try every60()]),
                snapshot(
                    id: "dev.test.disabled",
                    schedules: [try every60()],
                    isEnabled: false
                ),
            ],
            now: t0
        )

        XCTAssertEqual(
            scheduler.listings(),
            [
                AutomationScheduler.ScheduleListing(
                    pluginID: "dev.test.a",
                    spec: daily,
                    nextDue: daily.nextOccurrence(after: t0, calendar: saigon)
                ),
                AutomationScheduler.ScheduleListing(
                    pluginID: "dev.test.a",
                    spec: try every60(),
                    nextDue: t0.addingTimeInterval(60)
                ),
                AutomationScheduler.ScheduleListing(
                    pluginID: "dev.test.b",
                    spec: try every60(),
                    nextDue: t0.addingTimeInterval(60)
                ),
            ],
            "listings show every armed schedule, deterministically ordered; a disabled plugin's schedule is not armed"
        )
    }

    func testListingsTrackTheAdvancedPhaseAfterAFiring() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        _ = scheduler.tick(now: t0.addingTimeInterval(60))

        XCTAssertEqual(
            scheduler.listings().map(\.nextDue),
            [t0.addingTimeInterval(120)],
            "next-due must be the live phase, not the reconcile-time one"
        )
    }

    func testManualFiringCarriesManualTriggerAndLeavesPhaseUntouched() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )

        let runNowAt = t0.addingTimeInterval(10)
        let firing = try XCTUnwrap(
            scheduler.manualFiring(
                pluginID: "dev.test.a",
                scheduleID: "tick",
                now: runNowAt
            )
        )
        XCTAssertEqual(
            firing,
            AutomationScheduler.Firing(
                pluginID: "dev.test.a",
                scheduleID: "tick",
                scheduledFor: runNowAt,
                late: false,
                trigger: .manual
            )
        )
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(60)).map(\.scheduledFor),
            [t0.addingTimeInterval(60)],
            "Run now must not shift the schedule's phase"
        )
    }

    func testManualFiringForAnUnarmedScheduleReturnsNil() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [
                snapshot(id: "dev.test.a", schedules: [try every60()]),
                snapshot(
                    id: "dev.test.disabled",
                    schedules: [try every60()],
                    isEnabled: false
                ),
            ],
            now: t0
        )

        XCTAssertNil(
            scheduler.manualFiring(
                pluginID: "dev.test.a",
                scheduleID: "no-such-schedule",
                now: t0
            )
        )
        XCTAssertNil(
            scheduler.manualFiring(
                pluginID: "dev.test.disabled",
                scheduleID: "tick",
                now: t0
            ),
            "a disabled plugin's schedule is not armed, so Run now has nothing to fire"
        )
    }

    func testPausedScheduleSkipsScheduledDeliveryButKeepsAdvancing() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        let spec = try every60()
        let key = AutomationScheduleKey(
            pluginID: "dev.test.a",
            scheduleID: spec.id
        )
        scheduler.reconcile(
            [snapshot(id: key.pluginID, schedules: [spec])],
            now: t0
        )
        scheduler.setPausedScheduleKeys([key])

        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(60)),
            [],
            "a paused schedule advances without delivering"
        )
        XCTAssertEqual(
            scheduler.listings().map(\.nextDue),
            [t0.addingTimeInterval(120)]
        )

        scheduler.setPausedScheduleKeys([])
        XCTAssertEqual(
            scheduler.tick(now: t0.addingTimeInterval(120)).map(\.scheduledFor),
            [t0.addingTimeInterval(120)],
            "resume starts at the live phase and never catches up the skipped event"
        )
    }

    func testManualFiringRemainsAvailableWhileScheduleIsPaused() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        let spec = try every60()
        let key = AutomationScheduleKey(
            pluginID: "dev.test.a",
            scheduleID: spec.id
        )
        scheduler.reconcile(
            [snapshot(id: key.pluginID, schedules: [spec])],
            now: t0
        )
        scheduler.setPausedScheduleKeys([key])

        XCTAssertEqual(
            scheduler.manualFiring(
                pluginID: key.pluginID,
                scheduleID: key.scheduleID,
                now: t0.addingTimeInterval(10)
            )?.trigger,
            .manual
        )
    }

    func testRecordedRunsSurviveReconcile() throws {
        let scheduler = AutomationScheduler(calendar: saigon)
        scheduler.reconcile(
            [snapshot(id: "dev.test.a", schedules: [try every60()])],
            now: t0
        )
        let firing = try XCTUnwrap(
            scheduler.tick(now: t0.addingTimeInterval(60)).first
        )
        scheduler.recordRun(
            firing,
            firedAt: t0.addingTimeInterval(61),
            delivered: true
        )

        // A hot reload that changes the spec reconciles the schedule table; the
        // history describes the past and must not be rewritten by it.
        scheduler.reconcile(
            [
                snapshot(
                    id: "dev.test.a",
                    schedules: [
                        try AutomationScheduleSpec(id: "tick", cadence: .every(120)),
                    ]
                ),
            ],
            now: t0.addingTimeInterval(90)
        )

        let record = try XCTUnwrap(scheduler.runHistory.records.only)
        XCTAssertEqual(record.pluginID, "dev.test.a")
        XCTAssertEqual(record.scheduleID, "tick")
        XCTAssertEqual(record.scheduledFor, t0.addingTimeInterval(60))
        XCTAssertEqual(record.firedAt, t0.addingTimeInterval(61))
        XCTAssertEqual(record.trigger, .scheduled)
        XCTAssertFalse(record.late)
        XCTAssertTrue(record.delivered)
    }

    // MARK: - Helpers

    private func every60() throws -> AutomationScheduleSpec {
        try AutomationScheduleSpec(id: "tick", cadence: .every(60))
    }

    private func snapshot(
        id: PluginID,
        schedules: [AutomationScheduleSpec],
        isLoaded: Bool = true,
        isEnabled: Bool = true
    ) -> PluginSnapshot {
        PluginSnapshot(
            id: id,
            installationID: nil,
            name: id.rawValue,
            version: "1",
            permissions: [],
            unknownPermissions: [],
            settingSpecs: [],
            icon: nil,
            displayName: nil,
            isLoaded: isLoaded,
            isEnabled: isEnabled,
            permissionViolations: [],
            error: nil,
            automationSchedules: schedules
        )
    }

    private var saigon: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        saigon.date(
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

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
