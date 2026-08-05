import SwiftUI

/// A semantic projection mounted in the terminal pane that owns the live PTY. Switching
/// modes only replaces the renderer: `SurfacePool` continues to own the same surface,
/// process, scrollback, and working directory until the workspace slot itself closes.
struct AgentLensSlotView: View {
    let terminal: AnyView
    @Bindable var model: AgentLensViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isAgentDetected {
                AgentLensModeBar(
                    provider: model.snapshot.provider,
                    status: model.snapshot.status,
                    mode: $model.mode,
                    hasDiagnostics: !model.snapshot.diagnostics.isEmpty
                )
                Divider().overlay(TenonTheme.line)
            }

            Group {
                if !model.isAgentDetected || model.mode == .terminal {
                    terminal
                } else if model.mode == .conversation {
                    AgentConversationView(model: model)
                } else {
                    AgentActivityView(snapshot: model.snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TenonTheme.ink)
        .task { model.start() }
        .accessibilityIdentifier("tenon.agentLens.slot")
    }
}

private struct AgentLensModeBar: View {
    let provider: AgentProvider?
    let status: AgentLensStatus
    @Binding var mode: AgentLensMode
    let hasDiagnostics: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(provider?.displayName ?? "Agent")
                    .font(.caption.weight(.semibold))
                Text(status.title)
                    .font(.caption)
                    .foregroundStyle(TenonTheme.muted)
                if hasDiagnostics {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Agent Lens has diagnostics")
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Picker("Agent Lens view", selection: $mode) {
                ForEach(AgentLensMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 310)
            .accessibilityIdentifier("tenon.agentLens.mode")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(TenonTheme.chrome)
    }

    private var statusColor: Color {
        switch status {
        case .ready, .completed: .green
        case .running: TenonTheme.amber
        case .waitingForUser: .yellow
        case .failed: .red
        case .degraded: .orange
        case .detecting, .unavailable: TenonTheme.muted
        }
    }
}

private struct AgentConversationView: View {
    @Bindable var model: AgentLensViewModel
    @State private var isPinnedToBottom = true
    @State private var unseenUpdates = 0
    @State private var lastRevision = 0
    @FocusState private var composerFocused: Bool

    private let bottomID = "agent-lens-bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider().overlay(TenonTheme.line)
            composer
        }
        .background(TenonTheme.ink)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.snapshot.earlierHistoryAvailable {
                            AgentLensNotice(
                                icon: "clock.arrow.circlepath",
                                text: "Showing a bounded recent window; earlier transcript history remains on disk."
                            )
                        }

                        if model.snapshot.messages.isEmpty &&
                            model.snapshot.tools.isEmpty &&
                            model.snapshot.interactions.isEmpty {
                            AgentLensEmptyProjection(status: model.snapshot.status)
                        }

                        ForEach(model.snapshot.messages) { message in
                            AgentMessageRow(message: message)
                                .id(message.id)
                        }

                        ForEach(model.snapshot.tools) { tool in
                            AgentToolRow(tool: tool)
                                .id("tool-\(tool.id)")
                        }

                        ForEach(model.snapshot.interactions) { request in
                            AgentInteractionRow(request: request)
                                .id("interaction-\(request.id)")
                        }

                        ForEach(model.snapshot.diagnostics) { diagnostic in
                            AgentDiagnosticRow(diagnostic: diagnostic)
                                .id("diagnostic-\(diagnostic.id)")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .onAppear {
                                isPinnedToBottom = true
                                unseenUpdates = 0
                            }
                            .onDisappear { isPinnedToBottom = false }
                    }
                    .padding(14)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if unseenUpdates > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                        unseenUpdates = 0
                    } label: {
                        Label("\(unseenUpdates) new updates", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                    .accessibilityHint("Scrolls to the latest agent output")
                }
            }
            .onAppear {
                lastRevision = model.snapshot.renderRevision
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: model.snapshot.renderRevision) { oldRevision, newRevision in
                guard newRevision != oldRevision, newRevision != lastRevision else { return }
                lastRevision = newRevision
                if isPinnedToBottom {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                } else {
                    unseenUpdates += 1
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the foreground agent", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(TenonTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(composerFocused ? TenonTheme.amber : TenonTheme.line)
                }
                .onSubmit {
                    guard model.canSend else { return }
                    Task { await model.sendDraft() }
                }
                .accessibilityHint("Input is sent only if the detected agent is still the terminal foreground process")

            Button {
                Task { await model.sendDraft() }
            } label: {
                if model.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSend)
            .accessibilityLabel("Send to agent")
            .accessibilityIdentifier("tenon.agentLens.send")
        }
        .padding(10)
        .background(TenonTheme.chrome)
    }
}

private struct AgentActivityView: View {
    let snapshot: AgentLensSnapshot

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if snapshot.activities.isEmpty {
                    AgentLensEmptyProjection(status: snapshot.status)
                        .padding(14)
                }
                ForEach(snapshot.activities) { activity in
                    AgentActivityRow(activity: activity)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(TenonTheme.ink)
        .accessibilityIdentifier("tenon.agentLens.activity")
    }
}

private struct AgentMessageRow: View {
    let message: AgentLensMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: roleIcon)
                    .foregroundStyle(roleColor)
                    .accessibilityHidden(true)
                Text(roleTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Streaming")
                }
                Spacer()
                AgentEvidenceBadge(evidence: message.evidence)
            }

            if message.role == .reasoning {
                DisclosureGroup("Reasoning") {
                    Text(message.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .foregroundStyle(TenonTheme.muted)
                        .padding(.top, 4)
                }
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundStyle(TenonTheme.text)
            }
        }
        .padding(10)
        .background(messageBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(TenonTheme.line.opacity(0.8))
        }
        .accessibilityElement(children: .contain)
    }

    private var roleTitle: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Assistant"
        case .reasoning: "Reasoning"
        case .system: "System"
        }
    }

    private var roleIcon: String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .reasoning: "brain"
        case .system: "info.circle"
        }
    }

    private var roleColor: Color {
        message.role == .user ? TenonTheme.amber : TenonTheme.muted
    }

    private var messageBackground: Color {
        message.role == .user ? TenonTheme.amber.opacity(0.07) : TenonTheme.panel
    }
}

private struct AgentToolRow: View {
    let tool: AgentToolRun
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if !tool.detail.isEmpty {
                Text(tool.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(TenonTheme.muted)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            AgentEvidenceBadge(evidence: tool.evidence)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: toolIcon)
                    .foregroundStyle(toolColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).font(.caption.weight(.semibold))
                    if !tool.summary.isEmpty {
                        Text(tool.summary)
                            .font(.caption)
                            .foregroundStyle(TenonTheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Text(tool.state.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(toolColor)
            }
        }
        .padding(10)
        .background(TenonTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(TenonTheme.line) }
    }

    private var toolIcon: String {
        switch tool.state {
        case .running: "gearshape.2"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .declined: "nosign"
        }
    }

    private var toolColor: Color {
        switch tool.state {
        case .running: TenonTheme.amber
        case .succeeded: .green
        case .failed: .red
        case .declined: TenonTheme.muted
        }
    }
}

private struct AgentInteractionRow: View {
    let request: AgentInteractionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                request.kind == .approval ? "Approval requested" : "Question",
                systemImage: request.kind == .approval ? "hand.raised.fill" : "questionmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(request.state == .pending ? Color.yellow : TenonTheme.muted)
            Text(request.title).font(.body.weight(.medium))
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.caption)
                    .foregroundStyle(TenonTheme.muted)
                    .textSelection(.enabled)
            }
            if request.state == .pending {
                Text("Respond in Terminal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TenonTheme.amber)
            }
            AgentEvidenceBadge(evidence: request.evidence)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.35)) }
    }
}

private struct AgentDiagnosticRow: View {
    let diagnostic: AgentLensDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: diagnostic.severity == .error
                ? "xmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(diagnostic.message).font(.caption)
                AgentEvidenceBadge(evidence: diagnostic.evidence)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TenonTheme.chrome, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct AgentActivityRow: View {
    let activity: AgentLensActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(kindColor).frame(width: 8, height: 8)
                Rectangle().fill(TenonTheme.line).frame(width: 1).frame(minHeight: 42)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(activity.title).font(.caption.weight(.semibold))
                    Spacer()
                    Text(activity.occurredAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(TenonTheme.muted)
                }
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.caption)
                        .foregroundStyle(TenonTheme.muted)
                        .textSelection(.enabled)
                }
                AgentEvidenceBadge(evidence: activity.evidence)
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var kindColor: Color {
        switch activity.kind {
        case .lifecycle: .blue
        case .message: TenonTheme.amber
        case .tool: .green
        case .interaction: .yellow
        case .diagnostic: .orange
        }
    }
}

private struct AgentEvidenceBadge: View {
    let evidence: AgentEvidence

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: evidence.authority == .observed ? "checkmark.shield" : "doc.text.magnifyingglass")
                .accessibilityHidden(true)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption2)
        .foregroundStyle(evidence.freshness == .current ? TenonTheme.muted : Color.orange)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var label: String {
        let source = evidence.source.rawValue
        return evidence.freshness == .current ? source : "\(source) · \(evidence.freshness.rawValue)"
    }

    private var helpText: String {
        let offset = evidence.byteOffset.map { " at byte \($0)" } ?? ""
        return "\(evidence.authority.rawValue.capitalized) evidence from \(evidence.location)\(offset)"
    }
}

private struct AgentLensNotice: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(TenonTheme.muted)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.chrome, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AgentLensEmptyProjection: View {
    let status: AgentLensStatus

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundStyle(TenonTheme.muted)
                .accessibilityHidden(true)
            Text(status.title).font(.headline)
            Text("Agent Lens is waiting for semantic output. The terminal remains available at all times.")
                .font(.caption)
                .foregroundStyle(TenonTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
