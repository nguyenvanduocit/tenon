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
