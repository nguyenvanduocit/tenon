import Foundation
import XCTest
@testable import TenonCore
import TenonIntentCore

@MainActor
final class PluginPersistenceIdentityTests: XCTestCase {
    func testInstallationIdentityRevisionAndEnablementSurviveRestartAndRemoval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("com.example.clock")

        let firstStore = try PluginInstallationStore(pluginsRoot: root)
        let initiallyEnabled = try await firstStore.isEnabled(for: pluginID)
        XCTAssertTrue(initiallyEnabled)

        let first = try await firstStore.beginSession(for: pluginID)
        try await firstStore.setEnabled(false, for: pluginID)
        let second = try await firstStore.beginSession(for: pluginID)

        XCTAssertEqual(first.installation, second.installation)
        XCTAssertEqual(first.sessionRevision, 1)
        XCTAssertEqual(second.sessionRevision, 2)
        let enabledAfterUpdate = try await firstStore.isEnabled(for: pluginID)
        XCTAssertFalse(enabledAfterUpdate)

        let restarted = try PluginInstallationStore(pluginsRoot: root)
        let restartedInstallation = try await restarted.installation(for: pluginID)
        let restartedEnabled = try await restarted.isEnabled(for: pluginID)
        XCTAssertEqual(restartedInstallation, first.installation)
        XCTAssertFalse(restartedEnabled)

        let third = try await restarted.beginSession(for: pluginID)
        XCTAssertEqual(third.installation, first.installation)
        XCTAssertEqual(third.sessionRevision, 3)

        let removed = try await restarted.removeInstallation(for: pluginID)
        let enabledAfterRemoval = try await restarted.isEnabled(for: pluginID)
        let installationAfterRemoval = try await restarted.installation(for: pluginID)
        XCTAssertEqual(removed, first.installation)
        XCTAssertTrue(enabledAfterRemoval)
        XCTAssertNil(installationAfterRemoval)

        let reinstalled = try await restarted.beginSession(for: pluginID)
        XCTAssertNotEqual(
            reinstalled.installation.installationID,
            first.installation.installationID
        )
        XCTAssertEqual(reinstalled.sessionRevision, 1)
        let reinstalledEnabled = try await restarted.isEnabled(for: pluginID)
        XCTAssertTrue(reinstalledEnabled)
    }

    func testMultipleInstallationStoresShareIdentityAndRevision() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("com.example.coordinated")
        let firstStore = try PluginInstallationStore(pluginsRoot: root)
        let secondStore = try PluginInstallationStore(pluginsRoot: root)

        let sessions = try await withThrowingTaskGroup(
            of: PluginSessionIdentity.self
        ) { group in
            for index in 0..<32 {
                group.addTask {
                    let store = index.isMultiple(of: 2)
                        ? firstStore
                        : secondStore
                    return try await store.beginSession(for: pluginID)
                }
            }
            var result: [PluginSessionIdentity] = []
            for try await session in group {
                result.append(session)
            }
            return result
        }

        XCTAssertEqual(Set(sessions.map(\.installation)).count, 1)
        XCTAssertEqual(
            sessions.map(\.sessionRevision).sorted(),
            Array(UInt64(1)...UInt64(32))
        )

        try await firstStore.setEnabled(false, for: pluginID)
        let enabled = try await secondStore.isEnabled(for: pluginID)
        let current = try await secondStore.currentSession(for: pluginID)
        XCTAssertFalse(enabled)
        XCTAssertEqual(current?.sessionRevision, 32)
    }

    func testInstallationDocumentRejectsCorruptionVersionAndDuplicates() throws {
        let pluginID = PluginID("com.example.one")
        let duplicatePluginID = PluginID("com.example.two")
        let firstID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )

        let corruptRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        try write(
            #"{"version":"not-an-integer"}"#,
            to: corruptRoot.appendingPathComponent(".installations.json")
        )
        XCTAssertThrowsError(
            try PluginInstallationStore(pluginsRoot: corruptRoot)
        ) { error in
            XCTAssertEqual(
                error as? PluginInstallationStoreError,
                .corruptDocument
            )
        }

        let versionRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: versionRoot) }
        try write(
            #"{"version":2,"records":{"future":"shape"}}"#,
            to: versionRoot.appendingPathComponent(".installations.json")
        )
        XCTAssertThrowsError(
            try PluginInstallationStore(pluginsRoot: versionRoot)
        ) { error in
            XCTAssertEqual(
                error as? PluginInstallationStoreError,
                .unsupportedVersion(2)
            )
        }

        let duplicatePluginRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicatePluginRoot) }
        try write(
            installationDocument(
                records: [
                    (pluginID.rawValue, firstID, 1, true),
                    (pluginID.rawValue, secondID, 2, false),
                ]
            ),
            to: duplicatePluginRoot.appendingPathComponent(".installations.json")
        )
        XCTAssertThrowsError(
            try PluginInstallationStore(pluginsRoot: duplicatePluginRoot)
        ) { error in
            XCTAssertEqual(
                error as? PluginInstallationStoreError,
                .duplicatePluginID(pluginID)
            )
        }

        let duplicateInstallationRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: duplicateInstallationRoot)
        }
        try write(
            installationDocument(
                records: [
                    (pluginID.rawValue, firstID, 1, true),
                    (duplicatePluginID.rawValue, firstID, 1, true),
                ]
            ),
            to: duplicateInstallationRoot
                .appendingPathComponent(".installations.json")
        )
        XCTAssertThrowsError(
            try PluginInstallationStore(
                pluginsRoot: duplicateInstallationRoot
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginInstallationStoreError,
                .duplicateInstallationID(firstID)
            )
        }
    }

    func testInstallationRevisionOverflowAndWriteFailureDoNotPublishState() async throws {
        let overflowRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overflowRoot) }
        let pluginID = PluginID("com.example.overflow")
        let installationID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        )
        try write(
            installationDocument(
                records: [
                    (pluginID.rawValue, installationID, UInt64.max, true),
                ]
            ),
            to: overflowRoot.appendingPathComponent(".installations.json")
        )

        let overflowStore = try PluginInstallationStore(pluginsRoot: overflowRoot)
        do {
            _ = try await overflowStore.beginSession(for: pluginID)
            XCTFail("Expected revision overflow")
        } catch {
            XCTAssertEqual(
                error as? PluginInstallationStoreError,
                .sessionRevisionOverflow(pluginID: pluginID)
            )
        }

        let rollbackRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rollbackRoot) }
        let rollbackStore = try PluginInstallationStore(pluginsRoot: rollbackRoot)
        let first = try await rollbackStore.beginSession(for: pluginID)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: rollbackRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rollbackRoot.path
            )
        }

        do {
            _ = try await rollbackStore.beginSession(for: pluginID)
            XCTFail("Expected atomic write to fail")
        } catch let error as PluginInstallationStoreError {
            guard case .persistenceFailed(operation: .write, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rollbackRoot.path
        )
        let second = try await rollbackStore.beginSession(for: pluginID)
        XCTAssertEqual(first.installation, second.installation)
        XCTAssertEqual(second.sessionRevision, 2)
    }

    func testSettingsAndStorageIsolateInstallationsAndSurviveRestart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginID = PluginID("com.example.shared")
        let first = PluginInstallationKey(
            pluginID: pluginID,
            installationID: try XCTUnwrap(
                UUID(uuidString: "33333333-3333-3333-3333-333333333333")
            )
        )
        let second = PluginInstallationKey(
            pluginID: pluginID,
            installationID: try XCTUnwrap(
                UUID(uuidString: "44444444-4444-4444-4444-444444444444")
            )
        )

        let settings = try SettingsStore(pluginsRoot: root)
        let storage = try PluginStorage(pluginsRoot: root)
        try await settings.setValue(
            .string("dark"),
            forKey: "theme",
            installation: first
        )
        try await settings.setValue(
            .string("light"),
            forKey: "theme",
            installation: second
        )
        try await storage.setValue(
            .integer(1),
            forKey: "launches",
            installation: first
        )
        try await storage.setValue(
            .integer(99),
            forKey: "launches",
            installation: second
        )

        let restartedSettings = try SettingsStore(pluginsRoot: root)
        let restartedStorage = try PluginStorage(pluginsRoot: root)
        let firstTheme = try await restartedSettings.value(
            for: "theme",
            installation: first
        )
        let secondTheme = try await restartedSettings.value(
            for: "theme",
            installation: second
        )
        let defaultValue = try await restartedSettings.value(
            for: "missing",
            installation: first,
            default: .bool(true)
        )
        let firstLaunches = try await restartedStorage.value(
            forKey: "launches",
            installation: first
        )
        let secondLaunches = try await restartedStorage.value(
            forKey: "launches",
            installation: second
        )
        XCTAssertEqual(firstTheme, .string("dark"))
        XCTAssertEqual(secondTheme, .string("light"))
        XCTAssertEqual(defaultValue, .bool(true))
        XCTAssertEqual(firstLaunches, .integer(1))
        XCTAssertEqual(secondLaunches, .integer(99))

        let removed = try await restartedSettings.removeInstallation(first)
        let removedTheme = try await restartedSettings.value(
            for: "theme",
            installation: first
        )
        let preservedTheme = try await restartedSettings.value(
            for: "theme",
            installation: second
        )
        XCTAssertEqual(removed, ["theme": .string("dark")])
        XCTAssertNil(removedTheme)
        XCTAssertEqual(preservedTheme, .string("light"))
    }

    func testMultipleValueStoresMergeCommittedUpdates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = PluginInstallationKey(
            pluginID: PluginID("com.example.coordinated-values"),
            installationID: UUID()
        )
        let firstSettings = try SettingsStore(pluginsRoot: root)
        let secondSettings = try SettingsStore(pluginsRoot: root)

        try await firstSettings.setValue(
            .string("dark"),
            forKey: "theme",
            installation: installation
        )
        try await secondSettings.setValue(
            .integer(14),
            forKey: "fontSize",
            installation: installation
        )

        let firstSnapshot = try await firstSettings.values(for: installation)
        XCTAssertEqual(
            firstSnapshot,
            ["theme": .string("dark"), "fontSize": .integer(14)]
        )
        let restarted = try SettingsStore(pluginsRoot: root)
        let restartedSnapshot = try await restarted.values(for: installation)
        XCTAssertEqual(
            restartedSnapshot,
            ["theme": .string("dark"), "fontSize": .integer(14)]
        )
    }

    func testValueDocumentEncodingIsDeterministicAcrossMutationOrder() async throws {
        let firstRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let secondRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let pluginID = PluginID("com.example.deterministic")
        let firstInstallation = PluginInstallationKey(
            pluginID: pluginID,
            installationID: try XCTUnwrap(
                UUID(uuidString: "66666666-6666-6666-6666-666666666666")
            )
        )
        let secondInstallation = PluginInstallationKey(
            pluginID: pluginID,
            installationID: try XCTUnwrap(
                UUID(uuidString: "77777777-7777-7777-7777-777777777777")
            )
        )

        let firstStore = try SettingsStore(pluginsRoot: firstRoot)
        try await firstStore.setValue(
            .object(["z": .integer(2), "a": .integer(1)]),
            forKey: "z",
            installation: secondInstallation
        )
        try await firstStore.setValue(
            .string("first"),
            forKey: "a",
            installation: firstInstallation
        )

        let secondStore = try SettingsStore(pluginsRoot: secondRoot)
        try await secondStore.setValue(
            .string("first"),
            forKey: "a",
            installation: firstInstallation
        )
        try await secondStore.setValue(
            .object(["a": .integer(1), "z": .integer(2)]),
            forKey: "z",
            installation: secondInstallation
        )

        XCTAssertEqual(
            try Data(
                contentsOf: firstRoot.appendingPathComponent(".settings.json")
            ),
            try Data(
                contentsOf: secondRoot.appendingPathComponent(".settings.json")
            )
        )
    }

    func testValueDocumentsRejectCorruptionVersionAndDuplicateInstallation() throws {
        let pluginID = PluginID("com.example.values")
        let installation = PluginInstallationKey(
            pluginID: pluginID,
            installationID: try XCTUnwrap(
                UUID(uuidString: "55555555-5555-5555-5555-555555555555")
            )
        )

        let corruptRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        try write(
            #"{"version":1,"records":"invalid"}"#,
            to: corruptRoot.appendingPathComponent(".settings.json")
        )
        XCTAssertThrowsError(try SettingsStore(pluginsRoot: corruptRoot)) { error in
            XCTAssertEqual(error as? PluginValueStoreError, .corruptDocument)
        }

        let versionRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: versionRoot) }
        try write(
            #"{"version":7,"records":{"future":"shape"}}"#,
            to: versionRoot.appendingPathComponent(".settings.json")
        )
        XCTAssertThrowsError(try SettingsStore(pluginsRoot: versionRoot)) { error in
            XCTAssertEqual(
                error as? PluginValueStoreError,
                .unsupportedVersion(7)
            )
        }

        let duplicateRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        let installationJSON = """
        {
          "pluginID": "\(pluginID.rawValue)",
          "installationID": "\(installation.installationID.uuidString)"
        }
        """
        try write(
            """
            {
              "version": 1,
              "records": [
                {"installation": \(installationJSON), "values": {"a": 1}},
                {"installation": \(installationJSON), "values": {"b": 2}}
              ]
            }
            """,
            to: duplicateRoot.appendingPathComponent(".settings.json")
        )
        XCTAssertThrowsError(try SettingsStore(pluginsRoot: duplicateRoot)) { error in
            XCTAssertEqual(
                error as? PluginValueStoreError,
                .duplicateInstallation(installation)
            )
        }

        let duplicateValueRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicateValueRoot) }
        try write(
            """
            {
              "version": 1,
              "records": [
                {
                  "installation": \(installationJSON),
                  "values": {"theme": "dark", "\\u0074heme": "light"}
                }
              ]
            }
            """,
            to: duplicateValueRoot.appendingPathComponent(".settings.json")
        )
        XCTAssertThrowsError(
            try SettingsStore(pluginsRoot: duplicateValueRoot)
        ) { error in
            XCTAssertEqual(error as? PluginValueStoreError, .corruptDocument)
        }

        let oversizedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        let smallDocumentLimits = try PluginValueStoreLimits(
            maxKeyBytes: 16,
            maxEntriesPerInstallation: 1,
            maxTotalEntries: 1,
            maxInstallations: 1,
            maxDocumentBytes: 32
        )
        try write(
            String(repeating: "x", count: 33),
            to: oversizedRoot.appendingPathComponent(".settings.json")
        )
        XCTAssertThrowsError(
            try SettingsStore(
                pluginsRoot: oversizedRoot,
                limits: smallDocumentLimits
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginValueStoreError,
                .documentTooLarge(limit: 32)
            )
        }
    }

    func testStrictJSONDepthBudgetRejectsAdversarialNestingWithoutCrash() throws {
        let allowedArrays = StrictJSONDocument.maximumNestingDepth - 1
        let allowed = """
        {"version":1,"payload":\(String(repeating: "[", count: allowedArrays))0\(String(repeating: "]", count: allowedArrays))}
        """
        XCTAssertEqual(
            try StrictJSONDocument.topLevelVersion(in: Data(allowed.utf8)),
            1
        )

        for arrayCount in [
            StrictJSONDocument.maximumNestingDepth,
            20_000,
        ] {
            let excessive = """
            {"version":1,"payload":\(String(repeating: "[", count: arrayCount))0\(String(repeating: "]", count: arrayCount))}
            """
            XCTAssertThrowsError(
                try StrictJSONDocument.topLevelVersion(
                    in: Data(excessive.utf8)
                )
            ) { error in
                XCTAssertEqual(
                    error as? StrictJSONDocument.ValidationError,
                    .maximumDepthExceeded
                )
            }
        }
    }

    func testValueBoundsAndFailedWriteRollBackMemory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = try PluginValueStoreLimits(
            maxKeyBytes: 4,
            maxEntriesPerInstallation: 1,
            maxTotalEntries: 2,
            maxInstallations: 2,
            maxDocumentBytes: 1_024
        )
        let pluginID = PluginID("com.example.bounds")
        let first = PluginInstallationKey(
            pluginID: pluginID,
            installationID: UUID()
        )
        let second = PluginInstallationKey(
            pluginID: pluginID,
            installationID: UUID()
        )
        let third = PluginInstallationKey(
            pluginID: pluginID,
            installationID: UUID()
        )
        let settings = try SettingsStore(pluginsRoot: root, limits: limits)

        await assertValueStoreError(.invalidKey) {
            try await settings.setValue(
                .null,
                forKey: " ",
                installation: first
            )
        }
        await assertValueStoreError(.keyTooLong(limit: 4)) {
            try await settings.setValue(
                .null,
                forKey: "abcde",
                installation: first
            )
        }

        try await settings.setValue(
            .string("old"),
            forKey: "name",
            installation: first
        )
        await assertValueStoreError(
            .tooManyEntriesPerInstallation(limit: 1)
        ) {
            try await settings.setValue(
                .null,
                forKey: "next",
                installation: first
            )
        }
        try await settings.setValue(
            .null,
            forKey: "name",
            installation: second
        )
        await assertValueStoreError(.tooManyInstallations(limit: 2)) {
            try await settings.setValue(
                .null,
                forKey: "name",
                installation: third
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }
        do {
            try await settings.setValue(
                .string("new"),
                forKey: "name",
                installation: first
            )
            XCTFail("Expected atomic write to fail")
        } catch let error as PluginValueStoreError {
            guard case .persistenceFailed(operation: .write, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let valueAfterFailedWrite = try await settings.value(
            for: "name",
            installation: first
        )
        XCTAssertEqual(valueAfterFailedWrite, .string("old"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        _ = try await settings.removeInstallation(second)
        let restarted = try SettingsStore(pluginsRoot: root, limits: limits)
        let restartedValue = try await restarted.value(
            for: "name",
            installation: first
        )
        XCTAssertEqual(restartedValue, .string("old"))

        await assertValueStoreError(
            .invalidValue(
                .maximumStringBytesExceeded(
                    limit: IntentValueLimits.default.maxStringBytes
                )
            )
        ) {
            _ = try await restarted.value(
                for: "none",
                installation: first,
                default: .string(
                    String(
                        repeating: "x",
                        count: IntentValueLimits.default.maxStringBytes + 1
                    )
                )
            )
        }

        let defaultStoreRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: defaultStoreRoot) }
        let defaultStore = try PluginStorage(pluginsRoot: defaultStoreRoot)
        await assertValueStoreError(
            .invalidValue(
                .maximumStringBytesExceeded(
                    limit: IntentValueLimits.default.maxStringBytes
                )
            )
        ) {
            try await defaultStore.setValue(
                .string(
                    String(
                        repeating: "x",
                        count: IntentValueLimits.default.maxStringBytes + 1
                    )
                ),
                forKey: "payload",
                installation: first
            )
        }

        let tinyRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tinyRoot) }
        let tinyLimits = try PluginValueStoreLimits(
            maxKeyBytes: 16,
            maxEntriesPerInstallation: 1,
            maxTotalEntries: 1,
            maxInstallations: 1,
            maxDocumentBytes: 32
        )
        let tinyStore = try PluginStorage(
            pluginsRoot: tinyRoot,
            limits: tinyLimits
        )
        await assertValueStoreError(.documentTooLarge(limit: 32)) {
            try await tinyStore.setValue(
                .null,
                forKey: "a",
                installation: first
            )
        }
        let tinyValue = try await tinyStore.value(
            forKey: "a",
            installation: first
        )
        XCTAssertNil(tinyValue)

        let totalRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: totalRoot) }
        let totalLimits = try PluginValueStoreLimits(
            maxKeyBytes: 16,
            maxEntriesPerInstallation: 2,
            maxTotalEntries: 2,
            maxInstallations: 3,
            maxDocumentBytes: 1_024
        )
        let totalStore = try PluginStorage(
            pluginsRoot: totalRoot,
            limits: totalLimits
        )
        try await totalStore.setValue(
            .null,
            forKey: "a",
            installation: first
        )
        try await totalStore.setValue(
            .null,
            forKey: "b",
            installation: first
        )
        await assertValueStoreError(.tooManyEntries(limit: 2)) {
            try await totalStore.setValue(
                .null,
                forKey: "a",
                installation: second
            )
        }
    }

    func testSettingValueProducesOwnedIntentValue() {
        XCTAssertEqual(
            PluginSettingValue.string("tenon").intentValue,
            .string("tenon")
        )
        XCTAssertEqual(
            PluginSettingValue.boolean(true).intentValue,
            .bool(true)
        )
        XCTAssertEqual(
            PluginSettingValue.number(1.5).intentValue,
            .number(1.5)
        )
    }

    func testSecretStoreRejectsInvalidInputsBeforeKeychainAccess() async throws {
        XCTAssertThrowsError(try SecretStore(servicePrefix: " ")) { error in
            XCTAssertEqual(error as? SecretStoreError, .invalidServicePrefix)
        }

        let store = try SecretStore(
            servicePrefix: "dev.tenon.persistence-tests.\(UUID().uuidString)"
        )
        let installation = PluginInstallationKey(
            pluginID: PluginID("com.example.secrets"),
            installationID: UUID()
        )

        do {
            _ = try await store.value(forKey: "", installation: installation)
            XCTFail("Expected invalid key")
        } catch {
            XCTAssertEqual(error as? SecretStoreError, .invalidKey)
        }

        do {
            try await store.setValue(
                String(repeating: "x", count: 64 * 1024 + 1),
                forKey: "token",
                installation: installation
            )
            XCTFail("Expected oversized value")
        } catch {
            XCTAssertEqual(
                error as? SecretStoreError,
                .valueTooLarge(limit: 64 * 1024)
            )
        }
    }
}

private extension PluginPersistenceIdentityTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-plugin-persistence-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    func installationDocument(
        records: [(String, UUID, UInt64, Bool)]
    ) -> String {
        let encodedRecords = records.map { record in
            """
            {
              "pluginID": "\(record.0)",
              "installationID": "\(record.1.uuidString)",
              "sessionRevision": \(record.2),
              "isEnabled": \(record.3)
            }
            """
        }.joined(separator: ",")
        return """
        {
          "version": 1,
          "records": [\(encodedRecords)]
        }
        """
    }

    func assertValueStoreError(
        _ expected: PluginValueStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? PluginValueStoreError, expected)
        }
    }
}
