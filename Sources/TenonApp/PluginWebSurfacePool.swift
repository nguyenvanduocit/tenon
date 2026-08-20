// @domain: terminal-surface, plugin-contributions
import AppKit
import Foundation
import Observation
import SwiftUI
import TenonCore
import TenonIntentCore
@preconcurrency import WebKit

struct WebSurfaceKey: Sendable, Equatable, Hashable {
    let installation: PluginInstallationKey
    let surfaceID: String

    var pluginID: PluginID {
        installation.pluginID
    }
}

struct WebSurfaceNavigationEvent: Sendable, Equatable {
    let key: WebSurfaceKey
    let name: String
    let payload: IntentValue
}

/// Owns every web surface behind a caller-scoped key.
///
/// The pool is an injected app service. Plugins only see surface IDs through intents
/// and declarative view nodes; the shell retains the actual `WKWebView` instances.
@MainActor
@Observable
final class PluginWebSurfacePool {
    private(set) var titles: [WebSurfaceKey: String] = [:]
    private(set) var dataStoreRemovalFailures: [UUID: String] = [:]
    private(set) var retiredDataStoreIdentifiers: Set<UUID> = []

    @ObservationIgnored
    var onNavigationEvent: ((WebSurfaceNavigationEvent) -> Void)?

    @ObservationIgnored
    private var surfaces: [WebSurfaceKey: WebSurface] = [:]

    @ObservationIgnored
    private var knownInstallations: Set<PluginInstallationKey> = []

    func surface(for key: WebSurfaceKey) -> WebSurface {
        if let existing = surfaces[key] {
            return existing
        }

        let surface = WebSurface(
            websiteDataStoreIdentifier: key.installation.installationID
        )
        surface.onTitle = { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.titles[key] = title
            self.emit(
                key: key,
                name: "web.title-changed",
                fields: [
                    "surfaceID": .string(key.surfaceID),
                    "title": .string(title),
                ]
            )
        }
        surface.onURL = { [weak self] url in
            self?.emit(
                key: key,
                name: "web.did-navigate",
                fields: [
                    "surfaceID": .string(key.surfaceID),
                    "url": .string(url),
                ]
            )
        }
        surface.onLoading = { [weak self] loading in
            self?.emit(
                key: key,
                name: "web.loading-changed",
                fields: [
                    "surfaceID": .string(key.surfaceID),
                    "loading": .bool(loading),
                ]
            )
        }
        surfaces[key] = surface
        return surface
    }

    func existingSurface(for key: WebSurfaceKey) -> WebSurface? {
        surfaces[key]
    }

    func title(for key: WebSurfaceKey) -> String? {
        titles[key]
    }

    func key(
        pluginID: PluginID,
        surfaceID: String,
        host: PluginHost
    ) -> WebSurfaceKey? {
        key(
            pluginID: pluginID,
            surfaceID: surfaceID,
            plugins: host.plugins
        )
    }

    func key(
        pluginID: PluginID,
        surfaceID: String,
        plugins: [PluginSnapshot]
    ) -> WebSurfaceKey? {
        guard let plugin = plugins.first(where: {
            $0.id == pluginID
                && $0.isEnabled
                && $0.isLoaded
                && $0.permissions.contains("web.view")
        }), let installationID = plugin.installationID
        else {
            return nil
        }
        return WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: pluginID,
                installationID: installationID
            ),
            surfaceID: surfaceID
        )
    }

    func dispose(_ key: WebSurfaceKey) {
        surfaces.removeValue(forKey: key)?.dispose()
        titles.removeValue(forKey: key)
    }

    func retainOnly(_ liveKeys: Set<WebSurfaceKey>) {
        let removed = Set(surfaces.keys).subtracting(liveKeys)
        for key in removed {
            dispose(key)
        }
    }

    /// Disposes exactly the web surfaces owned by the given pluginView slots, for
    /// `workspace.sleep.v1` — which must release one workspace's webviews without
    /// recomputing or touching any other workspace's live keys the way `reconcile` does.
    func disposeSurfaces(
        forPluginViewSlots slots: [(slotID: UUID, pluginID: PluginID, viewID: String)],
        host: PluginHost
    ) {
        let active = Self.activeInstallations(in: host)
        for slot in slots {
            guard let installation = active[slot.pluginID],
                  let section = host.pluginViews.first(where: {
                      $0.pluginID == slot.pluginID
                          && $0.viewID == slot.viewID
                          && (
                              $0.instanceID == nil
                                  || $0.instanceID == slot.slotID.uuidString
                          )
                  }),
                  let body = section.body
            else { continue }
            for surfaceID in Self.webSurfaceIDs(in: body) {
                dispose(WebSurfaceKey(installation: installation, surfaceID: surfaceID))
            }
        }
    }

    /// Reconciles surface lifetime against the host's active view tree and durable
    /// installation snapshots.
    ///
    /// Pane close and plugin disable release `WKWebView`s immediately. Uninstall also
    /// retires the installation-scoped persistent data store; disabling preserves it so
    /// re-enabling the same installation keeps its cookies and session.
    func reconcile(
        catalog: WorkspaceCatalog,
        host: PluginHost
    ) {
        let installed = Set(
            host.plugins.compactMap { plugin -> PluginInstallationKey? in
                guard let installationID = plugin.installationID else {
                    return nil
                }
                return PluginInstallationKey(
                    pluginID: plugin.id,
                    installationID: installationID
                )
            }
        )
        let active = Self.activeInstallations(in: host)

        var liveKeys: Set<WebSurfaceKey> = []
        for slot in catalog.pluginViewSlots {
            guard let installation = active[slot.pluginID],
                  let section = host.pluginViews.first(where: {
                      $0.pluginID == slot.pluginID
                          && $0.viewID == slot.viewID
                          && (
                              $0.instanceID == nil
                                  || $0.instanceID == slot.slotID.uuidString
                          )
                  }),
                  let body = section.body
            else {
                continue
            }
            for surfaceID in Self.webSurfaceIDs(in: body) {
                liveKeys.insert(
                    WebSurfaceKey(
                        installation: installation,
                        surfaceID: surfaceID
                    )
                )
            }
        }
        retainOnly(liveKeys)

        let retired = knownInstallations.subtracting(installed)
        knownInstallations = installed
        for installation in retired {
            retireDataStore(for: installation)
        }
    }

    func disposeAll() {
        retainOnly([])
    }
}

private extension PluginWebSurfacePool {
    func emit(
        key: WebSurfaceKey,
        name: String,
        fields: [String: IntentValue]
    ) {
        onNavigationEvent?(
            WebSurfaceNavigationEvent(
                key: key,
                name: name,
                payload: .object(fields)
            )
        )
    }

    static func activeInstallations(
        in host: PluginHost
    ) -> [PluginID: PluginInstallationKey] {
        Dictionary(
            uniqueKeysWithValues: host.plugins.compactMap {
                plugin -> (PluginID, PluginInstallationKey)? in
                guard plugin.isEnabled,
                      plugin.isLoaded,
                      plugin.permissions.contains("web.view"),
                      let installationID = plugin.installationID
                else {
                    return nil
                }
                return (
                    plugin.id,
                    PluginInstallationKey(
                        pluginID: plugin.id,
                        installationID: installationID
                    )
                )
            }
        )
    }

    static func webSurfaceIDs(
        in node: PluginViewNode
    ) -> Set<String> {
        switch node {
        case let .webview(surfaceID):
            return [surfaceID]
        case let .vstack(_, children),
             let .hstack(_, children),
             let .box(_, _, _, _, children),
             let .card(children),
             let .grid(_, _, children),
             let .scroll(_, children),
             let .field(_, children),
             let .dragSource(_, children),
             let .dropTarget(_, children):
            return children.reduce(into: []) { result, child in
                result.formUnion(webSurfaceIDs(in: child))
            }
        case .text,
             .badge,
             .button,
             .textfield,
             .image,
             .spacer,
             .divider,
             .stat,
             .keyValue,
             .progress:
            return []
        }
    }

    func retireDataStore(
        for installation: PluginInstallationKey
    ) {
        for key in Array(surfaces.keys)
            where key.installation == installation
        {
            dispose(key)
        }
        WKWebsiteDataStore.remove(
            forIdentifier: installation.installationID
        ) { [weak self] error in
            let diagnostic = error.map { String(describing: $0) }
            Task { @MainActor [weak self, diagnostic] in
                guard let self else { return }
                if let diagnostic {
                    dataStoreRemovalFailures[
                        installation.installationID
                    ] = diagnostic
                } else {
                    dataStoreRemovalFailures[
                        installation.installationID
                    ] = nil
                    retiredDataStoreIdentifiers.insert(
                        installation.installationID
                    )
                }
            }
        }
    }
}

@MainActor
final class BrowserIntentProvider {
    private struct ErrorCodes {
        let surfaceNotFound: IntentErrorCode
        let navigationUnavailable: IntentErrorCode
        let navigationFailed: IntentErrorCode

        init() throws {
            surfaceNotFound = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.surface-not-found"
                )
            )
            navigationUnavailable = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.navigation-unavailable"
                )
            )
            navigationFailed = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.navigation-failed"
                )
            )
        }
    }

    private let pool: PluginWebSurfacePool
    private let codes: ErrorCodes

    init(pool: PluginWebSurfacePool) throws {
        self.pool = pool
        codes = try ErrorCodes()
    }

    func bindings() throws -> [IntentProviderBinding] {
        [
            IntentProviderBinding(
                intentID: try CoreIntentName.browserSurfaceLoad.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.load(envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.browserSurfaceBack.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.goBack(envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.browserSurfaceForward.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.goForward(envelope)
                try context.checkCancellation()
                return reply
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.browserSurfaceReload.intentID
            ) { envelope, context in
                try context.checkCancellation()
                let reply = await self.reload(envelope)
                try context.checkCancellation()
                return reply
            },
        ]
    }
}

private extension BrowserIntentProvider {
    func load(_ envelope: IntentEnvelope) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let key = try surfaceKey(
                caller: envelope.caller,
                object: object
            )
            let rawURL = try AppIntentProviderSupport.string(
                "url",
                in: object
            )
            guard let url = Self.httpURL(rawURL),
                  pool.surface(for: key).load(url)
            else {
                return failure(codes.navigationFailed, "invalid-or-refused-url")
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch is IntentPrincipalIdentityError {
            return failure(codes.surfaceNotFound, "plugin-caller-required")
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func goBack(_ envelope: IntentEnvelope) -> IntentProviderReply {
        withExistingSurface(envelope) { surface in
            guard surface.goBack() else {
                return failure(
                    codes.navigationUnavailable,
                    "back-history-unavailable"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        }
    }

    func goForward(_ envelope: IntentEnvelope) -> IntentProviderReply {
        withExistingSurface(envelope) { surface in
            guard surface.goForward() else {
                return failure(
                    codes.navigationUnavailable,
                    "forward-history-unavailable"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        }
    }

    func reload(_ envelope: IntentEnvelope) -> IntentProviderReply {
        withExistingSurface(envelope) { surface in
            guard surface.reload() else {
                return failure(
                    codes.navigationFailed,
                    "reload-refused"
                )
            }
            return AppIntentProviderSupport.emptySuccess
        }
    }

    func withExistingSurface(
        _ envelope: IntentEnvelope,
        operation: (WebSurface) -> IntentProviderReply
    ) -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let key = try surfaceKey(
                caller: envelope.caller,
                object: object
            )
            guard let surface = pool.existingSurface(for: key) else {
                return failure(codes.surfaceNotFound, "surface-not-found")
            }
            return operation(surface)
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch is IntentPrincipalIdentityError {
            return failure(codes.surfaceNotFound, "plugin-caller-required")
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }

    func surfaceKey(
        caller: IntentPrincipal,
        object: [String: IntentValue]
    ) throws -> WebSurfaceKey {
        let owner = try IntentProviderOwner.pluginOwner(from: caller)
        guard case let .plugin(pluginID, installationID) = owner else {
            throw IntentPrincipalIdentityError.pluginPrincipalRequired
        }
        return WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: pluginID,
                installationID: installationID
            ),
            surfaceID: try AppIntentProviderSupport.string(
                "surfaceID",
                in: object
            )
        )
    }

    func failure(
        _ code: IntentErrorCode,
        _ reason: String
    ) -> IntentProviderReply {
        AppIntentProviderSupport.failure(code: code, reason: reason)
    }

    static func httpURL(_ rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else {
            return nil
        }
        return url
    }
}

/// One host-owned web view plus navigation observations.
@MainActor
final class WebSurface: NSObject, WKNavigationDelegate, WKUIDelegate {
    let containerView: NSView
    private(set) var webView: WKWebView?

    var onTitle: ((String) -> Void)?
    var onURL: ((String) -> Void)?
    var onLoading: ((Bool) -> Void)?

    private var lastTitle: String?
    private var lastURL: String?
    private var lastLoading: Bool?

    init(websiteDataStoreIdentifier: UUID) {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = WebUserAgent.current
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: websiteDataStoreIdentifier
        )
        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )
        containerView = NSView(frame: .zero)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(
                equalTo: containerView.leadingAnchor
            ),
            webView.trailingAnchor.constraint(
                equalTo: containerView.trailingAnchor
            ),
            webView.topAnchor.constraint(
                equalTo: containerView.topAnchor
            ),
            webView.bottomAnchor.constraint(
                equalTo: containerView.bottomAnchor
            ),
        ])
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        guard Self.allowsTopLevelNavigation(url),
              let webView
        else {
            return false
        }
        return webView.load(URLRequest(url: url)) != nil
    }

    @discardableResult
    func goBack() -> Bool {
        guard let webView, webView.canGoBack else { return false }
        return webView.goBack() != nil
    }

    @discardableResult
    func goForward() -> Bool {
        guard let webView, webView.canGoForward else { return false }
        return webView.goForward() != nil
    }

    @discardableResult
    func reload() -> Bool {
        guard let webView, webView.url != nil else { return false }
        return webView.reload() != nil
    }

    /// Synchronously severs every owner of the installation-scoped `WKWebView`.
    ///
    /// The stable container remains in SwiftUI until its next render, but the WebKit
    /// instance is detached and released before the pool retires its website data store.
    func dispose() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        onTitle = nil
        onURL = nil
        onLoading = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            return .allow
        }
        return Self.allowsTopLevelNavigation(
            navigationAction.request.url
        ) ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        publishLoading(true)
        publishLocation(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?
    ) {
        publishLocation(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didCommit navigation: WKNavigation?
    ) {
        publishLocation(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        publishLocation(from: webView)
        publishLoading(false)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        publishLocation(from: webView)
        publishLoading(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        publishLocation(from: webView)
        publishLoading(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        publishLoading(false)
    }

    /// A pane is one surface, so a link in its page asking for a new window gets this one.
    ///
    /// WebKit discards every `window.open` / `target="_blank"` navigation when no
    /// `WKUIDelegate` is set — after `decidePolicyFor` has already allowed it — so the link
    /// simply does nothing. Loading in place is the honest single-surface answer; returning
    /// `nil` tells WebKit no separate web view was created.
    ///
    /// This is popup *navigation* only. Alert/confirm/prompt panels and the file-upload
    /// panel stay unimplemented, so WebKit keeps its default of suppressing them.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = Self.popupTarget(
            navigationAction.request.url,
            initiatedByMainFrame: navigationAction.sourceFrame.isMainFrame
        ) {
            load(target)
        }
        return nil
    }

    /// Where a `target="_blank"` / `window.open` navigation should go on a single-surface
    /// pane: the same place, under the same rule that governs any other top-level
    /// navigation. `nil` means the pane declines it.
    ///
    /// Only the page the person is looking at may redirect the pane. A subframe — an ad, a
    /// widget, any embedded third party — reaches this delegate with the same shape, and
    /// `window.open` needs no user gesture, so adopting its target would let an embedded
    /// origin replace the top-level document under the pane's persistent cookie store. A
    /// declined popup is exactly what WebKit did before this delegate existed.
    static func popupTarget(
        _ url: URL?,
        initiatedByMainFrame: Bool
    ) -> URL? {
        guard initiatedByMainFrame,
              let url,
              allowsTopLevelNavigation(url)
        else {
            return nil
        }
        return url
    }

    static func allowsTopLevelNavigation(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            return false
        }
        return true
    }
}

private extension WebSurface {
    func publishLocation(from webView: WKWebView) {
        if let title = webView.title,
           title != lastTitle {
            lastTitle = title
            onTitle?(title)
        }

        if let url = webView.url?.absoluteString,
           url != lastURL {
            lastURL = url
            onURL?(url)
        }
    }

    func publishLoading(_ isLoading: Bool) {
        guard isLoading != lastLoading else { return }
        lastLoading = isLoading
        onLoading?(isLoading)
    }
}

/// Thin SwiftUI bridge; the pool retains the `WKWebView`.
struct WebSurfaceView: NSViewRepresentable {
    let surface: WebSurface

    func makeNSView(context: Context) -> NSView {
        surface.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
