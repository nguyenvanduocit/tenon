// @domain: agent-lens
import AppKit
import SwiftUI
import TenonCore

/// What the pane's renderer picker offers, as ONE value.
///
/// The pane itself holds two properties — which single renderer it shows, and whether it is
/// showing both — because those are two independent facts about the same PTY. The picker is the
/// one place a person names a *combination* of them, so the combination gets a name here rather
/// than a second discriminator on the model. `PaneHeaderCommand.agentLensPresentation` relays
/// this enum's raw value and nothing else, which is what keeps the built-in half typed.
enum AgentLensPresentation: String, CaseIterable {
    case session
    case terminal
    case split

    /// What the pane is showing right now. Split wins over whichever single renderer was last
    /// chosen, because it is the thing on screen.
    init(mode: AgentLensMode, showsSplitView: Bool) {
        if showsSplitView {
            self = .split
        } else {
            self = mode == .session ? .session : .terminal
        }
    }

    /// The single renderer this presentation asks for, or nil when it asks for both.
    ///
    /// Picking split deliberately leaves `mode` alone: it is still the renderer the pane
    /// returns to when split is turned off, and overwriting it here would silently discard the
    /// person's last answer.
    var mode: AgentLensMode? {
        switch self {
        case .session: .session
        case .terminal: .terminal
        case .split: nil
        }
    }

    var showsSplitView: Bool { self == .split }

    /// The picker option this presentation draws as.
    ///
    /// Split is the one option with no word of its own — it names a layout rather than a
    /// renderer, and "Split" beside "Session" and "Terminal" reads as a third renderer. Both
    /// readers that an icon leaves without text are written for explicitly rather than left to
    /// `PaneHeaderSegment`'s fallback: the pointer gets `tooltip`, VoiceOver gets
    /// `accessibilityLabel`.
    ///
    /// They are deliberately not the same string. A spoken name stands in for a segment's
    /// visible label and is bounded like one — `PaneHeaderSegment.maximumLabelLength`, 32 — so
    /// the explanatory sentence would arrive at VoiceOver as "side by sid". The short name is
    /// the whole name; the hover text, bounded at a tooltip's 1024, is the sentence.
    var segment: PaneHeaderSegment? {
        switch self {
        case .session:
            PaneHeaderSegment(value: rawValue, label: AgentLensMode.session.title)
        case .terminal:
            PaneHeaderSegment(value: rawValue, label: AgentLensMode.terminal.title)
        case .split:
            PaneHeaderSegment(
                value: rawValue,
                systemName: "rectangle.split.2x1",
                accessibilityLabel: "Session beside Terminal",
                tooltip: "Session and Terminal side by side"
            )
        }
    }
}

/// What the Agent Lens pane contributes to the ONE chrome header its card draws.
///
/// Pure, and deliberately outside the view: which provider, which status, whether there is
/// anything wrong and which renderer is showing are all decisions about the pane's own state,
/// and once the items are chosen the drawing has no decisions left in it. Keeping the decision
/// here is what lets it be swept headlessly, which is the fitness test `docs/tdd.md` sets for
/// any rule that would otherwise only be checkable by looking at a window.
enum AgentLensPaneHeader {
    static func header(
        isAgentDetected: Bool,
        provider: AgentProvider?,
        status: AgentLensStatus,
        currentAction: String,
        hasDiagnostics: Bool,
        presentation: AgentLensPresentation,
        showsInspector: Bool,
        account: AgentLensAccount = .chat
    ) -> PaneHeader {
        // A terminal pane with no agent in it is a terminal pane. There is no provider to
        // name, no status to report and no second renderer to offer, so it keeps the bare
        // chrome every pane starts with — which is also the receipt that a shell pane pays
        // nothing for a feature it is not using.
        guard isAgentDetected else { return .empty }

        var leading: [PaneHeaderItem] = [
            // What the agent is doing right now is the one thing in this strip that is not
            // already written on it, so it hangs off the two items that are about status.
            .dot(id: "state", tint: tint(for: status), tooltip: currentAction),
            .label(
                id: "provider",
                text: provider?.displayName ?? "Agent",
                weight: .semibold,
                color: .text,
                truncation: .tail,
                tooltip: nil
            ),
            .label(
                id: "status",
                text: status.title,
                weight: .regular,
                color: .muted,
                truncation: .tail,
                tooltip: currentAction
            ),
        ]
        if hasDiagnostics {
            leading.append(
                .image(
                    id: "diagnostics",
                    systemName: "exclamationmark.triangle.fill",
                    tint: .amber,
                    tooltip: "Agent Lens has diagnostics"
                )
            )
        }

        // The account picker exists only while the Session renderer is on screen. A Terminal-only
        // pane draws no Chat and no Timeline, so offering a choice between them would be a
        // control whose two states look identical.
        var trailing: [PaneHeaderItem] = []
        if presentation != .terminal {
            trailing.append(
                .segmented(
                    id: PaneHeaderCommand.agentLensAccount.rawValue,
                    segments: AgentLensAccount.allCases.compactMap {
                        PaneHeaderSegment(value: $0.rawValue, label: $0.title)
                    },
                    selection: account.rawValue,
                    isEnabled: true,
                    accessibilityID: "tenon.agentLens.account"
                )
            )
        }

        return PaneHeader(
            leading: leading,
            trailing: trailing + [
                .segmented(
                    id: PaneHeaderCommand.agentLensPresentation.rawValue,
                    segments: AgentLensPresentation.allCases.compactMap(\.segment),
                    selection: presentation.rawValue,
                    isEnabled: true,
                    // An XCUITest anchor is host identity, not contributor data: a plugin
                    // cannot mint one, and a host-native producer must, or the anchor the
                    // in-body picker carried is lost in the move into chrome.
                    accessibilityID: "tenon.agentLens.mode"
                ),
                .toggle(
                    id: PaneHeaderCommand.agentLensInspector.rawValue,
                    systemName: "sidebar.right",
                    // The item's own CURRENT state, not the next one; the pane flips it.
                    isOn: showsInspector,
                    isEnabled: true,
                    tooltip: showsInspector
                        ? "Hide context and evidence"
                        : "Show context and evidence",
                    accessibilityID: nil
                ),
            ]
        )
    }

    /// The status dot's colour, in the header's own token space rather than as a `Color`.
    ///
    /// Every other item in the strip resolves its colour through `ViewTokenPalette`, so a pane
    /// mixing its own greens would be the one thing in the chrome able to disagree with the
    /// rest of it about what green means.
    ///
    /// Running, waiting and degraded all collapse onto amber because they are all "look here"
    /// rather than "this is over", and amber is the chrome's one attention colour. The label
    /// beside the dot is what tells them apart.
    private static func tint(for status: AgentLensStatus) -> ColorToken {
        switch status {
        case .completed: .green
        case .failed: .red
        case .running, .waitingForUser, .degraded: .amber
        case .ready, .detecting, .unavailable: .muted
        }
    }
}

/// A semantic projection mounted in the terminal pane that owns the live PTY. Switching
/// modes only replaces the renderer: `SurfacePool` continues to own the same surface,
/// process, scrollback, and working directory until the workspace slot itself closes.
struct AgentLensSlotView: View {
    let terminal: AnyView
    let focusTerminal: @MainActor @Sendable () -> Void
    @Bindable var model: AgentLensViewModel
    /// The workspace a written path is read against. A path only becomes a link while it
    /// resolves to a file that is really there.
    var workspaceRoot: URL?
    /// Opens the file a cited path names. Agent Lens is host-native UI over the host-owned
    /// file pane, so this is the typed workspace call, not a public boundary.
    var openFile: (@MainActor @Sendable (String) -> Void)?
    /// Where this pane's contribution to the card's ONE chrome header goes UP. The already
    /// projected value comes back DOWN through `SpatialSlotCardView.configure`; this is the
    /// other half of that loop.
    var headerStore: PaneHeaderStore

    var body: some View {
        VStack(spacing: 0) {
            if !model.isAgentDetected {
                terminal
            } else if model.showsSplitView {
                HSplitView {
                    session
                        .frame(minWidth: 320)
                    terminal
                        .frame(minWidth: 280)
                }
                .accessibilityIdentifier("tenon.agentLens.splitView")
            } else if model.mode == .terminal {
                terminal
            } else {
                session
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.ink)
        // The inspector is a panel inside the body, because a `PaneHeader` is a bounded value
        // and cannot carry an `AgentLensSnapshot`: the evidence stays where the data already
        // is, and the toggle in the chrome only says whether the panel is open.
        .overlay(alignment: .topTrailing) { inspector }
        .environment(\.openURL, OpenURLAction { url in
            // A cited file opens in the workspace; everything else keeps the system
            // behaviour a link in prose already had.
            guard url.isFileURL, let openFile else { return .systemAction }
            openFile(url.path)
            return .handled
        })
        .onChange(of: model.mode) { _, mode in
            guard mode == .terminal else { return }
            // The segmented control is the first responder when the user switches
            // renderers. Wait until the live Ghostty view is back in the hierarchy,
            // then return keyboard ownership to the PTY.
            DispatchQueue.main.async(execute: focusTerminal)
        }
        .onChange(of: model.showsSplitView) { _, showsSplitView in
            guard !showsSplitView, model.mode == .terminal else { return }
            DispatchQueue.main.async(execute: focusTerminal)
        }
        .task {
            model.start()
            // The controls in the chrome report an item id; the router turns it back into a
            // typed command and this is where the pane acts on it. `model` is what the
            // handler closes over, and it outlives every re-root the canvas hands this view.
            headerStore.onCommand(for: model.slotID) { [model] command, value in
                switch command {
                case .agentLensPresentation:
                    guard let next = value.flatMap(AgentLensPresentation.init(rawValue:)) else {
                        return
                    }
                    if let mode = next.mode { model.mode = mode }
                    model.showsSplitView = next.showsSplitView
                case .agentLensAccount:
                    guard let next = value.flatMap(AgentLensAccount.init(rawValue:)) else {
                        return
                    }
                    model.account = next
                case .agentLensInspector:
                    // Opening the panel from the chrome shows the session's own context, not
                    // whichever timeline row was inspected last — that selection belongs to the
                    // row that made it.
                    model.inspection = nil
                    model.showsInspector.toggle()
                case .diffStyle, .changesLayout, .changesRefresh:
                    return
                }
            }
            headerStore.publish(header, for: model.slotID)
        }
        // Published from `.onChange`, never from `body`: writing to an observable during a view
        // update is what makes SwiftUI re-enter, and the store's equality guard is a backstop
        // for that mistake rather than a licence to make it. Reading `header` here is what
        // registers the observation that makes this fire.
        .onChange(of: header) { _, next in
            headerStore.publish(next, for: model.slotID)
        }
        .onDisappear { headerStore.clear(for: model.slotID) }
        .accessibilityIdentifier("tenon.agentLens.slot")
    }

    /// This pane's chrome contribution for its current state.
    private var header: PaneHeader {
        AgentLensPaneHeader.header(
            isAgentDetected: model.isAgentDetected,
            provider: model.snapshot.provider,
            status: model.snapshot.status,
            currentAction: model.snapshot.currentActionSummary,
            hasDiagnostics: !model.snapshot.diagnostics.isEmpty,
            presentation: AgentLensPresentation(
                mode: model.mode,
                showsSplitView: model.showsSplitView
            ),
            showsInspector: model.showsInspector,
            account: model.account
        )
    }

    /// The context-and-evidence panel, layered over the pane it belongs to.
    ///
    /// The scrim is the panel's dismiss: a click anywhere outside it puts it away. It is drawn
    /// rather than left clear so the body dims behind it and the panel reads as layered over
    /// the pane instead of pasted into it.
    @ViewBuilder private var inspector: some View {
        if model.showsInspector {
            // The scrim is the base and the panel is drawn on it, for the same reason the
            // timeline uses an overlay: a `ZStack` would size itself by asking the panel —
            // and the lazy list inside it — what it wants, which measures rows nobody can see.
            Rectangle()
                .fill(TenonTheme.ink.opacity(0.35))
                .onTapGesture { model.showsInspector = false }
                .accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                    AgentLensInspector(snapshot: model.snapshot, inspection: model.inspection)
                        .frame(maxWidth: 420, maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            Divider().overlay(TenonTheme.line)
                        }
                }
        }
    }

    private var session: some View {
        AgentSessionView(
            model: model,
            openTerminal: openTerminal,
            fileLinks: fileLinks
        )
    }

    private var fileLinks: AgentFileLinks {
        guard openFile != nil, let workspaceRoot else { return .none }
        return AgentFileLinks(root: workspaceRoot)
    }

    private func openTerminal() {
        model.mode = .terminal
        if model.showsSplitView {
            DispatchQueue.main.async(execute: focusTerminal)
        }
    }
}

/// Owns the finite pane viewport without asking the account content for its ideal size.
///
/// Agent Chat contains a live `ScrollView`/`LazyVStack`. Measuring that content while placing
/// the pane lets lazy prefetch invalidate the same `NSHostingView` constraints pass that caused
/// the measurement, so AppKit can keep restarting one display cycle. Only the small footer is
/// content-sized; the account receives the exact space left above it.
struct AgentSessionLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let footerSize = measuredFooter(proposal: proposal, subviews: subviews)
        return CGSize(
            width: proposal.width ?? footerSize.width,
            height: proposal.height ?? footerSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        guard subviews.count > 1 else {
            content.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
            return
        }

        let footer = subviews[1]
        let measuredHeight = footer.sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        let footerHeight = min(max(measuredHeight.isFinite ? measuredHeight : 0, 0), bounds.height)
        let contentHeight = max(bounds.height - footerHeight, 0)

        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: contentHeight)
        )
        footer.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - footerHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: footerHeight)
        )
    }

    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        Self.guidePosition(of: guide, across: bounds.width)
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        Self.guidePosition(of: guide, across: bounds.height)
    }

    /// Where a standard guide sits across this layout, read off the box rather than the content.
    ///
    /// This layout fills whatever it is offered — `sizeThatFits` returns the proposal — and puts
    /// the account at the top-leading corner with the footer against the bottom edge. Its
    /// leading edge, centre and trailing edge are therefore properties of the box alone, and no
    /// subview has to be measured or placed to say where they are.
    ///
    /// A guide this layout does not recognise — a text baseline, or one an ancestor defined —
    /// answers `nil` and takes the default. That is the expensive route, and it is the correct
    /// one: a baseline is a fact about the content, and guessing the box's centre for it would
    /// misalign the pane to buy speed.
    static func guidePosition(of guide: HorizontalAlignment, across width: CGFloat) -> CGFloat? {
        switch guide {
        case .leading: 0
        case .center: width / 2
        case .trailing: width
        default: nil
        }
    }

    static func guidePosition(of guide: VerticalAlignment, across height: CGFloat) -> CGFloat? {
        switch guide {
        case .top: 0
        case .center: height / 2
        case .bottom: height
        default: nil
        }
    }

    private func measuredFooter(proposal: ProposedViewSize, subviews: Subviews) -> CGSize {
        guard subviews.count > 1 else { return .zero }
        return subviews[1].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
    }
}

/// Admits one bottom-scroll request until that request has run on the next main-loop turn.
///
/// Snapshot delivery and the scroll itself both run on the main actor. Without this gate, a
/// burst can enqueue one expensive `ScrollViewProxy.scrollTo` for every revision before the
/// first request gets a turn, leaving the UI draining obsolete geometry work after input stops.
struct AgentScrollTurnGate {
    private(set) var isClaimed = false

    mutating func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }

    mutating func release() {
        isClaimed = false
    }
}

private struct AgentSessionView: View {
    @Bindable var model: AgentLensViewModel
    let openTerminal: () -> Void
    let fileLinks: AgentFileLinks

    @State private var isPinnedToBottom = true
    @State private var unseenUpdates = 0
    @State private var lastRevision = 0
    @State private var bottomScrollGate = AgentScrollTurnGate()
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "agent-lens-bottom"

    var body: some View {
        AgentSessionLayout {
            // Two readings of ONE attached session. Switching between them changes no
            // attachment, sends nothing to the PTY, and leaves the composer where it is: a
            // person can answer a waiting question without leaving the synthesized reading.
            switch model.account {
            case .chat:
                timeline
            case .timeline:
                AgentSessionTimelineView(
                    model: model,
                    returnToEvidence: { model.returnToEvidence($0) }
                )
            }
            // A recorded session draws no composer at all, rather than a disabled one. There
            // is nothing to type into: the pane holds no PTY, and a greyed-out field would
            // still say "you could answer this here" about a session that ended.
            if model.attachment.allowsSending {
                VStack(spacing: 0) {
                    Divider().overlay(TenonTheme.line)
                    composer
                }
            }
        }
        .background(TenonTheme.ink)
        .onChange(of: model.snapshot.pendingInteraction?.id) { _, requestID in
            guard requestID != nil else { return }
            composerFocused = true
        }
        .accessibilityIdentifier("tenon.agentLens.session")
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            // `.overlay` keeps the jump button out of the scroll view's sizing contract.
            //
            // The enclosing `AgentSessionLayout` owns the stronger invariant: it places this
            // scroll view with an exact finite viewport, so neither a ZStack nor an ordinary
            // StackLayout can ask the lazy content for an ideal size during the host's pass.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AgentHookSetupNotice(provider: model.snapshot.provider)

                    if let earlierHistory = model.snapshot.earlierHistory {
                        AgentLensNotice(
                            icon: "clock.arrow.circlepath",
                            text: AgentLensEarlierHistoryNotice.text(for: earlierHistory)
                        )
                        .padding(.bottom, 8)
                    }

                    if model.timelineItems.isEmpty {
                        AgentLensEmptyProjection(status: model.snapshot.status)
                    }

                    ForEach(model.timelineItems) { item in
                        AgentTimelineRow(
                            item: item,
                            inspect: inspect,
                            chooseOption: chooseOption,
                            openTerminal: openTerminal,
                            fileLinks: fileLinks,
                            submittedOptionRequestID: model.submittedOptionRequestID,
                            allowsAnswering: model.attachment.allowsSending
                        )
                        .id(item.id)
                    }

                    // Keep the breathing room inside the target so its bottom edge is
                    // also the real end of the scroll content. Parent bottom padding
                    // would leave scrollTo(bottomID) one inset short of the true bottom.
                    Color.clear
                        .frame(height: 12)
                        .id(bottomID)
                        .onAppear {
                            isPinnedToBottom = true
                            unseenUpdates = 0
                        }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .tenonScrollbarStyle()
            .overlay(alignment: .bottomTrailing) {
                if unseenUpdates > 0 {
                    Button {
                        if reduceMotion {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
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
                if let factID = model.pendingChatFocus {
                    model.pendingChatFocus = nil
                    isPinnedToBottom = false
                    DispatchQueue.main.async { proxy.scrollTo(factID, anchor: .center) }
                } else {
                    scheduleBottomScroll(using: proxy)
                }
            }
            // A milestone's anchor landing while Chat is already mounted — the split view shows
            // both, so this list may never have gone away.
            .onChange(of: model.pendingChatFocus) { _, factID in
                guard let factID else { return }
                model.pendingChatFocus = nil
                isPinnedToBottom = false
                DispatchQueue.main.async { proxy.scrollTo(factID, anchor: .center) }
            }
            .onChange(of: model.snapshot.renderRevision) { oldRevision, newRevision in
                guard newRevision != oldRevision, newRevision != lastRevision else { return }
                lastRevision = newRevision
                if isPinnedToBottom {
                    // The revision arrives before the new row has completed layout.
                    // Coalesce the burst and scroll once on the next main-loop turn using the
                    // newest bottom geometry. Obsolete requests must never form a queue.
                    scheduleBottomScroll(using: proxy)
                } else {
                    unseenUpdates += 1
                }
            }
        }
    }

    private func scheduleBottomScroll(using proxy: ScrollViewProxy) {
        let admitted = bottomScrollGate.claim()
        DiagnosticsRuntimeSignals.shared.noteAgentLensScroll(
            paneOrdinal: model.diagnosticsPaneOrdinal,
            admitted: admitted,
            pinned: isPinnedToBottom
        )
        guard admitted else { return }
        DispatchQueue.main.async {
            defer { bottomScrollGate.release() }
            DiagnosticsRuntimeSignals.shared.noteAgentLensScrollExecuted(
                paneOrdinal: model.diagnosticsPaneOrdinal
            )
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private var composer: some View {
        TextField(composerPlaceholder, text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($composerFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(TenonTheme.panel, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(composerFocused ? TenonTheme.amber : TenonTheme.line)
            }
            .onSubmit(of: .text) {
                guard model.canSend else { return }
                Task { await model.sendDraft() }
            }
            .onExitCommand { composerFocused = false }
            .accessibilityHint("Input is sent only while the detected agent remains the terminal foreground process")
            .padding(10)
            .background(TenonTheme.chrome)
    }

    private var composerPlaceholder: String {
        switch model.snapshot.status {
        case .waitingForUser: "Type your decision or answer"
        case .running: "Add direction without leaving the session"
        case .completed: "Send a follow-up"
        default: "Message the foreground agent"
        }
    }

    /// A timeline row raising the inspector on its own evidence. This is the second reader of
    /// that state — the chrome toggle is the first — and it is why the two properties live on
    /// the model rather than in this view's `@State`.
    private func inspect(_ next: AgentLensInspection) {
        model.inspection = next
        model.showsInspector = true
    }

    /// The agent is showing a numbered list and reading keystrokes, so answering is sending
    /// the key for that option. When the decision is no longer the one on screen the answer
    /// would land somewhere else entirely, so it falls back to the composer and the person
    /// stays in control of what gets sent.
    private func chooseOption(_ request: AgentInteractionRequest, _ option: AgentInteractionOption) {
        Task {
            guard await model.answer(request, with: option) == false else { return }
            model.draft = option.label
            composerFocused = true
        }
    }
}

private struct AgentTimelineRow: View {
    let item: AgentTimelineItem
    let inspect: (AgentLensInspection) -> Void
    let chooseOption: (AgentInteractionRequest, AgentInteractionOption) -> Void
    let openTerminal: () -> Void
    let fileLinks: AgentFileLinks
    let submittedOptionRequestID: String?
    /// Whether an answer can reach anything. False for a recorded session, whose pending
    /// question was answered — or abandoned — before this pane ever opened.
    let allowsAnswering: Bool

    @ViewBuilder var body: some View {
        switch item.content {
        case .message(let message):
            AgentSpineMessageRow(
                message: message,
                occurredAt: item.occurredAt,
                inspect: { inspect(.message(message)) },
                fileLinks: fileLinks
            )
        case .tools(let group):
            AgentSpineToolRow(
                group: group,
                occurredAt: item.occurredAt
            )
        case .interaction(let request):
            AgentSpineInteractionRow(
                request: request,
                occurredAt: item.occurredAt,
                inspect: { inspect(.interaction(request)) },
                chooseOption: chooseOption,
                openTerminal: openTerminal,
                answerSubmitted: submittedOptionRequestID == request.id,
                allowsAnswering: allowsAnswering
            )
        case .diagnostic(let diagnostic):
            AgentSpineDiagnosticRow(
                diagnostic: diagnostic,
                occurredAt: item.occurredAt,
                inspect: { inspect(.diagnostic(diagnostic)) }
            )
        }
    }
}

private struct AgentSpineChrome<Content: View>: View {
    let evidence: AgentEvidence
    let tint: Color
    let active: Bool
    let inspect: () -> Void
    let content: Content

    init(
        evidence: AgentEvidence,
        tint: Color,
        active: Bool,
        inspect: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.evidence = evidence
        self.tint = tint
        self.active = active
        self.inspect = inspect
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .top) {
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    context.stroke(
                        path,
                        with: .color((active ? tint : TenonTheme.line).opacity(active ? 0.58 : 0.72)),
                        style: StrokeStyle(lineWidth: 1, dash: active ? [2, 3] : [])
                    )
                }

                Button(action: inspect) {
                    ZStack {
                        Circle()
                            .strokeBorder(tickTint, lineWidth: 1.25)
                            .frame(width: 8, height: 8)
                        if evidence.authority == .observed {
                            Circle().fill(tickTint).frame(width: 4, height: 4)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(evidence.helpText)
                .accessibilityLabel(evidence.helpText)
            }
            .frame(width: 18)
            .frame(maxHeight: .infinity)

            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private var tickTint: Color {
        evidence.freshness == .current ? tint : .orange
    }
}

private struct AgentSpineTag: View {
    let title: String
    var tint = TenonTheme.muted

    var body: some View {
        Text(title.uppercased())
            .font(TenonTheme.utilityFont(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .fixedSize()
    }
}

private struct AgentSpineMessageRow: View {
    let message: AgentLensMessage
    let occurredAt: Date
    let inspect: () -> Void
    let fileLinks: AgentFileLinks

    @State private var expanded = false

    var body: some View {
        AgentSpineChrome(
            evidence: message.evidence,
            tint: railTint,
            active: message.isStreaming,
            inspect: inspect
        ) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentSpineTag(title: message.role.timelineTitle, tint: railTint)
                    if message.role == .reasoning {
                        Text(expanded ? "Expanded" : "Collapsed")
                            .font(.caption2)
                            .foregroundStyle(TenonTheme.muted)
                    }
                    if message.isStreaming {
                        Text("LIVE")
                            .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                            .foregroundStyle(TenonTheme.amber)
                            .accessibilityLabel("Streaming")
                    }
                    Spacer()
                    Text(occurredAt, style: .time)
                        .font(TenonTheme.utilityFont(size: 9.5))
                        .foregroundStyle(TenonTheme.muted)
                }

                if message.role == .reasoning {
                    reasoning
                } else {
                    messageBody
                }
            }
            .contextMenu {
                Button("Copy text") { copyAgentLensText(message.text) }
                Button("Inspect evidence", action: inspect)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(message.evidence.authority.rawValue), \(message.isStreaming ? "streaming" : "complete")")
    }

    private var reasoning: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(expanded ? "Reasoning trace" : compactPreview)
                        .font(.caption)
                        .lineLimit(expanded ? 1 : 2)
                }
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapses reasoning" : "Expands reasoning")

            if expanded {
                AgentMarkdownText(
                    source: message.text,
                    textStyle: .callout,
                    tint: TenonTheme.muted,
                    fileLinks: fileLinks
                )
            }
        }
    }

    /// A message renders whole. Length is not a reason to hide what an agent said: the
    /// reader scrolls past what they do not need, and never has to ask for the rest.
    private var messageBody: some View {
        AgentMarkdownText(
            source: message.text,
            weight: message.role == .user ? .medium : .regular,
            caret: message.isStreaming,
            fileLinks: fileLinks
        )
    }

    private var railTint: Color {
        message.role == .user || message.isStreaming ? TenonTheme.amber : TenonTheme.muted
    }

    private var compactPreview: String {
        message.text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

}

private struct AgentSpineToolRow: View {
    let group: AgentTimelineToolGroup
    let occurredAt: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(TenonTheme.amber)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            AgentSpineTag(title: group.kind.timelineTitle, tint: TenonTheme.amber)
            Text(group.tools.last?.name ?? group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TenonTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("Running")
                .font(.caption2.weight(.medium))
                .foregroundStyle(TenonTheme.amber)
            Text(occurredAt, style: .time)
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
        }
        .padding(.vertical, 7)
        .help("Open Terminal to inspect execution details")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.kind.timelineTitle), \(group.tools.last?.name ?? group.title), running")
    }
}

private struct AgentSpineInteractionRow: View {
    let request: AgentInteractionRequest
    let occurredAt: Date
    let inspect: () -> Void
    let chooseOption: (AgentInteractionRequest, AgentInteractionOption) -> Void
    let openTerminal: () -> Void
    let answerSubmitted: Bool
    let allowsAnswering: Bool

    var body: some View {
        AgentSpineChrome(
            evidence: request.evidence,
            tint: request.state == .pending ? TenonTheme.amber : TenonTheme.muted,
            active: request.state == .pending,
            inspect: inspect
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AgentSpineTag(
                        title: request.kind == .approval ? "Approval" : "Question",
                        tint: request.state == .pending ? TenonTheme.amber : TenonTheme.muted
                    )
                    Text(request.state.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(TenonTheme.muted)
                    Spacer()
                    Text(occurredAt, style: .time)
                        .font(TenonTheme.utilityFont(size: 9.5))
                        .foregroundStyle(TenonTheme.muted)
                }
                Text(request.title).font(.callout.weight(.medium))
                if !request.detail.isEmpty {
                    Text(request.detail)
                        .font(.caption)
                        .foregroundStyle(TenonTheme.muted)
                        .textSelection(.enabled)
                }
                // A finished session that stopped mid-question still carries a pending
                // request, and that is worth SHOWING — it is how the session ended. What it
                // does not get is controls: nobody is waiting for the answer.
                if request.state == .pending, allowsAnswering {
                    pendingControls
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(request.state.displayTitle), \(request.evidence.authority.rawValue)")
    }

    @ViewBuilder private var pendingControls: some View {
        if request.options.isEmpty {
            Button(request.kind == .approval ? "Review in Terminal" : "Answer in Terminal") {
                openTerminal()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(request.options) { option in
                        Button(option.label) { chooseOption(request, option) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(answerSubmitted)
                            .help(option.detail.isEmpty ? "Use this answer" : option.detail)
                    }
                }
            }
            .tenonScrollbarStyle()
            .scrollIndicators(.hidden)
            .accessibilityLabel("Suggested answers")
        }
    }
}

/// Says so when the agent's Tenon hook is not installed, and offers the one step that fixes
/// it. Without the hook a Claude Code session still shows its transcript, but everything
/// that happens *during* a turn — the tool running now, the question waiting now — is
/// invisible, and that gap is the whole reason to watch a session instead of a log.
private struct AgentHookSetupNotice: View {
    let provider: AgentProvider?

    @State private var status = AgentHookInstallStatus.shared
    @State private var isRetrying = false

    var body: some View {
        if let reason = status.failureReason(for: provider), let provider {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.clock")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Live session updates are off")
                        .font(.caption.weight(.semibold))
                }
                Text(
                    """
                    \(provider.displayName)'s Tenon hook is not installed, so this pane sees \
                    a turn only after it ends. Reason: \(reason)
                    """
                )
                .font(.caption)
                .foregroundStyle(TenonTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(isRetrying ? "Setting up…" : "Set up hook") {
                        isRetrying = true
                        status.retry(provider: provider)
                        isRetrying = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRetrying || !status.canRetry(provider))
                    Text("Restart the \(provider.displayName) session afterwards")
                        .font(.caption2)
                        .foregroundStyle(TenonTheme.muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.panel, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(TenonTheme.line)
            }
            .padding(.bottom, 8)
            .accessibilityIdentifier("tenon.agentLens.hookSetup")
        }
    }
}

private struct AgentSpineDiagnosticRow: View {
    let diagnostic: AgentLensDiagnostic
    let occurredAt: Date
    let inspect: () -> Void

    var body: some View {
        AgentSpineChrome(
            evidence: diagnostic.evidence,
            tint: severityTint,
            active: false,
            inspect: inspect
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AgentSpineTag(
                    title: diagnostic.severity == .error ? "Error" : "Warning",
                    tint: severityTint
                )
                Text(diagnostic.message)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(occurredAt, style: .time)
                    .font(TenonTheme.utilityFont(size: 9.5))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// An error resolves the same red the chrome header's `.red` token resolves, so the rail in
    /// the timeline and the dot in the strip cannot drift apart about what failure looks like.
    private var severityTint: Color {
        diagnostic.severity == .error
            ? ViewTokenPalette.color(.red, style: .caption)
            : .orange
    }
}

func copyAgentLensText(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

private struct AgentLensInspector: View {
    let snapshot: AgentLensSnapshot
    let inspection: AgentLensInspection?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let inspection {
                    selectedEvidence(inspection)
                    Divider().overlay(TenonTheme.line)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Session Context")
                        .font(.headline)
                    Text("Instructions shape agent behavior but stay outside the execution timeline.")
                        .font(.caption)
                        .foregroundStyle(TenonTheme.muted)
                }

                AgentContextOverview(messages: snapshot.contextMessages)

                if snapshot.contextMessages.isEmpty {
                    ContentUnavailableView(
                        "No Context Messages",
                        systemImage: "slider.horizontal.3",
                        description: Text("No system, developer, project, or skill instructions were projected.")
                    )
                } else {
                    ForEach(snapshot.contextMessages) { message in
                        AgentContextInspectorRow(message: message)
                    }
                }
            }
            .padding(14)
        }
        .tenonScrollbarStyle()
        .background(TenonTheme.chrome)
        .accessibilityIdentifier("tenon.agentLens.inspector")
    }

    private func selectedEvidence(_ item: AgentLensInspection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.category.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TenonTheme.amber)
                Spacer()
                Text(item.evidence.capturedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(TenonTheme.muted)
            }
            Text(item.title)
                .font(.headline)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(TenonTheme.muted)
                    .textSelection(.enabled)
            }
            AgentEvidenceDetails(evidence: item.evidence)
        }
    }
}

private struct AgentContextOverview: View {
    let messages: [AgentLensMessage]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                count("System", role: .system)
                count("Developer", role: .developer)
            }
            GridRow {
                count("Project", kind: .instruction, role: .user)
                count("Skills", kind: .skill)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TenonTheme.panel, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func count(
        _ title: String,
        kind: AgentMessageKind? = nil,
        role: AgentMessageRole? = nil
    ) -> some View {
        let value = messages.filter { message in
            (kind == nil || message.kind == kind) && (role == nil || message.role == role)
        }.count
        return HStack(spacing: 6) {
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(TenonTheme.muted)
        }
    }
}

private struct AgentContextInspectorRow: View {
    let message: AgentLensMessage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.caption)
                    .textSelection(.enabled)
                AgentEvidenceDetails(evidence: message.evidence)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: message.contextIcon)
                    .font(.caption2)
                    .foregroundStyle(TenonTheme.muted)
                    .accessibilityHidden(true)
                Text(message.contextTitle)
                    .font(.caption.weight(.semibold))
                Text("·")
                    .foregroundStyle(TenonTheme.muted)
                Text(message.contextSummary)
                    .font(.caption2)
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityHint("Expands the full context message and evidence")
    }
}

private struct AgentEvidenceDetails: View {
    let evidence: AgentEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            evidenceRow("Authority", evidence.authority.rawValue.capitalized)
            evidenceRow("Source", evidence.source.displayTitle)
            evidenceRow("Freshness", evidence.freshness.displayTitle)
            evidenceRow("Location", evidence.location)
            if let offset = evidence.byteOffset {
                evidenceRow("Offset", "byte \(offset)")
            }
            if !evidence.fingerprint.isEmpty {
                evidenceRow("Fingerprint", evidence.fingerprint)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TenonTheme.panel, in: .rect(cornerRadius: 7))
    }

    private func evidenceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(TenonTheme.muted)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
                .lineLimit(label == "Location" ? 3 : 1)
                .truncationMode(.middle)
        }
    }
}

private struct AgentLensNotice: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(TenonTheme.muted)
            // A notice that says where evidence begins is worth more than the width it fits
            // in, so a narrow pane wraps it instead of truncating the part that locates it.
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TenonTheme.chrome, in: .rect(cornerRadius: 7))
    }
}

private struct AgentLensEmptyProjection: View {
    let status: AgentLensStatus

    var body: some View {
        ContentUnavailableView(
            status.title,
            systemImage: "scope",
            description: Text("Waiting for semantic output. The live terminal remains available at all times.")
        )
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// One inspected fact and the evidence behind it. Held by `AgentLensViewModel` rather than by a
/// view, because two readers raise it: a timeline row picking its own evidence, and the chrome
/// toggle that opens the panel on the session's context.
@MainActor
struct AgentLensInspection: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let evidence: AgentEvidence

    init(id: String, category: String, title: String, detail: String, evidence: AgentEvidence) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }

    static func message(_ message: AgentLensMessage) -> Self {
        Self(
            id: "message-\(message.id)",
            category: message.role.timelineTitle,
            title: message.role.timelineTitle,
            detail: message.text,
            evidence: message.evidence
        )
    }

    static func interaction(_ request: AgentInteractionRequest) -> Self {
        Self(
            id: "interaction-\(request.id)",
            category: request.kind == .approval ? "Approval" : "Question",
            title: request.title,
            detail: request.detail,
            evidence: request.evidence
        )
    }

    static func diagnostic(_ diagnostic: AgentLensDiagnostic) -> Self {
        Self(
            id: "diagnostic-\(diagnostic.id)",
            category: "Diagnostic",
            title: diagnostic.severity.rawValue.capitalized,
            detail: diagnostic.message,
            evidence: diagnostic.evidence
        )
    }

    /// The inspection for any fact a milestone anchored to.
    ///
    /// This is the anchor's return path, and it is deliberately the one that always exists.
    /// Scrolling Chat to the anchored row works only for a fact Chat draws, and Chat drops
    /// completed tool runs on purpose — so a milestone standing on "ran the suite, 1510 passed"
    /// would otherwise cite evidence with nothing on the other end. The inspector shows the
    /// source, authority, location, offset and fingerprint for every kind of fact.
    init?(fact item: AgentTimelineItem) {
        switch item.content {
        case .message(let message): self = .message(message)
        case .interaction(let request): self = .interaction(request)
        case .diagnostic(let diagnostic): self = .diagnostic(diagnostic)
        case .tools(let group):
            guard let evidence = group.evidence else { return nil }
            self = Self(
                id: group.id,
                category: group.kind == .subagent ? "Subagent" : "Tool",
                title: group.title,
                detail: group.tools
                    .map { tool in
                        [tool.name, tool.summary, tool.detail]
                            .filter { !$0.isEmpty }
                            .joined(separator: " — ")
                    }
                    .joined(separator: "\n"),
                evidence: evidence
            )
        }
    }
}

@MainActor
private extension AgentMessageRole {
    var timelineTitle: String {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .reasoning: "Reasoning"
        case .system: "System"
        case .developer: "Developer"
        }
    }

    var timelineIcon: String {
        switch self {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .reasoning: "brain"
        case .system: "gearshape.fill"
        case .developer: "wrench.and.screwdriver.fill"
        }
    }

}

@MainActor
private extension AgentToolKind {
    var timelineTitle: String {
        switch self {
        case .generic: "Tool"
        case .command: "Command"
        case .fileChange: "File"
        case .fileRead: "Read"
        case .search: "Search"
        case .webSearch: "Web"
        case .plan: "Plan"
        case .skill: "Skill"
        case .subagent: "Subagent"
        case .question: "Question"
        }
    }

}

private extension AgentInteractionState {
    var displayTitle: String {
        switch self {
        case .pending: "Needs input"
        case .answered: "Answered"
        case .expired: "Expired"
        }
    }
}

private extension AgentEvidenceSource {
    var displayTitle: String {
        switch self {
        case .transcript: "Transcript"
        case .nativeProtocol: "Native protocol"
        case .providerHook: "Provider hook"
        case .terminalInput: "Terminal input"
        case .terminalInference: "Terminal observation"
        }
    }
}

private extension AgentEvidenceFreshness {
    var displayTitle: String {
        switch self {
        case .current: "Current"
        case .stale: "Stale"
        case .sourceMissing: "Source missing"
        case .gap: "Incomplete"
        }
    }
}

private extension AgentEvidence {
    var helpText: String {
        let offset = byteOffset.map { " at byte \($0)" } ?? ""
        return "\(authority.rawValue.capitalized) evidence from \(location)\(offset)"
    }
}

@MainActor
private extension AgentLensMessage {
    var contextTitle: String {
        if kind == .skill { return "Skill" }
        if kind == .instruction, role == .user { return "Project" }
        return role.timelineTitle
    }

    var contextIcon: String {
        if kind == .skill { return "book.closed.fill" }
        if kind == .instruction, role == .user { return "doc.text.fill" }
        return role.timelineIcon
    }

    var contextSummary: String {
        if kind == .skill { return "Injected skill catalog and workflow instructions" }
        return switch role {
        case .system: "System instructions"
        case .developer: "Developer instructions"
        case .user: "Injected AGENTS.md project instructions"
        case .assistant: "Assistant context"
        case .reasoning: "Reasoning context"
        }
    }
}
