// @domain: process-telemetry
import SwiftUI
import TenonCore

// MARK: - Trigger  @domain: process-telemetry

/// The title-bar control that opens the monitor.
///
/// It lives in the host's own chrome rather than `WorkspaceStatusBar`, which is a closed
/// plugin-contribution surface — putting a host control there would make the one strip Tenon
/// promises to plugins into a shared one.
struct ResourceMonitorButton: View {
    @Bindable var model: ResourceMonitorModel
    /// Below this the caption is dropped and the icon stands alone. A caption is the part
    /// that grows under translation or a larger text size, so removing it is what makes the
    /// narrow case fit rather than clip.
    let isCompact: Bool

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11, weight: .medium))
                if !isCompact, let summary {
                    Text(summary)
                        .font(TenonTheme.utilityFont(size: 10.5))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(accessibilityValue)
        .accessibilityLabel(Text("Open Resource Monitor", comment: "Resource monitor trigger"))
        .accessibilityValue(Text(accessibilityValue))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ResourceMonitorPopover(model: model)
                .task { await model.opened() }
                .onDisappear { Task { await model.closed() } }
        }
    }

    private var summary: String? {
        guard let snapshot = model.snapshot else { return nil }
        let memory = TelemetryFormat.bytes(snapshot.totalFootprintBytes)
        return "\(memory) · \(snapshot.paneCount)"
    }

    /// Freshness is part of the value, not decoration: a paused or stale reading that spoke
    /// only its numbers would be indistinguishable from a live one.
    private var accessibilityValue: String {
        guard let snapshot = model.snapshot else { return "Resource Monitor, no reading yet" }
        let cpu = TelemetryFormat.percent(snapshot.totalCPUPercent)
        let memory = TelemetryFormat.bytes(snapshot.totalFootprintBytes)
        return "CPU \(cpu), memory \(memory), \(snapshot.paneCount) panes, \(stateDescription(snapshot.state))"
    }
}

private func stateDescription(_ state: TelemetryState) -> String {
    switch state {
    case .loading: return "loading"
    case .ready: return "current"
    case let .partial(unreadable, truncated):
        if truncated { return "partial, list truncated at capacity" }
        return "partial, \(unreadable) processes unreadable"
    case .empty: return "no local terminal processes"
    case .paused: return "paused, not refreshing"
    case .stale: return "stale, showing the last good reading"
    case .failed: return "could not be read"
    }
}

// MARK: - Popover  @domain: process-telemetry

struct ResourceMonitorPopover: View {
    @Bindable var model: ResourceMonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider().overlay(TenonTheme.line)
            headers
            Divider().overlay(TenonTheme.line)
            content
            footer
        }
        // 480 pt is `designs.md`'s focused-panel low bound, not a number invented for this
        // feature. The July snapshot's 460 belonged to no band in the design system.
        .frame(width: 480, height: 520)
        .background(TenonTheme.chromeRaised)
        .tint(TenonTheme.amber)
    }

    @ViewBuilder
    private var summary: some View {
        let snapshot = model.snapshot
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            figure("CPU", snapshot.map { TelemetryFormat.percent($0.totalCPUPercent) } ?? TelemetryFormat.missing)
            figure("Memory", snapshot.map { TelemetryFormat.bytes($0.totalFootprintBytes) } ?? TelemetryFormat.missing)
            figure("Share", snapshot.map { TelemetryFormat.share($0.physicalMemoryShare) } ?? TelemetryFormat.missing)
            figure("Panes", snapshot.map { "\($0.paneCount)" } ?? TelemetryFormat.missing)
            Spacer()
            MemorySparkline(samples: model.history["app"] ?? [])
                .frame(width: 96)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        if let snapshot {
            stateBanner(snapshot)
        }
    }

    /// Two minutes of aggregate footprint, at the two-second cadence.
    ///
    /// Aggregates only — a ring per process would grow with a `make -j16` and would draw a
    /// sparkline for processes that live four seconds. It is decoration for a value already
    /// stated in words above it, so it is hidden from VoiceOver rather than read out as a
    /// meaningless list of numbers.
    private struct MemorySparkline: View {
        let samples: [UInt64]

        var body: some View {
            GeometryReader { proxy in
                let peak = samples.max() ?? 0
                Path { path in
                    guard samples.count > 1, peak > 0 else { return }
                    let step = proxy.size.width / CGFloat(samples.count - 1)
                    for (index, value) in samples.enumerated() {
                        let x = CGFloat(index) * step
                        let y = proxy.size.height * (1 - CGFloat(value) / CGFloat(peak))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(TenonTheme.amber.opacity(0.7), lineWidth: 1)
            }
            .frame(height: 22)
            .accessibilityHidden(true)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(TenonTheme.utilityFont(size: 8.5))
                .foregroundStyle(TenonTheme.muted)
            Text(value)
                .font(TenonTheme.utilityFont(size: 12))
                .monospacedDigit()
                .foregroundStyle(TenonTheme.text)
        }
    }

    /// Every state that is not plain `ready` says so in words. Meaning never rests on colour
    /// alone, so the same sentence is what VoiceOver reads.
    @ViewBuilder
    private func stateBanner(_ snapshot: TelemetrySnapshot) -> some View {
        if snapshot.state != .ready {
            HStack(spacing: 6) {
                Text(stateDescription(snapshot.state))
                    .font(TenonTheme.utilityFont(size: 10.5))
                    .foregroundStyle(TenonTheme.muted)
                if case .failed = snapshot.state {
                    Button("Retry") { Task { await model.retry() } }
                        .font(TenonTheme.utilityFont(size: 10.5))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var headers: some View {
        HStack(spacing: 0) {
            sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("CPU", .cpu).frame(width: 70, alignment: .trailing)
            sortHeader("Memory", .memory).frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func sortHeader(_ title: String, _ key: TelemetrySortKey) -> some View {
        Button { model.toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title.uppercased())
                    .font(TenonTheme.utilityFont(size: 8.5))
                if model.sortKey == key {
                    Image(systemName: model.sortDirection == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(model.sortKey == key ? TenonTheme.text : TenonTheme.muted)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.sortKey == key ? [.isSelected] : [])
        .accessibilityValue(
            model.sortKey == key
                ? Text(model.sortDirection == .ascending ? "ascending" : "descending")
                : Text("not sorted")
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows, id: \.node.id) { row in
                        ResourceMonitorRow(
                            node: row.node,
                            depth: row.depth,
                            isExpanded: model.expanded.contains(row.node.id),
                            isSelected: model.selection == row.node.id,
                            onToggle: { model.toggleExpansion(row.node.id) },
                            onSelect: { model.selection = row.node.id },
                            onActivate: {
                                model.selection = row.node.id
                                model.activateSelection()
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .focusable()
            .focusEffectDisabled()
            // The outline is walkable with no pointer at all. Every key here moves or opens
            // something; none of them can terminate, close, or change a process, because the
            // model exposes no such verb to bind to.
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            .onKeyPress(.leftArrow) { model.collapseOrAscend(); return .handled }
            .onKeyPress(.rightArrow) { model.expandOrDescend(); return .handled }
            .onKeyPress(.home) { model.moveSelectionToFirst(); return .handled }
            .onKeyPress(.end) { model.moveSelectionToLast(); return .handled }
            .onKeyPress(.space) { model.toggleSelectedExpansion(); return .handled }
            .onKeyPress(.return) { model.activateSelection(); return .handled }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if model.showsSkeleton {
                ProgressView().controlSize(.small)
            }
            Text(emptyMessage)
                .font(TenonTheme.utilityFont(size: 11))
                .foregroundStyle(TenonTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch model.snapshot?.state {
        case .none, .loading: return model.showsSkeleton ? "Reading processes…" : ""
        case .empty: return "No local terminal processes"
        case let .failed(reason): return reason
        default: return ""
        }
    }

    /// The absence macOS forces, stated once where a person can read it — rather than as a
    /// column of em dashes that would read as "no traffic".
    private var footer: some View {
        HStack {
            Text("Network use is not attributable per process on macOS.")
                .font(TenonTheme.utilityFont(size: 8.5))
                .foregroundStyle(TenonTheme.muted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(TenonTheme.chrome)
    }

    /// Flatten only what is open. A collapsed workspace costs one row, not one per process
    /// underneath it.
    private var visibleRows: [(node: TelemetryNode, depth: Int)] {
        var rows: [(TelemetryNode, Int)] = []
        func walk(_ nodes: [TelemetryNode], _ depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if model.expanded.contains(node.id) { walk(node.children, depth + 1) }
            }
        }
        walk(model.rows, 0)
        return rows
    }
}

// MARK: - Row  @domain: process-telemetry

struct ResourceMonitorRow: View {
    let node: TelemetryNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
                disclosure
                Text(node.name)
                    .font(TenonTheme.utilityFont(size: 11))
                    .foregroundStyle(TenonTheme.text)
                    .lineLimit(1)
                if let pid = node.pid {
                    Text("\(pid)")
                        .font(TenonTheme.utilityFont(size: 9))
                        .foregroundStyle(TenonTheme.muted)
                        .monospacedDigit()
                }
                if node.isForeground {
                    Image(systemName: "chevron.forward.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(TenonTheme.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TelemetryFormat.percent(node.cpuPercent))
                .font(TenonTheme.utilityFont(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(node.cpuPercent.isKnown ? TenonTheme.text : TenonTheme.muted)
                .frame(width: 70, alignment: .trailing)

            Text(TelemetryFormat.bytes(node.footprintBytes))
                .font(TenonTheme.utilityFont(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(node.footprintBytes.isKnown ? TenonTheme.text : TenonTheme.muted)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(isSelected ? TenonTheme.amber.opacity(0.14) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onActivate)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityValue(Text(spokenValue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(node.revealsPane == nil ? Text("") : Text("Return reveals the owning pane"))
    }

    @ViewBuilder
    private var disclosure: some View {
        if node.children.isEmpty {
            Color.clear.frame(width: 10, height: 10)
        } else {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(TenonTheme.muted)
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }

    private var spokenLabel: String {
        node.pid.map { "\(node.name), process \($0)" } ?? node.name
    }

    /// Speaks the reason a value is missing rather than the em dash, because "dash" tells a
    /// screen-reader user nothing about whether the number is zero or unknown.
    private var spokenValue: String {
        let cpu = node.cpuPercent.isKnown
            ? "CPU \(TelemetryFormat.percent(node.cpuPercent))"
            : "CPU unavailable"
        let memory = node.footprintBytes.isKnown
            ? "memory \(TelemetryFormat.bytes(node.footprintBytes))"
            : "memory unavailable"
        let level = "level \(depth + 1)"
        let expansion = node.children.isEmpty ? "" : (isExpanded ? ", expanded" : ", collapsed")
        return "\(cpu), \(memory), \(level)\(expansion)"
    }
}
