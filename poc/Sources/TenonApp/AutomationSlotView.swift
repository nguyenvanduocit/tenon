// @domain: automation
import SwiftUI
import TenonCore
import TenonIntentCore

/// Same-owner use cases exposed by the composition root to the host-native pane.
/// They stay typed and deliberately do not expose an intent runtime to built-in UI.
struct AutomationPaneActions {
    let runNow: (PluginID, String) async -> Void
    let setPaused: (PluginID, String, Bool) -> Void
    let createWithAI: () -> Void
}

/// Compact geometry budget for the operations surface. Important dimensions stay pure
/// so density regressions fail headlessly before pixel review.
enum AutomationPaneMetrics {
    static let contentInset: CGFloat = 12
    static let sectionSpacing: CGFloat = 14
    static let headerHeight: CGFloat = 44
    static let summaryHeight: CGFloat = 48
    static let navigatorWidth: CGFloat = 280
    static let navigatorCompactHeight: CGFloat = 236
    static let scheduleRowHeight: CGFloat = 54
    static let activityRowHeight: CGFloat = 44
    static let controlHeight: CGFloat = 28
    static let maximumScheduleHistory = 12
}

enum AutomationPaneFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case paused

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .attention: "Attention"
        case .paused: "Paused"
        }
    }
}

enum AutomationScheduleAvailability: Equatable {
    case ready
    case pluginUnavailable(String?)

    var isReady: Bool { self == .ready }
}

enum AutomationScheduleState: Equatable {
    case scheduled
    case paused
    case globallyPaused
    case attention
    case unavailable

    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .paused: "Paused"
        case .globallyPaused: "Globally paused"
        case .attention: "Needs attention"
        case .unavailable: "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .scheduled: "clock.arrow.circlepath"
        case .paused, .globallyPaused: "pause.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .unavailable: "bolt.slash.fill"
        }
    }

    var isEmphasized: Bool {
        self != .scheduled
    }
}

struct AutomationScheduleSummary: Identifiable, Equatable {
    let id: AutomationScheduleKey
    let pluginTitle: String
    let spec: AutomationScheduleSpec
    let nextDue: Date?
    let availability: AutomationScheduleAvailability
    let isPaused: Bool
    let latestRun: AutomationRunRecord?
    let runCount: Int
    let deliveredCount: Int

    var pluginID: PluginID { id.pluginID }
    var scheduleID: String { id.scheduleID }

    var needsAttention: Bool {
        !availability.isReady || latestRun?.delivered == false
    }

    func state(globalDeliveryEnabled: Bool) -> AutomationScheduleState {
        guard availability.isReady else { return .unavailable }
        if latestRun?.delivered == false { return .attention }
        guard globalDeliveryEnabled else { return .globallyPaused }
        return isPaused ? .paused : .scheduled
    }
}

/// Pure product projections shared by SwiftUI and regression tests. The host can prove
/// event delivery, not business success, so every metric and label uses that exact fact.
enum AutomationPanePresentation {
    static func scheduleKey(
        pluginID: PluginID,
        scheduleID: String
    ) -> AutomationScheduleKey {
        AutomationScheduleKey(pluginID: pluginID, scheduleID: scheduleID)
    }

    static func scheduleRowID(pluginID: PluginID, scheduleID: String) -> String {
        pluginID.rawValue + "/" + scheduleID
    }

    static func scheduleTitle(_ scheduleID: String) -> String {
        let words = scheduleID
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { word in
                let text = String(word)
                return text.prefix(1).uppercased() + text.dropFirst()
            }
        return words.isEmpty ? scheduleID : words.joined(separator: " ")
    }

    static func cadenceText(_ spec: AutomationScheduleSpec) -> String {
        switch spec.cadence {
        case .every(let interval):
            return "Every \(durationText(interval))"
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        }
    }

    static func graceText(_ spec: AutomationScheduleSpec) -> String {
        durationText(spec.grace)
    }

    static func evidenceText(_ record: AutomationRunRecord) -> String {
        var parts = [
            record.trigger == .manual ? "manual" : "scheduled",
            "for " + record.scheduledFor.formatted(
                date: .abbreviated,
                time: .shortened
            ),
        ]
        if record.late { parts.append("late") }
        parts.append(record.delivered ? "event delivered" : "event not delivered")
        return parts.joined(separator: " · ")
    }

    static func summaries(
        plugins: [PluginSnapshot],
        listings: [AutomationScheduler.ScheduleListing],
        pausedScheduleKeys: Set<AutomationScheduleKey>,
        records: [AutomationRunRecord]
    ) -> [AutomationScheduleSummary] {
        let listingByKey = Dictionary(
            uniqueKeysWithValues: listings.map { listing in
                (
                    scheduleKey(
                        pluginID: listing.pluginID,
                        scheduleID: listing.spec.id
                    ),
                    listing
                )
            }
        )

        // A disabled plugin is not part of the product right now, so neither is anything
        // it declares: its schedules leave the pane entirely rather than lingering as
        // rows nobody can act on. Enabling it in Settings brings them back intact,
        // including their pause preference.
        return plugins
            .filter(\.isEnabled)
            .flatMap { plugin -> [AutomationScheduleSummary] in
                let availability: AutomationScheduleAvailability =
                    plugin.isLoaded && plugin.error == nil
                        ? .ready
                        : .pluginUnavailable(plugin.error)

                return plugin.automationSchedules.map { spec in
                    let key = scheduleKey(pluginID: plugin.id, scheduleID: spec.id)
                    let scheduleRecords = records.filter {
                        $0.pluginID == plugin.id && $0.scheduleID == spec.id
                    }
                    return AutomationScheduleSummary(
                        id: key,
                        pluginTitle: plugin.settingsTitle,
                        spec: spec,
                        nextDue: listingByKey[key]?.nextDue,
                        availability: availability,
                        isPaused: pausedScheduleKeys.contains(key),
                        latestRun: scheduleRecords.first,
                        runCount: scheduleRecords.count,
                        deliveredCount: scheduleRecords.filter(\.delivered).count
                    )
                }
            }
            .sorted {
                let titleOrder = $0.pluginTitle.localizedCaseInsensitiveCompare(
                    $1.pluginTitle
                )
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return $0.scheduleID < $1.scheduleID
            }
    }

    static func filteredSummaries(
        _ summaries: [AutomationScheduleSummary],
        query: String,
        filter: AutomationPaneFilter,
        globalDeliveryEnabled: Bool
    ) -> [AutomationScheduleSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return summaries.filter { summary in
            let matchesQuery = needle.isEmpty
                || summary.pluginTitle.lowercased().contains(needle)
                || summary.pluginID.rawValue.lowercased().contains(needle)
                || summary.scheduleID.lowercased().contains(needle)
                || scheduleTitle(summary.scheduleID).lowercased().contains(needle)
            guard matchesQuery else { return false }
            switch filter {
            case .all:
                return true
            case .attention:
                return summary.needsAttention
            case .paused:
                return summary.isPaused || !globalDeliveryEnabled
            }
        }
    }

    static func activeCount(
        _ summaries: [AutomationScheduleSummary],
        globalDeliveryEnabled: Bool
    ) -> Int {
        guard globalDeliveryEnabled else { return 0 }
        return summaries.count { $0.availability.isReady && !$0.isPaused }
    }

    static func attentionCount(_ summaries: [AutomationScheduleSummary]) -> Int {
        summaries.count(where: \.needsAttention)
    }

    static func nextDue(
        _ summaries: [AutomationScheduleSummary],
        globalDeliveryEnabled: Bool
    ) -> Date? {
        guard globalDeliveryEnabled else { return nil }
        return summaries
            .filter { $0.availability.isReady && !$0.isPaused }
            .compactMap(\.nextDue)
            .min()
    }

    static func records(
        for key: AutomationScheduleKey,
        in records: [AutomationRunRecord]
    ) -> [AutomationRunRecord] {
        Array(
            records.lazy.filter {
                $0.pluginID == key.pluginID && $0.scheduleID == key.scheduleID
            }.prefix(AutomationPaneMetrics.maximumScheduleHistory)
        )
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

/// The compact state Automation contributes to the one host-owned pane header.
enum AutomationPaneHeader {
    static func header(
        scheduleCount: Int,
        schedulesEnabled: Bool,
        attentionCount: Int = 0
    ) -> PaneHeader {
        var leading: [PaneHeaderItem] = [
            .image(
                id: "automation",
                systemName: "clock.arrow.circlepath",
                tint: .muted,
                tooltip: nil
            ),
        ]
        if scheduleCount > 0 {
            leading.append(
                .badge(
                    id: "schedule-count",
                    text: "\(scheduleCount)",
                    tint: .muted,
                    tooltip: scheduleCount == 1 ? "1 schedule" : "\(scheduleCount) schedules"
                )
            )
        }
        let status: PaneHeaderItem = attentionCount > 0
            ? .badge(
                id: "schedule-attention",
                text: "\(attentionCount) ATTENTION",
                tint: .amber,
                tooltip: "Automation schedules need attention"
            )
            : .badge(
                id: "schedule-state",
                text: schedulesEnabled ? "SCHEDULED" : "PAUSED",
                tint: schedulesEnabled ? .muted : .amber,
                tooltip: schedulesEnabled
                    ? "Scheduled automation delivery is enabled"
                    : "Scheduled automation delivery is paused"
            )
        return PaneHeader(leading: leading, trailing: [status])
    }
}

/// A schedule-first operations center: what runs next, what needs judgment, and the
/// exact host evidence behind each delivery. Settings remains configuration-only.
struct AutomationSlotView: View {
    let slotID: UUID
    var host: PluginHost
    var automation: AutomationScheduler
    let schedulesEnabled: Bool
    let actions: AutomationPaneActions
    var headerStore: PaneHeaderStore

    @State private var query = ""
    @State private var filter: AutomationPaneFilter = .all
    @State private var selectedSchedule: AutomationScheduleKey?
    @State private var runningScheduleKeys: Set<AutomationScheduleKey> = []

    var body: some View {
        // Run history is a bounded recent-evidence buffer. The summary says "recent"
        // rather than implying that evicted records still contribute to its ratio; the
        // detail list applies its own tighter per-schedule display bound below.
        let records = automation.runHistory.records
        let summaries = AutomationPanePresentation.summaries(
            plugins: host.plugins,
            listings: automation.listings(),
            pausedScheduleKeys: automation.pausedScheduleKeys,
            records: records
        )
        let visible = AutomationPanePresentation.filteredSummaries(
            summaries,
            query: query,
            filter: filter,
            globalDeliveryEnabled: schedulesEnabled
        )
        let selected = selectedSchedule.flatMap { key in
            summaries.first(where: { $0.id == key })
        }

        VStack(spacing: 0) {
            AutomationDashboardHeader(
                scheduleCount: summaries.count,
                schedulesEnabled: schedulesEnabled,
                query: $query,
                filter: $filter,
                create: actions.createWithAI
            )
            AutomationDivider()
            AutomationSummaryStrip(
                summaries: summaries,
                records: records,
                schedulesEnabled: schedulesEnabled
            )
            AutomationDivider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    navigator(summaries: visible)
                        .frame(
                            minWidth: 236,
                            idealWidth: AutomationPaneMetrics.navigatorWidth,
                            maxWidth: 320
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    AutomationVerticalDivider()
                    detail(
                        summary: selected,
                        records: records,
                        hasSchedules: !summaries.isEmpty
                    )
                    .frame(minWidth: 360)
                }
                VStack(spacing: 0) {
                    navigator(summaries: visible)
                        .frame(
                            height: AutomationPaneMetrics.navigatorCompactHeight,
                            alignment: .top
                        )
                    AutomationDivider()
                    detail(
                        summary: selected,
                        records: records,
                        hasSchedules: !summaries.isEmpty
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TenonTheme.panel)
        .foregroundStyle(TenonTheme.text)
        .tint(TenonTheme.amber)
        .accessibilityIdentifier("tenon.automation")
        .onChange(of: visible.map(\.id), initial: true) { _, keys in
            guard !keys.isEmpty else {
                selectedSchedule = nil
                return
            }
            if let selectedSchedule, keys.contains(selectedSchedule) { return }
            selectedSchedule = keys.first
        }
        .onChange(of: paneHeader(summaries), initial: true) { _, next in
            headerStore.publish(next, for: slotID)
        }
        .onDisappear { headerStore.clear(for: slotID) }
    }

    private func paneHeader(
        _ summaries: [AutomationScheduleSummary]
    ) -> PaneHeader {
        AutomationPaneHeader.header(
            scheduleCount: summaries.count,
            schedulesEnabled: schedulesEnabled,
            attentionCount: AutomationPanePresentation.attentionCount(summaries)
        )
    }

    private func navigator(
        summaries: [AutomationScheduleSummary]
    ) -> some View {
        AutomationScheduleNavigator(
            summaries: summaries,
            query: query,
            selection: selectedSchedule,
            schedulesEnabled: schedulesEnabled,
            select: { selectedSchedule = $0 }
        )
    }

    @ViewBuilder
    private func detail(
        summary: AutomationScheduleSummary?,
        records: [AutomationRunRecord],
        hasSchedules: Bool
    ) -> some View {
        if let summary {
            AutomationScheduleDetail(
                summary: summary,
                records: AutomationPanePresentation.records(for: summary.id, in: records),
                schedulesEnabled: schedulesEnabled,
                isRunning: runningScheduleKeys.contains(summary.id),
                runNow: { run(summary) },
                setPaused: {
                    actions.setPaused(
                        summary.pluginID,
                        summary.scheduleID,
                        !summary.isPaused
                    )
                }
            )
        } else {
            AutomationEmptyDetail(
                hasSchedules: hasSchedules,
                create: actions.createWithAI
            )
        }
    }

    private func run(_ summary: AutomationScheduleSummary) {
        guard summary.availability.isReady,
              runningScheduleKeys.insert(summary.id).inserted
        else { return }
        Task { @MainActor in
            await actions.runNow(summary.pluginID, summary.scheduleID)
            runningScheduleKeys.remove(summary.id)
        }
    }
}

private struct AutomationDashboardHeader: View {
    let scheduleCount: Int
    let schedulesEnabled: Bool
    @Binding var query: String
    @Binding var filter: AutomationPaneFilter
    let create: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            compactHeader
        }
        .background(TenonTheme.chrome)
    }

    private var wideHeader: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 8)
            AutomationScheduleToolbar(
                query: $query,
                filter: $filter,
                allowsStackedLayout: false
            )
            if !schedulesEnabled {
                AutomationStatusBadge(label: "GLOBAL PAUSE", emphasized: true)
            }
            createButton
        }
        .padding(.horizontal, AutomationPaneMetrics.contentInset)
        .frame(height: AutomationPaneMetrics.headerHeight)
    }

    private var compactHeader: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    if !schedulesEnabled {
                        AutomationStatusBadge(label: "GLOBAL PAUSE", emphasized: true)
                    }
                    createButton
                }
                .padding(.horizontal, AutomationPaneMetrics.contentInset)
                .frame(height: AutomationPaneMetrics.headerHeight)
                narrowHeader
            }
            AutomationDivider()
            AutomationScheduleToolbar(
                query: $query,
                filter: $filter,
                allowsStackedLayout: true
            )
                .padding(.horizontal, AutomationPaneMetrics.contentInset)
        }
    }

    private var title: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TenonTheme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automations")
                    .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
                Text(
                    scheduleCount == 1
                        ? "1 declared schedule"
                        : "\(scheduleCount) declared schedules"
                )
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var createButton: some View {
        Button(action: create) {
            Label("New Automation", systemImage: "plus")
        }
        .controlSize(.small)
        .frame(height: AutomationPaneMetrics.controlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("New Automation")
        .accessibilityIdentifier("tenon.automation.create")
        .help("Create an automation with an agent in a new terminal")
    }

    private var narrowHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TenonTheme.amber)
                    .accessibilityHidden(true)
                Text("Automations")
                    .font(TenonTheme.interfaceFont(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            if !schedulesEnabled {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TenonTheme.amber)
                    .accessibilityLabel("Scheduled automation delivery is globally paused")
                    .help("Scheduled automation delivery is globally paused")
            }
            Button(action: create) {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: AutomationPaneMetrics.controlHeight)
            .accessibilityLabel("New Automation")
            .accessibilityIdentifier("tenon.automation.create.compact")
            .help("Create an automation with an agent in a new terminal")
        }
        .padding(.horizontal, AutomationPaneMetrics.contentInset)
        .frame(height: AutomationPaneMetrics.headerHeight)
    }
}

private struct AutomationScheduleToolbar: View {
    @Binding var query: String
    @Binding var filter: AutomationPaneFilter
    let allowsStackedLayout: Bool

    @ViewBuilder
    var body: some View {
        if allowsStackedLayout {
            ViewThatFits(in: .horizontal) {
                singleRow
                stackedRows
            }
        } else {
            singleRow
        }
    }

    private var singleRow: some View {
        HStack(spacing: 8) {
            searchField
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 220)
            Picker("Schedule filter", selection: $filter) {
                ForEach(AutomationPaneFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 190)
        }
    }

    private var stackedRows: some View {
        VStack(spacing: 6) {
            searchField
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text("FILTER")
                    .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted)
                    .accessibilityHidden(true)
                Picker("Schedule filter", selection: $filter) {
                    ForEach(AutomationPaneFilter.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: AutomationPaneMetrics.controlHeight)
        }
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            TextField("Find a schedule…", text: $query)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 11.5))
                .accessibilityLabel("Search automation schedules")
                .accessibilityIdentifier("tenon.automation.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TenonTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear schedule search")
                .help("Clear schedule search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AutomationPaneMetrics.controlHeight)
        .background(TenonTheme.panel)
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(TenonTheme.line, lineWidth: 1)
        }
    }
}

private struct AutomationSummaryStrip: View {
    let summaries: [AutomationScheduleSummary]
    let records: [AutomationRunRecord]
    let schedulesEnabled: Bool

    var body: some View {
        let active = AutomationPanePresentation.activeCount(
            summaries,
            globalDeliveryEnabled: schedulesEnabled
        )
        let attention = AutomationPanePresentation.attentionCount(summaries)
        let delivered = records.filter(\.delivered).count

        HStack(spacing: 0) {
            AutomationSummaryMetric(
                label: "ACTIVE",
                value: "\(active)",
                emphasized: false
            )
            AutomationVerticalDivider()
            AutomationSummaryMetric(
                label: "NEXT",
                value: nextValue,
                emphasized: false
            )
            AutomationVerticalDivider()
            AutomationSummaryMetric(
                label: "ATTENTION",
                value: "\(attention)",
                emphasized: attention > 0
            )
            AutomationVerticalDivider()
            AutomationSummaryMetric(
                label: "RECENT EVENTS",
                value: records.isEmpty ? "—" : "\(delivered)/\(records.count) delivered",
                emphasized: delivered < records.count
            )
        }
        .frame(height: AutomationPaneMetrics.summaryHeight)
        .background(TenonTheme.chromeRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automation summary")
    }

    private var nextValue: String {
        if let next = AutomationPanePresentation.nextDue(
            summaries,
            globalDeliveryEnabled: schedulesEnabled
        ) {
            return next.formatted(date: .omitted, time: .shortened)
        }
        return "—"
    }
}

private struct AutomationSummaryMetric: View {
    let label: String
    let value: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
            Text(value)
                .font(TenonTheme.utilityFont(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? TenonTheme.amber : TenonTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationScheduleNavigator: View {
    let summaries: [AutomationScheduleSummary]
    let query: String
    let selection: AutomationScheduleKey?
    let schedulesEnabled: Bool
    let select: (AutomationScheduleKey) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if summaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(query.isEmpty ? "No schedules in this view" : "No matching schedules")
                        .font(TenonTheme.interfaceFont(size: 11.5, weight: .semibold))
                    Text("Change the filter or create a new automation.")
                        .font(TenonTheme.interfaceFont(size: 10.5))
                        .foregroundStyle(TenonTheme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(summaries) { summary in
                            AutomationScheduleNavigatorRow(
                                summary: summary,
                                state: summary.state(
                                    globalDeliveryEnabled: schedulesEnabled
                                ),
                                selected: summary.id == selection,
                                select: { select(summary.id) }
                            )
                            AutomationDivider()
                        }
                    }
                }
                .tenonScrollbarStyle()
            }
        }
        .background(TenonTheme.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automation schedules")
    }
}

private struct AutomationScheduleNavigatorRow: View {
    let summary: AutomationScheduleSummary
    let state: AutomationScheduleState
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(state.isEmphasized ? TenonTheme.amber : TenonTheme.muted)
                    .frame(width: 2, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AutomationPanePresentation.scheduleTitle(summary.scheduleID))
                        .font(TenonTheme.interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(TenonTheme.text)
                        .lineLimit(1)
                    Text("\(summary.pluginTitle) · \(AutomationPanePresentation.cadenceText(summary.spec))")
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let nextDue = summary.nextDue,
                   state == .scheduled {
                    Text(nextDue, style: .relative)
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .lineLimit(1)
                } else {
                    Image(systemName: state.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            state.isEmphasized ? TenonTheme.amber : TenonTheme.muted
                        )
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: AutomationPaneMetrics.scheduleRowHeight)
            .contentShape(Rectangle())
            .background(
                selected ? TenonTheme.amber.opacity(0.10) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(AutomationPanePresentation.scheduleTitle(summary.scheduleID)), \(summary.pluginTitle)"
        )
        .accessibilityValue(state.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(
            "tenon.automation.schedule.\(summary.pluginID.rawValue).\(summary.scheduleID)"
        )
    }
}

private struct AutomationScheduleDetail: View {
    let summary: AutomationScheduleSummary
    let records: [AutomationRunRecord]
    let schedulesEnabled: Bool
    let isRunning: Bool
    let runNow: () -> Void
    let setPaused: () -> Void

    private var state: AutomationScheduleState {
        summary.state(globalDeliveryEnabled: schedulesEnabled)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AutomationPaneMetrics.sectionSpacing) {
                detailHeader
                if state != .scheduled {
                    AutomationScheduleNotice(summary: summary, state: state)
                }
                AutomationDefinitionSection(summary: summary)
                AutomationActivitySection(
                    records: records,
                    canRetry: summary.availability.isReady && !isRunning,
                    retry: runNow
                )
            }
            .padding(AutomationPaneMetrics.contentInset)
        }
        .tenonScrollbarStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TenonTheme.panel)
        .accessibilityIdentifier("tenon.automation.detail")
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(AutomationPanePresentation.scheduleTitle(summary.scheduleID))
                        .font(TenonTheme.interfaceFont(size: 14, weight: .semibold))
                        .lineLimit(1)
                    AutomationStatusBadge(
                        label: state.label.uppercased(),
                        emphasized: state.isEmphasized
                    )
                }
                Text(summary.pluginTitle)
                    .font(TenonTheme.utilityFont(size: 10))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(summary.isPaused ? "Resume" : "Pause", action: setPaused)
                .controlSize(.small)
                .frame(height: AutomationPaneMetrics.controlHeight)
                .accessibilityLabel(
                    summary.isPaused ? "Resume this automation" : "Pause this automation"
                )
                .accessibilityIdentifier("tenon.automation.pause")
            Button(isRunning ? "Running…" : "Run Now", action: runNow)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(height: AutomationPaneMetrics.controlHeight)
                .disabled(isRunning || !summary.availability.isReady)
                .accessibilityLabel(isRunning ? "Running automation" : "Run automation now")
                .accessibilityIdentifier("tenon.automation.run")
                .help("Deliver a manual automation event without changing the schedule")
        }
    }
}

private struct AutomationScheduleNotice: View {
    let summary: AutomationScheduleSummary
    let state: AutomationScheduleState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.symbol)
                .foregroundStyle(TenonTheme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label)
                    .font(TenonTheme.interfaceFont(size: 11.5, weight: .semibold))
                Text(message)
                    .font(TenonTheme.interfaceFont(size: 10.5))
                    .foregroundStyle(TenonTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TenonTheme.chromeRaised, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(TenonTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch state {
        case .scheduled:
            return ""
        case .paused:
            return "Scheduled events are skipped and the clock keeps advancing. Run Now remains available."
        case .globallyPaused:
            return "Scheduled delivery is disabled in Settings. Run Now remains available."
        case .attention:
            return "The most recent event was not accepted by a live plugin generation. Inspect the plugin, then retry."
        case .unavailable:
            switch summary.availability {
            case .pluginUnavailable(let diagnostic):
                return diagnostic.map { "The plugin is unavailable: \($0)" }
                    ?? "The declaring plugin is not currently loaded."
            case .ready:
                return "The schedule is not currently available."
            }
        }
    }
}

private struct AutomationDefinitionSection: View {
    let summary: AutomationScheduleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AutomationSectionLabel("Schedule")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                definitionRow("CADENCE", AutomationPanePresentation.cadenceText(summary.spec))
                definitionRow("NEXT EVENT", nextDueText)
                definitionRow("GRACE", AutomationPanePresentation.graceText(summary.spec))
                definitionRow("PLUGIN", summary.pluginID.rawValue)
                definitionRow("SCHEDULE ID", summary.scheduleID)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.chrome)
        }
    }

    private var nextDueText: String {
        summary.nextDue?.formatted(date: .abbreviated, time: .standard) ?? "Not armed"
    }

    private func definitionRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
                .foregroundStyle(TenonTheme.muted)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(TenonTheme.utilityFont(size: 10.5))
                .foregroundStyle(TenonTheme.text)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private struct AutomationActivitySection: View {
    let records: [AutomationRunRecord]
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                AutomationSectionLabel("Activity")
                Text("RECENT")
                    .font(TenonTheme.utilityFont(size: 8.5))
                    .foregroundStyle(TenonTheme.muted)
                Spacer()
                if !records.isEmpty {
                    Text("\(records.count) events")
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                }
            }
            if records.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No delivery evidence yet")
                        .font(TenonTheme.interfaceFont(size: 11.5, weight: .semibold))
                    Text("Use Run Now to verify that the live plugin accepts this schedule's event.")
                        .font(TenonTheme.interfaceFont(size: 10.5))
                        .foregroundStyle(TenonTheme.muted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TenonTheme.chrome)
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        AutomationActivityRow(
                            record: record,
                            canRetry: canRetry,
                            retry: retry
                        )
                        AutomationDivider()
                    }
                }
                .background(TenonTheme.chrome)
            }
        }
    }
}

private struct AutomationActivityRow: View {
    let record: AutomationRunRecord
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: record.delivered
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .foregroundStyle(record.delivered ? TenonTheme.muted : TenonTheme.amber)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.delivered ? "Event delivered" : "Event not delivered")
                    .font(TenonTheme.interfaceFont(size: 11, weight: .semibold))
                Text(AutomationPanePresentation.evidenceText(record))
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(record.firedAt.formatted(.relative(presentation: .named)))
                .font(TenonTheme.utilityFont(size: 9))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
            if !record.delivered {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!canRetry)
                .help("Retry with a manual event")
                .accessibilityLabel("Retry automation")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: AutomationPaneMetrics.activityRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.delivered ? "Event delivered" : "Event not delivered")
        .accessibilityValue(AutomationPanePresentation.evidenceText(record))
    }
}

private struct AutomationEmptyDetail: View {
    let hasSchedules: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: hasSchedules ? "line.3.horizontal.decrease.circle" : "clock.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            Text(hasSchedules ? "No schedule selected" : "No automations yet")
                .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
            Text(
                hasSchedules
                    ? "Choose a schedule or change the current filter."
                    : "Create a plugin automation to schedule work and inspect its delivery evidence here."
            )
            .font(TenonTheme.interfaceFont(size: 11))
            .foregroundStyle(TenonTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            if !hasSchedules {
                Button("New Automation…", action: create)
                    .controlSize(.small)
                    .accessibilityLabel("New Automation")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TenonTheme.panel)
        .accessibilityElement(children: .contain)
    }
}

private struct AutomationStatusBadge: View {
    let label: String
    let emphasized: Bool

    var body: some View {
        Text(label)
            .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
            .foregroundStyle(emphasized ? TenonTheme.amber : TenonTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                (emphasized ? TenonTheme.amber : TenonTheme.muted).opacity(0.10),
                in: .rect(cornerRadius: 5)
            )
    }
}

private struct AutomationSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TenonTheme.muted)
    }
}

private struct AutomationDivider: View {
    var body: some View {
        Rectangle()
            .fill(TenonTheme.line)
            .frame(height: 1)
    }
}

private struct AutomationVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(TenonTheme.line)
            .frame(width: 1)
    }
}
