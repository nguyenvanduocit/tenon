import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginHostStateRootTests: XCTestCase {
    @MainActor
    func testHostKeepsMutablePersistenceOutsidePluginInventory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inventoryRoot = root.appendingPathComponent(
            "inventory",
            isDirectory: true
        )
        let stateRoot = root.appendingPathComponent(
            "state",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: inventoryRoot,
            withIntermediateDirectories: true
        )
        let legacySettings = inventoryRoot.appendingPathComponent(
            ".settings.json"
        )
        try Data(
            """
            {
              "claude-sessions": {
                "projectPath": "/tmp/legacy"
              }
            }
            """.utf8
        ).write(to: legacySettings)
        let inventoryBefore = try snapshot(of: inventoryRoot)

        let kernel = try IntentKernelComponents(
            persistence: IntentSQLiteIdempotencyPersistence.inMemory()
        )
        let host = try PluginHost(
            pluginsRoot: inventoryRoot,
            stateRoot: stateRoot,
            kernel: kernel
        )
        let installation = PluginInstallationKey(
            pluginID: "dev.test.state-root",
            installationID: UUID()
        )

        try await host.settings.setValue(
            IntentValue.string("dark"),
            forKey: "theme",
            installation: installation
        )

        XCTAssertEqual(try snapshot(of: inventoryRoot), inventoryBefore)
        XCTAssertEqual(host.pluginsRoot, inventoryRoot)
        XCTAssertEqual(host.stateRoot, stateRoot)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateRoot
                    .appendingPathComponent(".settings.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateRoot
                    .appendingPathComponent(".installations.json.lock").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateRoot
                    .appendingPathComponent(".storage.json.lock").path
            )
        )
    }
}

private func snapshot(of root: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(
        atPath: root.path
    ).sorted()
    return try Dictionary(
        uniqueKeysWithValues: names.map { name in
            let url = root.appendingPathComponent(name)
            return (name, try Data(contentsOf: url))
        }
    )
}
