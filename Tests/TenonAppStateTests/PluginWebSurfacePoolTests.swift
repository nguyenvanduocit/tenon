import Foundation
import WebKit
import XCTest
@testable import TenonApp
@testable import TenonCore
import TenonIntentCore

final class PluginWebSurfacePoolTests: XCTestCase {
    func testSurfaceKeySeparatesInstallationsOfTheSamePlugin() {
        let pluginID: PluginID = "dev.tenon.browser"
        let first = WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: pluginID,
                installationID: UUID()
            ),
            surfaceID: "main"
        )
        let second = WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: pluginID,
                installationID: UUID()
            ),
            surfaceID: "main"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pluginID, pluginID)
    }

    @MainActor
    func testRendererRequiresActiveWebViewCapability() {
        let pool = PluginWebSurfacePool()
        let pluginID: PluginID = "dev.tenon.browser"
        let installationID = UUID()
        let allowed = pluginSnapshot(
            pluginID: pluginID,
            installationID: installationID,
            permissions: ["web.view"]
        )
        let downgraded = pluginSnapshot(
            pluginID: pluginID,
            installationID: installationID,
            permissions: []
        )

        XCTAssertNotNil(
            pool.key(
                pluginID: pluginID,
                surfaceID: "main",
                plugins: [allowed]
            )
        )
        XCTAssertNil(
            pool.key(
                pluginID: pluginID,
                surfaceID: "main",
                plugins: [downgraded]
            )
        )
    }

    @MainActor
    func testSurfaceUsesInstallationPersistentWebsiteDataStore() async throws {
        let installationID = UUID()
        var surface: WebSurface? = WebSurface(
            websiteDataStoreIdentifier: installationID
        )
        // Read the two values out rather than binding the view or its configuration:
        // either binding would keep the data store open past `surface = nil`, and the
        // teardown below is precisely a test of the store being closable.
        let storeIdentifier = try XCTUnwrap(
            surface?.webView?.configuration.websiteDataStore.identifier
        )
        let isPersistent = try XCTUnwrap(
            surface?.webView?.configuration.websiteDataStore.isPersistent
        )

        XCTAssertEqual(storeIdentifier, installationID)
        XCTAssertTrue(isPersistent)

        surface = nil
        try await removeDataStore(installationID)
    }

    func testBrowserUserAgentAdvertisesSafariProductToken() {
        // macOS 26 onward: Safari's marketing version tracks the OS release.
        XCTAssertEqual(
            WebUserAgent.applicationName(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 26,
                    minorVersion: 4,
                    patchVersion: 1
                )
            ),
            "Version/26.4 Safari/605.1.15"
        )
        // Older systems shipped Safari versions unrelated to the OS number. The
        // `Version/` token follows that rule; the product token never moves, because
        // it is the token UA sniffers actually read.
        XCTAssertEqual(
            WebUserAgent.applicationName(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 15,
                    minorVersion: 6,
                    patchVersion: 0
                )
            ),
            "Version/18.5 Safari/605.1.15"
        )
    }

    @MainActor
    func testSurfaceAdvertisesSafariUserAgentToTheNetwork() async throws {
        let installationID = UUID()
        var surface: WebSurface? = WebSurface(
            websiteDataStoreIdentifier: installationID
        )
        // Read the value out rather than binding the view or its configuration: either
        // binding would keep the data store open past `surface = nil`, and the teardown
        // below needs the store closable.
        let applicationName = surface?.webView?.configuration
            .applicationNameForUserAgent

        // Tear down before asserting: this test mints a real persistent store, and an
        // assertion that fails between the two would leave one on disk per failing run.
        surface = nil
        try await removeDataStore(installationID)

        XCTAssertEqual(applicationName, WebUserAgent.current)
    }

    @MainActor
    func testPopupNavigationLoadsInPlaceOnlyForAllowedMainFrameURLs() {
        let allowed = URL(string: "https://example.com/path")
        XCTAssertEqual(
            WebSurface.popupTarget(allowed, initiatedByMainFrame: true),
            allowed
        )
        XCTAssertNil(
            WebSurface.popupTarget(
                URL(string: "javascript:alert(1)"),
                initiatedByMainFrame: true
            )
        )
        XCTAssertNil(
            WebSurface.popupTarget(nil, initiatedByMainFrame: true)
        )
        // An embedded third party asks for a new window with the same delegate shape,
        // and `window.open` needs no user gesture. Adopting it would let a subframe
        // replace the top-level document of the pane.
        XCTAssertNil(
            WebSurface.popupTarget(allowed, initiatedByMainFrame: false)
        )
    }

    /// The rule above, driven by WebKit rather than by the test: a real embedded frame
    /// scripting a real `window.open` reaches the real delegate.
    @MainActor
    func testCrossOriginSubframeCannotRedirectTheSurface() async throws {
        let installationID = UUID()
        var surface: WebSurface? = WebSurface(
            websiteDataStoreIdentifier: installationID
        )
        let settled = Settled()
        surface?.onLoading = { isLoading in
            if !isLoading { settled.value = true }
        }

        // A `data:` document has an opaque origin, so the iframe is cross-origin to the
        // top document, and `window.open` needs no user gesture: WebKit delivers the
        // popup while the page is still loading, ahead of the finish this test waits on.
        // A closed loopback port is the target, so a regression is a local refusal
        // instead of a request to a real host.
        let hijack = "<script>window.open('https://127.0.0.1:9/hijack')</script>"
        let encoded = try XCTUnwrap(
            hijack.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        surface?.webView?.loadHTMLString(
            "<html><body>top<iframe src=\"data:text/html,\(encoded)\"></iframe></body></html>",
            baseURL: try XCTUnwrap(URL(string: "https://a.example/"))
        )

        let loaded = await waitUntil { settled.value }

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            surface?.webView?.url?.absoluteString,
            "https://a.example/"
        )

        surface?.dispose()
        surface = nil
        try await removeDataStore(installationID)
    }

    @MainActor
    func testRetainOnlyReleasesClosedPaneSurface() async throws {
        let pool = PluginWebSurfacePool()
        let firstInstallationID = UUID()
        let secondInstallationID = UUID()
        let first = WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: "dev.tenon.browser",
                installationID: firstInstallationID
            ),
            surfaceID: "first-pane"
        )
        let second = WebSurfaceKey(
            installation: PluginInstallationKey(
                pluginID: "dev.tenon.browser",
                installationID: secondInstallationID
            ),
            surfaceID: "second-pane"
        )
        let firstSurface = pool.surface(for: first)
        _ = pool.surface(for: second)
        weak let releasedWebView = firstSurface.webView

        pool.retainOnly([second])

        XCTAssertNil(pool.existingSurface(for: first))
        XCTAssertNotNil(pool.existingSurface(for: second))
        // The pool drops its reference synchronously; the `WKWebView` itself dies on a
        // later turn, so a bounded wait is the honest assertion. If it never clears, the
        // closed pane leaked its renderer — which is what this test exists to catch.
        let released = await waitUntilReleased { releasedWebView }
        XCTAssertTrue(released, "closing a pane must release its WKWebView")

        pool.disposeAll()
        try await removeDataStore(firstInstallationID)
        try await removeDataStore(secondInstallationID)
    }

    @MainActor
    func testLifecycleCallbackRetiresSurfacesWithoutASpatialCanvas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-web-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginDirectory = root.appendingPathComponent(
            "browser",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        try """
        {
          "id": "dev.test.web-lifecycle",
          "name": "web-lifecycle",
          "version": "1",
          "permissions": ["web.view"],
          "intents": { "uses": [], "provides": [] }
        }
        """.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        tenon.views.register("browser", { title: "Browser" });
        tenon.views.set("browser", {
          body: { type: "webview", surfaceID: "main" }
        });
        """.write(
            to: pluginDirectory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let pluginID: PluginID = "dev.test.web-lifecycle"
        let catalog = WorkspaceCatalog(
            path: root,
            content: .pluginView(
                pluginID: pluginID,
                viewID: "browser"
            )
        )
        let stateRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-state",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        // `.bundledInventory` because this fixture asserts what the pool does with a
        // plugin that HAS `web.view`. Consent is T-021's separate rule and has its own
        // tests; leaving it to prompt here would make this test fail for a reason it is
        // not about.
        let host = try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
        let pool = PluginWebSurfacePool()
        host.onPluginLifecycleChanged = {
            [weak host, weak pool] _ in
            guard let host else { return }
            pool?.reconcile(catalog: catalog, host: host)
        }

        try await host.loadAll()
        let installationID = try XCTUnwrap(
            host.plugins.first?.installationID
        )
        let key = try XCTUnwrap(
            pool.key(
                pluginID: pluginID,
                surfaceID: "main",
                host: host
            )
        )
        let enabledSurface = pool.surface(for: key)
        weak let disabledWebView = enabledSurface.webView

        try await host.setEnabled(false, pluginID: pluginID)

        XCTAssertNil(pool.existingSurface(for: key))
        XCTAssertNil(disabledWebView)
        XCTAssertFalse(
            pool.retiredDataStoreIdentifiers.contains(installationID),
            "disable preserves the installation's persistent browser profile"
        )

        try await host.setEnabled(true, pluginID: pluginID)
        let reenabledKey = try XCTUnwrap(
            pool.key(
                pluginID: pluginID,
                surfaceID: "main",
                host: host
            )
        )
        XCTAssertEqual(reenabledKey.installation.installationID, installationID)
        let reenabledSurface = pool.surface(for: reenabledKey)
        weak let uninstalledWebView = reenabledSurface.webView

        try await host.uninstall(pluginID: pluginID)

        XCTAssertNil(pool.existingSurface(for: reenabledKey))
        XCTAssertNil(uninstalledWebView)
        // Retirement is real work on another task, so the wait has to pass wall-clock
        // time. A `Task.yield()` loop only offers the scheduler a turn — a thousand of
        // them can burn through in microseconds, which is why this passed alone and
        // failed inside the full suite.
        let retired = await waitUntil {
            pool.retiredDataStoreIdentifiers.contains(installationID)
        }
        XCTAssertTrue(
            retired,
            "uninstall retires the installation-scoped persistent data store"
        )
        await host.shutdown()
    }

    @MainActor
    func testDisposeSurfacesForPluginViewSlotsReleasesOnlyTheNamedSlotsWebviews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tenon-web-dispose-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Two separate plugin installations (not two panes of one plugin) so each slot's
        // webview key is unambiguous without needing per-instance surfaceIDs.
        let pluginIDA: PluginID = "dev.test.web-dispose-a"
        let pluginIDB: PluginID = "dev.test.web-dispose-b"
        for pluginID in [pluginIDA, pluginIDB] {
            let pluginDirectory = root.appendingPathComponent(
                pluginID.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: pluginDirectory,
                withIntermediateDirectories: true
            )
            try """
            {
              "id": "\(pluginID.rawValue)",
              "name": "\(pluginID.rawValue)",
              "version": "1",
              "permissions": ["web.view"],
              "intents": { "uses": [], "provides": [] }
            }
            """.write(
                to: pluginDirectory.appendingPathComponent("manifest.json"),
                atomically: true,
                encoding: .utf8
            )
            try """
            tenon.views.register("browser", { title: "Browser" });
            tenon.views.set("browser", {
              body: { type: "webview", surfaceID: "main" }
            });
            """.write(
                to: pluginDirectory.appendingPathComponent("main.js"),
                atomically: true,
                encoding: .utf8
            )
        }

        var catalog = WorkspaceCatalog(
            name: "A",
            path: root,
            content: .pluginView(pluginID: pluginIDA, viewID: "browser")
        )
        catalog.addWorkspace(
            name: "B",
            path: root,
            content: .pluginView(pluginID: pluginIDB, viewID: "browser")
        )
        let slotsByWorkspace = catalog.workspaces.map { workspace in
            catalog.pluginViewSlots.filter { entry in
                workspace.tabs.contains { $0.slots.contains { $0.id == entry.slotID } }
            }
        }
        let workspaceASlots = slotsByWorkspace[0]
        XCTAssertEqual(workspaceASlots.count, 1)

        let stateRoot = root.deletingLastPathComponent()
            .appendingPathComponent(
                "\(root.lastPathComponent)-state",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: root,
            stateRoot: stateRoot,
            kernel: kernel,
            authorization: .bundledInventory
        )
        let pool = PluginWebSurfacePool()
        try await host.loadAll()

        let keyA = try XCTUnwrap(
            pool.key(pluginID: pluginIDA, surfaceID: "main", host: host)
        )
        let keyB = try XCTUnwrap(
            pool.key(pluginID: pluginIDB, surfaceID: "main", host: host)
        )
        _ = pool.surface(for: keyA)
        _ = pool.surface(for: keyB)
        XCTAssertNotNil(pool.existingSurface(for: keyA))
        XCTAssertNotNil(pool.existingSurface(for: keyB))

        pool.disposeSurfaces(forPluginViewSlots: workspaceASlots, host: host)

        XCTAssertNil(pool.existingSurface(for: keyA))
        XCTAssertNotNil(pool.existingSurface(for: keyB))

        pool.disposeAll()
        await host.shutdown()
    }

    @MainActor
    func testVisibleTopLevelNavigationAllowsOnlyHTTPAndHTTPS() {
        XCTAssertTrue(
            WebSurface.allowsTopLevelNavigation(
                URL(string: "https://example.com/path")
            )
        )
        XCTAssertTrue(
            WebSurface.allowsTopLevelNavigation(
                URL(string: "http://127.0.0.1:8080/")
            )
        )
        XCTAssertFalse(
            WebSurface.allowsTopLevelNavigation(
                URL(string: "file:///etc/passwd")
            )
        )
        XCTAssertFalse(
            WebSurface.allowsTopLevelNavigation(
                URL(string: "javascript:alert(1)")
            )
        )
        XCTAssertFalse(
            WebSurface.allowsTopLevelNavigation(
                URL(string: "https://user:secret@example.com/")
            )
        )
    }

    /// `WKWebsiteDataStore.remove(forIdentifier:)` throws `InvalidTransition` while a
    /// `WKWebView` still holds the store open, and a view dies a turn or two after the
    /// statement that dropped its last reference. Retrying is what separates "the store
    /// is still in use" from "the store cannot be removed at all" — the last attempt is
    /// left unguarded so a genuine failure still surfaces as one.
    @MainActor
    private func removeDataStore(
        _ identifier: UUID,
        attempts: Int = 200
    ) async throws {
        for _ in 0 ..< attempts {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                return
            } catch {
                await Task.yield()
            }
        }
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    /// Bounded wait on a condition that other tasks make true. Sleeps rather than yields,
    /// so a loaded machine gets the same answer an idle one does, and returns false on
    /// expiry so the caller asserts rather than hangs.
    @MainActor
    private func waitUntil(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Bounded wait for a weak reference to clear. Returns false if it never does, so the
    /// caller asserts a leak rather than hanging.
    @MainActor
    private func waitUntilReleased(
        attempts: Int = 200,
        _ reference: () -> AnyObject?
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if reference() == nil { return true }
            await Task.yield()
        }
        return reference() == nil
    }

    private func pluginSnapshot(
        pluginID: PluginID,
        installationID: UUID,
        permissions: [String]
    ) -> PluginSnapshot {
        PluginSnapshot(
            id: pluginID,
            installationID: installationID,
            name: "Browser",
            version: "1",
            permissions: permissions,
            unknownPermissions: [],
            settingSpecs: [],
            icon: nil,
            displayName: nil,
            isLoaded: true,
            isEnabled: true,
            permissionViolations: [],
            error: nil
        )
    }
}

/// A flag a WebKit callback sets and a bounded wait polls.
@MainActor
private final class Settled {
    var value = false
}
