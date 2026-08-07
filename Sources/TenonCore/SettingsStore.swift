// @domain: plugin-settings
import Foundation
import TenonIntentCore

/// Resource limits shared by plugin settings and plugin storage documents.
public struct PluginValueStoreLimits: Sendable, Equatable {
    public static let hardMaximumDocumentBytes = 64 * 1024 * 1024

    public static let `default` = PluginValueStoreLimits(
        uncheckedMaxKeyBytes: 256,
        maxEntriesPerInstallation: 1_024,
        maxTotalEntries: 16_384,
        maxInstallations: 4_096,
        maxDocumentBytes: 8 * 1024 * 1024
    )

    public let maxKeyBytes: Int
    public let maxEntriesPerInstallation: Int
    public let maxTotalEntries: Int
    public let maxInstallations: Int
    public let maxDocumentBytes: Int

    public init(
        maxKeyBytes: Int,
        maxEntriesPerInstallation: Int,
        maxTotalEntries: Int,
        maxInstallations: Int,
        maxDocumentBytes: Int
    ) throws {
        guard maxKeyBytes > 0,
              maxEntriesPerInstallation > 0,
              maxTotalEntries > 0,
              maxInstallations > 0,
              maxDocumentBytes > 0,
              maxDocumentBytes <= Self.hardMaximumDocumentBytes
        else {
            throw PluginValueStoreError.invalidLimits
        }

        self.init(
            uncheckedMaxKeyBytes: maxKeyBytes,
            maxEntriesPerInstallation: maxEntriesPerInstallation,
            maxTotalEntries: maxTotalEntries,
            maxInstallations: maxInstallations,
            maxDocumentBytes: maxDocumentBytes
        )
    }

    private init(
        uncheckedMaxKeyBytes: Int,
        maxEntriesPerInstallation: Int,
        maxTotalEntries: Int,
        maxInstallations: Int,
        maxDocumentBytes: Int
    ) {
        maxKeyBytes = uncheckedMaxKeyBytes
        self.maxEntriesPerInstallation = maxEntriesPerInstallation
        self.maxTotalEntries = maxTotalEntries
        self.maxInstallations = maxInstallations
        self.maxDocumentBytes = maxDocumentBytes
    }
}

public enum PluginValueStoreError: Error, Sendable, Equatable {
    case invalidLimits
    case corruptDocument
    case unsupportedVersion(Int)
    case duplicateInstallation(PluginInstallationKey)
    case invalidKey
    case keyTooLong(limit: Int)
    case invalidValue(IntentValueError)
    case tooManyInstallations(limit: Int)
    case tooManyEntriesPerInstallation(limit: Int)
    case tooManyEntries(limit: Int)
    case documentTooLarge(limit: Int)
    case encodingFailed
    case persistenceFailed(operation: PersistenceOperation, domain: String, code: Int)

    public enum PersistenceOperation: String, Sendable, Equatable {
        case createDirectory
        case lock
        case read
        case write
    }
}

/// Per-installation setting overrides persisted to `<pluginsRoot>/.settings.json`.
///
/// Every mutation validates a copy, commits that copy atomically, and only then publishes
/// it as actor state. A failed write therefore cannot leak an uncommitted value to readers.
public actor SettingsStore {
    private let documentStore: PluginValueDocumentStore

    public init(
        pluginsRoot: URL,
        limits: PluginValueStoreLimits = .default
    ) throws {
        documentStore = try PluginValueDocumentStore(
            pluginsRoot: pluginsRoot,
            fileName: ".settings.json",
            limits: limits
        )
    }

    /// Returns the user's override or `defaultValue` when no override exists.
    public func value(
        for key: String,
        installation: PluginInstallationKey,
        default defaultValue: IntentValue? = nil
    ) throws -> IntentValue? {
        if let defaultValue {
            try PluginValueDocumentStore.validate(value: defaultValue)
        }
        return try documentStore.value(
            forKey: key,
            installation: installation
        ) ?? defaultValue
    }

    public func values(
        for installation: PluginInstallationKey
    ) throws -> [String: IntentValue] {
        try documentStore.values(for: installation)
    }

    public func setValue(
        _ value: IntentValue,
        forKey key: String,
        installation: PluginInstallationKey
    ) throws {
        try documentStore.setValue(
            value,
            forKey: key,
            installation: installation
        )
    }

    @discardableResult
    public func removeValue(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> IntentValue? {
        try documentStore.removeValue(
            forKey: key,
            installation: installation
        )
    }

    @discardableResult
    public func removeInstallation(
        _ installation: PluginInstallationKey
    ) throws -> [String: IntentValue]? {
        try documentStore.removeInstallation(installation)
    }
}

/// Per-installation persistent data behind `tenon.storage`, stored in
/// `<pluginsRoot>/.storage.json`.
public actor PluginStorage {
    private let documentStore: PluginValueDocumentStore

    public init(
        pluginsRoot: URL,
        limits: PluginValueStoreLimits = .default
    ) throws {
        documentStore = try PluginValueDocumentStore(
            pluginsRoot: pluginsRoot,
            fileName: ".storage.json",
            limits: limits
        )
    }

    public func value(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> IntentValue? {
        try documentStore.value(
            forKey: key,
            installation: installation
        )
    }

    public func values(
        for installation: PluginInstallationKey
    ) throws -> [String: IntentValue] {
        try documentStore.values(for: installation)
    }

    public func setValue(
        _ value: IntentValue,
        forKey key: String,
        installation: PluginInstallationKey
    ) throws {
        try documentStore.setValue(
            value,
            forKey: key,
            installation: installation
        )
    }

    @discardableResult
    public func removeValue(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> IntentValue? {
        try documentStore.removeValue(
            forKey: key,
            installation: installation
        )
    }

    @discardableResult
    public func removeInstallation(
        _ installation: PluginInstallationKey
    ) throws -> [String: IntentValue]? {
        try documentStore.removeInstallation(installation)
    }
}

private struct PluginValueDocumentStore {
    private struct Record: Sendable, Codable {
        let installation: PluginInstallationKey
        let values: [String: IntentValue]
    }

    private struct Document: Sendable, Codable {
        let version: Int
        let records: [Record]
    }

    private static let documentVersion = 1

    private let fileURL: URL
    private let limits: PluginValueStoreLimits

    init(
        pluginsRoot: URL,
        fileName: String,
        limits: PluginValueStoreLimits
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: pluginsRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw Self.persistenceError(.createDirectory, error)
        }

        let fileURL = pluginsRoot.appendingPathComponent(fileName)
        self.fileURL = fileURL
        self.limits = limits
        _ = try Self.withLockedFile(at: fileURL) {
            try Self.load(from: fileURL, limits: limits)
        }
    }

    func value(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> IntentValue? {
        try Self.validate(key: key, limits: limits)
        return try Self.withLockedFile(at: fileURL) {
            try Self.load(
                from: fileURL,
                limits: limits
            )[installation]?[key]
        }
    }

    func values(
        for installation: PluginInstallationKey
    ) throws -> [String: IntentValue] {
        try Self.withLockedFile(at: fileURL) {
            try Self.load(
                from: fileURL,
                limits: limits
            )[installation] ?? [:]
        }
    }

    func setValue(
        _ value: IntentValue,
        forKey key: String,
        installation: PluginInstallationKey
    ) throws {
        try Self.validate(key: key, limits: limits)
        try Self.validate(value: value)

        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL, limits: limits)
            proposed[installation, default: [:]][key] = value
            try Self.validate(proposed, limits: limits)
            try Self.persist(proposed, to: fileURL, limits: limits)
        }
    }

    func removeValue(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> IntentValue? {
        try Self.validate(key: key, limits: limits)
        return try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL, limits: limits)
            guard let current = proposed[installation]?[key] else {
                return nil
            }

            proposed[installation]?.removeValue(forKey: key)
            if proposed[installation]?.isEmpty == true {
                proposed.removeValue(forKey: installation)
            }
            try Self.persist(proposed, to: fileURL, limits: limits)
            return current
        }
    }

    func removeInstallation(
        _ installation: PluginInstallationKey
    ) throws -> [String: IntentValue]? {
        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL, limits: limits)
            guard let current = proposed[installation] else {
                return nil
            }

            proposed.removeValue(forKey: installation)
            try Self.persist(proposed, to: fileURL, limits: limits)
            return current
        }
    }
}

private extension PluginValueDocumentStore {
    static func withLockedFile<Result>(
        at fileURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        do {
            return try DurableJSONFile.withExclusiveLock(
                for: fileURL,
                operation
            )
        } catch let error as PluginValueStoreError {
            throw error
        } catch {
            if let details = DurableJSONFile.posixDetails(for: error) {
                throw PluginValueStoreError.persistenceFailed(
                    operation: .lock,
                    domain: details.domain,
                    code: details.code
                )
            }
            throw persistenceError(.lock, error)
        }
    }

    static func load(
        from fileURL: URL,
        limits: PluginValueStoreLimits
    ) throws -> [PluginInstallationKey: [String: IntentValue]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try readDocumentData(from: fileURL, limits: limits)

        let version: Int
        do {
            version = try StrictJSONDocument.topLevelVersion(in: data)
        } catch {
            throw PluginValueStoreError.corruptDocument
        }
        guard version == documentVersion else {
            throw PluginValueStoreError.unsupportedVersion(version)
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw PluginValueStoreError.corruptDocument
        }
        guard document.records.count <= limits.maxInstallations else {
            throw PluginValueStoreError.tooManyInstallations(
                limit: limits.maxInstallations
            )
        }

        var result: [PluginInstallationKey: [String: IntentValue]] = [:]
        result.reserveCapacity(document.records.count)
        for record in document.records {
            guard result.updateValue(
                record.values,
                forKey: record.installation
            ) == nil else {
                throw PluginValueStoreError.duplicateInstallation(
                    record.installation
                )
            }
        }

        try validate(result, limits: limits)
        return result
    }

    static func persist(
        _ values: [PluginInstallationKey: [String: IntentValue]],
        to fileURL: URL,
        limits: PluginValueStoreLimits
    ) throws {
        try validate(values, limits: limits)

        let records = values.map {
            Record(installation: $0.key, values: $0.value)
        }.sorted {
            if $0.installation.pluginID.rawValue != $1.installation.pluginID.rawValue {
                return $0.installation.pluginID.rawValue
                    < $1.installation.pluginID.rawValue
            }
            return $0.installation.installationID.uuidString
                < $1.installation.installationID.uuidString
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(
                Document(version: documentVersion, records: records)
            )
        } catch {
            throw PluginValueStoreError.encodingFailed
        }
        guard data.count <= limits.maxDocumentBytes else {
            throw PluginValueStoreError.documentTooLarge(
                limit: limits.maxDocumentBytes
            )
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw persistenceError(.write, error)
        }
    }

    static func readDocumentData(
        from fileURL: URL,
        limits: PluginValueStoreLimits
    ) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw persistenceError(.read, error)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(
                upToCount: limits.maxDocumentBytes + 1
            ) ?? Data()
        } catch {
            throw persistenceError(.read, error)
        }
        guard data.count <= limits.maxDocumentBytes else {
            throw PluginValueStoreError.documentTooLarge(
                limit: limits.maxDocumentBytes
            )
        }
        return data
    }

    static func validate(
        _ values: [PluginInstallationKey: [String: IntentValue]],
        limits: PluginValueStoreLimits
    ) throws {
        guard values.count <= limits.maxInstallations else {
            throw PluginValueStoreError.tooManyInstallations(
                limit: limits.maxInstallations
            )
        }

        var totalEntries = 0
        for installationValues in values.values {
            guard installationValues.count <= limits.maxEntriesPerInstallation else {
                throw PluginValueStoreError.tooManyEntriesPerInstallation(
                    limit: limits.maxEntriesPerInstallation
                )
            }
            totalEntries += installationValues.count
            guard totalEntries <= limits.maxTotalEntries else {
                throw PluginValueStoreError.tooManyEntries(
                    limit: limits.maxTotalEntries
                )
            }
            for (key, value) in installationValues {
                try validate(key: key, limits: limits)
                try validate(value: value)
            }
        }
    }

    static func validate(
        key: String,
        limits: PluginValueStoreLimits
    ) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginValueStoreError.invalidKey
        }
        guard key.utf8.count <= limits.maxKeyBytes else {
            throw PluginValueStoreError.keyTooLong(limit: limits.maxKeyBytes)
        }
    }

    static func validate(value: IntentValue) throws {
        do {
            try value.validate(limits: .default)
        } catch let error as IntentValueError {
            throw PluginValueStoreError.invalidValue(error)
        } catch {
            throw PluginValueStoreError.encodingFailed
        }
    }

    static func persistenceError(
        _ operation: PluginValueStoreError.PersistenceOperation,
        _ error: any Error
    ) -> PluginValueStoreError {
        let nsError = error as NSError
        return .persistenceFailed(
            operation: operation,
            domain: nsError.domain,
            code: nsError.code
        )
    }
}
