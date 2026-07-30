import Foundation
import Security

public enum SecretStoreError: Error, Sendable, Equatable {
    case invalidServicePrefix
    case servicePrefixTooLong(limit: Int)
    case invalidKey
    case keyTooLong(limit: Int)
    case valueTooLarge(limit: Int)
    case invalidStoredValue
    case keychainFailure(operation: KeychainOperation, status: OSStatus)

    public enum KeychainOperation: String, Sendable, Equatable {
        case read
        case update
        case insert
        case delete
    }
}

/// Per-installation secret storage in the user's Keychain.
///
/// The service name includes both the canonical publisher identity and the immutable
/// installation UUID. Removing and reinstalling a plugin therefore cannot inherit secrets
/// from the previous installation.
public actor SecretStore {
    private static let maximumServicePrefixBytes = 128
    private static let maximumKeyBytes = 256
    private static let maximumValueBytes = 64 * 1024

    private let servicePrefix: String

    public init(servicePrefix: String = "dev.tenon.plugin-secrets") throws {
        guard !servicePrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else {
            throw SecretStoreError.invalidServicePrefix
        }
        guard servicePrefix.utf8.count <= Self.maximumServicePrefixBytes else {
            throw SecretStoreError.servicePrefixTooLong(
                limit: Self.maximumServicePrefixBytes
            )
        }
        self.servicePrefix = servicePrefix
    }

    /// Returns nil only when the key does not exist. Every Keychain failure is thrown.
    public func value(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> String? {
        try Self.validate(key: key)

        var request = query(forKey: key, installation: installation)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(
                operation: .read,
                status: status
            )
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw SecretStoreError.invalidStoredValue
        }
        return value
    }

    public func setValue(
        _ value: String,
        forKey key: String,
        installation: PluginInstallationKey
    ) throws {
        try Self.validate(key: key)
        let data = Data(value.utf8)
        guard data.count <= Self.maximumValueBytes else {
            throw SecretStoreError.valueTooLarge(limit: Self.maximumValueBytes)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let request = query(forKey: key, installation: installation)
        let updateStatus = SecItemUpdate(
            request as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(
                operation: .update,
                status: updateStatus
            )
        }

        var insert = request
        insert.merge(attributes) { _, new in new }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus == errSecSuccess {
            return
        }

        // Another SecretStore instance can win the insert race between our update and add.
        if insertStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                request as CFDictionary,
                attributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw SecretStoreError.keychainFailure(
                    operation: .update,
                    status: retryStatus
                )
            }
            return
        }

        throw SecretStoreError.keychainFailure(
            operation: .insert,
            status: insertStatus
        )
    }

    /// Returns true when an item was deleted and false when it was already absent.
    @discardableResult
    public func removeValue(
        forKey key: String,
        installation: PluginInstallationKey
    ) throws -> Bool {
        try Self.validate(key: key)

        let status = SecItemDelete(
            query(forKey: key, installation: installation) as CFDictionary
        )
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(
                operation: .delete,
                status: status
            )
        }
        return true
    }
}

private extension SecretStore {
    func service(for installation: PluginInstallationKey) -> String {
        [
            servicePrefix,
            installation.pluginID.rawValue,
            installation.installationID.uuidString.lowercased(),
        ].joined(separator: ".")
    }

    func query(
        forKey key: String,
        installation: PluginInstallationKey
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: installation),
            kSecAttrAccount as String: key,
        ]
    }

    static func validate(key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SecretStoreError.invalidKey
        }
        guard key.utf8.count <= maximumKeyBytes else {
            throw SecretStoreError.keyTooLong(limit: maximumKeyBytes)
        }
    }
}
