// @domain: plugin-settings
import Foundation
import Observation
import TenonIntentCore

// MARK: - Durable stores  @domain: plugin-settings

/// Durable plugin-host stores opened during the app's concurrent startup preparation.
/// Keeping this package-scoped preserves the ordinary `PluginHost` API while letting the
/// production composition root avoid filesystem and lock acquisition on `MainActor`.
package struct PluginHostPersistence: Sendable {
    package let installations: PluginInstallationStore
    package let settings: SettingsStore
    package let storage: PluginStorage
    package let secrets: SecretStore

    package init(stateRoot: URL) throws {
        installations = try PluginInstallationStore(pluginsRoot: stateRoot)
        settings = try SettingsStore(pluginsRoot: stateRoot)
        storage = try PluginStorage(pluginsRoot: stateRoot)
        secrets = try SecretStore()
    }
}
