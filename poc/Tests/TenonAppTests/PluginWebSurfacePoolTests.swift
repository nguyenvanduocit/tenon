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
        let webView = try XCTUnwrap(surface?.webView)

        XCTAssertEqual(
            webView.configuration.websiteDataStore.identifier,
            installationID
        )
        XCTAssertEqual(
            webView.configuration.websiteDataStore.isPersistent,
            true
        )

        surface = nil
        try await WKWebsiteDataStore.remove(forIdentifier: installationID)
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
        weak var releasedWebView = firstSurface.webView

        pool.retainOnly([second])

        XCTAssertNil(pool.existingSurface(for: first))
        XCTAssertNil(releasedWebView)
        XCTAssertNotNil(pool.existingSurface(for: second))

        pool.disposeAll()
        try await WKWebsiteDataStore.remove(
            forIdentifier: firstInstallationID
        )
        try await WKWebsiteDataStore.remove(
            forIdentifier: secondInstallationID
        )
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
          "permissions": ["web.view"]
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
        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: root,
            kernel: kernel
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
        weak var disabledWebView = enabledSurface.webView

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
        weak var uninstalledWebView = reenabledSurface.webView

        try await host.uninstall(pluginID: pluginID)

        XCTAssertNil(pool.existingSurface(for: reenabledKey))
        XCTAssertNil(uninstalledWebView)
        for _ in 0 ..< 1_000
            where !pool.retiredDataStoreIdentifiers.contains(installationID)
        {
            await Task.yield()
        }
        XCTAssertTrue(
            pool.retiredDataStoreIdentifiers.contains(installationID),
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
