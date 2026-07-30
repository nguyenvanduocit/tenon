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
    var webPool: PluginWebSurfacePool
    /// Present for real panes; nil in preview/detached rendering. An empty slot
    /// needs it to fill itself in place.
    var store: WorkspaceStore?
    /// Whether this slot is the active pane — an empty slot only claims the
    /// return-key default action while active.
    var isActive: Bool = false

    var body: some View {
        switch slot.content {
        case .terminal:
            pool.surface(
                for: slot.id,
                workspacePath: workspacePath
            ).makeView()

        case .file(let path):
            FileSlotView(path: path)

        case .changes:
            ChangesPanelView(root: workspacePath, store: store)

        case .docs:
            DocsSlotView(root: workspacePath)

        case .pluginView(let pluginID, let viewID):
            PluginSlotView(
                pluginID: pluginID,
                viewID: viewID,
                slotID: slot.id,
                host: host,
                webPool: webPool
            )

        case .diff(let request):
            DiffSlotView(request: request)

        case .empty:
            EmptySlotView(slotID: slot.id, store: store, isActive: isActive)
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
            return "Docs — README"
        case .pluginView(let pluginID, let viewID):
            // An instanced view's tab shows the web page title for THIS pane (keyed by
            // its slot id); a singleton view falls back to a viewID-keyed title (T-012).
            // Failing both, the tab takes the title the plugin registered — the raw
            // viewID is a last resort, not the normal answer, or every plugin pane reads
            // like a variable name ("tree", "sessions") instead of "Files", "Sessions".
            let registered = pluginViewSections.first {
                $0.pluginID == pluginID && $0.viewID == viewID
                    && ($0.instanceID == nil || $0.instanceID == slot.id.uuidString)
            }?.title
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
        case .pluginView:
            return "◇"
        case .diff:
            return "Δ"
        case .empty:
            return "·"
        }
    }
}

// MARK: - Git changes

@MainActor
@Observable
private final class GitChangesModel {
    private(set) var status = ""
    private(set) var diff = ""
    private(set) var error: String?
    private(set) var isLoading = false

    private var path: URL?
    private var task: Task<Void, Never>?

    func load(_ path: URL) {
        let standardized = path.standardizedFileURL
        guard self.path != standardized else { return }
        self.path = standardized
        task?.cancel()
        status = ""
        diff = ""
        error = nil
        isLoading = true

        task = Task { [weak self] in
            do {
                async let status = CancellableProcess.run(
                    executable: "/usr/bin/git",
                    arguments: ["status", "--short", "--branch"],
                    directory: standardized,
                    outputLimit: 120_000
                )
                async let diff = CancellableProcess.run(
                    executable: "/usr/bin/git",
                    arguments: ["diff", "--no-ext-diff", "--unified=3", "--"],
                    directory: standardized,
                    outputLimit: 500_000
                )
                let values = try await (status, diff)
                guard !Task.isCancelled else { return }
                self?.status = values.0
                self?.diff = values.1
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                self?.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

private struct ChangesSlotView: View {
    let root: URL
    @State private var model = GitChangesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKING TREE")
                    .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                    .tracking(0.8)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(TenonTheme.chromeRaised)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(model.status.isEmpty ? "Clean working tree" : model.status)
                        .foregroundStyle(TenonTheme.text)
                    if !model.diff.isEmpty {
                        Divider().overlay(TenonTheme.line)
                        ForEach(
                            Array(model.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(String(line))
                                .foregroundStyle(diffColor(for: line))
                        }
                    }
                }
                .font(TenonTheme.utilityFont(size: 9))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if let error = model.error {
                Text(error)
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .padding(8)
            }
        }
        .background(TenonTheme.panel)
        .onAppear { model.load(root) }
        .onChange(of: root) { _, newRoot in model.load(newRoot) }
        .onDisappear { model.cancel() }
    }

    private func diffColor(for line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return Color(nsColor: NSColor(hex: 0x61C28B))
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return Color(nsColor: NSColor(hex: 0xED6A5E))
        }
        if line.hasPrefix("@@") {
            return TenonTheme.amber
        }
        return TenonTheme.muted
    }
}

// MARK: - Docs

@MainActor
@Observable
private final class DocsModel {
    private(set) var content = ""
    private(set) var sourceName = "README.md"
    private(set) var error: String?
    private(set) var isLoading = false

    private var path: URL?
    private var task: Task<Void, Never>?

    func load(_ workspacePath: URL) {
        let standardized = workspacePath.standardizedFileURL
        guard path != standardized else { return }
        path = standardized
        task?.cancel()
        content = ""
        error = nil
        isLoading = true

        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let candidates = ["README.md", "VISION.md", "docs/README.md"]
                    guard let url = candidates
                        .map({ standardized.appendingPathComponent($0) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
                    else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 600_000) ?? Data()
                    return (
                        url.lastPathComponent,
                        String(data: data, encoding: .utf8) ?? "Document is not UTF-8 text."
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.sourceName = result.0
                self?.content = result.1
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

private struct DocsSlotView: View {
    let root: URL
    @State private var model = DocsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.sourceName)
                    .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(TenonTheme.chromeRaised)

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
        .onDisappear { model.cancel() }
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
        guard section.pluginID == pluginID,
              section.viewID == viewID
        else {
            return false
        }
        return section.instanceID == nil || section.instanceID == slotID.uuidString
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
                    .background(TenonTheme.panel)
                }
            } else {
                PluginRowsView(
                    title: section.title,
                    subtitle: section.subtitle,
                    actions: section.actions,
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
        case let .box(_, _, _, c): return c
        case let .card(c): return c
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

/// A `browserBar` node: a native browser toolbar the host paints pretty — SF Symbol
/// back/forward/reload buttons and a Safari-style address field over a chrome material
/// with a hairline bottom divider. It owns only presentation: every control routes to
/// the plugin's `onSelect` through the fixed action ids `back`/`forward`/`reload`/`go`,
/// so the plugin keeps all navigation logic and URL resolution (invariants 2 & 6). The
/// address field mirrors the live URL the plugin pushes and re-syncs on redirects and
/// link clicks, but never clobbers what the user is mid-typing.
private struct BrowserBarView: View {
    let url: String
    let placeholder: String
    let onAction: (String, String?) -> Void

    @State private var draft: String = ""
    @State private var hovered: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            navButton("chevron.left", "back")
            navButton("chevron.right", "forward")
            navButton("arrow.clockwise", "reload")
            addressField
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(TenonTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TenonTheme.line).frame(height: 1)
        }
    }

    private func navButton(_ symbol: String, _ action: String) -> some View {
        let isHovering = hovered == action
        return Button { onAction(action, nil) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? TenonTheme.text : TenonTheme.muted)
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? TenonTheme.text.opacity(0.07) : Color.clear)
        )
        .onHover { hovering in
            if hovering { hovered = action }
            else if hovered == action { hovered = nil }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TenonTheme.muted.opacity(0.7))
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(TenonTheme.interfaceFont(size: 12))
                .foregroundStyle(TenonTheme.text)
                .focused($addressFocused)
                .onSubmit { onAction("go", draft) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(TenonTheme.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(addressFocused ? TenonTheme.amber.opacity(0.55) : TenonTheme.line, lineWidth: 1)
        )
        .onAppear { draft = url }
        // Mirror real navigations (redirects, link clicks) into the field, but leave the
        // user's in-progress typing alone.
        .onChange(of: url) { _, newValue in if !addressFocused { draft = newValue } }
    }
}

private struct PluginNodeView: View {
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
        case let .box(padding, background, cornerRadius, children):
            VStack(alignment: .leading, spacing: 6) { childViews(children) }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background ? TenonTheme.chromeRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
                .foregroundStyle(Self.color(color, style: style))
                .textSelection(.enabled)
        case let .badge(value, tint):
            Text(value)
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .foregroundStyle(Self.color(tint, style: .caption))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Self.color(tint, style: .caption).opacity(0.14))
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
                    .foregroundStyle(tint == .default ? TenonTheme.text : Self.color(tint, style: .body))
                    .textSelection(.enabled)
            }
        case let .progress(value, tint):
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(tint == .default ? TenonTheme.amber : Self.color(tint, style: .body))
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
        case let .browserBar(url, placeholder):
            BrowserBarView(url: url, placeholder: placeholder, onAction: onAction)
        }
    }

    @ViewBuilder
    private func childViews(_ children: [PluginViewNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            PluginNodeView(node: child, onAction: onAction, webSurface: webSurface)
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

    private static func color(_ token: ColorToken, style: TextStyle) -> Color {
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
    var isActive: Bool

    var body: some View {
        EmptyStateCard(
            title: "This panel is empty",
            subtitle: "No terminal running yet",
            recents: store?.recent?.recent ?? [],
            isDefaultAction: isActive,
            onLaunch: { store?.setSlotContent(slotID, $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.ink)
    }
}

// MARK: - Cancel-aware process capture

private enum CancellableProcess {
    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        outputLimit: Int
    ) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        let buffer = ProcessOutputBuffer(limit: outputLimit)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                buffer.append(data)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    let text = buffer.string
                    if completed.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "Tenon.Process",
                            code: Int(completed.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    text.isEmpty ? "Command failed." : text,
                            ]
                        ))
                    }
                }
                do {
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        guard remaining > 0 else { return }
        data.append(chunk.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? "Command returned non-UTF-8 output."
    }
}
