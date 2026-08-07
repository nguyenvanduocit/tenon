// @domain: plugin-host
import Foundation
import TenonIntentCore

/// Durable identity for one installed copy of a plugin.
///
/// `PluginID` identifies the publisher namespace. `installationID` changes only after an
/// explicit removal followed by a reinstall, so persisted state and policy grants cannot be
/// inherited accidentally by a different installation of the same plugin.
public struct PluginInstallationKey: Sendable, Codable, Hashable {
    public let pluginID: PluginID
    public let installationID: UUID

    public init(pluginID: PluginID, installationID: UUID) {
        self.pluginID = pluginID
        self.installationID = installationID
    }
}

/// One runtime session minted from a durable installation identity.
public struct PluginSessionIdentity: Sendable, Codable, Hashable {
    public let installation: PluginInstallationKey
    public let sessionRevision: UInt64

    public var pluginID: PluginID {
        installation.pluginID
    }

    public var installationID: UUID {
        installation.installationID
    }

    public init(installation: PluginInstallationKey, sessionRevision: UInt64) {
        self.installation = installation
        self.sessionRevision = sessionRevision
    }
}

public enum PluginInstallationStoreError: Error, Sendable, Equatable {
    case corruptDocument
    case unsupportedVersion(Int)
    case duplicatePluginID(PluginID)
    case duplicateInstallationID(UUID)
    case sessionRevisionOverflow(pluginID: PluginID)
    case tooManyInstallations(limit: Int)
    case documentTooLarge(limit: Int)
    case persistenceFailed(operation: PersistenceOperation, domain: String, code: Int)

    public enum PersistenceOperation: String, Sendable, Equatable {
        case createDirectory
        case lock
        case read
        case write
    }
}

struct PluginInstallationDisposition: Sendable {
    let installation: PluginInstallationKey
    let isEnabled: Bool
}

/// Owns installation UUIDs and monotonically increasing runtime-session revisions.
///
/// A session identity is returned only after its new revision's atomic write succeeds. The
/// actor serializes its callers and a sibling lock file serializes the complete transaction
/// with every other store instance and process.
public actor PluginInstallationStore {
    private struct Record: Sendable, Codable {
        let pluginID: PluginID
        let installationID: UUID
        let sessionRevision: UInt64
        let isEnabled: Bool
        /// Optional so version-1 documents written before trust provenance was added still
        /// decode. Reconciliation handles that legacy state before any runtime is created.
        let inventoryTrust: PluginInventoryTrust?
    }

    private struct Document: Sendable, Codable {
        let version: Int
        let records: [Record]
    }

    private static let documentVersion = 1
    private static let maximumInstallations = 4_096
    private static let maximumDocumentBytes = 1024 * 1024

    private let fileURL: URL

    public init(pluginsRoot: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: pluginsRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw Self.persistenceError(.createDirectory, error)
        }

        let fileURL = pluginsRoot.appendingPathComponent(".installations.json")
        self.fileURL = fileURL
        _ = try Self.withLockedFile(at: fileURL) {
            try Self.load(from: fileURL)
        }
    }

    public func installation(
        for pluginID: PluginID
    ) throws -> PluginInstallationKey? {
        try Self.withLockedFile(at: fileURL) {
            try Self.load(from: fileURL)[pluginID].map(Self.installationKey)
        }
    }

    /// Reconciles the inventory's current trust provenance before runtime construction.
    ///
    /// A trust-class change rotates the installation UUID so caller consent, settings,
    /// storage, and secrets owned by the old principal cannot cross the boundary. Moving to
    /// explicit enablement also fails closed by disabling the replacement. Legacy records
    /// have unknowable provenance and therefore rotate once whichever class discovers them.
    func reconcileInventoryTrust(
        for pluginID: PluginID,
        inventoryTrust: PluginInventoryTrust,
        enablesNewPluginsByDefault: Bool
    ) throws -> PluginInstallationDisposition {
        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL)
            let record: Record

            if let current = proposed[pluginID],
               current.inventoryTrust == inventoryTrust
            {
                return PluginInstallationDisposition(
                    installation: Self.installationKey(current),
                    isEnabled: current.isEnabled
                )
            } else if let current = proposed[pluginID] {
                // A trust transition is a new installation. Legacy records have no
                // trustworthy provenance, so they take this path too — even when the
                // current inventory is bundled. Otherwise an attacker could pre-seed a
                // same-ID user installation whose data is later inherited by shipped code.
                record = Record(
                    pluginID: current.pluginID,
                    installationID: Self.freshInstallationID(
                        excluding: proposed.values
                    ),
                    sessionRevision: 0,
                    isEnabled: inventoryTrust == .explicitEnablement
                        ? false
                        : current.isEnabled,
                    inventoryTrust: inventoryTrust
                )
            } else {
                guard proposed.count < Self.maximumInstallations else {
                    throw PluginInstallationStoreError.tooManyInstallations(
                        limit: Self.maximumInstallations
                    )
                }
                record = Record(
                    pluginID: pluginID,
                    installationID: Self.freshInstallationID(
                        excluding: proposed.values
                    ),
                    sessionRevision: 0,
                    isEnabled: enablesNewPluginsByDefault,
                    inventoryTrust: inventoryTrust
                )
            }

            proposed[pluginID] = record
            try Self.persist(proposed, to: fileURL)
            return PluginInstallationDisposition(
                installation: Self.installationKey(record),
                isEnabled: record.isEnabled
            )
        }
    }

    public func currentSession(
        for pluginID: PluginID
    ) throws -> PluginSessionIdentity? {
        try Self.withLockedFile(at: fileURL) {
            guard let record = try Self.load(from: fileURL)[pluginID],
                  record.sessionRevision > 0
            else {
                return nil
            }
            return Self.sessionIdentity(record)
        }
    }

    /// Plugins are enabled until an installation record says otherwise.
    public func isEnabled(for pluginID: PluginID) throws -> Bool {
        try Self.withLockedFile(at: fileURL) {
            try Self.load(from: fileURL)[pluginID]?.isEnabled ?? true
        }
    }

    /// Persists enablement in the installation record. Disabling a discovered plugin before
    /// its first runtime session creates its installation identity with revision zero.
    public func setEnabled(_ isEnabled: Bool, for pluginID: PluginID) throws {
        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL)
            if proposed[pluginID]?.isEnabled == isEnabled {
                return
            }

            if let current = proposed[pluginID] {
                proposed[pluginID] = Record(
                    pluginID: current.pluginID,
                    installationID: current.installationID,
                    sessionRevision: current.sessionRevision,
                    isEnabled: isEnabled,
                    inventoryTrust: current.inventoryTrust
                )
            } else {
                guard proposed.count < Self.maximumInstallations else {
                    throw PluginInstallationStoreError.tooManyInstallations(
                        limit: Self.maximumInstallations
                    )
                }
                proposed[pluginID] = Record(
                    pluginID: pluginID,
                    installationID: Self.freshInstallationID(
                        excluding: proposed.values
                    ),
                    sessionRevision: 0,
                    isEnabled: isEnabled,
                    inventoryTrust: nil
                )
            }

            try Self.persist(proposed, to: fileURL)
        }
    }

    /// Creates an installation UUID once, increments its session revision, persists it, and
    /// only then returns the identity to the caller.
    public func beginSession(for pluginID: PluginID) throws -> PluginSessionIdentity {
        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL)
            let record: Record

            if let current = proposed[pluginID] {
                guard current.sessionRevision < UInt64.max else {
                    throw PluginInstallationStoreError.sessionRevisionOverflow(
                        pluginID: pluginID
                    )
                }
                record = Record(
                    pluginID: pluginID,
                    installationID: current.installationID,
                    sessionRevision: current.sessionRevision + 1,
                    isEnabled: current.isEnabled,
                    inventoryTrust: current.inventoryTrust
                )
            } else {
                guard proposed.count < Self.maximumInstallations else {
                    throw PluginInstallationStoreError.tooManyInstallations(
                        limit: Self.maximumInstallations
                    )
                }
                record = Record(
                    pluginID: pluginID,
                    installationID: Self.freshInstallationID(
                        excluding: proposed.values
                    ),
                    sessionRevision: 1,
                    isEnabled: true,
                    inventoryTrust: nil
                )
            }

            proposed[pluginID] = record
            try Self.persist(proposed, to: fileURL)
            return Self.sessionIdentity(record)
        }
    }

    /// Removes one installation identity. A later `beginSession` is a reinstall with a fresh
    /// UUID and revision 1.
    @discardableResult
    public func removeInstallation(
        for pluginID: PluginID
    ) throws -> PluginInstallationKey? {
        try Self.withLockedFile(at: fileURL) {
            var proposed = try Self.load(from: fileURL)
            guard let current = proposed[pluginID] else {
                return nil
            }

            proposed.removeValue(forKey: pluginID)
            try Self.persist(proposed, to: fileURL)
            return Self.installationKey(current)
        }
    }
}

private extension PluginInstallationStore {
    private static func withLockedFile<Result>(
        at fileURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        do {
            return try DurableJSONFile.withExclusiveLock(
                for: fileURL,
                operation
            )
        } catch let error as PluginInstallationStoreError {
            throw error
        } catch {
            if let details = DurableJSONFile.posixDetails(for: error) {
                throw PluginInstallationStoreError.persistenceFailed(
                    operation: .lock,
                    domain: details.domain,
                    code: details.code
                )
            }
            throw persistenceError(.lock, error)
        }
    }

    private static func load(from fileURL: URL) throws -> [PluginID: Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try readDocumentData(from: fileURL)

        let version: Int
        do {
            version = try StrictJSONDocument.topLevelVersion(in: data)
        } catch {
            throw PluginInstallationStoreError.corruptDocument
        }
        guard version == documentVersion else {
            throw PluginInstallationStoreError.unsupportedVersion(version)
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw PluginInstallationStoreError.corruptDocument
        }
        guard document.records.count <= maximumInstallations else {
            throw PluginInstallationStoreError.tooManyInstallations(
                limit: maximumInstallations
            )
        }

        var result: [PluginID: Record] = [:]
        result.reserveCapacity(document.records.count)
        var installationIDs: Set<UUID> = []
        installationIDs.reserveCapacity(document.records.count)

        for record in document.records {
            guard result.updateValue(record, forKey: record.pluginID) == nil else {
                throw PluginInstallationStoreError.duplicatePluginID(record.pluginID)
            }
            guard installationIDs.insert(record.installationID).inserted else {
                throw PluginInstallationStoreError.duplicateInstallationID(
                    record.installationID
                )
            }
        }
        return result
    }

    private static func persist(
        _ records: [PluginID: Record],
        to fileURL: URL
    ) throws {
        let sortedRecords = records.values.sorted {
            if $0.pluginID.rawValue != $1.pluginID.rawValue {
                return $0.pluginID.rawValue < $1.pluginID.rawValue
            }
            return $0.installationID.uuidString < $1.installationID.uuidString
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(
                Document(version: documentVersion, records: sortedRecords)
            )
        } catch {
            throw PluginInstallationStoreError.corruptDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw PluginInstallationStoreError.documentTooLarge(
                limit: maximumDocumentBytes
            )
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw persistenceError(.write, error)
        }
    }

    private static func readDocumentData(from fileURL: URL) throws -> Data {
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
                upToCount: maximumDocumentBytes + 1
            ) ?? Data()
        } catch {
            throw persistenceError(.read, error)
        }
        guard data.count <= maximumDocumentBytes else {
            throw PluginInstallationStoreError.documentTooLarge(
                limit: maximumDocumentBytes
            )
        }
        return data
    }

    private static func installationKey(
        _ record: Record
    ) -> PluginInstallationKey {
        PluginInstallationKey(
            pluginID: record.pluginID,
            installationID: record.installationID
        )
    }

    private static func sessionIdentity(
        _ record: Record
    ) -> PluginSessionIdentity {
        PluginSessionIdentity(
            installation: installationKey(record),
            sessionRevision: record.sessionRevision
        )
    }

    private static func freshInstallationID(
        excluding records: Dictionary<PluginID, Record>.Values
    ) -> UUID {
        let existing = Set(records.map(\.installationID))
        var candidate = UUID()
        while existing.contains(candidate) {
            candidate = UUID()
        }
        return candidate
    }

    private static func persistenceError(
        _ operation: PluginInstallationStoreError.PersistenceOperation,
        _ error: any Error
    ) -> PluginInstallationStoreError {
        let nsError = error as NSError
        return .persistenceFailed(
            operation: operation,
            domain: nsError.domain,
            code: nsError.code
        )
    }
}
