import XCTest
import TenonIntentCore
@testable import TenonApp
@testable import TenonCore

@MainActor
final class AutomationScheduledDeliveryTests: XCTestCase {
    func testDisablingWhileFirstFiringIsInFlightPreventsSecondFromStarting() async {
        let first = firing(scheduleID: "first")
        let second = firing(scheduleID: "second")
        var schedulesEnabled = true
        var schedulesRevision: UInt64 = 0
        let pausedSchedules: Set<AutomationScheduleKey> = []
        let scheduleRevisions: [AutomationScheduleKey: UInt64] = [:]
        var started: [String] = []
        var completed: [String] = []

        await ScheduledAutomationDelivery.deliver(
            [first, second],
            batchEpoch: batchEpoch(
                for: [first, second],
                globalRevision: schedulesRevision,
                scheduleRevisions: scheduleRevisions
            ),
            currentState: { key in
                .init(
                    enabled: schedulesEnabled,
                    globalRevision: schedulesRevision,
                    paused: pausedSchedules.contains(key),
                    scheduleRevision: scheduleRevisions[key, default: 0]
                )
            },
            delivery: { firing in
                started.append(firing.scheduleID)
                if firing.scheduleID == first.scheduleID {
                    // Model the real host delivery suspension. MainActor can run the
                    // Settings toggle while the first event is still in flight.
                    await Task.yield()
                    schedulesEnabled = false
                    schedulesRevision += 1
                }
                completed.append(firing.scheduleID)
            }
        )

        XCTAssertEqual(
            started,
            [first.scheduleID],
            "the per-firing gate must stop the second delivery before it starts"
        )
        XCTAssertEqual(
            completed,
            [first.scheduleID],
            "the already-started delivery is allowed to complete"
        )
    }

    func testOffOnCycleWhileFirstFiringIsInFlightInvalidatesTheOldBatch() async {
        let first = firing(scheduleID: "first")
        let second = firing(scheduleID: "second")
        var schedulesEnabled = true
        var schedulesRevision: UInt64 = 4
        let pausedSchedules: Set<AutomationScheduleKey> = []
        let scheduleRevisions: [AutomationScheduleKey: UInt64] = [:]
        var started: [String] = []
        var completed: [String] = []

        await ScheduledAutomationDelivery.deliver(
            [first, second],
            batchEpoch: batchEpoch(
                for: [first, second],
                globalRevision: schedulesRevision,
                scheduleRevisions: scheduleRevisions
            ),
            currentState: { key in
                .init(
                    enabled: schedulesEnabled,
                    globalRevision: schedulesRevision,
                    paused: pausedSchedules.contains(key),
                    scheduleRevision: scheduleRevisions[key, default: 0]
                )
            },
            delivery: { firing in
                started.append(firing.scheduleID)
                if firing.scheduleID == first.scheduleID {
                    await Task.yield()
                    schedulesEnabled = false
                    schedulesRevision += 1
                    schedulesEnabled = true
                    schedulesRevision += 1
                }
                completed.append(firing.scheduleID)
            }
        )

        XCTAssertTrue(schedulesEnabled, "the control proves the preference ended enabled")
        XCTAssertEqual(
            started,
            [first.scheduleID],
            "re-enabling must not revive a batch created before the Off/On cycle"
        )
        XCTAssertEqual(completed, [first.scheduleID])
    }

    func testUnchangedEnabledRevisionDeliversTheWholeBatch() async {
        let firings = [firing(scheduleID: "first"), firing(scheduleID: "second")]
        let revision: UInt64 = 9
        var delivered: [String] = []

        await ScheduledAutomationDelivery.deliver(
            firings,
            batchEpoch: batchEpoch(
                for: firings,
                globalRevision: revision,
                scheduleRevisions: [:]
            ),
            currentState: { _ in
                .init(
                    enabled: true,
                    globalRevision: revision,
                    paused: false,
                    scheduleRevision: 0
                )
            },
            delivery: { firing in
                await Task.yield()
                delivered.append(firing.scheduleID)
            }
        )

        XCTAssertEqual(delivered, firings.map(\.scheduleID))
    }

    func testPausingOneScheduleDoesNotDropUnrelatedFiringsInTheBatch() async {
        let first = firing(scheduleID: "first")
        let second = firing(scheduleID: "second")
        let changed = firing(scheduleID: "changed")
        let firings = [first, second, changed]
        let changedKey = key(for: changed)
        var pausedSchedules: Set<AutomationScheduleKey> = []
        var scheduleRevisions: [AutomationScheduleKey: UInt64] = [:]
        var delivered: [String] = []

        await ScheduledAutomationDelivery.deliver(
            firings,
            batchEpoch: batchEpoch(
                for: firings,
                globalRevision: 0,
                scheduleRevisions: scheduleRevisions
            ),
            currentState: { key in
                .init(
                    enabled: true,
                    globalRevision: 0,
                    paused: pausedSchedules.contains(key),
                    scheduleRevision: scheduleRevisions[key, default: 0]
                )
            },
            delivery: { firing in
                delivered.append(firing.scheduleID)
                if firing.scheduleID == first.scheduleID {
                    await Task.yield()
                    pausedSchedules.insert(changedKey)
                    scheduleRevisions[changedKey, default: 0] &+= 1
                }
            }
        )

        XCTAssertEqual(
            delivered,
            [first.scheduleID, second.scheduleID],
            "a changed schedule is skipped without invalidating an unrelated owner"
        )
    }

    func testPauseResumeCycleInvalidatesOnlyThatSchedulesOldFiring() async {
        let first = firing(scheduleID: "first")
        let changed = firing(scheduleID: "changed")
        let last = firing(scheduleID: "last")
        let firings = [first, changed, last]
        let changedKey = key(for: changed)
        var pausedSchedules: Set<AutomationScheduleKey> = []
        var scheduleRevisions: [AutomationScheduleKey: UInt64] = [:]
        var delivered: [String] = []

        await ScheduledAutomationDelivery.deliver(
            firings,
            batchEpoch: batchEpoch(
                for: firings,
                globalRevision: 0,
                scheduleRevisions: scheduleRevisions
            ),
            currentState: { key in
                .init(
                    enabled: true,
                    globalRevision: 0,
                    paused: pausedSchedules.contains(key),
                    scheduleRevision: scheduleRevisions[key, default: 0]
                )
            },
            delivery: { firing in
                delivered.append(firing.scheduleID)
                if firing.scheduleID == first.scheduleID {
                    await Task.yield()
                    pausedSchedules.insert(changedKey)
                    scheduleRevisions[changedKey, default: 0] &+= 1
                    pausedSchedules.remove(changedKey)
                    scheduleRevisions[changedKey, default: 0] &+= 1
                }
            }
        )

        XCTAssertFalse(pausedSchedules.contains(changedKey))
        XCTAssertEqual(
            delivered,
            [first.scheduleID, last.scheduleID],
            "resume must not revive one schedule's firing from a pre-pause batch"
        )
    }

    func testPreferencesPolicyEpochsChangeAtTheirOwningScope() throws {
        let suiteName = "AutomationScheduledDeliveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prefs = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(prefs.automationSchedulesRevision, 0)
        prefs.preferences.automationSchedulesEnabled = true
        XCTAssertEqual(
            prefs.automationSchedulesRevision,
            0,
            "assigning the same value must not invalidate an active batch"
        )

        prefs.preferences.sidebarWidth += 1
        XCTAssertEqual(
            prefs.automationSchedulesRevision,
            0,
            "unrelated settings do not identify a new automation epoch"
        )

        let key = AutomationScheduleKey(
            pluginID: "dev.example.automation",
            scheduleID: "daily"
        )
        prefs.preferences.pausedAutomationSchedules.insert(key)
        XCTAssertEqual(prefs.automationSchedulesRevision, 0)
        XCTAssertEqual(prefs.automationScheduleRevision(for: key), 1)
        prefs.preferences.pausedAutomationSchedules.remove(key)
        XCTAssertEqual(prefs.automationSchedulesRevision, 0)
        XCTAssertEqual(prefs.automationScheduleRevision(for: key), 2)

        prefs.preferences.automationSchedulesEnabled = false
        XCTAssertEqual(prefs.automationSchedulesRevision, 1)
        prefs.preferences.automationSchedulesEnabled = true
        XCTAssertEqual(prefs.automationSchedulesRevision, 2)
        XCTAssertEqual(
            prefs.automationScheduleRevision(for: key),
            2,
            "global policy changes must not rewrite an owner's epoch"
        )
    }

    private func batchEpoch(
        for firings: [AutomationScheduler.Firing],
        globalRevision: UInt64,
        scheduleRevisions: [AutomationScheduleKey: UInt64]
    ) -> ScheduledAutomationDelivery.BatchEpoch {
        .init(
            globalRevision: globalRevision,
            scheduleRevisions: Dictionary(
                uniqueKeysWithValues: firings.map { firing in
                    let key = key(for: firing)
                    return (key, scheduleRevisions[key, default: 0])
                }
            )
        )
    }

    private func key(
        for firing: AutomationScheduler.Firing
    ) -> AutomationScheduleKey {
        AutomationScheduleKey(
            pluginID: firing.pluginID,
            scheduleID: firing.scheduleID
        )
    }

    private func firing(
        scheduleID: String
    ) -> AutomationScheduler.Firing {
        AutomationScheduler.Firing(
            pluginID: "dev.example.automation",
            scheduleID: scheduleID,
            scheduledFor: Date(timeIntervalSince1970: 1_000),
            late: false,
            trigger: .scheduled
        )
    }
}
