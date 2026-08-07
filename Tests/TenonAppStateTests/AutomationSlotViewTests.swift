import XCTest
import TenonCore
import TenonIntentCore
@testable import TenonApp

@MainActor
final class AutomationSlotViewTests: XCTestCase {
    func testPaneDensityMatchesTheNativeCanvasBudget() {
        XCTAssertEqual(AutomationPaneMetrics.contentInset, 12)
        XCTAssertEqual(AutomationPaneMetrics.sectionSpacing, 14)
        XCTAssertEqual(AutomationPaneMetrics.headerHeight, 44)
        XCTAssertEqual(AutomationPaneMetrics.summaryHeight, 48)
        XCTAssertEqual(AutomationPaneMetrics.navigatorWidth, 280)
        XCTAssertEqual(AutomationPaneMetrics.scheduleRowHeight, 54)
        XCTAssertEqual(AutomationPaneMetrics.activityRowHeight, 44)
        XCTAssertEqual(AutomationPaneMetrics.controlHeight, 28)
        XCTAssertTrue((28 ... 30).contains(AutomationPaneMetrics.controlHeight))
    }

    func testNavigatorStaysPinnedToTopWhenAFilterHasNoResults() throws {
        let source = try automationSlotViewSource()

        let wideLayoutStart = try XCTUnwrap(source.range(of: "HStack(spacing: 0) {")?.upperBound)
        let navigatorEnd = try XCTUnwrap(
            source.range(
                of: "AutomationVerticalDivider()",
                range: wideLayoutStart ..< source.endIndex
            )?.lowerBound
        )
        let wideNavigator = source[wideLayoutStart ..< navigatorEnd]

        XCTAssertTrue(
            wideNavigator.contains(".frame(maxHeight: .infinity, alignment: .top)"),
            "The wide navigator must fill its split column and pin intrinsic empty content to the top."
        )

        let compactHeight = try XCTUnwrap(
            source.range(of: "height: AutomationPaneMetrics.navigatorCompactHeight")
        )
        let compactEnd = source.index(
            compactHeight.upperBound,
            offsetBy: 120,
            limitedBy: source.endIndex
        ) ?? source.endIndex
        XCTAssertTrue(
            source[compactHeight.lowerBound ..< compactEnd].contains("alignment: .top"),
            "The compact navigator must pin intrinsic empty content to the top of its fixed height."
        )
    }

    func testSearchAndFilterBelongToTheDashboardHeaderInsteadOfListContent() throws {
        let source = try automationSlotViewSource()
        let headerStart = try XCTUnwrap(
            source.range(of: "private struct AutomationDashboardHeader")?.lowerBound
        )
        let headerEnd = try XCTUnwrap(
            source.range(of: "private struct AutomationSummaryStrip")?.lowerBound
        )
        let navigatorStart = try XCTUnwrap(
            source.range(of: "private struct AutomationScheduleNavigator")?.lowerBound
        )
        let navigatorEnd = try XCTUnwrap(
            source.range(of: "private struct AutomationScheduleNavigatorRow")?.lowerBound
        )

        let header = source[headerStart ..< headerEnd]
        let navigator = source[navigatorStart ..< navigatorEnd]

        XCTAssertTrue(header.contains("AutomationScheduleToolbar("))
        XCTAssertFalse(navigator.contains("TextField("))
        XCTAssertFalse(navigator.contains("Picker(\"Schedule filter\""))
    }

    func testCompactHeaderKeepsPrimaryActionAndToolbarReachableAtNarrowWidths() throws {
        let source = try automationSlotViewSource()
        let headerStart = try XCTUnwrap(
            source.range(of: "private struct AutomationDashboardHeader")?.lowerBound
        )
        let toolbarStart = try XCTUnwrap(
            source.range(of: "private struct AutomationScheduleToolbar")?.lowerBound
        )
        let toolbarEnd = try XCTUnwrap(
            source.range(of: "private struct AutomationSummaryStrip")?.lowerBound
        )
        let header = source[headerStart ..< toolbarStart]
        let toolbar = source[toolbarStart ..< toolbarEnd]
        let compactHeaderStart = try XCTUnwrap(
            header.range(of: "private var compactHeader")?.lowerBound
        )
        let compactHeaderEnd = try XCTUnwrap(
            header.range(of: "private var title")?.lowerBound
        )
        let narrowHeaderStart = try XCTUnwrap(
            header.range(of: "private var narrowHeader")?.lowerBound
        )
        let compactHeader = header[compactHeaderStart ..< compactHeaderEnd]
        let narrowHeader = header[narrowHeaderStart ..< header.endIndex]
        let toolbarBodyStart = try XCTUnwrap(
            toolbar.range(of: "var body: some View")?.lowerBound
        )
        let toolbarBodyEnd = try XCTUnwrap(
            toolbar.range(of: "private var singleRow")?.lowerBound
        )
        let stackedRowsStart = try XCTUnwrap(
            toolbar.range(of: "private var stackedRows")?.lowerBound
        )
        let stackedRowsEnd = try XCTUnwrap(
            toolbar.range(of: "private var searchField")?.lowerBound
        )
        let toolbarBody = toolbar[toolbarBodyStart ..< toolbarBodyEnd]
        let stackedRows = toolbar[stackedRowsStart ..< stackedRowsEnd]

        XCTAssertTrue(compactHeader.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(compactHeader.contains("narrowHeader"))
        XCTAssertTrue(compactHeader.contains("allowsStackedLayout: true"))
        XCTAssertTrue(narrowHeader.contains("tenon.automation.create.compact"))
        XCTAssertTrue(toolbarBody.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(toolbarBody.contains("singleRow"))
        XCTAssertTrue(toolbarBody.contains("stackedRows"))
        XCTAssertTrue(stackedRows.contains(".pickerStyle(.menu)"))
    }

    func testScheduleIdentityUsesBothOwningPluginAndManifestScheduleID() {
        XCTAssertEqual(
            AutomationPanePresentation.scheduleRowID(
                pluginID: "dev.example.one",
                scheduleID: "daily"
            ),
            "dev.example.one/daily"
        )
        XCTAssertNotEqual(
            AutomationPanePresentation.scheduleRowID(
                pluginID: "dev.example.one",
                scheduleID: "daily"
            ),
            AutomationPanePresentation.scheduleRowID(
                pluginID: "dev.example.two",
                scheduleID: "daily"
            )
        )
    }

    func testCadenceProjectionStaysCompact() throws {
        XCTAssertEqual(
            AutomationPanePresentation.cadenceText(
                try AutomationScheduleSpec(id: "hourly", cadence: .every(3_600))
            ),
            "Every 1h"
        )
        XCTAssertEqual(
            AutomationPanePresentation.cadenceText(
                try AutomationScheduleSpec(
                    id: "morning",
                    cadence: .daily(hour: 7, minute: 5)
                )
            ),
            "Daily at 07:05"
        )
    }

    func testScheduleTitleTurnsManifestIDsIntoScannableLabels() {
        XCTAssertEqual(
            AutomationPanePresentation.scheduleTitle("daily_repo-audit"),
            "Daily Repo Audit"
        )
    }

    func testDashboardShowsOnlyEnabledPluginSchedules() throws {
        let active = try AutomationScheduleSpec(id: "active", cadence: .every(60))
        let disabled = try AutomationScheduleSpec(id: "disabled", cadence: .every(120))
        let unloaded = try AutomationScheduleSpec(id: "unloaded", cadence: .every(180))
        let activePlugin = snapshot(
            id: "dev.example.active",
            title: "Active Plugin",
            schedules: [active]
        )
        let disabledPlugin = snapshot(
            id: "dev.example.disabled",
            title: "Disabled Plugin",
            schedules: [disabled],
            isEnabled: false
        )
        let unloadedPlugin = snapshot(
            id: "dev.example.unloaded",
            title: "Unloaded Plugin",
            schedules: [unloaded],
            isLoaded: false
        )
        let scheduler = AutomationScheduler(calendar: calendar)
        scheduler.reconcile(
            [disabledPlugin, activePlugin, unloadedPlugin],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let due = Date(timeIntervalSince1970: 1_060)

        let summaries = AutomationPanePresentation.summaries(
            plugins: [disabledPlugin, activePlugin, unloadedPlugin],
            listings: scheduler.listings(),
            pausedScheduleKeys: [],
            records: []
        )

        XCTAssertEqual(
            summaries.map(\.scheduleID),
            ["active", "unloaded"],
            "a disabled plugin contributes no automation surface at all"
        )
        XCTAssertEqual(summaries.first?.nextDue, due)
        XCTAssertEqual(summaries.last?.availability, .pluginUnavailable(nil))
        XCTAssertNil(
            summaries.last?.nextDue,
            "an enabled plugin that is not loaded stays visible without pretending it is armed"
        )
    }

    func testEmptyDetailAsksForSchedulesFromTheSameEnabledRule() throws {
        let source = try automationSlotViewSource()

        XCTAssertFalse(
            source.contains("host.plugins.flatMap(\\.automationSchedules)"),
            "the empty state must reuse the summaries rule instead of counting every declaration"
        )
        XCTAssertTrue(
            source.contains("hasSchedules: !summaries.isEmpty"),
            "'no automations yet' follows exactly what the navigator can show"
        )
    }

    func testAttentionFilterUsesDroppedDeliveryAndPluginAvailability() throws {
        let spec = try AutomationScheduleSpec(id: "audit", cadence: .every(60))
        let key = AutomationScheduleKey(
            pluginID: "dev.example.audit",
            scheduleID: spec.id
        )
        let dropped = AutomationRunRecord(
            id: UUID(),
            pluginID: key.pluginID,
            scheduleID: key.scheduleID,
            scheduledFor: Date(timeIntervalSince1970: 1_000),
            firedAt: Date(timeIntervalSince1970: 1_001),
            trigger: .scheduled,
            late: false,
            delivered: false
        )
        let plugin = snapshot(
            id: key.pluginID,
            title: "Audit",
            schedules: [spec]
        )
        let scheduler = AutomationScheduler(calendar: calendar)
        scheduler.reconcile(
            [plugin],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let summaries = AutomationPanePresentation.summaries(
            plugins: [plugin],
            listings: scheduler.listings(),
            pausedScheduleKeys: [],
            records: [dropped]
        )

        XCTAssertEqual(
            AutomationPanePresentation.filteredSummaries(
                summaries,
                query: "audit",
                filter: .attention,
                globalDeliveryEnabled: true
            ).map(\.id),
            [key]
        )
        XCTAssertEqual(
            summaries.only?.state(globalDeliveryEnabled: true),
            .attention
        )
    }

    func testNextDueAndActiveCountIgnoreAnIndividuallyPausedSchedule() throws {
        let paused = try AutomationScheduleSpec(id: "paused", cadence: .every(60))
        let active = try AutomationScheduleSpec(id: "active", cadence: .every(120))
        let plugin = snapshot(
            id: "dev.example.automation",
            title: "Automation",
            schedules: [paused, active]
        )
        let pausedKey = AutomationScheduleKey(
            pluginID: plugin.id,
            scheduleID: paused.id
        )
        let scheduler = AutomationScheduler(calendar: calendar)
        scheduler.reconcile(
            [plugin],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let summaries = AutomationPanePresentation.summaries(
            plugins: [plugin],
            listings: scheduler.listings(),
            pausedScheduleKeys: [pausedKey],
            records: []
        )

        XCTAssertEqual(
            AutomationPanePresentation.activeCount(
                summaries,
                globalDeliveryEnabled: true
            ),
            1
        )
        XCTAssertEqual(
            AutomationPanePresentation.nextDue(
                summaries,
                globalDeliveryEnabled: true
            ),
            Date(timeIntervalSince1970: 1_120)
        )
    }

    func testScheduleHistoryKeepsNewestFirstOrderAndStableIDsWhileBoundingRows() {
        let key = AutomationScheduleKey(
            pluginID: "dev.example.automation",
            scheduleID: "daily"
        )
        let records = (0 ... AutomationPaneMetrics.maximumScheduleHistory).map { offset in
            AutomationRunRecord(
                id: UUID(),
                pluginID: key.pluginID,
                scheduleID: key.scheduleID,
                scheduledFor: Date(timeIntervalSince1970: TimeInterval(1_000 - offset)),
                firedAt: Date(timeIntervalSince1970: TimeInterval(1_000 - offset)),
                trigger: .scheduled,
                late: false,
                delivered: true
            )
        }

        let visible = AutomationPanePresentation.records(for: key, in: records)

        XCTAssertEqual(visible.count, AutomationPaneMetrics.maximumScheduleHistory)
        XCTAssertEqual(visible.map(\.id), records.prefix(12).map(\.id))
        XCTAssertEqual(visible.first?.scheduledFor, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(visible.last?.scheduledFor, Date(timeIntervalSince1970: 989))
    }

    func testHistoryEvidenceNamesTriggerLatenessAndDeliveryOutcome() {
        let dropped = AutomationRunRecord(
            id: UUID(),
            pluginID: "dev.example.automation",
            scheduleID: "daily",
            scheduledFor: Date(timeIntervalSince1970: 1_000),
            firedAt: Date(timeIntervalSince1970: 1_200),
            trigger: .manual,
            late: true,
            delivered: false
        )

        let evidence = AutomationPanePresentation.evidenceText(dropped)

        XCTAssertTrue(evidence.contains("manual"))
        XCTAssertTrue(evidence.contains("late"))
        XCTAssertTrue(evidence.contains("event not delivered"))
    }

    private func snapshot(
        id: PluginID,
        title: String,
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
            displayName: title,
            isLoaded: isLoaded,
            isEnabled: isEnabled,
            permissionViolations: [],
            error: nil,
            automationSchedules: schedules
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func automationSlotViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/TenonApp/AutomationSlotView.swift"),
            encoding: .utf8
        )
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
