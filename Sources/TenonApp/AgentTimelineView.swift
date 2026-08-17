// @domain: agent-lens
import SwiftUI
import TenonCore

/// The Timeline account: a synthesized reading of the same session Chat shows verbatim.
///
/// Every state it can be in is drawn here, including the ones with nothing to show. An empty,
/// short or unreadable session says so in its own words; it never renders a plausible-looking
/// timeline over evidence that does not support one.
struct AgentSessionTimelineView: View {
    @Bindable var model: AgentLensViewModel
    /// Follows one anchor back to the fact it names.
    let returnToEvidence: (String) -> Void
    /// Opens every milestone's evidence on first draw. The offscreen snapshot writer passes it
    /// so the anchor rows can be looked at, the way `DiffSlotView(startSplit:)` already works.
    var startsExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch model.timelineGeneration {
                case .idle:
                    // Asked here, on every snapshot change, rather than remembered from the
                    // first draw: a session is short only until it is not, and a pane that
                    // scored itself once went on showing "nothing to summarize" over a
                    // 354-record transcript (T-102).
                    if let insufficiency = AgentTimelineDigest.insufficiency(of: model.snapshot) {
                        AgentTimelineNotice(
                            icon: "text.magnifyingglass",
                            title: "Nothing to summarize yet",
                            detail: insufficiency.message
                        )
                    } else {
                        invitation
                    }
                case let .running(fingerprint, progress):
                    running(fingerprint: fingerprint, progress: progress)
                case .ready(let timeline):
                    reading(timeline)
                case .failed(let failure):
                    failed(failure)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .tenonScrollbarStyle()
        .background(TenonTheme.ink)
        .accessibilityIdentifier("tenon.agentLens.timeline")
        // The pane already asked when it opened, and the answer is kept, so this is a no-op on
        // every visit but the first. It stays for the composition that mounts this view without
        // a started pane — the offscreen snapshot writer — and because a machine that had no
        // reader when the pane opened may have one now.
        .task { await model.loadAvailableReaders() }
    }

    // MARK: - States  @domain: agent-lens

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read this session")
                .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(TenonTheme.text)
            Text(
                """
                An agent reads the transcript and the lifecycle facts behind Chat and answers in \
                a few moments, each one anchored back to the rows it came from.
                """
            )
            .font(TenonTheme.interfaceFont(size: 11.5))
            .foregroundStyle(TenonTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            readingControls
            Text(model.readingOptions.lens.hint)
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Read this session") { model.generateTimeline() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Runs an agent over this session's evidence and writes its milestones")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TenonTheme.chrome, in: .rect(cornerRadius: 8))
    }

    // MARK: - What the next reading is asked for  @domain: agent-lens

    /// The four choices, folded to whatever the pane is wide enough for.
    ///
    /// They sit on the invitation rather than in the pane header because they belong to the
    /// reading that has not been asked for yet: a run in flight keeps the options it started
    /// with, and a header control would suggest it could be steered mid-flight.
    private var readingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                readerPicker
                modelPicker
                spanPicker
                lensPicker
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    readerPicker
                    modelPicker
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    spanPicker
                    lensPicker
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                readerPicker
                modelPicker
                spanPicker
                lensPicker
            }
        }
        .disabled(model.timelineGeneration.isRunning)
    }

    /// Only the CLIs this machine has, and only when there is more than one of them: a menu with
    /// a single item is a control that cannot be used for anything.
    @ViewBuilder
    private var readerPicker: some View {
        if model.availableReaders.count > 1 {
            Picker("Reader", selection: readerBinding) {
                ForEach(model.availableReaders, id: \.self) { reader in
                    Text(reader.label).tag(reader)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let choices = AgentReadingModel.choices(for: model.readingOptions.provider)
        if choices.count > 1 {
            Picker("Model", selection: modelBinding) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var spanPicker: some View {
        Picker("How much of the session", selection: $model.readingOptions.span) {
            ForEach(AgentReadingSpan.allCases) { span in
                Text(span.title).tag(span)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private var lensPicker: some View {
        Picker("What the reading looks for", selection: $model.readingOptions.lens) {
            ForEach(AgentReadingLens.allCases) { lens in
                Text(lens.title).tag(lens)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    /// Provider and model are written through the options' own guard rather than assigned, so the
    /// pane cannot leave a CLI holding another CLI's alias.
    private var readerBinding: Binding<AgentCLI> {
        Binding(
            get: { model.readingOptions.provider },
            set: { model.readingOptions.select(provider: $0) }
        )
    }

    private var modelBinding: Binding<AgentReadingModel> {
        Binding(
            get: { model.readingOptions.model },
            set: { model.readingOptions.select(model: $0) }
        )
    }

    /// A run in flight, described by what it has actually done.
    ///
    /// The line that moves is the point: a spinner and an elapsed clock both keep going for a
    /// process that died, so neither answers the only question being asked here. What the run
    /// has said about itself does.
    private func running(
        fingerprint: String,
        progress: AgentTimelineProgress
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.message)
                    .font(TenonTheme.interfaceFont(size: 12))
                    .foregroundStyle(TenonTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelTimelineGeneration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Chat stays live while this runs. Evidence read: \(fingerprint.prefix(12)).")
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(TenonTheme.chrome, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.message)
    }

    private func failed(_ failure: AgentTimelineFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentTimelineNotice(
                icon: "exclamationmark.triangle",
                title: "No reading was produced",
                detail: failure.message,
                tint: TenonTheme.amber
            )
            if failure.isRetryable {
                // The controls come back with the retry rather than only on the invitation: the
                // most useful thing to change after a reading failed is the reading — a CLI that
                // is not installed, a model that was busy, a span that was too much to chew.
                readingControls
                Button("Try again") { model.generateTimeline() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func reading(_ timeline: AgentSessionTimeline) -> some View {
        summary(timeline)
        if model.timelineIsStale {
            AgentTimelineNotice(
                icon: "clock.arrow.circlepath",
                title: "The session has moved on",
                detail: "This reading covers \(timeline.factCount) facts. Newer work is in Chat until you read again.",
                tint: TenonTheme.amber
            )
        }
        ForEach(timeline.milestones) { milestone in
            AgentMilestoneRow(
                milestone: milestone,
                returnToEvidence: returnToEvidence,
                showsEvidence: startsExpanded
            )
        }
    }

    private func summary(_ timeline: AgentSessionTimeline) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                summaryText(timeline)
                Spacer(minLength: 8)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 6) {
                summaryText(timeline)
                refreshButton
            }
        }
        .padding(.bottom, 2)
    }

    private func summaryText(_ timeline: AgentSessionTimeline) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "\(timeline.milestones.count) \(timeline.milestones.count == 1 ? "milestone" : "milestones") from \(timeline.factCount) facts"
            )
            .font(TenonTheme.utilityFont(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(TenonTheme.muted)
            .accessibilityLabel(
                "\(timeline.milestones.count) milestones synthesized from \(timeline.factCount) session facts"
            )
            // What this reading was asked for, not what the pickers say now: the two differ the
            // moment someone starts choosing the next one, and only the first explains what is
            // on screen.
            if let taken = model.readingOptionsInUse {
                Text("Read by \(taken.summary)")
                    .font(TenonTheme.utilityFont(size: 9.5))
                    .foregroundStyle(TenonTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("This reading was taken with \(taken.summary)")
            }
        }
    }

    private var refreshButton: some View {
        Button("Read again") { model.generateTimeline() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("Replaces this reading with one that covers the newest evidence")
    }
}

// MARK: - One milestone  @domain: agent-lens

/// A milestone, with its evidence one keystroke away.
///
/// The anchors are collapsed by default and expand into buttons rather than into text: the whole
/// claim of this surface is that a person can check it, and a citation you cannot click is a
/// summary asking to be trusted.
private struct AgentMilestoneRow: View {
    let milestone: AgentMilestone
    let returnToEvidence: (String) -> Void

    @State private var showsEvidence: Bool

    init(
        milestone: AgentMilestone,
        returnToEvidence: @escaping (String) -> Void,
        showsEvidence: Bool = false
    ) {
        self.milestone = milestone
        self.returnToEvidence = returnToEvidence
        _showsEvidence = State(initialValue: showsEvidence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading
            Text(milestone.whatChanged)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(milestone.whyItMattered)
                .font(TenonTheme.interfaceFont(size: 11.5))
                .foregroundStyle(TenonTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            evidence
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(TenonTheme.chrome, in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            // One accent stripe rather than a coloured card: the outcome is a small orientation
            // mark, and `designs.md` reserves large fills for something rarer than every row.
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 2)
                .padding(.vertical, 10)
                .padding(.leading, 1)
                .accessibilityHidden(true)
        }
    }

    /// Title and metadata share a line while the pane is wide enough, and stack when it is not —
    /// a narrow pane reflows rather than asking for horizontal scrolling.
    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 8)
                metadata
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                metadata
            }
        }
    }

    private var title: some View {
        Text(milestone.title)
            .font(TenonTheme.interfaceFont(size: 13, weight: .semibold))
            .foregroundStyle(TenonTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        // Read once: the drawn text and the spoken label are the same sentence, and this body
        // sits inside a `ViewThatFits`, which evaluates its candidates.
        let span = span
        return HStack(spacing: 6) {
            Text(milestone.outcome.title.uppercased())
                .font(TenonTheme.utilityFont(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(tint)
            Text(span)
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(milestone.outcome.title), \(span)")
    }

    @ViewBuilder private var evidence: some View {
        Button {
            showsEvidence.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showsEvidence ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(milestone.factCount) \(milestone.factCount == 1 ? "fact" : "facts")")
                    .font(TenonTheme.utilityFont(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(TenonTheme.muted)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            showsEvidence
                ? "Hide the \(milestone.factCount) facts behind this milestone"
                : "Show the \(milestone.factCount) facts behind this milestone"
        )

        if showsEvidence {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(milestone.anchors) { anchor in
                    Button {
                        returnToEvidence(anchor.factID)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8))
                                .foregroundStyle(TenonTheme.muted)
                                .padding(.top, 2)
                            Text(anchor.label)
                                .font(TenonTheme.utilityFont(size: 10))
                                .foregroundStyle(TenonTheme.muted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Show this in Chat")
                    .accessibilityLabel("Evidence: \(anchor.label)")
                    .accessibilityHint("Opens the verbatim account at this fact")
                }
            }
            .padding(.leading, 2)
            .background(TenonTheme.panel, in: .rect(cornerRadius: 6))
        }
    }

    private var span: String {
        AgentMilestoneSpan.text(from: milestone.startedAt, to: milestone.endedAt)
    }

    private var tint: Color {
        switch milestone.outcome {
        case .settled: .green
        case .inProgress: TenonTheme.amber
        case .superseded: TenonTheme.muted
        }
    }
}

// MARK: - Shared notice  @domain: agent-lens

private struct AgentTimelineNotice: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = TenonTheme.muted

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TenonTheme.interfaceFont(size: 12, weight: .semibold))
                    .foregroundStyle(TenonTheme.text)
                Text(detail)
                    .font(TenonTheme.interfaceFont(size: 11.5))
                    .foregroundStyle(TenonTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TenonTheme.chrome, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
