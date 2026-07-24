import AppKit
import Observation
import SwiftUI
import TenonCore
import WebKit

struct BuiltInSlotContentView: View {
    let slot: WorkspaceSlot
    let workspacePath: URL
    var host: PluginHost
    var pool: SurfacePool

    var body: some View {
        switch slot.content {
        case .terminal:
            pool.surface(
                for: slot.id,
                workspacePath: workspacePath
            ).makeView()

        case .files:
            FilesSlotView(root: workspacePath)

        case .changes:
            ChangesSlotView(root: workspacePath)

        case .docs:
            DocsSlotView(root: workspacePath)

        case .browser(let url):
            WebBrowserSlotView(slotID: slot.id, seedURL: url, pool: pool)

        case .pluginView(let plugin, let viewID):
            PluginSlotView(plugin: plugin, viewID: viewID, host: host)

        case .empty:
            EmptySlotView()
        }
    }
}

enum SlotPresentation {
    static func title(
        for slot: WorkspaceSlot,
        workspacePath: URL,
        pool: SurfacePool
    ) -> String {
        switch slot.content {
        case .terminal:
            return pool.titles[slot.id] ?? "Ghostty — shell"
        case .files:
            return "Files — \(workspacePath.lastPathComponent)"
        case .changes:
            return "Changes — working tree"
        case .docs:
            return "Docs — README"
        case .browser(let url):
            return pool.titles[slot.id] ?? "Browser — \(url.host ?? url.absoluteString)"
        case .pluginView(_, let viewID):
            return viewID
        case .empty:
            return "Empty slot"
        }
    }

    static func glyph(for content: SlotContent) -> String {
        switch content {
        case .terminal:
            return ">_"
        case .files:
            return "F"
        case .changes:
            return "±"
        case .docs:
            return "#"
        case .browser:
            return "◎"
        case .pluginView:
            return "◇"
        case .empty:
            return "·"
        }
    }
}

// MARK: - Files

private struct FileBrowserEntry: Equatable, Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
}

@MainActor
@Observable
private final class FileBrowserModel {
    private(set) var workspaceRoot: URL?
    private(set) var currentPath: URL?
    private(set) var entries: [FileBrowserEntry] = []
    private(set) var selectedFileName: String?
    private(set) var preview = ""
    private(set) var error: String?
    private(set) var isLoading = false

    private var directoryTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    func loadWorkspace(_ path: URL) {
        let standardized = path.standardizedFileURL
        guard workspaceRoot != standardized else { return }
        workspaceRoot = standardized
        loadDirectory(standardized)
    }

    func loadDirectory(_ path: URL) {
        directoryTask?.cancel()
        previewTask?.cancel()
        currentPath = path.standardizedFileURL
        selectedFileName = nil
        preview = ""
        error = nil
        isLoading = true

        directoryTask = Task { [weak self] in
            do {
                let rows = try await Task.detached(priority: .userInitiated) {
                    let keys: [URLResourceKey] = [
                        .isDirectoryKey,
                        .isHiddenKey,
                        .nameKey,
                    ]
                    return try FileManager.default
                        .contentsOfDirectory(
                            at: path,
                            includingPropertiesForKeys: keys,
                            options: [.skipsHiddenFiles]
                        )
                        .map { url -> FileBrowserEntry in
                            let values = try url.resourceValues(forKeys: Set(keys))
                            return FileBrowserEntry(
                                url: url,
                                isDirectory: values.isDirectory == true
                            )
                        }
                        .sorted {
                            if $0.isDirectory != $1.isDirectory {
                                return $0.isDirectory && !$1.isDirectory
                            }
                            return $0.url.lastPathComponent.localizedStandardCompare(
                                $1.url.lastPathComponent
                            ) == .orderedAscending
                        }
                }.value
                guard !Task.isCancelled else { return }
                self?.entries = rows
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.entries = []
                self?.isLoading = false
                self?.error = error.localizedDescription
            }
        }
    }

    func open(_ entry: FileBrowserEntry) {
        if entry.isDirectory {
            loadDirectory(entry.url)
            return
        }

        previewTask?.cancel()
        selectedFileName = entry.url.lastPathComponent
        preview = ""
        error = nil
        previewTask = Task { [weak self] in
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: entry.url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 256_000) ?? Data()
                    return String(data: data, encoding: .utf8)
                        ?? "Binary file — preview unavailable."
                }.value
                guard !Task.isCancelled else { return }
                self?.preview = text
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
        }
    }

    func goUp() {
        guard let workspaceRoot,
              let currentPath,
              currentPath.standardizedFileURL != workspaceRoot.standardizedFileURL
        else { return }
        let parent = currentPath.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(workspaceRoot.path) else { return }
        loadDirectory(parent)
    }

    func cancel() {
        directoryTask?.cancel()
        previewTask?.cancel()
    }
}

private struct FilesSlotView: View {
    let root: URL
    @State private var model = FileBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    model.goUp()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Parent folder")

                Text(model.currentPath?.path.replacingOccurrences(
                    of: root.path,
                    with: root.lastPathComponent
                ) ?? root.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .font(TenonTheme.utilityFont(size: 9))
            .foregroundStyle(TenonTheme.muted)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(TenonTheme.chromeRaised)

            List(model.entries) { entry in
                Button {
                    model.open(entry)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(
                                entry.isDirectory ? TenonTheme.amber.opacity(0.78) : TenonTheme.muted
                            )
                            .frame(width: 13)
                        Text(entry.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(TenonTheme.utilityFont(size: 10))

            if let selected = model.selectedFileName {
                Divider().overlay(TenonTheme.line)
                VStack(alignment: .leading, spacing: 5) {
                    Text(selected)
                        .font(TenonTheme.interfaceFont(size: 10, weight: .semibold))
                        .foregroundStyle(TenonTheme.text)
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.preview)
                            .font(TenonTheme.utilityFont(size: 9))
                            .foregroundStyle(TenonTheme.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(8)
                .frame(maxHeight: 160)
            }

            if let error = model.error {
                Text(error)
                    .font(TenonTheme.utilityFont(size: 9))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(TenonTheme.panel)
        .onAppear { model.loadWorkspace(root) }
        .onChange(of: root) { _, newRoot in model.loadWorkspace(newRoot) }
        .onDisappear { model.cancel() }
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

// MARK: - Web and plugins

@MainActor
@Observable
private final class WebBrowserModel: NSObject, WKUIDelegate {
    let webView: WKWebView

    var addressText = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress = 0.0
    var isReaderMode = false

    private let slotID: UUID
    private let config: BrowserConfigStore
    private let pool: SurfacePool
    private var observations: [NSKeyValueObservation] = []
    private var readerSourceURL: URL?

    init(slotID: UUID, seedURL: URL, config: BrowserConfigStore, pool: SurfacePool) {
        self.slotID = slotID
        self.config = config
        self.pool = pool
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()

        webView.underPageBackgroundColor = .clear
        webView.uiDelegate = self
        wireObservations()

        load(config.lastURL(forSlot: slotID) ?? seedURL)
    }

    /// Every navigation goes through here so the current user-agent config is applied
    /// on each load — change the UA in settings, reload, and it takes effect.
    private func load(_ url: URL) {
        webView.customUserAgent = config.userAgent.customUAString
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    private func wireObservations() {
        observations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.isLoading = value }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let newURL = change.newValue, let url = newURL else { return }
                Task { @MainActor in self?.didNavigate(to: url) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishTitle() }
            },
        ]
    }

    private func didNavigate(to url: URL) {
        // A real navigation (link click, redirect) leaves reader mode behind.
        if isReaderMode, url != readerSourceURL {
            isReaderMode = false
            readerSourceURL = nil
        }
        addressText = url.absoluteString
        if !isReaderMode {
            config.rememberURL(url, forSlot: slotID)
        }
        publishTitle()
    }

    private func publishTitle() {
        let pageTitle = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if !pageTitle.isEmpty {
            title = isReaderMode ? "Reader — \(pageTitle)" : pageTitle
        } else {
            title = webView.url?.host ?? "Browser"
        }
        pool.setTitle(title, for: slotID)
    }

    func submitAddress() {
        guard let url = BrowserAddress.resolve(addressText, searchTemplate: config.searchTemplate) else { return }
        load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.customUserAgent = config.userAgent.customUAString
            webView.reload()
        }
    }

    func goHome() {
        load(config.homeURL)
    }

    // MARK: - Reader view

    /// Toggle a distraction-free rendering of the current page's main content.
    func toggleReader() {
        if isReaderMode {
            isReaderMode = false
            let source = readerSourceURL
            readerSourceURL = nil
            publishTitle()
            if let source { load(source) }
            return
        }

        guard let source = webView.url, source.scheme?.hasPrefix("http") == true else { return }
        readerSourceURL = source
        webView.evaluateJavaScript(Self.readerExtractionScript) { [weak self] result, _ in
            Task { @MainActor in self?.presentReader(from: result, source: source) }
        }
    }

    private func presentReader(from result: Any?, source: URL) {
        guard
            let json = result as? String,
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let bodyHTML = parsed["html"] as? String,
            !bodyHTML.isEmpty
        else {
            readerSourceURL = nil
            return
        }
        isReaderMode = true
        webView.loadHTMLString(
            Self.readerDocument(
                title: (parsed["title"] as? String) ?? "",
                byline: (parsed["byline"] as? String) ?? "",
                bodyHTML: bodyHTML
            ),
            baseURL: source
        )
        publishTitle()
    }

    /// Heuristic extraction: score candidate containers by paragraph text, clone the
    /// winner, strip chrome, absolutize URLs, and hand back a JSON payload.
    private static let readerExtractionScript = """
    (function () {
      var pool = Array.from(document.querySelectorAll('article, main, [role=main]'));
      if (pool.length === 0) pool = Array.from(document.querySelectorAll('div, section'));
      var best = null, bestScore = 0;
      pool.forEach(function (el) {
        var score = 0;
        el.querySelectorAll('p').forEach(function (p) {
          var l = (p.innerText || '').trim().length;
          if (l > 25) score += l;
        });
        if (el.tagName === 'ARTICLE' || el.tagName === 'MAIN') score *= 1.5;
        if (score > bestScore) { bestScore = score; best = el; }
      });
      if (!best) best = document.body;
      var clone = best.cloneNode(true);
      clone.querySelectorAll('script,style,noscript,nav,aside,header,footer,form,iframe,button,svg,object,embed,[aria-hidden=true],[role=navigation],[role=complementary]')
        .forEach(function (n) { n.remove(); });
      clone.querySelectorAll('img').forEach(function (img) {
        try { img.src = img.src; } catch (e) {}
        img.removeAttribute('srcset'); img.removeAttribute('loading');
      });
      clone.querySelectorAll('a').forEach(function (a) { try { a.href = a.href; } catch (e) {} });
      var h1 = document.querySelector('h1');
      var title = (h1 && h1.innerText) || document.title || '';
      var bl = document.querySelector('[rel=author], .byline, .author, [itemprop=author]');
      var byline = bl ? (bl.innerText || '').trim() : '';
      return JSON.stringify({ title: title.trim(), byline: byline, html: clone.innerHTML });
    })();
    """

    private static func readerDocument(title: String, byline: String, bodyHTML: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let heading = title.isEmpty ? "" : "<h1>\(esc(title))</h1>"
        let bylineRow = byline.isEmpty ? "" : "<p class=\"byline\">\(esc(byline))</p>"
        let docTitle = title.isEmpty ? "Reader" : esc(title)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(docTitle)</title>
        <style>
          :root { color-scheme: light dark; }
          img, pre, table { max-width: 100%; }
          body {
            margin: 0 auto; padding: 48px 24px 96px; max-width: 44rem;
            font: 18px/1.7 -apple-system, ui-serif, Georgia, serif;
            color: #1a1a1a; background: #faf9f7;
          }
          h1 { font-size: 1.9em; line-height: 1.2; margin: 0 0 .15em; font-family: -apple-system, system-ui, sans-serif; }
          .byline { color: #6a6a6a; font-size: .8em; margin: 0 0 2em; font-family: -apple-system, system-ui, sans-serif; }
          p { margin: 0 0 1.15em; }
          img { height: auto; border-radius: 6px; display: block; margin: 1.5em auto; }
          a { color: #b5651d; }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em; }
          pre { background: rgba(0,0,0,.05); padding: 12px 14px; border-radius: 6px; overflow-x: auto; }
          blockquote { margin: 1.2em 0; padding-left: 1em; border-left: 3px solid rgba(0,0,0,.18); color: #555; }
          h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; margin: 1.6em 0 .5em; }
          hr { border: none; border-top: 1px solid rgba(0,0,0,.12); margin: 2em 0; }
          @media (prefers-color-scheme: dark) {
            body { color: #d8d4cc; background: #1c1b19; }
            .byline { color: #9a948a; }
            a { color: #e0a458; }
            pre { background: rgba(255,255,255,.06); }
            blockquote { border-left-color: rgba(255,255,255,.2); color: #b0aa9e; }
            hr { border-top-color: rgba(255,255,255,.12); }
          }
        </style></head>
        <body>\(heading)\(bylineRow)\(bodyHTML)</body></html>
        """
    }

    // Route target="_blank" / window.open into the same pane — a basic browser has one view.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private struct WebContentView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Void) {
        nsView.stopLoading()
    }
}

private struct WebBrowserSlotView: View {
    @State private var model: WebBrowserModel
    @State private var showConfig = false

    init(slotID: UUID, seedURL: URL, pool: SurfacePool) {
        _model = State(
            initialValue: WebBrowserModel(slotID: slotID, seedURL: seedURL, config: .shared, pool: pool)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            progressBar
            WebContentView(webView: model.webView)
        }
        .background(TenonTheme.panel)
        .popover(isPresented: $showConfig, arrowEdge: .top) {
            BrowserConfigPopover().frame(width: 264)
        }
    }

    private var chrome: some View {
        HStack(spacing: 5) {
            navButton("chevron.left", enabled: model.canGoBack, help: "Back") { model.goBack() }
            navButton("chevron.right", enabled: model.canGoForward, help: "Forward") { model.goForward() }
            navButton(
                model.isLoading ? "xmark" : "arrow.clockwise",
                enabled: true,
                help: model.isLoading ? "Stop" : "Reload"
            ) { model.reloadOrStop() }
            navButton("house", enabled: true, help: "Home") { model.goHome() }
            navButton(
                "book",
                enabled: true,
                help: model.isReaderMode ? "Exit reader view" : "Reader view",
                active: model.isReaderMode
            ) { model.toggleReader() }

            TextField("Search or enter address", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(TenonTheme.utilityFont(size: 10))
                .foregroundStyle(TenonTheme.text)
                .onSubmit { model.submitAddress() }
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(TenonTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(TenonTheme.line, lineWidth: 1)
                )

            navButton("gearshape", enabled: true, help: "Browser settings") { showConfig = true }
        }
        .padding(.horizontal, 8)
        .frame(height: 31)
        .background(TenonTheme.chromeRaised)
    }

    private var progressBar: some View {
        ProgressView(value: model.progress)
            .progressViewStyle(.linear)
            .tint(TenonTheme.amber)
            .opacity(model.isLoading && model.progress > 0 && model.progress < 1 ? 1 : 0)
            .frame(height: 2)
    }

    private func navButton(
        _ symbol: String,
        enabled: Bool,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(
            active
                ? TenonTheme.amber
                : (enabled ? TenonTheme.text.opacity(0.82) : TenonTheme.muted.opacity(0.4))
        )
        .help(help)
    }
}

private struct BrowserConfigPopover: View {
    @Bindable private var config = BrowserConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BROWSER")
                .font(TenonTheme.utilityFont(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TenonTheme.muted)

            field("Home page") {
                TextField("https://…", text: $config.homeURLString)
                    .textFieldStyle(.roundedBorder)
                    .font(TenonTheme.utilityFont(size: 10))
            }

            field("Search engine") {
                Picker("", selection: $config.searchEngineID) {
                    ForEach(BrowserSearchEngine.all) { engine in
                        Text(engine.label).tag(engine.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            field("User agent") {
                Picker("", selection: $config.userAgent) {
                    ForEach(BrowserUserAgent.allCases) { agent in
                        Text(agent.label).tag(agent)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(isOn: $config.remembersLastURL) {
                Text("Remember last page per pane")
                    .font(TenonTheme.utilityFont(size: 10))
                    .foregroundStyle(TenonTheme.text)
            }
            .toggleStyle(.checkbox)
        }
        .padding(14)
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(TenonTheme.utilityFont(size: 9))
                .foregroundStyle(TenonTheme.muted)
            content()
        }
    }
}

private struct PluginSlotView: View {
    let plugin: String
    let viewID: String
    var host: PluginHost

    var body: some View {
        if let section = host.pluginViews.first(where: {
            $0.pluginName == plugin && $0.viewID == viewID
        }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(section.items) { item in
                        Button {
                            host.invokeViewSelect(
                                pluginName: plugin,
                                viewID: viewID,
                                itemID: item.id
                            )
                        } label: {
                            HStack(spacing: 6) {
                                if let icon = item.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 10))
                                        .foregroundStyle(TenonTheme.muted)
                                }
                                Text(item.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(item.depth) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(TenonTheme.utilityFont(size: 10))
                        .foregroundStyle(TenonTheme.text.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(TenonTheme.panel)
        } else {
            VStack(spacing: 7) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.title2)
                Text("Plugin view unavailable")
                    .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                Text("\(plugin) · \(viewID)")
                    .font(TenonTheme.utilityFont(size: 9))
            }
            .foregroundStyle(TenonTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.panel)
        }
    }
}

private struct EmptySlotView: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "square.dashed")
                .font(.title2)
            Text("Empty slot")
                .font(TenonTheme.utilityFont(size: 10))
        }
        .foregroundStyle(TenonTheme.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.panel)
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
