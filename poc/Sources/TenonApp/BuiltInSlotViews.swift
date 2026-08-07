import AppKit
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore

struct BuiltInSlotContentView: View {
    let slot: WorkspaceSlot
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

        case .docs:
            DocsSlotView(
                root: workspacePath,
                slotID: slot.id,
                headerStore: headerStore
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

        case .empty:
            EmptySlotView(
                slotID: slot.id,
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
        switch slot.content {
        case .terminal:
            return pool.titles[slot.id] ?? "Ghostty — shell"
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .changes:
            return "Changes — working tree"
        case .docs:
            // The kind, never the file. Which document a docs pane shows is decided by walking
            // a candidate list against the filesystem inside `DocsModel`, and this function
            // sees only `SlotContent`, which carries no filename — so any file named here
            // would be a guess that goes wrong the moment the first candidate is absent. The
            // pane publishes the real name into its chrome header (`DocsPaneHeader`).
            return "Docs"
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
        case .docs:
            return "#"
        case .automation:
            return "↻"
        case .pluginView:
            return "◇"
        case .diff:
            return "Δ"
        case .empty:
            return "·"
        }
    }
}

// MARK: - Docs

@MainActor
@Observable
private final class DocsModel {
    private(set) var content = ""
    private(set) var error: String?
    private(set) var isLoading = false
    /// The workspace-relative name of the file `content` came from — the candidate that won
    /// the walk below, not a guess. It is published into the chrome header because this object
    /// is the only thing in the process that knows the answer.
    private(set) var document: String?

    private var path: URL?
    private var task: Task<Void, Never>?

    func load(_ workspacePath: URL) {
        let standardized = workspacePath.standardizedFileURL
        guard path != standardized else { return }
        path = standardized
        task?.cancel()
        content = ""
        error = nil
        document = nil
        isLoading = true

        task = Task { [weak self] in
            do {
                // The winning candidate comes back WITH the text rather than being recomputed
                // for display: two walks of the same list against a filesystem that can change
                // between them is two answers to one question.
                let result = try await Task.detached(priority: .userInitiated) {
                    let candidates = ["README.md", "VISION.md", "docs/README.md"]
                    guard let candidate = candidates
                        .first(where: {
                            FileManager.default.fileExists(
                                atPath: standardized.appendingPathComponent($0).path
                            )
                        })
                    else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let url = standardized.appendingPathComponent(candidate)
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 600_000) ?? Data()
                    return (
                        name: candidate,
                        text: String(data: data, encoding: .utf8)
                            ?? "Document is not UTF-8 text."
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.content = result.text
                self?.document = result.name
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                self?.error = "No README or workspace document found."
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// What the docs pane contributes to the ONE chrome header the card draws.
///
/// The document's name is here rather than in `SlotPresentation.title` because of what that
/// function *is*: a pure map from `SlotContent` to a string, and `SlotContent.docs` carries no
/// filename. Which document loaded is decided inside `DocsModel`, by walking a candidate list
/// against the filesystem, and that answer lives in a `@State` model in the content view's own
/// SwiftUI graph — the graph `PaneHeaderStore` exists to carry values OUT of. So the title
/// names the KIND ("Docs") and this names the INSTANCE, which is the only division under which
/// neither can be wrong.
///
/// That is not the restatement the second header row was doing. The strip this replaces printed
/// `README.md` under a chrome header that had already printed `Docs — README`; here the chrome
/// says one thing, the header says the other, and only one of them can know the filename.
///
/// Pure and headless for the same reason `DiffPaneHeader` is: the rule is arithmetic over the
/// pane's state, and nothing about it needs a window to be true.
enum DocsPaneHeader {
    /// - Parameter document: the workspace-relative name of the file the pane actually loaded,
    ///   or `nil` before the read lands and after one that found nothing.
    static func header(document: String?, isLoading: Bool) -> PaneHeader {
        PaneHeader(
            leading: document.map {
                [
                    // `.head`, because a candidate can be a path (`docs/README.md`) and the
                    // filename is the end that carries the meaning.
                    .label(
                        id: "document",
                        text: $0,
                        weight: .semibold,
                        color: .text,
                        truncation: .head,
                        tooltip: nil
                    ),
                ]
            } ?? [],
            trailing: isLoading ? [.spinner(id: "loading")] : []
        )
    }
}

private struct DocsSlotView: View {
    let root: URL
    /// Which pane this is, and where its header contribution goes UP — the projected value
    /// comes back DOWN through `SpatialSlotCardView.configure`.
    let slotID: UUID
    let headerStore: PaneHeaderStore
    @State private var model = DocsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                Text(model.content)
                    .font(TenonTheme.utilityFont(size: 10))
                    .foregroundStyle(TenonTheme.text.opacity(0.86))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if let error = model.error {
                Text(error)
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(TenonTheme.muted)
                    .padding(10)
            }
        }
        .background(TenonTheme.panel)
        .onAppear { model.load(root) }
        .onChange(of: root) { _, newRoot in model.load(newRoot) }
        // Published from `.onChange`, never from `body`. `initial: true` covers the first
        // frame, where the model is already loading and the pane has something to say.
        .onChange(
            of: DocsPaneHeader.header(document: model.document, isLoading: model.isLoading),
            initial: true
        ) { _, next in
            headerStore.publish(next, for: slotID)
        }
        .onDisappear {
            model.cancel()
            headerStore.clear(for: slotID)
        }
    }
}

// MARK: - Plugins

/// Renders a plugin's declarative rows (`PluginRowItem`) as an indented tree. The
/// disclosure chevron, container-accented icon, and dotfile dimming are all driven
/// off the row's own fields — no knowledge of any specific plugin (VISION §6).
private struct PluginSlotView: View {
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
                                itemID: action,
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
                    }
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
                    .scrollIndicators(.hidden, axes: .vertical)
                    .background(TenonTheme.panel)
                }
            } else {
                PluginRowsView(
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
            VStack(spacing: 7) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.title2)
                Text("Plugin view unavailable")
                    .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                Text("\(pluginID.rawValue) · \(viewID)")
                    .font(TenonTheme.utilityFont(size: 9))
            }
            .foregroundStyle(TenonTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.panel)
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
private struct PluginTextFieldView: View {
    let value: String
    let placeholder: String
    let onSubmit: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TenonTheme.chromeRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(TenonTheme.line, lineWidth: 1))
            .onSubmit { onSubmit(draft) }
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in draft = newValue }
    }
}

struct PluginNodeView: View {
    let node: PluginViewNode
    /// (action id, submitted text). Text is nil for a plain button, the typed value
    /// for a `textfield` submit — one route the JS `onSelect(id, value?)` handles.
    let onAction: (String, String?) -> Void
    /// Renders a `webview` node's host-owned `WKWebView` surface; nil outside a pane,
    /// where the node degrades to a placeholder.
    var webSurface: ((String) -> AnyView)? = nil

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
    }

    @ViewBuilder
    private func childViews(_ children: [PluginViewNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            PluginNodeView(node: child, onAction: onAction, webSurface: webSurface)
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
private struct EmptySlotView: View {
    let slotID: UUID
    var store: WorkspaceStore?
    let pool: SurfacePool
    let agentSuggestions: [AgentLaunchSuggestion]
    var isActive: Bool

    var body: some View {
        EmptyStateCard(
            title: "This panel is empty",
            subtitle: "No terminal running yet",
            recents: store?.recent?.recent ?? [],
            agentSuggestions: agentSuggestions,
            isDefaultAction: isActive,
            onLaunch: { store?.setSlotContent(slotID, $0) },
            onLaunchAgent: { suggestion in
                guard let store else { return }
                _ = AgentLaunchExecutor.run(
                    suggestion,
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
