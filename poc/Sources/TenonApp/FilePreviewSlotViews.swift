import AppKit
import SwiftUI
import TenonCore
import WebKit

/// A file pane showing a picture.
///
/// Decoding is the only thing that can fail here, and it fails often enough to design for:
/// a truncated download, a `.png` that is really HTML, a format this macOS does not know.
/// The pane says so and stays a pane — the host is not brought down by a bad file, and the
/// path stays visible so the human can see *which* file it was.
struct ImageSlotView: View {
    let path: String

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                unreadable
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.panel)
        .task(id: path) {
            // Off the main actor: a large image decodes for long enough to drop frames,
            // and a pane appearing is not a reason for the window to stutter.
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: path)
            }.value
            image = loaded
            failed = loaded == nil
        }
    }

    private var unreadable: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 20))
                .foregroundStyle(TenonTheme.muted)
            Text("Cannot read this image")
                .font(TenonTheme.interfaceFont(size: 11, weight: .medium))
                .foregroundStyle(TenonTheme.muted)
            Text((path as NSString).lastPathComponent)
                .font(TenonTheme.interfaceFont(size: 10, weight: .regular))
                .foregroundStyle(TenonTheme.muted.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding()
    }
}

/// A file pane showing rendered HTML.
///
/// Host-native and deliberately not routed through `PluginWebSurfacePool`: that pool keys
/// surfaces by plugin installation so each plugin gets its own persistent browser profile,
/// and a file preview belongs to no plugin. Minting a fake installation to borrow it would
/// give a host pane a plugin's identity — and its cookie jar.
///
/// The web view is a renderer here, not a browser: no navigation, no JavaScript, and a file
/// read scoped to the file's own directory.
struct WebPreviewSlotView: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        load(into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedPath != path else { return }
        load(into: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(path: path)
    }

    private func load(into view: WKWebView) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            view.loadHTMLString(Self.unreadableHTML(path), baseURL: nil)
            return
        }
        // Read access is the file's own directory and no wider, so a preview cannot walk
        // the disk through a relative link.
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private static func unreadableHTML(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <html><body style="font:12px -apple-system;color:#888;padding:16px">
        Cannot read this page — \(name)
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedPath: String

        init(path: String) {
            loadedPath = path
        }

        /// A preview renders one file. A link that would navigate elsewhere — including
        /// anything remote — is refused rather than followed, because a pane that silently
        /// became a browser would be a browser with none of a browser's controls.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let isInitialLoad = navigationAction.navigationType == .other
                && webView.url == nil
            return isInitialLoad ? .allow : .cancel
        }
    }
}
