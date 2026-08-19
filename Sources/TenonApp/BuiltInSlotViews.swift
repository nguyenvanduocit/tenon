// @domain: plugin-contributions, pane-chrome
import AppKit
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore

struct BuiltInSlotContentView: View {
    let slot: WorkspaceSlot
    /// The workspace that owns this pane, handed down the canvas rather than looked up. An
    /// empty pane's launcher offers this workspace's recents and nothing else.
    let workspaceID: UUID
    let workspacePath: URL
    var host: PluginHost
    var pool: SurfacePool
    var agentLens: AgentLensPool
    var webPool: PluginWebSurfacePool
    let agentSuggestions: [AgentLaunchSuggestion]
    /// Per-slot editor state (scroll/selection/unsaved buffer), so a file pane
    /// survives its view being destroyed on a pane switch (T-016).
    var editorStates: EditorPaneStateStore
    /// Where a host-native pane publishes what it wants in the chrome header.
    ///
    /// This is the UP channel, and it is deliberately not the channel the header comes
    /// down. `SpatialSlotCardView.configure` is handed an already-projected `PaneHeader`
    /// VALUE to render; this store is what a content view WRITES into from
    /// `.task`/`.onChange`/`.onAppear` when its own model changes. Neither direction can
    /// serve the other: the card cannot see a content model, and the value it renders is
    /// the projection's answer, which for a plugin pane never comes from this store at all
    /// (`PaneHeaderProjection`).
    var headerStore: PaneHeaderStore
    /// Present for real panes; nil in preview/detached rendering. An empty slot
    /// needs it to fill itself in place.
    var store: WorkspaceStore?
    /// Whether this slot is the active pane — an empty slot only claims the
    /// return-key default action while active.
    var isActive: Bool = false
    var automation: AutomationScheduler
    let automationSchedulesEnabled: Bool
    let automationActions: AutomationPaneActions

    var body: some View {
        switch slot.content {
        case .terminal:
            AgentLensSlotView(
                terminal: pool.surface(
                    for: slot.id,
                    workspacePath: workspacePath
                ).makeView(),
                focusTerminal: { pool.focusSurface(for: slot.id) },
                model: agentLens.model(for: slot.id, terminalPool: pool),
                workspaceRoot: workspacePath,
                // A file cited in agent prose opens the host's own file pane through the
                // typed workspace use case, the same service `workspace.content.open.v1`
                // adapts for plugin, CLI, and agent callers.
                openFile: store.map { store in
                    { @MainActor @Sendable path in
                        store.openContent(.file(path: path))
                    }
                },
                headerStore: headerStore
            )

        case .file(let path):
            // One file-pane content kind, three renderers. The choice is a pure rule so it
            // can be asserted without a window; unrecognised files keep the editor, which
            // is legible for anything.
            switch FilePaneKind.kind(forPath: path) {
            case .image:
                ImageSlotView(path: path)
            case .web:
                WebPreviewSlotView(path: path)
            case .text:
                FileSlotView(
                    path: path,
                    slotID: slot.id,
                    editorStates: editorStates,
                    headerStore: headerStore
                )
            }

        case .changes:
            ChangesPanelView(
                root: workspacePath,
                slotID: slot.id,
                headerStore: headerStore,
                store: store
            )

        case .automation:
            AutomationSlotView(
                slotID: slot.id,
                host: host,
                automation: automation,
                schedulesEnabled: automationSchedulesEnabled,
                actions: automationActions,
                headerStore: headerStore
            )

        case .pluginView(let pluginID, let viewID):
            PluginSlotView(
                pluginID: pluginID,
                viewID: viewID,
                slotID: slot.id,
                host: host,
                webPool: webPool
            )

        case .diff(let request):
            DiffSlotView(
                request: request,
                slotID: slot.id,
                headerStore: headerStore
            )

        case .agentSession(let ref):
            // The same Agent Lens a live pane mounts, reading a transcript instead of a PTY.
            // Where a live pane puts its terminal, this one puts the resume invitation: the
            // pane holds no surface, so there is no terminal to draw and nothing to focus.
            AgentLensSlotView(
                terminal: AnyView(AgentSessionResumeView(
                    ref: ref,
                    offer: AgentSessionResume.offer(for: ref, installed: agentSuggestions),
                    resume: { commandLine in
                        guard let store else { return }
                        // In place, in this order: the pane becomes a terminal, and the
                        // command is queued for the surface that pane is about to build.
                        // `sendTextWhenReady` holds the text until the shell exists, which
                        // is why the conversion does not have to wait for it here.
                        store.setSlotContent(slot.id, .terminal)
                        pool.sendTextWhenReady(commandLine + "\n", to: slot.id)
                    }
                )),
                focusTerminal: {},
                model: agentLens.model(for: slot.id, recording: ref),
                workspaceRoot: workspacePath,
                openFile: store.map { store in
                    { @MainActor @Sendable path in
                        store.openContent(.file(path: path))
                    }
                },
                headerStore: headerStore
            )

        case .empty:
            EmptySlotView(
                slotID: slot.id,
                workspaceID: workspaceID,
                store: store,
                pool: pool,
                agentSuggestions: agentSuggestions,
                isActive: isActive
            )
        }
    }
}

enum SlotPresentation {
    @MainActor
    static func title(
        for slot: WorkspaceSlot,
        workspacePath: URL,
        pool: SurfacePool,
        webPool: PluginWebSurfacePool,
        pluginSnapshots: [PluginSnapshot],
        pluginViewSections: [PluginViewSection],
        webSurfaceTitles: [WebSurfaceKey: String]
    ) -> String {
        if let customTitle = slot.customTitle {
            return customTitle
        }
        switch slot.content {
        case .terminal:
            return pool.titles[slot.id] ?? "Ghostty — shell"
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .changes:
            return "Changes — working tree"
        case .automation:
            return "Automation"
        case .pluginView(let pluginID, let viewID):
            // An instanced view's tab shows the web page title for THIS pane (keyed by
            // its slot id); a singleton view falls back to a viewID-keyed title (T-012).
            // Failing both, the tab takes the title the plugin registered — the raw
            // viewID is a last resort, not the normal answer, or every plugin pane reads
            // like a variable name ("tree", "sessions") instead of "Files", "Sessions".
            let registered = PaneHeaderProjection.section(
                pluginID: pluginID,
                viewID: viewID,
                slotID: slot.id,
                in: pluginViewSections
            )?.title
            var webTitle: String?
            for surfaceID in [slot.id.uuidString, viewID] {
                guard let key = webPool.key(
                    pluginID: pluginID,
                    surfaceID: surfaceID,
                    plugins: pluginSnapshots
                ), let title = webSurfaceTitles[key]
                else {
                    continue
                }
                webTitle = title
                break
            }
            return webTitle ?? registered ?? viewID
        case .diff(let request):
            return request.title
        case .agentSession(let ref):
            return ref.displayName
        case .empty:
            return "Empty slot"
        }
    }

    static func glyph(for content: SlotContent) -> String {
        switch content {
        case .terminal:
            return ">_"
        case .file:
            return "F"
        case .changes:
            return "±"
        case .automation:
            return "↻"
        case .pluginView:
            return "◇"
        case .diff:
            return "Δ"
        case .agentSession:
            // A session that already happened, distinct from the live `>_` it was recorded
            // from: the pane reads a transcript and holds no PTY until someone resumes it.
            return "◷"
        case .empty:
            return "·"
        }
    }
}

// MARK: - Plugins  @domain: plugin-contributions

/// Whether a pane's plugin view has a section to render yet — and if not, whether that is
/// ordinary activation latency or a genuine failure.
///
/// Before this, `PluginSlotView` had exactly one signal: whether `host.pluginViews` already
/// contained this pane's section. A plugin mid-activation (`isLoaded`, no error, no section
/// published yet) and a plugin whose generation had permanently failed looked identical —
/// both showed the same "Plugin view unavailable" error UI, so an operator watching an
/// ordinary load had no way to tell it apart from watching a stuck failure (T-182). Pulled
/// into a pure function, testable without mounting any view.
enum PluginViewAvailability: Equatable {
    case ready
    case activating
    case unavailable(reason: String?)

    static func resolve(
        pluginID: PluginID,
        hasSection: Bool,
        plugins: [PluginSnapshot]
    ) -> PluginViewAvailability {
        if hasSection {
            return .ready
        }
        guard let snapshot = plugins.first(where: { $0.id == pluginID }) else {
            return .unavailable(reason: nil)
        }
        guard snapshot.isEnabled, snapshot.isLoaded, snapshot.error == nil else {
            return .unavailable(reason: snapshot.error)
        }
        return .activating
    }
}

/// Renders a plugin's declarative rows (`TreeRowItem`) as an indented tree. The
/// disclosure chevron, container-accented icon, and dotfile dimming are all driven
/// off the row's own fields — no knowledge of any specific plugin (VISION §6).
///
/// Internal rather than private because `PluginViewSnapshot` mounts this exact view offscreen
/// (T-063). A snapshot that rendered a second opinion of a plugin pane would be worth nothing:
/// the point is to see what the pane shows.
struct PluginSlotView: View {
    let pluginID: PluginID
    let viewID: String
    let slotID: UUID
    var host: PluginHost
    var webPool: PluginWebSurfacePool

    /// This pane's section: the singleton (nil instance) or our own slot's instance.
    private func matches(_ section: PluginViewSection) -> Bool {
        PaneHeaderProjection.matches(
            section,
            pluginID: pluginID,
            viewID: viewID,
            slotID: slotID
        )
    }

    var body: some View {
        // Match the singleton section (instanceID nil) or THIS pane's own instance
        // (instanceID == our slot id) — never another pane's instance (T-012).
        if let section = host.pluginViews.first(where: matches) {
            if let tree = section.body {
                // A rich view-tree: render it natively. A button's action re-uses the
                // same onSelect route a row click takes (one event shape). A `webview`
                // node resolves to the plugin's host-owned surface.
                let node = PluginNodeView(
                    node: tree,
                    onAction: { action, value in
                        Task { @MainActor in
                            _ = await host.invokeViewSelect(
                                pluginID: pluginID,
                                viewID: viewID,
                                instanceID: section.instanceID,
                                action: action,
                                value: value.map(IntentValue.string)
                            )
                        }
                    },
                    webSurface: { surfaceID in
                        guard let key = webPool.key(
                            pluginID: pluginID,
                            surfaceID: surfaceID,
                            host: host
                        ) else {
                            return AnyView(
                                Text("Web surface unavailable")
                                    .font(TenonTheme.utilityFont(size: 10))
                                    .foregroundStyle(TenonTheme.muted)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity
                                    )
                            )
                        }
                        return AnyView(
                            WebSurfaceView(
                                surface: webPool.surface(for: key)
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        )
                    },
                    // A drag belongs to the instance that drew it: the same board open in
                    // two panes is two scopes, and a card picked up in one is refused by
                    // the other (T-012, T-056).
                    dragScope: PluginViewDragScope(
                        pluginID: pluginID,
                        viewID: viewID,
                        instanceID: section.instanceID
                    )
                )
                if Self.containsWebview(tree) {
                    // A web-hosting view (a browser): fill the pane, no scroll or padding,
                    // so the WKWebView takes all the space under the plugin's chrome.
                    node
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(TenonTheme.panel)
                } else {
                    ScrollView {
                        node
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .tenonScrollbarStyle()
                    .scrollIndicators(.hidden, axes: .vertical)
                    .background(TenonTheme.panel)
                }
            } else {
                TreeRowsView(
                    items: section.items,
                    onSelect: { itemID, menuID in
                        Task { @MainActor in
                            _ = await host.invokeViewSelect(
                                pluginID: pluginID,
                                viewID: viewID,
                                instanceID: section.instanceID,
                                itemID: itemID,
                                value: menuID.map(IntentValue.string)
                            )
                        }
                    },
                    onSubmit: { itemID, text in
                        Task { @MainActor in
                            _ = await host.invokeViewSubmit(
                                pluginID: pluginID,
                                viewID: viewID,
                                instanceID: section.instanceID,
                                itemID: itemID,
                                text: text
                            )
                        }
                    }
                )
            }
        } else {
            switch PluginViewAvailability.resolve(
                pluginID: pluginID,
                hasSection: false,
                plugins: host.plugins
            ) {
            case .ready:
                // Unreachable: `hasSection: false` is passed above because the `if let
                // section` branch already handles the `true` case. Kept exhaustive.
                EmptyView()
            case .activating:
                VStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(pluginID.rawValue) · \(viewID)")
                        .font(TenonTheme.utilityFont(size: 9))
                }
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TenonTheme.panel)
            case let .unavailable(reason):
                VStack(spacing: 7) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                    Text("Plugin view unavailable")
                        .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                    Text(reason ?? "\(pluginID.rawValue) · \(viewID)")
                        .font(TenonTheme.utilityFont(size: 9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .foregroundStyle(TenonTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TenonTheme.panel)
            }
        }
    }

    /// True when the view-tree hosts a `webview` node anywhere — a browser-style pane
    /// that should fill rather than scroll.
    static func containsWebview(_ node: PluginViewNode) -> Bool {
        if case .webview = node { return true }
        return children(of: node).contains(where: containsWebview)
    }

    private static func children(of node: PluginViewNode) -> [PluginViewNode] {
        switch node {
        case let .vstack(_, c), let .hstack(_, c): return c
        case let .box(_, _, _, _, c): return c
        case let .card(c): return c
        case let .scroll(_, c): return c
        case let .grid(_, _, c): return c
        case let .field(_, c): return c
        default: return []
        }
    }

}

/// Renders one node of a plugin's declarative view-tree (`PluginViewNode`) as native
/// SwiftUI, recursing into containers. Style tokens resolve against `TenonTheme`, so a
/// plugin's UI tracks the app's colors and light/dark for free (design-plugin-views.md).
/// The host knows nothing about any specific plugin — it paints the vocabulary (VISION §6).
/// A `textfield` node: a local editable buffer that submits on Enter and re-syncs when
/// the plugin pushes a new `value` (e.g. the address bar after a navigation).
///
/// A plugin republishes its whole view for any reason at all, including while someone is
/// typing here, so `EditableFieldDraft` decides who wins: the person while the field is
/// focused, the plugin's value the moment they leave.
private struct PluginTextFieldView: View {
    let value: String
    let placeholder: String
    let onSubmit: (String) -> Void

    @State private var draft = EditableFieldDraft()
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft.text)
            .textFieldStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 12))
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TenonTheme.chromeRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(TenonTheme.line, lineWidth: 1))
            .onSubmit { onSubmit(draft.text) }
            .onAppear { draft = EditableFieldDraft(value: value) }
            .onChange(of: value) { _, newValue in
                draft.externalValueChanged(to: newValue, isFocused: focused)
            }
            .onChange(of: focused) { _, isFocused in
                draft.focusChanged(to: isFocused)
            }
    }
}

struct PluginNodeView: View {
    let node: PluginViewNode
    /// (action id, submitted text). Text is nil for a plain button, the typed value
    /// for a `textfield` submit — one route the JS `onSelect(id, value?)` handles.
    let onAction: (PluginNodeAction, String?) -> Void
    /// Renders a `webview` node's host-owned `WKWebView` surface; nil outside a pane,
    /// where the node degrades to a placeholder.
    var webSurface: ((String) -> AnyView)? = nil
    /// Which plugin view instance this tree belongs to (T-056). A `dragSource` is only
    /// draggable, and a `dropTarget` only admits a drop, inside one scope; nil renders both
    /// as the plain containers they otherwise are.
    var dragScope: PluginViewDragScope? = nil

    var body: some View {
        switch node {
        case let .vstack(spacing, children):
            VStack(alignment: .leading, spacing: spacing) { childViews(children) }
        case let .hstack(spacing, children):
            HStack(spacing: spacing) { childViews(children) }
        case let .box(padding, background, cornerRadius, width, children):
            boxView(padding, background, cornerRadius, width, children)
        case let .card(children):
            VStack(alignment: .leading, spacing: 6) { childViews(children) }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TenonTheme.chromeRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(TenonTheme.line, lineWidth: 1))
        case let .text(value, style, weight, color):
            Text(value)
                .font(Self.font(style, weight))
                .foregroundStyle(ViewTokenPalette.color(color, style: style))
                .textSelection(.enabled)
        case let .badge(value, tint):
            Text(value)
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .foregroundStyle(ViewTokenPalette.color(tint, style: .caption))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ViewTokenPalette.color(tint, style: .caption).opacity(0.14))
                .clipShape(Capsule())
        case let .button(label, action, style):
            Button { onAction(action, nil) } label: {
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                    .foregroundStyle(style == .primary ? TenonTheme.ink : TenonTheme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(style == .primary ? TenonTheme.amber : TenonTheme.chromeRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        if style != .primary {
                            RoundedRectangle(cornerRadius: 5).stroke(TenonTheme.line, lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)
        case let .image(systemName):
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(TenonTheme.muted)
        case .spacer:
            Spacer(minLength: 0)
        case .divider:
            Divider().overlay(TenonTheme.line)
        case let .scroll(axis, children):
            scrollView(axis, children)
        case let .grid(columns, spacing, children):
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: columns),
                alignment: .leading,
                spacing: spacing
            ) { childViews(children) }
        case let .stat(label, value):
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(TenonTheme.interfaceFont(size: 17, weight: .semibold))
                    .foregroundStyle(TenonTheme.text)
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 10))
                    .foregroundStyle(TenonTheme.muted)
            }
        case let .keyValue(label, value, tint):
            HStack(spacing: 8) {
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 11.5))
                    .foregroundStyle(TenonTheme.muted)
                Spacer(minLength: 8)
                Text(value)
                    .font(TenonTheme.interfaceFont(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        tint == .default
                            ? TenonTheme.text
                            : ViewTokenPalette.color(tint, style: .body)
                    )
                    .textSelection(.enabled)
            }
        case let .progress(value, tint):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(
                    tint == .default
                        ? TenonTheme.amber
                        : ViewTokenPalette.color(tint, style: .body)
                )
        case let .field(label, children):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(TenonTheme.interfaceFont(size: 10, weight: .semibold))
                    .foregroundStyle(TenonTheme.muted)
                childViews(children)
            }
        case let .textfield(value, placeholder, action):
            PluginTextFieldView(value: value, placeholder: placeholder) { text in
                onAction(action, text)
            }
        case let .dragSource(payload, children):
            dragSourceView(payload, children)
        case let .dropTarget(action, children):
            PluginDropTargetView(
                action: action,
                scope: dragScope,
                onAction: onAction
            ) { AnyView(wrapped(children)) }
        case let .webview(surfaceID):
            if let webSurface {
                webSurface(surfaceID)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(TenonTheme.chromeRaised)
                    .overlay(
                        Text("web surface")
                            .font(TenonTheme.utilityFont(size: 10))
                            .foregroundStyle(TenonTheme.muted)
                    )
            }
        }
    }

    /// A declared width is exact — `width:` alone, not a max — so the box holds it whether
    /// the pane is wide or narrow, and whether it holds one child or twelve. Without one,
    /// fill the offered width as every box did before.
    private func boxView(
        _ padding: Double,
        _ background: Bool,
        _ cornerRadius: Double,
        _ width: Double?,
        _ children: [PluginViewNode]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) { childViews(children) }
            .padding(padding)
            .frame(width: width.map { CGFloat($0) }, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(background ? TenonTheme.chromeRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// A horizontal scroller must not stretch its content to the viewport, or fixed-width
    /// children would be squeezed back to fit and nothing would ever overflow — which is
    /// the whole point of asking to scroll.
    private func scrollView(
        _ axis: ScrollAxis,
        _ children: [PluginViewNode]
    ) -> some View {
        ScrollView(Self.axisSet(axis)) {
            VStack(alignment: .leading, spacing: 6) { childViews(children) }
                .frame(
                    maxWidth: axis == .vertical ? .infinity : nil,
                    alignment: .topLeading
                )
        }
        .tenonScrollbarStyle()
    }

    /// A drag wrapper adds a gesture and nothing else, so it lays its children out exactly
    /// as they would lay themselves out: leading-aligned, no spacing of its own. Around the
    /// single child both wrappers actually take, this is the child.
    private func wrapped(_ children: [PluginViewNode]) -> some View {
        VStack(alignment: .leading, spacing: 0) { childViews(children) }
    }

    /// The payload rides the drag as plain text carrying its own scope, and the scope is
    /// checked on arrival — see `PluginViewDrag`. An empty or over-long payload leaves the
    /// subtree in place and simply undraggable.
    @ViewBuilder
    private func dragSourceView(
        _ payload: String,
        _ children: [PluginViewNode]
    ) -> some View {
        if let dragScope,
           let encoded = PluginViewDrag.encode(payload: payload, from: dragScope) {
            wrapped(children).draggable(encoded)
        } else {
            wrapped(children)
        }
    }

    /// Siblings are identified by what they are, not by where they sit: a field's draft and a
    /// live web surface have to survive the plugin inserting a row above them.
    @ViewBuilder
    private func childViews(_ children: [PluginViewNode]) -> some View {
        ForEach(IdentifiedPluginViewNode.identify(children)) { child in
            PluginNodeView(
                node: child.node,
                onAction: onAction,
                webSurface: webSurface,
                dragScope: dragScope
            )
        }
    }

    private static func axisSet(_ axis: ScrollAxis) -> Axis.Set {
        switch axis {
        case .horizontal: [.horizontal]
        case .vertical: [.vertical]
        case .both: [.horizontal, .vertical]
        }
    }

    private static func font(_ style: TextStyle, _ weight: FontWeight) -> Font {
        let w = fontWeight(weight)
        switch style {
        case .title: return TenonTheme.interfaceFont(size: 15, weight: w)
        case .body: return TenonTheme.interfaceFont(size: 12, weight: w)
        case .caption: return TenonTheme.interfaceFont(size: 10.5, weight: w)
        case .code: return TenonTheme.utilityFont(size: 11, weight: w)
        }
    }

    private static func fontWeight(_ weight: FontWeight) -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }

}

/// A subtree that accepts a drag from its own view instance and fires the target's action
/// with the dragged payload (T-056).
///
/// The refusal lives in `PluginViewDrag.decode`, which is why this view can answer the
/// drag honestly: a string from another plugin, another instance, or another app decodes to
/// nothing, the drop returns `false`, and no event reaches the generation. What it cannot
/// answer honestly is the *highlight* — SwiftUI decides that from the dragged type alone,
/// so text dragged in from another app still lights the target up before being refused.
private struct PluginDropTargetView<Content: View>: View {
    let action: PluginNodeAction
    let scope: PluginViewDragScope?
    let onAction: (PluginNodeAction, String?) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        if action.stringValue?.isEmpty != false || scope == nil {
            content()
        } else {
            content()
                .dropDestination(for: String.self) { items, _ in
                    accept(items)
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(TenonTheme.amber, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func accept(_ items: [String]) -> Bool {
        guard let scope else { return false }
        for item in items {
            guard let payload = PluginViewDrag.decode(item, into: scope) else { continue }
            onAction(action, payload)
            return true
        }
        return false
    }
}

/// The ONE place a `ColorToken` becomes a `Color`.
///
/// `ColorToken` is the view vocabulary's own token enum, published by plugins and by built-in
/// panes alike, and it is drawn in two places: the body, by `PluginNodeView`, and a pane's
/// chrome header, by `PaneHeaderBar`. Two switches over one token enum is two answers to one
/// question waiting to drift — the same shape invariant 6 forbids for semantics, in paint.
///
/// `style` is the only thing the two callers disagree about, and only for `.default`, which
/// means "whatever unqualified text looks like here": primary in a title or a body line,
/// secondary at caption scale. Header items draw at the pane title's 10 points — caption scale
/// — so they pass `.caption` and an unqualified accessory reads as `muted`, leaving the pane's
/// own name the primary text in that strip.
enum ViewTokenPalette {
    /// `@MainActor` because `.amber` follows the user's live accent preference, which the shell
    /// owns; every caller is a SwiftUI body, which is already main-isolated.
    @MainActor
    static func color(_ token: ColorToken, style: TextStyle) -> Color {
        switch token {
        case .default: return style == .caption ? TenonTheme.muted : TenonTheme.text
        case .text: return TenonTheme.text
        case .muted: return TenonTheme.muted
        case .amber: return TenonTheme.amber
        case .green: return Color(nsColor: NSColor(hex: 0x61C28B))
        case .red: return Color(nsColor: NSColor(hex: 0xED6A5E))
        }
    }
}

/// An empty pane reuses the empty-tab launcher card; its actions fill this exact
/// slot in place via `setSlotContent` rather than adding a new one.
///
/// Internal rather than private so `WorkspaceRecentLauncherTests` can mount it offscreen and
/// check that the workspace it is handed is the workspace whose recents it draws.
struct EmptySlotView: View {
    let slotID: UUID
    /// Received, never derived. `setSlotContent` files the opened view against the workspace
    /// its own event names, so this pane's launcher and the record it produces agree by
    /// construction — including for a pane in a workspace that is not the selected one.
    let workspaceID: UUID
    var store: WorkspaceStore?
    let pool: SurfacePool
    let agentSuggestions: [AgentLaunchSuggestion]
    var isActive: Bool

    var body: some View {
        EmptyStateCard(
            recents: store?.recent?.recent(for: workspaceID) ?? [],
            agentSuggestions: agentSuggestions,
            isActive: isActive,
            onLaunch: { store?.setSlotContent(slotID, $0) },
            onLaunchAgent: { suggestion in
                guard let store else { return }
                _ = AgentLaunchExecutor.run(
                    suggestion,
                    placement: .emptySlot(slotID),
                    workspaceStore: store,
                    terminalPool: pool
                )
            },
            onRunCommand: { commandLine in
                guard let store else { return }
                _ = TerminalCommandLaunch.run(
                    commandLine: commandLine,
                    placement: .emptySlot(slotID),
                    workspaceStore: store,
                    terminalPool: pool
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.ink)
    }
}
